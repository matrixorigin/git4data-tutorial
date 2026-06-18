# MatrixOne Git4Data 技术详解（五）：误操作急救——从手滑 UPDATE 到误删整表，都能秒级回退

上一篇画完了数据版本控制的全景地图——你现在清楚我们说的 git4data 具体指什么。从这一篇起进入实践篇，第一个主题是**数据运维**，而数据运维里没有什么比这件事更让人心跳加速：

> 凌晨两点，你在生产库上敲下一条 `UPDATE`——回车之后才发现，**WHERE 条件忘了写**。8 万条订单的金额，全部变成了同一个数。

传统的处理方式大家都熟：翻昨晚的备份、拉起一个恢复实例、等几个小时导数据，再想办法把备份之后的正常写入补回来——一边操作一边祈祷。整个过程以**小时**计，而事故本身只用了 0.5 秒。

这一篇讲 git4data 给这类时刻准备的**三层安全网**：事前快照、事中调查、事后任意时间点恢复。每条 SQL 都可以直接复制运行。

> 📦 本文全部 SQL 在配套仓库 [matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial)。环境照旧：`docker run -d -p 6001:6001 --name matrixone matrixorigin/matrixone:4.0.0-rc1`，然后灌一张 100 万行的 `orders` 表（建表 SQL 见第二篇或配套仓库，几秒钟的事）。

---

## 第一层：重要操作之前，先按一下"存档键"

最朴素、也最有效的习惯：**任何有风险的批量操作之前，先打一个快照。**

```sql
-- 上线变更前，先存档（毫秒级，与表多大无关）
CREATE SNAPSHOT before_repricing FOR TABLE mydb orders;

-- 跑你的批量变更
UPDATE orders SET amount = amount * 1.1 WHERE region = 'EU';
```

第二篇实测过：给一张 100 万行（乃至 1 亿行）的表打快照，只要 **5–8 毫秒**——因为它只是记录一个时刻、并保护住该时刻的对象（第三篇讲过原理）。这意味着打快照**没有任何心理负担**：每次变更前都打一个，就像写文档时随手 Ctrl+S。

变更出了问题？一条 SQL 回到存档点：

```sql
RESTORE TABLE mydb.orders {SNAPSHOT = before_repricing};
```

秒级完成，整张表回到变更前的状态。这就是 `git reset --hard` 在数据上的样子。

---

## 第二层：先别急着回滚——用 DIFF 看清"到底改坏了什么"

真实事故里，回滚往往不是第一动作。你更想先知道三件事：**改坏了多少行?改坏了哪些行?有没有伤到不该伤的数据?**——因为回滚也有代价（会把事故之后的正常写入一起抹掉），得先评估。

传统数据库在这一步基本只能靠猜。git4data 给你的是**行级的事故报告**：

```sql
-- 当前的表 vs 事故前的快照，到底差了什么？
DATA BRANCH DIFF orders AGAINST orders {SNAPSHOT='before_repricing'} OUTPUT SUMMARY;
```

```
metric   | orders | (snapshot)
INSERTED |      0 |      0
DELETED  |      0 |      0
UPDATED  |    500 |      0     ← 受损范围：500 行被改
```

再看具体是哪些行、被改成了什么：

```sql
DATA BRANCH DIFF orders AGAINST orders {SNAPSHOT='before_repricing'} OUTPUT LIMIT 10;
-- 每一行：哪张表、什么操作、主键、各列当前的值——损失清单一目了然
```

我们在一张 100 万行的表上实测：手滑改了 500 行，这条 DIFF **毫秒级**返回，UPDATED=500，分毫不差（第三篇讲过为什么这么快：它只扫增量对象，不扫全表）。

评估完成，再决定怎么处理——全表回滚、还是只修复受损的行（DIFF 的输出本身就是修复清单）。**"先看清、再动手"，这是 git4data 给数据运维带来的最大心态变化。**

---

## 第三层：没打快照？PITR 兜底——连 DROP TABLE 都能救

第一层有个明显的漏洞：它依赖你**记得**打快照。可事故最爱挑你没存档的时候发生。

所以真正的安全网是 **PITR（任意时间点恢复）**——给库配一个保留窗口，之后这个窗口内的**任何一个时刻**，无论你有没有打过快照，都能恢复回去：

```sql
-- 一次性配置：给库开 1 天的连续保护（建议生产库常备）
CREATE PITR ops_pitr FOR DATABASE mydb RANGE 1 'd';
```

配好之后，它就在后台默默工作。我们来演示一次最糟糕的事故——**整张表被 DROP 了**：

```sql
DROP TABLE orders;        -- 100 万行，没了
SELECT COUNT(*) FROM orders;   -- ERROR: no such table
```

恢复到出事前的任意一刻（时间戳精确到秒）：

```sql
RESTORE DATABASE mydb FROM PITR ops_pitr "2026-06-10 15:45:00";

SELECT COUNT(*) FROM orders;   -- 1000000，整张表连同数据原样回来了
```

这是我们实测过的：**被 DROP 的 100 万行表，从 PITR 整库恢复，数据一行不少。** 传统流程里这是"重大事故、全员加班"级别的事件；这里是一条 SQL。

> ⚠ 一个时序细节（实测踩过）：PITR 有一个生效边界（约等于它的创建时刻）。刚建完 PITR 就拿秒级时间戳去恢复，可能报 `input timestamp ... is less than the pitr valid time`。建完等 1–2 秒、或先 `SHOW PITR` 看一眼生效时间即可。所以：**PITR 要平时就配好，而不是出事了才建**——它保护的是"创建之后"的时间窗。

---

## 安全网的覆盖范围：从一张表到整个集群

以上演示都在表和库的级别，但这套安全网是**全粒度**的——单表手滑、整库污染、租户级灾难，对应同一套语义：

| 事故范围 | 存档 | 恢复 |
|---|---|---|
| 一张表 | `CREATE SNAPSHOT s FOR TABLE db t` | `RESTORE TABLE db.t {SNAPSHOT = s}` |
| 一个库（多表一致） | `CREATE SNAPSHOT s FOR DATABASE db` | `RESTORE DATABASE db FROM PITR p "时刻"` |
| 一个租户 | `CREATE SNAPSHOT s FOR ACCOUNT acc` | `RESTORE ACCOUNT acc FROM SNAPSHOT s` |
| 整个集群 | `CREATE SNAPSHOT s FOR CLUSTER` | `RESTORE CLUSTER FROM SNAPSHOT s` |

库级一点尤其值得记住：**库级快照/恢复是多表原子的**——特征表、订单表、元数据表一起回到同一时刻，不会出现"这张表回去了、那张表没回去"的撕裂状态。

---

## 一页急救卡

把这一篇压缩成一张可以贴在工位上的卡片：

| 时刻 | 动作 | SQL |
|---|---|---|
| **平时** | 给生产库常备 PITR | `CREATE PITR p FOR DATABASE db RANGE 1 'd'` |
| **变更前** | 随手打快照 | `CREATE SNAPSHOT s FOR TABLE db t` |
| **出事后第一步** | 别慌，先看损失 | `DATA BRANCH DIFF t AGAINST t {SNAPSHOT='s'} OUTPUT SUMMARY` |
| **决定回滚** | 回到存档点 | `RESTORE TABLE db.t {SNAPSHOT = s}` |
| **没打快照** | PITR 救回任意一刻 | `RESTORE DATABASE db FROM PITR p "YYYY-MM-DD HH:MM:SS"` |
| **表被 DROP** | 整库 PITR 恢复 | 同上——连表结构带数据一起回来 |

成本几乎为零（快照毫秒级、与数据量无关），收益是把"以小时计的事故恢复"变成"以秒计的一条 SQL"。这笔账，怎么算都划算。

---

## 结语

误操作急救是 git4data 最"朴素"的应用——没有花哨的概念，就是把软件工程里"犯错可以撤销"这件理所当然的事，带给了生产数据库。但注意这一篇里反复出现的一个模式：**事前廉价存档、事中行级看清、事后精确回退**。这个模式不只属于救火。

下一篇我们讲它的进阶形态：**数据团队的协作开发**——多个工程师在同一张大表上并行干活，每人一条分支，改完合并回主线，冲突由数据库裁决。也就是把 GitHub 上的多人协作，搬到数据上。

> 📎 可运行 SQL：[github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ 源码与社区：[github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)

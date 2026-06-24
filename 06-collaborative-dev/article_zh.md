# MatrixOne Git4Data 技术详解（六）·数据运维实践篇：数据协作开发——像合并代码一样合并数据

上一篇讲的是一个人出了事故怎么救。这一篇讲更日常、也更容易被忽视的一件事：**一个团队，同时改同一份数据。**

没有版本控制的时候，团队是怎么协作改数据的？基本靠嘴和靠备份表：

> "这张 `products` 表这两天我在清洗，你先别动。""你改完了吱一声，我再上。"——再配上满库的 `products_backup_0610_final_v2`。

本质上是**串行干活 + 人肉加锁**：一张表同一时间只能一个人安全地动。这正是代码世界二十年前、靠 Git 就告别了的状态。git4data 把 GitHub 那套协作模式原样搬给数据：**每人一条分支，并行干活，改完自查，合并回主线，冲突由数据库逐行裁决。**

这一篇还是一份能照着做的手册：先说清**什么时候真的需要它**，再用一张商品表，把"多人并行""数据 PR 评审""在分支上做大改造""真撞车了怎么裁决"四个真实场景从头跑一遍。每条 SQL 都在 MatrixOne `4.0.0-rc3` 上实测过。

> 📦 本文 SQL 整体可跑：[matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) 的 `06-collaborative-dev/`。环境：`docker run -d -p 6001:6001 --name matrixone matrixorigin/matrixone:4.0.0-rc3`。

---

## 什么时候需要"数据协作开发"？

不是所有改数据都需要分支。但下面这几类情形，几乎一定会撞上"多个人/多条改动要并行推进、又要安全地汇到一起"——这正是它的用武之地：

- **多人并行清洗 / 补全一张大主数据表**：商品库、客户主数据、地址库……三五个人各管一段，同时干。
- **把一次有风险的大改造放到一边慢慢做**：重算全量价格、切换分类体系、批量回填历史字段——工作量大、要反复验证，但**主线得照常对外服务**，不能为它停摆。
- **数据改动要走"评审"再上线**：改的人提交一条分支，负责人看过 diff、确认无误才准合（数据治理 / 合规场景的硬要求）。
- **多人各试一版，择优合并**：不同的清洗规则、不同的打分口径，各自在分支上试，用 DIFF 比一比，留下更好的那版，或从每条分支里挑出最好的部分。

它们的共同点都是一句话：**让"改数据"从一件需要排队、需要互相打招呼的事，变成像改代码一样可以放心并行。**

---

## 场景一：多人并行维护一张主数据表

三位工程师要同时维护一张 10 万行的商品表：Alice 调价、Bob 补缺失的描述、Carol 下架一批停产商品。

先固定全队共同的起点（一个快照），然后每人 fork 一条**带血缘**的分支：

```sql
CREATE SNAPSHOT team_base FOR TABLE collab_demo products;

DATA BRANCH CREATE TABLE products_alice FROM products;
DATA BRANCH CREATE TABLE products_bob   FROM products;
DATA BRANCH CREATE TABLE products_carol FROM products;
```

三条分支**瞬间就位**（第三篇讲过：分支只复制对象引用、不搬数据，毫秒级，10 万行和 6 亿行一样快）。从这一刻起，三个人**互相完全不可见、互相完全不影响**——不需要商量谁先谁后，也不存在"谁正占着这张表"。

![分支协作：全队从 team_base 分出三条独立分支并行修改，改完各自合并回主线](./images/fig_branch-merge_zh.svg)

```sql
-- Alice：A 类商品调价（负责 1~30000 号段）
UPDATE products_alice SET price = round(price * 1.10, 2)
WHERE category = 'A' AND product_id <= 30000;

-- Bob：补缺失描述（负责 30001~60000 号段）
UPDATE products_bob SET descr = concat('backfilled_', product_id)
WHERE descr IS NULL AND product_id BETWEEN 30001 AND 60000;

-- Carol：下架停产区间（90000~95000）
UPDATE products_carol SET status = 'retired'
WHERE product_id BETWEEN 90000 AND 95000;
```

> ⚠ **一个实操要点：分工要按「行」切，不要按「列」切。** git4data 的冲突判定是**行级**的——哪怕 Alice 改的是某行的价格、Bob 改的是同一行的描述，碰的是不同列，合并时也会算作冲突（我们写这篇时真踩到过这个坑）。所以让每个人负责**不重叠的主键号段 / 分区**，就能天然无冲突。下文"真撞车"一节会把这条规则掰开讲。

合并前，每人用 DIFF 给自己的改动做一次行级 self-review——相当于提 PR 之前先看一眼自己的 diff：

```sql
DATA BRANCH DIFF products_alice AGAINST products OUTPUT SUMMARY;
--   metric   | products_alice | products
--   UPDATED  |          10000 |        0     ← 我这次改了 1 万行，范围对不对？有没有误伤？
```

确认无误，依次合并。因为行范围不重叠，三条分支**以任意顺序合并都干净通过**，不需要任何协调：

```sql
DATA BRANCH MERGE products_alice INTO products;
DATA BRANCH MERGE products_bob   INTO products;
DATA BRANCH MERGE products_carol INTO products;
```

主线现在同时携带三个人的成果。整个过程：**没有锁表、没有窗口期、没有"你等我"。** 这就是"廉价的并行"最直接的样子。

---

## 场景二：把"数据改动"做成一次可评审的 PR

第二个常见诉求是**治理**：一处批量数据修复，不能让人直接在生产表上 `UPDATE` 完事，得有人先看一眼、批准了才算数。

git4data 让"数据改动"天然变成一次可评审的 PR——改的人在分支上动手，负责人在合并前 review：

```sql
-- 改的人：在分支上做，绝不碰生产表
DATA BRANCH CREATE TABLE products_fix_1837 FROM products;
UPDATE products_fix_1837 SET category = 'A'
WHERE category = 'C' AND name LIKE 'prod_1%';        -- 一处分类订正

-- 负责人 review：先看规模，再逐行看，必要时留底
DATA BRANCH DIFF products_fix_1837 AGAINST products OUTPUT SUMMARY;   -- 改了多少、什么类型
DATA BRANCH DIFF products_fix_1837 AGAINST products OUTPUT LIMIT 20;  -- 逐行看改成了什么
DATA BRANCH DIFF products_fix_1837 AGAINST products OUTPUT FILE '/tmp';  -- 存一份 .sql 补丁备查
```

这一步和你在 GitHub 上点开一个 PR、逐行看 diff 是**完全一样的动作**——只不过看的是数据。看完之后：

```sql
-- 批准：合入主线
DATA BRANCH MERGE products_fix_1837 INTO products;
-- 或者打回：直接删掉分支，生产表一行都没动过
DROP TABLE products_fix_1837;
```

两个关键点：**改动在合并之前，对生产完全不可见**；而 review 是建立在**行级事实（DIFF）**上的，不是"我大概改了下分类"这种口头描述。对需要留痕、需要审批的团队，这一条本身就值回票价。

---

## 场景三：在分支上开发一次大改造，主线照常服务

有些改造不是几行 UPDATE，而是一个**项目**：把全部商品按新分类体系重打标签、再重算价格，要写不少逻辑、反复跑、反复校验，可能要几小时甚至几天。

传统做法很难受：要么停服务、要么搭一套 CDC 双写再对账，要么忍受"改一半的中间态被业务读到"。git4data 的做法是——**开一条分支，在分支上慢慢折腾，主线照常对外读写、零感知**：

```sql
DATA BRANCH CREATE TABLE products_migration FROM products;

-- 在 products_migration 上反复迭代你的大改造逻辑……
-- 主线 products 这期间照常被业务读写，完全不受影响。

-- 改造完成、自测通过后，先 DIFF 确认改动范围符合预期（没有越界误伤）：
DATA BRANCH DIFF products_migration AGAINST products OUTPUT SUMMARY;

-- 一切无误，一次性原子合入主线：
DATA BRANCH MERGE products_migration INTO products;
```

分支是你的"施工围挡"：里面怎么折腾都行，外面的生意照做；拆围挡（合并）是**秒级**的一步，不是一个漫长的切换窗口。

> 边界提醒：这套行级 diff/merge **要求两边 schema 一致**。如果你的大改造要动表结构（加列、改类型），顺序得是"**先在主线改 schema、再开分支**"，而不是在分支里改结构再合（第四篇讲过这个边界）。

---

## 真撞车了怎么办：真假冲突 + 三种裁决

分工再好也有意外。这一节是协作的核心，值得讲细。先记住那条唯一的规则：

> **只有"两条分支都独立改了同一行"，才算真冲突。** 改的是不同的行 → 假冲突，数据库自动合并，无需任何人介入；哪怕两人改的是同一行的不同列，也算真冲突（行级判定）。

![真假冲突：改不同行自动合并（假冲突），改同一行才需裁决（真冲突）](./images/fig_conflict-detect_zh.svg)

Dave 和 Erin 不知情地改了**同一行**（42 号），同时 Erin 还顺手改了另一行（20 号，没人碰）：

```sql
DATA BRANCH CREATE TABLE products_dave FROM products;
DATA BRANCH CREATE TABLE products_erin FROM products;
UPDATE products_dave SET price = 1.00 WHERE product_id = 42;     -- Dave 改 42
UPDATE products_erin SET price = 2.00 WHERE product_id = 42;     -- Erin 也改 42（撞车）
UPDATE products_erin SET status = 'retired' WHERE product_id = 20;  -- Erin 独有、不冲突

DATA BRANCH MERGE products_dave INTO products;     -- Dave 先到，干净合入，主线 42 = 1.00
```

现在 Erin 来合，42 号撞上了。三种裁决方式，行为各不相同——这是实测确认的：

```sql
-- ① FAIL（默认）：一旦发现冲突，整个合并中止回滚。
DATA BRANCH MERGE products_erin INTO products WHEN CONFLICT FAIL;
--   报错：conflict on pk(42)；主线一行未动——连 Erin 不冲突的 20 号也没合进来。
--   FAIL 是"全有或全无"：把冲突摆到台面上，让你先去解决。
```

```sql
-- ② SKIP：只跳过冲突的行，其余正常合入。
DATA BRANCH MERGE products_erin INTO products WHEN CONFLICT SKIP;
--   结果：42 号保留主线的值（Dave 的 1.00）；20 号成功合入（Erin 的 retired）。
```

```sql
-- ③ ACCEPT：冲突行采用分支（Erin）的值，其余也照常合入。
DATA BRANCH MERGE products_erin INTO products WHEN CONFLICT ACCEPT;
--   结果：42 号变成 Erin 的 2.00。
```

![三种冲突裁决：FAIL 整体中止 / SKIP 跳过冲突行其余合入 / ACCEPT 冲突行采用分支值](./images/fig_conflict-policies_zh.svg)

这里有两个容易忽略、但很关键的点：

1. **数据库把冲突显式摆出来，而不是悄悄让后写覆盖先写。** "后写静默覆盖先写"正是没有版本控制时最常见的事故来源（lost update），而这里它变成一个你必须主动裁决的决定。
2. **需要裁决的只有真撞上的那一行。** Erin 分支里其它成百上千行正常改动，会跟着 SKIP/ACCEPT 自动合入——要人拍板的，永远只是那几行真冲突。

### 只想挑几行过去：cherry-pick

有时你不想合整条分支，只想把里面**某几条改动**（比如几条紧急修复）单独提到主线。这就是 cherry-pick：

```sql
-- 只把 50、51 两条改动挑到主线，其余不动（PICK 需要主键）
DATA BRANCH PICK products_fix INTO products KEYS (50, 51) WHEN CONFLICT FAIL;
--   实测：只有 50、51 号被合入，52 号即便在分支里也改过，主线保持原值。
```

回到上一篇埋的那个伏笔：第五篇里"手工 `UPDATE … JOIN` 把受损行还原、保住新订单"的定点修复，本质上就是这里 `DATA BRANCH MERGE` 自动做的三方合并——以共同祖先为基准、自动区分真假冲突。当时我们手工跑了一遍原理，现在把它交还给数据库：真假冲突自动判，撞车了再按策略裁决。

---

## 几条让冲突更少的实践

- **按主键号段 / 分区分工**，让各人的改动天然不重叠——这是成本最低的"无冲突"。
- **小步快合**：频繁地把小分支合回主线，比攒一个月再做一次大爆炸式合并，冲突少得多。
- **全队固定一个 base 快照**（`team_base`），所有分支从它分出——血缘清晰，合并走第三篇说的增量快路径。
- **要改表结构？先在主线改 schema、再开分支**，别在分支里改完结构再合。

---

## 这就是数据的 Pull Request

对照一下你每天在 GitHub 上做的事，几乎一一对应：

| GitHub | git4data |
|---|---|
| fork / branch | `DATA BRANCH CREATE TABLE … FROM …` |
| 看自己 / 别人的 diff | `DATA BRANCH DIFF … AGAINST … OUTPUT SUMMARY / LIMIT / FILE` |
| merge PR | `DATA BRANCH MERGE … INTO …` |
| 冲突解决 | `WHEN CONFLICT FAIL / SKIP / ACCEPT` |
| cherry-pick | `DATA BRANCH PICK … INTO … KEYS (…)` |
| 回到分叉点 | `RESTORE TABLE … {SNAPSHOT = team_base}` |

---

## 成本与边界

- **分支免费、合并秒级**，并且与表多大、并行多少人无关：之前实测过，6 亿行的表、4 个工程师各自 fork、各改百万行，每次合并都是**秒级**。并行人数和表大小，都不再是协作的瓶颈。
- **冲突裁决是行级，不是单元格级**：同一行的不同列也算冲突（第四篇讲过；单元格级自动合并是未来工作）。
- **diff/merge 要求 schema 一致**，且血缘可用时才走增量快路径（第三篇）。
- **`FAIL` 是全有或全无**：要"部分合并"，用 `SKIP` / `ACCEPT`，或用 `PICK` 精确挑行。

---

## 结语

数据协作开发，是 git4data 把"廉价的并行"兑现得最彻底的地方：分支免费、合并秒级、冲突显式且只裁决真撞上的行。团队规模，不再被"一张表同一时间只能一个人动"这条隐形约束卡住。

但有个问题这篇还没回答：合并进主线的数据，**质量谁来把关**？万一某条分支合进来的就是脏数据呢？下一篇讲发布侧的答案：**Write-Audit-Publish**——新数据先进 staging 分支、过一道 SQL 审计门禁、再原子发布，让生产**永远看不到**没过关的数据。

> 📎 可运行 SQL：[github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ 源码与社区：[github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)

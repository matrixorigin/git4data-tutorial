# MatrixOne Git4Data 技术详解（十五·终章）：Agent 自进化——branch、评估、合并、回滚

这个系列的第一篇就放过一张图:生产 Agent 的数据被 fork 成几条隔离分支,各自尝试不同的改进(SFT、强化、治理),离线评估把关,赢家合并上线,输家整支丢弃——**每一步都由机器驱动,没有人类工程师在环里**。

当时它是一张愿景图。十四篇之后,跑通它需要的每一块积木都已经在你手里了:分支(六)、门禁(七)、评估数据(八~十一)、记忆与轨迹(十三、十四)。终章,把它们拼成那个闭环。

> 📦 本文 SQL 整体可跑:[matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) 的 `15-agent-evolution/`。

---

## Agent 的"大脑"也是一张表

可进化的部分——技能、prompt 模板、各技能的滚动评分——本来就该结构化存放:

```sql
CREATE TABLE brain (
    skill_id BIGINT PRIMARY KEY,
    skill    VARCHAR(32),
    prompt   VARCHAR(256),
    score    DECIMAL(5,2)
);
-- 200 个技能,生产中服役
CREATE SNAPSHOT brain_gen0 FOR TABLE evolve_demo brain;   -- 本轮进化的回滚点
```

`brain_gen0` 是这一轮进化的**保险**:无论下面发生什么,第 0 代永远一条语句可回。

## 第一步:branch——三个候选,三种策略

进化的本质是**并行探索假设空间**。三条分支,三种互相隔离的变异策略:

```sql
DATA BRANCH CREATE TABLE cand_sft FROM brain;   -- 策略一:重写弱技能的 prompt
DATA BRANCH CREATE TABLE cand_rl  FROM brain;   -- 策略二:强化已经好用的
DATA BRANCH CREATE TABLE cand_gov FROM brain;   -- 策略三:裁汰持续失败的

UPDATE cand_sft SET prompt = concat('prompt_v2_refined_', skill_id) WHERE score < 60;
UPDATE cand_rl  SET prompt = concat(prompt, '_reinforced'), score = score + 5 WHERE score > 70;
DELETE FROM cand_gov WHERE score < 55;
```

三个候选互不可见,生产大脑毫发无伤——第三篇讲过,这三条分支的物理成本只是三份对象引用元数据,几毫秒。**廉价,是机器敢于大胆探索的前提**:如果开一个候选要拷一遍全量数据,进化循环根本转不起来。

## 第二步:评估——replay 门禁

每个候选大脑挂上影子 Agent,对着固定任务集回放(replay),评估器把分数写回库里:

```sql
CREATE TABLE eval_results (candidate VARCHAR(16) PRIMARY KEY, eval_score DECIMAL(5,2));
INSERT INTO eval_results VALUES ('cand_sft', 71.40), ('cand_rl', 66.20), ('cand_gov', 64.80);

-- 门禁:生产基线 65.0,过线者按分数排队
SELECT * FROM eval_results WHERE eval_score > 65.0 ORDER BY eval_score DESC;
--   cand_sft  71.40   ← 赢家
--   cand_rl   66.20   ← 过线但非最优
```

上线前最后一道审查——赢家**究竟**要往生产大脑里改什么,行级摊开:

```sql
DATA BRANCH DIFF cand_sft AGAINST brain OUTPUT SUMMARY;
```

机器决策也要有可审计的形态。这条 DIFF 就是进化的"变更说明书",出事时人类可以回来查。

## 第三步:合并赢家,丢弃输家

```sql
DATA BRANCH MERGE cand_sft INTO brain WHEN CONFLICT ACCEPT;   -- 赢家上线
DROP TABLE cand_rl;                                            -- 输家整支消失
DROP TABLE cand_gov;

CREATE SNAPSHOT brain_gen1 FOR TABLE evolve_demo brain;        -- 第 1 代封档
```

注意输家的结局:`DROP TABLE`,干净利落。没有残留状态、没有半合并的污染——**敢丢弃,和敢探索同样重要**,而这同样是分支廉价带来的。

## 第四步:安全属性——进化永远可悔

第 1 代上线后在生产中劣化了?

```sql
RESTORE TABLE evolve_demo.brain {SNAPSHOT = brain_gen0};   -- 一条语句,回到第 0 代
```

而且每一代之间的差异终身可查:

```sql
DATA BRANCH DIFF brain AGAINST brain {SNAPSHOT='brain_gen0'} OUTPUT SUMMARY;
--   两代之间恰好哪些技能变了——进化史每一步都有据可查
```

**branch → 变异 → 评估 → 合并/丢弃 → 封档 → 重复。** 这个循环可以夜复一夜地自动转下去,人类只在告警响起时回来翻账本。

---

## 终章总结:为什么这件事非版本控制不可

回到第一篇的论断:Agent 的三个本质特征——**自主、会犯错、需要并行探索**——恰好是当年 Git 为人类开发者解决的三件事。现在把主语换成机器,这个对应不是修辞,是工程上的一一映射:

| Agent 的需要 | git4data 的供给 |
|---|---|
| 大胆探索而不伤生产 | 分支 = 毫秒级沙箱 |
| 多个假设并行验证 | N 个候选 = N 条分支 |
| 决策可审计 | DIFF = 行级变更说明书 |
| 犯错可逆 | RESTORE = 一条语句的悔棋 |
| 进化史可追溯 | 快照链 = 每一代的封档 |

没有版本控制的 Agent 只有两种结局:**鲁莽**(不可逆地乱改),或**瘫痪**(什么都不敢动)。版本控制是把"自我进化"从演示变成生产系统的那个前提条件。

十四篇至此收官。从"代码有 Git,数据没有"的那个问题出发,经过原理、运维、训练,走到机器自己驱动的进化闭环——**让海量数据可版本化,从来不只是补一笔历史欠账;它是 AI 时代数据基础设施的地基。** 这个系列结束了,但建在这块地基上的东西,才刚刚开始。

> 📎 全系列可运行 SQL:[github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ 源码与社区:[github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)

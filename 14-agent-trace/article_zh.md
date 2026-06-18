# MatrixOne Git4Data 技术详解（十四）：Agent Trace——版本化的运行轨迹

Agent 主题第二篇,讲记忆之外的另一类核心数据:**trace(运行轨迹)**。

一个 Agent 处理一次请求,内部其实是一连串动作:接到任务 → 调 LLM 规划 → 调工具 → 再调 LLM 总结……每一步的耗时、token、成败,构成一棵调用树(OpenTelemetry 的 GenAI 规范管它叫 spans)。这些 trace 是回答一切 Agent 工程问题的原始证据:**为什么慢?为什么贵?为什么错?升级之后真的变好了吗?**

通常 trace 被丢给专门的 APM/可观测平台。那条路在"看大盘"上很强,但有两件事它做不好——**而这两件恰好是 Agent 工程最需要的**:

1. **trace 和业务数据联不起来**:想知道"出错的请求都集中在哪类用户/哪个数据集分片",需要 trace JOIN 业务表——可观测平台里没有你的业务表;
2. **trace 没有版本语义**:"Agent v1 时代的轨迹"和"v2 时代的轨迹"混在一条时间线里,A/B 靠时间窗口切,边界模糊。

把 trace 落进 git4data,这两件事都是顺手解决的。

> 📦 本文 SQL 整体可跑:[matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) 的 `14-agent-trace/`。配套仓库里还有一个用真实 OpenTelemetry SDK + 自定义 Exporter 把真 Agent 的 span 写进 MatrixOne 的完整实现。

---

## Trace 就是行

OTel 风格的 span 表(简化版):trace_id、span_id、parent_id、名称、模型、token、耗时、是否出错。Agent v1 在生产上跑了 1000 个请求,6000 个 span 入库。

trace 是行,意味着**全部 SQL 能力直接可用**。重建一棵调用树是个自连接:

```sql
SELECT s.name, s.tokens, s.dur_ms, p.name AS parent
FROM spans s LEFT JOIN spans p ON s.parent_id = p.span_id
WHERE s.trace_id = 7 ORDER BY s.span_id;
```

算全量指标不抽样、不近似:

```sql
SELECT COUNT(DISTINCT trace_id) AS traces,
       SUM(tokens)              AS total_tokens,
       SUM(CASE WHEN is_error=1 THEN 1 ELSE 0 END) AS errors
FROM spans;
```

以及可观测平台给不了的:**trace JOIN 业务表**——"哪个数据集分片上的请求 token 最高""出错请求对应的用户画像"——因为它们就在同一个库里。

## 快照 = Agent 版本的行为存档

关键动作来了。Agent v1 要升级到 v2(换 prompt、换更便宜的模型)之前:

```sql
CREATE SNAPSHOT traces_v1 FOR TABLE trace_demo spans;
```

这个快照的含义不是"备份",而是**"v1 时代行为的封档"**:它钉住了 v1 全部轨迹,从此 v2 的 trace 随便往同一张表里灌,两个时代互不污染。

## A/B:有版本语义的对比

v2 上线,5000 个新 span 落库。现在做升级评审:

```sql
-- v1 时代的全貌:读快照
SELECT SUM(tokens), SUM(CASE WHEN is_error=1 THEN 1 ELSE 0 END)
FROM spans {snapshot='traces_v1'};

-- v2 净贡献了什么:DIFF 一下,边界精确到行
DATA BRANCH DIFF spans AGAINST spans {SNAPSHOT='traces_v1'} OUTPUT SUMMARY;
--   INSERTED = 5000   ← v2 产生的 span,恰好这些,没有混入
```

对比结果:v2 的单请求 token 显著下降(新模型 + 更短的循环),错误率持平——**升级结论来自版本化的数据,而不是盯着大盘曲线目测**。如果 v2 表现劣化,你手里有精确的两个对照组,逐 trace 下钻找原因。

这里的范式转变值得点破:可观测平台用**时间**切分版本("大概是周二下午上的线"),git4data 用**版本**切分版本——快照打在哪,边界就在哪,和部署时刻的模糊性无关。

---

## 诚实边界:它不替代 APM

第十五篇之前的老规矩,边界说清楚:如果你的需求是**海量实时监控**——百万 span/秒摄入、p99 分位数大盘、TTL 自动过期、告警生态——ClickHouse 这类专用引擎仍是更对的选择,我们实测对比过,差距是真实的。

git4data 路线的甜区是 **Agent 工程的分析与回归**:中等量级的 trace、要和业务数据联接、要按 Agent 版本做精确 A/B、要把"某一版的行为"长期封档可复现。两条路线不互斥——很多团队的答案是 APM 看实时大盘,trace 同时落一份进数据库做深度分析。

---

## 结语

Trace 入库后,Agent 工程的证据链闭环了:**记忆**(上一篇)记录它"知道什么",**trace**(本篇)记录它"做了什么",两者都版本化、都可 SQL、都在一个库里互相 JOIN。

只差最后一块拼图:让 Agent 用这些证据**改进它自己**。下一篇,系列终章——**Agent 自进化**:branch 出多个候选大脑、隔离评估、合并赢家、丢弃输家,全程机器驱动。这个系列从第一篇就在铺垫的那张图,终于要跑起来了。

> 📎 可运行 SQL:[github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ 源码与社区:[github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)

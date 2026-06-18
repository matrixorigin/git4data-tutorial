# MatrixOne Git4Data 技术详解（八）：ML 持续学习——只训练"变了的那部分"

从这一篇起进入 AI 训练主题。先从一个所有 ML 工程师都熟的循环说起：

> 数据每天都在变——新样本进来、旧标签被修正。于是每周（甚至每天）把**全量**数据重新喂给模型,从头训一遍。数据涨到千万级后,这个循环越来越贵、越来越慢,但你不敢省:因为你**说不清这周到底哪些数据变了**。

问题的根源不在训练,在数据侧:**缺一个"上次训练之后,数据动了哪些"的精确答案。** git4data 恰好就是干这个的。

> 📦 本文 SQL 整体可跑:[matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) 的 `08-ml-incremental/`。

---

## 每次训练,先 pin 一个版本

训练集是一张 `samples` 表,旁边放一张模型注册表。第一次训练前,把数据状态钉住:

```sql
CREATE SNAPSHOT train_v1 FOR TABLE mltrain_demo samples;
-- (训练器读全表,训出模型 m1 ...)
INSERT INTO model_registry VALUES ('m1', 'train_v1', 0.9012);
```

这一步毫秒级、近零成本,但它把"模型 m1 是用什么数据训的"从一句口头描述,变成了一个**可执行的事实**——任何时候 `SELECT ... FROM samples {snapshot='train_v1'}` 都能逐位复原 m1 的训练集。

## 一周后:数据动了,但动了哪些?

一周的真实生活:新批次进来 3000 行,质检又修正了 200 个标签:

```sql
INSERT INTO samples SELECT ... FROM generate_series(1, 3000) g;        -- 新数据
UPDATE samples SET label = 1 - label WHERE sample_id BETWEEN 500 AND 699;  -- 标签修正
```

现在问关键问题——**相对 m1 的训练集,数据到底变了哪些?** 一条 DIFF:

```sql
DATA BRANCH DIFF samples AGAINST samples {SNAPSHOT='train_v1'} OUTPUT SUMMARY;
--   INSERTED = 3000   (新批次)
--   UPDATED  =  200   (被修正的标签)
--   DELETED  =    0
```

答案精确到行:**变更就是这 3200 行,其余 10 万行一行没动。** 用 `OUTPUT LIMIT` / `OUTPUT FILE` 把这 3200 行取出来,喂给 `partial_fit`(scikit-learn)或你的增量训练逻辑——全量重训就此告别。

我们在配套实验里量化过这笔账:同一个持续学习场景跑 6 轮,增量方式总共只处理了 **6,012 行**,全量重训要处理 **21,000 行**——而且差距随轮数**二次增长**(数据越积越多,全量越来越贵,增量始终只看本轮变化)。

## 训练完,再 pin 一个

```sql
CREATE SNAPSHOT train_v2 FOR TABLE mltrain_demo samples;
INSERT INTO model_registry VALUES ('m2', 'train_v2', 0.9145);
```

于是注册表里积累出一条**模型↔数据的对应链**:

```
m1 ← train_v1 (100,000 行)
m2 ← train_v2 (103,000 行) = train_v1 + 3000 新增 + 200 修正
```

这条链解锁了几个平时做不到的动作:

- **精确复现**:三个月后审计问"m1 是用什么训的",`{snapshot='train_v1'}` 一查便知,逐位一致;
- **归因调试**:m2 比 m1 差了?两个快照之间 DIFF 一下,可疑变更就是那 3200 行,而不是大海捞针;
- **数据回退**:发现修正的标签本身是错的,`RESTORE` 回 train_v1,重新来过。

---

## 模式总结

这一篇的全部内容,其实是一个三步循环:

```
①  CREATE SNAPSHOT train_vN          -- 训练前,钉住数据
②  训练 → 注册 (model, train_vN)      -- 模型与数据版本绑定
③  下轮: DIFF 现状 AGAINST train_vN   -- 增量 = 确切的变更行 → partial_fit
```

成本侧:快照毫秒级与数据量无关(第三篇的原理),DIFF 只随变更量走。也就是说,**这个循环跑得越久、数据越大,相对全量重训省得越多**。

下一篇换到 LLM 的语境:**SFT 数据策展**——去重、过滤、去污染都用 SQL 原地完成,而且每一刀都有 DIFF 作为"收据"。

> 📎 可运行 SQL:[github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ 源码与社区:[github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)

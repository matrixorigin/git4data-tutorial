# MatrixOne Git4Data 技术详解（十）：标注协作——分歧即冲突，裁决有章法

标注是训练数据生产里**人最多**的环节,也是版本问题最密集的环节:几位标注员同时往一份数据上写标签,谁覆盖了谁?两个人对同一条样本意见相反,听谁的?质检要求重叠标注算一致率,怎么算?

这些问题在标注平台里要靠一堆应用逻辑来管。而 git4data 给了一个更底层的视角:**标注就是对数据的并行修改,标注分歧就是合并冲突**——版本控制天生就是处理这件事的。

> 📦 本文 SQL 整体可跑:[matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) 的 `10-labeling-collab/`。

---

## 每个标注员一条分支

一万条待标样本。Alice 负责 1–5000,Bob 负责 5001–10000,另外**两人都标 4901–5100**——这 200 条重叠是故意的,标注行业的标准做法,用来度量标注一致率:

```sql
CREATE SNAPSHOT before_labeling FOR TABLE label_demo samples;   -- 随时可重来

DATA BRANCH CREATE TABLE samples_alice FROM samples;
DATA BRANCH CREATE TABLE samples_bob   FROM samples;

-- 两人各自在自己的分支上打标(互不可见、互不干扰)
UPDATE samples_alice SET label = ... WHERE id BETWEEN 1 AND 5100;
UPDATE samples_bob   SET label = ... WHERE id BETWEEN 4901 AND 10000;
```

## 合并之前:一致率就是一个 JOIN

分支不是什么特殊对象,就是表。所以"两位标注员在重叠区标得是否一致"——直接 JOIN:

```sql
SELECT COUNT(*) AS qc_disagreements
FROM samples_alice a JOIN samples_bob b ON a.id = b.id
WHERE a.id BETWEEN 4901 AND 5100 AND a.label <> b.label;
```

分歧清单存进评审队列,留给资深评审员定夺:

```sql
CREATE TABLE review_queue AS
SELECT a.id, a.label AS alice_label, b.label AS bob_label
FROM samples_alice a JOIN samples_bob b ON a.id = b.id
WHERE a.id BETWEEN 4901 AND 5100 AND a.label <> b.label;
```

这一步很能说明 git4data 的特质:**版本之间可以直接互相计算**(第一篇说的"版本之上直接算")。在文件式的标注流程里,这需要导出两份结果再写脚本比对;在这里是一条 SQL。

## 合并:分歧自动浮出水面

```sql
DATA BRANCH MERGE samples_alice INTO samples;          -- Alice 先合,干净
DATA BRANCH MERGE samples_bob INTO samples WHEN CONFLICT SKIP;
-- Bob 的分支恰好在"两人标得不一样"的那些行上撞车——SKIP 先保留 Alice 的,
-- 其余几千行 Bob 的标注全部自动合入
```

注意这个对应关系:**真冲突的行 = 两人意见相反的行**,不多不少。意见一致的重叠行(改动相同)在 diff 聚合里直接抵消,根本不算冲突——第三篇讲的机制在这里严丝合缝地接住了业务语义。

## 评审裁决:cherry-pick 精确落地

评审员在分支上对争议行改判(本例采纳 Bob),然后**只把这些行**挑回主线——其余数据纹丝不动:

```sql
DATA BRANCH CREATE TABLE samples_review FROM samples;
UPDATE samples_review r SET label = (
  SELECT q.bob_label FROM review_queue q WHERE q.id = r.id
) WHERE r.id IN (SELECT id FROM review_queue);

DATA BRANCH PICK samples_review INTO samples
  KEYS (SELECT id FROM review_queue)
  WHEN CONFLICT ACCEPT;
```

`PICK ... KEYS(子查询)` 是这一篇的主角:裁决范围由 SQL 精确圈定,**改判多少行就动多少行**。

## 收尾:整个战役有账可查

```sql
-- 这次标注战役总共改了什么?
DATA BRANCH DIFF samples AGAINST samples {SNAPSHOT='before_labeling'} OUTPUT SUMMARY;

-- 整个战役需要推倒重来?一条语句:
-- RESTORE TABLE label_demo.samples {SNAPSHOT = before_labeling};
```

---

## 结语

把标注映射到版本控制之后,那些靠应用逻辑硬管的问题都有了结构性答案:**并行 = 分支,覆盖 = 合并顺序,分歧 = 冲突,裁决 = SKIP/ACCEPT/PICK,一致率 = 跨分支 JOIN,重来 = RESTORE。** 标注平台当然还有它的价值(界面、任务分发、计件),但数据底座上的版本语义,数据库直接给了。

下一篇沿着标注再往下游走一步:**RLHF 偏好数据**——三个标注员投票、SQL 算共识、争议对改判后 cherry-pick 进训练集,奖励模型的每一版数据都可复现。

> 📎 可运行 SQL:[github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ 源码与社区:[github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)

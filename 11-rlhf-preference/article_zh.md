# MatrixOne Git4Data 技术详解（十一）：RLHF 偏好数据——共识、改判与可复现

RLHF/DPO 的原料是**偏好数据**:同一个 prompt 配两个回答 A 和 B,标注员选哪个更好。这种数据有个特殊的麻烦——**它本质上是主观判断**。三个人看同一对回答,经常 2:1 甚至各执一词;隔几周复审,改判也很正常。

于是偏好数据集永远处在流动中:共识在变、争议在裁、版本在长。而奖励模型对数据极其敏感——**训 RM1 和 RM2 的偏好集差了哪 200 对,直接决定两版模型的行为差异**。这正是版本控制的主场。

> 📦 本文 SQL 整体可跑:[matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) 的 `11-rlhf-preference/`。

---

## 投票表 → 共识表,一条 SQL

一万个 prompt 对,三位标注员各投了一票(A 或 B)。共识就是按对分组数票:

```sql
CREATE TABLE preferences (pair_id BIGINT PRIMARY KEY, preferred VARCHAR(1), agreement INT);

INSERT INTO preferences
SELECT pair_id,
       CASE WHEN SUM(CASE WHEN choice='A' THEN 1 ELSE 0 END) >= 2 THEN 'A' ELSE 'B' END,
       CASE WHEN SUM(CASE WHEN choice='A' THEN 1 ELSE 0 END) IN (0,3) THEN 3 ELSE 2 END
FROM votes GROUP BY pair_id;

SELECT agreement, COUNT(*) FROM preferences GROUP BY agreement ORDER BY agreement DESC;
--   agreement=3(全票一致) vs agreement=2(2:1 分裂)——后者就是"心虚"的那部分
```

把共识表钉成第一版,奖励模型 RM1 就训在它上面:

```sql
CREATE SNAPSHOT pref_v1 FOR TABLE rlhf_demo preferences;
```

## 改判:动多少,挑多少

资深评审员复审 2:1 的争议对,在分支上改判其中 200 对:

```sql
DATA BRANCH CREATE TABLE preferences_review FROM preferences;

UPDATE preferences_review
SET preferred = CASE preferred WHEN 'A' THEN 'B' ELSE 'A' END, agreement = 3
WHERE agreement = 2 AND pair_id BETWEEN 2000 AND 2199;
```

然后是关键一步——**只把这 200 对改判挑回主线**,其余 9800 对一根毫毛不动:

```sql
DATA BRANCH PICK preferences_review INTO preferences
  KEYS (SELECT pair_id FROM preferences_review
        WHERE agreement = 3 AND pair_id BETWEEN 2000 AND 2199)
  WHEN CONFLICT ACCEPT;
```

这就是 cherry-pick 在数据上的样子:改判的范围由 KEYS 子查询**精确圈定**,不存在"顺手把别的也带进去"。

## 版本链:RM1 与 RM2 之间差的不是"感觉"

```sql
DATA BRANCH DIFF preferences AGAINST preferences {SNAPSHOT='pref_v1'} OUTPUT SUMMARY;
--   UPDATED = 200   ← v2 相对 v1 的全部差异,一对不多

CREATE SNAPSHOT pref_v2 FOR TABLE rlhf_demo preferences;
```

现在两版奖励模型的数据谱系完全清晰:

```
RM1 ← pref_v1
RM2 ← pref_v2 = pref_v1 + 恰好 200 对改判
```

如果 RM2 的行为变了,你知道**唯一的变量就是那 200 对**——可以逐对审看,而不是对着两个几 GB 的 JSONL 文件挠头。任何一版都随时可逐位复现(`{snapshot='pref_v1'}`),论文复现、合规审计、回归调试,同一条 SQL 全部覆盖。

---

## 偏好数据的完整工作流

把训练主题这四篇串起来,LLM 数据侧的版本闭环是这样的:

```
SFT 策展(第九篇)        快照=策展版本,DIFF=收据
   ↓
标注协作(第十篇)        分支=标注员,冲突=分歧,PICK=裁决
   ↓
偏好共识(本篇)          SQL 数票,PICK 改判,快照=RM 训练版本
   ↓
持续学习(第八篇)        DIFF 取增量,注册表绑定 模型↔数据版本
```

四个环节用的是同一套原语——这正是把训练数据放进"会版本控制的数据库"的复利:**学一次,处处可用。**

下一篇是训练主题的收官,也是系列里第一次"组合作战":**多模态训练集**——图像字节归 lakeFS,目录与标注归 MatrixOne,两个版本世界怎么缝成一个可复现的整体。

> 📎 可运行 SQL:[github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ 源码与社区:[github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)

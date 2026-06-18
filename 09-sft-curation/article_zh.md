# MatrixOne Git4Data 技术详解（九）：SFT 数据策展——每一刀都有收据

LLM 圈有句共识:**模型的上限是数据定的,数据的上限是策展定的。** SFT(监督微调)尤其如此——几十万条指令数据,真正决定效果的,是去重去得干不干净、低质过滤狠不狠、有没有把评测集泄漏进训练集。

但策展的日常工具链很尴尬:JSONL 文件 + 一堆 pandas 脚本。每过一道工序就落一个新文件——`sft_v3_dedup_filtered_final.jsonl`——三周后没人说得清:v3 和 v2 之间删了什么?为什么删?能不能撤销?

把数据放进 git4data,这三个问题各自变成一条 SQL。

> 📦 本文 SQL 整体可跑:[matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) 的 `09-sft-curation/`。

---

## 动刀之前,先钉住原始池

10 万条原始 SFT 样本(指令、回复、质量分、来源),带着真实数据的全部毛病:约 20% 指令重复、质量分参差、还混进了 300 条评测集的 prompt:

```sql
CREATE SNAPSHOT sft_raw FOR TABLE sft_demo sft_samples;
```

毫秒级。从此无论后面删得多狠,原始池永远一条 SQL 可回。**这一下,策展从"不可逆的破坏性操作"变成了"随时可悔棋的实验"。**

## 三刀,全在原地

不导出、不落中间文件,SQL 直接在表上做:

```sql
-- 第一刀:去重——同一条指令只留最早的一条
DELETE FROM sft_samples
WHERE id NOT IN (
  SELECT * FROM (SELECT MIN(id) FROM sft_samples GROUP BY instruction) keep
);

-- 第二刀:质量地板——低于 3.0 分的全部出局
DELETE FROM sft_samples WHERE quality < 3.0;

-- 第三刀:去污染——和评测集重叠的指令,一条不留
DELETE FROM sft_samples
WHERE instruction IN (SELECT instruction FROM eval_set);
```

第三刀值得多说一句:**评测集泄漏**是 SFT 最隐蔽的事故——分数虚高,上线见光死。当评测集就是库里的一张表时,去污染就是一个 `IN` 子查询,而且每次策展都能例行执行。

## 收据:这版到底删了什么?

策展完,问那个文件流程答不上来的问题:

```sql
DATA BRANCH DIFF sft_samples AGAINST sft_samples {SNAPSHOT='sft_raw'} OUTPUT SUMMARY;
--   DELETED = 本次策展删掉的确切行数
```

`OUTPUT LIMIT` 能逐行看被删的内容——**每一刀都有据可查**。这就是"收据"的含义:策展不再是黑箱,评审同事可以逐行 review 你删了什么,就像 review 一个 PR。

确认无误,把策展结果钉成训练版本:

```sql
CREATE SNAPSHOT sft_v1 FOR TABLE sft_demo sft_samples;
-- 这次 SFT 训练用的就是 sft_v1——和第八篇的模型注册表配合,版本闭环
```

删过头了?一条语句回到原始池重来:

```sql
RESTORE TABLE sft_demo.sft_samples {SNAPSHOT = sft_raw};
```

---

## 文件流程 vs git4data 流程

| | JSONL + 脚本 | git4data |
|---|---|---|
| 每道工序 | 落一个新文件 | 原地 SQL |
| "删了什么" | 肉眼比对两个大文件 | `DIFF ... OUTPUT SUMMARY/LIMIT` |
| 撤销一刀 | 找上一个文件(如果还在) | `RESTORE {SNAPSHOT}` |
| 版本管理 | 文件名命名学 | 命名快照 |
| 复现某次训练 | 祈祷文件没被覆盖 | `{snapshot='sft_v1'}` |

配套实验里量化过一组数:同样一份 8000 条的策展(去重+过滤+去污染),原地 SQL 全程 **410 毫秒**,DIFF 溯源出 DELETED=4836——每一条都点得出名字。

---

## 结语

SFT 策展的本质是**做减法**,而减法最怕的就是"减错了说不清、想撤撤不回"。快照给了悔棋,DIFF 给了收据,原地 SQL 省掉了文件搬运——三件事合起来,策展变成一个可审计、可迭代、可协作的工程活动。

说到协作——下一篇正面处理策展里"人最多"的环节:**标注协作**。多个标注员同时打标,意见不一致怎么办?剧透:分歧本身,就是 merge 冲突。

> 📎 可运行 SQL:[github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ 源码与社区:[github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)

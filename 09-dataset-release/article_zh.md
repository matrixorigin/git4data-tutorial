# MatrixOne Git4Data 技术详解（九）·AI 训练实践篇：数据集发布与泄漏——别让离线指标骗了你

在机器学习里，一个模型上线前值不值得信，几乎全靠**离线评估**来回答：这一版比上一版好吗？这个特征有没有用？阈值调到多少合适？能不能上线？——所有这些决定，背后都是同一件事：在一批模型**没见过**的数据上，量出它真实的表现。

而“没见过”这三个字，全靠数据集切分来保证。训练前，我们把数据分成三份各司其职的集合：**训练集（train）**拟合模型参数，**验证集（valid）**用来选特征、调超参、比候选模型，**测试集（test）**在方案锁定后给出一次尽量无偏的最终估计。这三份怎么切、边界画在哪，直接决定了后面每一个指标能不能信。

问题是，这一步偏偏常常是整个流程里最被随手对待的一环——一句 `train_test_split(random_state=42)` 就翻篇了。于是有了下面这个很多机器学习工程师都经历过的场景。

离线评估 AUC 0.94，兴冲冲上线，一周后线上表现掉到 0.78。回头排查：模型没动、特征没动、代码没改——问题出在最不起眼的那一步，训练集和测试集是怎么切的。

当初切分用的是一句随手的 `train_test_split(random_state=42)`：同一个用户的多笔交易被随机分到了 train 和 test，模型其实“见过”测试集里的人；标准化又是在切分之前对全量数据做的，均值和方差早偷看了测试集。更麻烦的是，那份切出 0.94 的数据集现在**复现不出来了**——当时的 notebook 早关了，`samples` 表这一周又新增、修正了几千行，同样的 `random_state=42` 作用在一张已经变了的表上，切出来的根本不是同一批行。

离线指标是模型上线前唯一的“体检报告”。**切分错了，这份报告就是假的**——它不会报错，只会给你一个好看的数字，然后在生产环境里翻车。

这一篇就讲这一步：为什么训练 / 验证 / 测试的切分不是一句 `ORDER BY RAND()`，而是决定离线评估可不可信的关键一步；以及怎么用 MatrixOne 的 Git4Data 能力，把它做成可复现、可审计、可回退的版本化对象。

> 本篇承接上一篇[《AI 训练实践篇·总览》](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part8-ml-lifecycle-zh/index.md)第四站，沿用同一个风控案例往深里钻。仍然聚焦基于结构化数据的传统机器学习。文中 SQL 全部在 MatrixOne `4.1.0` 上实测，可跑版本见 [matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) 的 `09-dataset-release/`。

---

## 一次切分，其实同时定义了三件事

“把数据切成 train / valid / test”听起来是一个动作，其实它同时定义了三件事：

1. **谁属于哪一集（membership）**——每一条样本，是训练、验证还是测试；
2. **按什么规则切（rule）**——时间截点？实体哈希？随机种子？去重键？
3. **切在哪一版数据上（version）**——这份切分，作用在“哪一个时刻的 `samples`”上。

大多数团队只版本化了第 2 条里的一小部分——代码里的 `random_state`——却几乎从不版本化第 1 条和第 3 条。于是“可复现的切分”成了一句空话：只要底层表动过，同一个种子切出来的就是另一批行；而“哪一条样本当时属于哪一集”这个最关键的事实，根本没被任何东西记住。

真正要冻结的，是 **membership + 规则 + 它作用的那一版数据**，三者一起。这恰好是 Git4Data 能钉住的东西。下面先把切分做错，看看错在哪；再把这三样一起钉稳。

---

## 五类泄漏，逐个上手

这里的“泄漏（leakage）”是机器学习里的专门术语，**指训练时用到了上线时根本拿不到的信息**——它和“数据被泄露出去”那种安全意义上的数据外泄（data breach）完全是两回事，说的是训练数据里混进了本不该被模型提前看到的信息。它的典型症状就是开头那一幕——离线虚高、上线滑坡。先把案例的数据准备出来。

相比总览，这里给 `samples` 加了三列做泄漏检测必需的键：`user_id`（实体键，同一个人有多笔交易）、`event_key`（去重键，同一底层事件及其增强副本）、`label_time`（真值何时可知，晚于事件时间）。

```sql
CREATE TABLE samples (
    sample_id    BIGINT PRIMARY KEY,
    event_time   DATETIME,       -- 交易发生时间，也是特征截点
    user_id      BIGINT,         -- 实体键：同一个人可能有多笔
    event_key    VARCHAR(64),    -- 去重键：同一笔底层事件 / 其增强副本
    amount       DECIMAL(12,2),
    txn_count_7d INT,
    label        TINYINT,        -- 0=正常, 1=欺诈, NULL=真值未到
    label_time   DATETIME,       -- 标签何时可知（晚于 event_time）
    label_source VARCHAR(32)
);
```

案例数据：10 万笔交易、2 万个用户（人均约 5 笔），时间跨度 121 天（`2026-03-01` 到 `2026-06-29`），欺诈真值在事件 3 天后回来。再加 2000 条**增强近重复**样本，和原始样本共享同一个 `event_key`。以“现在是 `2026-07-01`”为界，`label_time` 还没到的最近样本，真值尚未回来。实测共 **102,000** 行，其中 **101,158** 行有标签、**842** 行是“真值未回”的最近样本。

### 先看反面教材：一次朴素的随机切分

```sql
-- 一个不看时间、也不看实体的切分。这里用 sample_id 的确定性哈希做分桶
-- （复跑结果一致），它打散数据的方式和随手一个随机切分完全一样。
INSERT INTO membership_rand
SELECT sample_id,
       CASE WHEN CONV(SUBSTR(MD5(CAST(sample_id AS CHAR)),1,8),16,10) % 10 < 8 THEN 'train'
            WHEN CONV(SUBSTR(MD5(CAST(sample_id AS CHAR)),1,8),16,10) % 10 = 8 THEN 'valid'
            ELSE 'test' END
FROM samples
WHERE label IS NOT NULL;
--   实测 train 80893 / valid 10229 / test 10036，比例看着很正常。
```

比例没问题，但下面三条检测器会让它原形毕露。

### 泄漏一：时间泄漏（把未来喂给了过去）

风控、推荐、风险这类业务有强时间性：你要用**过去**预测**未来**。随机切分却把不同时间的样本打散，`train` 里混进了比 `test` 更晚的交易——相当于让模型提前看了未来。

```sql
-- train 里有多少样本，比 test 最早的那条还晚？
SELECT COUNT(*) AS train_rows_from_the_future
FROM samples s JOIN membership_rand m ON s.sample_id = m.sample_id
WHERE m.split_name = 'train'
  AND s.event_time > (SELECT MIN(s2.event_time)
                      FROM samples s2 JOIN membership_rand m2 ON s2.sample_id = m2.sample_id
                      WHERE m2.split_name = 'test');
--   实测 80205。train 的 8 万行里几乎全都晚于 test 的起点——彻底穿越。
```

这里要分清两件常被混为一谈的事。**特征**必须在每条样本自己的特征截点（`event_time`）就能算出来——把“这笔后来被拒付了”这种**结果**当成特征喂进去，就是典型的泄漏（它正是上线当下拿不到的）。而**标签**本来就允许晚到：`label_time` 比 `event_time` 晚几天是正常的，要求的不是“标签在 `event_time` 已知”，而是“标签在本轮训练所用的 as-of 截点（这里是 `2026-07-01`）之前已经回流”。所以门禁检查的正是后者——真值还没回来的样本，本轮先不进任何集合（前面那 842 行就是这么被排除的）。

### 泄漏二：实体泄漏（同一个人跨集）

同一个 `user_id` 的多笔交易被逐行随机切分，一部分进 train、一部分进 test。模型于是学到了“这个人”，而不是“这类行为”。离线看着很准，一上线遇到全新用户就崩。

```sql
-- 有多少用户同时出现在 train 和 test？
SELECT COUNT(*) AS users_in_train_and_test FROM (
  SELECT s.user_id
  FROM samples s JOIN membership_rand m ON s.sample_id = m.sample_id
  WHERE m.split_name IN ('train', 'test')
  GROUP BY s.user_id
  HAVING COUNT(DISTINCT m.split_name) = 2
) t;
--   实测 8213。两万用户里超四成横跨 train 和 test。
```

### 泄漏三：重复 / 增强泄漏（同一事件被拆开）

同一笔底层事件的重复记录、或数据增强产生的近重复样本，被随机拆到不同集合。测试集里于是躺着训练集样本的“双胞胎”。

```sql
-- 有多少 event_key 被切到了不止一个集合？
SELECT COUNT(*) AS event_keys_across_splits FROM (
  SELECT s.event_key
  FROM samples s JOIN membership_rand m ON s.sample_id = m.sample_id
  GROUP BY s.event_key
  HAVING COUNT(DISTINCT m.split_name) > 1
) t;
--   实测 677。那 2000 条增强样本，有 677 组和它们的原件分了家。
```

一次随机切分，三条检测器全部亮红。而这三条，都是**能用 SQL 在切分清单上直接查出来**的结构性泄漏。还有两类泄漏不在 membership 里，但同样致命。

### 泄漏四：预处理泄漏（统计量偷看了验证 / 测试集）

在**全量**数据上先做标准化、目标编码、缺失值拟合，再切分——预处理器的均值、方差、类别频率里，已经含了验证集和测试集的信息。正确顺序是反过来的：**只在 train 上 `fit`，再原样 `transform` 到 valid 和 test**。

这一步不是 membership 能查的，是流程纪律。但版本化切分能给它一个可靠前提：因为 train 是从一个**确定的快照**、按 `split_name='train'` 读出来的，你能保证“预处理器 fit 用的就是 train 这批行、而且这批行日后可逐位复现”，而不是某次 notebook 里飘忽的一个子集。

### 泄漏五：目标泄漏（特征里混进了答案）

特征里混进了与标签强相关、但上线时拿不到的字段。风控里最典型的就是拿“是否已拒付 / 人工审核结论”去预测欺诈——这些是**结果**，不是**事前特征**。症状是某个特征重要性高得离谱、离线 AUC 好得不真实。

它同样超出 membership 的范围，属于特征来源审计。但这正是[第七篇 Write-Audit-Publish](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part7-write-audit-publish-zh/index.md) 的用武之地：某个“好得可疑”的特征列是什么时候、由谁加进主表的，配合 `DATA BRANCH DIFF` 一查便知，而不是靠回忆。

---

## 把切分改对：时间切分，再让检测器归零

对这个风控案例，正确的主切分方式是**按时间切**——训练用早期数据，验证和测试用后面的时间窗口，模拟“用过去预测未来”。切分规则连同时间截点一起，显式写进 `dataset_membership`。

```sql
INSERT INTO dataset_membership
SELECT sample_id,
       CASE WHEN event_time <  '2026-06-05' THEN 'train'
            WHEN event_time <  '2026-06-17' THEN 'valid'
            ELSE 'test' END,
       'time_split:v1 cutoffs=2026-06-05/2026-06-17; feature_cutoff=event_time; label_ready<=2026-07-01'
FROM samples
WHERE label IS NOT NULL;          -- “真值未回”的最近样本，本轮先不进任何集合
--   实测 train 80950 / valid 10104 / test 10104，约 80 / 10 / 10。
```

注意两件事：切分规则里**存下了时间截点、特征截点和标签可用条件**，不只是 train/valid/test 三个词；而“真值未回”的 842 行被显式排除，不会因为“凑数”混进训练。

现在把前面那两条结构性检测器重新跑一遍：

```sql
-- 时间泄漏：归零
--   train_rows_from_the_future = 0    （train 全部早于 test 的起点）
-- 重复泄漏：归零
--   event_keys_across_splits    = 0   （同 event_key 共享 event_time，天然落进同一集）
```

时间切分把“时间”和“重复”两类泄漏一起解决了。但**实体重叠这条，诚实地说，并没有归零**：

```sql
-- 时间切分下，仍有多少用户跨 train 和 test？
--   users_in_train_and_test = 9912
```

这不是 bug，而是一个要讲清楚的取舍。按时间切分时，一个“回头客”早期的交易在 train、后期的交易在 test，本来就会横跨边界。**对风控这种业务，这恰恰是真实的**——线上你就是会反复遇到老用户，让模型见过他们的历史并不算作弊。所以这里的正确做法不是消灭它，而是**报告并接受它**。

只有当任务本身要求“实体不相交”时（比如按用户做留一评估、或严禁模型记住个体），才改用**按实体哈希**切分：让同一个用户的所有行整体落进同一集。

```sql
INSERT INTO membership_entity
SELECT sample_id,
       CASE WHEN user_id % 10 < 8 THEN 'train'
            WHEN user_id % 10 = 8 THEN 'valid'
            ELSE 'test' END
FROM samples WHERE label IS NOT NULL;
--   此时 users_in_train_and_test = 0，但代价是牺牲了严格的时间顺序。
```

**时间切分**和**实体切分**往往不能兼得，选哪个取决于你的业务里“未来会不会遇到老用户”。Git4Data 不替你做这个判断——它保证的是：无论你选哪种规则，这份 membership 都会被完整、可复现地钉住，而且发布前能被逐条审计。

---

## 发布前的审计门：一份全是 SQL 的切分 checklist

[第七篇的 Write-Audit-Publish](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part7-write-audit-publish-zh/index.md) 是把坏数据挡在生产门外；同样的思路可以直接套在**切分**上：切分清单先在工作区里过一遍审计，全绿了才发布成一个命名版本。审计项每一条都是 SQL，每一条都必须通过：

```sql
-- ① 时间单调：train 不得晚于 test 起点        → 期望 0
-- ② 实体重叠：按业务要求，为 0 或“已知可接受值”  → 记录在案
-- ③ 重复不跨集：同 event_key 只在一个集合        → 期望 0
-- ④ 标签不来自未来：labeled 行的 label_time ≤ 截点 → 期望 0
SELECT COUNT(*) AS label_from_future
FROM samples s JOIN dataset_membership m ON s.sample_id = m.sample_id
WHERE s.label IS NOT NULL AND s.label_time > '2026-07-01';   -- 实测 0

-- ⑤ 三集规模与占比在合理带内（防呆：空集 / 比例失衡）
SELECT m.split_name, COUNT(*) AS n,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM dataset_membership), 1) AS pct
FROM dataset_membership m GROUP BY m.split_name;
--   实测 train 80.0% / valid 10.0% / test 10.0%

-- ⑥ 每个集合都要有正样本（防呆：某一集没有欺诈样本，指标没意义）
SELECT m.split_name, AVG(s.label) AS pos_rate
FROM samples s JOIN dataset_membership m ON s.sample_id = m.sample_id
GROUP BY m.split_name;
--   实测三集 pos_rate 均为 0.5，均衡
```

再加一条流程约定（第 4 类泄漏）：**预处理器只在 `train` 上 `fit`**。全部通过，才进入发布。任何一条亮红，就回到 `dataset_membership` 修规则，主线一行不动。

---

## 发布：把样本和切分冻结成同一个版本

样本内容和切分清单必须作为**一个整体**发布——给两张表分别打快照，可能落在不同时刻，对不齐。这里用库级快照，一次冻结整个 `risk_ml`：

```sql
CREATE SNAPSHOT risk_dataset_v1 FOR DATABASE risk_ml;
```

![数据集发布：一次库级快照同时冻结 samples 与 dataset_membership，train/valid/test 三个集合在同一版本里一致发布，按时间切分并通过审计门](./images/fig_split-release_zh.svg)

之后训练、调参、最终测试，都从**同一个数据集版本**读取，只改 `split_name`：

```sql
-- 训练器读 train（验证 / 测试同理，只换 split_name）
SELECT s.*
FROM samples {SNAPSHOT='risk_dataset_v1'} s
JOIN dataset_membership {SNAPSHOT='risk_dataset_v1'} m ON s.sample_id = m.sample_id
WHERE m.split_name = 'train';
--   实测 train 80950 行。
```

这条库级快照不是物理复制整个库，而是给当时各表的一致状态建立一个命名版本——[第三篇](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part3-under-the-hood-zh/index.md)讲过，MatrixOne 的不可变对象加元数据目录，让快照成本几乎与数据量无关。至此，可复现的不只是“有哪些样本”，还包括“每条样本在这次实验里扮演什么角色”。三个月后要复现，`SELECT ... {SNAPSHOT='risk_dataset_v1'}` 一句话，逐位一致。

---

## 版本演进：区分“尺子变了”还是“模型变了”

后来发现测试集缺少一批困难样本，要把 500 条挪进 test。正确做法不是覆盖 v1，而是发布 `risk_dataset_v2`，并让新指标明确绑定 v2：

```sql
UPDATE dataset_membership SET split_name = 'test',
       split_rule = 'time_split:v2 + 500 hard cases moved to test'
WHERE sample_id IN (SELECT sample_id FROM dataset_membership WHERE split_name = 'train' LIMIT 500);

-- 相对已发布的 v1，切分到底动了什么？
DATA BRANCH DIFF dataset_membership
  AGAINST dataset_membership {SNAPSHOT='risk_dataset_v1'} OUTPUT SUMMARY;
--   实测 UPDATED = 500（INSERTED 0 / DELETED 0）——正好是挪动的那 500 条。

CREATE SNAPSHOT risk_dataset_v2 FOR DATABASE risk_ml;
```

这一条 DIFF 能把一个总被含糊带过的问题说清楚：模型指标变了，到底是**模型变了**还是**尺子变了**？如果 test 的成员、标签或评估协议动过，v2 的分数仍然有效，但它已经不是和 v1 完全同口径的直接对比。所以跨版本的趋势，应该优先在**没变过的固定测试集 / golden set** 上比，同时把新的时间窗口作为另一条独立指标报告。这里要和开头的原则对齐：**特征、超参、模型的选择只看验证集**；每轮都在变的这个 test，本质上是一个**跨版本的滚动评估窗口**——用来观察新时间段的表现，而不是那把“锁定后只测一次”的无偏尺子；真正无偏的最终回归，落在下一节那种**长期不变的固定 holdout / golden set** 上。而 v1 始终原样可查、可回退：

```sql
-- 各自在自己的语句里查（每个快照一条语句）
SELECT split_name, COUNT(*) FROM dataset_membership {SNAPSHOT='risk_dataset_v1'} GROUP BY split_name;
--   test 10104 / train 80950 / valid 10104   ← v1 逐位不变
SELECT split_name, COUNT(*) FROM dataset_membership {SNAPSHOT='risk_dataset_v2'} GROUP BY split_name;
--   test 10604 / train 80450 / valid 10104   ← v2 反映了挪动
```

映射到原语上，切分的整个生命周期非常自然：

```text
一次切分         = 一份 dataset_membership + 规则
把切分钉成版本   = snapshot（库级，连样本一起冻结）
读某一集         = SELECT … {SNAPSHOT} WHERE split_name = …
切分改了什么     = DATA BRANCH DIFF（尺子变了 vs 模型变了）
切分整轮作废     = RESTORE 回上一版
```

---

## golden set 的纪律

除了随每轮迭代变化的 test，很多团队还会维护一份长期稳定的 **golden evaluation set**：覆盖关键人群、罕见风险和业务底线，专门用于跨模型版本的回归。它的价值全在“稳定”二字——**永不回训、尽量不变**。

用快照管它最合适：golden set 钉成一个长期保留的命名版本，内容可复现、被改动能被发现（可追溯、防篡改）。要说清楚的是，快照本身只解决“可追溯”——它并不能阻止有读权限的人把它查出来、拿去训练；真要防止误用，还得靠权限隔离和训练流水线的审计来配合。真到了必须更新的那天（比如补充新型欺诈手法），那就是一次显式的 `golden_v2` 发布 + 重建基线，而不是在原地悄悄改几行——否则你会发现“模型在 golden set 上涨了 2 个点”，其实是 golden set 自己变松了。发布前，同样用一条 DIFF 确认它没有和当前 train 产生交集。

---

## 行业里的其他做法：切分与泄漏，业内还有哪些方案

先说清楚：把“数据集这一版”钉住、可回到，业内已有不少成熟方案，各有各的强项。这里不是要否定它们，而是想指出一个常被忽略的差别——**“某条样本属于 train / valid / test”这份 membership，是不是作为一等的关系数据，和样本放在同一个库里、用同一个快照一起冻结、并且能直接用 SQL 审计泄漏。** 用这把尺子逐个看：

**notebook 随机切分（`train_test_split`）。** membership 藏在代码的 `random_state` 里，根本不是一份可查询的数据，也不和数据版本绑定。开头翻车的就是它。

**存一列 `split` / 每次重跑切分 SQL。** membership 成了表里的一列，比前者好；但它不会和样本一起被冻进某个版本，重跑在变了的表上就变了。

**数据 / 数据集版本工具（DVC、lakeFS、Delta Lake）。** 这几种都能把“数据集这一版”钉住、可回到，这是它们的共同强项，而且各有亮点：**lakeFS 在对象存储上提供 git 式的 zero-copy 分支**（并不是每个版本都复制一份数据）；**Delta Lake 的 Change Data Feed 能给出版本间的行级 insert / update / delete**；DVC 则是文件级的版本化。它们解决的是“数据 / 文件版本”这一层；而“哪条样本属于哪一集”是一个建模概念，通常要你在其上再建一层，泄漏检查（同一 user 是否跨集、event_key 是否跨集）也要把数据读出来另做。

**特征平台（Feast、Tecton）。** 强项是 **point-in-time 正确性**——按事件时间做特征关联，很好地防住“未来特征”这一类时间泄漏，值得肯定。它们聚焦特征，切分 membership 的治理通常在平台之外。

**实验跟踪（MLflow、W&B）。** 也能记录数据：**MLflow 的 `mlflow.data` 会记下 dataset 的来源与 digest（内容指纹）**，**W&B 的 Artifact 是带版本和血缘的**。它们很好地解决了“这次 run 用的是哪一份”的**追溯**问题；记录的是引用 + 指纹，而不是一张能直接和当前库 JOIN、对两版做行级 membership diff 的活表。

放进一张表里（据实标注各自的强项）：

| 方案 | membership 的形态 | 与样本同库、同快照冻结 | 行级看“谁在集合间移动” | 泄漏检查 |
|---|---|---|---|---|
| notebook 随机切分 | 代码里的 `random_state` | 否 | 否 | 靠自觉 |
| 存一列 / 重跑 SQL | 表里一列 | 否（不随版本冻结） | 否 | 自己写 SQL |
| DVC | 物化文件的版本 | 否（文件与活表分离） | 文件级 | 文件上的脚本 |
| lakeFS | 对象 / 路径版本（**zero-copy 分支**） | 否（对象与活表分离） | 对象 / 路径级 | 对象上的 hook / 脚本 |
| Delta Lake | 表版本 + **CDF** | 否（独立表 / 湖） | **行级（CDF）** | Spark / SQL（湖侧） |
| 特征平台（Feast/Tecton） | 训练集物化 | 部分 | 否 | **强于时间泄漏** |
| 实验跟踪（MLflow/W&B） | dataset digest / Artifact 版本 | 否 | 否（引用 + 指纹） | 另一套 |
| **MatrixOne（Git4Data 能力）** | **一张关系表 `dataset_membership`** | **是（同库、同一个快照）** | **是（`DATA BRANCH DIFF`）** | **同库 SQL，直接跑在版本化数据集上** |

所以 MatrixOne 的差异不在于“能不能版本化数据”——上面几种各有各的版本化能力，有的还很强。它的位置在于：**把切分 membership 当成一等的关系数据，和样本同库、用同一个快照一起冻结，让“同一 user 跨集”“event_key 跨集”“标签是否来自未来”这些泄漏检查，就是几条直接跑在版本化数据集上的 JOIN 与反连接；跨版本“谁在集合间移动”则是一条行级 `DATA BRANCH DIFF`。** 切分于是从流程里最没人管的一环，变成和数据同源、可查询、可审计的一等公民。

---

## 边界与适用范围

- **随机切分不是原罪**。如果数据本身独立同分布、既没有实体结构也没有时间结构（很多纯表格任务就是如此），随机切分完全够用。泄漏来自“数据有结构，切分却假装它没有”。

- **`random_state` 固定不了一切**。它只固定“怎么抽”，固定不了“从哪一版表抽”。底层表一变，同一个种子就是另一批行——所以真正的可复现，靠的是把数据版本一起钉住，而不只是记一个种子。

- **快照有保留成本**。被钉住的历史版本会占存储，直到 `DROP SNAPSHOT`。给每个上线模型对应的 `dataset_vN` 长期保留，给废弃的中间版本设清理策略。

- **行级操作要求 schema 一致**（[第四篇](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part4-landscape-zh/index.md)的边界）：给训练集加特征列，先在主线走受控的 schema 迁移，再继续。

---

## 结语

切分是离线评估的地基。`random_state` 给你的，是“看起来可复现”；真正可复现、可信的切分，是把 **membership、规则、数据版本**三者一起钉住，发布前逐条审计，出问题能回退。

MatrixOne 用 Git4Data 能力，把这三样一起放进数据库里——切分清单和样本、标签在同一个版本里一致发布，每一次改动都留下 DIFF 作为收据，每一个历史版本都能逐位复原。评估这份“体检报告”能不能信，从此有了确定的答案。

下一篇，我们离开结构化表格，进入大模型的语境：**SFT 数据策展**——几十万条指令数据的去重、过滤、去污染，怎么全用 SQL 原地完成，而且每一刀都有 DIFF 作为收据。

> 📎 可运行 SQL：[github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ 源码与社区：[github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)


---

## 参考资料

- scikit-learn — 数据泄漏与常见陷阱：<https://scikit-learn.org/stable/common_pitfalls.html#data-leakage>
- lakeFS — 零拷贝分支（zero-copy branching）：<https://docs.lakefs.io/understand/how/branches.html>
- Delta Lake — Change Data Feed（版本间行级变更）：<https://docs.delta.io/latest/delta-change-data-feed.html>
- MLflow — Dataset 追踪（`mlflow.data`）：<https://mlflow.org/docs/latest/tracking/data-api.html>
- Weights & Biases — Artifacts：<https://docs.wandb.ai/guides/artifacts>
- Feast — point-in-time joins：<https://docs.feast.dev/getting-started/concepts/point-in-time-joins>
- 本文配套可运行脚本（已在 MatrixOne 4.1.0 验证）：[`09-dataset-release/dataset_release_demo.sql`](https://github.com/matrixorigin/git4data-tutorial/blob/d47dc1b811a19bc1b278b29cdd8a9d1e07b7988a/09-dataset-release/dataset_release_demo.sql)

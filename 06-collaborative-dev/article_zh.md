# MatrixOne Git4Data 技术详解（六）·数据运维实践篇：数据协作开发——像合并代码一样合并数据

上一篇讲的是一个人出了事故怎么救。这一篇讲一件更日常、也更容易被低估的事：**一个团队，同时改同一份数据。**

但"数据协作"不是凭空冒出来的需求——它**总是伴随着某件具体的事**发生。所以这一篇我们不空谈"协作"，而是先把那些"事"摆出来：你大概率正在做、或下个月就要做其中之一。每个场景都从头跑一遍，SQL 全部在 MatrixOne `4.0.0-rc3` 上实测过。

> 📦 本文 SQL 整体可跑：[matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) 的 `06-collaborative-dev/`。环境：`docker run -d -p 6001:6001 --name matrixone matrixorigin/matrixone:4.0.0-rc3`。

---

## 你在干哪些事的时候，会撞上"数据协作"？

问题不是"要不要给数据搞协作"，而是——**只要你在做下面这些事，数据协作就已经发生了**，区别只在于你是用 Git 那套方法做、还是用"抢一张表 + 建一堆备份 + 群里喊话"那套老办法做：

- **备战一次大促 / 上一个运营活动**：运营、定价、类目几拨人，deadline 之前要在同一张商品表上同时改。
- **做一次跨系统迁移 / 字段重构**：把数据迁到一套新标准，是个跨周的工程，而生产这期间一刻不能停。
- **推进一次合规 / 数据质量整改**：多人分头清洗不同部分，但每一处改动都要负责人 review、签字、留痕才能上线。
- **多人配置一批规则 / 营销活动**：各配各的，统一发布前要有人把关。

这些事的共同点是同一句话：**多拨人、多条改动要同时往前推，最后还得安全地并到一起。** 下面用一张 10 万行的商品表 `products`，把前三件事完整走一遍——你会看到，它们用的其实是同一套动作：分支、自查、合并、裁决冲突。

---

## 活动一：备战大促——三个团队同时改一张商品表

> 距双十一还有两周。商品表 `products` 这两周要被三拨人同时改：**定价团队**给活动商品批量打活动价、**运营团队**给活动品补卖点文案、**类目团队**把一批停产品下架。三拨人、一张表、deadline 就在眼前。

没有版本控制时，这种局面只有两条难走的路：要么排期串行（一拨改完另一拨再上，两周根本不够），要么各自建 `products_backup_运营版` 这样的备份表、最后人肉对账合并（极易出错）。

git4data 的做法：固定一个全队共同的起点，三个团队各 fork 一条分支，**互相完全不可见、互相完全不影响地并行干**。

```sql
CREATE SNAPSHOT team_base FOR TABLE collab_demo products;   -- 全队的共同起点

DATA BRANCH CREATE TABLE products_pricing FROM products;    -- 定价团队
DATA BRANCH CREATE TABLE products_ops     FROM products;    -- 运营团队
DATA BRANCH CREATE TABLE products_catalog FROM products;    -- 类目团队
```

三条分支**瞬间就位**（第三篇讲过：分支只复制对象引用、不搬数据，毫秒级，10 万行和 6 亿行一样快）。从这一刻起，谁也不用问"这张表现在谁占着"。

![分支协作：三个团队从 team_base 各分一条分支并行改，改完各自合并回主线](./images/fig_branch-merge_zh.svg)

```sql
-- 定价团队：A 类活动品打 8 折（负责 1~30000 号段）
UPDATE products_pricing SET price = round(price * 0.80, 2)
WHERE category = 'A' AND product_id <= 30000;

-- 运营团队：给缺文案的活动品补卖点（负责 30001~60000 号段）
UPDATE products_ops SET descr = concat('SALE_', product_id)
WHERE descr IS NULL AND product_id BETWEEN 30001 AND 60000;

-- 类目团队：下架一批停产品（负责 90000~95000 号段）
UPDATE products_catalog SET status = 'retired'
WHERE product_id BETWEEN 90000 AND 95000;
```

> ⚠ **一个实操要点：分工按「行」切，不要按「列」切。** git4data 的冲突判定是**行级**的——哪怕定价改的是某商品的价格、运营改的是同一商品的文案，碰的是不同列，合并时也会算作冲突（我们写这篇时真踩到过这个坑）。所以让每个团队负责**不重叠的商品号段 / 类目**，就天然无冲突。

合并前，每个团队用 DIFF 给自己的改动做一次行级 self-review——相当于提 PR 前先看一眼自己的 diff：

```sql
DATA BRANCH DIFF products_pricing AGAINST products OUTPUT SUMMARY;
--   UPDATED = 我这次改了多少行？范围对不对？有没有误伤别人的号段？
```

确认无误，依次合并。因为号段不重叠，三条分支**以任意顺序合并都干净通过**，不需要任何协调：

```sql
DATA BRANCH MERGE products_pricing INTO products;
DATA BRANCH MERGE products_ops     INTO products;
DATA BRANCH MERGE products_catalog INTO products;
```

整个大促备战：**没有锁表、没有窗口期、没有"你等我先合"。** 三个团队真正并行冲刺到 deadline。

---

## 活动二：一次跨系统迁移——迁移在分支上慢慢做，店照常卖货

> 产品决定把商品的类目体系换成一套新标准。这不是几行 UPDATE，而是个要写转换逻辑、反复跑、还要 QA 验收的工程，前后好几天。最大的难点是：**这期间店还在正常营业**，`products` 表一刻不停地被下单读写。

传统做法都很难受：停服务迁移（业务不会答应）、CDC 双写 + 对账（复杂又易错）、或者让业务读到"迁了一半"的中间态（直接出乱子）。

git4data 的做法是开一条迁移分支，迁移团队在分支上慢慢做、QA 在分支上验，**主线零感知、照常卖货**：

```sql
DATA BRANCH CREATE TABLE products_migration FROM products;

-- 在分支上反复迭代你的迁移逻辑（几小时 / 几天都行）。
-- 这期间主线 products 照常被业务读写，完全不受影响。
UPDATE products_migration SET category = 'D' WHERE category = 'C';   -- 示意：旧类目 C → 新类目 D

-- 验收：切换前先 DIFF 确认改动范围正是预期（没有越界误伤）
DATA BRANCH DIFF products_migration AGAINST products OUTPUT SUMMARY;

-- 一切无误，一次性原子切换（合并是秒级的一步）
DATA BRANCH MERGE products_migration INTO products;
```

分支就是你的"施工围挡"：里面怎么折腾都行，外面的生意照做；拆围挡（合并）是**秒级**的一步，而不是一个漫长的、要全员盯着的切换窗口。万一切完才发现问题？还有 `RESTORE TABLE … {SNAPSHOT = team_base}` 兜底，一键回到迁移之前。

> 边界提醒：这套行级 diff/merge **要求两边 schema 一致**。如果你的迁移要动表结构（加列、改类型），顺序得是"**先在主线改 schema，再开分支做数据迁移**"，而不是在分支里改完结构再合（第四篇讲过这个边界）。

---

## 活动三：一次合规整改——分头清洗，但每一处改动都要签字

> 监管下来一纸整改要求，限一个月完成：脱敏历史遗留的明文信息、补全缺失的字段、清理过期数据。多个工程师分头干不同部分。但合规卡了一条死规矩：**任何对生产数据的改动，必须有负责人 review、留痕、签字，才允许上线。**

传统怎么满足这条？改完截图发群里让领导看一眼？还是改完口头通知一声？——既没法基于事实审查，也没法留下可追溯的痕迹。出了事，谁也说不清当时到底改了什么。

git4data 把每个工程师的改动，天然变成一个**可评审、可留痕的 PR**：人在分支上改，负责人把分支当 PR 来审。

```sql
-- 工程师：在分支上改，绝不直接碰生产表
DATA BRANCH CREATE TABLE products_review FROM products;
UPDATE products_review SET descr = 'REDACTED' WHERE product_id <= 2000;   -- 脱敏

-- 负责人 / 合规官 review：先看规模，再逐行看，最后导出补丁存档
DATA BRANCH DIFF products_review AGAINST products OUTPUT SUMMARY;   -- 改了多少、什么类型
DATA BRANCH DIFF products_review AGAINST products OUTPUT LIMIT 20;  -- 逐行看改成了什么
DATA BRANCH DIFF products_review AGAINST products OUTPUT FILE '/tmp';  -- 存一份 .sql 补丁归档
```

这一步，和你在 GitHub 上点开一个 PR、逐行看 diff，是**完全一样的动作**——只不过看的是数据。看完之后：

```sql
DATA BRANCH MERGE products_review INTO products;   -- 批准：合入主线
-- 或者打回：DROP TABLE products_review; —— 生产表一行都没动过
```

三个关键点正好对上合规的三条诉求：改动在**合并前对生产完全不可见**；review 建立在**行级事实（DIFF）**上、而非口头描述；`OUTPUT FILE` 导出的 `.sql` 补丁可以**归档留痕**，事后随时可审。

---

## 真撞车了：大促时两拨人改到了同一个爆款

分工再清楚也有意外。回到大促现场：有两个同事（就叫 Dave 和 Erin）临时都去调了**同一个爆款（42 号）的价格**，而 Erin 顺手还改了另一个商品（20 号，没人碰）。42 号就撞上了——这是**真冲突**。先记住那条唯一的规则：

> **只有"两条分支都独立改了同一行"，才算真冲突。** 改的是不同的行 → 假冲突，数据库自动合并、无人介入；哪怕两人改的是同一行的不同列，也算真冲突（行级判定）。

![真假冲突：改不同行自动合并（假冲突），改同一行才需裁决（真冲突）](./images/fig_conflict-detect_zh.svg)

```sql
DATA BRANCH CREATE TABLE products_dave FROM products;
DATA BRANCH CREATE TABLE products_erin FROM products;
UPDATE products_dave SET price = 1.00 WHERE product_id = 42;          -- Dave 改 42
UPDATE products_erin SET price = 2.00 WHERE product_id = 42;          -- Erin 也改 42（撞车）
UPDATE products_erin SET status = 'retired' WHERE product_id = 20;    -- Erin 独有、不冲突

DATA BRANCH MERGE products_dave INTO products;     -- Dave 先到，干净合入，主线 42 = 1.00
```

现在 Erin 来合，42 号撞上了。三种裁决方式，行为各不相同（实测确认）：

```sql
-- ① FAIL（默认）：一旦发现冲突，整个合并中止回滚。
DATA BRANCH MERGE products_erin INTO products WHEN CONFLICT FAIL;
--   报错：conflict on pk(42)；主线一行未动——连 Erin 不冲突的 20 号也没合进来。
--   FAIL 是"全有或全无"：把冲突摆上台面，逼你先去解决。

-- ② SKIP：只跳过冲突的行，其余正常合入。
DATA BRANCH MERGE products_erin INTO products WHEN CONFLICT SKIP;
--   结果：42 号保留主线（Dave 的 1.00）；20 号成功合入（Erin 的 retired）。

-- ③ ACCEPT：冲突行采用分支（Erin）的值，其余也照常合入。
DATA BRANCH MERGE products_erin INTO products WHEN CONFLICT ACCEPT;
--   结果：42 号变成 Erin 的 2.00。
```

![三种冲突裁决：FAIL 整体中止 / SKIP 跳过冲突行其余合入 / ACCEPT 冲突行采用分支值](./images/fig_conflict-policies_zh.svg)

放到大促语境里就很具体了：如果**定价的活动价更权威**，就 `ACCEPT` 定价那条分支；如果只是想把**几个紧急要改的爆款**单独提到主线、不合整条分支，就用 cherry-pick：

```sql
-- 只把 50、51 两个爆款的改动挑到主线，其余不动（PICK 需要主键）
DATA BRANCH PICK products_pick INTO products KEYS (50, 51) WHEN CONFLICT FAIL;
--   实测：只有 50、51 号被合入，52 号即便在分支里也改过，主线保持原值。
```

这里有两个容易忽略、但很关键的点：

1. **数据库把冲突显式摆出来，而不是悄悄让后写覆盖先写。** "后写静默覆盖先写"正是没有版本控制时最常见的事故来源（lost update）；在大促这种多人抢改的高压场景下，它尤其致命。
2. **要裁决的只有真撞上的那一行。** Erin 分支里其它正常改动会跟着 SKIP/ACCEPT 自动合入——要人拍板的，永远只是那几行真冲突。

> 回到上一篇埋的伏笔：第五篇里"手工 `UPDATE … JOIN` 把受损行还原、保住新订单"的定点修复，本质上就是这里 `DATA BRANCH MERGE` 自动做的三方合并——以共同祖先为基准、自动区分真假冲突。当时我们手工跑了一遍原理，现在把它交还给数据库。

---

## 几条让冲突更少的实践

- **按主键号段 / 分区分工**，让各人的改动天然不重叠——这是成本最低的"无冲突"。
- **小步快合**：频繁地把小分支合回主线，比攒一个月再做一次大爆炸式合并，冲突少得多。
- **全队固定一个 base 快照**（`team_base`），所有分支从它分出——血缘清晰，合并走第三篇说的增量快路径。
- **要改表结构？先在主线改 schema、再开分支**，别在分支里改完结构再合。

---

## 这就是数据的 Pull Request

把上面三件事用的动作抽出来，对照你每天在 GitHub 上做的事，几乎一一对应：

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

- **分支免费、合并秒级**，且与表多大、并行多少人无关：之前实测过，6 亿行的表、4 个工程师各自 fork、各改百万行，每次合并都是**秒级**。无论是大促的三拨人、还是迁移的长周期分支，瓶颈都不在 git4data 这一侧。
- **冲突裁决是行级，不是单元格级**：同一行的不同列也算冲突（第四篇讲过；单元格级自动合并是未来工作）。
- **diff/merge 要求 schema 一致**，且血缘可用时才走增量快路径（第三篇）。
- **`FAIL` 是全有或全无**：要"部分合并"，用 `SKIP` / `ACCEPT`，或用 `PICK` 精确挑行。

---

## 结语

数据协作开发不是一个抽象能力，而是**每次你做大促备战、系统迁移、合规整改这类事时，都会用上的基础设施**：分支免费、合并秒级、冲突显式且只裁决真撞上的行。多拨人同时推进、最后安全汇到一起——这件以前要靠排期和备份表硬扛的事，现在和合并代码一样自然。

但有个问题这篇还没回答：合并进主线的数据，**质量谁来把关**？万一某条分支合进来的本身就是脏数据呢？下一篇讲发布侧的答案：**Write-Audit-Publish**——新数据先进 staging 分支、过一道 SQL 审计门禁、再原子发布，让生产**永远看不到**没过关的数据。

> 📎 可运行 SQL：[github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ 源码与社区：[github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)

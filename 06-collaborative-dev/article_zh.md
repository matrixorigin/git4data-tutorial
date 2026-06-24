# MatrixOne Git4Data 技术详解（六）：数据协作开发——像合并代码一样合并数据

上一篇讲了一个人出事故怎么救。这一篇讲更日常的事：**一个团队，同时改同一份数据**。

没有版本控制的时候，团队是怎么协作的？基本靠嘴："这张表这两天我在改，你先别动""你改完了吱一声，我再上"。再配上几张 `orders_backup_0610_final_v2` 这样的备份表。本质上是**串行干活 + 人肉加锁**——代码世界二十年前就告别的状态。

git4data 把 GitHub 的协作模式原样搬给数据：**每人一条分支，并行干活，改完自查，合并回主线，冲突由数据库裁决。**

> 📦 本文 SQL 可整体跑通：[matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) 的 `06-collaborative-dev/`。环境照旧（`matrixone:4.0.0-rc3` + 一张 10 万行的 `products` 表）。

---

## 每人一条分支

三位工程师要同时维护一张商品表：Alice 调价、Bob 补缺失的描述、Carol 下架一批停产商品。先固定全队共同的起点，然后每人 fork 一条带血缘的分支：

```sql
CREATE SNAPSHOT team_base FOR TABLE collab_demo products;

DATA BRANCH CREATE TABLE products_alice FROM products;
DATA BRANCH CREATE TABLE products_bob   FROM products;
DATA BRANCH CREATE TABLE products_carol FROM products;
```

三条分支瞬间就位（第三篇讲过：分支只复制对象引用，毫秒级）。从这一刻起，三个人**互相完全不可见、互相完全不影响**——不用商量谁先谁后。

```sql
-- Alice：A 类商品调价（负责 1~30000 号段）
UPDATE products_alice SET price = round(price * 1.10, 2)
WHERE category = 'A' AND product_id <= 30000;

-- Bob：补缺失描述（负责 30001~60000 号段）
UPDATE products_bob SET descr = concat('backfilled_', product_id)
WHERE descr IS NULL AND product_id BETWEEN 30001 AND 60000;

-- Carol：下架停产区间
UPDATE products_carol SET status = 'retired'
WHERE product_id BETWEEN 90000 AND 95000;
```

⚠ 注意一个实操要点：**分工要按"行"切，不要按"列"切**。冲突判定是行级的——如果 Alice 改了第 60 行的价格、Bob 改了第 60 行的描述，虽然碰的是不同列，合并时也算冲突（我们在写这篇时真踩到了这个坑）。按主键号段划分工作范围，就天然无冲突。

---

## 合并前，先自查

每人合并前用 DIFF 给自己的改动做一次行级 review——相当于提 PR 前先看一眼自己的 diff：

```sql
DATA BRANCH DIFF products_alice AGAINST products OUTPUT SUMMARY;
-- UPDATED = 我这次到底改了多少行？范围对不对？有没有误伤？
```

确认无误，依次合并——因为行范围不重叠，三条分支**以任意顺序合并都干净通过**，不需要任何协调：

```sql
DATA BRANCH MERGE products_alice INTO products;
DATA BRANCH MERGE products_bob   INTO products;
DATA BRANCH MERGE products_carol INTO products;
```

主线现在同时携带三个人的成果。整个过程没有锁表、没有窗口期、没有"你等我"。

---

## 真撞上了怎么办

分工再好也有意外。Dave 和 Erin 不知情地改了**同一行**：

```sql
DATA BRANCH CREATE TABLE products_dave FROM products;
DATA BRANCH CREATE TABLE products_erin FROM products;
UPDATE products_dave SET price = 1.00 WHERE product_id = 42;
UPDATE products_erin SET price = 2.00 WHERE product_id = 42;

DATA BRANCH MERGE products_dave INTO products;          -- Dave 先到，干净合入
DATA BRANCH MERGE products_erin INTO products WHEN CONFLICT FAIL;
-- 报错：在 product_id=42 上冲突；整个合并回滚，主线一行未动
```

数据库把冲突**摆到台面上**，而不是悄悄让后写的覆盖先写的（这正是没有版本控制时最常见的事故来源：lost update）。裁决方式三选一：

```sql
DATA BRANCH MERGE products_erin INTO products WHEN CONFLICT SKIP;    -- 保留 Dave 的
-- 或 WHEN CONFLICT ACCEPT（采用 Erin 的）；或人工改完 Erin 的分支再合
```

而且记住第三篇的结论：**只有真撞上的行需要裁决**。Erin 分支里其它几千行正常改动会自动合入,需要拍板的只有 42 号这一行。

---

## 这就是数据的 Pull Request

对照一下你每天在 GitHub 上做的事：

| GitHub | git4data |
|---|---|
| fork / branch | `DATA BRANCH CREATE TABLE … FROM …` |
| 看自己的 diff | `DATA BRANCH DIFF … AGAINST … OUTPUT SUMMARY` |
| merge PR | `DATA BRANCH MERGE … INTO …` |
| 冲突解决 | `WHEN CONFLICT FAIL / SKIP / ACCEPT` |
| 回到分叉点 | `RESTORE … {SNAPSHOT = team_base}` |

成本侧再提一句：这套流程在 6 亿行的表上同样成立——之前实测过，4 个工程师各自 fork、改百万行、合并回主线，每次合并都是**秒级**。并行的人数和表的大小，都不再是协作的瓶颈。

---

## 结语

数据协作开发是 git4data 把"廉价的并行"兑现得最直接的地方：分支免费、合并秒级、冲突显式。团队规模不再受"一张表只能一个人动"的隐形约束。

但有一个问题这篇还没回答：合并进主线的数据，**质量谁来把关**？下一篇讲发布侧的answer：**Write-Audit-Publish**——数据先进 staging 分支、过 SQL 审计门禁、再原子发布,生产永远看不到脏数据。

> 📎 可运行 SQL：[github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ 源码与社区：[github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)

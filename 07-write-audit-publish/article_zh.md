# MatrixOne Git4Data 技术详解（七）：Write-Audit-Publish——给数据发布加一道门禁

数据管道有一个老大难问题：**上游来的数据,质量不归你管,但出了事算你的。**

凌晨的 ETL 把一批新数据直接灌进了生产表——里面混着空 user_id、负数金额、一眼假的离群值。等白天有人发现时,下游报表已经算错、模型已经训歪、客户已经看到了。然后是更难的部分:**脏数据和好数据已经混在一张表里**,清理它比当初挡住它难十倍。

软件工程对这类问题的标准答案是 CI 门禁:代码必须过测试,才能合进主干。数据世界的对应物叫 **Write-Audit-Publish(WAP)**——写入先进隔离区,审计通过,再发布。过去要靠 Iceberg/lakeFS 这类湖上工具来搭;在 git4data 里,它就是分支的一个基本用法。

> 📦 本文 SQL 整体可跑:[matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) 的 `07-write-audit-publish/`。

---

## Write:新数据永远先落在 staging 分支

生产表 `events` 有 10 万行干净数据,下游持续在读。今天的新批次**不直接碰它**:

```sql
-- 给生产表开一条 staging 分支(毫秒级,第三篇讲过原理)
DATA BRANCH CREATE TABLE events_staging FROM events;

-- 新批次 5000 行,落到 staging——其中混着真实管道里常见的脏数据:
-- 空 user_id、负数金额、离谱的离群值
INSERT INTO events_staging
SELECT 100000 + result,
       CASE WHEN result % 100 = 0 THEN NULL ELSE result % 5000 END,
       CASE WHEN result % 250 = 0 THEN -1.00
            WHEN result % 333 = 0 THEN 999999.99
            ELSE round(rand()*500, 2) END,
       '2026-06-10'
FROM generate_series(1, 5000) g;
```

此刻生产表一行未动。脏数据被关在 staging 里——这就是 WAP 的第一性原理:**隔离先于质量**。

## Audit:SQL 就是质量门禁

审计就是几条跑在 staging 上的 SQL——你可以把它做成 CI 里的一个步骤:

```sql
SELECT
  SUM(CASE WHEN user_id IS NULL THEN 1 ELSE 0 END)  AS null_user,
  SUM(CASE WHEN amount < 0 THEN 1 ELSE 0 END)       AS negative_amount,
  SUM(CASE WHEN amount > 10000 THEN 1 ELSE 0 END)   AS outlier_amount
FROM events_staging WHERE ts = '2026-06-10';
-- 门禁不过:三类脏数据都被抓出来了
```

门禁失败,修复也在 staging 里完成(生产全程无感):

```sql
DELETE FROM events_staging
WHERE ts = '2026-06-10'
  AND (user_id IS NULL OR amount < 0 OR amount > 10000);
-- 重跑门禁 → 全零,通过
```

发布前还可以最后看一眼这批数据**究竟**会给生产带来什么——行级的:

```sql
DATA BRANCH DIFF events_staging AGAINST events OUTPUT SUMMARY;
-- INSERTED = 这批将要发布的确切行数
```

## Publish:一次原子合并

```sql
DATA BRANCH MERGE events_staging INTO events;
```

这一步是**原子**的:下游读者要么看到完整的、已审计的整批数据,要么(在这条语句之前)一行也看不到——**不存在"发布到一半"的中间状态**。验证一下:

```sql
SELECT COUNT(*) FROM events
WHERE user_id IS NULL OR amount < 0 OR amount > 10000;   -- 0
```

生产表从头到尾没出现过一行脏数据。

---

## 为什么这件事值得一道门禁

把三步连起来看,WAP 改变的是一个根本假设:

> 没有 WAP:生产表 = 数据的**入口**,质量问题进来之后再说。
> 有了 WAP:生产表 = 数据的**出口**,只有通过审计的数据才配进来。

成本上,这道门禁几乎是免费的:staging 分支毫秒级创建(零拷贝)、审计就是普通 SQL、发布是一次秒级 MERGE。对比传统做法——建临时表、全量拷贝、写交换逻辑——既慢又碎。

再往前一步,这套流程天然可以自动化:管道每天的批次 → 自动开 staging → 自动跑审计 SQL → 通过即 MERGE、失败即告警并保留现场(staging 分支就是完整的事故现场,可以直接拿来 debug)。**这就是数据的 CI/CD。**

---

## 结语

至此,数据运维三部曲完成了:**个人的安全网**(第五篇,出事能回去)、**团队的并行**(第六篇,分支与合并)、**生产的门禁**(本篇,脏数据进不来)。三件事共用同一套原语——snapshot、branch、diff、merge——这正是"把版本控制装进数据库"的意义:不是多了一个功能,而是多了一种工作方式。

下一篇起进入 AI 训练主题。第一站是最经典的:**机器学习的持续学习**——数据每天都在变,凭什么每次都全量重训?用 DIFF 把"变了的那部分"精确取出来,只训增量。

> 📎 可运行 SQL:[github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ 源码与社区:[github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)

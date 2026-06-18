# MatrixOne Git4Data 技术详解（十二）：多模态训练集——lakeFS 管字节，MatrixOne 管目录

训练主题的前四篇都在处理**结构化的行**:样本、标签、偏好对。但视觉/多模态模型的训练集里还有另一半——**图像、音频、视频的原始字节**。这一半,坦白说,不是 git4data 的主场。

第三篇讲边界时就说过:git4data 对文件只版本化"引用",不版本化字节本身。几百万张图的内容级版本管理,属于 **lakeFS** 这类面向对象存储的 git-for-data 工具(commit/branch/merge 的对象是文件)。那多模态训练集怎么办?

答案不是二选一,而是**各管一半,缝在一起**:

> **lakeFS 版本化字节,MatrixOne 版本化目录(哪些文件 + 哪些标注),一个表快照把两个世界钉成一个可复现的数据集版本。**

> 📦 本文目录侧 SQL 整体可跑(lakeFS 侧以 commit id 表示):[matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) 的 `12-multimodal-lakefs/`。

---

## 关键设计:目录按 commit 引用字节

MatrixOne 里建一张目录表,每行一张图。要点在 `uri` 的构造——**路径里带着 lakeFS 的 commit id**:

```sql
CREATE TABLE image_catalog (
    img_id        BIGINT PRIMARY KEY,
    lakefs_commit VARCHAR(16),
    uri           VARCHAR(256),    -- lakefs://repo/<commit>/imgs/<id>.jpg
    label         VARCHAR(16),
    quality       DECIMAL(4,2)
);
```

为什么不直接用 `lakefs://repo/main/...`(指向分支)?因为分支会动,**commit 不会**。按 commit 引用,这一行目录就成了**不可变引用**:无论 lakeFS 那边后来怎么变,这个 uri 永远解析出同一份字节。这是整个集成的支点。

一万张图在 lakeFS 落定于 commit `c1a2b3`,目录入库、标注就位,然后:

```sql
CREATE SNAPSHOT dataset_v1 FOR TABLE mm_demo image_catalog;
```

**dataset_v1 这个表快照,同时钉住了两个世界**:字节侧(每个 uri 里的 commit)+ 标注侧(label 列当时的值)。模型 m1 训练于此。

## 两种"变",各走各的版本

多模态数据集的演化有两条独立的线,这套架构把它们分得很清楚:

**标注变了**(纯 MatrixOne 侧):

```sql
UPDATE image_catalog SET label = 'cat' WHERE label = 'other' AND img_id < 500;
```

**字节变了**(两边联动):2000 张图重新导出(更好的裁切),lakeFS 产生新 commit `c9d8e7`,目录里**只有这些行**的引用跟着移过去:

```sql
UPDATE image_catalog
SET lakefs_commit = 'c9d8e7',
    uri = concat('lakefs://imgs/c9d8e7/imgs/', img_id, '.jpg')
WHERE img_id BETWEEN 3000 AND 4999;
```

再钉一版:`CREATE SNAPSHOT dataset_v2 ...`。

## 字节级时间旅行

现在,"精确复现 m1 的输入"这个多模态最难的问题,变成了一次时间旅行:

```sql
SELECT lakefs_commit, COUNT(*) FROM image_catalog {snapshot='dataset_v1'}
GROUP BY lakefs_commit;
--   c1a2b3 | 10000      ← v1 的每个 uri 都还指着原始字节

SELECT lakefs_commit, COUNT(*) FROM image_catalog GROUP BY lakefs_commit;
--   c1a2b3 | 8000, c9d8e7 | 2000   ← 现在的数据集混着新旧两版字节
```

按 `dataset_v1` 解析目录,拿到的 uri 全部指向 commit `c1a2b3`——lakeFS 据此交付**当时的字节**。标注同理回到当时的值。**单独哪一边都做不到这件事**:lakeFS 不知道"哪些文件配哪些标注算一个数据集",MatrixOne 不保管字节;目录 pin commit,把两边的版本语义缝合了。

两版数据集之间差了什么,照例行级可查:

```sql
DATA BRANCH DIFF image_catalog AGAINST image_catalog {SNAPSHOT='dataset_v1'} OUTPUT SUMMARY;
--   UPDATED = 改标注的行 + 换字节引用的行,每一行可单独追责
```

---

## 分工表

| | lakeFS | MatrixOne |
|---|---|---|
| 版本化对象 | 文件字节(content-addressed commit) | 目录行:引用 + 标注 + 元数据 |
| 强项 | 海量非结构化、字节级 dedup | 行级 diff/merge、SQL 计算、快照原子性 |
| 数据集版本 | —(只知道文件) | **表快照 = 字节版本 × 标注版本** |

诚实补一句工程成本:这套组合需要额外运维一个 lakeFS(加对象存储)。如果你的多模态规模还小、或字节基本不变,先用 MatrixOne 目录 + 对象存储裸路径也能跑,等字节本身需要版本化了再上 lakeFS——架构是渐进的,不必一步到位。

---

## 结语

训练主题到此收官。五篇连起来是一条完整的数据生产线:增量训练(七)、策展(八)、标注(九)、偏好(十)、多模态(十一)——结构化的行归 git4data,海量字节归 lakeFS,边界清楚,组合有道。

下一个主题,也是这个系列开篇就预告的终点站:**Agent**。第一站讲它最贴身的东西——**记忆**。Agent 的记忆是一张表,而一张表,我们现在已经知道怎么给它装上版本控制了。

> 📎 可运行 SQL:[github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ 源码与社区:[github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)

# MatrixOne Git4Data Deep Dive (Part 10) · Deep Learning — Managing Multimodal Training Data: lakeFS for the Bytes, MatrixOne for the Metadata

The first nine parts stayed on structured data: the [first four](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part1-data-at-scale/index.md) established what Git4Data is, how to use it, and [where it sits](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part4-landscape/index.md) versus other tools; parts five through seven covered data operations; parts eight and nine entered AI training, walking a risk model through the [whole-pipeline map](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part8-ml-lifecycle/index.md) and [dataset release & leakage](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part9-dataset-release/index.md).

From this part on, we turn to the data of **deep learning**. One clarification first: deep learning is a broad field, and it is not the same as multimodal — a text-only network or an image-only CNN is still deep learning. But it shares a watershed with classical ML in one respect, **data shape**: deep learning often trains directly on large-scale unstructured data (images, audio, video, raw text), and multimodal models mix several modalities together.

**This part focuses on managing that kind of multimodal / unstructured-media training data** — the most typical, and hardest-to-version, data shape in deep learning, not deep learning as a whole. When the data goes from "rows in a table" to "a pile of bytes + a huge metadata table," the versioning playbook has to change.

> This part is the **opening overview of multimodal training-data management** (the first in the deep-learning-data thread), the structural counterpart of Part 8 for classical machine learning: lay out the whole picture first — from arrival to release, what the real problem is at each step, and which side owns the bytes versus the metadata. All metadata-side SQL here is verified on MatrixOne `4.1.0`; the runnable version lives in [matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) under `10-multimodal-lakefs/`.

---

## Deep learning's data is, first of all, a "bytes" problem

A classical ML sample is a row in a table: a few dozen structured fields, naturally fit for a database, naturally snapshot-able, diff-able, merge-able.

Multimodal data isn't like that. A sample's body is **a pile of bytes** — a few-MB image, a few-tens-of-MB audio clip, a hundred-MB video segment. A whole dataset runs to tens of millions of items, TB to PB. You can't, and shouldn't, stuff those bytes into a database.

But note one thing: **the bytes themselves don't go in the database, yet everything about the bytes is highly structured.** Every sample has: where it lives (object path), its content hash, its perceptual hash, the paired text (caption), its label, which source it came from, what license, width/height, quality score, whether it's train or test, which model version used it… These are tens of millions of rows, still constantly inserted / updated / deleted — exactly where row-level version semantics matter most.

So deep learning's data versioning splits naturally into **two worlds**:

- **The byte world**: the image / audio / video bodies. In object storage or lakeFS, what's versioned is "the object / file version."
- **The metadata world**: who points to which object, caption, label, split, various hashes, source, license… one (or a few) huge structured tables, where what's versioned is "the row."

A truly reproducible multimodal training set is this product:

```text
reproducible training set = one definite metadata version (metadata snapshot)
                          × one definite set of byte versions (lakeFS commit)
```

The two worlds must be **pinned together and kept consistent**: pin only the metadata and the bytes may have been overwritten; pin only the bytes and you don't know which samples, what labels, what split were in play. This is exactly where lakeFS (for the bytes) and MatrixOne's Git4Data capability (for the metadata) each do their job and then compose.

### Why give the bytes to lakeFS, instead of stuffing them into the database too?

A natural question: since MatrixOne can version data, why not put the image bytes in there too and let one system manage everything? The earlier parts already laid out the answer.

- **Git4Data's cheap snapshots assume "structured data + a metadata catalog."** [Part 3](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part3-under-the-hood/index.md) showed MatrixOne's snapshots are nearly independent of data size because immutable objects plus a metadata catalog version **row-level structured data**. Pour in PB of unparseable image bytes and that assumption breaks — the database degrades into a slow, expensive object store.

- **Bytes have no structure to diff.** Git4Data's value, established back in [Part 2](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part2-hands-on/index.md), is row-level diff / merge / query. But a JPEG has no rows, no primary key, no columns — a "row-level diff" of two images' bytes is meaningless. The boundary [Part 4](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part4-landscape/index.md) drew is exactly this: Git4Data manages "structured-data evolution under one schema," and bytes have no schema.

- **Bytes are whole, immutable, content-addressed.** An image isn't `UPDATE`d row by row; it's replaced wholesale. Versioning that's "whole objects + content dedup + cheap branching" is exactly what object storage + lakeFS (git-over-objects) is built for; forcing the database's row-level MVCC onto it is a mismatch.

- **The database should only hold the pointer anyway.** [Part 8](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part8-ml-lifecycle/index.md)'s overview already said it: unparseable bytes go to object storage / lakeFS, and MatrixOne stores only the catalog, hashes, URI, and commit — and a database snapshot can only freeze the **value of the pointer field**, not the external bytes themselves (the `datalink` boundary). So the byte version must be lakeFS's own job.

In one line: **the database is best at "row-level versioning of structured metadata," lakeFS is best at "whole-object versioning of large bytes." Let each do what it's strongest at, then pin the two together — that's the whole thesis of this part.**

---

## One master map: the multimodal data lifecycle — bytes to lakeFS, metadata to MatrixOne

The conclusion first. The whole lifecycle of multimodal training data splits cleanly into a "byte side" and a "metadata side," each versioned on its own, aligned at release.

![The multimodal data lifecycle: ingest → dedup → decontaminate → align → relabel → curate → release → train; at each stop the byte side goes to lakeFS and the metadata side to MatrixOne, pinned together at release by one metadata snapshot × one lakeFS commit](./images/fig_multimodal-lifecycle_en.svg)

| Stage | The real problem | Byte side (lakeFS) | Metadata side (MatrixOne Git4Data) |
|---|---|---|---|
| Ingestion | new media, quality unknown, mustn't poison the set | land on an ingest branch | metadata rows on a branch, `MERGE` only on pass |
| Dedup | exact + perceptual duplicates across tens of millions | objects stored as-is | `GROUP BY` on `content_hash` / `phash`, pure SQL |
| Decontamination | eval / benchmark samples leaked into train | —— | anti-join the metadata to a benchmark-hash table, `DELETE` overlaps |
| Multimodal alignment | image, text, boxes, labels must stay consistent | object existence guaranteed by lakeFS | find broken pairs on the metadata (missing caption / pointer) |
| Relabel / re-caption | labels, captions, safety scores iterate | bytes unchanged | one branch per person, `MERGE` conflicts, `DIFF` the changes |
| Curation | filter a clean subset by quality / safety / license | —— | a versioned `dataset_membership` subset |
| Dataset release | freeze "which version of which bytes this training used" | one lakeFS commit | one database-scope metadata snapshot, commit recorded in a registry |
| Training & evaluation | model must trace back to the exact data scene | commit locates the bytes | snapshot + registry build `model → metadata snapshot × lakeFS commit × code/env` lineage |
| Monitoring & retrain | new data accumulates, when to trigger the next round | new commit | distribution stats on the metadata + cross-version `DIFF` |

The division of labor in one line:

> **lakeFS makes the bytes traceable and reversible; MatrixOne's Git4Data capability makes the metadata queryable, row-level comparable, and atomically publishable. The two align into one reproducible whole via "a lakeFS commit recorded inside a metadata snapshot."**

Below, one complete case runs the whole map.

---

## The running case: preparing image-text training data for a multimodal model

Say we're preparing training data for an image-text model (think a multimodal model for content understanding / moderation). The data is crawled and purchased from several sources; it needs dedup, decontamination, alignment, and relabeling, and finally curation into a clean, reproducible training set.

The metadata is a `samples` table — **note it stores no bytes, only a pointer to the bytes plus everything you actually query on**:

```sql
CREATE TABLE samples (
    sample_id     BIGINT PRIMARY KEY,
    modality      VARCHAR(16),
    object_uri    VARCHAR(512),   -- lakeFS path (a pointer, not the bytes)
    object_commit VARCHAR(64),    -- the lakeFS commit that pins these bytes
    content_hash  VARCHAR(64),    -- sha256 of the bytes (exact-dup key)
    phash         VARCHAR(64),    -- perceptual hash (near-dup key)
    caption       TEXT,           -- the paired text (a second modality)
    label         VARCHAR(16),
    source        VARCHAR(32),    -- provenance
    license       VARCHAR(16),
    quality       DOUBLE,
    ingest_batch  VARCHAR(32)
);
```

A reproducible training record must bind at least these:

```text
run = metadata snapshot
    + lakeFS commit (the byte version)
    + curation & split rules
    + preprocessing / tokenizer version
    + code commit + runtime image digest
    + hyperparameters & random seed
    + model artifact URI & hash
    + evaluation metrics
```

**The metadata snapshot owns "which samples, what labels, how split"; the lakeFS commit owns "which version of the bytes" — drop either and this record can't be reproduced.**

### Stop 1: Ingestion — WAP across two worlds

Monday, upstream delivers 5,000 new image-text pairs. The bytes are pushed to a lakeFS ingest branch; meanwhile the metadata rows enter a metadata branch, not yet touching the set:

```sql
DATA BRANCH CREATE TABLE samples_stage FROM samples;
INSERT INTO samples_stage SELECT ... FROM ...;   -- the batch enters staging only

-- metadata-side gate: pointers complete? captions present? license known?
SELECT
  SUM(CASE WHEN object_uri IS NULL OR object_commit IS NULL THEN 1 ELSE 0 END) AS missing_pointer,
  SUM(CASE WHEN caption IS NULL THEN 1 ELSE 0 END)                             AS missing_caption,
  SUM(CASE WHEN license = 'unknown' THEN 1 ELSE 0 END)                         AS unknown_license
FROM samples_stage WHERE ingest_batch = '2026w30';
--   measured missing_pointer 0 / missing_caption 250 / unknown_license 1000

DATA BRANCH DIFF samples_stage AGAINST samples OUTPUT SUMMARY;   -- measured INSERTED 5000
DATA BRANCH MERGE samples_stage INTO samples;                    -- publish only on full pass
```

The byte-side counterpart is a lakeFS pre-merge hook on that ingest branch doing byte-level checks (can the file decode, dimensions, a safety pre-scan), merging the lakeFS branch only on pass. **Each side audits and merges atomically; whatever fails on either side doesn't reach the mainline.**

### Stop 2: Dedup — exact + perceptual, pure SQL, not one byte touched

Across tens of millions of files there will be exact duplicates (the same image crawled twice at different URLs) and perceptual near-duplicates (the "same image" after cropping, compression, or a watermark). Both can be found on the metadata with SQL, **without pulling a single byte back**:

```sql
-- exact duplicates: one content_hash owned by more than one sample
SELECT COUNT(*) AS exact_dup_groups FROM (
  SELECT content_hash FROM samples GROUP BY content_hash HAVING COUNT(*) > 1
) t;   -- measured 3000 groups

-- perceptual near-dups (not exact dups): same phash, more than one content_hash
SELECT COUNT(*) AS near_dup_groups FROM (
  SELECT phash FROM samples GROUP BY phash HAVING COUNT(DISTINCT content_hash) > 1
) t;   -- measured 2000 groups
```

The byte-side hashes are computed offline and written into the metadata; once in the metadata, dedup is a few `GROUP BY`s, not a sweep across PB of object storage.

### Stop 3: Decontamination — dig the eval set out of the training set

This is the sore spot of deep learning, foundation models especially: **one test / benchmark image leaking into the training set inflates every downstream number.** The move is to anti-join the metadata against known eval-set hashes:

```sql
-- how many training samples overlap the benchmark (by content)?
SELECT COUNT(*) AS contaminated FROM samples s
WHERE EXISTS (SELECT 1 FROM eval_hashes e WHERE e.content_hash = s.content_hash);
--   measured 1000 (500 benchmark originals + their re-crawled mirrors)
```

Note the exact hits are 500, but with mirrors it's 1000 — **decontamination must cover duplicates and near-duplicates**, or an escaped mirror feeds the benchmark into training anyway. That's why dedup and decontamination belong on the same metadata, done together.

### Stop 4: Multimodal alignment — the image-text pair must be one consistent unit

What's special about a multimodal sample: one sample is a **combination of modalities** (image + caption + maybe boxes, labels), and they must stay consistent as a whole. The commonest break is a "snapped pair" — an image with no text, text with no image, or a pointer to an object that no longer exists:

```sql
-- broken image-text pairs: an image with no caption
SELECT COUNT(*) AS unaligned_pairs FROM samples WHERE caption IS NULL;
--   measured 550
```

Here's a trap between the byte world and the metadata world: **deleting an object in lakeFS does not automatically delete the metadata rows pointing to it; and deleting a metadata row doesn't delete the bytes.** The two worlds are versioned independently, but alignment rides on discipline — an SQL sweep for orphan pointers and broken pairs before release is the cheapest alignment gate.

### Stop 5: Relabel and re-caption — the metadata evolves, the bytes don't budge

Labels get corrected, captions get rewritten, safety scores get re-assessed — all of these touch only the **metadata**; the bytes are untouched. So we're back to the parallel collaboration of [Part 6](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part6-collaborative-dev/index.md): one branch per person, conflicts surface themselves, changes are on the record.

```sql
DATA BRANCH CREATE TABLE samples_review FROM samples;
UPDATE samples_review SET label = 'nsfw'
WHERE sample_id BETWEEN 1000 AND 1999 AND label = 'safe';
DATA BRANCH DIFF samples_review AGAINST samples OUTPUT SUMMARY;   -- measured UPDATED 980
DATA BRANCH MERGE samples_review INTO samples;
```

What a relabeling round changed is one `DIFF` away — and none of it produced a single byte copy.

### Stop 6: Curation and release — metadata snapshot × lakeFS commit

Release time. First curate a clean subset on the metadata: drop exact duplicates (keep the lowest `sample_id` per `content_hash`), drop eval overlaps, drop broken pairs, keep only clearly-licensed samples, and write the split:

```sql
INSERT INTO dataset_membership
SELECT s.sample_id,
       CASE WHEN s.sample_id % 10 < 8 THEN 'train'
            WHEN s.sample_id % 10 = 8 THEN 'valid' ELSE 'test' END,
       'curate:v1 dedup+decontam+aligned+licensed'
FROM samples s
WHERE s.caption IS NOT NULL
  AND s.license <> 'unknown'
  AND NOT EXISTS (SELECT 1 FROM eval_hashes e WHERE e.content_hash = s.content_hash)
  AND s.sample_id = (SELECT MIN(s2.sample_id) FROM samples s2 WHERE s2.content_hash = s.content_hash);
--   measured train 38474 / valid 4934 / test 4935
```

Then the key step — **pin the metadata snapshot together with the lakeFS commit**:

```sql
CREATE SNAPSHOT mm_dataset_v1 FOR DATABASE mm_train;

-- register "metadata version × byte version" as an executable binding
INSERT INTO dataset_registry
SELECT 'mm_v1', 'mm_dataset_v1', 'media', 'commit-2026w30-d4e5f6',
       COUNT(*), 'metadata snapshot × lakeFS commit = reproducible training set'
FROM dataset_membership;
```

From now on, "what data did mm_v1 use" is no longer a verbal description but a product: `mm_dataset_v1` (the metadata snapshot) names the samples, labels, and split, and `commit-2026w30-d4e5f6` (the lakeFS commit) names the bytes. To reproduce three months later, read the metadata from the snapshot and pull the bytes from the commit:

```sql
SELECT COUNT(*) AS train_rows_v1
FROM samples {SNAPSHOT='mm_dataset_v1'} s
JOIN dataset_membership {SNAPSHOT='mm_dataset_v1'} m ON s.sample_id = m.sample_id
WHERE m.split_name = 'train';
--   measured 38474, bit-for-bit
```

---

## lakeFS and MatrixOne: how the two version worlds divide the work and compose

This part has to make the boundary clear, or it's easy to assume "one of them is enough."

**lakeFS manages the bytes.** It's git-style version control over object storage: branch / commit / merge on top of S3 / GCS / Azure, pinning "the state of object storage at a moment" as a commit you can return to; plus pre-merge hooks for byte-level checks before a merge. It excels at versioning and rolling back **large file bodies**. What it doesn't do: treat tens of millions of metadata entries as a table to run SQL / JOIN / aggregate on, or tell you "between these two versions, which **rows'** labels changed."

**MatrixOne's Git4Data capability manages the metadata.** It treats the metadata as a live, queryable table: row-level snapshot / branch / diff / merge / restore, JOIN-able, aggregate-able, anti-join-able any time. It excels at versioning, row-level comparison, and atomic publishing of a **structured metadata**. What it doesn't do: store and version the byte bodies of images/audio/video.

**How do they compose?** Via "a lakeFS commit recorded inside a metadata snapshot." At release, the MatrixOne side takes a database-scope metadata snapshot and writes the current lakeFS commit into a registry; to reproduce, you use both IDs together.

| Object | Better suited to | What it owns | What it doesn't |
|---|---|---|---|
| Image / audio / video / large-file bytes | **lakeFS / object storage** | byte versioning, rollback, pre-merge checks | row-level metadata query & diff |
| Metadata: pointers, caption, label, hash, split, source | **MatrixOne (Git4Data capability)** | row-level snapshot / branch / diff / merge / restore, JOIN & aggregate | storing the byte bodies |
| Alignment of the two | **a binding in the registry** | metadata snapshot × lakeFS commit = reproducible training set | —— |

This is more realistic than "hoping one tool manages both bytes and metadata well." Bytes have their optimal solution, the metadata has its own; the key is to **pin them together explicitly**.

---

## Run it for real: an end-to-end lakeFS + MatrixOne practice

Everything above was described side by side. This section actually wires the two worlds together and runs them — the companion repo has a directly runnable [`run_practice.sh`](https://github.com/matrixorigin/git4data-tutorial/blob/main/10-multimodal-lakefs/run_practice.sh); below is its skeleton and measured output (commit values differ per run; the one shown is an example — the counts are deterministic).

**Start the two services**, one container each:

```bash
# byte side: lakeFS (local storage + pre-seeded admin credentials)
docker run -d --name lakefs -p 8000:8000 \
  -e LAKEFS_INSTALLATION_ACCESS_KEY_ID=... -e LAKEFS_INSTALLATION_SECRET_ACCESS_KEY=... \
  -e LAKEFS_DATABASE_TYPE=local -e LAKEFS_BLOCKSTORE_TYPE=local \
  -e LAKEFS_AUTH_ENCRYPT_SECRET_KEY=... treeverse/lakefs:latest run
# metadata side: MatrixOne
docker run -d --name matrixone -p 6001:6001 matrixorigin/matrixone:4.1.0
```

**① Bytes into lakeFS**: create the repo, open an ingest branch, upload objects, commit, merge to main, and get a real commit (the "byte version"):

```bash
curl -u $KEY:$SECRET -X POST $L/repositories/media/branches/ingest/commits -d '{"message":"ingest 2026w30"}'
curl -u $KEY:$SECRET -X POST $L/repositories/media/refs/ingest/merge/main   -d '{"message":"publish 2026w30"}'
#   -> main commit (the byte version) = ba1693908b37…
```

**② Metadata into MatrixOne**: each row points at a lakeFS object path + the commit just obtained; then dedup, decontaminate, align, curate on the metadata, snapshot it, and record the commit in a registry:

```sql
-- each samples row: object_uri='lakefs://media/main/img/000003.jpg', object_commit='ba1693908b37…',
--                   content_hash, phash, caption, label, license
--   measured exact_dup 1 / near_dup 1 / contaminated 1 / unaligned 1; after curation train 4 / valid 1 / test 1
CREATE SNAPSHOT mm_dataset_v1 FOR DATABASE mm_practice;
INSERT INTO dataset_registry
SELECT 'mm_v1', 'mm_dataset_v1', 'media', 'ba1693908b37…', COUNT(*) FROM dataset_membership;
```

**③ Reproduce — use both IDs together**: read a train sample's pointer and commit from the metadata snapshot, then go back to lakeFS and fetch the **actual bytes** at that commit:

```sql
SELECT s.object_uri, s.object_commit
FROM samples {SNAPSHOT='mm_dataset_v1'} s
JOIN dataset_membership {SNAPSHOT='mm_dataset_v1'} m ON s.sample_id = m.sample_id
WHERE m.split_name = 'train' ORDER BY s.sample_id LIMIT 1;
--   -> lakefs://media/main/img/000003.jpg  @  ba1693908b37…
```

```bash
curl -u $KEY:$SECRET "$L/repositories/media/refs/ba1693908b37…/objects?path=img/000003.jpg"
#   -> "img-3-bytes"   <- metadata snapshot × lakeFS commit reproduced the exact bytes
```

One metadata snapshot plus one lakeFS commit nail down exactly "which samples, which version of the bytes this training used" — which is the whole point of composing the two version worlds.

---

## Pitfalls to watch for

- **The two versions drift.** The commonest mistake is pinning only the metadata and not recording the lakeFS commit — the metadata reproduces, but the bytes don't match (an object may have been overwritten or deleted). The iron rule: **the metadata snapshot must remember its corresponding lakeFS commit.**

- **Don't store a bare, overwritable URI.** `object_uri` holds a pointer; if it's an address that can be overwritten, the snapshot freezes only that string, not the bytes. Store an immutable object version or a lakeFS commit. (Note: MatrixOne v4.1.0's `datalink` type only parses `file://` / `hdfs://` / `stage://`, not `s3://`; S3 / lakeFS objects should be stored as a stage path or an immutable object / commit version.)

- **Dedup is heuristic.** Perceptual hashes have false positives and false negatives; check exact and near-duplicates together, and sample suspicious groups by hand on important datasets.

- **Decontamination must cover near-duplicates**, not just exact matches — mirrors and crops are the commonest escapees for eval leakage.

- **License and consent must propagate with the sample.** The metadata's `source` / `license` aren't decoration; the moment a source's license is revoked, you must be able to find every affected sample in one SQL and curate them out in the next version.

- **Alignment rides on discipline.** The byte world and the metadata world are versioned independently; deletes don't sync automatically. An SQL sweep for orphan pointers and broken pairs before release is the cheapest alignment gate.

---

## A minimal loop you can adopt directly

1. Bytes to lakeFS, metadata to a MatrixOne `samples` table, each row recording a pointer + `content_hash` + `phash` + source + license.
2. New batches go to a branch first: bytes on a lakeFS branch, metadata on a metadata branch; each side audits, merge only on pass.
3. On the metadata, use SQL for dedup, decontamination, and alignment checks, keeping suspicious samples out of curation.
4. Curate a clean subset into `dataset_membership`, take a database-scope metadata snapshot.
5. **Register the lakeFS commit together with the metadata snapshot** — that's the reproducibility anchor.
6. At training, bind `model → metadata snapshot × lakeFS commit × code/env`; next round, use `DIFF` for metadata changes and a new commit for byte changes.

---

## Closing

Multimodal and unstructured data turned training data from "rows in a table" into "bytes in object storage + a huge metadata table." The optimal way to manage the two differs: the bytes want large-file versioning and rollback, the metadata wants row-level query, comparison, and atomic publishing. Force them into one tool and one end always chafes.

The more realistic architecture lets **lakeFS manage the bytes and MatrixOne's Git4Data capability manage the metadata**, then pins the two version worlds into one reproducible whole via "metadata snapshot × lakeFS commit." Dedup, decontamination, alignment, relabeling, curation — the operations that actually decide multimodal data quality happen almost entirely on the metadata, and the metadata happens to be a table you can version with SQL.

Next, we return to the text world of large models: **SFT data curation** — how to dedup, filter, and decontaminate hundreds of thousands of instruction records entirely in SQL, with a DIFF as the receipt for every cut.

> 📎 Runnable SQL: [github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ Source & community: [github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)

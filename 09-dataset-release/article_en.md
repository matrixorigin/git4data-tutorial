# MatrixOne Git4Data Deep Dive (Part 9) · AI Training in Practice — Dataset Release & Leakage: Don't Let Your Offline Metrics Fool You

In machine learning, whether a model can be trusted before it ships is answered almost entirely by **offline evaluation**: is this version better than the last? does this feature help? what threshold is right? can we go live? — every one of those decisions comes down to the same thing: measuring the model's real performance on data it **hasn't seen**.

And that "hasn't seen" rests entirely on how the dataset is split. Before training, we divide the data into three sets with distinct duties: the **training set** fits the model's parameters, the **validation set** selects features, tunes hyperparameters, and compares candidate models, and the **test set** gives one as-unbiased-as-possible final estimate once the approach is locked. How these three are cut, and where the boundaries are drawn, directly decides whether every metric you see afterward can be trusted.

The trouble is that this step is often the most casually handled in the whole pipeline — one `train_test_split(random_state=42)` and it's done. Which leads to a scene many ML engineers have lived through.

Offline AUC 0.94, ship it with confidence, and a week later production drops to 0.78. You go back and check: the model didn't change, the features didn't change, the code didn't change — the problem was in that most overlooked step of all, how the train and test sets were split.

The split was a casual `train_test_split(random_state=42)`: the same user's multiple transactions got randomly scattered across train and test, so the model had actually "seen" the people in the test set; and standardization was fit on the full data *before* the split, so its mean and variance had already peeked at the test set. Worse, the dataset that produced 0.94 **can no longer be reproduced** — the notebook is long closed, the `samples` table has had a few thousand rows added and corrected this week, and the same `random_state=42` on a table that has changed gives you a different set of rows entirely.

Offline metrics are the model's only "medical exam" before it ships. **Get the split wrong and that exam is fake** — it won't throw an error, it just hands you a good-looking number and then falls over in production.

This part is about that step: why a train / valid / test split isn't a throwaway `ORDER BY RAND()`, but the step that decides whether your offline evaluation can be trusted at all; and how to use MatrixOne's Git4Data capability to make it a reproducible, auditable, reversible versioned object.

> This part continues Stop 4 of the previous [AI Training in Practice · Overview](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part8-ml-lifecycle/index.md), drilling deeper into the same risk-model case. Still focused on classical machine learning over structured data. All SQL is verified on MatrixOne `4.1.0`; the runnable version lives in [matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) under `09-dataset-release/`.

---

## One split actually defines three things at once

"Splitting data into train / valid / test" sounds like one action, but it defines three things at once:

1. **Who belongs to which set (membership)** — for every sample, is it train, valid, or test;
2. **By what rule you split (rule)** — a time cutoff? an entity hash? a random seed? a dedup key?
3. **On which version of the data you split (version)** — which *moment* of `samples` this split applies to.

Most teams version only a sliver of rule #2 — the `random_state` in code — and almost never version #1 and #3. So "a reproducible split" becomes an empty phrase: the moment the underlying table changes, the same seed produces a different set of rows; and the most critical fact — "which sample belonged to which set at the time" — was never remembered by anything.

What you actually need to freeze is **membership + rule + the version of data it ran on**, all three together. That happens to be exactly what Git4Data can pin down. Below we first get the split wrong, see where it breaks, then pin all three down solidly.

---

## Five kinds of leakage, hands-on

Leakage — the ML term, not a security data breach — means: **using, at training time, information you won't have at serving time.** Its classic symptom is the opening scene — inflated offline, sliding online. First, set up the case data.

Compared with the overview, `samples` here gains three keys that leakage detection needs: `user_id` (entity key — one person, many transactions), `event_key` (dedup key — one underlying event and its augmented copies), and `label_time` (when the truth became known, later than the event time).

```sql
CREATE TABLE samples (
    sample_id    BIGINT PRIMARY KEY,
    event_time   DATETIME,       -- when the transaction happened; also the feature cutoff
    user_id      BIGINT,         -- entity key: one person may have many
    event_key    VARCHAR(64),    -- dedup key: one underlying event / its augmented copies
    amount       DECIMAL(12,2),
    txn_count_7d INT,
    label        TINYINT,        -- 0=normal, 1=fraud, NULL=truth not back yet
    label_time   DATETIME,       -- when the label became known (later than event_time)
    label_source VARCHAR(32)
);
```

Case data: 100,000 transactions, 20,000 users (~5 each), spanning 121 days (`2026-03-01` to `2026-06-29`), with fraud truth returning 3 days after the event. Plus 2,000 **augmented near-duplicates** sharing an `event_key` with the originals. Taking "now = `2026-07-01`" as the cutoff, the most recent samples whose `label_time` hasn't arrived have no truth yet. Measured: **102,000** rows total, of which **101,158** are labeled and **842** are the recent "truth-not-back" rows.

### First, the anti-pattern: a naive random split

```sql
-- A split that ignores time and entity. We bucket on a DETERMINISTIC hash of
-- sample_id (reproducible run to run) instead of an unseeded rand(); it scatters
-- rows exactly the way a careless random split does.
INSERT INTO membership_rand
SELECT sample_id,
       CASE WHEN CONV(SUBSTR(MD5(CAST(sample_id AS CHAR)),1,8),16,10) % 10 < 8 THEN 'train'
            WHEN CONV(SUBSTR(MD5(CAST(sample_id AS CHAR)),1,8),16,10) % 10 = 8 THEN 'valid'
            ELSE 'test' END
FROM samples
WHERE label IS NOT NULL;
--   measured: train 80893 / valid 10229 / test 10036 — the proportions look fine.
```

The proportions are fine, but the three detectors below expose it.

### Leakage 1: temporal leakage (feeding the future to the past)

Fraud, recommendation, and risk are strongly temporal: you predict the **future** from the **past**. A random split scatters samples from different times, so `train` ends up with transactions later than those in `test` — letting the model peek at the future.

```sql
-- How many train rows are later than the earliest row in test?
SELECT COUNT(*) AS train_rows_from_the_future
FROM samples s JOIN membership_rand m ON s.sample_id = m.sample_id
WHERE m.split_name = 'train'
  AND s.event_time > (SELECT MIN(s2.event_time)
                      FROM samples s2 JOIN membership_rand m2 ON s2.sample_id = m2.sample_id
                      WHERE m2.split_name = 'test');
--   measured: 80205. Nearly all of train's 80k rows are later than test's start — total time travel.
```

Two things often get conflated here. A **feature** must be computable at each sample's own feature cutoff (`event_time`) — feeding in an **outcome** like "this one was later charged back" is textbook leakage (it's exactly what you don't have at serving time). A **label**, by contrast, is allowed to arrive late: `label_time` being a few days after `event_time` is normal. The requirement isn't "the label is known at `event_time`" but "the label has returned before the as-of cutoff used for this training round (here `2026-07-01`)." So the gate checks the latter — samples whose truth hasn't returned enter no set this round (that's how the 842 rows were excluded above).

### Leakage 2: entity leakage (the same person across sets)

The same `user_id`'s multiple transactions get split row by row, some into train, some into test. The model then learns "this person" rather than "this kind of behavior." Looks accurate offline, collapses the moment a brand-new user shows up online.

```sql
-- How many users appear in BOTH train and test?
SELECT COUNT(*) AS users_in_train_and_test FROM (
  SELECT s.user_id
  FROM samples s JOIN membership_rand m ON s.sample_id = m.sample_id
  WHERE m.split_name IN ('train', 'test')
  GROUP BY s.user_id
  HAVING COUNT(DISTINCT m.split_name) = 2
) t;
--   measured: 8213. Over 40% of the 20k users straddle train and test.
```

### Leakage 3: duplicate / augmentation leakage (one event torn apart)

Duplicate records of one underlying event, or near-duplicates from augmentation, get randomly torn into different sets. The test set now holds the "twins" of training samples.

```sql
-- How many event_keys landed in more than one split?
SELECT COUNT(*) AS event_keys_across_splits FROM (
  SELECT s.event_key
  FROM samples s JOIN membership_rand m ON s.sample_id = m.sample_id
  GROUP BY s.event_key
  HAVING COUNT(DISTINCT m.split_name) > 1
) t;
--   measured: 677. Of the 2000 augmented samples, 677 groups got separated from their originals.
```

One random split, all three detectors red. And all three are **structural leaks you can find with SQL directly on the split manifest**. Two more kinds of leakage live outside membership, but are just as fatal.

### Leakage 4: preprocessing leakage (statistics that peeked at valid / test)

Fitting standardization, target encoding, or missing-value imputation on the **full** data before splitting — the preprocessor's means, variances, and category frequencies already contain information from valid and test. The correct order is the reverse: **`fit` on train only, then `transform` valid and test unchanged.**

This isn't something membership can check; it's process discipline. But a versioned split gives it a reliable footing: because train is read from a **fixed snapshot** by `split_name='train'`, you can guarantee "the preprocessor was fit on exactly these train rows, and these rows are bit-for-bit reproducible later" — not on some drifting subset from one notebook run.

### Leakage 5: target leakage (the answer sneaks into the features)

A field that correlates strongly with the label but isn't available at serving time sneaks into the features. In fraud, the classic is using "already charged back / manual-review verdict" to predict fraud — those are **outcomes**, not **prior features**. The symptom is one feature with absurdly high importance and an offline AUC that's too good to be true.

This too is outside membership; it's feature-provenance auditing. And that's exactly where [Part 7 Write-Audit-Publish](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part7-write-audit-publish/index.md) helps: when and by whom a "suspiciously good" feature column entered the main table is one `DATA BRANCH DIFF` away, not a matter of memory.

---

## Getting the split right: time-based, then drive the detectors to zero

For this risk case, the correct primary split is **by time** — train on earlier data, validate and test on later windows, modeling "predict the future from the past." The split rule, together with the time cutoffs, is written explicitly into `dataset_membership`.

```sql
INSERT INTO dataset_membership
SELECT sample_id,
       CASE WHEN event_time <  '2026-06-05' THEN 'train'
            WHEN event_time <  '2026-06-17' THEN 'valid'
            ELSE 'test' END,
       'time_split:v1 cutoffs=2026-06-05/2026-06-17; feature_cutoff=event_time; label_ready<=2026-07-01'
FROM samples
WHERE label IS NOT NULL;          -- the recent "truth-not-back" rows enter no set this round
--   measured: train 80950 / valid 10104 / test 10104, about 80 / 10 / 10.
```

Note two things: the rule **stores the time cutoffs, the feature cutoff, and the label-availability condition** — not just the three words train/valid/test; and the 842 "truth-not-back" rows are explicitly excluded, never slipped into training to pad the count.

Now re-run the two structural detectors:

```sql
-- Temporal leakage: zero
--   train_rows_from_the_future = 0    (all of train is earlier than test's start)
-- Duplicate leakage: zero
--   event_keys_across_splits    = 0   (same event_key shares event_time -> same set)
```

The time split resolves the "temporal" and "duplicate" leaks together. But **entity overlap, honestly, is not zero**:

```sql
-- Under the time split, how many users still straddle train and test?
--   users_in_train_and_test = 9912
```

This isn't a bug; it's a tradeoff worth spelling out. Under a time split, a "returning customer" with early transactions in train and later ones in test naturally straddles the boundary. **For a business like fraud, this is exactly realistic** — online you *do* keep meeting returning users, and letting the model see their history isn't cheating. So the right move here isn't to eliminate it, but to **report and accept it**.

Only when the task itself requires "entity disjointness" (e.g. leave-one-user-out evaluation, or a hard ban on the model memorizing individuals) do you switch to an **entity-hash** split: send all of a user's rows into the same set.

```sql
INSERT INTO membership_entity
SELECT sample_id,
       CASE WHEN user_id % 10 < 8 THEN 'train'
            WHEN user_id % 10 = 8 THEN 'valid'
            ELSE 'test' END
FROM samples WHERE label IS NOT NULL;
--   now users_in_train_and_test = 0, at the cost of strict time ordering.
```

**Time split** and **entity split** often can't both be had; which you pick depends on whether your business meets returning users in the future. Git4Data doesn't make that call for you — what it guarantees is that whichever rule you choose, this membership is pinned down completely and reproducibly, and can be audited row by row before release.

---

## The release gate: a split checklist that's all SQL

[Part 7's Write-Audit-Publish](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part7-write-audit-publish/index.md) keeps bad data out of production; the same idea applies directly to **splits**: audit the split manifest in a workspace first, and only publish it as a named version once it's all green. Every check is SQL, and every one must pass:

```sql
-- ① time monotonic: train must not be later than test's start   -> expect 0
-- ② entity overlap: 0 or a "known acceptable value" per the task -> recorded
-- ③ no duplicate across sets: an event_key in only one set       -> expect 0
-- ④ no label from the future: labeled rows' label_time <= cutoff -> expect 0
SELECT COUNT(*) AS label_from_future
FROM samples s JOIN dataset_membership m ON s.sample_id = m.sample_id
WHERE s.label IS NOT NULL AND s.label_time > '2026-07-01';   -- measured 0

-- ⑤ set sizes and proportions within a sane band (guards empty set / imbalance)
SELECT m.split_name, COUNT(*) AS n,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM dataset_membership), 1) AS pct
FROM dataset_membership m GROUP BY m.split_name;
--   measured train 80.0% / valid 10.0% / test 10.0%

-- ⑥ every set has positives (guards a set with no fraud samples -> metrics meaningless)
SELECT m.split_name, AVG(s.label) AS pos_rate
FROM samples s JOIN dataset_membership m ON s.sample_id = m.sample_id
GROUP BY m.split_name;
--   measured pos_rate 0.5 in all three sets, balanced
```

Plus one process convention (leakage #4): **the preprocessor is fit on `train` only.** All green, then release. Any red, and you go back to `dataset_membership` and fix the rule — the mainline doesn't move a row.

---

## Release: freeze the samples and the split into one version

The sample content and the split manifest must be released as **one whole** — snapshotting the two tables separately could land at different moments and misalign. Here we use a database-scope snapshot to freeze all of `risk_ml` at once:

```sql
CREATE SNAPSHOT risk_dataset_v1 FOR DATABASE risk_ml;
```

![Dataset release: one database-scope snapshot freezes samples and dataset_membership together; train/valid/test are released consistently in one version, split by time and past the audit gate](./images/fig_split-release_en.svg)

Afterward training, tuning, and final testing all read from the **same dataset version**, changing only `split_name`:

```sql
-- the trainer reads train (valid / test the same, just change split_name)
SELECT s.*
FROM samples {SNAPSHOT='risk_dataset_v1'} s
JOIN dataset_membership {SNAPSHOT='risk_dataset_v1'} m ON s.sample_id = m.sample_id
WHERE m.split_name = 'train';
--   measured train 80950 rows.
```

This database-scope snapshot doesn't physically copy the whole database; it establishes a named version of the tables' consistent state at that moment — as [Part 3](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part3-under-the-hood/index.md) explained, MatrixOne's immutable objects plus a metadata catalog make snapshot cost nearly independent of data size. Now what's reproducible isn't only "which samples exist," but "what role each sample played in this experiment." To reproduce three months later, `SELECT ... {SNAPSHOT='risk_dataset_v1'}` in one line, bit-for-bit identical.

---

## Version evolution: is it the ruler that changed, or the model?

Later you find the test set is short on hard samples and want to move 500 into test. The right move isn't to overwrite v1, but to release `risk_dataset_v2` and bind the new metrics explicitly to v2:

```sql
UPDATE dataset_membership SET split_name = 'test',
       split_rule = 'time_split:v2 + 500 hard cases moved to test'
WHERE sample_id IN (SELECT sample_id FROM dataset_membership WHERE split_name = 'train' LIMIT 500);

-- relative to the released v1, what exactly did the split change?
DATA BRANCH DIFF dataset_membership
  AGAINST dataset_membership {SNAPSHOT='risk_dataset_v1'} OUTPUT SUMMARY;
--   measured UPDATED = 500 (INSERTED 0 / DELETED 0) — exactly the 500 moved rows.

CREATE SNAPSHOT risk_dataset_v2 FOR DATABASE risk_ml;
```

This one DIFF settles a question that's usually waved away: the metric moved — was it the **model** that changed, or the **ruler**? If test's membership, labels, or evaluation protocol changed, v2's score is still valid, but it's no longer a like-for-like comparison with v1. So cross-version trends should be compared first on an **unchanged fixed test set / golden set**, while the new time window is reported as a separate metric. To square this with the opening principle: **feature, hyperparameter, and model selection look only at the validation set**; this test set that changes every round is really a **rolling evaluation window** across versions — for watching a new time period, not the "measure once after lock" unbiased ruler — while the genuinely unbiased final regression belongs on the kind of **long-lived fixed holdout / golden set** in the next section. And v1 remains queryable and reversible, untouched:

```sql
-- query each in its OWN statement (one snapshot per statement)
SELECT split_name, COUNT(*) FROM dataset_membership {SNAPSHOT='risk_dataset_v1'} GROUP BY split_name;
--   test 10104 / train 80950 / valid 10104   <- v1 unchanged, bit-for-bit
SELECT split_name, COUNT(*) FROM dataset_membership {SNAPSHOT='risk_dataset_v2'} GROUP BY split_name;
--   test 10604 / train 80450 / valid 10104   <- v2 reflects the move
```

Mapped onto the primitives, the whole life of a split is natural:

```text
one split          = one dataset_membership + rule
pin a split        = snapshot (database-scope, freezing samples along with it)
read a set         = SELECT … {SNAPSHOT} WHERE split_name = …
what the split did  = DATA BRANCH DIFF (ruler-changed vs model-changed)
discard a split    = RESTORE to the previous version
```

---

## The discipline of the golden set

Besides the test set that changes every iteration, many teams keep a long-lived **golden evaluation set**: covering key cohorts, rare risks, and business red lines, used specifically for regression across model versions. Its whole value is in "stable" — **never retrained on, changed as little as possible.**

A snapshot manages it best: pin the golden set as a long-retained named version whose content is reproducible and whose edits are detectable (traceable, tamper-evident). To be precise, a snapshot only buys traceability — it does not by itself stop someone with read access from querying it and training on it; actually preventing misuse needs access isolation plus training-pipeline auditing. The day it truly must be updated (e.g. adding a new fraud pattern), that's an explicit `golden_v2` release plus a re-baselining, not a few silent edits in place — otherwise you'll find "the model gained 2 points on the golden set" was really the golden set loosening on its own. Before release, one DIFF likewise confirms it hasn't intersected the current train.

---

## The industry's other approaches to splits and leakage

First, to be clear: pinning "this version of the dataset" so you can return to it is well-served by several mature tools, each with real strengths. The point here isn't to dismiss them, but to name an often-overlooked difference — **whether the "which sample belongs to train / valid / test" membership is first-class relational data, living in the same database as the samples, frozen by the same snapshot, and auditable for leakage directly in SQL.** By that yardstick, one by one:

**Notebook random split (`train_test_split`).** Membership hides in the code's `random_state` — not queryable data at all, and not bound to the data version. This is what fell over at the start.

**A stored `split` column / a re-run split query.** Membership becomes a column — better; but it isn't frozen into a version alongside the samples, so re-running on a changed table changes it.

**Data / dataset version tools (DVC, lakeFS, Delta Lake).** All can pin "this version of the dataset" and return to it — their shared strength, each with highlights: **lakeFS offers git-style zero-copy branching over object storage** (not a full data copy per version); **Delta Lake's Change Data Feed exposes row-level insert / update / delete between versions**; DVC does file-level versioning. They solve the data / file-version layer; "which sample belongs to which set" is a modeling concept you usually build on top, and leakage checks (same user across sets, event_key across sets) are done separately after reading the data out.

**Feature platforms (Feast, Tecton).** Their strength is **point-in-time correctness** — feature joins by event time, handling "future feature" temporal leakage well, which deserves credit. They focus on features; split-membership governance usually sits outside.

**Experiment trackers (MLflow, W&B).** These record data too: **MLflow's `mlflow.data` logs a dataset's source and digest (content fingerprint)**, and **W&B Artifacts are versioned with lineage**. They solve the traceability of "which one did this run use" well; what's recorded is a reference plus a fingerprint, not a live table you can JOIN against the current database or row-diff between two versions.

Put in one table (each tool's real strength noted):

| Approach | Form of membership | Same DB & snapshot as samples | Row-level "who moved between sets" | Leakage checks |
|---|---|---|---|---|
| Notebook random split | code's `random_state` | No | No | on discipline |
| Stored column / re-run SQL | a table column | No (not frozen with a version) | No | write your own |
| DVC | versioned files | No (files divorced from live table) | file level | scripts over files |
| lakeFS | object/path versions (**zero-copy branching**) | No (objects divorced from live table) | object/path level | hooks / scripts on objects |
| Delta Lake | table versions + **CDF** | No (a separate table / lake) | **row-level (CDF)** | Spark / SQL (lake side) |
| Feature platforms (Feast/Tecton) | materialized training set | partial | No | **strong on temporal** |
| Experiment trackers (MLflow/W&B) | dataset digest / Artifact version | No | No (reference + fingerprint) | separate |
| **MatrixOne (Git4Data capability)** | **a relational table `dataset_membership`** | **Yes (same DB, same snapshot)** | **Yes (`DATA BRANCH DIFF`)** | **SQL in the same DB, on the versioned dataset** |

So MatrixOne's difference isn't "can you version data" — the tools above each version data, some very capably. Its place is this: **treat split membership as first-class relational data, in the same database as the samples and frozen by the same snapshot, so that "same user across sets," "event_key across sets," and "is a label from the future" are a few JOINs and anti-joins run directly on the versioned dataset — and cross-version "who moved between sets" is one row-level `DATA BRANCH DIFF`.** The split turns from the pipeline's most unmanaged step into a first-class citizen: co-versioned with the data, queryable, auditable.

---

## Boundaries and applicability

- **Random splitting isn't the original sin.** If the data is genuinely i.i.d. with neither entity structure nor temporal structure (many pure tabular tasks are), a random split is perfectly fine. Leakage comes from "the data has structure, but the split pretends it doesn't."

- **`random_state` doesn't fix everything.** It only fixes "how to sample," not "which version of the table to sample from." Change the underlying table and the same seed is a different set of rows — so true reproducibility comes from pinning the data version too, not just recording a seed.

- **Snapshots have retention cost.** A pinned historical version occupies storage until `DROP SNAPSHOT`. Retain the `dataset_vN` for each shipped model long-term, and set a cleanup policy for abandoned intermediate versions.

- **Row-level operations require a consistent schema** (the boundary from [Part 4](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part4-landscape/index.md)): to add a feature column to the training set, do a controlled schema migration on the mainline first, then continue.

---

## Closing

The split is the foundation of offline evaluation. What `random_state` gives you is "looks reproducible"; a split that's truly reproducible and trustworthy pins **membership, rule, and data version** together, audits each item before release, and can roll back when something goes wrong.

MatrixOne, through its Git4Data capability, puts these three into the database — the split manifest is released consistently with the samples and labels in one version, every change leaves a DIFF as its receipt, and every historical version can be reconstructed bit-for-bit. Whether that "medical exam" can be trusted finally has a definite answer.

Next, we leave structured tables for the world of large models: **SFT data curation** — how to dedup, filter, and decontaminate hundreds of thousands of instruction records entirely in SQL, with a DIFF as the receipt for every cut.

> 📎 Runnable SQL: [github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ Source & community: [github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)


---

## References

- scikit-learn — data leakage & common pitfalls: <https://scikit-learn.org/stable/common_pitfalls.html#data-leakage>
- lakeFS — zero-copy branching: <https://docs.lakefs.io/understand/how/branches.html>
- Delta Lake — Change Data Feed (row-level changes between versions): <https://docs.delta.io/latest/delta-change-data-feed.html>
- MLflow — dataset tracking (`mlflow.data`): <https://mlflow.org/docs/latest/tracking/data-api.html>
- Weights & Biases — Artifacts: <https://docs.wandb.ai/guides/artifacts>
- Feast — point-in-time joins: <https://docs.feast.dev/getting-started/concepts/point-in-time-joins>
- Companion runnable script (verified on MatrixOne 4.1.0): [`09-dataset-release/dataset_release_demo.sql`](https://github.com/matrixorigin/git4data-tutorial/blob/d47dc1b811a19bc1b278b29cdd8a9d1e07b7988a/09-dataset-release/dataset_release_demo.sql)

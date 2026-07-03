# MatrixOne Git4Data Deep Dive (Part 8) · AI Training in Practice — ML Continuous Learning: Train Only What Changed

With this part the series enters **AI training.** Start with a loop every ML engineer knows:

> The data changes every day — new samples arrive, old labels get corrected. So every week (or every day) you feed the **entire** dataset back into the model and retrain from scratch. Once the data reaches the tens of millions, the loop gets ever more expensive and slow — but you don't dare skip it, because **you can't say precisely which data changed this week.**

The root problem isn't training, it's the data side: **there's no precise answer to "what moved since the last run."** And that is exactly what MatrixOne's git4data capability is best at. This article does the loop in detail, and **compares, one by one, where the other approaches get stuck.** Every statement is verified on MatrixOne `4.0.0-rc3`.

> 📦 All SQL runs as one script: [matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial), under `08-ml-incremental/`. Environment: `docker run -d -p 6001:6001 --name matrixone matrixorigin/matrixone:4.0.0-rc3`.

---

## When do you do continuous learning?

**Any time a model's training data keeps growing and you retrain on a cadence, you're doing continuous learning** — the only question is whether you *retrain on everything each time* or *train only the delta*. Typical cases:

- **Risk / fraud**: new transactions and freshly-labeled fraud samples arrive daily; the model updates with them;
- **Recommendation / CTR**: impression-click data streams in, features and labels shift every day;
- **Content moderation / classifiers**: QA keeps correcting mislabels and adding new classes;
- **Any supervised task whose labeled set is growing**: appending new samples and correcting old labels is the norm.

When the data is small, a full retrain is fine — a few minutes. **The pain starts at "the table is tens of millions / billions of rows, and retraining is a daily job":** a full retrain takes hours and burns real compute, and 99% of the data is **identical** to last round. You want to train only that 1% of change — but you lack a reliable answer to **which rows actually changed.** The three-step loop below turns that answer into one SQL statement.

---

## The three-step loop: pin → train → DIFF the delta

The training set is a `samples` table; next to it, a model registry `model_registry`.

### Step 1: pin a version before training

```sql
CREATE SNAPSHOT train_v1 FOR TABLE mltrain_demo samples;   -- milliseconds, near-zero cost
-- (the trainer reads the table, fits model m1 …)
INSERT INTO model_registry VALUES ('m1', 'train_v1', 0.9012);
```

Milliseconds, almost no space (Part 3's mechanics), but it turns "what data trained m1" from a verbal claim into an **executable fact**: at any time, `SELECT … FROM samples {SNAPSHOT='train_v1'}` reconstructs m1's training set, bit for bit.

### Step 2: a week later — the data moved, but where?

A week of real life: a 3000-row batch arrives, and QA corrects 200 labels:

```sql
INSERT INTO samples SELECT 100000 + result, … FROM generate_series(1, 3000) g;  -- new data
UPDATE samples SET label = 1 - label WHERE sample_id BETWEEN 500 AND 699;        -- label fixes
```

Now the key question — **relative to m1's training set, what exactly changed?** One DIFF:

```sql
DATA BRANCH DIFF samples AGAINST samples {SNAPSHOT='train_v1'} OUTPUT SUMMARY;
--   INSERTED = 3000   (the new batch)
--   UPDATED  =  200   (the corrected labels)
--   DELETED  =    0
```

Row-precise: **the change is these 3,200 rows; the other 100,000 didn't move.** Pull that delta (new + changed rows) and feed it to `partial_fit` (scikit-learn) or your incremental trainer:

```sql
-- The incremental training set = rows new or changed vs train_v1 (net, by value)
SELECT * FROM samples cur
WHERE NOT EXISTS (
    SELECT 1 FROM samples {SNAPSHOT='train_v1'} base
    WHERE base.sample_id = cur.sample_id
      AND base.f1 = cur.f1 AND base.f2 = cur.f2 AND base.label = cur.label
);
--   Measured: 3200 rows; a full retrain would process the whole 103000-row table.
```

A full retrain touches **103,000** rows; incremental touches **3,200** — 97% saved in one round. (`DATA BRANCH DIFF … OUTPUT FILE '/some-dir'` can also export that delta straight to a `.sql` for a downstream pipeline.)

### Step 3: after training, pin again

```sql
CREATE SNAPSHOT train_v2 FOR TABLE mltrain_demo samples;
INSERT INTO model_registry VALUES ('m2', 'train_v2', 0.9145);
```

The registry accumulates a **model ↔ data chain**:

```
m1 ← train_v1 (100,000 rows)
m2 ← train_v2 (103,000 rows) = train_v1 + 3000 new + 200 corrected
```

That chain unlocks moves you normally can't make:

- **Exact reproduction**: three months on, an audit asks "what trained m1?" — `SELECT … {SNAPSHOT='train_v1'}` answers, bit for bit (measured: the full 100k restored intact);
- **Attributable debugging**: m2 worse than m1? DIFF the two snapshots — the suspect set is those 3,200 rows, not a needle in 100k;
- **Data rollback**: the label "corrections" turn out wrong? `RESTORE TABLE … {SNAPSHOT = train_v1}` and start over.

![The three-step continuous-learning loop: pin a snapshot before training, register model↔data after, DIFF the delta next round and train only the change; snapshots are milliseconds, DIFF tracks only the change volume](./images/fig_incremental-loop_en.svg)

---

## How much does this actually save?

We quantified it in the companion experiment: the same continuous-learning scenario over **6 rounds**, each round adding ~1000 rows plus a few label corrections. Result —

- **Full retrain**: each round processes the **whole current table** → **21,000** rows over 6 rounds;
- **Train only the delta**: each round processes only that round's change → **6,004** rows over 6 rounds.

The point isn't this round's 3.5×, it's the **trend**: full-retrain cost grows **quadratically** with rounds (the table keeps growing, and every round starts over), while incremental stays roughly **linear** — it only ever sees this round's change. **The longer the loop runs and the bigger the data, the more it saves.** In the experiment each round's delta stayed at "about 1000 rows" even when the whole table was already 6× that.

![Cost: full retrain processes the whole table each round, cumulative area swelling quadratically; incremental processes only the current round's change, cumulative roughly linear — 6,004 vs 21,000 rows over 6 rounds](./images/fig_cost-curve_en.svg)

---

## How do the alternatives do it — and where do they break?

"Isn't finding the changed rows just a timestamp away?" It's worth laying out the common approaches — each works, and each gets stuck somewhere.

**Approach A: full retrain every time (the baseline).** Simplest and dearest: O(N) each round, growing without bound, ever-slower feedback. Fine when small, pure burn when big.

**Approach B: an `updated_at` watermark.** Add `updated_at`, remember "last trained up to time T," next round `WHERE updated_at > T`. Sounds enough, several traps: **misses deletes** (a DELETEd row won't show up past a watermark); **depends on end-to-end discipline** — any bulk backfill / correction that doesn't bump `updated_at` is silently missed; **a watermark is a moving pointer, not a version** — you can't "reproduce the exact set the last run used," nor diff two arbitrary past versions; and a row changed and reverted still counts.

**Approach C: CDC / binlog streaming (Debezium + Kafka).** Stream every row change out and consume the delta downstream. Problems: **heavy infra** (Kafka + Debezium + consumers); you get a **firehose of change events**, not "the net delta relative to a chosen training version"; to align "which version trained m1" you'd replay offsets; exactly-once is fiddly; a row changed 5× gives you 5 events. You now run a stream-processing pipeline just to know what changed.

**Approach D: keep two full copies + `EXCEPT` / anti-join.** Keep a full copy of last-train data, `SELECT … EXCEPT …` for the difference. Problems: **a full copy per training version → N× storage**; the diff is a **full scan of both copies** (O(N) — you touch all the data again just to find the delta); it doesn't scale as versions accumulate.

**Approach E: data-versioning tools.**
- **DVC**: versions **files** — any change makes a new dataset file and re-hashes it; you can diff file versions, but **not row-level** "which rows changed" — the grain is the whole file.
- **lakeFS**: versions files / paths in object storage; the diff is **object / file-level**, not rows.
- **Delta Lake (time travel + Change Data Feed)**: this one **can** give **row-level** changes between versions — the closest analog here. Differences: you must **enable CDF** (which writes extra change files), consume via Spark, lake / analytics-oriented; it gives **change events** (possibly intermediate states), not "the net diff vs a chosen snapshot"; and it isn't a live database still serving point reads.

| Approach | Captures ins/upd/del | Row-level net delta vs a chosen version | Cost to compute delta | Extra infra / storage | Reproduce training set bit-for-bit | Diff any two versions |
|---|---|---|---|---|---|---|
| A full retrain | — (no distinction) | — | O(N) each round | none | no | no |
| B updated_at watermark | ins / upd (**misses del**) | no (only "changed since") | O(delta) | maintain column + discipline | no | no |
| C CDC / binlog stream | ins / upd / del | no (event stream, not a net diff) | streaming | **heavy (Kafka+CDC)** | hard | hard |
| D two copies + EXCEPT | ins / upd / del | yes | **O(N) full scan** | **N× storage** | yes (kept a copy) | only if copies survive |
| E1 DVC / lakeFS | file / object level | no (not row-level) | file-level | another tool | yes (file versions) | file-level |
| E2 Delta CDF | ins / upd / del | events (may include intermediate) | Spark consume | enable CDF + Spark | yes (time travel) | version-level |
| **MatrixOne (git4data capability)** | **ins / upd / del** | **yes — one `DATA BRANCH DIFF … {SNAPSHOT}`** | **only the change volume** | **none (just SQL)** | **yes (snapshot, bit-for-bit)** | **yes (any two snapshots)** |

In one line: the others are either **only approximate** (watermark misses deletes, DVC isn't row-level), or **costly** (two full copies at N× storage, CDC's whole stream stack), or **on the lake needing a separate engine** (Delta CDF). MatrixOne collapses it into one SQL statement — relative to any pinned version, `DATA BRANCH DIFF` yields the **row-level net delta**, at a cost that tracks the change, not the table; and the same snapshot is both "the baseline for the delta" and "a bit-for-bit reproducible training-set version." That's what this capability buys inside an HTAP database: **versioning, the delta, and reproduction are three faces of one thing.**

---

## Cost and boundaries

- **Snapshots are milliseconds, independent of data size** (Part 3); **DIFF tracks only the change volume**, never a full scan. So the longer the loop runs and the bigger the table, the more it saves over full retrains.
- **DIFF reports "rows touched since the snapshot"** (by *was it changed*, not by value): for feeding incremental training that's exactly right — a touched row should be retrained. If you specifically want the **net value change** ("current value differs from the last version"), use the **value anti-join** above (it naturally excludes rows changed-and-reverted).
- **To reproduce, don't rush to drop snapshots**: a snapshot pins historical objects and holds storage until `DROP SNAPSHOT`. Keep each shipped model's `train_vN` long-term; set a cleanup policy for discarded intermediate versions.
- **Row-level DIFF requires a shared schema** (Part 4's boundary): to add a feature column, change the schema on mainline first, then continue.

---

## Closing

This whole article is a three-step loop:

```
①  CREATE SNAPSHOT train_vN             -- pin the data version before training
②  train → register (model, train_vN)   -- bind model to data version
③  next round: DIFF now AGAINST train_vN  -- the delta = exact changed rows → partial_fit
```

It saves more than compute — it hands you three things you normally **just can't get**: a model's **reproducibility**, a regression's **attributability**, and dirty data's **rollback**.

Next, the LLM context: **SFT data curation** — dedup, filtering, and decontamination over hundreds of thousands of instructions, all done in place with SQL, with a DIFF "receipt" for every cut: what was removed, why, and whether it can be undone.

> 📎 Runnable SQL: [github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ Source & community: [github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)

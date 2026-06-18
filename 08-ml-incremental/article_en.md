# MatrixOne Git4Data Deep Dive (Part 8): ML Continuous Learning — Train Only What Changed

With this part the series enters AI training. Start with a loop every ML engineer knows:

> The data changes every day — new samples arrive, old labels get corrected. So every week (or every day) you feed the **entire** dataset back into the model and retrain from scratch. Once the data reaches the tens of millions, the loop gets ever more expensive and slow — but you don't dare skip it, because **you can't say precisely which data changed this week.**

The root problem isn't training, it's the data side: **there's no precise answer to "what moved since the last run."** That is exactly what git4data provides.

> 📦 Full runnable SQL: [`08-ml-incremental/`](https://github.com/matrixorigin/git4data-tutorial) in the companion repo.

---

## Pin a version before every run

The training set is a `samples` table; next to it, a model registry. Before the first run, pin the data state:

```sql
CREATE SNAPSHOT train_v1 FOR TABLE mltrain_demo samples;
-- (trainer reads the table, fits model m1 ...)
INSERT INTO model_registry VALUES ('m1', 'train_v1', 0.9012);
```

Milliseconds, near-zero cost — but it turns "what data trained m1" from a verbal claim into an **executable fact**: at any time, `SELECT ... FROM samples {snapshot='train_v1'}` reconstructs m1's training set, bit for bit.

## A week later: the data moved — but where?

A week of real life: a 3000-row batch arrives, and QA corrects 200 labels:

```sql
INSERT INTO samples SELECT ... FROM generate_series(1, 3000) g;            -- new data
UPDATE samples SET label = 1 - label WHERE sample_id BETWEEN 500 AND 699;  -- label fixes
```

Now the key question — **relative to m1's training set, what exactly changed?** One DIFF:

```sql
DATA BRANCH DIFF samples AGAINST samples {SNAPSHOT='train_v1'} OUTPUT SUMMARY;
--   INSERTED = 3000   (the new batch)
--   UPDATED  =  200   (the corrected labels)
--   DELETED  =    0
```

The answer is row-precise: **the change is these 3,200 rows; the other 100,000 didn't move.** Pull them out with `OUTPUT LIMIT` / `OUTPUT FILE` and feed them to `partial_fit` (scikit-learn) or your incremental trainer — and full retrains are history.

We quantified this in the companion experiments: over 6 rounds of the same continuous-learning scenario, the incremental approach processed **6,012 rows total** where full retrains would have processed **21,000** — and the gap grows **quadratically** with rounds (the dataset keeps growing, full retrains keep getting dearer; the incremental path only ever sees this round's changes).

## After training, pin again

```sql
CREATE SNAPSHOT train_v2 FOR TABLE mltrain_demo samples;
INSERT INTO model_registry VALUES ('m2', 'train_v2', 0.9145);
```

The registry accumulates a **model↔data chain**:

```
m1 ← train_v1 (100,000 rows)
m2 ← train_v2 (103,000 rows) = train_v1 + 3000 new + 200 corrected
```

That chain unlocks moves you normally can't make:

- **Exact reproduction**: three months on, an audit asks "what trained m1?" — `{snapshot='train_v1'}` answers, bit for bit;
- **Attributable debugging**: m2 worse than m1? DIFF the two snapshots — the suspect set is those 3,200 rows, not a haystack;
- **Data rollback**: the label "corrections" turn out wrong? `RESTORE` to train_v1 and start over.

---

## The pattern

This whole article is a three-step loop:

```
①  CREATE SNAPSHOT train_vN            -- pin the data before training
②  train → register (model, train_vN)  -- bind model to data version
③  next round: DIFF now AGAINST train_vN  -- the delta = exact changed rows → partial_fit
```

On cost: snapshots are milliseconds regardless of data size (Part 3's mechanics), and DIFF tracks only the change volume. Meaning: **the longer this loop runs and the bigger the data grows, the more it saves over full retrains.**

Next, the LLM context: **SFT data curation** — dedup, filtering, and decontamination done in place with SQL, with a DIFF "receipt" for every cut.

> 📎 Runnable SQL: [github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ Source & community: [github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)

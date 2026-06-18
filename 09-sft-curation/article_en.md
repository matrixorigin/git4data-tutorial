# MatrixOne Git4Data Deep Dive (Part 9): SFT Data Curation — A Receipt for Every Cut

There's a consensus in the LLM world: **the model's ceiling is set by the data, and the data's ceiling is set by curation.** SFT (supervised fine-tuning) especially — across hundreds of thousands of instruction pairs, what actually decides quality is how cleanly you dedup, how ruthlessly you filter, and whether the eval set leaked into training.

Yet the everyday curation toolchain is awkward: JSONL files plus a pile of pandas scripts. Every pass drops a new file — `sft_v3_dedup_filtered_final.jsonl` — and three weeks later nobody can say: what got deleted between v2 and v3? why? can it be undone?

Put the data in git4data and each of those questions becomes one SQL statement.

> 📦 Full runnable SQL: [`09-sft-curation/`](https://github.com/matrixorigin/git4data-tutorial) in the companion repo.

---

## Before any cutting, pin the raw pool

100k raw SFT samples (instruction, response, quality score, source), with all the diseases of real data: ~20% duplicate instructions, scattered quality, and 300 eval-set prompts mixed in:

```sql
CREATE SNAPSHOT sft_raw FOR TABLE sft_demo sft_samples;
```

Milliseconds. From here on, however hard the later cuts go, the raw pool is always one statement away. **Curation turns from an irreversible destructive operation into an experiment you can always take back.**

## Three cuts, all in place

No exports, no intermediate files — SQL operates on the table directly:

```sql
-- Cut 1: dedup — keep the earliest row per instruction
DELETE FROM sft_samples
WHERE id NOT IN (
  SELECT * FROM (SELECT MIN(id) FROM sft_samples GROUP BY instruction) keep
);

-- Cut 2: quality floor — everything under 3.0 is out
DELETE FROM sft_samples WHERE quality < 3.0;

-- Cut 3: decontaminate — anything overlapping the eval set, gone
DELETE FROM sft_samples
WHERE instruction IN (SELECT instruction FROM eval_set);
```

Cut 3 deserves a note: **eval-set leakage** is SFT's most insidious accident — inflated scores that collapse in production. When the eval set is just another table in the database, decontamination is an `IN` subquery, and it can run routinely on every curation pass.

## The receipt: what exactly did this version remove?

Curation done, ask the question the file-based workflow can't answer:

```sql
DATA BRANCH DIFF sft_samples AGAINST sft_samples {SNAPSHOT='sft_raw'} OUTPUT SUMMARY;
--   DELETED = exactly the rows curation removed
```

`OUTPUT LIMIT` shows the removed rows one by one — **every cut is accounted for.** That's what "receipt" means: curation stops being a black box; a colleague can review what you deleted row by row, the way they'd review a PR.

Confirmed? Pin the curated result as the training version:

```sql
CREATE SNAPSHOT sft_v1 FOR TABLE sft_demo sft_samples;
-- This SFT run trains on sft_v1 — pair it with Part 8's model registry and
-- the version loop closes
```

Cut too deep? One statement back to the raw pool:

```sql
RESTORE TABLE sft_demo.sft_samples {SNAPSHOT = sft_raw};
```

---

## File workflow vs. git4data workflow

| | JSONL + scripts | git4data |
|---|---|---|
| Each pass | drops a new file | in-place SQL |
| "What got deleted" | eyeball-diff two big files | `DIFF ... OUTPUT SUMMARY/LIMIT` |
| Undo a cut | find the previous file (if it survived) | `RESTORE {SNAPSHOT}` |
| Version management | filename taxonomy | named snapshots |
| Reproduce a training run | pray the file wasn't overwritten | `{snapshot='sft_v1'}` |

From the companion experiments, one quantified run: the same 8,000-row curation (dedup + filter + decontaminate) completed in-place in **410 ms**, with DIFF attributing DELETED=4,836 — every single row nameable.

---

## Closing

SFT curation is fundamentally **subtraction**, and subtraction's great fear is "cut wrong, can't explain, can't undo." Snapshots give you the undo, DIFF gives you the receipt, in-place SQL removes the file shuffling — together, curation becomes an auditable, iterable, collaborative engineering activity.

Speaking of collaboration — next time we face curation's most human-heavy stage head-on: **collaborative labeling**. Multiple annotators labeling at once; what happens when they disagree? Spoiler: the disagreement itself *is* the merge conflict.

> 📎 Runnable SQL: [github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ Source & community: [github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)

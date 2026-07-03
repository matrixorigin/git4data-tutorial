# MatrixOne Git4Data Deep Dive (Part 7) · Data Operations in Practice — Write-Audit-Publish: A Release Gate for Your Data Pipeline

Data pipelines have a perennial problem: **you don't control upstream data quality, but you own the fallout.**

3 a.m. A scheduled ETL pours yesterday's fresh batch into the production table `events` — which reports, dashboards, downstream jobs, and a feature pipeline all read. The batch is laced with what upstream loves to produce: null `user_id`s, negative amounts, absurd outliers, users that don't exist in the dimension. By the time someone notices in the morning, the standup dashboard has computed wrong numbers, downstream jobs have run on it, a model has trained a round on it. Then the harder part: **the dirty rows are now mixed into the same table as the good ones**, and picking them back out is ten times harder than blocking them would have been — that's Part 5's incident rescue all over again.

Software engineering's standard answer to this class of problem is the **CI gate**: code must pass tests before it merges to main. The data world's counterpart is **Write-Audit-Publish (WAP)** — new data lands in isolation, passes an audit, then publishes. It used to take lake-side tooling (Iceberg, lakeFS) to build; with git4data it's just a basic use of branches. This article does it in detail: **when you need it, how the three steps land, and why the alternatives don't hold up.** Every statement is verified on MatrixOne `4.0.0-rc3`.

> 📦 All SQL runs as one script: [matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial), under `07-write-audit-publish/`. Environment: `docker run -d -p 6001:6001 --name matrixone matrixorigin/matrixone:4.0.0-rc3`.

---

## When do you actually need WAP?

WAP isn't for every table — it treats one situation: **a table with downstream consumers that receives new data from a source you don't fully trust.** Meet those two conditions and it wants a gate. Typical cases:

- **A daily / hourly ETL batch load**: a table that reports, dashboards, and downstream jobs read continuously, loaded in bulk overnight. One bad batch and the whole company sees wrong numbers in the morning.
- **Ingesting an external source you don't control**: a partner feed, a third-party API, scraped data, user uploads — quality varies, and fine today can be broken tomorrow when upstream renames a field.
- **Feeding a training / feature pipeline**: dirty data doesn't error out; it just **silently trains the model crooked** (exactly what last article's feature table dreads).
- **Publishing a canonical metrics table many people depend on**: one wrong definition and a whole tree of consumers is wrong with it.
- **Reverse ETL back into operational systems**: pushing computed results back to a production DB, to marketing / risk systems — a bad push has real consequences.

What they share: **once the problem data is in the production table, the damage is already done** (consumers read it, decisions were made, the model trained). WAP's whole value is moving "catch the problem" from *after* production to *before* publish.

---

## The three steps: Write → Audit → Publish

Let's walk all three on a real table. Production `events` holds 100k rows of yesterday's clean data, read continuously downstream; a dimension `dim_users` exists that the fact's `user_id` must stay consistent with.

### Write: new data always lands on a staging branch

Today's batch **never touches production directly**. Open a staging branch off it — milliseconds, zero-copy (Part 3 explained why) — and load the batch onto that branch:

```sql
DATA BRANCH CREATE TABLE events_stage FROM events;   -- staging branch, milliseconds

-- Today's 5000-row batch lands on staging, laced with what upstream really produces:
-- null user_ids, users absent from the dimension, negatives, absurd outliers
INSERT INTO events_stage
SELECT 200000 + result,
       CASE WHEN result % 97 = 0 THEN NULL
            WHEN result % 89 = 0 THEN 999999          -- a user not in dim_users
            ELSE result % 5000 END,
       CASE WHEN result % 250 = 0 THEN -1.00
            WHEN result % 333 = 0 THEN 999999.99
            ELSE round(rand()*500 + 1, 2) END,
       'paid', '2026-06-30'
FROM generate_series(1, 5000) g;
```

Right now `events` hasn't moved a row; downstream still reads yesterday's clean data. The dirty data is quarantined on staging — WAP's first principle: **isolation before quality.**

### Audit: SQL is the quality gate

The audit is a set of SQL assertions run against staging — **each should return 0**; if any is non-zero, the gate doesn't open. A decent audit covers a few classes of check:

```sql
-- 1) Completeness + domain + business rules: key fields non-null, sane amounts, valid status
SELECT
  SUM(CASE WHEN user_id IS NULL THEN 1 ELSE 0 END)  AS null_user,
  SUM(CASE WHEN amount  < 0     THEN 1 ELSE 0 END)  AS negative_amount,
  SUM(CASE WHEN amount  > 10000 THEN 1 ELSE 0 END)  AS outlier_amount,
  SUM(CASE WHEN status NOT IN ('paid','refunded','void') THEN 1 ELSE 0 END) AS bad_status
FROM events_stage WHERE ts = '2026-06-30';

-- 2) Referential integrity: every user_id in the batch must exist in the dimension
SELECT COUNT(*) AS orphan_users
FROM events_stage s LEFT JOIN dim_users d ON s.user_id = d.user_id
WHERE s.ts = '2026-06-30' AND s.user_id IS NOT NULL AND d.user_id IS NULL;

-- 3) Volume: today's batch size must sit in a sane band (guards double-load / empty run)
SELECT COUNT(*) AS batch_rows FROM events_stage WHERE ts = '2026-06-30';
```

Measured against this dirty batch, the gate catches the problems one by one:

| Check | Result |
|---|---|
| `null_user` | **51** ✗ |
| `negative_amount` | **20** ✗ |
| `outlier_amount` | **15** ✗ |
| `orphan_users` (not in the dimension) | **56** ✗ |
| `batch_rows` (volume) | 5000 ✓ |

**The gate does not open.** You can bolt on more checks here — **uniqueness** (no dup primary / natural key: `GROUP BY key HAVING COUNT(*) > 1`), **freshness** (`MAX(ts)` must be today), **distribution drift** (this batch's null rate / mean amount vs history). They're all just SQL; add what you need.

### When the gate fails: reject it, production none the wiser

Here's the crux: **when the gate fails, you do nothing to production — because production never touched this batch.** Just throw the staging branch away:

```sql
DROP TABLE events_stage;                                -- reject this batch
SELECT COUNT(*) FROM events;                            -- still 100000, not a row moved
SELECT COUNT(*) FROM events WHERE ts = '2026-06-30';    -- 0, this batch never got in
```

Measured: after the rejection production is still **100k rows**, and today's dirty batch put **zero rows** into production. Next you go debug upstream, fix it, and re-run — instead of doing incident rescue on a live table.

> Want to debug the scene? **Don't DROP — just keep the staging branch.** It's a complete, isolated crime scene; you can pore over exactly what upstream sent, with zero impact on production.

### Publish: passes the audit, one atomic publish

Swap in the fixed, clean batch — the audit is all green now (`null_user / negative / outlier / orphan` all 0, `MAX(ts)` is today). Before publishing, use DIFF for one last look at what this batch will *actually* do to production — row-level, exact:

```sql
DATA BRANCH DIFF events_stage AGAINST events OUTPUT SUMMARY;   -- INSERTED 5000: exactly these 5000 rows
```

All confirmed — one atomic merge:

```sql
DATA BRANCH MERGE events_stage INTO events;
```

This step is **atomic**: downstream readers see either the whole audited batch of 5000 rows, or (before this statement) none of it — **there is no "half-published" state**. Measured:

```sql
SELECT COUNT(*) FROM events;                                                    -- 105000
SELECT COUNT(*) FROM events WHERE user_id IS NULL OR amount < 0 OR amount > 10000;  -- 0
```

Production went from 100k to 105k, and not one dirty row ever appeared in it.

![Write-Audit-Publish: the batch lands on a staging branch and runs an SQL audit gate; pass → atomic MERGE into production, fail → drop the branch — production is untouched throughout](./images/fig_wap-flow_en.svg)

---

## How do the alternatives do it — and where do they break?

"Isn't this just checking before you load? Why a whole process?" It's worth laying out the common approaches and where each gets stuck — you're probably using one of them.

**Approach A: load straight into production, check afterward (the most common).** `INSERT INTO events`, then run the checks. Fatal problem: **by the time the check finds the problem, the dirty data is already in production and already read downstream.** The dashboard computed wrong, the cache was warmed, downstream jobs ran on it, a model trained a round. Cleaning up now is Part 5's incident rescue — a rollback takes real new data with it, and surgical cleanup is slow and easy to miss. It's "publish, then pray."

**Approach B: blue/green or shadow table + rename swap.** Load into an `events_new`, validate, then `RENAME` it over `events`. A pile of problems: every run **full-copies** the whole table → double storage and slow; the rename **isn't atomic across multiple tables** (fact swapped, dimensions not yet → a torn intermediate state); **incremental / append** doesn't fit at all (you want to add today's 5000 rows but must rebuild the whole 100k-row table); and in-flight queries, cached table handles, indexes / permissions / constraints all have to be rebuilt on the new table.

**Approach C: a staging table + `INSERT … SELECT` into production.** Load a standalone staging table, validate, then `INSERT INTO events SELECT * FROM staging`. Problem: that final big `INSERT` **isn't itself an atomic publish** — while it runs, downstream reads a "half-loaded" production table; the data is **copied again**; if you're publishing updates / upserts rather than pure appends, the merge logic is complex and error-prone; and a mid-way failure is hard to roll back.

**Approach D: wrap it in a transaction (`BEGIN; load; audit; COMMIT / ROLLBACK`).** Right idea, steep cost: a long transaction on a live table **holds locks and bloats undo**, dragging concurrent reads and writes down with it; many warehouses have weak transactions or don't allow DDL in one; a big batch blows past its limits; and the whole table is effectively occupied during the audit.

**Approach E: bolt on a data-quality tool (dbt tests / Great Expectations / Soda).** These are great at *defining* checks, but the default timing is often "test *after* the data has already landed in the production table" (e.g. `dbt build` builds into the target, then runs tests) — the gate and the storage are separate things, and in that gap the dirty data may already have been read. To make it a true pre-publish gate you still need B/C's stage-then-swap underneath; so now you're maintaining another system and another layer of orchestration.

Side by side with git4data's WAP:

| Approach | Dirty data touches prod? | Atomic publish? | Extra storage | Reject / rollback | Incremental append | Complexity |
|---|---|---|---|---|---|---|
| A load then check | **Yes** (in first) | — | none | incident rescue | yes | low |
| B blue/green rename | no | single-table only, not multi | **2× (full copy)** | swap back | **N/A** | med-high |
| C staging + INSERT | exposed during publish | **no** (INSERT has a mid-state) | 2× | hard | yes | medium |
| D wrap in a txn | no | yes, but **locks / bloat** | none | ROLLBACK | yes | med (hurts live table) |
| E DQ tool bolted on | **often** (tests post-load) | depends on substrate | depends | depends | yes | high (extra system) |
| **git4data WAP** | **no** (prod never touched) | **yes, second-scale atomic** | **~zero (zero-copy branch)** | **just drop the branch** | **native** | **low (just SQL)** |

In one line: git4data gets all three hard things right at once — **isolation** via a zero-copy branch (no storage, instant), **publish** via a second-scale atomic MERGE (no half-published window, regardless of table size), and **rejection** via a single DROP (production never touched the batch at all).

![Two worlds: load-then-check — bad data enters production and is read downstream before you scramble to clean it; WAP — bad data stops at the gate, and production only ever serves clean data](./images/fig_where-bad-data-lands_en.svg)

---

## Publishing several tables together: a database snapshot as the backstop

If one release has to update the fact table and several dimensions and you want "all or nothing," snapshot the whole database before publishing, then `MERGE` table by table; if any step's audit or merge goes wrong, `RESTORE DATABASE db {SNAPSHOT = s}` rolls the entire database back to before the release — multi-table atomicity backstopped by the **database-level snapshot** from Part 5 (a single `DATA BRANCH MERGE` is itself table-level).

---

## Wiring it into the pipeline: CI/CD for data

This flow is built to automate — hang it on your scheduler / CI and every daily batch runs the loop:

1. **Write**: batch arrives → auto `DATA BRANCH CREATE` a staging branch for the day, load it.
2. **Audit**: auto-run the audit SQL; any assertion > 0 → fail.
3. **Publish / Reject**: all green → `DATA BRANCH MERGE` to publish; any red → **don't publish, alert, and keep the staging branch as the scene**.

The mental-model shift is the real point:

> Without WAP: the production table is data's **entry point**; quality problems get handled after they're in.
> With WAP: the production table is data's **exit point**; only data that passed the audit earns its way in.

That's **CI/CD for data**: fail the gate, and bad data doesn't even reach production's door.

---

## Cost and boundaries

- **The gate is nearly free**: the staging branch is milliseconds and zero-copy; the audit is plain SQL; the publish is one second-scale MERGE, independent of table size. This gate won't be your pipeline's bottleneck.
- **The audit is only as strong as the checks you write**: WAP gives you the mechanism to *reliably block*; *what* to block is yours to express in SQL. A good mechanism is no substitute for thinking through what "good enough to ship" means for this data.
- **Branches / snapshots hold storage until released**: objects pinned by a staging branch or snapshot aren't reclaimed by background GC; `DROP` after a rejection (and have a cleanup policy for scenes you keep).
- **Multi-table atomic publish** rests on a database snapshot (above); a single `DATA BRANCH MERGE` is table-level.
- **Row-level diff/merge requires a shared schema** (Part 4's boundary): if the batch adds a column, change the schema on mainline first, then load.

---

## Closing

That completes the data-operations trilogy: **a personal safety net** (Part 5 — you can always roll back in seconds), **team parallelism** (Part 6 — branch and merge), and **a production gate** (this part — dirty data can't get in). All three run on the same primitives — snapshot, branch, diff, merge — which is the whole point of "version control inside the database": not one more feature, but a different way of working.

Next, the series turns to **AI training.** First stop, the classic: the data changes every day, so why retrain on all of it? Use DIFF to extract exactly the part that changed, and **train only the delta.**

> 📎 Runnable SQL: [github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ Source & community: [github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)

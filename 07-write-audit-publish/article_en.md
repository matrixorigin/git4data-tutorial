# MatrixOne Git4Data Deep Dive (Part 7): Write-Audit-Publish — A Release Gate for Data

Data pipelines have a perennial problem: **you don't control upstream data quality, but you own the fallout.**

The overnight ETL pours a fresh batch straight into the production table — laced with null user_ids, negative amounts, and obviously bogus outliers. By the time someone notices in the morning, downstream reports have computed wrong numbers, a model has trained crooked, customers have seen it. Then comes the harder part: **the dirty rows are now mixed into the same table as the good ones**, and cleaning that up is ten times harder than blocking it would have been.

Software engineering's standard answer to this class of problem is the CI gate: code must pass tests before it merges to main. The data world's counterpart is called **Write-Audit-Publish (WAP)** — writes land in isolation, pass an audit, then publish. It used to take lake-side tooling (Iceberg, lakeFS) to build; with git4data, it's just a basic use of branches.

> 📦 Full runnable SQL: [`07-write-audit-publish/`](https://github.com/matrixorigin/git4data-tutorial) in the companion repo.

---

## Write: new data always lands on a staging branch

The production table `events` holds 100k clean rows, read continuously downstream. Today's batch **never touches it directly**:

```sql
-- Open a staging branch off production (milliseconds — Part 3 explained why)
DATA BRANCH CREATE TABLE events_staging FROM events;

-- The 5000-row batch lands on staging — with the diseases real pipelines
-- actually produce: null user_ids, negative amounts, absurd outliers
INSERT INTO events_staging
SELECT 100000 + result,
       CASE WHEN result % 100 = 0 THEN NULL ELSE result % 5000 END,
       CASE WHEN result % 250 = 0 THEN -1.00
            WHEN result % 333 = 0 THEN 999999.99
            ELSE round(rand()*500, 2) END,
       '2026-06-10'
FROM generate_series(1, 5000) g;
```

Production hasn't moved a row. The dirty data is quarantined on staging — WAP's first principle: **isolation before quality.**

## Audit: SQL is the quality gate

The audit is a few SQL statements run against staging — easily a CI step:

```sql
SELECT
  SUM(CASE WHEN user_id IS NULL THEN 1 ELSE 0 END)  AS null_user,
  SUM(CASE WHEN amount < 0 THEN 1 ELSE 0 END)       AS negative_amount,
  SUM(CASE WHEN amount > 10000 THEN 1 ELSE 0 END)   AS outlier_amount
FROM events_staging WHERE ts = '2026-06-10';
-- Gate FAILS: all three kinds of bad rows caught
```

The gate failed; the fix also happens on staging (production oblivious throughout):

```sql
DELETE FROM events_staging
WHERE ts = '2026-06-10'
  AND (user_id IS NULL OR amount < 0 OR amount > 10000);
-- Re-run the gate → all zeros, pass
```

Before publishing, one last look at what this batch will *actually* do to production — row-level:

```sql
DATA BRANCH DIFF events_staging AGAINST events OUTPUT SUMMARY;
-- INSERTED = exactly the rows about to be published
```

## Publish: one atomic merge

```sql
DATA BRANCH MERGE events_staging INTO events;
```

This step is **atomic**: downstream readers see either the whole audited batch, or (before this statement) none of it — **there is no "half-published" state**. Verify:

```sql
SELECT COUNT(*) FROM events
WHERE user_id IS NULL OR amount < 0 OR amount > 10000;   -- 0
```

Not one dirty row ever appeared in the production table.

---

## Why this deserves a gate

Put the three steps together and WAP changes a fundamental assumption:

> Without WAP: the production table is data's **entry point**; quality problems get handled after they're in.
> With WAP: the production table is data's **exit point**; only data that passed the audit earns its way in.

Cost-wise the gate is nearly free: the staging branch is created in milliseconds (zero-copy), the audit is plain SQL, the publish is one merge measured in seconds. Compare the traditional dance — temp tables, full copies, swap logic — slow and brittle.

One step further: this naturally automates. Daily batch → auto-create staging → auto-run audit SQL → merge on pass, alert on fail *with the crime scene preserved* (the staging branch IS the full incident scene, ready to debug). **This is CI/CD for data.**

---

## Closing

The data-operations trilogy is complete: **a personal safety net** (Part 5 — you can always go back), **team parallelism** (Part 6 — branch and merge), and **a production gate** (this part — dirty data can't get in). All three run on the same primitives — snapshot, branch, diff, merge — which is the whole point of "version control inside the database": not one more feature, but a different way of working.

Next, the series moves to AI training. First stop, the classic: **continuous learning for ML** — the data changes every day, so why retrain on everything? Use DIFF to extract exactly the part that changed, and train only the delta.

> 📎 Runnable SQL: [github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ Source & community: [github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)

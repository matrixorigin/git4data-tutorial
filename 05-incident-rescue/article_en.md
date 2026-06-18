# MatrixOne Git4Data Deep Dive (Part 5): Incident Rescue — From a Fat-Fingered UPDATE to a Dropped Table, Roll Back in Seconds

The last article mapped the data-versioning landscape — you now know exactly what we mean by git4data. From here the series turns practical, and the first theme is **data operations** — where nothing raises your heart rate quite like this:

> 2 a.m. You run an `UPDATE` against production — and only after hitting Enter do you realize **you forgot the WHERE clause**. The amounts on 80,000 orders are now all the same number.

Everyone knows the traditional drill: dig out last night's backup, spin up a recovery instance, wait hours for the data to load, then figure out how to replay the legitimate writes that happened after the backup — praying the whole way through. The recovery takes **hours**; the accident itself took half a second.

This article covers the **three layers of safety net** git4data provides for moments like this: snapshot before, investigate during, point-in-time recovery after. Every SQL statement is copy-paste runnable.

> 📦 All SQL lives in the companion repo [matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial). Same setup as before: `docker run -d -p 6001:6001 --name matrixone matrixorigin/matrixone:4.0.0-rc1`, then load a 1,000,000-row `orders` table (the setup SQL is in Part 2 or the repo — takes seconds).

---

## Layer 1: before any risky operation, press "save"

The plainest and most effective habit: **take a snapshot before any risky bulk operation.**

```sql
-- Before the change goes in, save a checkpoint (milliseconds, regardless of table size)
CREATE SNAPSHOT before_repricing FOR TABLE mydb orders;

-- Run your bulk change
UPDATE orders SET amount = amount * 1.1 WHERE region = 'EU';
```

We measured this in Part 2: snapshotting a 1M-row (or 100M-row) table takes **5–8 milliseconds** — because it only records a moment and protects that moment's objects (Part 3 explained why). Which means snapshots carry **zero psychological cost**: take one before every change, the way you hit Ctrl+S while writing a document.

Change went wrong? One statement returns you to the checkpoint:

```sql
RESTORE TABLE mydb.orders {SNAPSHOT = before_repricing};
```

Done in seconds; the whole table is back to its pre-change state. This is `git reset --hard`, for data.

---

## Layer 2: don't roll back yet — use DIFF to see exactly what got damaged

In a real incident, rollback is rarely the first move. What you want to know first is: **how many rows were damaged? which rows? did anything that shouldn't be touched get touched?** — because rollback has a cost too (it wipes out the legitimate writes that came after the accident), so you assess before you act.

A traditional database leaves you guessing at this step. git4data hands you a **row-level incident report**:

```sql
-- Current table vs. the pre-incident snapshot: what exactly differs?
DATA BRANCH DIFF orders AGAINST orders {SNAPSHOT='before_repricing'} OUTPUT SUMMARY;
```

```
metric   | orders | (snapshot)
INSERTED |      0 |      0
DELETED  |      0 |      0
UPDATED  |    500 |      0     ← damage scope: 500 rows modified
```

Then see exactly which rows, and what they were changed to:

```sql
DATA BRANCH DIFF orders AGAINST orders {SNAPSHOT='before_repricing'} OUTPUT LIMIT 10;
-- Each row: which table, what operation, the key, current column values — a damage inventory at a glance
```

We measured this on a 1M-row table: a fat-fingered change to 500 rows, and this DIFF returns in **milliseconds** with UPDATED=500, exactly right (Part 3 explained why it's this fast: it scans only the increment objects, never the full table).

Assessment done, then decide: full-table rollback, or repair just the damaged rows (the DIFF output is itself the repair list). **"See clearly first, act second" — that's the biggest mindset shift git4data brings to data operations.**

---

## Layer 3: no snapshot? PITR has your back — even a DROP TABLE

Layer 1 has an obvious hole: it depends on you **remembering** to snapshot. And accidents love to strike precisely when you didn't save.

The real safety net is **PITR (point-in-time recovery)** — configure a retention window for the database, and afterwards **any moment** inside that window is recoverable, whether or not you ever took a snapshot:

```sql
-- One-time setup: 1 day of continuous protection for the database (recommended as standing config in production)
CREATE PITR ops_pitr FOR DATABASE mydb RANGE 1 'd';
```

Once configured, it works quietly in the background. Let's demonstrate with the worst accident there is — **the whole table got dropped**:

```sql
DROP TABLE orders;        -- 1,000,000 rows, gone
SELECT COUNT(*) FROM orders;   -- ERROR: no such table
```

Recover to any moment before the incident (timestamp at second precision):

```sql
RESTORE DATABASE mydb FROM PITR ops_pitr "2026-06-10 15:45:00";

SELECT COUNT(*) FROM orders;   -- 1000000 — the table is back, schema and data intact
```

We tested this end to end: **a dropped 1M-row table, restored whole-database from PITR, not a row missing.** In the traditional playbook this is a "major incident, all hands on deck" event; here it's one SQL statement.

> ⚠ A timing detail (we hit it in testing): a PITR has a valid-from boundary (roughly its creation time). Restoring to a second-precision timestamp right after creating the PITR may fail with `input timestamp ... is less than the pitr valid time`. Wait 1–2 seconds after creating it, or check `SHOW PITR` for its start time. Which is exactly why **PITR should be standing configuration, not something you create after the incident** — it protects the window *after* its creation.

---

## Coverage: from one table to the whole cluster

The demos above were at table and database level, but this safety net is **full-granularity** — a fat-fingered table, a polluted database, a tenant-level disaster, all with the same semantics:

| Incident scope | Save | Recover |
|---|---|---|
| One table | `CREATE SNAPSHOT s FOR TABLE db t` | `RESTORE TABLE db.t {SNAPSHOT = s}` |
| One database (multi-table consistent) | `CREATE SNAPSHOT s FOR DATABASE db` | `RESTORE DATABASE db FROM PITR p "moment"` |
| One account (tenant) | `CREATE SNAPSHOT s FOR ACCOUNT acc` | `RESTORE ACCOUNT acc FROM SNAPSHOT s` |
| The whole cluster | `CREATE SNAPSHOT s FOR CLUSTER` | `RESTORE CLUSTER FROM SNAPSHOT s` |

The database level is especially worth remembering: **database-level snapshot/restore is multi-table atomic** — feature tables, order tables, and metadata tables all return to the same instant together. No torn state where one table went back and another didn't.

---

## The one-page rescue card

This whole article, compressed into a card you could pin at your desk:

| When | Action | SQL |
|---|---|---|
| **Routinely** | Keep standing PITR on production | `CREATE PITR p FOR DATABASE db RANGE 1 'd'` |
| **Before a change** | Snapshot, casually | `CREATE SNAPSHOT s FOR TABLE db t` |
| **First move after an incident** | Don't panic — assess the damage | `DATA BRANCH DIFF t AGAINST t {SNAPSHOT='s'} OUTPUT SUMMARY` |
| **Decided to roll back** | Return to the checkpoint | `RESTORE TABLE db.t {SNAPSHOT = s}` |
| **No snapshot taken** | PITR recovers any moment | `RESTORE DATABASE db FROM PITR p "YYYY-MM-DD HH:MM:SS"` |
| **Table was dropped** | Whole-database PITR restore | Same as above — schema and data come back together |

The cost is near zero (snapshots in milliseconds, independent of data size); the payoff is turning "hours of incident recovery" into "one SQL statement in seconds." That math works out every time.

---

## Closing

Incident rescue is git4data's most "unglamorous" application — no fancy concepts, just bringing the thing software engineering takes for granted ("mistakes can be undone") to production databases. But notice the pattern that kept repeating in this article: **cheap checkpoint before, row-level clarity during, precise rollback after.** That pattern isn't only for firefighting.

Next time, its grown-up form: **collaborative data development** — multiple engineers working on the same large table in parallel, each on their own branch, merging back to mainline when done, conflicts adjudicated by the database. In other words: GitHub-style teamwork, on data.

> 📎 Runnable SQL: [github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ Source & community: [github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)

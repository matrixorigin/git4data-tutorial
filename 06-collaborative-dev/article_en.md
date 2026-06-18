# MatrixOne Git4Data Deep Dive (Part 6): Collaborative Data Development — Merge Data the Way You Merge Code

Last time: one person, one incident, how to recover. This time, something more everyday: **a team, changing the same data, at the same time.**

How do teams collaborate without version control? Mostly by talking: "I'm working on this table for the next two days, don't touch it." "Ping me when you're done and I'll go in." Plus a few backup tables named `orders_backup_0610_final_v2`. It's **serialized work + human locking** — the state the code world left behind twenty years ago.

git4data brings the GitHub model to data, intact: **one branch per person, work in parallel, self-review, merge back to mainline, conflicts adjudicated by the database.**

> 📦 Full runnable SQL: [`06-collaborative-dev/`](https://github.com/matrixorigin/git4data-tutorial) in the companion repo. Same setup as before (`matrixone:4.0.0-rc1` + a 100k-row `products` table).

---

## One branch per person

Three engineers maintain one product table: Alice reprices, Bob backfills missing descriptions, Carol retires discontinued items. Pin the shared starting point, then each forks a lineage-tracked branch:

```sql
CREATE SNAPSHOT team_base FOR TABLE collab_demo products;

DATA BRANCH CREATE TABLE products_alice FROM products;
DATA BRANCH CREATE TABLE products_bob   FROM products;
DATA BRANCH CREATE TABLE products_carol FROM products;
```

Three branches, instantly (Part 3 explained why: a branch copies only object references — milliseconds). From this moment the three are **fully invisible to, and isolated from, each other** — nobody coordinates who goes first.

```sql
-- Alice: reprice category A (her range: ids 1–30000)
UPDATE products_alice SET price = round(price * 1.10, 2)
WHERE category = 'A' AND product_id <= 30000;

-- Bob: backfill descriptions (his range: 30001–60000)
UPDATE products_bob SET descr = concat('backfilled_', product_id)
WHERE descr IS NULL AND product_id BETWEEN 30001 AND 60000;

-- Carol: retire a discontinued range
UPDATE products_carol SET status = 'retired'
WHERE product_id BETWEEN 90000 AND 95000;
```

⚠ One practical rule: **divide work by rows, not by columns.** Conflict detection is row-level — if Alice changes row 60's price and Bob changes row 60's description, that's still a merge conflict even though they touched different columns (we genuinely hit this while writing this article). Carving work by primary-key ranges makes merges conflict-free by construction.

---

## Self-review before merging

Before merging, each engineer reviews their own change set with DIFF — the equivalent of checking your own diff before opening a PR:

```sql
DATA BRANCH DIFF products_alice AGAINST products OUTPUT SUMMARY;
-- UPDATED = how many rows did I actually touch? right range? collateral damage?
```

Confirmed, merge in turn — disjoint row ranges mean the three branches **merge cleanly in any order**, no coordination required:

```sql
DATA BRANCH MERGE products_alice INTO products;
DATA BRANCH MERGE products_bob   INTO products;
DATA BRANCH MERGE products_carol INTO products;
```

The mainline now carries all three change sets. No table locks, no maintenance windows, no "wait for me."

---

## When work genuinely collides

Even good division of labor has accidents. Dave and Erin unknowingly change **the same row**:

```sql
DATA BRANCH CREATE TABLE products_dave FROM products;
DATA BRANCH CREATE TABLE products_erin FROM products;
UPDATE products_dave SET price = 1.00 WHERE product_id = 42;
UPDATE products_erin SET price = 2.00 WHERE product_id = 42;

DATA BRANCH MERGE products_dave INTO products;          -- Dave lands first, cleanly
DATA BRANCH MERGE products_erin INTO products WHEN CONFLICT FAIL;
-- ERROR: conflict on product_id=42; the merge rolls back, mainline untouched
```

The database puts the collision **on the table**, instead of silently letting the later write clobber the earlier one (the classic "lost update" — the most common accident in versionless collaboration). Three ways to rule:

```sql
DATA BRANCH MERGE products_erin INTO products WHEN CONFLICT SKIP;    -- keep Dave's
-- or WHEN CONFLICT ACCEPT (take Erin's); or fix Erin's branch by hand, then merge
```

And remember Part 3's conclusion: **only genuinely colliding rows need a ruling.** The thousands of other normal changes in Erin's branch merge automatically; the only row needing judgment is #42.

---

## This is the Pull Request, for data

Map it onto what you already do on GitHub every day:

| GitHub | git4data |
|---|---|
| fork / branch | `DATA BRANCH CREATE TABLE … FROM …` |
| review your own diff | `DATA BRANCH DIFF … AGAINST … OUTPUT SUMMARY` |
| merge the PR | `DATA BRANCH MERGE … INTO …` |
| conflict resolution | `WHEN CONFLICT FAIL / SKIP / ACCEPT` |
| back to the fork point | `RESTORE … {SNAPSHOT = team_base}` |

On cost: this workflow holds on a 600-million-row table too — measured: four engineers each forked it, changed a million rows, and merged back, every merge in **seconds**. Neither headcount nor table size is the bottleneck anymore.

---

## Closing

Collaborative development is where git4data cashes in "cheap parallelism" most directly: branches are free, merges are seconds, conflicts are explicit. Team size is no longer constrained by the invisible rule of "one table, one person at a time."

One question this article left open: when changes merge into the mainline, **who guards the quality?** Next time, the publishing side of the answer: **Write-Audit-Publish** — data lands on a staging branch, passes an SQL audit gate, then publishes atomically. Production never sees a dirty row.

> 📎 Runnable SQL: [github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ Source & community: [github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)

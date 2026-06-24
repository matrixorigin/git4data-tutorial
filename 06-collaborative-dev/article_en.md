# MatrixOne Git4Data Deep Dive (Part 6) · Data Operations in Practice — Collaborative Data Development: Merge Data the Way You Merge Code

The last article was about one person rescuing one accident. This one is about something more everyday, and more easily overlooked: **a team editing the same data at the same time.**

Without version control, how does a team collaborate on data changes? Mostly by talking, and by backup tables:

> "I'm cleaning the `products` table this week — don't touch it." "Ping me when you're done and I'll go next." — plus a database full of `products_backup_0610_final_v2`.

It's **serial work + a human lock**: only one person can safely touch a table at a time. Exactly the state the software world left behind twenty years ago, thanks to Git. git4data brings that same GitHub workflow to data: **each person on a branch, working in parallel, self-reviewing, merging back to mainline, with conflicts adjudicated row by row by the database.**

This article is again a hands-on manual: first, **when you actually need it**, then — using one products table — four real scenarios end to end: **parallel multi-person editing, a reviewable data PR, developing a big change on a branch, and what to do when two people genuinely collide.** Every statement is verified on MatrixOne `4.0.0-rc3`.

> 📦 All SQL runs as one script: [matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial), under `06-collaborative-dev/`. Environment: `docker run -d -p 6001:6001 --name matrixone matrixorigin/matrixone:4.0.0-rc3`.

---

## When do you actually need "collaborative data development"?

Not every data edit needs a branch. But these situations almost always hit the same wall — "several people / several change sets need to move forward in parallel and then safely come together" — which is exactly where it earns its keep:

- **Several people cleaning / enriching one large master table in parallel**: a product catalog, a customer master, an address book — three to five people each own a slice and work at once.
- **Developing a risky big change off to the side**: recompute all prices, switch to a new taxonomy, backfill a historical column — heavy, needs repeated validation, but **mainline must keep serving** and can't freeze for it.
- **Data changes that must be reviewed before they land**: the author submits a branch, and a lead must look at the diff and approve before it merges (a hard requirement for governance / compliance).
- **Several people each try a version, the best one wins**: different cleaning rules, different scoring definitions — each tried on a branch, compared with DIFF, keeping the better one, or cherry-picking the best parts from each.

What they share, in one line: **turn "editing data" from something that needs queueing and coordination into something you can safely do in parallel, just like editing code.**

---

## Scenario 1: several people maintain one master table in parallel

Three engineers maintain a 100,000-row products table at once: Alice reprices, Bob backfills missing descriptions, Carol retires a discontinued batch.

First pin the team's shared starting point (a snapshot), then each forks a **lineage-tracked** branch:

```sql
CREATE SNAPSHOT team_base FOR TABLE collab_demo products;

DATA BRANCH CREATE TABLE products_alice FROM products;
DATA BRANCH CREATE TABLE products_bob   FROM products;
DATA BRANCH CREATE TABLE products_carol FROM products;
```

All three branches appear **instantly** (Part 3: a branch copies object references, not data — milliseconds, the same for 100K rows or 600M). From this moment the three are **completely invisible to and independent of each other** — no need to agree who goes first, no "who's holding the table right now."

![Branch collaboration: the team forks three independent branches off team_base, edits in parallel, and merges each back to mainline](./images/fig_branch-merge_en.svg)

```sql
-- Alice: reprice category A (owns ids 1–30000)
UPDATE products_alice SET price = round(price * 1.10, 2)
WHERE category = 'A' AND product_id <= 30000;

-- Bob: backfill missing descriptions (owns ids 30001–60000)
UPDATE products_bob SET descr = concat('backfilled_', product_id)
WHERE descr IS NULL AND product_id BETWEEN 30001 AND 60000;

-- Carol: retire a discontinued range (90000–95000)
UPDATE products_carol SET status = 'retired'
WHERE product_id BETWEEN 90000 AND 95000;
```

> ⚠ **A practical rule: split the work by ROW, not by COLUMN.** git4data detects conflicts at the **row** level — even if Alice changes a row's price and Bob changes the *description* of the same row (different columns), the merge still counts it as a conflict (we hit this exact trap writing this piece). So have each person own a **disjoint key range / partition**, and merges stay clean. The "genuine collision" section below unpacks this rule.

Before merging, each runs DIFF for a row-level self-review — exactly like glancing at your own diff before opening a PR:

```sql
DATA BRANCH DIFF products_alice AGAINST products OUTPUT SUMMARY;
--   metric   | products_alice | products
--   UPDATED  |          10000 |        0     ← I changed 10K rows; right scope? anything stray?
```

All good, merge them in turn. Because the row ranges don't overlap, the three branches **merge cleanly in any order**, with zero coordination:

```sql
DATA BRANCH MERGE products_alice INTO products;
DATA BRANCH MERGE products_bob   INTO products;
DATA BRANCH MERGE products_carol INTO products;
```

Mainline now carries all three change sets. The whole thing: **no table lock, no maintenance window, no "wait for me."** That's the most direct face of cheap parallelism.

---

## Scenario 2: turn a data change into a reviewable PR

The second common need is **governance**: a batch fix shouldn't be a raw `UPDATE` on the production table — someone must look first and approve before it counts.

git4data turns a data change into a reviewable PR naturally — the author works on a branch, the lead reviews before the merge:

```sql
-- Author: work on a branch, never touch the production table
DATA BRANCH CREATE TABLE products_fix_1837 FROM products;
UPDATE products_fix_1837 SET category = 'A'
WHERE category = 'C' AND name LIKE 'prod_1%';        -- a category correction

-- Reviewer: scope first, then row by row, keep a copy if needed
DATA BRANCH DIFF products_fix_1837 AGAINST products OUTPUT SUMMARY;   -- how much, what kind
DATA BRANCH DIFF products_fix_1837 AGAINST products OUTPUT LIMIT 20;  -- exactly what changed
DATA BRANCH DIFF products_fix_1837 AGAINST products OUTPUT FILE '/tmp';  -- a .sql patch for the record
```

This step is the **same action** as opening a PR on GitHub and reading the diff line by line — only it's data. After the review:

```sql
-- Approve: merge into mainline
DATA BRANCH MERGE products_fix_1837 INTO products;
-- Or reject: just drop the branch — the production table was never touched
DROP TABLE products_fix_1837;
```

Two key points: **before the merge, the change is completely invisible to production**; and the review is grounded in **row-level fact (DIFF)**, not "I think I changed the categories a bit." For teams that need an audit trail and sign-off, that alone pays for itself.

---

## Scenario 3: develop a big change on a branch while mainline keeps serving

Some changes aren't a few UPDATEs — they're a **project**: relabel every product under a new taxonomy and recompute prices, with real logic, run and validated repeatedly, maybe over hours or days.

The traditional options all hurt: freeze the service, stand up CDC dual-writes plus reconciliation, or let business reads see a half-migrated state. git4data's answer: **open a branch, tinker on it as long as you need, while mainline keeps serving reads and writes, none the wiser**:

```sql
DATA BRANCH CREATE TABLE products_migration FROM products;

-- Iterate your big-change logic on products_migration as long as it takes…
-- Mainline products keeps taking business reads/writes, fully unaffected.

-- Done and self-tested? DIFF first to confirm the scope is what you expect (no stray damage):
DATA BRANCH DIFF products_migration AGAINST products OUTPUT SUMMARY;

-- All clear — merge it into mainline atomically:
DATA BRANCH MERGE products_migration INTO products;
```

The branch is your construction hoarding: tinker however you like inside; the shop keeps trading outside; taking the hoarding down (the merge) is a **seconds-long** step, not a long cutover window.

> Boundary note: this row-level diff/merge **requires both sides to share a schema**. If your big change alters the table structure (add a column, change a type), the order must be "**change the schema on mainline first, then branch**," not change the structure on a branch and merge it back (Part 4 covered this boundary).

---

## When two people genuinely collide: true vs false conflict + three policies

Even good division of labor has accidents. This section is the heart of collaboration, so it's worth the detail. First, the one rule:

> **It's a true conflict only when two branches independently changed the SAME row.** Different rows → a false conflict, auto-merged with nobody involved; and even two people changing different columns of the same row counts as a true conflict (row-level detection).

![True vs false conflict: editing different rows auto-merges (false conflict); editing the same row needs a decision (true conflict)](./images/fig_conflict-detect_en.svg)

Dave and Erin unknowingly change the **same row** (#42), and Erin also touches another row (#20, nobody else's):

```sql
DATA BRANCH CREATE TABLE products_dave FROM products;
DATA BRANCH CREATE TABLE products_erin FROM products;
UPDATE products_dave SET price = 1.00 WHERE product_id = 42;     -- Dave changes 42
UPDATE products_erin SET price = 2.00 WHERE product_id = 42;     -- Erin also changes 42 (collision)
UPDATE products_erin SET status = 'retired' WHERE product_id = 20;  -- Erin-only, no conflict

DATA BRANCH MERGE products_dave INTO products;     -- Dave lands first, clean; mainline 42 = 1.00
```

Now Erin merges and #42 collides. Three policies, each behaving differently — confirmed in testing:

```sql
-- ① FAIL (default): on any conflict, the whole merge aborts and rolls back.
DATA BRANCH MERGE products_erin INTO products WHEN CONFLICT FAIL;
--   Error: conflict on pk(42); mainline untouched — even Erin's non-conflicting row 20 did NOT merge.
--   FAIL is all-or-nothing: it puts the conflict on the table for you to resolve.
```

```sql
-- ② SKIP: skip only the conflicting rows; merge the rest.
DATA BRANCH MERGE products_erin INTO products WHEN CONFLICT SKIP;
--   Result: row 42 keeps mainline's value (Dave's 1.00); row 20 merges in (Erin's 'retired').
```

```sql
-- ③ ACCEPT: conflicting rows take the branch (Erin's) value; the rest merge too.
DATA BRANCH MERGE products_erin INTO products WHEN CONFLICT ACCEPT;
--   Result: row 42 becomes Erin's 2.00.
```

![Three conflict policies: FAIL aborts the whole merge / SKIP skips conflicting rows and merges the rest / ACCEPT takes the branch value on conflicts](./images/fig_conflict-policies_en.svg)

Two easily-missed but crucial points:

1. **The database surfaces the conflict explicitly, instead of silently letting the later write overwrite the earlier one.** "Later write silently overwrites earlier" is the classic source of incidents without version control (the lost update) — here it becomes a decision you must make on purpose.
2. **Only the genuinely-colliding row needs adjudication.** The other hundreds or thousands of legitimate changes on Erin's branch merge automatically with SKIP/ACCEPT — the only thing a human decides is those few true collisions.

### Want just a few rows promoted: cherry-pick

Sometimes you don't want to merge a whole branch, just **a few of its changes** (say, a couple of hotfixes) lifted onto mainline. That's cherry-pick:

```sql
-- Promote only rows 50 and 51 to mainline, nothing else (PICK needs a primary key)
DATA BRANCH PICK products_fix INTO products KEYS (50, 51) WHEN CONFLICT FAIL;
--   Verified: only 50 and 51 merge in; even though 52 was also changed on the branch, mainline keeps its value.
```

Back to the thread Part 5 planted: the "hand-rolled `UPDATE … JOIN` to restore the damaged rows and keep the new orders" from the incident-rescue article is, at heart, exactly the three-way merge `DATA BRANCH MERGE` does automatically — against a common ancestor, telling true from false conflicts. There we ran the principle by hand; here we hand it back to the database: conflicts auto-detected, and adjudicated by policy when they happen.

---

## A few practices that mean fewer conflicts

- **Split the work by key range / partition** so people's changes naturally don't overlap — the cheapest "no conflict."
- **Small, frequent merges**: merging small branches back often beats hoarding a month of work for one big-bang merge.
- **Fix one base snapshot for the team** (`team_base`) and branch everyone off it — clean lineage, and merges take the incremental fast path from Part 3.
- **Changing the schema? Change it on mainline first, then branch** — don't alter the structure on a branch and merge it back.

---

## This is the Pull Request, for data

Map it to what you do on GitHub every day — it's nearly one-to-one:

| GitHub | git4data |
|---|---|
| fork / branch | `DATA BRANCH CREATE TABLE … FROM …` |
| read your / someone's diff | `DATA BRANCH DIFF … AGAINST … OUTPUT SUMMARY / LIMIT / FILE` |
| merge PR | `DATA BRANCH MERGE … INTO …` |
| resolve conflicts | `WHEN CONFLICT FAIL / SKIP / ACCEPT` |
| cherry-pick | `DATA BRANCH PICK … INTO … KEYS (…)` |
| go back to the fork point | `RESTORE TABLE … {SNAPSHOT = team_base}` |

---

## Cost and boundaries

- **Branches are free, merges are seconds** — independent of table size or how many people work at once: measured before, a 600M-row table with 4 engineers each forking and changing a million rows, every merge **in seconds**. Neither headcount nor table size is the bottleneck anymore.
- **Conflict adjudication is row-level, not cell-level**: different columns of the same row still count as a conflict (Part 4; cell-level auto-merge is future work).
- **diff/merge requires a shared schema**, and the incremental fast path needs lineage (Part 3).
- **`FAIL` is all-or-nothing**: for a "partial merge," use `SKIP` / `ACCEPT`, or `PICK` to promote exact rows.

---

## Closing

Collaborative data development is where git4data cashes out "cheap parallelism" most completely: branches free, merges in seconds, conflicts explicit and only the true collisions adjudicated. Team size is no longer bound by "one table, one person at a time."

But one question this article hasn't answered: who guards the **quality** of what gets merged into mainline? What if a branch merges in dirty data? Next time, the answer from the release side: **Write-Audit-Publish** — new data lands on a staging branch, passes an SQL audit gate, then publishes atomically, so production **never sees** data that didn't pass.

> 📎 Runnable SQL: [github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ Source & community: [github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)

# MatrixOne Git4Data Deep Dive (Part 6) · Data Operations in Practice — Collaborative Data Development: Merge Data the Way You Merge Code

The last article was about one person rescuing one accident. This one is about something more everyday, and easy to underrate: **a team editing the same data at the same time.**

But "data collaboration" never appears out of nowhere — it **always comes attached to some concrete piece of work.** So this article doesn't theorize about "collaboration"; it lays out the *work* first: you're probably doing one of these now, or will be next month. Each scenario runs end to end, and every statement is verified on MatrixOne `4.0.0-rc3`.

> 📦 All SQL runs as one script: [matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial), under `06-collaborative-dev/`. Environment: `docker run -d -p 6001:6001 --name matrixone matrixorigin/matrixone:4.0.0-rc3`.

---

## What are you doing when you hit "data collaboration"?

The question isn't "should we set up collaboration for data" — it's that **the moment you take on the work below, data collaboration is already happening**; the only choice is whether you do it the Git way, or the old way (fight over one table + a pile of backups + coordinating in a group chat):

- **Prepping for a big sale / launching a campaign**: pricing, ops, and catalog teams all need to edit the same products table before the deadline.
- **Running a cross-system migration / column refactor**: moving data to a new standard is a multi-day project — and production can't pause while you do it.
- **Driving a compliance / data-quality remediation**: several people clean different parts, but every change must be reviewed, signed off, and recorded before it ships.
- **Multiple people configuring a batch of rules / campaigns**: each configures their own, and someone reviews before a single publish.

What they share, in one line: **several people and several change sets must move forward at once, then come together safely.** Below, one 100,000-row products table walks through the first three — and you'll see they all use the same moves: branch, self-review, merge, adjudicate conflicts.

---

## Activity 1: prepping a big sale — three teams edit one products table at once

> Two weeks to the big sale. The `products` table is about to be edited by three groups at once: the **pricing team** sets sale prices in bulk, the **ops team** writes promo copy for the sale items, the **catalog team** retires a discontinued batch. Three groups, one table, a deadline staring back.

Without version control, this leaves two painful paths: serialize by schedule (one group finishes before the next starts — two weeks isn't enough), or each makes a `products_backup_ops_edition` table and reconciles by hand at the end (error-prone).

git4data's way: pin a shared starting point, and each team forks its own branch to work **completely invisible to and independent of the others**.

```sql
CREATE SNAPSHOT team_base FOR TABLE collab_demo products;   -- the team's shared start

DATA BRANCH CREATE TABLE products_pricing FROM products;    -- pricing team
DATA BRANCH CREATE TABLE products_ops     FROM products;    -- ops team
DATA BRANCH CREATE TABLE products_catalog FROM products;    -- catalog team
```

All three branches appear **instantly** (Part 3: a branch copies object references, not data — milliseconds, the same for 100K rows or 600M). From now on nobody has to ask "who's holding the table right now."

![Branch collaboration: three teams fork their own branch off team_base, edit in parallel, and merge each back to mainline](./images/fig_branch-merge_en.svg)

```sql
-- Pricing: 20% off category-A sale items (owns ids 1–30000)
UPDATE products_pricing SET price = round(price * 0.80, 2)
WHERE category = 'A' AND product_id <= 30000;

-- Ops: add promo copy where it's missing (owns ids 30001–60000)
UPDATE products_ops SET descr = concat('SALE_', product_id)
WHERE descr IS NULL AND product_id BETWEEN 30001 AND 60000;

-- Catalog: retire a discontinued range (owns ids 90000–95000)
UPDATE products_catalog SET status = 'retired'
WHERE product_id BETWEEN 90000 AND 95000;
```

> ⚠ **A practical rule: split the work by ROW, not by COLUMN.** git4data detects conflicts at the **row** level — even if pricing changes an item's price and ops changes the *copy* of the same item (different columns), the merge still counts it as a conflict (we hit this exact trap writing this piece). So have each team own a **disjoint product-id range / category**, and merges stay clean.

Before merging, each team runs DIFF for a row-level self-review — like glancing at your own diff before opening a PR:

```sql
DATA BRANCH DIFF products_pricing AGAINST products OUTPUT SUMMARY;
--   UPDATED = how many rows did I change? Right scope? Did I stray into someone else's range?
```

All good — merge them in turn. Because the ranges don't overlap, the three branches **merge cleanly in any order**, with zero coordination:

```sql
DATA BRANCH MERGE products_pricing INTO products;
DATA BRANCH MERGE products_ops     INTO products;
DATA BRANCH MERGE products_catalog INTO products;
```

The whole sale prep: **no table lock, no maintenance window, no "wait for me to merge first."** Three teams genuinely sprint in parallel to the deadline.

---

## Activity 2: a cross-system migration — build it on a branch, the shop keeps selling

> Product decides to move the catalog to a new taxonomy. This isn't a few UPDATEs — it's a project with transformation logic, run repeatedly, with QA sign-off, spanning days. The catch: **the shop is still open the whole time**, and `products` is being read and written by orders nonstop.

The traditional options all hurt: freeze the service (the business won't allow it), stand up CDC dual-writes plus reconciliation (complex and error-prone), or let business reads see a half-migrated state (chaos).

git4data's way: open a migration branch, let the migration team tinker on it and QA validate on it, while **mainline keeps selling, none the wiser**:

```sql
DATA BRANCH CREATE TABLE products_migration FROM products;

-- Iterate the migration logic on the branch (hours/days). Meanwhile mainline
-- products keeps taking business reads/writes, fully unaffected.
UPDATE products_migration SET category = 'D' WHERE category = 'C';   -- e.g. old category C -> new D

-- Acceptance: before cutover, DIFF to confirm the scope is exactly what you expect.
DATA BRANCH DIFF products_migration AGAINST products OUTPUT SUMMARY;

-- All clear — cut over in one atomic, second-scale step.
DATA BRANCH MERGE products_migration INTO products;
```

The branch is your construction hoarding: tinker however you like inside; the shop keeps trading outside; taking the hoarding down (the merge) is a **seconds-long** step, not a long all-hands cutover window. If the cutover turns out wrong? `RESTORE TABLE … {SNAPSHOT = team_base}` rolls back to before the migration.

> Boundary note: this row-level diff/merge **requires both sides to share a schema**. If your migration alters the table structure (add a column, change a type), the order must be "**change the schema on mainline first, then branch for the data migration**," not change the structure on a branch and merge it back (Part 4 covered this).

---

## Activity 3: a compliance remediation — clean in parallel, but every change is signed off

> A regulator hands down a remediation order, due in a month: scrub legacy plaintext, backfill missing fields, purge expired records. Several engineers each take a part. But compliance imposes a hard rule: **any change to production data must be reviewed, recorded, and signed off before it ships.**

How do you satisfy that traditionally? Screenshot your change to the group chat for a manager to glance at? Just announce "done"? Neither lets you review against facts, nor leaves a traceable record. When something goes wrong, nobody can say what was actually changed.

git4data turns each engineer's change into a **reviewable, recorded PR**: the author works on a branch, the lead reviews the branch as a PR.

```sql
-- Engineer: work on a branch, never touch the production table
DATA BRANCH CREATE TABLE products_review FROM products;
UPDATE products_review SET descr = 'REDACTED' WHERE product_id <= 2000;   -- scrub

-- Lead / compliance officer reviews: scope, then row by row, then export a patch for the record
DATA BRANCH DIFF products_review AGAINST products OUTPUT SUMMARY;   -- how much, what kind
DATA BRANCH DIFF products_review AGAINST products OUTPUT LIMIT 20;  -- exactly what changed
DATA BRANCH DIFF products_review AGAINST products OUTPUT FILE '/tmp';  -- a .sql patch to archive
```

This is the **same action** as opening a PR on GitHub and reading the diff line by line — only it's data. After the review:

```sql
DATA BRANCH MERGE products_review INTO products;   -- approve: merge into mainline
-- or reject: DROP TABLE products_review; — production was never touched
```

Three points map straight onto compliance's three demands: the change is **invisible to production until the merge**; the review is grounded in **row-level fact (DIFF)**, not a verbal summary; and the `OUTPUT FILE` `.sql` patch can be **archived** and audited later.

---

## When two people collide: during the sale, two people touch the same hot item

Even clear division of labor has accidents. Back at the sale: two colleagues (call them Dave and Erin) both reprice the **same hot item (#42)**, and Erin also touches another item (#20, nobody else's). #42 collides — a **true conflict**. First, the one rule:

> **It's a true conflict only when two branches independently changed the SAME row.** Different rows → a false conflict, auto-merged with nobody involved; and even two people changing different columns of the same row counts as a true conflict (row-level detection).

![True vs false conflict: editing different rows auto-merges (false conflict); editing the same row needs a decision (true conflict)](./images/fig_conflict-detect_en.svg)

```sql
DATA BRANCH CREATE TABLE products_dave FROM products;
DATA BRANCH CREATE TABLE products_erin FROM products;
UPDATE products_dave SET price = 1.00 WHERE product_id = 42;          -- Dave: row 42
UPDATE products_erin SET price = 2.00 WHERE product_id = 42;          -- Erin: row 42 (collision)
UPDATE products_erin SET status = 'retired' WHERE product_id = 20;    -- Erin-only, no conflict

DATA BRANCH MERGE products_dave INTO products;     -- Dave lands first; mainline 42 = 1.00
```

Now Erin merges and #42 collides. Three policies, each behaving differently (confirmed in testing):

```sql
-- ① FAIL (default): on ANY conflict, the whole merge aborts and rolls back.
DATA BRANCH MERGE products_erin INTO products WHEN CONFLICT FAIL;
--   Error: conflict on pk(42); mainline untouched — even Erin's non-conflicting row 20 did NOT merge.
--   FAIL is all-or-nothing: it puts the conflict on the table for you to resolve.

-- ② SKIP: skip only the conflicting row; merge the rest.
DATA BRANCH MERGE products_erin INTO products WHEN CONFLICT SKIP;
--   Result: row 42 keeps mainline's value (Dave's 1.00); row 20 merges in (Erin's 'retired').

-- ③ ACCEPT: conflicting row takes the branch (Erin's) value; the rest merge too.
DATA BRANCH MERGE products_erin INTO products WHEN CONFLICT ACCEPT;
--   Result: row 42 becomes Erin's 2.00.
```

![Three conflict policies: FAIL aborts the whole merge / SKIP skips conflicting rows and merges the rest / ACCEPT takes the branch value on conflicts](./images/fig_conflict-policies_en.svg)

In the sale's terms it's concrete: if the **pricing team's sale price is authoritative**, `ACCEPT` their branch; if you only want **a few hot items urgently corrected** promoted to mainline rather than the whole branch, cherry-pick:

```sql
-- Promote only rows 50 and 51 to mainline, nothing else (PICK needs a primary key)
DATA BRANCH PICK products_pick INTO products KEYS (50, 51) WHEN CONFLICT FAIL;
--   Verified: only 50 and 51 merge in; even though 52 was changed on the branch, mainline keeps its value.
```

Two easily-missed but crucial points:

1. **The database surfaces the conflict explicitly, instead of silently letting the later write overwrite the earlier one.** "Later write silently overwrites earlier" is the classic source of incidents without version control (the lost update) — and in a high-pressure, many-hands event like a sale, it's especially lethal.
2. **Only the genuinely-colliding row needs adjudication.** Erin's other legitimate changes merge automatically under SKIP/ACCEPT — the only thing a human decides is those few true collisions.

> Back to the thread Part 5 planted: the "hand-rolled `UPDATE … JOIN` to restore the damaged rows and keep the new orders" from incident rescue is, at heart, exactly the three-way merge `DATA BRANCH MERGE` does automatically — against a common ancestor, telling true from false conflicts. There we ran the principle by hand; here we hand it back to the database.

---

## A few practices that mean fewer conflicts

- **Split the work by key range / partition** so people's changes naturally don't overlap — the cheapest "no conflict."
- **Small, frequent merges**: merging small branches back often beats hoarding a month of work for one big-bang merge.
- **Fix one base snapshot for the team** (`team_base`) and branch everyone off it — clean lineage, and merges take the incremental fast path from Part 3.
- **Changing the schema? Change it on mainline first, then branch** — don't alter the structure on a branch and merge it back.

---

## This is the Pull Request, for data

Pull the moves out of those three activities and map them to GitHub — nearly one-to-one:

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

- **Branches are free, merges are seconds** — independent of table size or how many people work at once: measured before, a 600M-row table with 4 engineers each forking and changing a million rows, every merge **in seconds**. Whether it's the sale's three teams or the migration's long-lived branch, git4data isn't the bottleneck.
- **Conflict adjudication is row-level, not cell-level**: different columns of the same row still count as a conflict (Part 4; cell-level auto-merge is future work).
- **diff/merge requires a shared schema**, and the incremental fast path needs lineage (Part 3).
- **`FAIL` is all-or-nothing**: for a "partial merge," use `SKIP` / `ACCEPT`, or `PICK` to promote exact rows.

---

## Closing

Collaborative data development isn't an abstract capability — it's the **infrastructure you reach for every time you do work like a sale prep, a system migration, or a compliance remediation**: branches free, merges in seconds, conflicts explicit and only the true collisions adjudicated. Many hands pushing forward at once and then coming together safely — the thing you used to brute-force with schedules and backup tables — is now as natural as merging code.

But one question this article hasn't answered: who guards the **quality** of what gets merged into mainline? What if a branch merges in dirty data? Next time, the answer from the release side: **Write-Audit-Publish** — new data lands on a staging branch, passes an SQL audit gate, then publishes atomically, so production **never sees** data that didn't pass.

> 📎 Runnable SQL: [github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ Source & community: [github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)

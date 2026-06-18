# MatrixOne Git4Data Deep Dive (Part 11): RLHF Preference Data — Consensus, Re-Judging, Reproducibility

The raw material of RLHF/DPO is **preference data**: one prompt, two responses A and B, annotators pick the better one. This data has a peculiar difficulty — **it is inherently subjective judgment.** Three people read the same pair and split 2:1 all the time; re-reviews weeks later overturn verdicts routinely.

So a preference dataset is perpetually in motion: consensus shifts, disputes get ruled, versions accumulate. And reward models are exquisitely sensitive to their data — **which 200 pairs differ between RM1's and RM2's training sets directly determines how the two models behave.** This is version control's home turf.

> 📦 Full runnable SQL: [`11-rlhf-preference/`](https://github.com/matrixorigin/git4data-tutorial) in the companion repo.

---

## Votes → consensus, in one SQL statement

Ten thousand prompt pairs, three annotators each casting one vote (A or B). Consensus is a GROUP BY with vote counting:

```sql
CREATE TABLE preferences (pair_id BIGINT PRIMARY KEY, preferred VARCHAR(1), agreement INT);

INSERT INTO preferences
SELECT pair_id,
       CASE WHEN SUM(CASE WHEN choice='A' THEN 1 ELSE 0 END) >= 2 THEN 'A' ELSE 'B' END,
       CASE WHEN SUM(CASE WHEN choice='A' THEN 1 ELSE 0 END) IN (0,3) THEN 3 ELSE 2 END
FROM votes GROUP BY pair_id;

SELECT agreement, COUNT(*) FROM preferences GROUP BY agreement ORDER BY agreement DESC;
--   agreement=3 (unanimous) vs agreement=2 (a 2:1 split) — the latter are the shaky ones
```

Pin the consensus table as version one; reward model RM1 trains on it:

```sql
CREATE SNAPSHOT pref_v1 FOR TABLE rlhf_demo preferences;
```

## Re-judging: move exactly as much as was overturned

A senior reviewer re-examines the 2:1 disputes and overturns 200 of them, on a branch:

```sql
DATA BRANCH CREATE TABLE preferences_review FROM preferences;

UPDATE preferences_review
SET preferred = CASE preferred WHEN 'A' THEN 'B' ELSE 'A' END, agreement = 3
WHERE agreement = 2 AND pair_id BETWEEN 2000 AND 2199;
```

Then the key move — **promote only those 200 overturned pairs** to the mainline; the other 9,800 pairs don't move a hair:

```sql
DATA BRANCH PICK preferences_review INTO preferences
  KEYS (SELECT pair_id FROM preferences_review
        WHERE agreement = 3 AND pair_id BETWEEN 2000 AND 2199)
  WHEN CONFLICT ACCEPT;
```

This is cherry-pick, for data: the verdict's scope is **precisely delimited** by the KEYS subquery. There's no "accidentally dragging along something else."

## The version chain: RM1 and RM2 differ by facts, not vibes

```sql
DATA BRANCH DIFF preferences AGAINST preferences {SNAPSHOT='pref_v1'} OUTPUT SUMMARY;
--   UPDATED = 200   ← v2's entire difference from v1, not a pair more

CREATE SNAPSHOT pref_v2 FOR TABLE rlhf_demo preferences;
```

The two reward models' data lineage is now fully explicit:

```
RM1 ← pref_v1
RM2 ← pref_v2 = pref_v1 + exactly 200 overturned pairs
```

If RM2 behaves differently, you know **the only variable is those 200 pairs** — reviewable one by one, instead of squinting at two multi-GB JSONL files. And any version reproduces bit-for-bit at any time (`{snapshot='pref_v1'}`): paper reproduction, compliance audits, regression debugging — one SQL covers them all.

---

## The complete preference-data workflow

String the four training-theme articles together and the LLM data-side version loop looks like this:

```
SFT curation (Part 9)        snapshot = curated version, DIFF = the receipt
   ↓
Collaborative labeling (10)   branch = annotator, conflict = disagreement, PICK = verdict
   ↓
Preference consensus (11)    SQL counts votes, PICK re-judgments, snapshot = RM training version
   ↓
Continuous learning (8)      DIFF extracts the delta, registry binds model ↔ data version
```

Four stages, one set of primitives — the compounding return of keeping training data in a version-controlled database: **learn it once, use it everywhere.**

Next is the training theme's finale, and the series' first "joint operation": **multimodal training sets** — image bytes belong to lakeFS, the catalog and labels to MatrixOne. How do two version worlds get stitched into one reproducible whole?

> 📎 Runnable SQL: [github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ Source & community: [github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)

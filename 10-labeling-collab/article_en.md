# MatrixOne Git4Data Deep Dive (Part 10): Collaborative Labeling — Disagreement IS the Conflict

Labeling is the most **human-heavy** stage of training-data production — and the most version-dense: several annotators write labels onto the same dataset at once. Who overwrites whom? Two people label the same sample oppositely — whose call stands? QC wants agreement rates on overlap sets — computed how?

Labeling platforms manage all this with piles of application logic. git4data offers a more fundamental view: **labeling is parallel modification of data, and labeling disagreement is a merge conflict** — exactly what version control was born to handle.

> 📦 Full runnable SQL: [`10-labeling-collab/`](https://github.com/matrixorigin/git4data-tutorial) in the companion repo.

---

## One branch per annotator

Ten thousand unlabeled samples. Alice takes 1–5000, Bob takes 5001–10000, and **both label 4901–5100** — that 200-row overlap is deliberate, the labeling industry's standard practice for measuring inter-annotator agreement:

```sql
CREATE SNAPSHOT before_labeling FOR TABLE label_demo samples;   -- restart insurance

DATA BRANCH CREATE TABLE samples_alice FROM samples;
DATA BRANCH CREATE TABLE samples_bob   FROM samples;

-- Each labels on their own branch (invisible to, undisturbed by, the other)
UPDATE samples_alice SET label = ... WHERE id BETWEEN 1 AND 5100;
UPDATE samples_bob   SET label = ... WHERE id BETWEEN 4901 AND 10000;
```

## Before merging: the agreement rate is one JOIN

Branches aren't exotic objects — they're tables. So "did the two annotators agree on the overlap?" is a direct JOIN:

```sql
SELECT COUNT(*) AS qc_disagreements
FROM samples_alice a JOIN samples_bob b ON a.id = b.id
WHERE a.id BETWEEN 4901 AND 5100 AND a.label <> b.label;
```

The disagreement list goes into a review queue for a senior reviewer:

```sql
CREATE TABLE review_queue AS
SELECT a.id, a.label AS alice_label, b.label AS bob_label
FROM samples_alice a JOIN samples_bob b ON a.id = b.id
WHERE a.id BETWEEN 4901 AND 5100 AND a.label <> b.label;
```

This step shows git4data's character: **versions can compute against each other directly** (Part 1's "compute on any version"). In a file-based labeling workflow this takes two exports and a comparison script; here it's one SQL statement.

## Merge: disagreements surface automatically

```sql
DATA BRANCH MERGE samples_alice INTO samples;          -- Alice first, clean
DATA BRANCH MERGE samples_bob INTO samples WHEN CONFLICT SKIP;
-- Bob's branch collides precisely on the rows where the two disagreed —
-- SKIP keeps Alice's for now, while Bob's thousands of other labels merge in automatically
```

Note the correspondence: **truly conflicting rows = rows where the two disagreed**, no more, no less. Overlap rows where they agreed (identical changes) cancel out in the diff aggregation and never count as conflicts — Part 3's mechanism catching the business semantics exactly.

## The reviewer's verdict: cherry-picked, surgically

The reviewer rules on the disputed rows on a branch (here: siding with Bob), then promotes **only those rows** to the mainline — nothing else moves:

```sql
DATA BRANCH CREATE TABLE samples_review FROM samples;
UPDATE samples_review r SET label = (
  SELECT q.bob_label FROM review_queue q WHERE q.id = r.id
) WHERE r.id IN (SELECT id FROM review_queue);

DATA BRANCH PICK samples_review INTO samples
  KEYS (SELECT id FROM review_queue)
  WHEN CONFLICT ACCEPT;
```

`PICK ... KEYS(subquery)` is this article's star: the verdict's scope is delimited by SQL — **as many rows as were overturned move, and not one more.**

## Wrap-up: the whole campaign, accounted for

```sql
-- What did this labeling campaign change, in total?
DATA BRANCH DIFF samples AGAINST samples {SNAPSHOT='before_labeling'} OUTPUT SUMMARY;

-- Need to redo the whole campaign? One statement:
-- RESTORE TABLE label_demo.samples {SNAPSHOT = before_labeling};
```

---

## Closing

Once labeling is mapped onto version control, the problems that application logic strains to manage get structural answers: **parallelism = branches, overwrites = merge order, disagreement = conflict, adjudication = SKIP/ACCEPT/PICK, agreement rate = a cross-branch JOIN, restart = RESTORE.** Labeling platforms still earn their keep (UI, task dispatch, piecework) — but the version semantics at the data layer, the database simply provides.

Next, one step further downstream from labeling: **RLHF preference data** — three annotators vote, SQL computes consensus, disputed pairs get re-judged and cherry-picked into the training set, and every version of the reward model's data stays reproducible.

> 📎 Runnable SQL: [github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ Source & community: [github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)

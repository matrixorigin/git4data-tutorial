# MatrixOne Git4Data Deep Dive (Part 15, Finale): Agent Self-Evolution — Branch, Evaluate, Merge, Roll Back

The very first article of this series showed a figure: a production agent's data forked into isolated branches, each trying a different improvement (SFT, reinforcement, governance), an offline evaluation gate, the winner merged and deployed, the losers discarded wholesale — **every step machine-driven, no human engineer in the loop.**

Back then it was a vision diagram. Fourteen articles later, every brick needed to run it is in your hands: branching (6), gates (7), evaluation data (8–11), memory and traces (13, 14). The finale assembles them into that loop.

> 📦 Full runnable SQL: [`15-agent-evolution/`](https://github.com/matrixorigin/git4data-tutorial) in the companion repo.

---

## The agent's "brain" is a table too

The evolvable parts — skills, prompt templates, each skill's rolling score — belong in structured form anyway:

```sql
CREATE TABLE brain (
    skill_id BIGINT PRIMARY KEY,
    skill    VARCHAR(32),
    prompt   VARCHAR(256),
    score    DECIMAL(5,2)
);
-- 200 skills, serving in production
CREATE SNAPSHOT brain_gen0 FOR TABLE evolve_demo brain;   -- this round's rollback point
```

`brain_gen0` is this evolution round's **insurance**: whatever happens below, generation 0 stays one statement away.

## Step 1: branch — three candidates, three strategies

Evolution is, at heart, **parallel exploration of a hypothesis space.** Three branches, three mutually isolated mutation strategies:

```sql
DATA BRANCH CREATE TABLE cand_sft FROM brain;   -- strategy 1: rewrite weak prompts
DATA BRANCH CREATE TABLE cand_rl  FROM brain;   -- strategy 2: amplify what works
DATA BRANCH CREATE TABLE cand_gov FROM brain;   -- strategy 3: prune what keeps failing

UPDATE cand_sft SET prompt = concat('prompt_v2_refined_', skill_id) WHERE score < 60;
UPDATE cand_rl  SET prompt = concat(prompt, '_reinforced'), score = score + 5 WHERE score > 70;
DELETE FROM cand_gov WHERE score < 55;
```

The candidates can't see each other; the production brain is untouched — and per Part 3, the physical cost of these three branches is three sets of object references, a few milliseconds. **Cheapness is what makes a machine bold enough to explore**: if spinning up a candidate meant copying all the data, the evolution loop would never turn.

## Step 2: evaluate — the replay gate

Each candidate brain gets a shadow agent that replays a fixed task suite; the evaluator writes scores back into the database:

```sql
CREATE TABLE eval_results (candidate VARCHAR(16) PRIMARY KEY, eval_score DECIMAL(5,2));
INSERT INTO eval_results VALUES ('cand_sft', 71.40), ('cand_rl', 66.20), ('cand_gov', 64.80);

-- The gate: production baseline 65.0; qualifiers ranked by score
SELECT * FROM eval_results WHERE eval_score > 65.0 ORDER BY eval_score DESC;
--   cand_sft  71.40   ← winner
--   cand_rl   66.20   ← qualified, not best
```

One last review before deploying — what will the winner *actually* change in the production brain, laid out row by row:

```sql
DATA BRANCH DIFF cand_sft AGAINST brain OUTPUT SUMMARY;
```

Machine decisions still need an auditable shape. This DIFF is evolution's "change manifest" — when something goes wrong, humans come back to this ledger.

## Step 3: merge the winner, discard the rest

```sql
DATA BRANCH MERGE cand_sft INTO brain WHEN CONFLICT ACCEPT;   -- winner ships
DROP TABLE cand_rl;                                            -- losers vanish whole
DROP TABLE cand_gov;

CREATE SNAPSHOT brain_gen1 FOR TABLE evolve_demo brain;        -- generation 1, sealed
```

Note the losers' fate: `DROP TABLE`, clean and total. No residual state, no half-merged contamination — **daring to discard matters as much as daring to explore**, and both are gifts of cheap branching.

## Step 4: the safety property — evolution is always regrettable

Generation 1 regresses in production?

```sql
RESTORE TABLE evolve_demo.brain {SNAPSHOT = brain_gen0};   -- one statement, back to gen 0
```

And the difference between any two generations stays queryable for life:

```sql
DATA BRANCH DIFF brain AGAINST brain {SNAPSHOT='brain_gen0'} OUTPUT SUMMARY;
--   exactly which skills changed between generations — an evolution history with receipts
```

**Branch → mutate → evaluate → merge-or-discard → seal → repeat.** This loop can turn night after night on its own; humans return to the ledger only when an alarm rings.

---

## Finale: why this requires version control, specifically

Back to Part 1's claim: an agent's three defining traits — **autonomy, fallibility, the need to explore in parallel** — are exactly the three problems Git was invented to solve for human developers. Swap the subject to machines and the correspondence isn't rhetorical; it's a one-to-one engineering map:

| What the agent needs | What git4data supplies |
|---|---|
| Explore boldly without harming production | branch = a millisecond sandbox |
| Validate many hypotheses in parallel | N candidates = N branches |
| Auditable decisions | DIFF = a row-level change manifest |
| Reversible mistakes | RESTORE = a one-statement undo |
| Traceable evolution history | the snapshot chain = every generation, sealed |

An agent without version control has only two endings: **reckless** (changing things irreversibly) or **paralyzed** (afraid to touch anything). Version control is the precondition that turns "self-evolution" from a demo into a production system.

Fourteen articles, and we close here. From the question "code has Git; data doesn't," through the mechanics, the operations, the training, to a machine-driven evolution loop — **making data versionable at scale was never just settling an old debt; it is the foundation of AI-era data infrastructure.** This series ends here. What gets built on that foundation is just beginning.

> 📎 Runnable SQL for the whole series: [github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ Source & community: [github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)

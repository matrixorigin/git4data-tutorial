-- =============================================================================
-- Git4Data Tutorial — Part 15: Agent Self-Evolution (series capstone)
-- The full machine-driven loop: branch the agent's brain into candidates,
-- mutate each, evaluate offline, merge the winner, discard the rest — and
-- roll back if a release goes bad. No human in the loop.
-- Run:  mysql -h 127.0.0.1 -P 6001 -u root -p111 < agent_evolution.sql
-- =============================================================================

CREATE DATABASE evolve_demo;
USE evolve_demo;

-- The agent's "brain": skills with prompt templates and a fitness score.
CREATE TABLE brain (
    skill_id BIGINT PRIMARY KEY,
    skill    VARCHAR(32),
    prompt   VARCHAR(256),
    score    DECIMAL(5,2)          -- rolling eval score for this skill
);
INSERT INTO brain
SELECT result, concat('skill_', result),
       concat('prompt_v1_for_skill_', result),
       round(50 + rand()*30, 2)
FROM generate_series(1, 200) g;

-- Production brain pinned: the rollback point for this evolution round.
CREATE SNAPSHOT brain_gen0 FOR TABLE evolve_demo brain;

-- ============================================== 1. BRANCH: three candidates
-- Each candidate explores a different mutation strategy, fully isolated.
DATA BRANCH CREATE TABLE cand_sft FROM brain;   -- rewrite weak prompts
DATA BRANCH CREATE TABLE cand_rl  FROM brain;   -- amplify what already works
DATA BRANCH CREATE TABLE cand_gov FROM brain;   -- prune what keeps failing

UPDATE cand_sft SET prompt = concat('prompt_v2_refined_', skill_id)
WHERE score < 60;
UPDATE cand_rl  SET prompt = concat(prompt, '_reinforced'), score = score + 5
WHERE score > 70;
DELETE FROM cand_gov WHERE score < 55;

-- ============================================== 2. EVALUATE: replay gating
-- Each candidate is evaluated offline (replay a fixed task suite against the
-- candidate brain; here the harness writes its results in):
CREATE TABLE eval_results (candidate VARCHAR(16) PRIMARY KEY, eval_score DECIMAL(5,2));
INSERT INTO eval_results VALUES ('cand_sft', 71.40), ('cand_rl', 66.20), ('cand_gov', 64.80);

-- The gate: production baseline is 65.0; best candidate above it wins.
SELECT * FROM eval_results WHERE eval_score > 65.0 ORDER BY eval_score DESC;
--   cand_sft 71.40  <- winner
--   cand_rl  66.20  <- passed but not best

-- What would the winner actually change? Reviewable before deploy:
DATA BRANCH DIFF cand_sft AGAINST brain OUTPUT SUMMARY;

-- ============================================== 3. MERGE the winner, DISCARD the rest
DATA BRANCH MERGE cand_sft INTO brain WHEN CONFLICT ACCEPT;
DROP TABLE cand_rl;
DROP TABLE cand_gov;

SELECT COUNT(*) FROM brain WHERE prompt LIKE 'prompt_v2_refined%';  -- mutations live
CREATE SNAPSHOT brain_gen1 FOR TABLE evolve_demo brain;

-- ============================================== 4. The safety property
-- Generation 1 regresses in production? One statement back to gen 0:
-- RESTORE TABLE evolve_demo.brain {SNAPSHOT = brain_gen0};
-- And the full lineage of every generation stays queryable:
DATA BRANCH DIFF brain AGAINST brain {SNAPSHOT='brain_gen0'} OUTPUT SUMMARY;
--   exactly which skills changed between generations — evolution with receipts.

-- This loop — branch, mutate, evaluate, merge-or-discard, snapshot, repeat —
-- is the agentic workflow this series opened with. Every step here was a
-- machine decision; version control is what made it SAFE to hand over.

-- ---------------------------------------------------------------- cleanup
DROP TABLE eval_results;
DROP SNAPSHOT IF EXISTS brain_gen0;
DROP SNAPSHOT IF EXISTS brain_gen1;
DROP DATABASE IF EXISTS evolve_demo;

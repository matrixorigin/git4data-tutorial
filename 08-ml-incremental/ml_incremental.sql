-- =============================================================================
-- Git4Data Tutorial — Part 8: ML Continuous Learning (train only the delta)
-- Pin the training set with a SNAPSHOT; next round, DIFF against it to get the
-- exact changed rows and train only those. Plus a 6-round cost experiment
-- (incremental vs full retrain).
--
-- Companion to "Git4Data Deep Dive (Part 8) — ML Continuous Learning:
-- Train Only What Changed". Verified on MatrixOne v4.0.0-rc3.
--     docker run -d -p 6001:6001 --name matrixone matrixorigin/matrixone:4.0.0-rc3
--     mysql -h 127.0.0.1 -P 6001 -u root -p111 < ml_incremental.sql
-- =============================================================================

-- Re-runnable: snapshots are account-scoped and survive DROP DATABASE.
DROP SNAPSHOT IF EXISTS train_v1;
DROP SNAPSHOT IF EXISTS train_v2;
DROP SNAPSHOT IF EXISTS exp_r1; DROP SNAPSHOT IF EXISTS exp_r2; DROP SNAPSHOT IF EXISTS exp_r3;
DROP SNAPSHOT IF EXISTS exp_r4; DROP SNAPSHOT IF EXISTS exp_r5; DROP SNAPSHOT IF EXISTS exp_r6;
DROP DATABASE IF EXISTS mltrain_demo;
CREATE DATABASE mltrain_demo;
USE mltrain_demo;

CREATE TABLE samples (
    sample_id BIGINT PRIMARY KEY,
    f1    DOUBLE,
    f2    DOUBLE,
    label TINYINT
);
CREATE TABLE model_registry (model VARCHAR(16), data_snapshot VARCHAR(32), accuracy DOUBLE);

INSERT INTO samples
SELECT result, round(rand(),4), round(rand(),4), result % 2
FROM generate_series(1, 100000) g;


-- ------------------------------------------------------------ 1. PIN v1, train m1
CREATE SNAPSHOT train_v1 FOR TABLE mltrain_demo samples;   -- ms, near-zero cost
INSERT INTO model_registry VALUES ('m1', 'train_v1', 0.9012);   -- m1 <- train_v1 (100000 rows)


-- ------------------------------------------------------------ 2. A WEEK LATER: data moved
INSERT INTO samples                                             -- 3000 new samples
SELECT 100000 + result, round(rand(),4), round(rand(),4), result % 2
FROM generate_series(1, 3000) g;
UPDATE samples SET label = 1 - label WHERE sample_id BETWEEN 500 AND 699;   -- 200 label fixes


-- ------------------------------------------------------------ 3. WHAT CHANGED vs m1's set?
DATA BRANCH DIFF samples AGAINST samples {SNAPSHOT='train_v1'} OUTPUT SUMMARY;
--   INSERTED = 3000   DELETED = 0   UPDATED = 200

-- Pull the exact delta (net, by value) to feed partial_fit — new OR changed rows only:
SELECT COUNT(*) AS incremental_rows
FROM samples cur
WHERE NOT EXISTS (
    SELECT 1 FROM samples {SNAPSHOT='train_v1'} base
    WHERE base.sample_id = cur.sample_id
      AND base.f1 = cur.f1 AND base.f2 = cur.f2 AND base.label = cur.label
);   -- 3200  (3000 new + 200 changed) — full table is 103000

SELECT COUNT(*) AS full_table FROM samples;   -- 103000 (what a full retrain would touch)


-- ------------------------------------------------------------ 4. PIN v2, train m2
CREATE SNAPSHOT train_v2 FOR TABLE mltrain_demo samples;
INSERT INTO model_registry VALUES ('m2', 'train_v2', 0.9145);
--   registry now records the model <-> data chain:
--     m1 <- train_v1 (100000)
--     m2 <- train_v2 (103000) = train_v1 + 3000 new + 200 corrected

-- Reproduce m1's training set, bit for bit, months later:
SELECT COUNT(*) AS m1_trainset FROM samples {SNAPSHOT='train_v1'};   -- 100000


-- =============================================================================
-- COST EXPERIMENT — 6 rounds: incremental delta vs full retrain
--   round r: table grows to 1000*r rows; each round after the first adds 1000
--   new rows + 2 label fixes. Full retrain processes the WHOLE table each round;
--   incremental processes only that round's delta.
-- =============================================================================
DROP DATABASE IF EXISTS mltrain_exp;
CREATE DATABASE mltrain_exp;
USE mltrain_exp;
CREATE TABLE s (id BIGINT PRIMARY KEY, label TINYINT);

-- round 1: 1000 rows, first train sees all 1000
INSERT INTO s SELECT result, result % 2 FROM generate_series(1, 1000) g;
CREATE SNAPSHOT exp_r1 FOR TABLE mltrain_exp s;

-- round 2: +1000 new, 2 fixes -> delta vs r1
INSERT INTO s SELECT 1000 + result, result % 2 FROM generate_series(1, 1000) g;
UPDATE s SET label = 1 - label WHERE id IN (10, 20);
DATA BRANCH DIFF s AGAINST s {SNAPSHOT='exp_r1'} OUTPUT SUMMARY;   -- INSERTED 1000, UPDATED 2
CREATE SNAPSHOT exp_r2 FOR TABLE mltrain_exp s;

INSERT INTO s SELECT 2000 + result, result % 2 FROM generate_series(1, 1000) g;  -- r3
CREATE SNAPSHOT exp_r3 FOR TABLE mltrain_exp s;
INSERT INTO s SELECT 3000 + result, result % 2 FROM generate_series(1, 1000) g;  -- r4
CREATE SNAPSHOT exp_r4 FOR TABLE mltrain_exp s;
INSERT INTO s SELECT 4000 + result, result % 2 FROM generate_series(1, 1000) g;  -- r5
CREATE SNAPSHOT exp_r5 FOR TABLE mltrain_exp s;

-- round 6 (same shape) — the per-round delta is still ~1000+2 while the table is 6x bigger
INSERT INTO s SELECT 5000 + result, result % 2 FROM generate_series(1, 1000) g;
UPDATE s SET label = 1 - label WHERE id IN (30, 40);
DATA BRANCH DIFF s AGAINST s {SNAPSHOT='exp_r5'} OUTPUT SUMMARY;   -- INSERTED 1000, UPDATED 2 (table now 6000)

SELECT COUNT(*) AS final_table_size FROM s;   -- 6000
-- full retrain total  = 1000+2000+3000+4000+5000+6000 = 21000
-- incremental total   = 1000 + 1002 + 1000 + 1000 + 1000 + 1002 = 6004
--   (r1 initial 1000; r2 & r6 add 1000 new + 2 fixes; r3-r5 add 1000 new)
-- gap widens quadratically: full is O(rounds^2), incremental is O(rounds).


-- ---------------------------------------------------------------- cleanup
DROP SNAPSHOT IF EXISTS train_v1; DROP SNAPSHOT IF EXISTS train_v2;
DROP SNAPSHOT IF EXISTS exp_r1; DROP SNAPSHOT IF EXISTS exp_r2; DROP SNAPSHOT IF EXISTS exp_r3;
DROP SNAPSHOT IF EXISTS exp_r4; DROP SNAPSHOT IF EXISTS exp_r5; DROP SNAPSHOT IF EXISTS exp_r6;
DROP DATABASE IF EXISTS mltrain_demo;
DROP DATABASE IF EXISTS mltrain_exp;

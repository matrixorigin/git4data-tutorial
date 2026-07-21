-- =============================================================================
-- Git4Data Tutorial — Part 9: Dataset Release & Leakage
-- A train/valid/test split is a CONTRACT (membership + rule + data version).
-- This demo builds a leaky random split, exposes the leaks with SQL detectors,
-- builds a correct time-based split, gates it, then freezes it as ONE database
-- snapshot so it is bit-for-bit reproducible.
-- Verified on MatrixOne 4.1.0.
--     docker run -d -p 6001:6001 --name matrixone matrixorigin/matrixone:4.1.0
--     mysql -h 127.0.0.1 -P 6001 -u root -p111 < dataset_release_demo.sql
-- =============================================================================

DROP SNAPSHOT IF EXISTS risk_dataset_v1;
DROP SNAPSHOT IF EXISTS risk_dataset_v2;
DROP DATABASE IF EXISTS risk_ml;
CREATE DATABASE risk_ml;
USE risk_ml;

-- Training mainline. Enriched (vs Part 8) with the keys leakage detection needs:
--   user_id    — entity key (same person, many transactions)
--   event_key  — dedup key (same underlying event / its augmented copies)
--   label_time — when the label became known (later than event_time)
CREATE TABLE samples (
    sample_id    BIGINT PRIMARY KEY,
    event_time   DATETIME,
    user_id      BIGINT,
    event_key    VARCHAR(64),
    amount       DECIMAL(12,2),
    txn_count_7d INT,
    label        TINYINT,
    label_time   DATETIME,
    label_source VARCHAR(32)
);

-- 100,000 transactions, 20,000 users (~5 each), spread over 121 days
-- (2026-03-01 .. 2026-06-29). Fraud truth returns 3 days after the event.
-- "Now" is 2026-07-01: events whose label_time > now have no label yet.
INSERT INTO samples
SELECT g.result,
       DATE_ADD('2026-03-01', INTERVAL (g.result % 121) DAY),
       g.result % 20000,
       CONCAT('evt-', g.result),
       ROUND(rand() * 500 + 1, 2),
       g.result % 30,
       CASE WHEN DATE_ADD(DATE_ADD('2026-03-01', INTERVAL (g.result % 121) DAY), INTERVAL 3 DAY) > '2026-07-01'
            THEN NULL ELSE g.result % 2 END,
       DATE_ADD(DATE_ADD('2026-03-01', INTERVAL (g.result % 121) DAY), INTERVAL 3 DAY),
       'chargeback'
FROM generate_series(1, 100000) g;

-- 2,000 augmented near-duplicates: same event_key + same event_time as the
-- originals (evt-1 .. evt-2000), a different sample_id. A leak-safe split MUST
-- keep an event_key's rows together.
INSERT INTO samples
SELECT 100000 + g.result,
       DATE_ADD('2026-03-01', INTERVAL (g.result % 121) DAY),
       g.result % 20000,
       CONCAT('evt-', g.result),
       ROUND(rand() * 500 + 1, 2),
       g.result % 30,
       CASE WHEN DATE_ADD(DATE_ADD('2026-03-01', INTERVAL (g.result % 121) DAY), INTERVAL 3 DAY) > '2026-07-01'
            THEN NULL ELSE g.result % 2 END,
       DATE_ADD(DATE_ADD('2026-03-01', INTERVAL (g.result % 121) DAY), INTERVAL 3 DAY),
       'chargeback'
FROM generate_series(1, 2000) g;

SELECT COUNT(*) AS total_rows, COUNT(label) AS labeled_rows,
       COUNT(*) - COUNT(label) AS unlabeled_recent
FROM samples;   -- 102000 total; recent (label_time>now) rows unlabeled


-- #############################################################################
-- VILLAIN — a naive per-row RANDOM split (train_test_split-style)
-- #############################################################################
DROP TABLE IF EXISTS membership_rand;
CREATE TABLE membership_rand (sample_id BIGINT PRIMARY KEY, split_name VARCHAR(16));
INSERT INTO membership_rand
SELECT sample_id,
       CASE WHEN rand() < 0.8 THEN 'train'
            WHEN rand() < 0.5 THEN 'valid'
            ELSE 'test' END
FROM samples
WHERE label IS NOT NULL;

SELECT split_name, COUNT(*) FROM membership_rand GROUP BY split_name ORDER BY split_name;

-- Detector 1 — TIME leak: does train contain events later than test's earliest?
SELECT
  (SELECT MAX(s.event_time) FROM samples s JOIN membership_rand m ON s.sample_id=m.sample_id WHERE m.split_name='train') AS train_max_event,
  (SELECT MIN(s.event_time) FROM samples s JOIN membership_rand m ON s.sample_id=m.sample_id WHERE m.split_name='test')  AS test_min_event;
SELECT COUNT(*) AS train_rows_from_the_future
FROM samples s JOIN membership_rand m ON s.sample_id=m.sample_id
WHERE m.split_name='train'
  AND s.event_time > (SELECT MIN(s2.event_time) FROM samples s2 JOIN membership_rand m2 ON s2.sample_id=m2.sample_id WHERE m2.split_name='test');

-- Detector 2 — ENTITY leak: users appearing in BOTH train and test
SELECT COUNT(*) AS users_in_train_and_test FROM (
  SELECT s.user_id
  FROM samples s JOIN membership_rand m ON s.sample_id=m.sample_id
  WHERE m.split_name IN ('train','test')
  GROUP BY s.user_id
  HAVING COUNT(DISTINCT m.split_name) = 2
) t;

-- Detector 3 — DUPLICATE leak: one event_key split across multiple splits
SELECT COUNT(*) AS event_keys_across_splits FROM (
  SELECT s.event_key
  FROM samples s JOIN membership_rand m ON s.sample_id=m.sample_id
  GROUP BY s.event_key
  HAVING COUNT(DISTINCT m.split_name) > 1
) t;


-- #############################################################################
-- HERO — a TIME-based split (past predicts future), the right primary for fraud
--   train  : event_time <  2026-06-05   (~80%)
--   valid  : 2026-06-05 .. 2026-06-16   (~10%)
--   test   : event_time >= 2026-06-17   (~10%)
-- #############################################################################
DROP TABLE IF EXISTS dataset_membership;
CREATE TABLE dataset_membership (
    sample_id  BIGINT PRIMARY KEY,
    split_name VARCHAR(16),
    split_rule VARCHAR(256)
);
INSERT INTO dataset_membership
SELECT sample_id,
       CASE WHEN event_time <  '2026-06-05' THEN 'train'
            WHEN event_time <  '2026-06-17' THEN 'valid'
            ELSE 'test' END,
       'time_split:v1 cutoffs=2026-06-05/2026-06-17; feature_cutoff=event_time; label_ready<=2026-07-01'
FROM samples
WHERE label IS NOT NULL;   -- not-yet-labeled recent rows are excluded on purpose

SELECT split_name, COUNT(*) FROM dataset_membership GROUP BY split_name ORDER BY split_name;

-- Detector 1 again — TIME leak now gone
SELECT COUNT(*) AS train_rows_from_the_future
FROM samples s JOIN dataset_membership m ON s.sample_id=m.sample_id
WHERE m.split_name='train'
  AND s.event_time > (SELECT MIN(s2.event_time) FROM samples s2 JOIN dataset_membership m2 ON s2.sample_id=m2.sample_id WHERE m2.split_name='test');

-- Detector 3 again — DUP leak gone (same event_key shares event_time -> same split)
SELECT COUNT(*) AS event_keys_across_splits FROM (
  SELECT s.event_key
  FROM samples s JOIN dataset_membership m ON s.sample_id=m.sample_id
  GROUP BY s.event_key
  HAVING COUNT(DISTINCT m.split_name) > 1
) t;

-- Detector 2 — ENTITY overlap under a pure time split: still > 0.
-- Returning users straddle the time boundary. For fraud this is realistic
-- (you DO see returning users in production), so we report and accept it.
SELECT COUNT(*) AS users_in_train_and_test FROM (
  SELECT s.user_id
  FROM samples s JOIN dataset_membership m ON s.sample_id=m.sample_id
  WHERE m.split_name IN ('train','test')
  GROUP BY s.user_id
  HAVING COUNT(DISTINCT m.split_name) = 2
) t;

-- If the task instead REQUIRES entity disjointness, split by a hash of the
-- entity so all of a user's rows land together -> overlap becomes 0.
DROP TABLE IF EXISTS membership_entity;
CREATE TABLE membership_entity (sample_id BIGINT PRIMARY KEY, split_name VARCHAR(16));
INSERT INTO membership_entity
SELECT sample_id,
       CASE WHEN user_id % 10 < 8 THEN 'train'
            WHEN user_id % 10 = 8 THEN 'valid'
            ELSE 'test' END
FROM samples WHERE label IS NOT NULL;
SELECT COUNT(*) AS users_in_train_and_test_entity_split FROM (
  SELECT s.user_id
  FROM samples s JOIN membership_entity m ON s.sample_id=m.sample_id
  WHERE m.split_name IN ('train','test')
  GROUP BY s.user_id
  HAVING COUNT(DISTINCT m.split_name) = 2
) t;


-- #############################################################################
-- RELEASE GATE — every check must pass before we snapshot (WAP, for splits)
-- #############################################################################
-- label-time leak: any labeled row whose label wasn't known by its own cutoff?
SELECT COUNT(*) AS label_from_future
FROM samples s JOIN dataset_membership m ON s.sample_id=m.sample_id
WHERE s.label IS NOT NULL AND s.label_time > '2026-07-01';

-- split sizes (proportions must sit in a sane band)
SELECT m.split_name, COUNT(*) AS n,
       ROUND(100.0*COUNT(*)/(SELECT COUNT(*) FROM dataset_membership),1) AS pct
FROM dataset_membership m GROUP BY m.split_name ORDER BY m.split_name;

-- label balance per split (guards a split with no positives)
SELECT m.split_name, AVG(s.label) AS pos_rate
FROM samples s JOIN dataset_membership m ON s.sample_id=m.sample_id
GROUP BY m.split_name ORDER BY m.split_name;


-- #############################################################################
-- PUBLISH — freeze samples + dataset_membership together as ONE named version
-- #############################################################################
CREATE SNAPSHOT risk_dataset_v1 FOR DATABASE risk_ml;

-- Read any split from the frozen version (change only split_name)
SELECT COUNT(*) AS train_rows_v1
FROM samples {SNAPSHOT='risk_dataset_v1'} s
JOIN dataset_membership {SNAPSHOT='risk_dataset_v1'} m ON s.sample_id=m.sample_id
WHERE m.split_name='train';


-- #############################################################################
-- EVOLVE — v2 moves 500 hard samples from train into test, then DIFF the split
-- (ruler-changed vs model-changed)
-- #############################################################################
UPDATE dataset_membership SET split_name='test',
       split_rule='time_split:v2 + 500 hard cases moved to test'
WHERE sample_id IN (SELECT sample_id FROM dataset_membership WHERE split_name='train' LIMIT 500);

-- what moved between splits, vs the released v1
DATA BRANCH DIFF dataset_membership
  AGAINST dataset_membership {SNAPSHOT='risk_dataset_v1'} OUTPUT SUMMARY;   -- UPDATED = 500

CREATE SNAPSHOT risk_dataset_v2 FOR DATABASE risk_ml;

-- v1 is still reproducible bit-for-bit. NOTE: query each snapshot in its OWN
-- statement. Reading two snapshots of the SAME table via scalar subqueries in
-- one SELECT is unreliable on 4.1.0 (both return the first snapshot's value).
SELECT split_name, COUNT(*) AS n_v1 FROM dataset_membership {SNAPSHOT='risk_dataset_v1'}
GROUP BY split_name ORDER BY split_name;   -- test 10104 / train 80950 / valid 10104
SELECT split_name, COUNT(*) AS n_v2 FROM dataset_membership {SNAPSHOT='risk_dataset_v2'}
GROUP BY split_name ORDER BY split_name;   -- test 10604 / train 80450 / valid 10104


-- #############################################################################
-- CLEANUP
-- #############################################################################
DROP SNAPSHOT IF EXISTS risk_dataset_v1;
DROP SNAPSHOT IF EXISTS risk_dataset_v2;
DROP DATABASE IF EXISTS risk_ml;

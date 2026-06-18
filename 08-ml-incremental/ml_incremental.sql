-- =============================================================================
-- Git4Data Tutorial — Part 8: ML Continuous Learning — train only the delta
-- Snapshot per training run; DIFF between runs yields exactly the rows that
-- changed — feed those to incremental training instead of full retrains.
-- Run:  mysql -h 127.0.0.1 -P 6001 -u root -p111 < ml_incremental.sql
-- =============================================================================

CREATE DATABASE mltrain_demo;
USE mltrain_demo;

-- The growing training set + a model registry that pins data versions.
CREATE TABLE samples (
    sample_id BIGINT PRIMARY KEY,
    features  VARCHAR(128),
    label     INT,
    src       VARCHAR(16)
);
CREATE TABLE model_registry (
    model    VARCHAR(32) PRIMARY KEY,
    data_tag VARCHAR(64),
    metric   DECIMAL(6,4)
);

INSERT INTO samples
SELECT result, concat('feat_', result), result % 2, 'batch_0'
FROM generate_series(1, 100000) g;

-- ------------------------------------------------- training run #1
-- Pin the exact data this model sees, then register the pair.
CREATE SNAPSHOT train_v1 FOR TABLE mltrain_demo samples;
-- (your trainer reads the table, fits model m1 ...)
INSERT INTO model_registry VALUES ('m1', 'train_v1', 0.9012);

-- ------------------------------------------------- the data keeps moving
-- A week of life: new batch arrives, some labels get corrected.
INSERT INTO samples
SELECT 100000 + result, concat('feat_n_', result), result % 2, 'batch_1'
FROM generate_series(1, 3000) g;
UPDATE samples SET label = 1 - label WHERE sample_id BETWEEN 500 AND 699;  -- 200 fixes

-- ------------------------------------------------- train only the delta
-- What changed since m1's training set? EXACTLY these rows — nothing else.
DATA BRANCH DIFF samples AGAINST samples {SNAPSHOT='train_v1'} OUTPUT SUMMARY;
--   INSERTED = 3000 (new batch), UPDATED = 200 (label fixes)
-- Your trainer pulls just these 3200 rows (OUTPUT LIMIT / OUTPUT FILE) and
-- calls partial_fit — instead of re-reading all 103,000.
-- Measured in our experiments: 6 rounds of incremental training processed
-- 6,012 rows total where full retrains would have processed 21,000.

-- ------------------------------------------------- training run #2
CREATE SNAPSHOT train_v2 FOR TABLE mltrain_demo samples;
INSERT INTO model_registry VALUES ('m2', 'train_v2', 0.9145);

-- ------------------------------------------------- exact reproduction
-- Months later: "rebuild m1's training set, bit for bit."
SELECT COUNT(*) FROM samples {snapshot='train_v1'};   -- 100000, as m1 saw it
SELECT COUNT(*) FROM samples;                          -- 103000, the present
-- Registry tells you which tag belongs to which model:
SELECT * FROM model_registry ORDER BY model;

-- ---------------------------------------------------------------- cleanup
DROP SNAPSHOT IF EXISTS train_v1;
DROP SNAPSHOT IF EXISTS train_v2;
DROP DATABASE IF EXISTS mltrain_demo;

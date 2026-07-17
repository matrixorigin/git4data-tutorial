-- =============================================================================
-- Git4Data Tutorial — Part 8: ML lifecycle (companion)
-- ML lifecycle: ingest gate -> data review -> feature experiment -> dataset
-- release -> model/data lineage -> next-round DIFF.
--
-- Verified end to end on MatrixOne v4.1.0.
--     docker run -d -p 6001:6001 --name matrixone matrixorigin/matrixone:4.1.0
--     mysql -h 127.0.0.1 -P 6001 -u root -p111 < ml_lifecycle_demo.sql
-- This demo exercises the data lifecycle; it records model metadata but does
-- not run an external ML framework.
-- =============================================================================

-- Snapshots are account-scoped and survive DROP DATABASE, so clean them first.
DROP SNAPSHOT IF EXISTS risk_before_review;
DROP SNAPSHOT IF EXISTS risk_dataset_v1;
DROP SNAPSHOT IF EXISTS risk_dataset_v2;
DROP DATABASE IF EXISTS risk_ml;

CREATE DATABASE risk_ml;
USE risk_ml;

CREATE TABLE samples (
    sample_id      BIGINT PRIMARY KEY,
    event_time     DATETIME,
    amount         DECIMAL(12,2),
    txn_count_7d   INT,
    amount_sum_30d DECIMAL(14,2),
    label          TINYINT,
    label_source   VARCHAR(32),
    source_batch   VARCHAR(32)
);

CREATE TABLE dataset_membership (
    sample_id  BIGINT PRIMARY KEY,
    split_name VARCHAR(16),
    split_rule VARCHAR(128)
);

CREATE TABLE model_registry (
    model_version   VARCHAR(32) PRIMARY KEY,
    dataset_snapshot VARCHAR(64),
    code_commit     VARCHAR(64),
    feature_version VARCHAR(32),
    image_digest    VARCHAR(128),
    artifact_uri    VARCHAR(512),
    valid_auc       DOUBLE,
    test_auc        DOUBLE,
    status          VARCHAR(16)
);

-- -----------------------------------------------------------------------------
-- Round 1: publish train / valid / test membership as one dataset version.
-- -----------------------------------------------------------------------------
INSERT INTO samples
SELECT result,
       '2026-06-01 00:00:00',
       round(rand() * 5000 + 1, 2),
       result % 30,
       round(rand() * 50000 + 1, 2),
       result % 2,
       'historical_truth',
       'baseline'
FROM generate_series(1, 100000) g;

-- A deterministic 80/10/10 split for this compact demo. For temporal problems
-- such as fraud, prefer time-based splits plus entity grouping.
INSERT INTO dataset_membership
SELECT sample_id,
       CASE WHEN sample_id % 10 = 0 THEN 'test'
            WHEN sample_id % 10 = 1 THEN 'valid'
            ELSE 'train' END,
       'hash_mod10:v1'
FROM samples;

-- Database scope pins samples and membership at the same consistent point.
CREATE SNAPSHOT risk_dataset_v1 FOR DATABASE risk_ml;

INSERT INTO model_registry VALUES (
    'risk_m1', 'risk_dataset_v1', '8f31c2', 'feature_v7',
    'sha256:runtime-v1', 's3://models/risk_m1/model.bin',
    0.9430, 0.9412, 'production'
);

SELECT split_name, COUNT(*) AS rows_in_split
FROM dataset_membership {SNAPSHOT='risk_dataset_v1'}
GROUP BY split_name ORDER BY split_name;
-- Expected: train 80000 / valid 10000 / test 10000

-- -----------------------------------------------------------------------------
-- Round 2 / ingest: new data enters an isolated WAP branch first.
-- -----------------------------------------------------------------------------
DATA BRANCH CREATE TABLE samples_stage FROM samples;

INSERT INTO samples_stage
SELECT 100000 + result,
       '2026-07-01 00:00:00',
       round(rand() * 5000 + 1, 2),
       result % 30,
       round(rand() * 50000 + 1, 2),
       result % 2,
       'chargeback',
       '2026w27'
FROM generate_series(1, 3000) g;

-- Quality gates: each query should return zero bad rows.
SELECT COUNT(*) AS invalid_amount_or_count
FROM samples_stage
WHERE source_batch = '2026w27'
  AND (amount < 0 OR txn_count_7d < 0 OR amount_sum_30d < 0);

SELECT sample_id, COUNT(*) AS copies
FROM samples_stage
GROUP BY sample_id
HAVING COUNT(*) > 1;

-- Review the exact release scope, then publish atomically.
DATA BRANCH DIFF samples_stage AGAINST samples OUTPUT SUMMARY;
-- Expected: INSERTED 3000 / UPDATED 0 / DELETED 0

DATA BRANCH MERGE samples_stage INTO samples;
DROP TABLE samples_stage;

-- Assign newly accepted rows with the same deterministic split contract.
INSERT INTO dataset_membership
SELECT sample_id,
       CASE WHEN sample_id % 10 = 0 THEN 'test'
            WHEN sample_id % 10 = 1 THEN 'valid'
            ELSE 'train' END,
       'hash_mod10:v1'
FROM samples
WHERE sample_id > 100000;

-- -----------------------------------------------------------------------------
-- Label review: isolate corrections and keep a before-review anchor.
-- -----------------------------------------------------------------------------
CREATE SNAPSHOT risk_before_review FOR TABLE risk_ml samples;
DATA BRANCH CREATE TABLE samples_review FROM samples;

UPDATE samples_review
SET label = 1 - label,
    label_source = 'senior_review'
WHERE sample_id BETWEEN 500 AND 699;

DATA BRANCH DIFF samples_review AGAINST samples OUTPUT SUMMARY;
-- Expected: INSERTED 0 / UPDATED 200 / DELETED 0

DATA BRANCH MERGE samples_review INTO samples;
DROP TABLE samples_review;

-- -----------------------------------------------------------------------------
-- Feature experiment: work on a full-data branch; reject without touching main.
-- -----------------------------------------------------------------------------
DATA BRANCH CREATE TABLE samples_feat_candidate FROM samples;

UPDATE samples_feat_candidate
SET txn_count_7d = txn_count_7d * 2
WHERE sample_id BETWEEN 1 AND 1000;

DATA BRANCH DIFF samples_feat_candidate AGAINST samples OUTPUT SUMMARY;
-- Candidate is rejected in this demo. Main stays unchanged.
DROP TABLE samples_feat_candidate;

-- -----------------------------------------------------------------------------
-- Decide the next training strategy from the exact change set.
-- -----------------------------------------------------------------------------
DATA BRANCH DIFF samples
AGAINST samples {SNAPSHOT='risk_dataset_v1'}
OUTPUT SUMMARY;
-- Expected: INSERTED 3000 / UPDATED 200 / DELETED 0

DATA BRANCH DIFF dataset_membership
AGAINST dataset_membership {SNAPSHOT='risk_dataset_v1'}
OUTPUT SUMMARY;
-- Expected: INSERTED 3000 / UPDATED 0 / DELETED 0

-- Net rows that are new or whose current value differs from dataset_v1.
SELECT COUNT(*) AS changed_rows_for_training_decision
FROM samples cur
WHERE NOT EXISTS (
    SELECT 1
    FROM samples {SNAPSHOT='risk_dataset_v1'} base
    WHERE base.sample_id = cur.sample_id
      AND base.event_time = cur.event_time
      AND base.amount = cur.amount
      AND base.txn_count_7d = cur.txn_count_7d
      AND base.amount_sum_30d = cur.amount_sum_30d
      AND base.label = cur.label
      AND base.label_source = cur.label_source
      AND base.source_batch = cur.source_batch
);
-- Expected: 3200

-- Audit split membership before release: one membership per sample, no gaps.
SELECT COUNT(*) AS samples_without_split
FROM samples s LEFT JOIN dataset_membership m ON s.sample_id = m.sample_id
WHERE m.sample_id IS NULL;

SELECT split_name, COUNT(*) AS rows_in_split
FROM dataset_membership
GROUP BY split_name ORDER BY split_name;

CREATE SNAPSHOT risk_dataset_v2 FOR DATABASE risk_ml;

INSERT INTO model_registry VALUES (
    'risk_m2', 'risk_dataset_v2', 'b710aa', 'feature_v7',
    'sha256:runtime-v1', 's3://models/risk_m2/model.bin',
    0.9491, 0.9470, 'candidate'
);

SELECT model_version, dataset_snapshot, code_commit, feature_version,
       valid_auc, test_auc, status
FROM model_registry
ORDER BY model_version;

SELECT split_name, COUNT(*) AS risk_dataset_v1_rows
FROM dataset_membership {SNAPSHOT='risk_dataset_v1'}
GROUP BY split_name ORDER BY split_name;

SELECT split_name, COUNT(*) AS risk_dataset_v2_rows
FROM dataset_membership {SNAPSHOT='risk_dataset_v2'}
GROUP BY split_name ORDER BY split_name;

-- -----------------------------------------------------------------------------
-- Cleanup (comment out to inspect the final state).
-- -----------------------------------------------------------------------------
DROP SNAPSHOT IF EXISTS risk_before_review;
DROP SNAPSHOT IF EXISTS risk_dataset_v1;
DROP SNAPSHOT IF EXISTS risk_dataset_v2;
DROP DATABASE IF EXISTS risk_ml;

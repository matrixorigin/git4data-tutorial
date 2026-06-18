-- =============================================================================
-- Git4Data Tutorial — Part 7: Write-Audit-Publish (release gate for data)
-- New data lands on a staging branch, passes an SQL audit, then publishes
-- atomically. Production never sees a bad row.
-- Run:  mysql -h 127.0.0.1 -P 6001 -u root -p111 < write_audit_publish.sql
-- =============================================================================

CREATE DATABASE wap_demo;
USE wap_demo;

-- Production table: clean, consumers read it continuously.
CREATE TABLE events (
    event_id BIGINT PRIMARY KEY,
    user_id  INT,
    amount   DECIMAL(10,2),
    ts       VARCHAR(20)
);
INSERT INTO events
SELECT result, result % 5000, round(rand()*500, 2), '2026-06-09'
FROM generate_series(1, 100000) g;

-- ------------------------------------------------------------ 1. WRITE
-- New batch lands on a STAGING BRANCH, never directly on production.
DATA BRANCH CREATE TABLE events_staging FROM events;

-- Today's batch: 5000 rows, of which some are bad (negative amounts,
-- null user, absurd outliers) — exactly what upstream pipelines produce.
INSERT INTO events_staging
SELECT 100000 + result,
       CASE WHEN result % 100 = 0 THEN NULL ELSE result % 5000 END,
       CASE WHEN result % 250 = 0 THEN -1.00
            WHEN result % 333 = 0 THEN 999999.99
            ELSE round(rand()*500, 2) END,
       '2026-06-10'
FROM generate_series(1, 5000) g;

-- ------------------------------------------------------------ 2. AUDIT
-- SQL quality gates run on staging. Production untouched.
SELECT
  SUM(CASE WHEN user_id IS NULL THEN 1 ELSE 0 END)      AS null_user,
  SUM(CASE WHEN amount < 0 THEN 1 ELSE 0 END)           AS negative_amount,
  SUM(CASE WHEN amount > 10000 THEN 1 ELSE 0 END)       AS outlier_amount
FROM events_staging WHERE ts = '2026-06-10';
-- -> the gate FAILS: bad rows found. Fix them on staging:

DELETE FROM events_staging
WHERE ts = '2026-06-10'
  AND (user_id IS NULL OR amount < 0 OR amount > 10000);

-- Re-run the gate -> all zeros, gate passes.
SELECT
  SUM(CASE WHEN user_id IS NULL THEN 1 ELSE 0 END)      AS null_user,
  SUM(CASE WHEN amount < 0 THEN 1 ELSE 0 END)           AS negative_amount,
  SUM(CASE WHEN amount > 10000 THEN 1 ELSE 0 END)       AS outlier_amount
FROM events_staging WHERE ts = '2026-06-10';

-- Optional: review exactly what this batch will publish, row-level.
DATA BRANCH DIFF events_staging AGAINST events OUTPUT SUMMARY;

-- ------------------------------------------------------------ 3. PUBLISH
-- One atomic merge. Consumers see the whole verified batch at once,
-- or (before this statement) none of it. No half-published state.
DATA BRANCH MERGE events_staging INTO events;

SELECT COUNT(*) FROM events WHERE ts = '2026-06-10';   -- the clean batch
SELECT COUNT(*) FROM events
WHERE user_id IS NULL OR amount < 0 OR amount > 10000; -- 0: prod never saw bad rows

-- ---------------------------------------------------------------- cleanup
DROP TABLE events_staging;
DROP DATABASE IF EXISTS wap_demo;

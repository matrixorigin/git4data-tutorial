-- =============================================================================
-- Git4Data Tutorial — Part 7: Write-Audit-Publish (a release gate for data)
-- New data lands on a staging BRANCH, passes an SQL audit, then publishes with
-- one atomic MERGE. A bad batch is dropped at the gate — production never sees it.
--
-- Companion to "Git4Data Deep Dive (Part 7) · Data Operations in Practice —
-- Write-Audit-Publish: a release gate for your data pipeline".
--
-- Verified end to end on MatrixOne v4.0.0-rc3.
--     docker run -d -p 6001:6001 --name matrixone matrixorigin/matrixone:4.0.0-rc3
--     mysql -h 127.0.0.1 -P 6001 -u root -p111 < write_audit_publish.sql
-- =============================================================================

DROP DATABASE IF EXISTS wap_demo;
CREATE DATABASE wap_demo;
USE wap_demo;

-- Production fact table: yesterday's clean data. Dashboards, downstream jobs,
-- and a feature pipeline all read it continuously.
CREATE TABLE events (
    event_id BIGINT PRIMARY KEY,
    user_id  INT,
    amount   DECIMAL(10,2),
    status   VARCHAR(16),
    ts       DATE
);
INSERT INTO events
SELECT result, result % 5000, round(rand()*500 + 1, 2), 'paid', '2026-06-29'
FROM generate_series(1, 100000) g;

-- A dimension the fact must stay referentially consistent with.
CREATE TABLE dim_users (user_id INT PRIMARY KEY, tier VARCHAR(8));
INSERT INTO dim_users SELECT result, 'std' FROM generate_series(0, 4999) g;

SELECT COUNT(*) AS prod_rows FROM events;      -- 100000


-- #############################################################################
-- RUN 1 — a DIRTY batch: the gate catches it, production stays untouched
-- #############################################################################

-- ---- WRITE: the batch lands on a staging branch, never on production --------
DATA BRANCH CREATE TABLE events_stage FROM events;

-- Today's batch (5000 rows) — laced with what upstream pipelines really produce:
-- null user_ids, an unknown user (fails referential), negatives, absurd outliers.
INSERT INTO events_stage
SELECT 200000 + result,
       CASE WHEN result % 97  = 0 THEN NULL
            WHEN result % 89  = 0 THEN 999999          -- user not in dim_users
            ELSE result % 5000 END,
       CASE WHEN result % 250 = 0 THEN -1.00
            WHEN result % 333 = 0 THEN 999999.99
            ELSE round(rand()*500 + 1, 2) END,
       'paid', '2026-06-30'
FROM generate_series(1, 5000) g;

-- ---- AUDIT: a handful of SQL assertions; every count must be 0 to pass ------
SELECT
  SUM(CASE WHEN user_id IS NULL          THEN 1 ELSE 0 END) AS null_user,
  SUM(CASE WHEN amount  < 0              THEN 1 ELSE 0 END) AS negative_amount,
  SUM(CASE WHEN amount  > 10000          THEN 1 ELSE 0 END) AS outlier_amount,
  SUM(CASE WHEN status NOT IN ('paid','refunded','void') THEN 1 ELSE 0 END) AS bad_status
FROM events_stage WHERE ts = '2026-06-30';
-- referential: batch users that don't exist in the dimension
SELECT COUNT(*) AS orphan_users
FROM events_stage s LEFT JOIN dim_users d ON s.user_id = d.user_id
WHERE s.ts = '2026-06-30' AND s.user_id IS NOT NULL AND d.user_id IS NULL;
-- volume: today's batch size must sit in a sane band (guards double-load / empty run)
SELECT COUNT(*) AS batch_rows FROM events_stage WHERE ts = '2026-06-30';   -- expect ~4000-6000
-- --> the gate FAILS (null_user / negative / outlier / orphan_users all > 0).

-- ---- REJECT: drop the staging branch. Production never saw the batch. -------
--     (Keep it instead of dropping if you want the branch as a debugging scene.)
DROP TABLE events_stage;
SELECT COUNT(*) AS prod_rows_after_reject FROM events;                      -- still 100000
SELECT COUNT(*) AS batch_in_prod FROM events WHERE ts = '2026-06-30';       -- 0


-- #############################################################################
-- RUN 2 — a CLEAN batch: passes the gate, publishes atomically
-- #############################################################################
DATA BRANCH CREATE TABLE events_stage FROM events;
INSERT INTO events_stage
SELECT 200000 + result, result % 5000, round(rand()*500 + 1, 2), 'paid', '2026-06-30'
FROM generate_series(1, 5000) g;

-- AUDIT: all green now.
SELECT
  SUM(CASE WHEN user_id IS NULL THEN 1 ELSE 0 END) AS null_user,
  SUM(CASE WHEN amount  < 0     THEN 1 ELSE 0 END) AS negative_amount,
  SUM(CASE WHEN amount  > 10000 THEN 1 ELSE 0 END) AS outlier_amount
FROM events_stage WHERE ts = '2026-06-30';                                 -- 0 / 0 / 0
SELECT COUNT(*) AS orphan_users
FROM events_stage s LEFT JOIN dim_users d ON s.user_id = d.user_id
WHERE s.ts = '2026-06-30' AND d.user_id IS NULL;                           -- 0
SELECT MAX(ts) AS freshness FROM events_stage;                             -- 2026-06-30

-- Preview exactly what will publish, row-level.
DATA BRANCH DIFF events_stage AGAINST events OUTPUT SUMMARY;               -- INSERTED 5000

-- ---- PUBLISH: one atomic merge. No half-published state. --------------------
DATA BRANCH MERGE events_stage INTO events;
SELECT COUNT(*) AS prod_rows_after_publish FROM events;                     -- 105000
SELECT COUNT(*) AS dirty_in_prod FROM events
WHERE user_id IS NULL OR amount < 0 OR amount > 10000;                     -- 0
DROP TABLE events_stage;


-- #############################################################################
-- CLEANUP
-- #############################################################################
DROP DATABASE IF EXISTS wap_demo;

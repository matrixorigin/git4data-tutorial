-- =============================================================================
-- MatrixOne Git4Data Tutorial — Part 5: Incident Rescue (Data Ops in Practice)
-- Snapshot before · DIFF to investigate · surgical repair vs full rollback · PITR.
--
-- Companion to "Git4Data Deep Dive (Part 5) · Data Operations in Practice —
-- Incident Rescue: From a Fat-Fingered UPDATE to a Dropped Table".
--
-- Verified end to end on MatrixOne v4.0.0-rc3.
--     docker run -d -p 6001:6001 --name matrixone matrixorigin/matrixone:4.0.0-rc3
--     mysql -h 127.0.0.1 -P 6001 -u root -p111 < incident_rescue.sql
--
-- Statements that need a live timestamp (PITR restore) or are intentionally
-- destructive (DROP TABLE) are COMMENTED OUT with instructions — uncomment and
-- run them by hand when you reach those steps.
-- =============================================================================


-- ---------- Setup: a database with standing PITR + a 1M-row orders table -----
-- Defensive cleanup so the script is re-runnable. NOTE: PITRs and snapshots are
-- account-scoped and survive DROP DATABASE, so drop them explicitly first.
DROP PITR IF EXISTS ops_pitr;
DROP SNAPSHOT IF EXISTS before_repricing;
DROP SNAPSHOT IF EXISTS etl_pre_run8842;
DROP DATABASE IF EXISTS rescue_demo;
CREATE DATABASE rescue_demo;
USE rescue_demo;

-- Routinely: keep standing PITR on production (1-day window here).
-- Configure it BEFORE incidents — it protects the window after its creation.
CREATE PITR ops_pitr FOR DATABASE rescue_demo RANGE 1 'd';

CREATE TABLE orders (
    order_id BIGINT PRIMARY KEY,
    customer VARCHAR(32),
    amount   DECIMAL(10, 2),
    status   VARCHAR(16)
);

INSERT INTO orders
SELECT result, concat('cust_', result % 10000), round(rand()*1000, 2), 'paid'
FROM generate_series(1, 1000000) g;

SELECT COUNT(*) FROM orders;                       -- 1,000,000


-- =============================================================================
-- SCENARIO 1 — a fat-fingered UPDATE with no WHERE
-- =============================================================================

-- Good habit: snapshot before the risky bulk change (milliseconds).
CREATE SNAPSHOT before_repricing FOR TABLE rescue_demo orders;

-- The accident: meant to touch one batch, missed the WHERE.
UPDATE orders SET amount = 0 WHERE order_id <= 500;       -- 500 rows damaged


-- ---- Step 1: don't roll back — DIFF to see the damage first -----------------
DATA BRANCH DIFF orders AGAINST orders {SNAPSHOT='before_repricing'} OUTPUT SUMMARY;
--   metric   | orders | orders{snapshot}
--   INSERTED |      0 | 0
--   DELETED  |      0 | 0
--   UPDATED  |    500 | 0          <- 500 rows changed since the snapshot

-- The damage inventory: which rows, current values.
DATA BRANCH DIFF orders AGAINST orders {SNAPSHOT='before_repricing'} OUTPUT LIMIT 10;

-- Export the full changeset as a replayable .sql patch. NOTE: OUTPUT FILE takes
-- an EXISTING DIRECTORY (on the MO server); it writes a timestamped .sql there
-- that expresses the change as DELETE/INSERT.
DATA BRANCH DIFF orders AGAINST orders {SNAPSHOT='before_repricing'} OUTPUT FILE '/tmp';
--   -> /tmp/diff_orders_orders_before_repricing_<timestamp>.sql


-- ---- Step 2, Case B: surgical repair (keep post-incident business) ----------
-- Simulate legitimate new orders that arrived AFTER the accident.
INSERT INTO orders VALUES (1000001, 'cust_x', 250.00, 'paid'),
                          (1000002, 'cust_y',  88.00, 'paid');

-- Zero-copy the pre-incident snapshot into a side table (seconds, no data moved).
DATA BRANCH CREATE TABLE rescue_demo.orders_snap FROM rescue_demo.orders{SNAPSHOT='before_repricing'};

-- Restore only rows that now differ from the snapshot. The two new orders aren't
-- in the snapshot, so the join skips them — they survive.
UPDATE orders o
JOIN   orders_snap s ON o.order_id = s.order_id
SET    o.amount = s.amount, o.status = s.status
WHERE  o.amount <> s.amount OR o.status <> s.status;

-- Verify by VALUE (not by DIFF): current table should equal the snapshot, 0 off.
-- (DIFF vs the snapshot reports rows TOUCHED since it, so it would still list
--  these 500 as UPDATED — that's the assessment semantics, not a value check.)
SELECT COUNT(*) AS value_mismatch
FROM   orders o JOIN orders_snap s ON o.order_id = s.order_id
WHERE  o.amount <> s.amount OR o.status <> s.status;        -- expect 0
SELECT COUNT(*) AS new_orders_kept FROM orders WHERE order_id IN (1000001, 1000002);  -- 2

DROP TABLE orders_snap;


-- ---- Step 2, Case A: full rollback (git reset --hard, for data) -------------
-- Simplest when there are NO legitimate writes after the accident.
-- NOTE: this also removes the two post-incident orders above — that's the point.
RESTORE TABLE rescue_demo.orders {SNAPSHOT = before_repricing};
SELECT COUNT(*) AS damaged_after_restore FROM orders WHERE amount = 0 AND order_id <= 500;  -- 0
SELECT COUNT(*) AS total_after_restore   FROM orders;        -- 1000000 (new orders gone)


-- =============================================================================
-- SCENARIO 2 — a batch / ETL job gone wrong (duplicate load)
-- =============================================================================
CREATE SNAPSHOT etl_pre_run8842 FOR TABLE rescue_demo orders;

-- Simulate a batch that loaded twice (1,000 extra rows).
INSERT INTO orders
SELECT result + 2000000, concat('cust_', result % 10000), round(rand()*1000, 2), 'paid'
FROM generate_series(1, 1000) g;

-- DIFF tells "over-loaded" (INSERTED) from "overwritten" (UPDATED).
DATA BRANCH DIFF orders AGAINST orders {SNAPSHOT='etl_pre_run8842'} OUTPUT SUMMARY;
--   INSERTED | 1000 | 0    <- duplicate load
--   UPDATED  |    0 | 0

-- Whole job misfired? Roll back and rerun:  RESTORE TABLE rescue_demo.orders {SNAPSHOT = etl_pre_run8842};
-- Only one batch double-loaded? Delete just those keys (here: order_id > 2000000).
DELETE FROM orders WHERE order_id > 2000000;
DROP SNAPSHOT IF EXISTS etl_pre_run8842;


-- =============================================================================
-- SCENARIO 4 — accidental DROP / TRUNCATE: PITR whole-database restore
-- =============================================================================
-- TIMING NOTE: a PITR has a valid-from boundary (~its creation time). If you just
-- created ops_pitr, wait 1-2 seconds or check SHOW PITR first.
SHOW PITR;

-- Step 1: note the current time (copy the value — you'll restore to it).
SELECT now();

-- Step 2: the worst accident there is. Uncomment to run by hand:
-- DROP TABLE orders;                                -- 1,000,000 rows, gone

-- Step 3: whole-database restore to the moment you noted. Replace the timestamp
-- with YOUR value from step 1, then uncomment:
-- RESTORE DATABASE rescue_demo FROM PITR ops_pitr "2026-06-24 02:54:08";
-- SELECT COUNT(*) FROM orders;                      -- back, schema + data intact
-- Verified on rc3: a dropped 1M-row table comes back whole, not a row missing.


-- =============================================================================
-- Granularity recap — the same semantics from one table to the whole cluster
-- =============================================================================
--   scope     | save                                | recover
--   ----------+-------------------------------------+----------------------------------------
--   table     | CREATE SNAPSHOT s FOR TABLE db t    | RESTORE TABLE db.t {SNAPSHOT = s}
--   database  | CREATE SNAPSHOT s FOR DATABASE db   | RESTORE DATABASE db FROM PITR p "ts"
--   account   | CREATE SNAPSHOT s FOR ACCOUNT acc   | RESTORE ACCOUNT acc FROM SNAPSHOT s
--   cluster   | CREATE SNAPSHOT s FOR CLUSTER       | RESTORE CLUSTER FROM SNAPSHOT s
-- Database-level snapshot/restore is multi-table ATOMIC.


-- =============================================================================
-- CLEANUP
-- =============================================================================
DROP SNAPSHOT IF EXISTS before_repricing;
DROP PITR IF EXISTS ops_pitr;
DROP DATABASE IF EXISTS rescue_demo;

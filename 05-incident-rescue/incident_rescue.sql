-- =============================================================================
-- MatrixOne Git4Data Tutorial — Part 4: Incident Rescue
-- Three layers of safety net: snapshot before, DIFF to investigate, PITR after.
--
-- Companion to "Git4Data Deep Dive (Part 4): Incident Rescue — From a
-- Fat-Fingered UPDATE to a Dropped Table, Roll Back in Seconds".
--
-- Run against a local MatrixOne:
--     docker run -d -p 6001:6001 --name matrixone matrixorigin/matrixone:4.0.0-rc1
--     mysql -h 127.0.0.1 -P 6001 -u root -p111 < incident_rescue.sql
--
-- Statements that need a live timestamp (PITR restore) or are intentionally
-- destructive (DROP TABLE) are COMMENTED OUT with instructions — uncomment
-- and run them by hand when you reach those steps.
-- =============================================================================


-- ---------- Setup: a database with standing PITR + a 1M-row orders table ----
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
-- LAYER 1 — Before any risky operation, press "save"
-- =============================================================================
CREATE SNAPSHOT before_repricing FOR TABLE rescue_demo orders;   -- milliseconds

-- The "risky bulk change" — and the accident: WHERE clause forgotten.
UPDATE orders SET amount = 0 WHERE order_id <= 500;   -- (simulated damage: 500 rows)


-- =============================================================================
-- LAYER 2 — Don't roll back yet: DIFF to see exactly what got damaged
-- =============================================================================

-- Damage scope: how many rows changed vs. the pre-incident snapshot?
DATA BRANCH DIFF orders AGAINST orders {SNAPSHOT='before_repricing'} OUTPUT SUMMARY;
--   metric   | orders | (snapshot side)
--   INSERTED |      0 |  0
--   DELETED  |      0 |  0
--   UPDATED  |    500 |  0          <- 500 rows damaged

-- Damage inventory: exactly which rows, changed to what.
DATA BRANCH DIFF orders AGAINST orders {SNAPSHOT='before_repricing'} OUTPUT LIMIT 10;

-- Assessed. Decide: full rollback (below), or repair only the listed rows.


-- =============================================================================
-- LAYER 1b — Roll back to the checkpoint (git reset --hard, for data)
-- =============================================================================
RESTORE TABLE rescue_demo.orders {SNAPSHOT = before_repricing};

SELECT COUNT(*) FROM orders WHERE amount = 0 AND order_id <= 500;   -- back to pre-accident


-- =============================================================================
-- LAYER 3 — No snapshot? PITR recovers any moment — even a dropped table
-- =============================================================================

-- TIMING NOTE: a PITR has a valid-from boundary (~its creation time). If you
-- just created ops_pitr above, wait 1-2 seconds or check SHOW PITR first.
SHOW PITR;

-- Step 1: note the current time (copy the value — you'll restore to it).
SELECT now();

-- Step 2: the worst accident there is. Uncomment to run by hand:
-- DROP TABLE orders;                                -- 1,000,000 rows, gone

-- Step 3: whole-database restore to the moment you noted. Replace the
-- timestamp with YOUR value from step 1, then uncomment:
-- RESTORE DATABASE rescue_demo FROM PITR ops_pitr "2026-06-10 15:45:00";
-- SELECT COUNT(*) FROM orders;                      -- 1000000, schema + data back

-- Verified end to end: a dropped 1M-row table comes back whole, not a row missing.


-- =============================================================================
-- Granularity recap — the same semantics from one table to the whole cluster
-- =============================================================================
--   scope     | save                                | recover
--   ----------+-------------------------------------+----------------------------------------
--   table     | CREATE SNAPSHOT s FOR TABLE db t    | RESTORE TABLE db.t {SNAPSHOT = s}
--   database  | CREATE SNAPSHOT s FOR DATABASE db   | RESTORE DATABASE db FROM PITR p "ts"
--   account   | CREATE SNAPSHOT s FOR ACCOUNT acc   | RESTORE ACCOUNT acc FROM SNAPSHOT s
--   cluster   | CREATE SNAPSHOT s FOR CLUSTER       | RESTORE CLUSTER FROM SNAPSHOT s
-- Database-level snapshot/restore is multi-table ATOMIC: all tables return to
-- the same instant together.


-- =============================================================================
-- CLEANUP
-- =============================================================================
DROP SNAPSHOT IF EXISTS before_repricing;
DROP PITR IF EXISTS ops_pitr;
DROP DATABASE IF EXISTS rescue_demo;

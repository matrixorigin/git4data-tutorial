-- =============================================================================
-- MatrixOne Git4Data Tutorial — Part 2: Hands On
-- Every Git primitive, runnable end to end on 1,000,000 rows.
--
-- Companion to the article "MatrixOne Git4Data Deep Dive (Part 2): From Zero,
-- Through Every Git Primitive".
--
-- Run it against a local MatrixOne (Docker):
--     docker run -d -p 6001:6001 --name matrixone matrixorigin/matrixone:4.0.0-rc1
--     mysql -h 127.0.0.1 -P 6001 -u root -p111 < git4data_primitives.sql
--
-- Lines that are intentionally COMMENTED OUT either (a) are expected to fail on
-- purpose (the conflict demo), or (b) need a value only you can supply (a live
-- timestamp for PITR). Uncomment them when you run those steps by hand.
-- =============================================================================


-- =============================================================================
-- STEP 1 — Load 1,000,000 rows (no external files; generated server-side)
-- =============================================================================
CREATE DATABASE git4data_demo;
USE git4data_demo;

CREATE TABLE orders (
    order_id BIGINT PRIMARY KEY,
    customer VARCHAR(32),
    amount   DECIMAL(10, 2),
    status   VARCHAR(16)
);

-- One statement generates a million rows entirely on the server.
INSERT INTO orders
SELECT result,
       concat('cust_', result % 10000),
       round(rand() * 1000, 2),
       CASE result % 3 WHEN 0 THEN 'paid' WHEN 1 THEN 'pending' ELSE 'cancelled' END
FROM generate_series(1, 1000000) g;

SELECT COUNT(*) FROM orders;   -- 1,000,000


-- =============================================================================
-- STEP 2 — commit / tag / reset:  CREATE SNAPSHOT  +  time travel  +  RESTORE
-- =============================================================================

-- commit / tag: press "save" on the current 1M-row state.
-- NOTE: in FOR TABLE, the database and table names are separated by a SPACE,
--       not a dot:  "git4data_demo orders", not "git4data_demo.orders".
CREATE SNAPSHOT v1 FOR TABLE git4data_demo orders;

SHOW SNAPSHOTS;

-- Simulate an accident: a fat-fingered delete of 1,000 orders.
DELETE FROM orders WHERE order_id <= 1000;
SELECT COUNT(*) FROM orders;                    -- 999000  (1000 rows gone)

-- Time travel: peek at the snapshot moment; the live table is NOT touched.
SELECT COUNT(*) FROM orders {snapshot = 'v1'};  -- 1000000 (intact in the past)

-- reset --hard: actually roll the table back to v1.
RESTORE TABLE git4data_demo.orders {SNAPSHOT = v1};
-- Equivalent form:
-- RESTORE TABLE git4data_demo.orders FROM SNAPSHOT v1;
SELECT COUNT(*) FROM orders;                    -- 1000000 (the 1000 rows are back)


-- =============================================================================
-- STEP 3 — clone:  zero-copy CLONE
-- =============================================================================

-- An independent copy that appears instantly and costs almost no space:
-- it records a pointer to existing data, it does not copy the data.
CREATE TABLE orders_copy CLONE orders;
SELECT COUNT(*) FROM orders_copy;               -- 1000000, appears instantly

-- Clone from a specific snapshot (e.g. a "dev env as of a past state"):
CREATE TABLE orders_at_v1 CLONE orders {SNAPSHOT = "v1"};

-- CLONE is the cheapest fork, but it records NO lineage. For row-level
-- diff/merge later, use DATA BRANCH CREATE (next step) instead.


-- =============================================================================
-- STEP 4 — branch:  DATA BRANCH CREATE  (lineage-tracked)
-- =============================================================================

-- Looks like CLONE, but records "where I branched from" so that later
-- DIFF / MERGE / PICK can find the lowest common ancestor automatically.
DATA BRANCH CREATE TABLE orders_dev FROM orders;

-- Diverge from the mainline: change 1,000 rows, add one new order.
UPDATE orders_dev SET status = 'shipped' WHERE order_id BETWEEN 5000 AND 5999;
INSERT INTO orders_dev VALUES (1000001, 'Frank', 400.00, 'paid');

SELECT COUNT(*) FROM orders;                    -- still 1000000 (mainline untouched)


-- =============================================================================
-- STEP 5 — diff:  DATA BRANCH DIFF  (row-level)
-- =============================================================================

-- Totals only. Returns in milliseconds even on 1M rows, because it scans only
-- the CHANGED objects, not the whole table.
DATA BRANCH DIFF orders_dev AGAINST orders OUTPUT SUMMARY;
--   INSERTED  1      (Frank)
--   UPDATED   1000   (the rows whose status changed)
--   DELETED   0

-- Other OUTPUT forms:
DATA BRANCH DIFF orders_dev AGAINST orders OUTPUT LIMIT 10;                 -- per-row diff
DATA BRANCH DIFF orders_dev AGAINST orders OUTPUT COUNT;                    -- single number
DATA BRANCH DIFF orders_dev AGAINST orders COLUMNS (status, amount) OUTPUT SUMMARY; -- only some columns

-- Export the diff as an executable SQL patch (DELETE + REPLACE INTO) that can
-- be applied to any MatrixOne instance with `mysql ... < diff_xxx.sql`.
-- DATA BRANCH DIFF orders_dev AGAINST orders OUTPUT FILE '/tmp/orders_diff/';


-- =============================================================================
-- STEP 6 — merge:  DATA BRANCH MERGE  (three-way, conflict-aware)
-- =============================================================================

-- Merge the branch back into the mainline.
DATA BRANCH MERGE orders_dev INTO orders;
SELECT COUNT(*) FROM orders;                    -- 1000001 (Frank merged in)

-- Conflict demo: two branches change the SAME row (order_id = 1).
DATA BRANCH CREATE TABLE orders_a FROM orders;
DATA BRANCH CREATE TABLE orders_b FROM orders;
UPDATE orders_a SET status = 'shipped'  WHERE order_id = 1;
UPDATE orders_b SET status = 'refunded' WHERE order_id = 1;

-- orders_a merges cleanly (no conflict yet).
DATA BRANCH MERGE orders_a INTO orders;

-- orders_b now collides on order_id = 1. The default WHEN CONFLICT is FAIL.
-- This statement is EXPECTED TO FAIL and roll back; uncomment to see the error:
-- DATA BRANCH MERGE orders_b INTO orders WHEN CONFLICT FAIL;

-- Resolve by choosing a policy:
DATA BRANCH MERGE orders_b INTO orders WHEN CONFLICT SKIP;    -- keep mainline (accept ours)
-- DATA BRANCH MERGE orders_b INTO orders WHEN CONFLICT ACCEPT; -- take branch  (accept theirs)

-- Key design: MatrixOne treats a row as a TRUE conflict only when BOTH sides
-- changed it. If only one side touched a row, the change is applied
-- automatically — so even on millions of changed rows, only the genuine
-- collisions need a human decision.


-- =============================================================================
-- STEP 7 — cherry-pick:  DATA BRANCH PICK  (promote only chosen rows)
-- =============================================================================

DATA BRANCH CREATE TABLE orders_fix FROM orders;
UPDATE orders_fix SET status = 'refunded' WHERE order_id IN (2, 4);
INSERT INTO orders_fix VALUES (1000002, 'Grace', 500.00, 'paid');

-- Promote ONLY order_id 2 and 1000002 into the mainline; leave everything else.
DATA BRANCH PICK orders_fix INTO orders KEYS (2, 1000002) WHEN CONFLICT ACCEPT;

SELECT order_id, status FROM orders WHERE order_id IN (2, 4, 1000002) ORDER BY order_id;
--   2        -> refunded  (cherry-picked)
--   4        -> unchanged (not picked)
--   1000002  -> Grace's new order (cherry-picked)

-- KEYS also accepts a subquery, so SQL decides which rows are picked:
-- DATA BRANCH PICK orders_fix INTO orders
--     KEYS (SELECT order_id FROM orders_fix WHERE customer = 'Grace')
--     WHEN CONFLICT ACCEPT;


-- =============================================================================
-- STEP 8 — rewind to any moment:  PITR (point-in-time recovery)
-- =============================================================================

-- SNAPSHOT is a save button you press; PITR is continuous history the database
-- keeps automatically. RANGE unit: 'h' hours / 'd' days (default) / 'mo' months / 'y' years.
CREATE PITR demo_pitr FOR DATABASE git4data_demo RANGE 1 'd';

-- Note "now", then do something destructive.
SELECT now();                                   -- e.g. 2026-06-04 14:03:07 — copy this value
-- DELETE FROM orders;                           -- worst case: whole table gone

-- Restore to that exact moment (timestamp format "YYYY-MM-DD HH:MM:SS").
-- Uncomment and replace the timestamp with the value you copied above:
-- RESTORE DATABASE git4data_demo FROM PITR demo_pitr "2026-06-04 14:03:07";
-- SELECT COUNT(*) FROM orders;                  -- rows are back


-- =============================================================================
-- STEP 9 — Beyond tables: database / account / cluster granularity
-- =============================================================================
-- Git4Data is not table-only. SNAPSHOT / RESTORE / PITR work at four levels —
-- table, database, account (tenant), and cluster. CLONE and DATA BRANCH work at
-- the table and database levels.
--
--   Operation        | table                  | database                  | account            | cluster
--   -----------------+------------------------+---------------------------+--------------------+--------------
--   CREATE SNAPSHOT  | FOR TABLE db t         | FOR DATABASE db           | FOR ACCOUNT acc    | FOR CLUSTER
--   RESTORE          | RESTORE TABLE ...      | RESTORE DATABASE ...      | RESTORE ACCOUNT ...| RESTORE CLUSTER ...
--   CREATE PITR      | FOR TABLE ...          | FOR DATABASE ...          | FOR ACCOUNT ...    | FOR CLUSTER
--   CLONE            | CREATE TABLE ... CLONE | CREATE DATABASE ... CLONE | (n/a)              | (n/a)
--   DATA BRANCH      | ... TABLE ... FROM     | ... DATABASE ... FROM     | (n/a)              | (n/a)

-- Database level — the most common "consistent version" granularity: snapshot a
-- whole database (features + labels + metadata tables together) and roll them
-- back atomically, keeping the training set consistent across tables.
CREATE SNAPSHOT db_v1 FOR DATABASE git4data_demo;
-- ... change several tables in the database ...
RESTORE DATABASE git4data_demo {SNAPSHOT = db_v1};   -- all tables atomically back to db_v1

-- Account (tenant) level — version every database & table under one tenant at
-- once; useful for per-customer isolated snapshots in multi-tenant SaaS.
--   CREATE SNAPSHOT acct_v1 FOR ACCOUNT myacct;
--   RESTORE ACCOUNT myacct {SNAPSHOT = acct_v1};     -- whole-tenant rollback (use with care)

-- Cluster level — a single snapshot/restore covering the entire instance
-- (typically for disaster recovery).
--   CREATE SNAPSHOT cluster_v1 FOR CLUSTER;
--   RESTORE CLUSTER {SNAPSHOT = cluster_v1};


-- =============================================================================
-- STEP 10 — Scale up: cost is independent of data size
-- =============================================================================
-- Load more data by raising the generate_series bound (offset order_id to avoid
-- primary-key collisions), then re-run the primitives above and watch SNAPSHOT
-- / CLONE / DATA BRANCH stay in the millisecond range regardless of table size.

-- Top the table up to 10,000,000 rows (adds 9M):
-- INSERT INTO orders
-- SELECT result + 2000000,
--        concat('cust_', result % 10000),
--        round(rand()*1000, 2),
--        CASE result % 3 WHEN 0 THEN 'paid' WHEN 1 THEN 'pending' ELSE 'cancelled' END
-- FROM generate_series(1, 9000000) g;

-- Measured on a single-node Docker MatrixOne 4.0.0-rc1, steady-state (median of
-- several runs; diff/merge each touch only 1000 rows):
--
--   table size | load  | SNAPSHOT | CLONE | DATA BRANCH | DIFF(1000) | MERGE(1000)
--   -----------+-------+----------+-------+-------------+------------+------------
--   1,000,000  | 0.5 s | 6 ms     | 6 ms  | 7 ms        | 13 ms      | 64 ms
--   10,000,000 | 5.3 s | 8 ms     | 8 ms  | 7 ms        | 21 ms      | 178 ms
--   100,000,000| 41 s  | 5 ms     | 25 ms | 19 ms       | 23 ms      | 189 ms
--
-- snapshot: dead constant (just names a metadata directory).
-- clone/branch: copy the metadata directory, not the data — 100x the data, clone
--   rises only 6ms -> 25ms (a few MB of metadata, never tens of GB of rows).
-- diff/merge: scale with HOW MANY ROWS CHANGED, not table size (merge also grows
--   with table size since it writes the changes back into the main table).
-- NOTE: the FIRST snapshot of a freshly loaded table is ~10-12 ms (a one-time
--   flush of in-memory data to object storage); it then drops to the above.


-- =============================================================================
-- STEP 11 — A complete "Git-flavored data" workflow (data curation before training)
-- =============================================================================
CREATE SNAPSHOT samples_v3_raw FOR TABLE git4data_demo orders;   -- pin the raw input

DATA BRANCH CREATE TABLE orders_clean FROM orders;               -- clean on a branch
DELETE FROM orders_clean WHERE amount < 200;
UPDATE orders_clean SET status = 'cancelled' WHERE status = 'pending';

DATA BRANCH DIFF orders_clean AGAINST orders OUTPUT SUMMARY;      -- review the change

DATA BRANCH MERGE orders_clean INTO orders WHEN CONFLICT FAIL;    -- gate passed -> publish

CREATE SNAPSHOT samples_v3 FOR TABLE git4data_demo orders;       -- "data used by model_v3"

-- ... if the model later regresses, roll back in one second:
-- RESTORE TABLE git4data_demo.orders {SNAPSHOT = samples_v3_raw};


-- =============================================================================
-- CLEANUP
-- =============================================================================
DROP SNAPSHOT IF EXISTS v1;
DROP SNAPSHOT IF EXISTS db_v1;
DROP SNAPSHOT IF EXISTS samples_v3_raw;
DROP SNAPSHOT IF EXISTS samples_v3;
DROP PITR IF EXISTS demo_pitr;
DROP DATABASE IF EXISTS git4data_demo;           -- drops all demo tables at once

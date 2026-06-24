-- =============================================================================
-- Git4Data Tutorial — Part 6: Collaborative Data Development (Data Ops in Practice)
-- Many engineers fork the same table, work in parallel, review, merge, resolve.
--
-- Companion to "Git4Data Deep Dive (Part 6) · Data Operations in Practice —
-- Collaborative Data Development: Merge Data the Way You Merge Code".
--
-- Verified end to end on MatrixOne v4.0.0-rc3.
--     docker run -d -p 6001:6001 --name matrixone matrixorigin/matrixone:4.0.0-rc3
--     mysql -h 127.0.0.1 -P 6001 -u root -p111 < collaborative_dev.sql
-- =============================================================================

-- Defensive cleanup so the script is re-runnable (a snapshot is account-scoped
-- and survives DROP DATABASE).
DROP SNAPSHOT IF EXISTS team_base;
DROP DATABASE IF EXISTS collab_demo;

CREATE DATABASE collab_demo;
USE collab_demo;

CREATE TABLE products (
    product_id BIGINT PRIMARY KEY,
    name       VARCHAR(64),
    category   VARCHAR(16),
    price      DECIMAL(10,2),
    descr      VARCHAR(64),
    status     VARCHAR(16)
);
INSERT INTO products
SELECT result, concat('prod_', result),
       CASE result % 3 WHEN 0 THEN 'A' WHEN 1 THEN 'B' ELSE 'C' END,
       round(rand()*100, 2),
       CASE WHEN result % 10 = 0 THEN NULL ELSE concat('desc_', result) END,
       'active'
FROM generate_series(1, 100000) g;

-- Pin the starting point the whole team forks from.
CREATE SNAPSHOT team_base FOR TABLE collab_demo products;


-- =============================================================================
-- SCENARIO 1 — several people maintain one master table in parallel
-- =============================================================================
DATA BRANCH CREATE TABLE products_alice FROM products;
DATA BRANCH CREATE TABLE products_bob   FROM products;
DATA BRANCH CREATE TABLE products_carol FROM products;

-- Division of work — IMPORTANT: split by ROW RANGES, not by columns. Conflicts
-- are detected per ROW: changing different columns of the SAME row still
-- conflicts. Disjoint key ranges guarantee clean merges.
UPDATE products_alice SET price = round(price * 1.10, 2)
WHERE category = 'A' AND product_id <= 30000;
UPDATE products_bob   SET descr = concat('backfilled_', product_id)
WHERE descr IS NULL AND product_id BETWEEN 30001 AND 60000;
UPDATE products_carol SET status = 'retired'
WHERE product_id BETWEEN 90000 AND 95000;

-- Self-review before merging (row-level, like glancing at your own diff).
DATA BRANCH DIFF products_alice AGAINST products OUTPUT SUMMARY;   -- UPDATED 10000
DATA BRANCH DIFF products_bob   AGAINST products OUTPUT SUMMARY;   -- UPDATED  3000
DATA BRANCH DIFF products_carol AGAINST products OUTPUT SUMMARY;   -- UPDATED  5001

-- Disjoint ranges -> merge cleanly, in any order, no coordination.
DATA BRANCH MERGE products_alice INTO products;
DATA BRANCH MERGE products_bob   INTO products;
DATA BRANCH MERGE products_carol INTO products;

SELECT COUNT(*) AS backfilled FROM products WHERE descr LIKE 'backfilled%';   -- 3000
SELECT COUNT(*) AS retired    FROM products WHERE status = 'retired';         -- 5001

DROP TABLE products_alice; DROP TABLE products_bob; DROP TABLE products_carol;


-- =============================================================================
-- SCENARIO 2 — turn a data change into a reviewable PR
-- =============================================================================
DATA BRANCH CREATE TABLE products_fix_1837 FROM products;
UPDATE products_fix_1837 SET category = 'A'
WHERE category = 'C' AND name LIKE 'prod_1%';        -- a category correction

-- Reviewer: scope, then row by row, then keep a .sql patch for the record.
DATA BRANCH DIFF products_fix_1837 AGAINST products OUTPUT SUMMARY;
DATA BRANCH DIFF products_fix_1837 AGAINST products OUTPUT LIMIT 20;
DATA BRANCH DIFF products_fix_1837 AGAINST products OUTPUT FILE '/tmp';

-- Approve -> merge ;  or reject -> DROP TABLE products_fix_1837 (production never touched).
DATA BRANCH MERGE products_fix_1837 INTO products;
DROP TABLE products_fix_1837;


-- =============================================================================
-- WHEN TWO PEOPLE COLLIDE — true vs false conflict, three policies
-- =============================================================================
DATA BRANCH CREATE TABLE products_dave FROM products;
DATA BRANCH CREATE TABLE products_erin FROM products;
UPDATE products_dave SET price = 1.00 WHERE product_id = 42;          -- Dave: row 42
UPDATE products_erin SET price = 2.00 WHERE product_id = 42;          -- Erin: row 42 (collision)
UPDATE products_erin SET status = 'retired' WHERE product_id = 20;    -- Erin: row 20 (no conflict)

DATA BRANCH MERGE products_dave INTO products;        -- Dave lands first; mainline 42 = 1.00

-- (1) FAIL (default): on ANY conflict the WHOLE merge aborts (even row 20 stays out).
--     Expected to error; uncomment to see it:
-- DATA BRANCH MERGE products_erin INTO products WHEN CONFLICT FAIL;

-- (2) SKIP: skip only the conflicting row; the rest merges.
DATA BRANCH MERGE products_erin INTO products WHEN CONFLICT SKIP;
SELECT price  FROM products WHERE product_id = 42;    -- 1.00   (Dave kept)
SELECT status FROM products WHERE product_id = 20;    -- retired (Erin merged)

-- (3) ACCEPT: conflicting row takes the branch value. (Separate branch to show it.)
DATA BRANCH CREATE TABLE products_frank FROM products;
UPDATE products_frank SET price = 42.42 WHERE product_id = 42;
DATA BRANCH MERGE products_frank INTO products WHEN CONFLICT ACCEPT;
SELECT price FROM products WHERE product_id = 42;     -- 42.42  (Frank's, branch wins)

-- cherry-pick: promote only chosen rows (PICK needs a primary key).
DATA BRANCH CREATE TABLE products_pick FROM products;
UPDATE products_pick SET status = 'hotfix' WHERE product_id IN (50, 51, 52);
DATA BRANCH PICK products_pick INTO products KEYS (50, 51) WHEN CONFLICT FAIL;
SELECT product_id, status FROM products WHERE product_id IN (50, 51, 52) ORDER BY product_id;
--   50 hotfix · 51 hotfix · 52 active   (only the picked keys were promoted)

DROP TABLE products_dave; DROP TABLE products_erin; DROP TABLE products_frank; DROP TABLE products_pick;


-- =============================================================================
-- CLEANUP
-- =============================================================================
DROP SNAPSHOT IF EXISTS team_base;
DROP DATABASE IF EXISTS collab_demo;

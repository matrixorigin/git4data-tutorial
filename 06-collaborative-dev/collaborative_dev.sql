-- =============================================================================
-- Git4Data Tutorial — Part 6: Collaborative Data Development
-- Multiple engineers fork the same table, work in parallel, merge back.
-- Run:  mysql -h 127.0.0.1 -P 6001 -u root -p111 < collaborative_dev.sql
-- =============================================================================

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

-- ---------------------------------------------------------------- fork x3
-- Each engineer gets their own lineage-tracked branch.
DATA BRANCH CREATE TABLE products_alice FROM products;
DATA BRANCH CREATE TABLE products_bob   FROM products;
DATA BRANCH CREATE TABLE products_carol FROM products;

-- Division of work — IMPORTANT: split by ROW RANGES, not by columns.
-- Conflicts are detected per ROW: if Alice changes the price and Bob the
-- description of the SAME row, that's still a conflict. Disjoint row ranges
-- guarantee clean merges.
UPDATE products_alice SET price = round(price * 1.10, 2)
WHERE category = 'A' AND product_id <= 30000;
UPDATE products_bob   SET descr = concat('backfilled_', product_id)
WHERE descr IS NULL AND product_id BETWEEN 30001 AND 60000;
UPDATE products_carol SET status = 'retired'
WHERE product_id BETWEEN 90000 AND 95000;

-- ---------------------------------------------------------- self-review
-- Before merging, each engineer reviews their own change set, row-level.
DATA BRANCH DIFF products_alice AGAINST products OUTPUT SUMMARY;
DATA BRANCH DIFF products_bob   AGAINST products OUTPUT SUMMARY;
DATA BRANCH DIFF products_carol AGAINST products OUTPUT SUMMARY;

-- ---------------------------------------------------------- merge back
-- Non-overlapping changes merge cleanly, in any order, no coordination.
DATA BRANCH MERGE products_alice INTO products;
DATA BRANCH MERGE products_bob   INTO products;
DATA BRANCH MERGE products_carol INTO products;

-- Mainline now carries all three change sets.
SELECT COUNT(*) FROM products WHERE descr LIKE 'backfilled%';
SELECT COUNT(*) FROM products WHERE status = 'retired';

-- ------------------------------------------------- when work overlaps
-- Dave and Erin both touch the same row -> a genuine collision.
DATA BRANCH CREATE TABLE products_dave FROM products;
DATA BRANCH CREATE TABLE products_erin FROM products;
UPDATE products_dave SET price = 1.00 WHERE product_id = 42;
UPDATE products_erin SET price = 2.00 WHERE product_id = 42;

DATA BRANCH MERGE products_dave INTO products;
-- Erin now collides on product_id=42. Default policy FAIL aborts and rolls
-- back, mainline untouched. Uncomment to see the error:
-- DATA BRANCH MERGE products_erin INTO products WHEN CONFLICT FAIL;

-- Resolve explicitly: keep mainline (Dave landed first), skip Erin's row.
DATA BRANCH MERGE products_erin INTO products WHEN CONFLICT SKIP;
SELECT price FROM products WHERE product_id = 42;   -- 1.00 (Dave's)

-- ---------------------------------------------------------------- cleanup
DROP TABLE products_alice;
DROP TABLE products_bob;
DROP TABLE products_carol;
DROP TABLE products_dave;
DROP TABLE products_erin;
DROP SNAPSHOT IF EXISTS team_base;
DROP DATABASE IF EXISTS collab_demo;

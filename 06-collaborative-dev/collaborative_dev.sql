-- =============================================================================
-- Git4Data Tutorial — Part 6: Collaborative Data Development (Data Ops in Practice)
-- Real activities that force data collaboration: a big-sale prep, a cross-system
-- migration, a compliance remediation — done with branch / diff / merge / pick.
--
-- Companion to "Git4Data Deep Dive (Part 6) · Data Operations in Practice —
-- Collaborative Data Development: Merge Data the Way You Merge Code".
--
-- Verified end to end on MatrixOne v4.0.0-rc3.
--     docker run -d -p 6001:6001 --name matrixone matrixorigin/matrixone:4.0.0-rc3
--     mysql -h 127.0.0.1 -P 6001 -u root -p111 < collaborative_dev.sql
-- =============================================================================

-- Re-runnable: a snapshot is account-scoped and survives DROP DATABASE.
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

CREATE SNAPSHOT team_base FOR TABLE collab_demo products;   -- the team's shared start


-- =============================================================================
-- ACTIVITY 1 — PREPPING A BIG SALE: pricing / ops / catalog teams, in parallel
-- =============================================================================
DATA BRANCH CREATE TABLE products_pricing FROM products;   -- pricing team
DATA BRANCH CREATE TABLE products_ops     FROM products;   -- operations team
DATA BRANCH CREATE TABLE products_catalog FROM products;   -- catalog team

-- Split by ROW RANGE (not by column): conflicts are per-row. Disjoint ranges
-- guarantee clean merges even when the work runs in parallel under a deadline.
UPDATE products_pricing SET price = round(price * 0.80, 2)              -- sale price
WHERE category = 'A' AND product_id <= 30000;
UPDATE products_ops     SET descr = concat('SALE_', product_id)        -- copy / blurbs
WHERE descr IS NULL AND product_id BETWEEN 30001 AND 60000;
UPDATE products_catalog SET status = 'retired'                         -- discontinue
WHERE product_id BETWEEN 90000 AND 95000;

-- Each team reviews its own change set before merging.
DATA BRANCH DIFF products_pricing AGAINST products OUTPUT SUMMARY;   -- UPDATED 10000
DATA BRANCH DIFF products_ops     AGAINST products OUTPUT SUMMARY;   -- UPDATED  3000
DATA BRANCH DIFF products_catalog AGAINST products OUTPUT SUMMARY;   -- UPDATED  5001

-- Disjoint ranges -> merge in any order, no coordination, no table lock.
DATA BRANCH MERGE products_pricing INTO products;
DATA BRANCH MERGE products_ops     INTO products;
DATA BRANCH MERGE products_catalog INTO products;

DROP TABLE products_pricing; DROP TABLE products_ops; DROP TABLE products_catalog;


-- =============================================================================
-- ACTIVITY 2 — A CROSS-SYSTEM MIGRATION: build it on a branch, mainline serves
-- =============================================================================
DATA BRANCH CREATE TABLE products_migration FROM products;

-- The migration logic (iterate on the branch over hours/days; mainline keeps
-- taking business reads/writes the whole time). Example: re-map category C -> D.
UPDATE products_migration SET category = 'D' WHERE category = 'C';

-- Acceptance: confirm the scope is exactly what you expect before cutover.
DATA BRANCH DIFF products_migration AGAINST products OUTPUT SUMMARY;

-- Cutover is one atomic, second-scale step. (If it goes wrong:
-- RESTORE TABLE collab_demo.products {SNAPSHOT = team_base} rolls back.)
DATA BRANCH MERGE products_migration INTO products;
DROP TABLE products_migration;


-- =============================================================================
-- ACTIVITY 3 — A COMPLIANCE REMEDIATION: every change reviewed and signed off
-- =============================================================================
DATA BRANCH CREATE TABLE products_review FROM products;
UPDATE products_review SET descr = 'REDACTED'
WHERE product_id <= 2000;                              -- e.g. scrub sensitive text

-- Reviewer/officer treats the branch as a PR: scope, row by row, keep a patch.
DATA BRANCH DIFF products_review AGAINST products OUTPUT SUMMARY;
DATA BRANCH DIFF products_review AGAINST products OUTPUT LIMIT 20;
DATA BRANCH DIFF products_review AGAINST products OUTPUT FILE '/tmp';   -- .sql patch for the record

-- Approve -> merge ;  reject -> DROP (production never touched).
DATA BRANCH MERGE products_review INTO products;
DROP TABLE products_review;


-- =============================================================================
-- WHEN TWO PEOPLE COLLIDE (during the sale: two people touch the same hot item)
-- =============================================================================
DATA BRANCH CREATE TABLE products_dave FROM products;
DATA BRANCH CREATE TABLE products_erin FROM products;
UPDATE products_dave SET price = 1.00 WHERE product_id = 42;          -- Dave: row 42
UPDATE products_erin SET price = 2.00 WHERE product_id = 42;          -- Erin: row 42 (collision)
UPDATE products_erin SET status = 'retired' WHERE product_id = 20;    -- Erin: row 20 (no conflict)

DATA BRANCH MERGE products_dave INTO products;        -- Dave lands first; mainline 42 = 1.00

-- (1) FAIL (default): ANY conflict aborts the WHOLE merge (row 20 stays out too).
--     Expected to error; uncomment to see it:
-- DATA BRANCH MERGE products_erin INTO products WHEN CONFLICT FAIL;

-- (2) SKIP: skip only the conflicting row; the rest merges.
DATA BRANCH MERGE products_erin INTO products WHEN CONFLICT SKIP;
SELECT price FROM products WHERE product_id = 42;     -- 1.00   (Dave kept)
SELECT status FROM products WHERE product_id = 20;    -- retired (Erin merged)

-- (3) ACCEPT: conflicting row takes the branch value.
DATA BRANCH CREATE TABLE products_frank FROM products;
UPDATE products_frank SET price = 42.42 WHERE product_id = 42;
DATA BRANCH MERGE products_frank INTO products WHEN CONFLICT ACCEPT;
SELECT price FROM products WHERE product_id = 42;     -- 42.42  (branch wins)

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

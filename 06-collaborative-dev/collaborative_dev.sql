-- =============================================================================
-- Git4Data Tutorial — Part 6: Collaborative Data Development (Data Ops in Practice)
-- A small ML/data team iterating on one shared feature table: branch per person,
-- diff your own change set, merge back, adjudicate conflicts, cherry-pick.
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

-- A churn-model feature table: one row per user, a few features + a label.
-- ~10% of `monetary` is missing (NULL); some `label`s are still unlabeled (NULL).
CREATE TABLE ml_features (
    user_id     BIGINT PRIMARY KEY,
    recency     INT,            -- days since last activity
    frequency   INT,            -- events in the window
    monetary    DECIMAL(10,2),  -- avg spend (NULL = missing)
    tenure_days INT,
    label       TINYINT         -- 0 / 1 / NULL (unlabeled)
);
INSERT INTO ml_features
SELECT result,
       result % 90,
       result % 50,
       CASE WHEN result % 10 = 0 THEN NULL ELSE round(rand()*500, 2) END,
       result % 365,
       CASE WHEN result % 7 = 0 THEN NULL ELSE result % 2 END
FROM generate_series(1, 100000) g;

CREATE SNAPSHOT team_base FOR TABLE collab_demo ml_features;   -- the team's shared start


-- =============================================================================
-- ACTIVITY 1 — three teammates iterate the feature table in parallel
--   Alice · feature engineering   Bob · data cleaning   Carol · new labeled data
-- =============================================================================
DATA BRANCH CREATE TABLE feat_alice FROM ml_features;   -- Alice
DATA BRANCH CREATE TABLE clean_bob  FROM ml_features;   -- Bob
DATA BRANCH CREATE TABLE data_carol FROM ml_features;   -- Carol

-- Split by ROW RANGE (not by column): conflicts are per-row. Disjoint ranges
-- guarantee clean merges even when everyone works at once.
-- Alice (owns 1–30000): recompute / calibrate the `monetary` feature.
UPDATE feat_alice SET monetary = round(monetary * 1.10, 2)
WHERE user_id <= 30000 AND monetary IS NOT NULL;
-- Bob (owns 30001–60000): clean — fill missing monetary, label the unlabeled.
UPDATE clean_bob SET monetary = 0     WHERE monetary IS NULL AND user_id BETWEEN 30001 AND 60000;
UPDATE clean_bob SET label    = 0     WHERE label    IS NULL AND user_id BETWEEN 30001 AND 60000;
-- Carol (owns 100001+): ingest a fresh batch of newly-labeled users.
INSERT INTO data_carol
SELECT result + 100000, result % 90, result % 50, round(rand()*500, 2), result % 365, result % 2
FROM generate_series(1, 2000) g;

-- Each reviews their own change set before merging (self-review = your PR diff).
DATA BRANCH DIFF feat_alice AGAINST ml_features OUTPUT SUMMARY;   -- UPDATED 27000
DATA BRANCH DIFF clean_bob  AGAINST ml_features OUTPUT SUMMARY;   -- UPDATED  6857 (nulls filled + labeled)
DATA BRANCH DIFF data_carol AGAINST ml_features OUTPUT SUMMARY;   -- INSERTED 2000 (new labeled users)

-- Disjoint ranges -> merge in any order, no coordination, no lock.
DATA BRANCH MERGE feat_alice INTO ml_features;
DATA BRANCH MERGE clean_bob  INTO ml_features;
DATA BRANCH MERGE data_carol INTO ml_features;
SELECT COUNT(*) AS rows_after_a1 FROM ml_features;          -- 102000 (2000 new rows merged in)
SELECT COUNT(*) AS still_missing FROM ml_features WHERE monetary IS NULL AND user_id BETWEEN 30001 AND 60000;  -- 0
DROP TABLE feat_alice; DROP TABLE clean_bob; DROP TABLE data_carol;


-- =============================================================================
-- ACTIVITY 2 — a big feature recompute on a branch; the current set keeps serving
--   (iterate for hours/days on the branch; mainline stays usable the whole time)
-- =============================================================================
DATA BRANCH CREATE TABLE feat_recompute FROM ml_features;

-- Re-derive a feature across the whole table (example: bucket `recency` into
-- 30-day buckets). Iterate as long as you need — mainline is untouched.
UPDATE feat_recompute SET recency = (recency DIV 30) * 30;
SELECT DISTINCT recency FROM feat_recompute ORDER BY recency;   -- 0 / 30 / 60 (bucketed)

-- Acceptance: confirm the scope before cutover.
DATA BRANCH DIFF feat_recompute AGAINST ml_features OUTPUT SUMMARY;

-- Cutover is one atomic, second-scale step. (If it goes wrong:
-- RESTORE TABLE collab_demo.ml_features {SNAPSHOT = team_base} rolls back.)
DATA BRANCH MERGE feat_recompute INTO ml_features;
DROP TABLE feat_recompute;


-- =============================================================================
-- ACTIVITY 3 — review before it enters the canonical set (data code review)
-- =============================================================================
DATA BRANCH CREATE TABLE feat_review FROM ml_features;
-- Author: relabel a slice found to be systematically mislabeled.
UPDATE feat_review SET label = 1 WHERE user_id <= 2000 AND label = 0;

-- Reviewer treats the branch as a PR: scope, row by row, keep a patch.
DATA BRANCH DIFF feat_review AGAINST ml_features OUTPUT SUMMARY;
DATA BRANCH DIFF feat_review AGAINST ml_features OUTPUT LIMIT 20;
DATA BRANCH DIFF feat_review AGAINST ml_features OUTPUT FILE '/tmp';   -- .sql patch for the record

-- Approve -> merge ;  reject -> DROP (the canonical set was never touched).
DATA BRANCH MERGE feat_review INTO ml_features;
DROP TABLE feat_review;


-- =============================================================================
-- WHEN TWO PEOPLE COLLIDE — Alice and Bob both recompute the SAME user's feature
-- =============================================================================
DATA BRANCH CREATE TABLE feat_alice2 FROM ml_features;
DATA BRANCH CREATE TABLE clean_bob2  FROM ml_features;
UPDATE feat_alice2 SET monetary = 11.00 WHERE user_id = 42;   -- Alice: user 42
UPDATE clean_bob2  SET monetary = 22.00 WHERE user_id = 42;   -- Bob:   user 42 (collision)
UPDATE clean_bob2  SET label    = 1     WHERE user_id = 20;   -- Bob:   user 20 (no conflict)

DATA BRANCH MERGE feat_alice2 INTO ml_features;        -- Alice lands first; mainline 42 monetary = 11.00

-- (1) FAIL (default): ANY conflict aborts the WHOLE merge (user 20 stays out too).
--     Expected to error; uncomment to see it:
-- DATA BRANCH MERGE clean_bob2 INTO ml_features WHEN CONFLICT FAIL;

-- (2) SKIP: skip only the conflicting row; the rest merges.
DATA BRANCH MERGE clean_bob2 INTO ml_features WHEN CONFLICT SKIP;
SELECT monetary FROM ml_features WHERE user_id = 42;   -- 11.00 (Alice kept)
SELECT label    FROM ml_features WHERE user_id = 20;   -- 1     (Bob merged)

-- (3) ACCEPT: conflicting row takes the branch value.
DATA BRANCH CREATE TABLE feat_carol2 FROM ml_features;
UPDATE feat_carol2 SET monetary = 33.33 WHERE user_id = 42;
DATA BRANCH MERGE feat_carol2 INTO ml_features WHEN CONFLICT ACCEPT;
SELECT monetary FROM ml_features WHERE user_id = 42;   -- 33.33 (branch wins)

-- cherry-pick: promote only chosen users (PICK needs a primary key).
DATA BRANCH CREATE TABLE feat_pick FROM ml_features;
UPDATE feat_pick SET recency = 999 WHERE user_id IN (50, 51, 52);
DATA BRANCH PICK feat_pick INTO ml_features KEYS (50, 51) WHEN CONFLICT FAIL;
SELECT user_id, recency FROM ml_features WHERE user_id IN (50, 51, 52) ORDER BY user_id;
--   50 -> 999 · 51 -> 999 · 52 -> unchanged   (only the picked keys were promoted)

DROP TABLE feat_alice2; DROP TABLE clean_bob2; DROP TABLE feat_carol2; DROP TABLE feat_pick;


-- =============================================================================
-- CLEANUP
-- =============================================================================
DROP SNAPSHOT IF EXISTS team_base;
DROP DATABASE IF EXISTS collab_demo;

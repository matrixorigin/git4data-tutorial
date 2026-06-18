-- =============================================================================
-- Git4Data Tutorial — Part 11: RLHF Preference Data
-- Majority-vote consensus in SQL, disputed pairs re-judged on a branch and
-- cherry-picked back, then the preference set pinned for reward-model training.
-- Run:  mysql -h 127.0.0.1 -P 6001 -u root -p111 < rlhf_preference.sql
-- =============================================================================

CREATE DATABASE rlhf_demo;
USE rlhf_demo;

-- Three annotators each voted A-or-B on every prompt pair.
CREATE TABLE votes (
    pair_id   BIGINT,
    annotator VARCHAR(16),
    choice    VARCHAR(1),          -- 'A' or 'B'
    PRIMARY KEY (pair_id, annotator)
);
INSERT INTO votes
SELECT result, 'ann1', CASE WHEN result % 10 < 6 THEN 'A' ELSE 'B' END FROM generate_series(1, 10000) g;
INSERT INTO votes
SELECT result, 'ann2', CASE WHEN result % 10 < 5 THEN 'A' ELSE 'B' END FROM generate_series(1, 10000) g;
INSERT INTO votes
SELECT result, 'ann3', CASE WHEN result % 10 < 7 THEN 'A' ELSE 'B' END FROM generate_series(1, 10000) g;

-- ------------------------------------------------- consensus, in plain SQL
-- The preference table: unanimous/majority pairs become training rows.
CREATE TABLE preferences (
    pair_id   BIGINT PRIMARY KEY,
    preferred VARCHAR(1),
    agreement INT                  -- 3 = unanimous, 2 = majority
);
INSERT INTO preferences
SELECT pair_id,
       CASE WHEN SUM(CASE WHEN choice='A' THEN 1 ELSE 0 END) >= 2 THEN 'A' ELSE 'B' END,
       CASE WHEN SUM(CASE WHEN choice='A' THEN 1 ELSE 0 END) IN (0,3) THEN 3 ELSE 2 END
FROM votes GROUP BY pair_id;

SELECT agreement, COUNT(*) FROM preferences GROUP BY agreement ORDER BY agreement DESC;
--   3 (unanimous) vs 2 (split 2-1): the 2-1 pairs are the shaky ones.

-- Pin v1: reward model RM1 trains on this exact preference set.
CREATE SNAPSHOT pref_v1 FOR TABLE rlhf_demo preferences;

-- ------------------------------------------------- re-judging, surgically
-- A senior reviewer re-judges the 2-1 pairs on a branch (here: flips a
-- specific disputed range after closer reading).
DATA BRANCH CREATE TABLE preferences_review FROM preferences;
UPDATE preferences_review
SET preferred = CASE preferred WHEN 'A' THEN 'B' ELSE 'A' END, agreement = 3
WHERE agreement = 2 AND pair_id BETWEEN 2000 AND 2199;     -- 200 overturned verdicts

-- Promote ONLY the overturned pairs — cherry-pick by key, nothing else moves.
DATA BRANCH PICK preferences_review INTO preferences
  KEYS (SELECT pair_id FROM preferences_review
        WHERE agreement = 3 AND pair_id BETWEEN 2000 AND 2199)
  WHEN CONFLICT ACCEPT;

-- ------------------------------------------------- versioned lineage
-- v2 = v1 + exactly those 200 re-judged pairs. DIFF proves it:
DATA BRANCH DIFF preferences AGAINST preferences {SNAPSHOT='pref_v1'} OUTPUT SUMMARY;
--   UPDATED = 200
CREATE SNAPSHOT pref_v2 FOR TABLE rlhf_demo preferences;

-- RM1 was trained on pref_v1, RM2 on pref_v2 — both remain exactly
-- reproducible, and the difference between them is 200 known rows, not vibes.
SELECT COUNT(*) FROM preferences {snapshot='pref_v1'};
SELECT COUNT(*) FROM preferences;

-- ---------------------------------------------------------------- cleanup
DROP TABLE preferences_review;
DROP SNAPSHOT IF EXISTS pref_v1;
DROP SNAPSHOT IF EXISTS pref_v2;
DROP DATABASE IF EXISTS rlhf_demo;

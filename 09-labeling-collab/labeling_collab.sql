-- =============================================================================
-- Git4Data Tutorial — Part 9: Collaborative Labeling
-- Each annotator labels on their own branch; disagreement on the same sample
-- IS the merge conflict; cross-branch SQL finds it before merging; a reviewer
-- cherry-picks final verdicts.
-- Run:  mysql -h 127.0.0.1 -P 6001 -u root -p111 < labeling_collab.sql
-- =============================================================================

CREATE DATABASE label_demo;
USE label_demo;

CREATE TABLE samples (
    id    BIGINT PRIMARY KEY,
    text  VARCHAR(128),
    label VARCHAR(16)            -- NULL = not yet labeled
);
INSERT INTO samples
SELECT result, concat('text_', result), NULL FROM generate_series(1, 10000) g;

-- Pin the pre-labeling state (we can always come back to it).
CREATE SNAPSHOT before_labeling FOR TABLE label_demo samples;

-- --------------------------------------------- each annotator gets a branch
DATA BRANCH CREATE TABLE samples_alice FROM samples;
DATA BRANCH CREATE TABLE samples_bob   FROM samples;

-- Work assignment: Alice 1-5000, Bob 5001-10000, PLUS both label 4901-5100
-- as a 200-row QC overlap (standard practice to measure agreement).
UPDATE samples_alice SET label = CASE WHEN id % 3 = 0 THEN 'neg' ELSE 'pos' END
WHERE id BETWEEN 1 AND 5100;
UPDATE samples_bob   SET label = CASE WHEN id % 5 = 0 THEN 'neg' ELSE 'pos' END
WHERE id BETWEEN 4901 AND 10000;

-- --------------------------------------------- agreement check BEFORE merging
-- Branches are just tables: one JOIN compares two annotators' work directly.
SELECT COUNT(*) AS qc_disagreements
FROM samples_alice a JOIN samples_bob b ON a.id = b.id
WHERE a.id BETWEEN 4901 AND 5100 AND a.label <> b.label;

-- The disagreement list goes to a reviewer:
CREATE TABLE review_queue AS
SELECT a.id, a.label AS alice_label, b.label AS bob_label
FROM samples_alice a JOIN samples_bob b ON a.id = b.id
WHERE a.id BETWEEN 4901 AND 5100 AND a.label <> b.label;

-- --------------------------------------------- merge the agreed work
DATA BRANCH MERGE samples_alice INTO samples;
-- Bob's branch now collides exactly on the overlap rows where they disagreed.
-- WHEN CONFLICT FAIL would refuse; we keep Alice's (already merged) labels and
-- take Bob's everywhere else:
DATA BRANCH MERGE samples_bob INTO samples WHEN CONFLICT SKIP;

SELECT COUNT(*) FROM samples WHERE label IS NOT NULL;   -- fully labeled

-- --------------------------------------------- reviewer verdicts, cherry-picked
-- The reviewer rules on the disputed rows (here: side with Bob) on a branch,
-- then ONLY those keys are promoted — nothing else moves.
DATA BRANCH CREATE TABLE samples_review FROM samples;
UPDATE samples_review r SET label = (
  SELECT q.bob_label FROM review_queue q WHERE q.id = r.id
) WHERE r.id IN (SELECT id FROM review_queue);

DATA BRANCH PICK samples_review INTO samples
  KEYS (SELECT id FROM review_queue)
  WHEN CONFLICT ACCEPT;

-- --------------------------------------------- audit trail + safety
-- Exactly what did this labeling campaign change?
DATA BRANCH DIFF samples AGAINST samples {SNAPSHOT='before_labeling'} OUTPUT SUMMARY;
-- And if the campaign must be redone from scratch:
-- RESTORE TABLE label_demo.samples {SNAPSHOT = before_labeling};

-- ---------------------------------------------------------------- cleanup
DROP TABLE samples_alice;
DROP TABLE samples_bob;
DROP TABLE samples_review;
DROP TABLE review_queue;
DROP SNAPSHOT IF EXISTS before_labeling;
DROP DATABASE IF EXISTS label_demo;

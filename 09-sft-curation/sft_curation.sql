-- =============================================================================
-- Git4Data Tutorial — Part 9: SFT Data Curation — clean in place, with receipts
-- Dedup / quality-filter / decontaminate with plain SQL, then use DIFF as the
-- provenance record of exactly what curation removed.
-- Run:  mysql -h 127.0.0.1 -P 6001 -u root -p111 < sft_curation.sql
-- =============================================================================

CREATE DATABASE sft_demo;
USE sft_demo;

-- Raw SFT pool: instructions + responses, with the usual diseases —
-- duplicates, low-quality rows, and eval-set contamination.
CREATE TABLE sft_samples (
    id          BIGINT PRIMARY KEY,
    instruction VARCHAR(128),
    response    VARCHAR(128),
    quality     DECIMAL(4,2),
    src         VARCHAR(16)
);
INSERT INTO sft_samples
SELECT result,
       concat('instr_', result % 80000),            -- ~20% duplicate instructions
       concat('resp_', result),
       round(rand()*10, 2),                          -- quality score 0-10
       CASE result % 4 WHEN 0 THEN 'crawl' WHEN 1 THEN 'human' ELSE 'distill' END
FROM generate_series(1, 100000) g;

-- The eval set we must NOT train on (contamination check target).
CREATE TABLE eval_set (instruction VARCHAR(128) PRIMARY KEY);
INSERT INTO eval_set
SELECT concat('instr_', result) FROM generate_series(100, 399) g;  -- 300 eval prompts

-- Pin the raw pool before touching anything.
CREATE SNAPSHOT sft_raw FOR TABLE sft_demo sft_samples;
SELECT COUNT(*) FROM sft_samples;                       -- 100,000

-- ------------------------------------------------- curation, in place
-- 1) Dedup: keep the first row per instruction.
DELETE FROM sft_samples
WHERE id NOT IN (
  SELECT * FROM (SELECT MIN(id) FROM sft_samples GROUP BY instruction) keep
);

-- 2) Quality floor: drop everything under 3.0.
DELETE FROM sft_samples WHERE quality < 3.0;

-- 3) Decontaminate: drop anything overlapping the eval set.
DELETE FROM sft_samples
WHERE instruction IN (SELECT instruction FROM eval_set);

SELECT COUNT(*) FROM sft_samples;                        -- the curated pool

-- ------------------------------------------------- receipts: what did we cut?
-- DIFF vs the raw snapshot = the audit trail of curation. Every removed row
-- is accounted for — reviewable, and recoverable if curation went too far.
DATA BRANCH DIFF sft_samples AGAINST sft_samples {SNAPSHOT='sft_raw'} OUTPUT SUMMARY;
--   DELETED = exactly the rows curation removed

-- Pin the curated version: this is what the SFT run trains on.
CREATE SNAPSHOT sft_v1 FOR TABLE sft_demo sft_samples;

-- Curation too aggressive? The raw pool is one statement away:
-- RESTORE TABLE sft_demo.sft_samples {SNAPSHOT = sft_raw};

-- ---------------------------------------------------------------- cleanup
DROP SNAPSHOT IF EXISTS sft_raw;
DROP SNAPSHOT IF EXISTS sft_v1;
DROP DATABASE IF EXISTS sft_demo;

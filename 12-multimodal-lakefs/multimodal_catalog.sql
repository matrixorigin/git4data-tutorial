-- =============================================================================
-- Git4Data Tutorial — Part 12: Multimodal Training Sets — MatrixOne x lakeFS
-- Bytes (images/video) live in lakeFS, versioned by commit. MatrixOne keeps
-- the CATALOG: file references pinned to a lakeFS commit + labels, all
-- versioned with git4data. A table snapshot then freezes "which bytes + which
-- labels" as ONE reproducible dataset version.
--
-- This file is self-contained: lakeFS commits are represented by their ids
-- (run a real lakeFS via docker to produce them; the catalog logic is
-- identical either way).
-- Run:  mysql -h 127.0.0.1 -P 6001 -u root -p111 < multimodal_catalog.sql
-- =============================================================================

CREATE DATABASE mm_demo;
USE mm_demo;

-- The catalog: one row per image. `uri` points into lakeFS BY COMMIT, so the
-- reference is immutable — re-exporting bytes produces a NEW commit + row update.
CREATE TABLE image_catalog (
    img_id        BIGINT PRIMARY KEY,
    lakefs_commit VARCHAR(16),
    uri           VARCHAR(256),     -- lakefs://repo/<commit>/imgs/<id>.jpg
    label         VARCHAR(16),
    quality       DECIMAL(4,2)
);

-- ------------------------------------------------- dataset v1
-- 10k images landed in lakeFS at commit c1a2b3; catalog + initial labels.
INSERT INTO image_catalog
SELECT result, 'c1a2b3',
       concat('lakefs://imgs/c1a2b3/imgs/', result, '.jpg'),
       CASE result % 4 WHEN 0 THEN 'cat' WHEN 1 THEN 'dog' WHEN 2 THEN 'bird' ELSE 'other' END,
       round(rand()*10, 2)
FROM generate_series(1, 10000) g;

-- Freeze dataset_v1: bytes pinned at c1a2b3 + labels as of now, atomically.
CREATE SNAPSHOT dataset_v1 FOR TABLE mm_demo image_catalog;
-- (model m1 trains on dataset_v1)

-- ------------------------------------------------- life happens, twice
-- (a) Labels change: a cleanup pass relabels a confused range.
UPDATE image_catalog SET label = 'cat' WHERE label = 'other' AND img_id < 500;

-- (b) BYTES change: 2000 images re-exported (better crops) -> lakeFS commit
--     c9d8e7. Only the catalog rows for those images move to the new commit:
UPDATE image_catalog
SET lakefs_commit = 'c9d8e7',
    uri = concat('lakefs://imgs/c9d8e7/imgs/', img_id, '.jpg')
WHERE img_id BETWEEN 3000 AND 4999;

-- Freeze dataset_v2.
CREATE SNAPSHOT dataset_v2 FOR TABLE mm_demo image_catalog;

-- ------------------------------------------------- byte-level time travel
-- Reproduce m1's EXACT inputs: resolve the catalog AT dataset_v1 — every uri
-- still points at commit c1a2b3, so lakeFS serves the original bytes.
SELECT lakefs_commit, COUNT(*) FROM image_catalog {snapshot='dataset_v1'}
GROUP BY lakefs_commit;
--   c1a2b3 | 10000          <- v1 is all original bytes

SELECT lakefs_commit, COUNT(*) FROM image_catalog GROUP BY lakefs_commit;
--   c1a2b3 | 8000, c9d8e7 | 2000   <- live set mixes old + re-exported bytes

-- What exactly changed between the two dataset versions? Row-level:
DATA BRANCH DIFF image_catalog AGAINST image_catalog {SNAPSHOT='dataset_v1'} OUTPUT SUMMARY;
--   UPDATED = relabeled rows + re-pointed rows, individually accountable

-- The division of labor:
--   lakeFS    versions the BYTES   (content-addressed commits)
--   MatrixOne versions the CATALOG (which bytes + which labels = a dataset)
--   a table snapshot stitches both into ONE reproducible version.

-- ---------------------------------------------------------------- cleanup
DROP SNAPSHOT IF EXISTS dataset_v1;
DROP SNAPSHOT IF EXISTS dataset_v2;
DROP DATABASE IF EXISTS mm_demo;

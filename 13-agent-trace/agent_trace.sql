-- =============================================================================
-- Git4Data Tutorial — Part 13: Agent Traces — queryable, joinable, versioned
-- Agent execution traces (OTel-style spans) land in a table: SQL rebuilds the
-- call tree and computes cost; snapshots pin "the traces as of release vN" so
-- A/B comparisons across agent versions are exact, not anecdotal.
-- Run:  mysql -h 127.0.0.1 -P 6001 -u root -p111 < agent_trace.sql
-- =============================================================================

CREATE DATABASE trace_demo;
USE trace_demo;

-- OTel GenAI-flavored span table (simplified).
CREATE TABLE spans (
    span_id   BIGINT PRIMARY KEY,
    trace_id  INT,
    parent_id BIGINT,              -- NULL = root (the user request)
    name      VARCHAR(32),         -- invoke_agent / chat / execute_tool
    model     VARCHAR(24),
    tokens    INT,
    dur_ms    INT,
    is_error  INT
);

-- ------------------------------------------------- agent v1 in production
-- 1000 traces, each: 1 root + 3 LLM calls + 2 tool calls (6 spans).
INSERT INTO spans
SELECT result,
       FLOOR((result-1) / 6),
       CASE WHEN result % 6 = 1 THEN NULL ELSE result - (result % 6) + 1 END,
       CASE result % 6 WHEN 1 THEN 'invoke_agent' WHEN 2 THEN 'chat'
                       WHEN 3 THEN 'execute_tool' WHEN 4 THEN 'chat'
                       WHEN 5 THEN 'execute_tool' ELSE 'chat' END,
       'model-a', 200 + result % 400, 100 + result % 900,
       CASE WHEN result % 97 = 0 THEN 1 ELSE 0 END
FROM generate_series(1, 6000) g;

-- Traces are just rows: rebuild one call tree with a self-join ...
SELECT s.name, s.tokens, s.dur_ms, p.name AS parent
FROM spans s LEFT JOIN spans p ON s.parent_id = p.span_id
WHERE s.trace_id = 7 ORDER BY s.span_id;

-- ... and compute fleet-level numbers nothing samples or approximates:
SELECT COUNT(DISTINCT trace_id)            AS traces,
       SUM(tokens)                         AS total_tokens,
       SUM(CASE WHEN is_error=1 THEN 1 ELSE 0 END) AS errors
FROM spans;

-- Pin the trace set that defines "agent v1's behavior."
CREATE SNAPSHOT traces_v1 FOR TABLE trace_demo spans;

-- ------------------------------------------------- agent v2 ships
-- New prompt + cheaper model; its traces accumulate into the same table.
INSERT INTO spans
SELECT 6000 + result,
       1000 + FLOOR((result-1) / 5),
       CASE WHEN result % 5 = 1 THEN NULL ELSE 6000 + result - (result % 5) + 1 END,
       CASE result % 5 WHEN 1 THEN 'invoke_agent' WHEN 2 THEN 'chat'
                       WHEN 3 THEN 'execute_tool' ELSE 'chat' END,
       'model-b', 150 + result % 300, 80 + result % 700,
       CASE WHEN result % 160 = 0 THEN 1 ELSE 0 END
FROM generate_series(1, 5000) g;

-- ------------------------------------------------- exact A/B, via versions
-- v1's world: the snapshot. v2's contribution: DIFF against it.
SELECT SUM(tokens) AS v1_tokens,
       SUM(CASE WHEN is_error=1 THEN 1 ELSE 0 END) AS v1_errors
FROM spans {snapshot='traces_v1'};

DATA BRANCH DIFF spans AGAINST spans {SNAPSHOT='traces_v1'} OUTPUT SUMMARY;
--   INSERTED = 5000   <- exactly the spans v2 produced, nothing mixed in

SELECT SUM(tokens) AS v2_tokens,
       SUM(CASE WHEN is_error=1 THEN 1 ELSE 0 END) AS v2_errors
FROM spans WHERE span_id > 6000;
-- tokens/trace down (model-b + shorter loop), error rate comparable:
-- the upgrade verdict comes from versioned data, not from eyeballing dashboards.

-- ---------------------------------------------------------------- cleanup
DROP SNAPSHOT IF EXISTS traces_v1;
DROP DATABASE IF EXISTS trace_demo;

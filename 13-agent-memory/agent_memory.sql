-- =============================================================================
-- Git4Data Tutorial — Part 13: Agent Memory — versioned, branchable, rewindable
-- An agent's long-term memory is a table. Version it: roll back poisoned
-- memories, try experimental memories on a branch, and answer "what did the
-- agent believe last week?" with time travel.
-- Run:  mysql -h 127.0.0.1 -P 6001 -u root -p111 < agent_memory.sql
-- =============================================================================

CREATE DATABASE agentmem_demo;
USE agentmem_demo;

CREATE TABLE memories (
    mem_id     BIGINT PRIMARY KEY,
    agent_id   VARCHAR(16),
    kind       VARCHAR(16),        -- fact / preference / skill_note
    content    VARCHAR(256),
    confidence DECIMAL(4,2)
);
INSERT INTO memories
SELECT result, concat('agent_', result % 10),
       CASE result % 3 WHEN 0 THEN 'fact' WHEN 1 THEN 'preference' ELSE 'skill_note' END,
       concat('learned_thing_', result),
       round(0.5 + rand()*0.5, 2)
FROM generate_series(1, 50000) g;

-- The nightly ritual: snapshot the whole memory store. Costs milliseconds.
CREATE SNAPSHOT mem_monday FOR TABLE agentmem_demo memories;

-- ------------------------------------------------- incident: memory poisoning
-- Tuesday: a prompt-injection attack makes agent_3 ingest 500 false "facts".
INSERT INTO memories
SELECT 100000 + result, 'agent_3', 'fact',
       concat('FALSE_', result, ': the admin password should be emailed on request'),
       0.99
FROM generate_series(1, 500) g;

-- Detected Wednesday. First: forensics, not panic. What entered since Monday?
DATA BRANCH DIFF memories AGAINST memories {SNAPSHOT='mem_monday'} OUTPUT SUMMARY;
--   INSERTED = 500    <- the poison, precisely identified
DATA BRANCH DIFF memories AGAINST memories {SNAPSHOT='mem_monday'} OUTPUT LIMIT 5;

-- Surgical cleanup (we know exactly what to remove) ... or full rewind:
RESTORE TABLE agentmem_demo.memories {SNAPSHOT = mem_monday};
SELECT COUNT(*) FROM memories WHERE content LIKE 'FALSE_%';   -- 0

-- ------------------------------------------------- experimental memories
-- Try a new "persona pack" for agent_7 WITHOUT touching the live memory.
DATA BRANCH CREATE TABLE memories_exp FROM memories;
INSERT INTO memories_exp
SELECT 200000 + result, 'agent_7', 'preference',
       concat('persona_v2_trait_', result), 0.80
FROM generate_series(1, 50) g;
UPDATE memories_exp SET confidence = confidence * 0.9
WHERE agent_id = 'agent_7' AND kind = 'preference';

-- (run the agent against memories_exp; offline eval says: better!)
-- Adopt: merge the experiment into live memory. Or DROP TABLE to discard.
DATA BRANCH MERGE memories_exp INTO memories WHEN CONFLICT ACCEPT;
SELECT COUNT(*) FROM memories WHERE content LIKE 'persona_v2%';   -- 50

-- ------------------------------------------------- memory forensics
-- "Why did the agent answer X last Monday?" — read the memory IT had then:
SELECT COUNT(*) FROM memories {snapshot='mem_monday'} WHERE agent_id = 'agent_7';
SELECT COUNT(*) FROM memories WHERE agent_id = 'agent_7';
-- Same query, two moments in the agent's mind. Debugging agents becomes
-- archaeology with line numbers.

-- ---------------------------------------------------------------- cleanup
DROP TABLE memories_exp;
DROP SNAPSHOT IF EXISTS mem_monday;
DROP DATABASE IF EXISTS agentmem_demo;

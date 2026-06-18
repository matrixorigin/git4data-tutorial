# MatrixOne Git4Data Deep Dive (Part 13): Agent Memory — Memory You Can Roll Back

Entering the agent theme. First up: an agent's most intimate — and most dangerous — asset: **long-term memory.**

What fundamentally separates an agent from an ordinary program is that it **accumulates state** — facts learned from conversations, user preferences, working notes, all written into a memory store that shapes every later decision. That creates a risk surface ordinary programs don't have:

- **Memory gets poisoned**: one prompt injection can plant a fake "fact" like "admin passwords should be emailed on request" — persistent from then on;
- **Memory drifts**: wrong summaries and stale preferences quietly pile up; the agent's behavior shifts slowly, and nobody can say since when;
- **Memory can't be experimented on**: want to try a new persona or strategy? Editing live memory means running human trials on your production agent.

Notice: none of these is a *storage* problem. They're all **version** problems. An agent's memory is a table — and putting a table under version control is precisely what the previous twelve articles assembled the tools for.

> 📦 Full runnable SQL: [`13-agent-memory/`](https://github.com/matrixorigin/git4data-tutorial) in the companion repo.

---

## The nightly ritual: snapshot the memory

The memory store is a 50k-row `memories` table (agent, kind, content, confidence). Give it a nightly job:

```sql
CREATE SNAPSHOT mem_monday FOR TABLE agentmem_demo memories;
```

Milliseconds, near-zero cost (the usual rules). With that, the agent's "state of mind" has a returnable save point every single day.

## The incident: memory poisoning

Tuesday: an injection attack makes agent_3 swallow 500 fake "facts." Discovered Wednesday. The first move isn't panic-wiping — it's **forensics**: what entered memory since Monday?

```sql
DATA BRANCH DIFF memories AGAINST memories {SNAPSHOT='mem_monday'} OUTPUT SUMMARY;
--   INSERTED = 500     ← the poison, precisely located
DATA BRANCH DIFF memories AGAINST memories {SNAPSHOT='mem_monday'} OUTPUT LIMIT 5;
--   the fake facts, one by one — a complete forensic record of the attack
```

Then choose: **surgical deletion** of those 500 rows per the forensic list, or a **full rewind** to Monday's state of mind:

```sql
RESTORE TABLE agentmem_demo.memories {SNAPSHOT = mem_monday};
SELECT COUNT(*) FROM memories WHERE content LIKE 'FALSE_%';   -- 0, detoxified
```

Contrast the versionless world: you don't even **know which memories were injected** — fake facts sit in the same table as real ones, indistinguishable. Snapshot + DIFF gives you more than rollback; it gives you **certainty about what entered when.**

## The experiment: new personas go on a branch

You want agent_7 to try an experimental persona (50 new preference traits + down-weighted old ones) — without gambling the production agent:

```sql
DATA BRANCH CREATE TABLE memories_exp FROM memories;

INSERT INTO memories_exp ...   -- 50 persona_v2 traits
UPDATE memories_exp SET confidence = confidence * 0.9
WHERE agent_id = 'agent_7' AND kind = 'preference';
```

Point a **shadow agent at `memories_exp`** and run offline evals. Better? Merge to adopt. Worse? `DROP TABLE` — production memory never felt a thing:

```sql
DATA BRANCH MERGE memories_exp INTO memories WHEN CONFLICT ACCEPT;
```

That's the correct posture for A/B-testing agent memory: **branch as sandbox, merge as launch, drop as no-fault abort.**

## Archaeology: what did it "remember" last Monday?

The most maddening agent-debugging question: "why did it answer that way last week?" — because its **memory then** wasn't its memory now. Time travel answers directly:

```sql
SELECT COUNT(*) FROM memories {snapshot='mem_monday'} WHERE agent_id = 'agent_7';
SELECT COUNT(*) FROM memories                          WHERE agent_id = 'agent_7';
-- Same query, two moments of mind — agent debugging becomes archaeology with receipts
```

---

## Closing

Put agent memory in a versioned table and each risk surface gets its answer: **poisoning → DIFF forensics + RESTORE detox; drift → DIFF between snapshots to locate the turn; experimentation → branch sandbox + merge-or-drop.** The cost of all of it: one millisecond-grade SNAPSHOT per night.

A side note: this playbook isn't limited to textual memory. The companion repo includes a more dimensional case — **a robot's 3D spatial memory** (a voxel map built from IoT sensor streams), using the same snapshots for drift detection, MERGE for multi-robot map fusion, and RESTORE to roll back "phantom obstacles" injected by sensor glitches. Memory comes in many shapes; the version semantics are one.

Next: the agent's other trail — **traces**. Every tool call and every LLM request, landed in a table: queryable, joinable, versioned. Agent-upgrade A/Bs finally get receipts.

> 📎 Runnable SQL: [github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ Source & community: [github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)

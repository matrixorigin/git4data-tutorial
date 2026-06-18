# MatrixOne Git4Data Deep Dive (Part 14): Agent Traces — A Versioned Record of What Your Agent Did

Second article of the agent theme, on the other core data class besides memory: **traces.**

When an agent handles one request, internally it's a chain of actions: receive task → call the LLM to plan → call tools → call the LLM again to summarize... Each step's latency, tokens, and success form a call tree (OpenTelemetry's GenAI conventions call them spans). These traces are the raw evidence for every agent-engineering question: **why slow? why expensive? why wrong? did the upgrade actually help?**

Traces usually get shipped to a dedicated APM/observability platform. That path is strong for dashboards, but two things it does poorly — **and they happen to be what agent engineering needs most**:

1. **Traces can't join business data**: "are the failing requests concentrated on some user segment / dataset shard?" requires trace JOIN business tables — and your business tables don't live in the observability platform;
2. **Traces have no version semantics**: "agent v1-era traces" and "v2-era traces" blur together on one timeline; A/Bs get cut by time windows, with fuzzy edges.

Land the traces in git4data, and both problems dissolve in passing.

> 📦 Full runnable SQL: [`14-agent-trace/`](https://github.com/matrixorigin/git4data-tutorial) in the companion repo — which also contains a complete implementation writing a real agent's spans into MatrixOne via the actual OpenTelemetry SDK and a custom exporter.

---

## Traces are rows

An OTel-style span table (simplified): trace_id, span_id, parent_id, name, model, tokens, duration, error flag. Agent v1 ran 1,000 production requests; 6,000 spans landed.

Traces being rows means **the full power of SQL applies directly**. Rebuilding a call tree is a self-join:

```sql
SELECT s.name, s.tokens, s.dur_ms, p.name AS parent
FROM spans s LEFT JOIN spans p ON s.parent_id = p.span_id
WHERE s.trace_id = 7 ORDER BY s.span_id;
```

Fleet-level metrics with no sampling, no approximation:

```sql
SELECT COUNT(DISTINCT trace_id) AS traces,
       SUM(tokens)              AS total_tokens,
       SUM(CASE WHEN is_error=1 THEN 1 ELSE 0 END) AS errors
FROM spans;
```

Plus what observability platforms can't offer: **trace JOIN business tables** — "which dataset shard drives the highest tokens per request," "what's the profile of users behind the failing requests" — because they live in the same database.

## A snapshot = a sealed archive of one agent version's behavior

Here's the key move. Before agent v1 upgrades to v2 (new prompt, cheaper model):

```sql
CREATE SNAPSHOT traces_v1 FOR TABLE trace_demo spans;
```

This snapshot isn't a "backup" — it's a **sealed archive of v1-era behavior**: all of v1's traces pinned, so v2's traces can pour into the same table without the two eras contaminating each other.

## The A/B, with version semantics

v2 ships; 5,000 new spans land. Now the upgrade review:

```sql
-- v1's world, in full: read the snapshot
SELECT SUM(tokens), SUM(CASE WHEN is_error=1 THEN 1 ELSE 0 END)
FROM spans {snapshot='traces_v1'};

-- v2's net contribution: one DIFF, row-precise boundary
DATA BRANCH DIFF spans AGAINST spans {SNAPSHOT='traces_v1'} OUTPUT SUMMARY;
--   INSERTED = 5000   ← exactly the spans v2 produced, nothing mixed in
```

The comparison: v2's tokens per request drop markedly (new model + a shorter loop), error rate holds — **the upgrade verdict comes from versioned data, not from eyeballing dashboard curves.** And if v2 had regressed, you'd hold two precisely bounded cohorts, ready for trace-by-trace drill-down.

The paradigm shift deserves naming: observability platforms cut versions by **time** ("we shipped... Tuesday afternoon-ish"); git4data cuts versions by **version** — the boundary sits wherever the snapshot was taken, immune to deployment-time fuzziness.

---

## Honest boundary: this does not replace APM

Per this series' standing habit, the boundary stated plainly: if your need is **massive real-time monitoring** — million-spans-per-second ingest, p99 dashboards, TTL expiry, alerting ecosystems — a dedicated engine like ClickHouse remains the righter tool; we've benchmarked the gap and it's real.

The git4data path's sweet spot is **agent-engineering analysis and regression**: moderate trace volume, joins against business data, exact per-version A/Bs, and long-lived sealed archives of "how version N behaved." The two paths aren't exclusive — many teams run APM for live dashboards while landing a copy of traces in the database for deep analysis.

---

## Closing

With traces landed, the agent-engineering evidence chain closes: **memory** (last part) records what it *knows*; **traces** (this part) record what it *did* — both versioned, both SQL-queryable, both JOIN-able in one database.

One puzzle piece remains: letting the agent use this evidence to **improve itself**. Next, the series finale — **agent self-evolution**: branch the brain into candidates, evaluate in isolation, merge the winner, discard the rest, all machine-driven. The figure this series has been setting up since Part 1 finally starts to run.

> 📎 Runnable SQL: [github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ Source & community: [github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)

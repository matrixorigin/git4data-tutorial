# MatrixOne Git4Data Tutorial

Runnable companion code for the **MatrixOne Git4Data Deep Dive** article series —
Git-style version control for data at scale (`commit`, `branch`, `diff`, `merge`,
`cherry-pick`, time travel), built into [MatrixOne](https://github.com/matrixorigin/matrixone).

> What is Git4Data? If you treat a database as a Git repository and a table as a
> file in it, MatrixOne lets you run everyday Git operations — snapshot, clone,
> branch, diff, merge, cherry-pick, restore — over terabytes of data, almost
> instantly. It's the same workflow software engineers use on code, now on data.

## The series

| Part | Topic | Code here |
|------|-------|-----------|
| 1 | The Git moment for data at scale (concept) | — |
| 2 | **Hands on: from zero, through every Git primitive** | [`02-hands-on/`](02-hands-on/) |
| … | more coming (implementation principles, ML/agent scenarios) | |

Each later tutorial will add its own folder here.

## Quick start (5 minutes)

```bash
# 1. Run a local MatrixOne (open source, MySQL-compatible)
docker run -d -p 6001:6001 --name matrixone matrixorigin/matrixone:latest

# 2. Run the Part 2 walkthrough — every Git primitive on 1,000,000 rows
mysql -h 127.0.0.1 -P 6001 -u root -p111 < 02-hands-on/git4data_primitives.sql
```

Default credentials: user `root`, password `111`, port `6001`.

## What Part 2 covers

[`02-hands-on/git4data_primitives.sql`](02-hands-on/git4data_primitives.sql) is a
single, copy-paste-runnable script (English comments) that walks through:

- **commit / tag / reset** — `CREATE SNAPSHOT`, time-travel `SELECT … {snapshot=…}`, `RESTORE`
- **clone** — zero-copy `CREATE TABLE … CLONE`
- **branch** — lineage-tracked `DATA BRANCH CREATE`
- **diff** — row-level `DATA BRANCH DIFF … OUTPUT SUMMARY / COUNT / LIMIT / FILE`
- **merge** — three-way `DATA BRANCH MERGE … WHEN CONFLICT FAIL | SKIP | ACCEPT`
- **cherry-pick** — `DATA BRANCH PICK … KEYS(…)`
- **point-in-time recovery** — `CREATE PITR` + `RESTORE … FROM PITR "…"`
- **granularity** — the same semantics at **table / database / account / cluster** levels
- **scale** — measured numbers showing snapshot/clone/branch cost is independent of table size

It loads a million rows with a single `generate_series` statement (no external
files needed) and cleans up after itself.

## Measured: cost is independent of data size

Same table, same operations, on a single-node Docker MatrixOne (diff/merge each
touch only 1,000 rows):

| table size | load | `CREATE SNAPSHOT` | `CLONE` | `DATA BRANCH CREATE` | `DIFF` (1000) | `MERGE` (1000) |
|---|---|---|---|---|---|---|
| 1,000,000 | 0.55 s | 5.9 ms | 6.7 ms | 7.1 ms | 11 ms | 62 ms |
| 10,000,000 | 5.5 s | 9.7 ms | 9.6 ms | 18.6 ms | 17.5 ms | 223 ms |
| 100,000,000 | 42 s | 45 ms | 146 ms | 229 ms | 219 ms | 2.9 s |

Snapshot / clone / branch stay ~constant (they move metadata, not data); diff /
merge scale with *how many rows changed*, not table size.

## Links

- MatrixOne: https://github.com/matrixorigin/matrixone
- Docs: https://docs.matrixorigin.cn/

## License

Apache 2.0

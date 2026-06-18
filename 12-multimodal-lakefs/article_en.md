# MatrixOne Git4Data Deep Dive (Part 12): Multimodal Training Sets — lakeFS Owns the Bytes, MatrixOne Owns the Catalog

The four training articles so far handled **structured rows**: samples, labels, preference pairs. But vision/multimodal training sets carry another half — **the raw bytes of images, audio, video**. And that half, frankly, is not git4data's home turf.

Part 3's boundaries said it plainly: git4data versions a file's *reference*, not its bytes. Content-level version management for millions of images belongs to **lakeFS**-class tools — git-for-data over object storage, where commits/branches/merges operate on files. So what about multimodal training sets?

The answer isn't either/or. It's **each owns half, stitched together**:

> **lakeFS versions the bytes; MatrixOne versions the catalog (which files + which labels); one table snapshot pins both worlds into a single reproducible dataset version.**

> 📦 The catalog-side SQL runs end to end (the lakeFS side represented by commit ids): [`12-multimodal-lakefs/`](https://github.com/matrixorigin/git4data-tutorial) in the companion repo.

---

## The key design: the catalog references bytes BY COMMIT

In MatrixOne, a catalog table, one row per image. The crux is how `uri` is built — **the path carries the lakeFS commit id**:

```sql
CREATE TABLE image_catalog (
    img_id        BIGINT PRIMARY KEY,
    lakefs_commit VARCHAR(16),
    uri           VARCHAR(256),    -- lakefs://repo/<commit>/imgs/<id>.jpg
    label         VARCHAR(16),
    quality       DECIMAL(4,2)
);
```

Why not just `lakefs://repo/main/...` (pointing at a branch)? Because branches move; **commits don't.** Referencing by commit makes each catalog row an **immutable reference**: however lakeFS evolves afterwards, that uri resolves to the same bytes forever. This is the fulcrum of the whole integration.

Ten thousand images land in lakeFS at commit `c1a2b3`; the catalog is loaded, labels in place. Then:

```sql
CREATE SNAPSHOT dataset_v1 FOR TABLE mm_demo image_catalog;
```

**That one table snapshot pins both worlds at once**: the byte side (the commit inside every uri) and the label side (the label column's values at that moment). Model m1 trains on it.

## Two kinds of change, cleanly separated

A multimodal dataset evolves along two independent axes, and this architecture keeps them distinct:

**Labels change** (pure MatrixOne side):

```sql
UPDATE image_catalog SET label = 'cat' WHERE label = 'other' AND img_id < 500;
```

**Bytes change** (both sides, in concert): 2,000 images get re-exported (better crops), lakeFS produces new commit `c9d8e7`, and **only those rows'** references move with it:

```sql
UPDATE image_catalog
SET lakefs_commit = 'c9d8e7',
    uri = concat('lakefs://imgs/c9d8e7/imgs/', img_id, '.jpg')
WHERE img_id BETWEEN 3000 AND 4999;
```

Pin again: `CREATE SNAPSHOT dataset_v2 ...`.

## Byte-level time travel

Now multimodal's hardest problem — "reproduce m1's exact inputs" — becomes a time-travel query:

```sql
SELECT lakefs_commit, COUNT(*) FROM image_catalog {snapshot='dataset_v1'}
GROUP BY lakefs_commit;
--   c1a2b3 | 10000      ← every uri in v1 still points at the original bytes

SELECT lakefs_commit, COUNT(*) FROM image_catalog GROUP BY lakefs_commit;
--   c1a2b3 | 8000, c9d8e7 | 2000   ← the live set mixes old and new bytes
```

Resolve the catalog at `dataset_v1` and every uri points at commit `c1a2b3` — lakeFS serves **the bytes as they were**. Labels likewise return to their values at that moment. **Neither side can do this alone**: lakeFS doesn't know "which files plus which labels constitute a dataset"; MatrixOne doesn't hold bytes. The commit-pinned catalog stitches the two version semantics together.

And what changed between the two dataset versions stays row-level queryable, as always:

```sql
DATA BRANCH DIFF image_catalog AGAINST image_catalog {SNAPSHOT='dataset_v1'} OUTPUT SUMMARY;
--   UPDATED = relabeled rows + re-pointed rows, each individually accountable
```

---

## The division of labor

| | lakeFS | MatrixOne |
|---|---|---|
| What it versions | file bytes (content-addressed commits) | catalog rows: references + labels + metadata |
| Strengths | massive unstructured data, byte-level dedup | row-level diff/merge, SQL compute, snapshot atomicity |
| A dataset version | — (knows only files) | **table snapshot = byte version × label version** |

One honest note on engineering cost: this combination means operating a lakeFS (plus object storage). If your multimodal scale is still small, or the bytes rarely change, a MatrixOne catalog over plain object-store paths works fine to start — add lakeFS when the bytes themselves need versioning. The architecture is incremental; no need to adopt it all at once.

---

## Closing

That wraps the training theme. Five articles form one production line: incremental training (7), curation (8), labeling (9), preferences (10), multimodal (11) — structured rows to git4data, massive bytes to lakeFS, boundaries clear, composition deliberate.

The next theme is the terminus this series announced at its very start: **agents**. First stop, the thing closest to an agent's skin — **memory**. An agent's memory is a table. And a table, by now, we know exactly how to put under version control.

> 📎 Runnable SQL: [github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ Source & community: [github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)

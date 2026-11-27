# Improvement: keep topic tables' size in line with their data

> **Status:** done in 44afee6 (FINDINGS §121): the lake's topic tables went from 727 MB to 40 MB with every record intact.

For a coding agent working in ako/DuckGraphLake.

## The problem

The Iceberg tables that Kafka topics become (`warpstream/_tableflow/<table>/`) grow far beyond the data they hold, and they keep growing faster the longer the server runs. Measured on build 46ec4c0, after about 36 hours of a dev stack:

| Table | Current snapshot | On disk | Metadata | Files |
|---|---|---|---|---|
| `local__openf1` (HTTP events, 967 records) | 11 data files, 22 MB | 338 MB | 153 MB | 2,902 |
| `local__cdc.<App>.LiveSyncState.1.local` (one row, updated each minute) | about 0.5 MB | 333 MB | 321 MB | 4,093 |

The Status page reports 657 MB of "Topic tables" for about 23 MB of current data.

There are three causes, and each needs its own fix:

1. **Snapshots are never expired.** Each flush (`flush_ms`, 1 s) that has data commits a snapshot, about 20 an hour for the CDC table above, so it holds 836. None is ever removed.
2. **Files replaced by compaction stay on disk.** The README says so: "The replaced files stay on disk for older snapshots." `local__openf1` keeps 602 data files (193 MB), of which the current snapshot uses 11 (22 MB).
3. **Every metadata file repeats the whole history, and every old one is kept.** Each commit writes a new `vN.metadata.json` that lists every snapshot, snapshot-log entry and metadata-log entry so far. `v1` was 4 KB and `v721` is 648 KB, so the total grows with the square of the number of commits: 839 files and 316 MB of JSON for a table with 12 MB of data files. At the current pace that is about 6 GB after a week and about 100 GB after a month, for one table. Every query reads the newest metadata file, so queries slow down as well.

## What to build

### 1. Expire snapshots

After a commit or a compaction, a table keeps its newest snapshots and drops the rest from its metadata. Configurable under `[kafka]`, with defaults that keep a dev lake small:

```toml
[kafka]
keep_snapshots = 10          # at least this many of the newest (0: keep all, today's behaviour)
keep_snapshots_for = "1h"    # and every snapshot younger than this
```

- Never expire the current snapshot, or one that a reader or a pipeline step is reading at that moment.
- Check what reads older snapshots:
  - Incremental CDC materialization merges "the events after the last offset". If it finds new events by snapshot rather than by Kafka offset, it needs the snapshot it last saw. It must either keep working after that snapshot has expired (fall back to offsets, or rebuild once), or the expiry must keep it.
  - Iceberg time travel through `/iceberg` or `iceberg_scan` with a snapshot id: a snapshot that has expired should give a clear error, not a crash.

### 2. Delete files that no live snapshot references

Once snapshots have expired, delete the data files, manifests and manifest lists that no remaining snapshot references. This includes the files compaction replaced. Do it after the new metadata has been committed, never before. A file still open by a running query must survive the query: either wait for a grace period (for example, delete only files that have been unreferenced for longer than `keep_snapshots_for`), or reference-count the open scans.

### 3. Bound the metadata files

- Keep only the newest few `vN.metadata.json` files, as Iceberg's `write.metadata.delete-after-commit.enabled = true` and `write.metadata.previous-versions-max` do. Default to about 10, and set both properties on the tables, so other Iceberg readers see the same policy.
- Expiry (1) trims `snapshots` and `snapshot-log`. Trim `metadata-log` to the files that still exist.

With all three, the size of a table's newest metadata file is bounded by `keep_snapshots`, not by the server's uptime.

### 4. Existing tables

On start-up, apply the policy to existing tables once, as a cleanup: expire their snapshots, delete unreferenced files and old metadata files. Log what it removed per table: snapshots, files and bytes. A data folder like the one measured above should shrink to tens of MB without losing a record.

### 5. Make it visible

- Status, Storage: per topic table, show the current snapshot's size beside the size on disk, so a gap like 22 MB against 338 MB is visible.
- The Pipelines/Topics pages or the log: when a cleanup ran, and what it reclaimed.
- Optional: a manual "Clean up now" (`POST /api/topics/<table>/cleanup` and an MCP tool) for an admin token.

## Acceptance

- A test that commits a few thousand small batches to one topic, with compaction on, then checks:
  - the record count and the content are unchanged;
  - the number of snapshots is ≤ `keep_snapshots`, apart from those still inside `keep_snapshots_for`;
  - the number of `*.metadata.json` files is ≤ `previous-versions-max` + 1;
  - the newest metadata file stays the same size as commits continue (it does not grow with them);
  - no file under `data/` or `metadata/` is unreferenced after a cleanup, beyond the grace period.
- A CDC topic with `[[materialize]] views = "<app>.*"` keeps exact current state across expiries, including after a restart.
- Queries running during a cleanup complete correctly.
- On a copy of an existing data folder like the one above: start the server, let the one-time cleanup run, compare every table's `count(*)` and a checksum of its rows before and after, then restart once more. The second start removes nothing and starts cleanly.

## Environment

- Build 46ec4c0 (DuckDB v2.0.0), linux arm64, the data folder on local disk.
- Producers: Mendix 11.16.1 CDC over Kafka (one entity updated every minute), and HTTP `/events/openf1` posts (OpenF1 responses of 1 KB to 3 MB, one per changed feed per minute during a live session).
- `[kafka]` defaults: `flush_ms = 1000`, `compact_files = 32`, `compact_seconds = 60`.

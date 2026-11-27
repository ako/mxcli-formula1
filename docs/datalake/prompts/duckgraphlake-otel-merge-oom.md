# Bug: one busy hour of OpenTelemetry spans kills the lake, at every start

For a coding agent working in ako/DuckGraphLake. Build 44afee6 (DuckDB v2.0.0), linux arm64.

## Summary

At the end of an hour the lake merges that hour's span part files (`<data>/otel/spans/<date>/<HH>.<n>.parquet`) into one file. For a busy hour, 358 part files and 58 MB on disk, the merge used 6–7 GB of resident memory within two seconds, and the operating system killed the process (SIGKILL, exit 137).

`[duckdb] memory_limit = "4GB"` was set, and DuckDB reported 3.7 GiB as its limit. So this memory is not under DuckDB's buffer manager, and the cap cannot protect against it.

The merge is retried at every start. The lake started, served for about eight seconds, and was killed again: a crash loop that only moving the hour's files out of the data folder could break.

There are two more problems that showed up during the recovery, and two smaller improvements. They are listed under "Also" below.

## What happened

- **14:00:41 UTC.** The process was killed. The log ends normally, with no error. The hour 13:00–14:00 had 358 part files, and a zero-byte `tmp_13.parquet.tmp` was left behind: the merge that was in progress.
- **Every start after that.** The process was killed, with RSS going from 1.2 GB to 6–7 GB in under two seconds, about eight seconds after "Web UI …" was logged. Nothing was logged before the kill.
- **Bisected on test ports, against the same data folder:**
  - it is killed even with a config of only `[data] directory`;
  - it survives once `otel/spans` is moved out, with a peak of 1.35 GB;
  - with every other hour of spans back and only hour 13 kept out, it runs normally.
- **Ruled out:** a 576 MB Kafka log for one topic, its 491 MB topic table, the R2RML mapping, and the previous build (46ec4c0, killed the same way).

The other hours of that day are single files of 16–23 MB. The spans came from two Mendix apps, each tracing every microflow through the OpenTelemetry Java agent, at full rate, during a live session.

## Reproduce

The hour is kept on the machine that ran it (`.lake-backup/otel/spans-hour13/`, outside the repository; ask for a copy): 358 part files (`13.<n>.parquet`, 58 MB) and the zero-byte `tmp_13.parquet.tmp`. To reproduce, copy them into `<data>/otel/spans/2026-11-27/` of an otherwise empty data folder, start the server with `[duckdb] memory_limit = "4GB"`, and watch RSS.

## Expected

- **A bounded merge.** Merge in a way whose memory is bounded: through DuckDB under its memory limit (`COPY (SELECT * FROM read_parquet([...])) TO ...`, which spills), or in batches of part files, or by streaming row groups. Its memory should not grow with the number of parts or their attributes.
- **A merge that fails is set aside.** It is not retried at every start. Log it, move the parts to a quarantine folder or leave them unmerged, and keep serving. A leftover `tmp_*.parquet.tmp` from an interrupted merge is cleaned up.
- **Startup never depends on telemetry housekeeping.** OpenTelemetry is the lake watching itself and its apps. It must not be able to take the lake down.

## Also

### 1. The business-event views were missing when init_sql ran (bug)

The topic `openf1` gets business events over `POST /events/openf1` (CloudEvents headers `ce_type` and `ce_subject`), and before the crash the server made views `openf1.<type>` for them. After the crash they were missing at start-up. init_sql referred to them, so the start stopped with:

```
init: Catalog Error: Table with name "openf1.sessions" does not exist because schema "openf1" does not exist.
```

The topic's table, `main.local__openf1`, was there: it is listed during discovery, and it became "queryable". When init_sql was re-run after that, the `openf1` schema was still missing, and new events arriving did not bring the views back either.

Expected: the views of a topic that has events exist when init_sql runs, which is documented as after discovery. Or, if they are made later, the documentation says so, and they are recreated from the topic's table and not from state that a crash can lose. The workaround here reads `main.local__openf1` and its `warpstream.headers` directly.

### 2. A topic's Kafka log has no retention (improvement)

`<data>/.duckgraphlake/log/<topic>/<partition>.log` keeps every batch forever. For a topic that receives a few MB of JSON a minute during a live session, it reached 576 MB in two days. That did not cause the crash: with the log back in place, the lake started at 1.35 GB peak. But it grows without bound.

A retention setting would cover it (time or size, or "once committed to Iceberg and no consumer group is behind"), with the defaults documented.

### 3. Materialized steps refresh all at once (improvement)

At start-up, several `[[materialize]]` steps refreshed at the same time, on all ten threads. A heavy one ran out of the DuckDB memory limit (`Out of Memory Error: failed to allocate data of size 16.0 MiB (3.7 GiB/3.7 GiB used)`). With `[duckdb] threads = 4` it ran in 25 s. DuckDB's error is correct; what would help is running steps one after another, or at a bounded concurrency, so one heavy step does not fail because of its neighbours.

## Acceptance

- The kept hour (358 parts plus the leftover `.tmp`) merges, or is set aside, with RSS staying under `memory_limit` plus a small fixed overhead. The server stays up.
- A merge that is interrupted (kill -9 halfway) leaves a state the next start handles: no crash loop, and nothing left in a temporary state.
- A start after a crash, with a business-events topic that has events, has its `<schema>.<type>` views before init_sql runs, or documents otherwise. This is covered by a test that kills the server and starts it again.

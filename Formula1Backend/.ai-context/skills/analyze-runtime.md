# Analyze an App's Runtime Behavior — Logs, Metrics, Traces, Catalog

## Overview

When you need to understand what an app *actually does* at runtime — why a page is
slow, which microflow dominates cost, what hits the database, whether an error is
network or logic — the signals live in four places. This skill is the procedure for
collecting them and, crucially, **joining them**, because the useful questions cross
sources that no single tool answers alone.

| Signal | Where | How you get it |
|--------|-------|----------------|
| **Logs** (server stack traces + your `LOG` output) | `<projectDir>/.mxcli/runtime.log` | `mxcli run --local` tees it automatically |
| **Metrics** (throughput, DB counts, sessions, queues) | `/prometheus` on the admin port | `mxcli run --local --metrics` |
| **Traces** (per-microflow / per-activity spans + timings) | console→`runtime.log`, or an OTLP collector | `mxcli run --local --trace` / `--trace-otlp` |
| **Model shape** (activities, complexity, refs, XPath) | `.mxcli/catalog.db` (SQLite) | `mxcli … "refresh catalog full"` then `SELECT … FROM CATALOG.*` |

## When to Use This Skill

- A page/microflow is slow and you need to find *where* the time goes.
- You want to know which entities/queries the app actually hits, and how often.
- A server-side error shows only a generic dialog in the browser.
- You're profiling and need a flame chart, or want cost correlated with model shape.

Prerequisite: run the app with the fast local loop — see `run-local.md`. Everything
below assumes `mxcli run --local` (add the flags noted per signal).

## 1. Logs — the first stop for errors

`run --local` writes the runtime log to `<projectDir>/.mxcli/runtime.log` (override
`--runtime-log`, `-` disables). It carries JVM stdout/stderr **and** the application
log — server stack traces, your microflow/nanoflow `LOG` output, and the DB
synchronization counts at startup.

```bash
mxcli run --local -p app.mpr
tail -f .mxcli/runtime.log
```

Gotchas:
- **Nanoflow `LOG` lands under the `Client_Nanoflow` node**, not the node name you
  declared — a filter built around microflow node names silently drops it. `LOG DEBUG`
  from a nanoflow is dropped server-side (browser console only). See `write-nanoflows.md`.
- A spike in "Executing N database synchronization command(s)" on an *unchanged* model
  is a red flag (see the `create or modify` data-loss class of bug).

## 2. Metrics — throughput and database pressure

`--metrics` registers a Prometheus registry, served at
`http://127.0.0.1:<admin-port>/prometheus` (loopback).

```bash
mxcli run --local -p app.mpr --metrics
curl -s http://127.0.0.1:8090/prometheus | grep -E 'connectionbus_|handler_requests|sessions_|taskqueue_'
```

Useful families: `connectionbus_{selects,inserts,updates,deletes,transactions}_total`
(database pressure), `handler_requests_total` (throughput), `sessions_*`,
`taskqueue_*` (background work). Merge any extra registry (otlp/influx/statsd) with
`--runtime-setting 'Metrics.Registries=[…]'`.

## 3. Traces — where the time goes

`--trace` attaches the bundled OpenTelemetry agent. **Default span filters ship with
it** (`OpenTelemetry._RuntimeSpanFilters`) because unfiltered per-activity tracing is
**~10× slower** and produces ~110k spans for one busy transaction — that's a
flow-*shape* debugging mode, not a timing mode.

```bash
# console exporter → runtime.log (span names/attrs only)
mxcli run --local -p app.mpr --trace
# flame charts: export to a collector (console can't reconstruct call trees/durations)
mxcli run --local -p app.mpr --trace-otlp http://127.0.0.1:4318
```

- The **console exporter omits start/end timestamps and parent span IDs** — you get
  span names + attributes but no call tree and no durations. For real timing/flame
  charts use `--trace-otlp <endpoint>` (implies `--trace`), which sets the OTLP
  exporter for you; user-set `OTEL_*` env still wins.
- `--trace-service NAME` sets `OTEL_SERVICE_NAME` (default the `.mpr` name); use
  distinct names per app for multi-app correlation. Trace context (W3C `traceparent`)
  crosses app boundaries automatically over `rest call`.
- To examine flow *shape* on a small flow, temporarily disable the filters with
  `--runtime-setting 'OpenTelemetry._RuntimeSpanFilters=[]'`.

## 4. Model shape — the catalog

The catalog is a SQLite database at `.mxcli/catalog.db` describing the model. **Run
`refresh catalog full`** — plain `refresh catalog` (fast mode) leaves the analytic
tables (`CATALOG.ACTIVITIES`, `CATALOG.REFS`, `CATALOG.XPATH_EXPRESSIONS`,
`CATALOG.WIDGETS`) **empty** (a fast-mode query warns "requires refresh catalog full").

```bash
mxcli -p app.mpr -c "refresh catalog full"
mxcli -p app.mpr -c "SELECT MicroflowQualifiedName, COUNT(*) activities
                     FROM CATALOG.ACTIVITIES GROUP BY 1 ORDER BY 2 DESC LIMIT 10"
```

`CATALOG.ACTIVITIES.Id` is the model GUID the debugger breaks on (see
`debug-microflows.md`), with the action name and its sequence — a named, ordered
activity list per microflow. See `catalog-search.md` / `graph-analysis.md` for the
richer queries.

## 5. The app warehouse — join the signals (external DuckDB)

Each signal alone answers little; the useful questions cross them. Because the catalog
is a plain database and the app's dev data is Postgres, one engine can join model
shape + live data + telemetry with **no ETL**. mxcli does **not** embed DuckDB — this
is a dev-container recipe (dev data, dev telemetry, everything read-only):

```sql
-- in duckdb, from the project dir, after `refresh catalog full` + a --trace-otlp run
ATTACH '.mxcli/catalog.db' AS cat (TYPE sqlite, READ_ONLY);
ATTACH 'dbname=app host=127.0.0.1 user=mendix' AS app (TYPE postgres, READ_ONLY);
CREATE VIEW spans AS SELECT * FROM read_json_auto('spans.jsonl');
```

Two joins that are impossible in any single source:

- **Runtime cost × model shape** — span durations per microflow joined to
  `cat.activities_data` (count) and complexity. Complexity does *not* predict cost: a
  2-activity flow that delegates can cost more than a 14-activity one. A lint rule
  can't see that; this join can.
- **Query time × entity × live rows** — span DB timings joined to `cat` (which entity)
  and `app` (row counts). This is how you find that the task-queue poller
  (`system$queuedtask`, owned by no microflow) is the app's largest DB consumer —
  invisible from any per-microflow view.

Caveats: keep every attachment **read-only** (never a production DB; even locally make
it explicit), and filter/sample traces first — unfiltered span volume is large.

## Known gap: logs ↔ traces

Runtime log lines carry **no trace id**, so joining logs to traces is a fuzzy
timestamp join (worst exactly under concurrency). The OTel agent populates the trace
id in the MDC, but Mendix's log pattern doesn't print it — closing the file-log side
needs an upstream `%X{trace_id}` change, not mxcli. For collector-side correlation,
export traces (and logs) via OTLP with `--trace-otlp` so the backend joins them.

## Decision guide

| Question | Reach for |
|----------|-----------|
| "Why did this error?" (server-side) | **Logs** (`runtime.log`) |
| "How much DB / throughput / queue work?" | **Metrics** (`--metrics`) |
| "Where does the time go in this flow?" | **Traces** (`--trace-otlp` for a flame chart) |
| "What's the flow's shape / activity list?" | **Catalog** (`refresh catalog full`) or the debugger |
| "Which cost belongs to which entity/model construct?" | **Warehouse** (catalog × spans × app DB) |

## See Also

- `run-local.md` — the local loop these flags hang off (`--metrics` / `--trace` / `--trace-otlp` / `--runtime-setting` reference).
- `debug-microflows.md` — interactive breakpoints/stepping when a trace isn't enough.
- `catalog-search.md`, `graph-analysis.md` — catalog query patterns and dependency analysis.
- `verify-with-oql.md` — query the running app's data directly.

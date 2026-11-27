# Bug: c88bda5 loses existing tableflow tables, then aborts on every restart

> **Status:** fixed in 46ec4c0 (FINDINGS §119): both starts on a copy of this lake matched the live one.

For a coding agent working in ako/DuckGraphLake.

## Summary

Build c88bda5 (DuckDB v2.0.0, linux arm64) cannot start on a data folder that 206c9e4 has been running on. It fails in two ways:

1. **Existing Kafka tableflow tables are not registered.** The Iceberg tables under `warpstream/_tableflow/` that 206c9e4 wrote (`local__openf1` from HTTP events, plus three CDC topics such as `local__cdc.Formula1Frontend.AgentTurn.1.local`) are missing from the catalog. The views over them (`openf1.<type>`, `<app>.<entity>`, `*_current`) are missing too. The startup log lists no `iceberg` sources at all, where 206c9e4 lists all four.
2. **An abort on every later start.** On that first start, c88bda5 writes an empty `warpstream/_tableflow/.iceberg-namespace`. Every start after that ends in SIGABRT (exit 134) with no message, right after the source listing. 206c9e4 writes the same empty marker and runs fine with it.

So one start of c88bda5 against an existing lake leaves a lake that c88bda5 itself cannot start again.

## Reproduce

All of these ran on a copy of the data folder, on test ports. A minimal config, `[data] directory = "<dir>"`, is enough; init_sql, materialize, rdf and mcp are not needed.

| `<dir>/warpstream/_tableflow/` holds | c88bda5 |
| --- | --- |
| the four tables, no marker | starts; tables not registered |
| the four tables + empty `.iceberg-namespace` | **abort (134)** |
| empty `.iceberg-namespace` only | starts |
| `.iceberg-namespace` + `local__openf1` | starts |
| `.iceberg-namespace` + `local__cdc.Formula1Frontend.AgentTurn.1.local` | **abort (134)** |
| that CDC table alone, started twice (c88bda5 writes no marker) | starts both times |
| full data folder with its `.duckgraphlake/` state (kafka.duckdb, pipeline.duckdb), no marker | starts, tables not registered, **writes the marker**; next start **aborts** |

The difference between the tables that abort and the one that doesn't: the CDC topic names contain dots (`cdc.Formula1Frontend.AgentTurn.1.local`), which become part of the table directory name. A guess for where to look is the namespace handling that the marker switches on: a dotted table name read as a nested namespace, with an assertion or an unchecked error that aborts instead of reporting.

## Expected

- c88bda5 picks up the tableflow tables that earlier builds wrote, or migrates them, and logs what it did.
- A malformed or unexpected entry under `_tableflow/` is a logged error naming the path, never an abort.
- A source that fails to load is skipped with an error, and the lake serves the rest.

## Environment

- Data folder: 860 MB. `warpstream/_tableflow`: `local__openf1` 338 MB, `local__cdc.Formula1Backend.LiveSyncState.1.local` 198 MB, two small frontend CDC tables. All written by 206c9e4 from Mendix 11.16.1 CDC (Kafka) and HTTP `/events/openf1` posts.
- Started from inside `data/` with `-c ../lake/server.toml` (repo `ako/mxcli-formula1`, branch `claude/lake-chat-agent`).
- 206c9e4 on the same folder, marker included: starts, and all four tables are registered.

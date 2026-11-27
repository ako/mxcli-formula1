# Datalake documents

The DuckGraphLake work, beyond the proposal in
[../proposals/datalake-refactor.md](../proposals/datalake-refactor.md).

| File | What it is |
|---|---|
| [architecture.html](architecture.html) | The target architecture: the backend ingests, the lake shapes, the frontend reads. Four lanes into the lake (snapshot files, live events, CDC of the sync state, OpenTelemetry), the lake sync dashboard, where today's pieces go, and what to check before committing. Open it in a browser. |
| [cdc-prompts.html](cdc-prompts.html) | The two prompts below on one page, each with a copy button. |
| [prompts/duckgraphlake-cdc-fix.md](prompts/duckgraphlake-cdc-fix.md) | For a coding agent in ako/DuckGraphLake: apply Mendix CDC updates attribute by attribute (only where `before` ≠ `after`), not as whole rows. |
| [prompts/mendix-cdc-after-image.md](prompts/mendix-cdc-after-image.md) | For the Mendix CDC and event broker team: an `after` image can hold values that were never stored, when two transactions change the same object. |
| [prompts/duckgraphlake-unknown-columns.md](prompts/duckgraphlake-unknown-columns.md) | For a coding agent in ako/DuckGraphLake: a statement with an untypeable parameter loses every result column's name over the PostgreSQL endpoint (FINDINGS §115). |
| [prompts/mendix-edc-missing-column.md](prompts/mendix-edc-missing-column.md) | For Mendix: the External Database Connector throws a NullPointerException instead of naming a mapped column that is missing from the result. |
| [prompts/duckgraphlake-c88bda5-tableflow-abort.md](prompts/duckgraphlake-c88bda5-tableflow-abort.md) | For a coding agent in ako/DuckGraphLake: build c88bda5 does not register the Kafka tableflow tables an earlier build wrote, writes `_tableflow/.iceberg-namespace`, and then aborts on every start (FINDINGS §119). |
| [prompts/duckgraphlake-tableflow-retention.md](prompts/duckgraphlake-tableflow-retention.md) | For a coding agent in ako/DuckGraphLake: topic tables keep every snapshot, every file compaction replaced and every metadata file, so they grow far beyond their data (657 MB for 23 MB). Expiry, cleanup, bounded metadata. |
| [prompts/duckgraphlake-otel-merge-oom.md](prompts/duckgraphlake-otel-merge-oom.md) | For a coding agent in ako/DuckGraphLake: merging a busy hour of OpenTelemetry spans killed the lake outside its memory cap, at every start (FINDINGS §125); also the business-event views missing at start-up, Kafka log retention, and steps refreshing all at once. |

Both HTML pages were also published as private Claude artifacts. These copies
are the versions kept with the project, and they open from disk. They load
their fonts from Google Fonts and fall back to system fonts offline.

The evidence behind the CDC prompts is FINDINGS §105; behind the column-name pair, §113–§115. The running pieces are
`scripts/run-lake.sh`, `scripts/run-backend-on-lake.sh` and
`lake/dashboards/lake-sync.json`.

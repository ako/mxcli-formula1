# Proposal: move the data-storage tier onto DuckGraphLake

Status: **draft for discussion**, November 2026. Written after reading
[ako/DuckGraphLake](https://github.com/ako/DuckGraphLake) at `9740897` and measuring
this solution's current data storage. Nothing here has been built yet.

## Recommendation in one paragraph

Do it in three stages, in this order, and treat them as independent. **Stage 1**
replaces the 44 hand-written `read_csv` queries with a served folder and gains an
ontology, SPARQL and MCP over the same data for no extra modelling — it is
available today and reversible in one constant. **Stage 2** adds entity CDC into
the lake, which is new capability rather than a replacement, and is blocked on the
mxcli work being extended now. **Stage 3** is where the real architectural win is:
move the aggregation that currently happens in 68 data-source microflows into SQL
and SPARQL against the lake. Stage 3 is also the riskiest and should not start
until 1 and 2 are running. There is no protocol question to settle first: the
target is **one binary**, with Trino dropping out along with the rest of the
separate components, so the PostgreSQL wire the lake already serves *is* the read
path rather than a dev-only stand-in for something else.

## What DuckGraphLake is

One statically linked binary (DuckDB 2.0.0 with the `rdf` extension, Quack, httpfs,
SQLite, Parquet and JSON compiled in). Point it at a folder and it serves the same
files through seven endpoints at once:

| Endpoint | Address | What it is for here |
|---|---|---|
| SQL, PostgreSQL wire | `127.0.0.1:5433` | **Mendix's External Database Connector** |
| SQL, Quack | `127.0.0.1:9494` | DuckDB CLI/JDBC, scripts |
| SPARQL 1.1 | `:9495/sparql` | graph queries over an ontology |
| OData v4, read-only | `:9495/odata` | **Mendix external entities** |
| MCP, streamable HTTP | `:9495/mcp` | agents — this session included |
| Kafka | `127.0.0.1:9092` | **Business Events and entity CDC in** |
| Iceberg REST catalog | `:9495/iceberg` | DuckDB, PyIceberg, Spark |

Three properties matter for this refactor:

1. **A folder is the schema.** Each `.csv`/`.parquet`/`.json` file, each folder of
   them, each Iceberg table, each `.sqlite`/`.duckdb` becomes a view named after it.
2. **Kafka in, Iceberg out.** It stands in locally for WarpStream + Tableflow. A
   CDC topic (`cdc.<app>.<entity>.<rev>.<space>`, Debezium envelope) is unwrapped
   into a table with a column per field, plus a `cdc` struct (`op`, `ts`, `tx_id`, …)
   and a `<table>_current` view holding the latest row per object id.
3. **The model maintains itself.** Per app it generates `<app>.<entity>`,
   `<entity>_history`, `<entity>__<assoc>` views *and a mapping*, so the class
   `<App>_<Entity>` becomes an OData entity set and a SPARQL class **without a
   hand-written mapping**. It rebuilds on a new topic or shape change, no restart.

## What this solution's data storage is today

Measured, not recalled:

| Layer | What | Size |
|---|---|---|
| Source files | `data/f1db` CSV, plus `facts`, `laps`, `live`, `openf1` | 25 MB, 47 CSVs |
| "Warehouse" | `F1Warehouse`, `Type: 'BYOD'`, `ConnectionString: jdbc:duckdb:` | **44 queries**, each `read_csv({dataDir} || '/f1db-*.csv')` |
| Ops database | `F1Ops`, `Type: 'PostgreSQL'`, `jdbc:postgresql://…/f1ops` | 3 queries |
| Mendix entities | 77 entities in `Formula1Backend` | RaceResult 27,731; Race 1,172; Driver 921; Constructor 187; Circuit 78; Season 77 |
| Published | 6 OData services, `x-api-key` microflow auth | — |
| Consumed | 58 external entities in the frontend across `F1Cached`, `F1Live`, `F1Fan`, `F1Now`, `F1Admin` | — |
| Analytics | 68 `DS_`/`DSJ_` data-source microflows; 20 Vega charts | 31 `CONV011` commit-in-loop warnings |

The shape of the problem, stated plainly:

- **`jdbc:duckdb:` has no path.** The warehouse is an *in-memory* DuckDB created per
  connection, so all 44 queries re-parse CSV from disk on every call. There is no
  warehouse to speak of — there is a CSV reader with 44 SQL statements pasted around it.
- **Aggregation happens twice.** Once in those 44 SQL queries, and again in 68
  microflows that loop over retrieved objects to build JSON for the charts. The 31
  commit-in-loop warnings and the whole MDL-JSONNUM01 episode (FINDINGS §91) are
  symptoms of the second.
- **The frontend's only route to data is the backend's OData.** Which means every
  analytic question has to become a Mendix entity first.

## The fit

### Stage 1 — replace the in-memory DuckDB with a served folder

Point `duckgraphlake ./data` at the existing data folder and repoint one constant:

```
DuckDbUrl   jdbc:duckdb:                                    (in-memory, per connection)
         -> jdbc:postgresql://127.0.0.1:5433/lake?sslmode=disable
```

`F1Warehouse`'s `Type` changes `BYOD` → `PostgreSQL`, and its 44 queries lose their
`read_csv({dataDir} || …)` wrapper in favour of the view name the folder produced
(`f1db-seasons.csv` → view `f1db-seasons`). The SQL dialect does not change — it is
DuckDB's on both sides.

What this buys, beyond not re-parsing 25 MB per query:

- **An ontology over the F1 data**, which the user reports already works, and with it
  SPARQL and a catalog/diagram UI at `:9495`.
- **MCP at `:9495/mcp`** — `list_tables`, `describe_table`, `sql`, `list_classes`,
  `sparql`. An agent working on this repo could answer data questions without a
  microflow or a running Mendix app.
- **One fewer moving part in CI**: the 47 CSVs stop being an implicit contract
  between `scripts/fetch-f1-data.sh` and 44 SQL strings.

Reversible by putting the constant back. Risk is low and contained to one
connection document.

### Stage 2 — entity CDC into the lake

Set the backend's `Kafka.BootstrapServers` to `localhost:9092` and let the lake take
the CDC stream. Each entity becomes an Iceberg table plus a `_current` view, and the
generated mapping makes it a SPARQL class and an OData entity set.

Volume here is trivial — a full snapshot is ~30k rows, dominated by RaceResult's
27,731 — so this is a correctness and plumbing exercise, not a capacity one.

What it buys: a queryable history of every entity (`<entity>_history`, `op`, `ts`,
`tx_id`) that the Mendix database does not keep, and a read model the frontend could
reach **without** the backend publishing it first.

Blocked on: mxcli's CDC support. The current build (`nightly-20261117-b7dc2f863`)
has `business-events` syntax but no CDC statement, so there is nothing to declare it
with yet.

### Stage 3 — move aggregation out of microflows

This is the one worth doing the first two for. The 68 `DS_`/`DSJ_` microflows exist
because the only way to get a number onto a page is to retrieve objects and loop. The
same questions are SQL or SPARQL one hop away once the lake holds the data:

- a `DSJ_*` chart payload becomes a view in the lake, read by the frontend as an
  external entity or over a REST call, instead of a microflow building JSON in a loop;
- the 31 commit-in-loop warnings go away with the loops that cause them;
- MDL-JSONNUM01's locale trap disappears because no microflow formats numbers into
  JSON any more.

Do not start this until 1 and 2 run. It changes the frontend's data contract, and it
is the only stage that touches the 20 charts that are the app's whole point.

## What is not ready

**Trino: settled, and it removes the one real blocker.** An earlier draft of this
proposal led with a protocol question, because DuckGraphLake's parked
`docs/proposals/dev-stack.md` says the apps read the lake **over the Trino JDBC
driver** and that "DuckDB alone is not enough unless something translates the
protocol and the SQL dialect". That is no longer the direction: Trino drops out with
the rest of the separate components, and the goal is one binary. So Stage 1's
PostgreSQL-wire connection is not a dev-only approximation of a Trino read path —
it is the read path, and dev and production do not differ in driver, protocol or
dialect. Stage 1 is unblocked.

**No release yet.** `ako/duckgraphlake` has no tags and no releases, so there is no
binary to download: it is a ~1 hour build on 4 cores (`server/build.sh`), or the
Docker image under `docker/`. For this repo's session-start hook to bring the lake up
the way it brings up Postgres, a published binary would help a lot — the hook cannot
spend an hour.

**That parked proposal is now partly superseded, in a good way.** It specifies Kafka
+ Lakekeeper + MinIO + Trino as separate dev components; the `server/` binary now
*is* the broker, the Iceberg writer, the catalog and the query engine. The component
table in `dev-stack.md` should probably be rewritten before it misleads someone.
With Trino dropping out too, **SSO is the only genuinely open component** in it —
every other row is now the one binary.

**Smaller things, each of which would bite:**

- **The lake's OData keys are IRIs.** `GET /odata/Employee('http://data.example.com/person/10')`,
  one entity set per ontology *class*, not per table. The frontend's 58 external
  entities are currently keyed the Mendix way. Consuming lake OData is not a
  drop-in swap for consuming the backend's services.
- **Read-only.** The lake's OData declares it in `$metadata`. Anything that writes
  stays on the current path — which is fine, since the write path is the Mendix apps.
- **No TLS, token on loopback.** Dev-only by design; the `docker/` image is the one
  with TLS.
- **No bound parameters over Quack.** Parameterised queries must use the PostgreSQL
  endpoint. Stage 1 uses that anyway, so this only constrains scripts.
- **`F1Ops` should stay where it is.** It is a real PostgreSQL database with stored
  procedures behind 3 queries; the lake is not a substitute for it and nothing is
  gained by moving it.

## What I would not do

- **Not retire the 6 published OData services.** They are the frontend's contract and
  the subject of a lot of this project's record (§40, §48, the `x-api-key` auth). The
  lake is an addition to the read side, not a replacement for the app's own API.
- **Not move the live OpenF1 sync.** `19-live-sync.mdl`'s 5 REST calls write into
  Mendix entities; with Stage 2 those changes reach the lake as CDC for free, which is
  strictly better than re-pointing the sync.
- **Not put the lake in the session-start hook** until there is a release binary.

## Next step

Smallest useful experiment, and it tests Stage 1 end to end without touching the model:
build the binary once, run `duckgraphlake ./data`, and check that the F1 ontology and
SPARQL work against the folder as the user reports. Then repoint **one** of the 44
queries at a view and compare its result with the `read_csv` version. If those agree,
the remaining 43 are mechanical.

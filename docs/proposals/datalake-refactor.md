# Proposal: move the data-storage tier onto DuckGraphLake

Status: **draft for discussion**, November 2026. Written after reading
[ako/DuckGraphLake](https://github.com/ako/DuckGraphLake) at `9740897` and measuring
this solution's current data storage. Nothing here has been built yet.

## Recommendation in one paragraph

Do it in three stages, in this order, and treat them as independent. **Stage 1**
replaces the hand-written `read_csv` queries with a served folder — **21** of the 44,
not all 44; see the survey and gains an
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

## Survey: what the 44 queries actually are

Done before the build finished, and it changes Stage 1's scope. "44 `read_csv`
queries" is not one population but three:

| Population | Count | What it is |
|---|---|---|
| **Real file reads** | **21** | Read columns out of a CSV. The view-swap candidates. |
| **Shape stubs** | **8** | `SELECT '' AS a, 0 AS b, … FROM read_csv(seasons.csv) LIMIT 1` — every column a literal. |
| **JSON-param compute** | **15** | `from_json({lapsJson}::JSON, '[{…schema…}]')` — DuckDB as a function over JSON the microflow passes in. No stored data is read. |

### The 21 real reads — Stage 1's actual scope

`GetSeasons`, `GetCircuits`, `GetConstructors`, `GetDrivers`, `GetRaces`,
`GetRaceResults`, `GetDriverCount`, `GetRaceResultCount`, `GetDriverStandings`,
`GetConstructorStandings`, `GetDriverSeasons`, `GetDriverRaces`, `GetRetirements`,
`GetFacts`, `GetLiveOrder`, `GetLiveMessages`, `GetLiveSession`, `GetLiveTrace`,
`GetLiveStints`, `GetCircuitOutlines`, `GetCircuitPoints`.

They touch **20 distinct files** across `data/f1db`, `data/facts`, `data/live` and
`data/circuits`; 9 read more than one. The most-shared are `f1db-seasons.csv` (9
queries), `f1db-constructors.csv` (7), `f1db-drivers.csv` (5) and
`f1db-races-race-results.csv` (5) — so a handful of views carry most of the traffic,
and the first one converted should be one of those.

One wrinkle: the lake names a view after the file, so `f1db-seasons.csv` becomes
`f1db-seasons`, which needs quoting in SQL (`FROM "f1db-seasons"`). An `--init`
script giving them plain aliases (`CREATE VIEW seasons AS SELECT * FROM "f1db-seasons"`)
would keep the 21 rewrites tidier, and is the kind of thing `--init setup.sql` exists for.

### The 15 JSON-param queries are a better opportunity than a migration

These never touch the data folder. The microflow fetches from the OpenF1 API, passes
the response in as a parameter, and DuckDB parses and aggregates it per call — six of
them with window functions. Swapping a view in does nothing for them.

What would: Stage 2. If the live sync's results land in the lake (as entities via CDC,
or as a topic), these fifteen become queries over **stored** tables instead of over a
JSON blob re-parsed on every request, and the window functions get something to range
over. That is a real gain, but it belongs with Stage 2, not Stage 1.

Note they must stay on the PostgreSQL endpoint, not Quack: they are parameterised, and
the server's README records that Quack does not forward bound parameters.

### The 8 stubs are a question for you, not a migration task

`GetSeasonProgress`, `GetRaceWeekend`, `GetRaceSessions`, `GetCalendar`,
`GetWeekendShape`, `GetLapChart`, `GetTeamSeason`, `GetTeamH2H` all read one row of
`f1db-seasons.csv` and return hard-coded constants — empty strings, zeros, a NULL
timestamp. `GetRaceWeekend` declares 23 such columns.

They look like result-shape placeholders from when those screens were built, with the
real data arriving another way. Worth deciding whether they are dead scaffolding to
delete or unfinished paths to implement; either way they should not be counted in the
refactor, and they inflate "44 queries" by a fifth.

### On the method

Two of my own classifier passes were wrong before this one, which is worth recording
because the numbers above would otherwise look more certain than they are: the first
missed `LIMIT 1` stubs entirely, and the second mistook `0.0 AS distance` for a
`table.column` reference, which let `GetRaceWeekend` pass as a real read and pushed
`GetFacts` into the stub column. The counts above were settled by reading the
ambiguous queries rather than by pattern.

## Measured: the equivalence holds, with one condition

Stage 1 is no longer a plan. I built the binary, served the folder, and ran every
real-read query twice against the **same** DuckGraphLake connection — once exactly as
the Mendix model has it (`read_csv({dataDir} || '/...')`), once with every `read_csv`
call swapped for a view. Nothing in the Mendix model was touched; both variants are
plain SQL over the same server, so the comparison isolates the storage change.

| Outcome | Queries |
| --- | --- |
| Identical — same rows, same order | **19** |
| Non-deterministic in *both* variants (pre-existing) | 1 — `GetDriverSeasons` |
| Untested — input not generated in this container | 2 — `GetCircuitOutlines`, `GetCircuitPoints` |

Every comparable query agrees byte for byte, including `GetRaceResults` at 27,731 rows
and `GetLiveTrace` at 1,437. Stage 1's read path is proven, not assumed.

### The condition: the declared column specs are load-bearing

Eight queries read with an explicit spec — `read_csv(path, header = true, columns =
{...})`. Pointed at views built by DuckDB's own type **inference**, all five live
queries failed outright:

```
ERROR:  Cannot mix values of type VARCHAR and ...
```

`live-order.csv` is the clearest case: the model declares `sessionKey` as `VARCHAR`,
inference makes it `BIGINT`. Re-emitting those seven views *with the declared spec*
carried over turned all five from errors into identical results. So the migration is
mechanical, but it is not "point at the folder and go": whatever creates the views has
to carry the column types the model already states, and generating them from the
model's own specs is the way to get that right.

### What the comparison surfaced about the app

Neither item is about the lake, and neither was visible until the queries ran.

**`GetDriverSeasons` is non-deterministic.** It ends `GROUP BY rr.year, rr.driverId
ORDER BY rr.year DESC LIMIT 1`, and 25 drivers tie on the latest year, so `LIMIT 1`
picks arbitrarily among them. Across cold starts the *unmodified* `read_csv` version
returned `pierre-gasly` three times and `kimi-antonelli` once; the view version
returned `pierre-gasly` three times and `george-russell` once. Both are unstable, so
this is a defect in the query, not a migration risk — it needs a tiebreaker. It is
also a warning about the method: run it once and it looks stable, which is why the
verdict above rests on repeated cold starts rather than a single pass.

**Two queries could not be tested here.** `GetCircuitOutlines` and `GetCircuitPoints`
read `/../circuits/f1db-circuit-paths.csv` and `/../circuits/f1db-circuit-points.csv`,
which `scripts/fetch-circuit-outlines.py` generates from OpenStreetMap. That directory
is gitignored like every other fetched dataset, but unlike `f1db`, `facts`, `laps` and
`live` it is not produced during setup, so it was absent in this container. I first
wrote these up as queries reading nonexistent files; that was wrong. They are ordinary
members of the 21 and need one script run to verify — so the measured result is 19 of
21 confirmed, 2 outstanding. I tried to close the gap and could not: the script reads
the OpenStreetMap Overpass API, and none of its three hosts is reachable through this
environment's network policy, so the fetch hangs and times out. It needs either
`overpass-api.de` allowed here or a run somewhere with open egress.

### Discovery does not do what this proposal first assumed

The earlier draft assumed `f1db-seasons.csv` becomes a view named `f1db-seasons`. It
does not. Discovery makes **one view per folder** (a glob across everything inside it)
and **one view per file** only for files at the root it is given — and it converts
hyphens to underscores, so the name is `f1db_seasons`. Pointed at `data/`, the 47
different-schema CSVs in `data/f1db/` collapse into a single unusable glob view.

Two further wrinkles: eight queries reach *out* of their folder with `/../` into
`facts`, `live` and `circuits`, so the server has to be pointed at `data/`, not
`data/f1db/`; and the queries' own `{dataDir}` stays `data/f1db` regardless. The fix
is the server's `--init` flag, a SQL script run after discovery — 62 `CREATE OR REPLACE
VIEW` statements generated from the file list and the model's column specs. That is
what the verified run above used, and it is the artifact Stage 1 should own.

### Reproducing it

The harness is in the session scratchpad, which does not survive the session; the parts
worth keeping are the two generators (per-file views from the file list, typed views
from the model's declared specs) and the comparison itself. Startup needed one fix
beyond `server/build.sh`: the binary loads Iceberg, Iceberg needs the `avro` extension,
and a source build ships neither, so it exits fatally. The release tarball includes
both in `extensions/`; building from source means installing `avro` into
`~/.duckdb/extensions/v2.0.0/<platform>/` first. There is no flag to disable Iceberg.

## Next step

The read path is settled, so the open questions are no longer about feasibility:

1. **Decide the 8 stubs** — delete as scaffolding, or implement. They are a fifth of
   the query count and nothing can be planned around them until that is answered.
2. **Fix `GetDriverSeasons`**, and run `scripts/fetch-circuit-outlines.py` so the two
   circuit queries can be verified like the rest. Both are worth doing whether or not
   the refactor proceeds; adding the circuits fetch to setup would stop the gap
   recurring.
3. **Generate the `--init` script from the model** rather than from a shell loop, so
   the column specs stay in step with the MDL by construction.
4. **Then Stage 2**, which is the part still genuinely unproven: nothing here tested
   CDC, the ontology, SPARQL or OData, because Stage 1 needs none of them.

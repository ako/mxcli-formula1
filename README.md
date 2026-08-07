# Formula1 — historical Formula 1 data browser

A Mendix **solution**: two apps in one repo, provisioned and developed with
[mxcli](https://github.com/ako/mxcli).

## The brief

> **What it is:** a Formula 1 historical data browser.
>
> **How it is built:** online-available Formula 1 data stored as CSV in a folder;
> a Mendix backend app using the Database Connector and DuckDB to read data from
> the CSV files; a Mendix frontend app allowing users to view all available data.
>
> **What it tracks:** all historical Formula 1 data.
>
> **Who logs in:** the Formula 1 enthusiast.

Theme `console` (dark), Mendix **11.13.0**, mxcli built from **ako/mxcli main**.

## The two apps

| App | Port / host | Owns |
|---|---|---|
| `Formula1Backend` | `http://backend.local:8080/` (admin 8090, serve 6543) | Reading the CSVs through DuckDB over JDBC, and publishing the result as **two** OData services — see below |
| `Formula1Frontend` | `http://frontend.local:8180/` (admin 8190, serve 6643) | Consuming both services as external entities, and presenting them — the browsing UI the enthusiast uses |

Each app is a full Mendix project: its own `.mpr`, its own runtime, its own
Postgres database (`formula1backend` / `formula1frontend`, derived from the
`.mpr` name).

**Two hostnames, not just two ports.** Cookies are keyed on host name and ignore
the port, so both apps on `localhost` would share one cookie jar and silently
overwrite each other's `XASSESSIONID`. `backend.local` and `frontend.local` both
resolve to `127.0.0.1` via `/etc/hosts`; each app's `ApplicationRootUrl` names
its own host so the runtime generates absolute URLs (deep links, OIDC redirect
URIs) against the name rather than the listen address.

**How they talk.** The backend publishes **two** OData services over the same
eight resources, built two different ways, so they can be compared directly.
Wire the frontend in dependency order — the backend must be *running* when the
OData client is created, because `CREATE ODATA CLIENT` fetches `$metadata` at
that moment and caches it. The frontend's `ServiceUrl` points at a constant, not
a literal, so the address is environment-overridable.

## The two services

| | `F1LiveApi` — `/odata/f1-live/` | `F1CachedApi` — `/odata/f1/` |
|---|---|---|
| Data comes from | the CSVs, read on every request | Postgres, filled by a refresh job |
| Entities | non-persistable + a read microflow each | persistent |
| Paging | `$skip`/`$top` translated to `OFFSET`/`LIMIT` by the read microflow | `PageSize` 100 (200 for results) |
| `$filter` / `$orderby` | translated to `WHERE`/`ORDER BY` against the CSVs | pushed into SQL by Mendix |
| `$count` | works (27533 race results) | works (27533 race results) |
| Navigation properties | none — the rows are flat, DuckDB did the joins | `season`, `circuit`, `driver`, `constructor` |
| Staleness | impossible | as old as the last refresh |
| Setup cost | none | `ACT_RefreshAll`, ~33 s |

### Query pushdown

Mendix applies **no** query options to a resource backed by a read microflow — it
hands over the request and returns whatever comes back. `?$top=5` really did
return all 917 drivers. So `Drivers` and `RaceResults` on the live service parse
the options off the request and turn them into SQL themselves
(`javasource/formula1backend/ODataQuery.java`).

A datagrid showing rows 80–100 sorted by name:

| | before | after |
|---|---|---|
| rows | 917 | **20** |
| bytes | 293422 | **6621** |
| `@odata.count` | unsupported | **917** |
| sort order | ignored | applied in SQL |

That is also what makes `RaceResults` publishable from the CSVs at all: all 27533
rows, a page at a time, 7.6 KB per request, nothing materialised. Both services
now answer **41** for Senna's race wins — one counting rows in Postgres, the
other scanning a 4 MB CSV per request.

Column names from `$orderby` and `$filter` reach SQL, so each one is resolved
through a per-resource whitelist. An unlisted name is ignored in a sort and
rejected in a filter — dropping a filter would quietly return more rows than the
client asked for. `tests/pushdown.test.mdl` covers the translation, the clamping
and the rejections.

The remaining live resources (Seasons, Circuits, Constructors, Races, both
standings) are small enough to return whole and still do; they follow the same
pattern when needed. All eight are countable.

## The frontend

Two OData clients, one per service, in their own modules — `F1Live` and
`F1Cached` — because both services publish identically named resources. 16
external entities generated from the contracts under
`Formula1Frontend/contracts/`, which are committed so the frontend model builds
with the backend down.

Verified against the running backend:

```
PASS  Live client retrieves all 917 drivers straight from the CSVs (1.799s)
PASS  Cached client retrieves all 917 drivers from Postgres          (452ms)
PASS  Live client:   Senna has 41 race wins                          (637ms)
PASS  Cached client: Senna has 41 race wins                          (416ms)
```

`RETRIEVE ... WHERE driverId = 'ayrton-senna'` on the live client reaches through
OData, into the read microflow, into a `read_csv()` scan and back.

See `model/frontend/README.md` — in particular, do not patch generated external
entities; fix the contract and regenerate.

## The data

`data/f1db/` — 47 CSV files, ~25 MB, covering every Formula 1 season from 1950
to the present: 1171 races, 917 drivers, 187 constructors, 78 circuits, 27533
race results, plus qualifying, practice, pit stops, fastest laps, sprint races
and season standings.

Source: [f1db/f1db](https://github.com/f1db/f1db) (CC-BY-4.0), which ships a
`f1db-csv.zip` on every release. **Not** Ergast — that service was shut down and
its domain no longer serves the dump.

The CSVs are git-ignored and re-fetched by `scripts/fetch-f1-data.sh`. The
backend never copies them into a Mendix database: DuckDB reads them in place at
query time via `read_csv()`, through the JDBC driver, behind Mendix's External
Database Connector (database type `BYOD`, connection string `jdbc:duckdb:`).

**This is proven, not assumed.** `spikes/duckdb-readpath/` holds a throwaway probe
that ran inside a booted Mendix runtime and asserted against real values — Senna 41
wins, Hamilton 106, 917 driver rows — in ~30 ms per query. Re-run it any time with
`mxcli test`; the README there has the commands.

The DuckDB JDBC driver (82 MB) is declared in the model as a managed Java
dependency; mxcli resolves it into `vendorlib/` before boot, so it is git-ignored
and needs no fetch script of its own.

## Working on it

A `SessionStart` hook (`.claude/settings.json` → `.claude/bootstrap-mxcli.sh`)
makes a fresh clone ready by itself: it builds mxcli, fetches the CSVs, adds the
hostnames, caches MxBuild + the Mendix runtime and provisions both databases.
To do it by hand:

```bash
sh .claude/bootstrap-mxcli.sh
```

For a fast test loop, leave the backend up with its test endpoint and attach to it
— ~2 s per iteration instead of a ~34 s cold boot each time:

```bash
./mxcli run --local -p Formula1Backend.mpr --test-endpoint   # terminal 1
./mxcli test tests/ -p Formula1Backend.mpr --attach          # terminal 2
```

Then boot either app:

```bash
cd Formula1Backend  && ./mxcli run --local -p Formula1Backend.mpr
cd Formula1Frontend && ./mxcli run --local -p Formula1Frontend.mpr \
    --app-port 8180 --admin-port 8190 --serve-port 6643
```

`./mxcli` is built from source rather than downloaded — see
`scripts/build-mxcli.sh` and the note in `FINDINGS.md`. Both the binary (~85 MB)
and the CSVs are git-ignored; the scripts that fetch them are committed, which
is what lets a reaped session bootstrap from files instead of from a prompt.

See `FINDINGS.md` for what broke and what was worked around.

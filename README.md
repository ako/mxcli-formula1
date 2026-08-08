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

Theme `console` (dark), Mendix **11.13.0**, mxcli built from **ako/mxcli main** (`c76d4b7`).

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

## The three services

Two of them publish the dataset the same eight ways, so the trade-off between
reading CSVs per request and materialising them can be measured. The third,
`F1FanApi` — `/odata/f1-fan/` — publishes answers rather than tables: a driver's
career season by season, a season's title fight round by round, a team's
retirements by cause, and a sourced paragraph about any of them. Same DuckDB,
same nothing-materialised, five resources, all filtered to one driver, season or
team by `$filter`.

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
PASS  Live client retrieves all 917 drivers straight from the CSVs (1.072s)
PASS  Cached client retrieves all 917 drivers from Postgres          (533ms)
PASS  Live client:   Senna has 41 race wins                          (634ms)
PASS  Cached client: Senna has 41 race wins                          (421ms)
PASS  Live client:   name maps to the remote name                    (469ms)
PASS  Cached client: name maps to the remote name                    (385ms)
```

`RETRIEVE ... WHERE driverId = 'ayrton-senna'` on the live client reaches through
OData, into the read microflow, into a `read_csv()` scan and back.

See `model/frontend/README.md` — in particular, do not patch generated external
entities; fix the contract and regenerate.

**Design.** The pages follow a supplied redesign that keeps the Console palette
exactly — `#0E1116` ground, `#2DD4BF` primary, 6px radius, 28px rows, Space
Grotesk over JetBrains Mono on every number — and changes the arrangement: a
header band (eyebrow, title, subtitle, one badge), a row of tiles carrying the
numbers that used to be a sentence, then panels holding one thing each with a
muted subtitle on the title's baseline. `theme/web/_f1-layout.scss` is that
layer; every value in it resolves through a `--mxt-*` token, so it follows a
light/dark flip and a re-brand rather than pinning the look.

**Theming.** `console`, variant `auto`, so the app follows the OS. The theme maps
~60 Atlas Core variables onto its palette; the widget modules' own styling used
to be out of reach — Data Grid 2 bakes colours as Sass literals no token can
touch, including a pager caption at 1.02:1 contrast. mxcli `c76d4b7` generates
`_mxcli-widgets.scss` for exactly that, so `theme/web/_f1-widget-dark.scss` is
down to what it still misses: the filter-operator popover, and the header logo
(an `<img>`, replaced with a mask painted from `--mxt-brand`). It sits outside
the `mxcli:theme` fence, so `mxcli theme apply` leaves it alone. FINDINGS §33, §34.

## The fan pages

Three pages, each opened from a row in an overview:

| Page | Shows |
|---|---|
| **Driver career** | Every season — teams, championship position, wins, poles, average qualifying and finishing position — then every race with its three practice sessions, qualifying, grid slot and result side by side. The practice columns are empty before timed practice was recorded, which is itself the answer to "how did they practise". |
| **Season summary** | A line chart of cumulative points round by round for the top five, computed with a DuckDB window function over the race results, plus both final standings. |
| **Constructor** | Every reason that team's cars stopped, how often, and what share of their entries it accounts for — Ferrari: 72 distinct reasons, `Engine` 146 times, 5.8% of 2515 entries, 1950 to 2024. |

Each page opens with a paragraph from Wikipedia — 224 of them, covering all 77
seasons, 116 race-winning drivers and 31 winning constructors, fetched by
`scripts/fetch-f1-facts.sh` and read by DuckDB from `data/facts/f1db-facts.csv`
like everything else. The text is CC BY-SA 4.0; the article link and licence
travel with every row and are shown on the page.

## The race weekend

A fourth page, opened from any row of a season's calendar: one Grand Prix with
every session beside the next.

| Panel | From |
|---|---|
| Session cards | who led FP1, FP2, FP3, who took pole and with what lap, the fastest lap, the winner |
| Position across the weekend | FP1 → FP2 → FP3 → Quali → Race for the top ten, as ten lines over five points |
| Race position by lap | the lap-by-lap traces — the one thing f1db does not carry |
| Session pace | each driver's gap to that session's own best, in seconds, so a wet FP1 does not skew the chart |
| The table | code, team, all three practices, qualifying position and lap, grid, Δ, best lap, pit stops, points, retirement |

**Where the lap traces come from.** f1db has every session's *result* — 17085
fastest laps back to 1950, qualifying with Q1/Q2/Q3 splits, practice from 1986,
22430 pit stops with lap and duration — but not a row per driver per lap. Ergast
had that and Ergast is gone (`ergast.com` now redirects). `scripts/fetch-f1-laps.sh`
pulls it from [Jolpica-F1](https://jolpi.ca), the community successor on the same
API shape: 26574 timings for 2024, ~12 requests per race inside a 500/hour budget,
written to `data/laps/f1db-laps.csv` and read by DuckDB like everything else.
Jolpica's driver ids are not f1db's, so the join tries the slug, then the
accent-stripped surname restricted to that race's starters.

Set `LAP_SEASONS="2023 2024"` to widen it; the default is one season because two
would exceed the hourly budget.

## Live race overview

A fourth data source and a fourth service, `F1LiveNowApi` — `/odata/f1-now/` —
carrying what neither f1db nor Jolpica publish: **live timing**.

```
Race @ Hungaroring, Budapest — lead lap 70, air 31.3°C, track 47.0°C
  P1  NOR  Lando NORRIS     McLaren          gap 0.0     S1 29.105 S2 30.486 S3 24.034  SOFT(3) 2 stops
  P2  VER  Max VERSTAPPEN   Red Bull Racing  gap 15.08   S1 29.425 S2 30.537 S3 24.258  SOFT(3) 2 stops
  P3  ANT  Kimi ANTONELLI   Mercedes         gap 18.728  S1 29.053 S2 30.514 S3 23.905  HARD(0) 2 stops
```

Running order with gap to leader and to the car ahead, last lap and its three
sectors, speed trap, tyre and age, pit stops; race-control messages newest
first; and air/track temperature, rain and wind.

Source: [OpenF1](https://openf1.org) — unofficial, free, key-less, documenting a
~3 second delay during a session. `scripts/fetch-f1-live.sh` snapshots one
session into `data/live/`; the page reads the last snapshot and **shows when it
was taken**. Re-run and reload for the next one; on a race Sunday run it on a
timer with `SESSION=latest`.

One trap: OpenF1 **404s the entire request if you pass `limit`**. Filter with
`session_key` / `driver_number` instead.

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

## Where the time actually goes

`tools/observability/` traces a page turn end to end — browser → frontend →
OData → backend → DuckDB — with real durations. Steady-state, per page turn:

| | live (DuckDB/CSV) | cached (Postgres) |
|---|---|---|
| whole turn | ~500 ms | ~370 ms |
| **BCrypt auth** | **303 ms (61%)** | **301 ms (81%)** |
| DuckDB `read_csv` ×2 | 68 ms | — |
| connector overhead | 78 ms | — |
| Postgres queries | — | 3.5 ms |

The frontend's OData client uses basic auth and holds no session, so the backend
runs a **full BCrypt password verification on every request**. A wrong password
costs the same ~350 ms as a right one; no credentials at all costs 10 ms. That is
the single biggest cost in the solution — bigger than reading a 4 MB CSV twice.

FINDINGS §31 has the full trace and the method.

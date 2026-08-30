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

Theme `console` (dark), Mendix **11.14.0**, mxcli built from **ako/mxcli main** (`81595f6`).

## What it looks like

Screenshots are the running app, captured against a live backend by
`scripts/shoot-screenshots.mjs`. They are regenerated rather than curated, so a
panel that is empty in one is empty in the app.

> **Stale after the redesign.** The shots of the previous twelve-page app were
> deleted rather than kept, because they show pages that no longer exist and the
> claim above is worth more than the pictures. Regenerate them with the app and
> backend running:
>
> ```bash
> node scripts/shoot-screenshots.mjs
> ```

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
return all 917 drivers. So every read microflow parses the options off the
request and answers them itself.

The part of that which is not about Formula 1 is now a standalone module:
[`ODataPushdown`](model/odatapushdown/) — one parse action turning `$filter`,
`$orderby`, `$top`, `$skip`, `$count` and the key lookup into either SQL to
splice or values to bind, across five SQL dialects. Copy two directories into
another project and it works there. Its grammar is the one Mendix's own OData
client emits, captured off the wire because
[the requirements page](https://docs.mendix.com/refguide/consumed-odata-service-requirements/)
names the query options and not one operator.

It also renders **stored routine** invocations — `SELECT * FROM f(…)`,
`CALL p(…)`, `EXEC p @x = …`, `BEGIN p(…); END;` — as bound templates, for
resources whose logic lives in the database rather than in a table. A fifth
service, `F1OpsApi`, puts a real Postgres schema's table function and procedure
behind OData to prove it (`scripts/create-f1ops-db.sh`). The procedure is a real
**OData action** — an `ActionImport` in `$metadata`, `POST` the arguments, get
the outcome back — which MDL could not declare until mxcli `715bac5` closed the
gap this repo filed. FINDINGS §47, §48.

All five services use **custom authentication**: a microflow reads a key off the
request headers, so no password is hashed per request. That deleted
`BcryptCost = 8`, a deliberate weakening taken when the proper fix could not be
expressed. FINDINGS §40, §48.

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
through a per-resource whitelist that also declares each column's type — Mendix
quotes a literal according to what the *widget* thinks the attribute is, so the
same numeric column arrives as `year eq 1957` from a grid header and
`year eq '1957'` from a combo box. An unlisted name is ignored in a sort and
rejected in a filter — dropping a filter would quietly return more rows than the
client asked for. `tests/pushdown.test.mdl` covers the grammar term by term, the
clamping, the key in all three spellings it arrives in, and the rejections: 49
tests, 57 across the backend.

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

## The five screens

The app is five screens and nothing else. There is no home page and there are no
overview lists, because every screen is an overview of the next one.

| Screen | Shows | Opens |
|---|---|---|
| **Narrate** | The race as it stands and how it got there: gap to leader lap by lap, the classification with sector marks, position by lap for every car, strategy as one bar per stint, and race control newest first. | — |
| **Season** | A championship: who won and by how much, cumulative points round by round, finishing position as ten small multiples on shared axes, the drivers' table, and the calendar. | driver · constructor · weekend |
| **Weekend** | One Grand Prix with every session beside the next: practice → qualifying → race as a slopegraph, pace as each driver's gap to that session's own best, the session-by-session table, and the lap traces. | driver · any other round |
| **Constructor** | A team's season, mostly as comparisons between its two drivers: points by round one bar per seat, team-mates head to head, championship position round by round. | driver · any other team |
| **Driver** | One driver: the season strip round by round, qualifying against race result, the career as points and championship finish, and every season in a table. | weekend · season · any other driver |

Four of the five take a parameter, and a Mendix menu item cannot supply one, so
the rail's four lower items are microflows that pick the most recent thing of
their kind — the latest season, its last round, and that season's two champions.
Narrate needs no parameter and is the home page.

**Chip rows move sideways.** Weekend, Constructor and Driver each carry a row of
siblings along the top — every round of the season, every constructor, the
twenty drivers with the most points ever scored — so a screen can be left
sideways rather than only backwards. That is what replaced the overview pages.

**Every screen ends on its sourcing.** A footnote saying which of f1db, Jolpica
and OpenF1 the numbers came from, and which of them were computed here rather
than read. The Narrate screen additionally shows *when* its snapshot was taken,
because it is the only one whose data was moving.

### What the design asks for and this does not have

Two panels of the Narrate screen are absent by decision rather than pending, and
`model/frontend/06-narrate.mdl` says so where a reader will find it:

* **the track map**, which wants an (x, y) per car against a drawn circuit
  outline. The snapshot carries positions in the running order, not positions in
  space, and the outline is a hand-drawn path per venue. A track map that
  guessed either would be a picture of nothing;
* **the story panel**, which wants precedents and streaks read out of
  seventy-five years of results by an agent pass. There is no such resource, and
  writing the sentences into the page is the exact failure its own comp warns
  about — "read the provenance line before you say it out loud".

One panel is drawn differently rather than dropped. The design puts a position
sparkline inside every row of the classification; a Mendix data grid column
holds an attribute and not a widget, so the same information is drawn once for
everybody as the position-by-lap chart underneath.

## Where the numbers come from

**The lap traces.** f1db has every session's *result* — 17085 fastest laps back
to 1950, qualifying with Q1/Q2/Q3 splits, practice from 1986, 22430 pit stops
with lap and duration — but not a row per driver per lap. Ergast had that and
Ergast is gone (`ergast.com` now redirects). `scripts/fetch-f1-laps.sh` pulls it
from [Jolpica-F1](https://jolpi.ca), the community successor on the same API
shape: 26574 timings for 2024, ~12 requests per race inside a 500/hour budget,
written to `data/laps/f1db-laps.csv` and read by DuckDB like everything else.
Jolpica's driver ids are not f1db's, so the join tries the slug, then the
accent-stripped surname restricted to that race's starters.

Set `LAP_SEASONS="2023 2024"` to widen it; the default is one season because two
would exceed the hourly budget.

**Live timing.** A fourth data source and a fourth service, `F1LiveNowApi` —
`/odata/f1-now/` — carrying what neither f1db nor Jolpica publish.

```
Race @ Hungaroring, Budapest — lead lap 70, air 31.3°C, track 47.0°C
  P1  NOR  Lando NORRIS     McLaren          gap 0.0     S1 29.105 S2 30.486 S3 24.034  SOFT(3) 2 stops
  P2  VER  Max VERSTAPPEN   Red Bull Racing  gap 15.08   S1 29.425 S2 30.537 S3 24.258  SOFT(3) 2 stops
  P3  ANT  Kimi ANTONELLI   Mercedes         gap 18.728  S1 29.053 S2 30.514 S3 23.905  HARD(0) 2 stops
```

Source: [OpenF1](https://openf1.org) — unofficial, free, key-less, documenting a
~3 second delay during a session. `scripts/fetch-f1-live.sh` snapshots one
session into `data/live/` as six CSVs. Four are the snapshot — session, order,
weather, race control. The other two are the history behind it: `live-trace.csv`
carries one row per driver per lap with position and gap to leader, and
`live-stints.csv` every set of tyres rather than only the one running. OpenF1
returns every endpoint as a time series, so keeping the history costs nothing at
the source, and it is the difference between a table of standings and a chart of
how the race got there.

The page reads the last snapshot and **shows when it was taken**. Re-run and
reload for the next one.

Three traps, all of them now handled in the script and named in its header:

* OpenF1 **404s the entire request if you pass `limit`**. Filter with
  `session_key` / `driver_number` instead.
* It **rate-limits per burst**, not per hour: fetching the nine endpoints back
  to back reliably earns a 429 partway down the list, and a 429 body is JSON
  too, so it lands in the output file and parses to nothing — which is how a
  snapshot ends up with a running order and no weather. The script retries with
  a widening pause.
* It **switches off unauthenticated access while a session is running** — every
  endpoint, past sessions included, answers 401 until the session ends. So the
  one moment a live page most wants a refresh is the one moment a *free* fetch
  cannot get one.

**Authenticating.** With an OpenF1 account it can. The scheme is OAuth2's
*password* grant and nothing more — there is no authorize endpoint, no redirect
and no consent screen, so there is no login page to build:

```bash
export OPENF1_USERNAME='...'
export OPENF1_PASSWORD='...'     # or OPENF1_TOKEN=<token> to skip the grant
sh scripts/fetch-f1-live.sh
```

The script form-POSTs to `https://api.openf1.org/token`, gets a bearer token
good for an hour, and sends it as `Authorization: Bearer` on every call. The
token is cached in `~/.mxcli/openf1-token` (mode 600) with its expiry, so a
fetch on a timer re-uses one token rather than re-sending the password every
minute. Credentials come from the environment and are passed to curl with
`--data-urlencode`, so they never reach a URL, a command line `ps` could show,
or the repository.

**An hour is shorter than a Grand Prix.** A race is ninety minutes of running
plus the formation lap, and a red flag can push it past three; a token minted at
lights-out expires somewhere around lap 50. Two mechanisms cover that, and they
cover different failures:

* *between runs* — every invocation re-reads the cached token and mints a new
  one as soon as the old is within five minutes of expiring. On a timer this is
  the whole answer: the run that straddles the hour mark pays for one extra
  round trip and nothing else notices. Five minutes rather than one because a
  full fetch is nine endpoints plus a per-driver telemetry pass, each of which
  can retry through a 429 backoff, so a run can outlive a smaller margin;
* *within a run* — a 401 mid-fetch re-mints once and retries that request, and
  the new token then serves every endpoint after it. Without this the failure is
  silent rather than loud: the remaining endpoints return nothing, the write
  guard keeps the previous snapshot, and the page shows a stale timestamp with
  no error anywhere to explain it.

`OPENF1_TOKEN` is a starting value rather than a ceiling — set it alone and the
fetch stops working after an hour, which the 401 message says out loud. Set the
username and password too and a long session refreshes itself.

On a race Sunday, a timer is all that is needed:

```bash
while sleep 30; do SESSION=latest sh scripts/fetch-f1-live.sh; done
```

That last point is why a failed fetch is now non-destructive: a file is always
*present*, because `read_csv()` needs something to open, but it is only
*rewritten* when the fetch returned rows.

**Circuit outlines.** The shape of each track, as an SVG path — and not traced
from the Wikipedia diagrams. Those are drawings: each hand-authored with its own
viewBox, stroke weights and embedded corner labels, so using them means cleaning
seventy files by hand and trusting the result.

OpenStreetMap maps a circuit as what it is — a chain of one-way ways carrying
real coordinates, usually one per named corner. At Zandvoort they come back
named: Tarzanbocht, Scheivlak, Hugenholtzbocht. `scripts/fetch-circuit-outlines.py`
stitches them in racing order into a closed loop and projects it, correcting
longitude by cos(latitude) so Spa is not drawn on a different projection to
Monza.

Because it is geometry rather than artwork, **it can be checked**: every outline
is measured against the length f1db records for that circuit, and one that
disagrees by more than a few per cent is left out rather than shown.

| Circuit | Traced | f1db recorded | Out by |
|---|---|---|---|
| Lusail | 5.426 km | 5.419 km | 0.1% |
| Austin | 5.502 km | 5.513 km | 0.2% |
| Hungaroring | 4.367 km | 4.381 km | 0.3% |
| Interlagos | 4.336 km | 4.362 km | 0.6% |

That guard is not decoration. An early version of the stitcher followed the pit
lane out of the Hungaroring and came back with 5.434 km against a recorded
4.381 — a plausible-looking shape that was 24% wrong, and exactly the error you
cannot detect when you are copying a picture. Street circuits are the remaining
gap: several are mapped as ordinary roads rather than `highway=raceway`, so no
closed loop forms and they are absent rather than approximated.

Output is `data/circuits/f1db-circuit-paths.csv` (the path, plus both lengths and
the licence) and `f1db-circuit-points.csv` (the same outline as vertices, which
is what the weekend screen's chart draws), and one SVG per circuit for
inspection. Overpass responses are cached, so a re-run is free.

OpenStreetMap is ODbL, which requires attribution; it rides in the row rather
than in a comment, and the weekend screen prints it under the circuit name.

**Wikipedia.** 224 paragraphs covering all 77 seasons, 116 race-winning drivers
and 31 winning constructors, fetched by `scripts/fetch-f1-facts.sh` and read by
DuckDB from `data/facts/f1db-facts.csv` like everything else. The text is
CC BY-SA 4.0; the article link and licence travel with every row.

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

That is all it takes again. Until mxcli `b4a825e` the boot deleted the browser
client it had just built and every page came up black, so this repo carried a
wrapper script to put it back; the boot now bundles after packaging and verifies
it. FINDINGS §35, §41.

**Watching it run.** `scripts/run-observed.sh` boots both apps with the three
things a plain `run --local` leaves off, and puts them on the hub:

```bash
scripts/run-observed.sh          # both apps, observed, on $MXCLI_HUB_URL
HUB= scripts/run-observed.sh     # the same, local only
scripts/run-observed.sh stop
```

| | |
|---|---|
| Errors | `Formula1{Backend,Frontend}/.mxcli/runtime.log` — server stack traces and microflow `LOG` output. The browser only ever shows a generic dialog; this is where the cause is. |
| Metrics | `--metrics` registers a Prometheus registry: `http://127.0.0.1:8090/prometheus` (backend), `:8190` (frontend). Sessions, JVM, connection pool, request counts. |
| Traces | `--trace-otlp` attaches the OpenTelemetry agent and exports to `scripts/otlp-collector.py`, which writes one JSON object per span to `.mxcli-obs/spans.jsonl`. |

`--trace` on its own uses a console exporter that drops timestamps and parent
span ids — enough to see that a span happened, not enough for a duration or a
call tree. The collector is what keeps both, and

```bash
python3 scripts/span-report.py .mxcli-obs/spans.jsonl --since 60
```

reads it: failures first, then total self-time by span, then the slowest single
spans, then the traces worth opening. Self-time is a span's duration less its
children's — a parent at 2000ms with 3ms of its own is not the bottleneck,
something under it is. Take one of the trace ids it prints and

```bash
python3 scripts/span-report.py .mxcli-obs/spans.jsonl --trace <id>
```

prints that request as a tree, SQL statements included. A cold
`GET /odata/f1-fan/DriverSeasons` looks like this — the authentication microflow,
then the DuckDB scan that is the actual cost:

```
  866.9ms  own   38.7ms  GET /*
     12.4ms  own   1.7ms  Microflow Formula1Backend.AuthenticateApiClient
       10.7ms  own   8.0ms  Retrieve activity //System.User[Name = ?]
    810.7ms  own   1.4ms  Microflow Formula1Backend.Read_DriverSeasons
      808.1ms own 393.4ms  ExecuteDatabaseQueryAction activity
```

One caveat worth knowing before reading a report: the first thirty seconds after
boot are dominated by Mendix's own cluster-management tasks, which have nothing
to do with the app. `--since` exists for that — exercise the page, then ask what
the last sixty seconds did.

**Flame charts.** With the apps observed, walk the screens and render the spans
as flame charts:

```bash
node  scripts/walk-screens.mjs .mxcli-obs/marks.json      # drives the six screens
python3 scripts/span-flame.py .mxcli-obs/spans.jsonl \
        .mxcli-obs/marks.json flames.html \
        Formula1Frontend/theme/web/mxcli-fonts/…          # optional inlined faces
```

`marks.json` records when each screen was on screen, which is how a span is
attributed to the screen that caused it. Each screen then gets two flames, and
they answer different questions. The **timeline** is one request on real time —
x is offset from its start, so a wide frame with a narrow child was waiting. The
**merged** flame is every span the screen produced, folded by call path and
summed, so x is share of work rather than time and a query issued twenty-eight
times is twenty-eight times wider.

Both are end to end: the consumed OData client propagates trace context, so one
stack descends from the browser's `POST /xas/`, through the frontend's
`Retrieve by microflow`, across the service call, into the backend microflow and
down to the DuckDB scan.

**Regenerating the screenshots.** With both apps up:

```bash
node scripts/shoot-screenshots.mjs
```

It logs in as the demo user, walks all five screens and writes
`docs/screenshots/`. Two things to know before believing a bad-looking result:
the weekend screen needs the better part of a minute for its last chart series, and the trial
licence caps concurrent sessions — enough runs and the client 401s at startup
and pages come up empty. Clear them with

```bash
sudo -u postgres psql -d formula1frontend -c 'delete from system$session;'
```

Rendering the real pages is not decoration. It is the only check in this project
that catches a chart on a white ground, a column header reading `COLOPENWEEKEND`,
or a drill-down that opens the wrong record — none of which `check`, the build,
the runtime log or `curl` report. FINDINGS §38 lists what one pass found.

`./mxcli` is built from source rather than downloaded — see
`scripts/build-mxcli.sh` and the note in `FINDINGS.md`. Both the binary (~85 MB)
and the CSVs are git-ignored; the scripts that fetch them are committed, which
is what lets a reaped session bootstrap from files instead of from a prompt.

See `FINDINGS.md` for what broke and what was worked around.

### Do not put the backend on the hub

`mxcli run --hub` sets `ApplicationRootUrl` to the public preview address so the
app works under that origin. For the frontend that is the whole point. For the
backend it silently breaks the frontend.

Mendix pages a published OData collection at 200 rows and puts an **absolute**
`@odata.nextLink` in the response, built from that root URL. With the backend on
the hub, a read of a season's race results comes back as:

```
"@odata.nextLink": "https://formula1backend.mxcli.org/odata/f1/RaceResults?$filter=year+eq+1988&$skip=200"
```

The frontend follows it, lands on the hub's GitHub sign-in gate, and the
retrieve throws — `Exception while retrieving data for 'dvMultiples'`. Every
single-page read keeps working, which is what makes it confusing: the failure is
specific to collections larger than one page, and the season screen's small
multiples were the first thing to cross that line.

So: frontend on the hub, backend on `--local`. The backend is an API behind a
key; it gains nothing from a public URL and costs the frontend its paging.

```bash
cd Formula1Backend  && ./mxcli run --local -p Formula1Backend.mpr
cd Formula1Frontend && ./mxcli run --hub https://hub.mxcli.org --hub-solution formula1 \
    -p Formula1Frontend.mpr --app-port 8180 --admin-port 8190 --serve-port 6643
```

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

The frontend's OData client used to send basic credentials and hold no session,
so the backend ran a **full BCrypt password verification on every request**. A
wrong password cost the same ~350 ms as a right one; no credentials at all cost
10 ms. That was the single biggest cost in the solution — bigger than reading a
4 MB CSV twice.

It is gone. All five services use custom authentication: a microflow reads a key
off the request headers, so there is no password to verify and no hash to
compute. The interim fix — dropping the BCrypt work factor from 12 to 8, which
is a deliberate weakening — has been reverted with it.

FINDINGS §31 has the full trace and the method; §40 and §48 the fix.

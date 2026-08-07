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
| `Formula1Backend` | `http://backend.local:8080/` (admin 8090, serve 6543) | Reading the CSVs through DuckDB over JDBC, and publishing the result as OData |
| `Formula1Frontend` | `http://frontend.local:8180/` (admin 8190, serve 6643) | Consuming that OData and presenting it — the browsing UI the enthusiast uses |

Each app is a full Mendix project: its own `.mpr`, its own runtime, its own
Postgres database (`formula1backend` / `formula1frontend`, derived from the
`.mpr` name).

**Two hostnames, not just two ports.** Cookies are keyed on host name and ignore
the port, so both apps on `localhost` would share one cookie jar and silently
overwrite each other's `XASSESSIONID`. `backend.local` and `frontend.local` both
resolve to `127.0.0.1` via `/etc/hosts`; each app's `ApplicationRootUrl` names
its own host so the runtime generates absolute URLs (deep links, OIDC redirect
URIs) against the name rather than the listen address.

**How they talk.** The backend publishes an OData service; the frontend consumes
it via an OData client plus external entities. Wire it in dependency order — the
backend must be *running* when the OData client is created, because
`CREATE ODATA CLIENT` fetches `$metadata` at that moment and caches it. The
frontend's `ServiceUrl` points at a constant, not a literal, so the address is
environment-overridable.

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
Database Connector.

## Working on it

A `SessionStart` hook (`.claude/settings.json` → `.claude/bootstrap-mxcli.sh`)
makes a fresh clone ready by itself: it builds mxcli, fetches the CSVs, adds the
hostnames, caches MxBuild + the Mendix runtime and provisions both databases.
To do it by hand:

```bash
sh .claude/bootstrap-mxcli.sh
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

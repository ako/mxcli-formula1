# The model, as re-runnable MDL

Every model change in this repo lives here as a numbered script rather than only
in the `.mpr`. Run them in order against a blank app and you get the whole
backend back. That is how the current `.mpr` was built, twice over, after the
domain model had to be reshaped.

```bash
cd Formula1Backend
for f in ../model/backend/[0-9][0-9]-*.mdl; do ./mxcli exec "$f" -p Formula1Backend.mpr; done
./mxcli -p Formula1Backend.mpr -c \
  "alter settings model AfterStartupMicroflow = 'Formula1Backend.ASU_LoadCacheIfEmpty';"
```

| Script | What it adds |
|---|---|
| `00-dependencies.mdl` | The module and the DuckDB JDBC driver. Separate because `ADD JAR DEPENDENCY` has no `IF NOT EXISTS`. |
| `01-foundation.mdl` | The DuckDB connection (`type 'BYOD'`), the `Stg_*` row shapes, and one query per resource. Both services stand on this. |
| `02-live-service.mdl` | Read microflows + `F1LiveApi` — non-persistable entities served straight from the CSVs. |
| `03-persistent-entities.mdl` | The persistent mirror + associations, for the cached service. |
| `04-refresh.mdl` | `ACT_RefreshAll` and the per-resource load jobs, plus the startup hook that fills an empty cache. |
| `05-cached-service.mdl` | `F1CachedApi` — the same eight resources with paging, `$filter` and navigation properties. |
| `06-security.mdl` | Module roles, entity and microflow access, user roles. |
| `07-demo-users.mdl` | `f1api` / `f1admin`. Split out when 06 could not be re-run; kept because demo users are worth changing on their own. |
| `08-health.mdl` | Row-count helpers and `Check_ServicesAgree`, the invariant the tests assert. |
| `09-query-pushdown.mdl` | Java actions that turn OData query options into SQL. Logic lives in `javasource/formula1backend/ODataQuery.java`. |
| `10-live-pushdown.mdl` | The read microflows that use them — `Read_Drivers` and `Read_RaceResults`. **Owns those two microflows**; `02` must not redefine them, and must run before this. |
| `11-pushdown-tests-support.mdl` | Thin wrappers so the Java actions can be unit-tested directly, plus `Probe_DynamicSql`. |
| `13-fan-resources.mdl` | `F1FanApi` — the derived views the fan pages are built on, and the two Java actions that lift an id out of `$filter`. Owns its service outright. |
| `12-folders.mdl` | Sorts the documents the scripts above created into folders. Runs last, and is the only place the layout is written down. |

## The folder layout

`00`–`11` and `13` create everything at the module root, which is fine at ten documents
and unreadable at forty. `12` sorts them:

| Folder | Holds |
|---|---|
| `Warehouse/` | The DuckDB connection and the four constants that configure it. |
| `Live/` | The eight read microflows behind `F1LiveApi`. |
| `Live/Pushdown/` | The three Java actions that turn OData query options into SQL. |
| `Cached/` | `ACT_RefreshAll`, `ASU_LoadCacheIfEmpty` and the eight refresh jobs. |
| `Health/` | The eight row counts and `Check_ServicesAgree`. |
| `Fan/` | The five read microflows behind `F1FanApi`. |
| `Services/` | All three published OData services. |
| `TestSupport/` | Wrappers that exist only so tests can reach the Java actions. |

Nothing is left at the module root. Five documents used to be — the Java actions
and both services — because `MOVE` had no doctype for either; mxcli `c76d4b7`
added both. FINDINGS §32, §34.

It is a separate script rather than `folder '…'` clauses on each definition
because `CREATE OR REPLACE` preserves a document's existing folder — so
re-running `00`–`11` leaves the layout alone — and because constants and the
database connection have no folder clause to hang it on. Re-running `12` is a
no-op on an already-tidy module.

## Re-runnability

Every script re-runs. `06` did not until mxcli `c76d4b7` added
`create or modify module role` (and the user-role form behind it) — before that
it stopped at the first role that already existed, which is why the demo users
were split into `07`. The split is still useful, but no longer required. To
rebuild from scratch, drop the module first:

```bash
./mxcli -p Formula1Backend.mpr -c "drop module Formula1Backend;"
```

Dropping the module also drops the security rules, so `06` then applies cleanly.
The user roles (`ApiConsumer`, `Administrator`) live at project level and survive
the drop; `06` uses `alter user role … add module roles` for `Administrator`
because the blank template already ships one.

## Four things that will bite whoever edits this

- **Whole numbers are `long`, not `integer`.** mxcli used to publish a Mendix
  `Integer` as `Edm.Int32` where Mendix wants `Edm.Int64`, and every exposed
  `integer` failed the build. Fixed in `c76d4b7`; the types here were never
  changed back, because `long` is right for these columns anyway. FINDINGS §16.
- **A `KEY` on a persistent entity needs `unique` on the attribute too.** The
  non-persistable `Stg_*` entities do not — same `expose` clause, different rule.
  FINDINGS §17.
- **`10` owns `Read_Drivers` and `Read_RaceResults`.** Re-running `02` after `10`
  reverts them to their non-pushdown form and the build fails on the missing
  `System.ODataResponse` parameter.
- **The standings key is `(year, positionDisplayOrder)`.** Not `(year,
  constructorId)`: Brabham has three 1966 rows, one per engine. FINDINGS §18.

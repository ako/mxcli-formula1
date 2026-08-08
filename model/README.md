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
| `07-demo-users.mdl` | `f1api` / `f1admin`. Separate because 06 is not re-runnable. |
| `08-health.mdl` | Row-count helpers and `Check_ServicesAgree`, the invariant the tests assert. |
| `09-query-pushdown.mdl` | Java actions that turn OData query options into SQL. Logic lives in `javasource/formula1backend/ODataQuery.java`. |
| `10-live-pushdown.mdl` | The read microflows that use them — `Read_Drivers` and `Read_RaceResults`. **Owns those two microflows**; `02` must not redefine them, and must run before this. |
| `11-pushdown-tests-support.mdl` | Thin wrappers so the Java actions can be unit-tested directly. |
| `12-folders.mdl` | Sorts the documents the scripts above created into folders. Runs last, and is the only place the layout is written down. |

## The folder layout

`00`–`11` create everything at the module root, which is fine at ten documents
and unreadable at forty. `12` sorts them:

| Folder | Holds |
|---|---|
| `Warehouse/` | The DuckDB connection and the four constants that configure it. |
| `Live/` | The eight read microflows behind `F1LiveApi`. |
| `Cached/` | `ACT_RefreshAll`, `ASU_LoadCacheIfEmpty` and the eight refresh jobs. |
| `Health/` | The eight row counts and `Check_ServicesAgree`. |
| `TestSupport/` | Wrappers that exist only so tests can reach the Java actions. |

Five documents stay at the root because mxcli cannot move them: the three
pushdown **Java actions** and both **published OData services**. `MOVE` has no
doctype for either and neither `CREATE` form takes a folder clause. FINDINGS §32.

It is a separate script rather than `folder '…'` clauses on each definition
because `CREATE OR REPLACE` preserves a document's existing folder — so
re-running `00`–`11` leaves the layout alone — and because constants and the
database connection have no folder clause to hang it on. Re-running `12` is a
no-op on an already-tidy module.

## Re-runnability

`01`–`05` and `08` use `CREATE OR REPLACE` / `create or modify` and are safe to
re-run. **`06` is not** — `create module role` has no `or modify` form, so it
stops at the first role that already exists. To rebuild from scratch, drop the
module first:

```bash
./mxcli -p Formula1Backend.mpr -c "drop module Formula1Backend;"
```

Dropping the module also drops the security rules, so `06` then applies cleanly.
The user roles (`ApiConsumer`, `Administrator`) live at project level and survive
the drop; `06` uses `alter user role … add module roles` for `Administrator`
because the blank template already ships one.

## Five things that will bite whoever edits this

- **Whole numbers must be `long`, not `integer`.** mxcli publishes a Mendix
  `Integer` as `Edm.Int32` while Mendix itself wants `Edm.Int64`, so any
  `integer` attribute exposed in either service fails the build. FINDINGS §16.
- **A `KEY` on a persistent entity needs `unique` on the attribute too.** The
  non-persistable `Stg_*` entities do not — same `expose` clause, different rule.
  FINDINGS §17.
- **`dynamic '' + $Sql`, never `dynamic $Sql`.** mxcli quotes a bare variable into
  a literal, so the runtime is asked to execute the text `$Sql`. FINDINGS §21.
- **`10` owns `Read_Drivers` and `Read_RaceResults`.** Re-running `02` after `10`
  reverts them to their non-pushdown form and the build fails on the missing
  `System.ODataResponse` parameter.
- **The standings key is `(year, positionDisplayOrder)`.** Not `(year,
  constructorId)`: Brabham has three 1966 rows, one per engine. FINDINGS §18.

# The model, as re-runnable MDL

Every model change in this repo lives here as a numbered script rather than only
in the `.mpr`. Run them in order against a blank app and you get the whole
backend back. That is how the current `.mpr` was built, twice over, after the
domain model had to be reshaped.

```bash
scripts/create-f1ops-db.sh          # the Postgres database 16 reaches into
cd Formula1Backend
./mxcli exec ../model/odatapushdown/module.mdl -p Formula1Backend.mpr
for pass in 1 2; do                 # twice — see "Two passes", below
  for f in ../model/backend/[0-9][0-9]-*.mdl; do ./mxcli exec "$f" -p Formula1Backend.mpr; done
done
./mxcli exec ../model/backend/12-folders.mdl -p Formula1Backend.mpr   # last
./mxcli sync-java-deps -p Formula1Backend.mpr
./mxcli -p Formula1Backend.mpr -c \
  "alter settings model AfterStartupMicroflow = 'Formula1Backend.ASU_LoadCacheIfEmpty';"
```

## Two passes, and why

**The set converges in two passes, not one.** That is a property of how these
files are split, not of MDL. Each file owns its documents *and* the grants on
them, so grants are forward references across files:

- `02` grants to `Formula1Backend.ApiUser`, a module role `06` creates;
- `06` grants execute on `Read_Drivers`, a microflow `10` owns;
- `13` grants on `F1FanApi`, which `14` declares.

`02 → 06 → 10 → 02` is a genuine cycle, so no single ordering exists. Running
the set twice resolves it: pass one creates every document, pass two lands every
grant. `12-folders.mdl` still has to come last — glob order puts it before `13`
and `14`, whose documents it moves.

The clean fix is to split `06` into roles-then-grants so the cycle breaks and
one pass suffices. Not done; the two-pass loop above is verified.

The frontend has the same shape and needs three passes — its page scripts
cross-reference each other's pages (`04` opens `Driver_Career` from `07`, which
opens `Race_Weekend` from `08`).

**`02-external-entities.mdl` must run exactly once**, so it is outside the loop:

```bash
cd Formula1Frontend
./mxcli exec ../model/frontend/01-odata-clients.mdl     -p Formula1Frontend.mpr
./mxcli exec ../model/frontend/02-external-entities.mdl -p Formula1Frontend.mpr   # ONCE
for pass in 1 2 3; do
  for f in ../model/frontend/0[3-9]-*.mdl; do ./mxcli exec "$f" -p Formula1Frontend.mpr; done
done
```

`create external entities from` duplicates any association whose name needed a
numeric suffix, every time it runs, without bound — two per run here. This repo
had silently accumulated `season_2` … `season_15` before a rebuild exposed it.
FINDINGS §50.

## Re-running is not free

A rebuild converges, but re-running the scripts on an already-built project is
**not** a no-op in version control. It is a no-op in the *model* — the semantic
fingerprint does not move — but every `create or modify` regenerates the
internal element ids of the document it rewrites, so 143 `.mxunit` files change
and their bytes differ on every run. A constant re-declared identically changes
exactly 16 bytes: one UUID.

Practically: do not expect `git diff` to tell you whether a script did anything,
and do not commit the churn from a re-run that changed nothing. FINDINGS §50.

## Verified, not asserted

`scripts/fingerprint.sh` dumps a semantic fingerprint of both apps — every
document round-tripped through `DESCRIBE`, the security matrix, the settings,
and the published `$metadata`. A rebuild cannot produce a byte-identical `.mpr`
(Mendix keys documents by UUID, so every element gets a new id and
`git diff mprcontents/` is thousands of files either way), but the fingerprint
carries meaning rather than identity.

Dropping all seven modules and rebuilding from these scripts, then diffing:

- **all five published `$metadata` documents byte-identical** — the contract a
  consumer binds to is exactly reproduced;
- 71/71 backend and 23/23 frontend tests pass against the rebuilt apps;
- `mx check` 0 errors on both;
- 166 differing lines, all in three classes: `@Position` coordinates for
  entities the scripts do not place explicitly, listing order, and a set of
  stale `…User` role grants that live in the `.mpr` and no script creates.

That last class is drift the rebuild *removed*: page and microflow grants to
the default `User` module role, left over from an early iteration. No demo user
holds that role — `fan` is `Enthusiast` — so nothing reachable changed.

`model/odatapushdown/` is not part of this app. It is a standalone Mendix module
— OData query options to SQL, for any resource backed by a read microflow over
data Mendix cannot see — and it runs first because everything from `02` onward
calls it. It has its own README. Copy it and `javasource/odatapushdown/` into
another project and it works there unchanged; that is the point of it.

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
| `10-live-pushdown.mdl` | The two **splice-style** reads — `Read_Drivers` and `Read_RaceResults`, which build their own SQL and concatenate `FilterSql` / `OrderBySql` into it. **Owns those two microflows**; `02` must not redefine them, and must run before this. |
| `11-pushdown-tests-support.mdl` | Thin wrappers so `ODataPushdown` can be unit-tested directly, plus `Probe_DynamicSql`. |
| `13-fan-resources.mdl` | The five derived views the fan pages are built on. Owns those microflows; **not** the service. |
| `14-weekend.mdl` | `RaceWeekend`, `RaceSessions`, `Calendar`, `WeekendShape`, `LapChart` — and the **whole** `F1FanApi` declaration, all ten resources, because `create or modify odata service` takes the entire surface. Grants service access after it — which used to be mandatory because the modify dropped it, and is now just where the grant lives. |
| `16-ops-procedures.mdl` | `F1OpsApi` — a Postgres database this app does not own, with its logic in **stored procedures**. A table function behind a read, a procedure behind a real **OData action**, and the custom-authentication microflow all five services use. Needs `scripts/create-f1ops-db.sh` first. |
| `12-folders.mdl` | Sorts the documents the scripts above created into folders. **Runs last** — after `16`, despite the number — and is the only place the layout is written down. |

## The folder layout

`00`–`11`, `13` and `14` create everything at the module root, which is fine at ten documents
and unreadable at forty. `12` sorts them:

| Folder | Holds |
|---|---|
| `Warehouse/` | The DuckDB connection and the four constants that configure it. |
| `Live/` | The eight read microflows behind `F1LiveApi`. |
| `Cached/` | `ACT_RefreshAll`, `ASU_LoadCacheIfEmpty` and the eight refresh jobs. |
| `Health/` | The eight row counts and `Check_ServicesAgree`. |
| `Fan/` | The five read microflows behind `F1FanApi`. |
| `Fan/Weekend/` | The five that answer for one Grand Prix, including the lap traces. |
| `Services/` | All three published OData services. |
| `TestSupport/` | Wrappers that exist only so tests can reach ODataPushdown and the dynamic-SQL path. |

Nothing is left at the module root. Five documents used to be — the Java actions
and both services — because `MOVE` had no doctype for either; mxcli `c76d4b7`
added both. FINDINGS §32, §34. `Live/Pushdown/` is gone with them: the ten Java
actions it held became the `ODataPushdown` module. FINDINGS §46.

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

## Six things that will bite whoever edits this

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
- **A `type 'PostgreSQL'` connection still needs the driver declared AND
  shipped.** Mendix runs on Postgres and it buys nothing: without a module jar
  dependency the build fails CE5278, and with `included = false` the build is
  green and the first request dies with "No JDBC driver found in app for URL".
  FINDINGS §47.
- **`drop module ODataPushdown` deletes `javasource/odatapushdown/` with it**,
  hand-written classes included — the drop takes the whole Java package, not
  only the generated action wrappers. To re-apply the module cleanly, run the
  script over the existing one; it is `create or modify` throughout.

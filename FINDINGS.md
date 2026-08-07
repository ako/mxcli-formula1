# Findings

Durable notes for the next session, and feedback worth sending back upstream to
mxcli. Append, do not rewrite.

**Versions in play**

| | |
|---|---|
| mxcli | built from source, `ako/mxcli` main @ `9236202` (2026-08-07), reports `mxcli version 9236202` |
| Mendix | 11.13.0 (MxBuild + runtime cached under `/root/.mxcli/mxbuild/11.13.0/`) |
| Go / JDK / ANTLR | go1.24.7 / OpenJDK 21.0.10 / antlr4-tools 0.2.2 with ANTLR 4.13.2 |
| DuckDB JDBC | `org.duckdb:duckdb_jdbc` 1.5.5.1 (driver reports version "1.0") |
| F1 dataset | [f1db/f1db](https://github.com/f1db/f1db) `f1db-csv.zip`, latest release |

---

## 1. Building mxcli from source: the documented path is incomplete

*Verified 2026-08-07, on `ako/mxcli` main @ `9236202`.*

`make build` depends on `grammar`, which delegates to `mdl/grammar/Makefile`,
which requires an `antlr4` (or `antlr`) launcher on `PATH` and errors out with
`ANTLR4 not found` otherwise. The README's note that `go install …@latest` does
not work is correct — the generated parser under `mdl/grammar/parser/` is not
committed — but the prerequisite list stops at "install ANTLR4" without saying
which version.

It matters: the CI workflows (`push-test.yml`, `release.yml`, `nightly.yml`) all
pin `ANTLR4_TOOLS_ANTLR_VERSION: '4.13.2'` against `antlr4-tools==0.2.2`, while
`go.mod` requires runtime `github.com/antlr4-go/antlr/v4 v4.13.1`. A generator/
runtime mismatch is a classic ANTLR failure mode, so the pin is load-bearing and
belongs in `mdl/grammar/Makefile`'s error message, not only in CI YAML.

What worked, from nothing:

```bash
pip install 'antlr4-tools==0.2.2'
export ANTLR4_TOOLS_ANTLR_VERSION=4.13.2
make -C /path/to/mxcli build     # ~2 min cold, 85 MB binary at bin/mxcli
```

`antlr4-tools` downloads `antlr4-4.13.2-complete.jar` on first run, so the build
needs network *and* a JVM, not just Go. Captured as `scripts/build-mxcli.sh`.

**Suggestion:** have `check-antlr` print the pinned version, and add a
`make bootstrap-antlr` target that does the pip install.

## 2. `mxcli new` hardlinks the local binary instead of downloading — good

Step 5 of `mxcli new` is documented as "Downloads the correct mxcli binary for
the devcontainer (linux)". On Linux it does not download: it printed
`Linked mxcli to …/Formula1Backend/mxcli (shared inode, no copy)`, and
`ls -i` confirmed all three paths share inode `475240`.

That is exactly right for a from-source build — the app folders got *our* binary,
not the nightly. Worth noting because the task instructions assume the opposite
and tell you to `rm -f <AppName>/mxcli` before moving files up. The help text for
`mxcli new` should say "links, or downloads if no local binary is usable".

## 3. Running `mxcli init` from a solution root silently picks one app

*Verified 2026-08-07.*

With two app folders side by side and **no** `.mpr` at the repo root, running
bare `./mxcli init --tool claude` from the root did not error and did not create
anything at the root. It walked into `Formula1Backend` and re-initialised that
one — `Generated 42 widget docs in /home/user/mxcli-formula1/Formula1Backend/…`.
`Formula1Frontend` was untouched.

That is a quiet wrong-target: in a two-app repo the odds of picking the app you
meant are 50%. Auto-discovery should either refuse when it finds more than one
candidate project, or say which one it chose *before* doing the work.

**Workaround:** always `cd` into the app folder, or pass the project directory
explicitly.

## 4. The generated bootstrap hook is per-app, and Claude Code only reads the root one

`mxcli init` writes `.claude/settings.json` + `.claude/bootstrap-mxcli.sh` inside
each app folder. Claude Code reads the root one, and dedupes hook entries on the
command string rather than on the project — so a solution gets zero working
hooks unless you write the root one yourself.

Two more things the generated script cannot know in a solution:

- It hardcodes the nightly release URL
  (`mendixlabs/mxcli/releases/download/nightly/…`). A from-source solution has to
  bypass it entirely.
- It runs `run --local --setup --ensure-db` on the default ports. The second app
  needs `--app-port 8180 --admin-port 8190 --serve-port 6643`.

The root `.claude/bootstrap-mxcli.sh` here covers both apps, builds from source,
fetches the dataset, and writes `/etc/hosts`. The per-app scripts are left in
place (harmless, and correct if someone opens a single app folder directly).

**Suggestion:** `mxcli init` could detect sibling `.mpr` projects and offer to
write a solution-level root hook with one line per app.

## 5. Ergast is gone — the dataset most F1 tutorials point at is dead

`https://ergast.com/downloads/f1db_csv.zip` returns **HTTP 200 with an HTML
page** (`content-type: text/html`, 78 KB, `<html lang="az">`) — a parked/squatted
domain, not a 404. Anything that trusts the status code will happily write an
HTML file named `.zip` and fail later at unzip.

Replacement: [f1db/f1db](https://github.com/f1db/f1db), CC-BY-4.0, actively
maintained, `f1db-csv.zip` on every release —
`https://github.com/f1db/f1db/releases/latest/download/f1db-csv.zip` (4.5 MB
zipped, 25 MB / 47 CSVs unzipped, 1950 → present). `scripts/fetch-f1-data.sh`
verifies by checking for an extracted CSV, not by trusting the HTTP status.

## 6. Mendix 11.13's External Database Connector has a `BYOD` type — this is what makes DuckDB possible

*Verified 2026-08-07 by reading the shipped Studio Pro editor bundle at
`/root/.mxcli/mxbuild/11.13.0/modeler/ide-client/database-connector-editor/`.*

The mxcli skill `database-connections.md` lists the supported `TYPE` values as
Oracle / PostgreSQL / MySQL / MSSQL / Snowflake / Redshift. DuckDB is not there,
which reads as "this architecture is impossible".

The editor bundle tells a different story. The actual picker is:

```js
[{id:"MSSQL",label:"Microsoft SQL"},{id:"MySQL",label:"MySQL"},{id:"Oracle",label:"Oracle"},
 {id:"PostgreSQL",label:"PostgreSQL"},{id:"Snowflake",label:"Snowflake"},{id:"BYOD",label:"Other"}]
```

`BYOD` — bring your own driver. Selecting it forces the connection-string config
method and **skips the driver presence check** (`if(!o||o==="BYOD"){…driverCheckStatus="idle"…}`).
Its only validation is that the connection string is non-empty. That is exactly
the hook needed for a JDBC driver Mendix has never heard of.

Two corrections fall out of this:

- The skill doc's table is wrong in both directions: it lists `Redshift`, which
  is **not** in the 11.13 picker, and omits `BYOD`, which is.
- mxcli does not validate the type string at all — `mdl/executor/cmd_dbconnection.go`
  passes `stmt.DatabaseType` straight through to `addStr(e,"DatabaseType",…)` in
  `mdl/backend/modelsdk/db_write.go`. So `type 'BYOD'` will be written happily;
  whether the *runtime* accepts it is still unproven here (see open items).

## 7. DuckDB-over-CSV via JDBC: verified working, including a bound path prefix

*Verified 2026-08-07 with a standalone JDBC harness (`java -cp duckdb_jdbc.jar`),
against the real 47-file dataset. Not yet verified from inside the Mendix runtime.*

| What | Result |
|---|---|
| `jdbc:duckdb:` (in-memory, no file, no path in the URL) | works |
| `SELECT … FROM read_csv('/abs/path/f1db-drivers.csv')` | works |
| `read_csv(?)` — filename as a bound JDBC parameter | works |
| `read_csv(? \|\| '/f1db-drivers.csv')` — **prefix** as a bound parameter | works |
| 3-way join across three CSVs in one query | works |
| Full scan of the largest CSV (4.1 MB, 27533 rows) | 204 ms cold, ~140 ms warm |
| Same on a brand-new connection (what a pool does) | 178 ms |

The `||` concatenation result is the important one: it means the data directory
can be a single Mendix **constant** bound as a query parameter, so no absolute
path is baked into the model and nothing has to be materialised into a `.duckdb`
file. The CSVs really are read in place, per query, and it is fast enough that
no caching layer is needed.

Cost to be aware of: `duckdb_jdbc-1.5.5.1.jar` is **82 MB** — it bundles native
libraries for every platform. That lands in `userlib/` or as a managed
`SET JAR DEPENDENCY 'org.duckdb:duckdb_jdbc'`, and it is not small.

## 8. `describe settings configuration 'Default'` is not valid syntax

`alter settings configuration 'Default' …` is the write form, but the read form
is not symmetrical:

```
> describe settings configuration 'Default';
Parse error: line 1:55 extraneous input 'configuration' expecting the start of a statement
```

`describe settings;` (no object) is the working form and dumps every section as
re-executable `alter settings …` statements, which is genuinely nice. But
`show settings configurations;` renders the configuration as a one-line summary
(`Hsqldb, , db=default, http=8080`) that **omits `ApplicationRootUrl`** — so the
obvious command for "did my root URL land?" cannot answer the question. Use
`describe settings; | grep ApplicationRootUrl` instead.

**Suggestion:** accept `describe settings configuration '<name>'` as an alias,
and include `ApplicationRootUrl` in the `show` summary.

---

## Open / not yet verified

*(Trimmed as items were closed. §10 later proved the OData half of this list; what
remains is the DuckDB half.)*

- `type 'BYOD'` has been shown to *write* cleanly through mxcli and to be a valid
  value in the Studio Pro editor. It has **not** been round-tripped through
  `mxbuild` or exercised against a booted runtime. Do that before trusting it.
- The DuckDB numbers in §7 come from a standalone JVM. Behaviour inside the
  Mendix runtime — driver discovery from `userlib/`, connection pooling against
  an in-memory DuckDB, and whether each pooled connection gets its own empty
  database — is untested.
- The two halves have not been joined: a read microflow whose body is
  `execute database query` against the DuckDB connection. §7 proved the JDBC
  layer, §10 proved the OData layer with a stub microflow returning an empty
  list. Nothing has yet carried a CSV row all the way to an OData response.

**Closed since:** `mxbuild` has now been run against `Formula1Backend` (green,
after the §10 workarounds), so "no `mx check` has been run" no longer holds. Both
apps are otherwise still the blank template plus theme and `ApplicationRootUrl` —
the probe module used in §10 was dropped and the `.mpr` restored.

---

## 9. Both apps boot, on their own hostnames, with the hub previews live

*Verified 2026-08-07.*

```
http://backend.local:8080/    200      http://frontend.local:8180/    200
http://backend.local:8080/xas/ 401     http://frontend.local:8180/xas/ 401   (correct: unauthenticated)
```

`run --local` picked up the per-app root URL exactly as documented:

```
Application root URL from configuration "Default": http://backend.local:8080/
Application root URL from configuration "Default": http://frontend.local:8180/
```

`MXCLI_HUB_KEY` was already set on this environment, so `--hub https://hub.mxcli.org
--hub-solution Formula1` worked for both:

- https://formula1backend-claude-mendix-app-provisioning-gvqxpg.mxcli.org
- https://formula1frontend-claude-mendix-app-provisioning-gvqxpg.mxcli.org

Both return **302 to GitHub OAuth** rather than 200 — the hub gates previews behind
a GitHub login, so `curl` sees the redirect and a browser sees the app. That is the
hub working, not a failure; do not go hunting for a broken tunnel. `--hub` implies
`--local`, so the loopback URLs keep serving at the same time.

Aside: `pkill -f "mxcli run --local"` leaves a **Gradle daemon** (`GradleDaemon 8.5`
from `…/mxbuild/11.13.0/modeler/tools/gradle/`) alive. Harmless, but it is not
mxcli's own process and will not be reaped by killing mxcli.

## 10. Publishing a CSV-backed non-persistable entity over OData: what actually works, and the four mxcli gaps in the way

*Verified 2026-08-07 end to end on `ako/mxcli` main @ `9236202` / Mendix 11.13.0:
MDL executed against a real `.mpr`, `mxbuild` run to completion, and the result
queried over HTTP from a booted runtime. Superseded an earlier version of this
entry that claimed mxcli could not do this at all — that claim was wrong.*

**The headline: it works today, with no changes to mxcli.** A non-persistable
entity, populated by a read microflow and published over OData v4, builds and
serves — no copy of the data into Postgres. Everything below is about the four
places where getting there is harder than it should be.

### 10.0 The MDL that works

```sql
create non-persistent entity ProbeOData.Row (
  RowKey: string(60),
  Label:  string(120)
);

CREATE MICROFLOW ProbeOData.Read_Rows ($Response: System.ODataResponse)
  RETURNS List of ProbeOData.Row AS $Rows
BEGIN
  $Rows = CREATE LIST OF ProbeOData.Row;
  RETURN $Rows;
END;

create odata service ProbeOData.ProbeApi (
  path: 'odata/probe/',
  version: '1.0.0',
  ODataVersion: OData4,
  namespace: 'ProbeOData.Probe',
  ServiceName: 'ProbeApi'          -- gap 1: omitting this fails the build
)
authentication basic
{
  publish entity ProbeOData.Row as 'Rows' (
    ReadMode: microflow ProbeOData.Read_Rows,   -- gap 2: undocumented
    InsertMode: not_supported,
    UpdateMode: not_supported,
    DeleteMode: not_supported
  )
  expose (
    RowKey as 'rowKey' (KEY, Filterable, Sortable),
    Label (Filterable, Sortable)
  );
};

alter odata service ProbeOData.ProbeApi set PublishAssociations = true;  -- gap 4
```

`mxbuild` → **BUILD SUCCEEDED**. Booted with `mxcli run --local`:

```
GET /odata/probe/$metadata          200   <EntitySet EntityType="…Row" Name="Rows">, <Key><PropertyRef Name="rowKey"/>
GET /odata/probe/Rows               200   {"@odata.context":"…#Rows","value":[]}
GET /odata/probe/Rows?$count=true   200   {"…","@odata.count":-1,"value":[]}
```

The read microflow is invoked and its list is what the client receives. (`@odata.count`
is `-1` because the probe microflow never sets `Count` on its `System.ODataResponse`;
that is the microflow's job, not a defect.)

### 10.1 Gap: `CREATE ODATA SERVICE` does not default `ServiceName`, so every published service fails to build

**This is the big one, and it has nothing to do with non-persistable entities —
it breaks every published OData service created purely from MDL.**

```
ERROR at …, Published OData service 'ProbeApi', -: The service name should not be empty.
```

`Name` (the document name) and `ServiceName` (the OData service name in the
metadata document) are different properties. `CREATE ODATA SERVICE` sets only the
first:

```go
// mdl/executor/cmd_odata.go:1356
newSvc := &model.PublishedODataService{
    Name:        stmt.Name.Name,
    ServiceName: stmt.ServiceName,   // empty unless the author typed ServiceName:
    …
}
```

The **consumed** path 300 lines earlier gets this right, and even says why:

```go
// mdl/executor/cmd_odata.go:1038
ServiceName: stmt.Name.Name, // Default ServiceName to document name (CE0339)
```

**Fix:** mirror line 1038 in the published path — `ServiceName: stmt.ServiceName`
falling back to `stmt.Name.Name`. One line. Worth a doctype/roundtrip test that
runs `mxbuild`, since MDL-level `check` passes happily on a model that cannot
deploy.

### 10.2 Gap: `ReadMode: microflow …` works but is undocumented

The full pipeline already supports it, and I only found it by reading the source:

| Stage | Evidence |
|---|---|
| grammar | `odataPropertyValue : … \| MICROFLOW qualifiedName` — `MDLService.g4:156` |
| visitor | `odataValueText` returns `"MICROFLOW " + qn` — `visitor_odata.go:275-280` |
| AST | `parsePublishEntityBlock`, `case "readmode": entity.ReadMode = value` — `visitor_odata.go:344` |
| BSON | `odataReadModeToGen`: `HasPrefix(mode, "MICROFLOW ")` → `ODataPublish$CallMicroflowToRead{Microflow: …}` — `odata_write.go:359-371` |

`odataChangeModeToGen` does the same for Insert/Update/Delete, and both also accept
a `CallMicroflow:<qn>` prefix.

But `mxcli syntax odata publish` documents only:

```
ReadMode: source,
InsertMode: source | not_supported,
```

so the feature is invisible. The `database-connections.md` and `odata-data-sharing.md`
skills likewise present "publish persistent entities" as the only shape, which is what
sent me down the materialise-into-Postgres path in the first place.

**Fix:** add to the syntax registry and the skills —
`ReadMode: microflow Module.Read_X` (and the Insert/Update/Delete equivalents), with
a note that non-persistable published entities *require* it.

### 10.3 Gap: `Countable` is hardcoded `true`, forcing a `System.ODataResponse` parameter

```
ERROR …: The published entity is marked as Countable, but the read microflow does not
have a parameter of type System.ODataResponse. This entity has a Count attribute which
should be used to return the count of the result set.
```

```go
// mdl/backend/modelsdk/odata_write.go:290-294
qo := newElem("ODataPublish$QueryOptions", "")
addBool(qo, "Countable", true)      // hardcoded
addBool(qo, "SkipSupported", true)  // hardcoded
addBool(qo, "TopSupported", true)   // hardcoded
addPart(g, "QueryOptions", qo)
```

There is no MDL to turn any of the three off, so **every** read-microflow-backed
resource is forced to declare `$Response: System.ODataResponse` and compute a count
it may not want to compute. For a resource over a 27533-row CSV scan, "cheap count"
is not a given.

**Fix:** expose them as publish-entity properties — `Countable: No`,
`SkipSupported: No`, `TopSupported: No` — defaulting to today's `true` so nothing
changes for existing scripts. They belong next to `UsePaging`/`PageSize` on
`PublishedEntityDef`.

### 10.4 Gap: the `PublishAssociations` default makes non-persistable resources unbuildable

```
ERROR …: Attribute ID for entity 'ProbeOData.Row' must be published and be the key
when associations are exposed as an associated object id.
```

This fires even with **no associations exposed at all**. `PublishAssociations`
defaults to `false`, which Mendix reads as "expose associations as associated object
id" — and that mode demands the system `ID` attribute be published as the key. For a
non-persistable entity that is flatly illegal; the same texts file says
`"Publishing object ID for entity '{ENTITY}' is not allowed, because the entity is
non-persistable."` So the default is a dead end from which there is no escape inside
`CREATE ODATA SERVICE`.

`alter odata service … set PublishAssociations = true` fixes it (build goes green
immediately), but:

- it needs a **second statement** — `PublishAssociations` is accepted by
  `alterODataService` (`cmd_odata.go:1427`) but the create path only reads it from
  `stmt.PublishAssociations`, which the `CREATE` grammar has no property for. So a
  one-shot MDL script cannot express it.
- the name is misleading. It is a two-value mode (`links` vs `associated object id`),
  not "publish associations yes/no", and `true` is what you want even when you publish
  none.

**Fix:** accept `PublishAssociations` as a `CREATE ODATA SERVICE` property, and
consider defaulting it to `true` (links) — or at minimum special-case it when every
published entity is non-persistable, where `false` can never build.

### 10.5 Roundtrip: `DESCRIBE` emits a form it cannot parse

```
> describe odata service ProbeOData.ProbeApi;
publish entity ProbeOData.Row as 'Row' (
  ReadMode: CallMicroflow:ProbeOData.Read_Rows,
  …
```

Three problems in four lines:

1. `ReadMode: CallMicroflow:ProbeOData.Read_Rows` is **not valid MDL input** — a bare
   `CallMicroflow:Qualified.Name` matches no `odataPropertyValue` alternative. DESCRIBE
   should emit `ReadMode: microflow ProbeOData.Read_Rows`, the form the user wrote.
2. `as 'Row'` — but the MDL said `as 'Rows'` and the served `$metadata` really does say
   `Name="Rows"`. DESCRIBE is printing the *entity type* exposed name where the
   *entity set* exposed name belongs, so a describe→re-exec cycle silently renames the
   entity set.
3. `UsePaging` and `PageSize` are omitted entirely.

That breaks the DESCRIBE-roundtrip property the project's own review checklist calls
for.

### 10.6 Consequence for this repo

The pure architecture is back on the table and is what the brief actually asked for:

```
data/f1db/*.csv → DuckDB (BYOD JDBC, read_csv at query time)
                → Database Connector query → non-persistable entity
                → read microflow → published OData v4
                → frontend OData client + external entities
```

No copy into Postgres, no refresh job. The cost is four workarounds (`ServiceName:`
explicitly, `ReadMode: microflow …`, a `System.ODataResponse` parameter on every read
microflow, and a follow-up `alter … set PublishAssociations = true`), all of which are
one-liners once known, and all of which are recorded above so the next session does not
rediscover them.

Still unproven: a Database Connector query with `type 'BYOD'` executing against DuckDB
from **inside the Mendix runtime**. §7 proved the JDBC layer standalone; §10 proved the
OData layer with a stub microflow. The join between them — a read microflow whose body
is `execute database query` — has not been run yet.

---

## Suggested mxcli issues, in the order I would file them

1. **`CREATE ODATA SERVICE` leaves `ServiceName` empty → every published service fails
   `mxbuild`** (§10.1). One-line fix, affects everyone, currently invisible because
   `mxcli check` passes. Highest impact.
2. **Add `Countable` / `SkipSupported` / `TopSupported` to `publish entity`** (§10.3) —
   they are hardcoded `true` in the BSON writer with no way to override.
3. **Accept `PublishAssociations` on `CREATE`, and reconsider the default** (§10.4) —
   today a non-persistable resource cannot be made buildable in a single script.
4. **Document `ReadMode: microflow …`** in `mxcli syntax odata publish` and the
   `odata-data-sharing` / `database-connections` skills (§10.2) — the feature exists
   and is unreachable by anyone who does not read the Go source.
5. **Fix the published-OData DESCRIBE roundtrip** (§10.5) — emit `microflow X`, use the
   entity-set exposed name, include paging.
6. **Correct the database type table in `database-connections.md`** (§6) — drop
   `Redshift`, add `BYOD` ("Other"), which is the only way to use a JDBC driver Mendix
   does not ship a picker entry for.
7. **`mxcli init` from a solution root silently initialises one app** (§3) — refuse, or
   name the chosen project first.
8. **Warn on unknown `publish entity` properties.** `parsePublishEntityBlock`
   (`visitor_odata.go:344-359`) has a `switch` with no `default`, so a typo like
   `ReadMicroflow:` or `Pagesize:` is silently discarded. The service-level path already
   does this right — `alterODataService` returns
   `"unknown OData service property: %s"`. Applying the same rule at entity level would
   have saved most of an afternoon here.

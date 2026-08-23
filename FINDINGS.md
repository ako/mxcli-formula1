# Findings

Durable notes for the next session, and feedback worth sending back upstream to
mxcli. Append, do not rewrite.

**Versions in play**

| | |
|---|---|
| mxcli | built from source, `ako/mxcli` main. §1–§10 on `9236202`; §11–§13 on `1bdd46a`; §14–§33 on `45ae6a6`; §34 on `c76d4b7`; §41–§46 on `b4a825e`; §47–§49 on `715bac5`; §50–§51 on `38a1137`; §52–§53 on PR 125 head `9ab9afa`; §54 on `a8dc083`; §55 on `d53691b` (devcontainer, arm64); §56 on `a8dc083`; §57 on **PR 202 head `e50ddac`** against `48114de` |
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
  `mdl/backend/modelsdk/db_write.go`. So `type 'BYOD'` will be written happily.
  ~~Whether the *runtime* accepts it is still unproven here.~~ **§11 proved it does:**
  a booted Mendix 11.13 runtime opened `jdbc:duckdb:` through a `type 'BYOD'`
  connection and returned real rows.

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

*(Trimmed as items were closed. §10 proved the OData half; §11 proved the DuckDB
half. Almost nothing is left.)*

- **Closed (§10):** `mxbuild` has been run against `Formula1Backend` — green, after
  the §10 workarounds.
- **Closed (§11):** `type 'BYOD'` is accepted by the runtime, the driver is found in
  `userlib/`, and real CSV rows come back through `execute database query`.
- **Still open:** the two halves have not been joined *in one flow* — a published
  OData read microflow whose body is `execute database query`. §10 used a stub
  returning an empty list; §11 called the DuckDB microflow directly from a test.
  Both ends work; the seam between them is the one untested inch.
- **Still open:** connection-pool behaviour against an in-memory DuckDB under
  concurrent load. §11's timings are single-threaded. Each pooled connection gets
  its own empty in-memory database, which is fine when every query inlines
  `read_csv()`, but would break anything relying on session state (temp tables,
  `CREATE VIEW`, `SET`).

Both apps are otherwise still the blank template plus theme and
`ApplicationRootUrl` — the probe modules from §10 and §11 were dropped and the
`.mpr` restored each time.

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

## 11. The DuckDB read path works from inside the Mendix runtime — and `test --attach` makes it a 2-second loop

*Verified 2026-08-07 on mxcli `1bdd46a` (rebuilt from `ako/mxcli` main) / Mendix
11.13.0, against the real 47-file dataset. Reproducible: `spikes/duckdb-readpath/`.*

This closes the biggest open item. A Mendix microflow, using the External Database
Connector with `type 'BYOD'` and connection string `jdbc:duckdb:`, calling
`read_csv()` on `data/f1db/`, returns real rows inside a booted runtime:

```
PASS  Ayrton Senna has 41 race wins           (29ms)
PASS  Lewis Hamilton has 106 race wins        (29ms)
PASS  An unknown driver id yields -1          (27ms)
PASS  The drivers CSV has 917 rows            (60ms)
```

Nothing is copied into Postgres. `BYOD` is accepted by the runtime, not just the
editor — §6's caveat ("whether the runtime accepts it is still unproven") is
resolved.

Two MDL details cost time and are worth writing down:

- `execute database query … dynamic '<sql>'` overrides the SQL at runtime but
  **still requires values for every declared parameter**, even ones the override
  does not use. `CountAllDrivers` passes `driverId = 'unused'`.
- `read_csv({dataDir} || '/f1db-drivers.csv')` — the `{param}` placeholder
  concatenated into the path — works through the connector exactly as it did in
  the standalone JDBC harness in §7. One constant, no absolute path in the model.

### The new test runner is the story

`mxcli test --local` used to boot the app once per invocation. `--watch` (#108) and
`--attach` (#109) change the economics completely. Measured here, same 4 tests:

| Mode | Wall clock |
|---|---|
| `test --local`, cold boot each run | **33.7 s** |
| `test --attach` against a warm `run --local --test-endpoint` | **2.2 s** (3.2 s first, then 2.1–2.5 s) |
| edit the microflow under test → verdict, via `--attach` | **2.0 s** |

That matches the commit message's claim of ~2 s. It is the difference between
"run the suite when you remember to" and "run it on every edit".

Two design choices that proved themselves in use:

- **Per-test microflows.** The first run of §11 failed all four tests with
  `exception during execution` — and reported four separate failures with
  individual timings, rather than dying on the first. The old after-startup runner
  would have given one log to grep.
- **Ownership on attach is strict, and it holds.** After an attach run,
  `show modules` showed `MxTest` still present with exactly its host-owned
  `RegisterEndpoint` microflow + Java action; the four `Test_*` microflows were
  gone. On `Ctrl-C` of the host, the log said `test endpoint removed; project
  restored`, `MxTest` disappeared, and `.mxcli/test-endpoint.json` was deleted. The
  probe module I created myself was the only thing left, which is correct.

The failure mode to know: `--attach` runs against the **host app's own database**,
not a scratch one. §11's tests are pure reads so it does not matter, but a test that
commits will leave rows in the app you are looking at.

## 12. Gap: a module JAR dependency never reaches the generated Gradle build

*Verified 2026-08-07 on mxcli `1bdd46a` / Mendix 11.13.0.*

This is why §11's first run failed. The documented way to add a JDBC driver is a
module JAR dependency, and mxcli writes it correctly:

```sql
ALTER MODULE DuckProbe ADD JAR DEPENDENCY (
  group = 'org.duckdb', artifact = 'duckdb_jdbc', version = '1.5.5.1', included = true,
);
```

```
> list jar dependencies in DuckProbe;
DuckProbe  org.duckdb  duckdb_jdbc  1.5.5.1  yes
```

The model has it. The build does not:

```
ERROR - ExternalDatabaseConnector: No JDBC drivers found, add the appropriate driver JAR to your app via Module Settings
java.sql.SQLException: No JDBC driver found in app for URL: jdbc:duckdb:.
```

`deployment/build.gradle` contains no `dependencies` block mentioning duckdb, and
`find deployment -iname '*duckdb*'` returns nothing. Dropping the same jar into
`Formula1Backend/userlib/` made all four tests pass on the next run with no other
change — so the driver and the connector were always fine; only dependency
*resolution* was missing.

Unresolved: whether `mxbuild --serve` simply skips Maven resolution (a full
`mxbuild` might do it), or whether mxcli writes the dependency somewhere MxBuild
does not read. Worth pinning down, because the failure is silent at model level —
`list jar dependencies` happily reports a dependency that will not be on the
classpath, and the only symptom is a runtime `SQLException` much later.

**Workaround in this repo:** `scripts/fetch-duckdb-driver.sh` puts the jar in
`userlib/` and the SessionStart hook runs it. The jar is git-ignored (82 MB).

## 13. MDL papercuts hit while writing the spike

Small, all verified 2026-08-07 on `1bdd46a`:

- **A bare literal assignment does not parse.** `$N = 0;` and `$N = -1;` both give
  `no viable alternative at input '$N=0'`. `DECLARE $N Integer = 0;` is the working
  form, and `$X = HEAD($List)` / `$X = execute database query …` still work bare, so
  the inconsistency is easy to trip over. The error names the token, not the
  missing `DECLARE`.
- **`mxcli lint` caught a real mistake with a genuinely good message**, worth
  crediting rather than just complaining:
  ```
  ✗ declare '$Total' calls 'count()', which is not a Mendix expression function —
    the build fails CE0117 "Error(s) in expression"  [MDL044]
    → 'count' is an aggregate activity, not an expression function. Assign it to a
      variable first: $n = count($List); then use $n in the expression.
  ```
  This is the standard other MDL errors should be held to.
- **`mxcli test tests/` resolves the path relative to the process CWD, not to `-p`.**
  Expected, but combined with `mxcli`'s project auto-discovery — which *does* search
  upward and sideways (§3) — it is easy to get a "no such file or directory" for a
  directory that exists next to the `.mpr`.

## 14. Every finding above was fixed upstream — re-verified on `45ae6a6`

*Verified 2026-08-07 by re-running each original reproduction against a fresh build
of `ako/mxcli` main @ `45ae6a6`. Not read from commit messages — every row below was
executed.*

| # | Finding | Fix | Verified how |
|---|---|---|---|
| §1 | ANTLR version not pinned where the failure happens | `68d235f` | — |
| §2 | `mxcli new` help said "downloads" when it links | `8e7bfcc` | `new --help` now reads *"6. Links this mxcli into the project (or downloads a Linux build on macOS/Windows)"* |
| §3 | `init` from a solution root silently picks one app | `83e85c2` | Now **refuses**, lists both `.mpr` paths, and prints `mxcli init /…/Formula1Backend`. An empty dir warns that paths are placeholders. |
| §6 | Wrong database-type table; `BYOD` undocumented | `1fb51d7` + skill | `check` on `type 'Redshift'` warns `MDL-DB01` and names the six real values, calling out `BYOD` for unknown drivers. `type 'BYOD'` is clean. |
| §8 | `describe settings configuration '…'` was a parse error | `f0d9e38` | Parses, and `show settings configurations` now carries `url=http://backend.local:8080/` (the empty-`DatabaseUrl` `, ,` is gone too) |
| §10.1 | `ServiceName` empty → every published service fails `mxbuild` | `d9cadfa` | See below |
| §10.2 | `ReadMode: microflow …` undocumented | `305a9fa` | `syntax odata publish` documents all four modes, `ServiceName`, and the query options |
| §10.3 | `Countable`/`Skip`/`Top` hardcoded `true` | `fa0cdb6` | All three accepted as publish-entity properties |
| §10.4 | `PublishAssociations` default unbuildable, `CREATE`-inaccessible | `d9cadfa` | See below |
| §10.5 | DESCRIBE emitted unparseable MDL and the wrong exposed name | `04aadde` | Round-tripped: DESCRIBE → `check` → passes |
| §12 | Declared JAR dependency never resolved | `38484ea` | See below |
| §13a | `$Total = 5;` did not parse | `e0744b9` | `$N = 0; $N = -1; $N = $N + 5;` all parse |
| §13b | Test path not resolved relative to the project | `d70c3e5` | Works for execution; **not** for `--list` (see §15) |
| §9 | Unknown publish-entity properties silently dropped | `6b5db79` | `ReadMicroflow:` now errors `MDL-ODATA01` and lists the known names |

### §10 end to end: the workarounds are gone

The §10 probe re-run with **no** `ServiceName`, **no** `alter … set PublishAssociations`,
and a read microflow taking **no parameters at all** (possible because `Countable: No`
now exists):

```sql
create odata service ProbeOData.ProbeApi (
  path: 'odata/probe/', version: '1.0.0', ODataVersion: OData4,
  namespace: 'ProbeOData.Probe'
) authentication basic {
  publish entity ProbeOData.Row as 'Rows' (
    ReadMode: microflow ProbeOData.Read_Rows,
    InsertMode: not_supported, UpdateMode: not_supported, DeleteMode: not_supported,
    Countable: No
  ) expose ( RowKey as 'rowKey' (KEY, Filterable, Sortable), Label (Filterable, Sortable) );
};
```

→ **BUILD SUCCEEDED.** Three workarounds retired by one script.

`DESCRIBE` now emits the defaults it filled in (`ServiceName: 'ProbeApi'`,
`PublishAssociations: Yes`), `ReadMode: microflow ProbeOData.Read_Rows` rather than
`CallMicroflow:…`, the correct entity-set name `as 'Rows'`, `Countable: No`, and `KEY`
rather than `IsPartOfKey`. Piped back through `check`: passes.

### §12: the answer was a third thing

My open question was "does `mxbuild --serve` skip Maven resolution, or does mxcli write
the dependency somewhere MxBuild cannot read?" Neither — **declaring and resolving are
separate steps**, and the Mendix toolset has always had `mx sync-java-dependencies`
for the second one. Studio Pro runs it when you edit Module Settings; nothing headless
was.

mxcli now wires it at three levels: a new `mxcli sync-java-deps [--check]` command, a
warning from the executor the moment an unvendored coordinate is written, and
resolution inside `run --local` before boot — which is what the log shows:

```
Resolving 1 managed Java dependency/dependencies (org.duckdb:duckdb_jdbc:1.5.5.1)...
```

Verified the hard way: **deleted the jar from `userlib/` entirely**, left only the
`ALTER MODULE … ADD JAR DEPENDENCY` declaration, and re-ran the §11 suite:

```
PASS  Ayrton Senna has 41 race wins        (704ms)
PASS  Lewis Hamilton has 106 race wins      (56ms)
PASS  An unknown driver id yields -1        (91ms)
PASS  The drivers CSV has 917 rows         (152ms)
```

with `userlib/` empty and the jar landing at
`deployment/model/lib/userlib/duckdb_jdbc-1.5.5.1.jar`. This repo's
`scripts/fetch-duckdb-driver.sh` workaround has been **deleted** as a result.

## 15. Two residuals from the fixes, and one operational gotcha

*Verified 2026-08-07 on `45ae6a6`. All minor; recorded so they are not rediscovered.*

- **`mxcli test --list` still does not resolve a project-relative path.** `d70c3e5`
  added `resolveTestPaths` and wired it into `RunOptions.TestFiles`, but the `--list`
  branch returns earlier and calls `testrunner.ListTests(args, …)` with the raw args
  (`cmd/mxcli/cmd_test_run.go:136`). So execution works from the solution root and
  listing does not:
  ```
  $ mxcli test tests/ -p Formula1Backend/Formula1Backend.mpr --attach   # 4 passed
  $ mxcli test tests/ -p Formula1Backend/Formula1Backend.mpr --list
  Error: stat tests/: stat tests/: no such file or directory
  ```
  One line: move the `resolveTestPaths` call above the `if list` branch.

- **`MDL-ODATA01`'s hint omits the properties `fa0cdb6` added.** The message says
  *"Known properties here: ReadMode, InsertMode, UpdateMode, DeleteMode, UsePaging,
  PageSize"* — no `Countable`, `SkipSupported` or `TopSupported`, though all three are
  accepted. The two lists want a single source.

- **`.ai-context/skills/` does not follow an mxcli upgrade.** The skills are copied
  into each app at `mxcli init` time, so after upgrading the binary this project was
  still reading the *old* `database-connections.md` — the one with the wrong type
  table that caused §6 in the first place. Re-running `mxcli init --tool claude` in
  each app folder refreshed 63 skill files (694 insertions). Worth knowing that
  upgrading mxcli is two steps, and worth mxcli either versioning the copied skills
  or noticing they are stale.

## 16. Gap: a published `Integer` attribute is written as `Edm.Int32`, but Mendix wants `Edm.Int64`

*Verified 2026-08-07 on mxcli `45ae6a6` / Mendix 11.13.0, building the real model.*

Every whole-number attribute published in either OData service failed the build:

```
ERROR at …, Published attribute Year from entity Formula1Backend.Stg_Season:
Attribute Formula1Backend.Stg_Season.Year is has type Integer, but is published
as Edm.Int32. Either change the attribute type or right-click this error to
update the published type in the metadata.
```

Fourteen of these on the first build, one per Integer attribute. The mapping is
in `mendixAttrTypeToEdm` (`mdl/executor/cmd_odata.go:1625`):

```go
case "String", "HashedString": return "Edm.String"
case "Integer":                return "Edm.Int32"      // <- Mendix publishes Int64
case "Long", "AutoNumber":     return "Edm.Int64"
```

and the function's own doc comment says exactly where the bug came from:

> String/Decimal/Boolean/DateTimeOffset **verified against Studio Pro output; the
> rest follow the standard OData mapping.**

Integer was an unverified guess. Mendix publishes both `Integer` and `Long` as
`Edm.Int64` — confirmed by switching every attribute to `long`, after which the
served `$metadata` reads `<Property Name="year" Type="Edm.Int64"/>` and the build
is green.

**Fix:** `case "Integer", "Long", "AutoNumber": return "Edm.Int64"`. Worth
re-verifying `Binary` and `Enumeration` against Studio Pro at the same time —
they carry the same unverified caveat.

**Workaround here:** every whole number in the model is `long`. Harmless (both are
Int64 over the wire) but it should not be necessary, and the error message is
confusing — it reads as if the *attribute* is wrong when the published type is.

## 17. A published key needs a unique validation rule — but only on persistable entities

*Verified 2026-08-07.*

```
ERROR …: Add a unique validation rule to attribute 'Year' of entity
'Formula1Backend.Season' to be able to use it as the key.
```

Eight of these, one per cached-service resource. `KEY` in the `expose` clause is
not enough: the attribute must also carry `unique` in the entity definition.

The interesting part is the asymmetry. The **live** service publishes the same
keys on the same attribute names, and needed nothing — non-persistable entities
have no unique-validation requirement (they have no database to enforce it in).
So the identical `expose (Year as 'year' (KEY, …))` is fine on `Stg_Season` and a
build error on `Season`.

Not an mxcli bug, but a sharp edge worth a lint rule: `mxcli check` could see
`KEY` on a persistable attribute with no unique validation and say so, rather than
leaving it to `mxbuild`.

## 18. The dataset itself: constructor standings are not unique per (year, constructor)

*Verified 2026-08-07 against f1db, by DuckDB query.*

The refresh failed on a uniqueness violation that looked like a modelling mistake
and was actually a fact about Formula 1:

```
year  constructorId  n
1966  brabham        3
1960  cooper         3
2018  force-india    2
```

f1db records one constructor-standings row per constructor **and engine**. Brabham
scored in 1966 with Repco (42 points, 1st), BRM (1 point) and Climax (1 point) —
three legitimate rows. Force India appears twice in 2018 on the *same* Mercedes
engine, so even `(year, constructorId, engineManufacturerId)` is not unique.

`(year, positionDisplayOrder)` is unique, and that is what the synthetic key uses.
`engineManufacturer` is now exposed on both services, because it is the thing that
explains the duplication to anyone looking at the data.

Driver standings, race results and races are all unique on the obvious key —
checked, not assumed.

## 19. `mxcli test --local` displaces the app's After-startup microflow

*Verified 2026-08-07.*

The test runner prints this on every `--local` run, and it is easy to read past:

```
After-startup set to MxTest.RegisterEndpoint (registers the endpoint; runs no tests)
```

It is doing the right thing — it needs the endpoint registered at boot and it
restores the setting afterwards. But it means **whatever your app does at startup
does not happen during a `--local` test run.** Here, `ASU_LoadCacheIfEmpty` fills
the cached service from the CSVs on first boot, so under `--local` the scratch
`formula1backend_test` database stays empty and every cached-service assertion
fails against zero rows.

Nothing is broken; the tests were asking for state the runner had deliberately
prevented. The split is now explicit:

| File | How to run | Why |
|---|---|---|
| `tests/live.test.mdl` | `--local` | needs only the CSVs |
| `tests/cached.test.mdl` | `--attach` | needs a loaded cache, which is the running app's state |

**Suggestion:** say so in the output — "After-startup set to … (your own
after-startup microflow will not run)" — or offer to chain the original one after
the endpoint registration. As it stands the failure mode is a suite that passes
under `--attach` and fails under `--local` for reasons unrelated to the code.

## 20. Mendix applies no query options to a read-microflow resource — the microflow owns all of them

*Verified 2026-08-07 on Mendix 11.13.0, by logging `System.HttpRequest.Uri` and
comparing responses.*

For a published resource backed by a read microflow, Mendix hands the request to
the microflow and returns exactly what comes back. It applies **nothing**:

```
GET /odata/f1-live/Drivers?$top=5                 -> 917 rows
GET /odata/f1-live/Drivers?$orderby=raceWins desc -> 917 rows, still alphabetical
GET /odata/f1-live/Drivers?$skip=80&$top=5        -> 917 rows
```

This is easy to get wrong in the optimistic direction, because the metadata
advertises the opposite — the entity set carries
`Org.OData.Capabilities.V1.TopSupported = true` and `SkipSupported = true`, so a
client believes paging works. It does, but only if the microflow implements it.

The full query string does arrive, URL-encoded, on `System.HttpRequest.Uri`:

```
F1Probe: URI=/odata/f1-live/Drivers?$orderby=raceWins%20desc&$top=3
```

so everything needed is there. `System.ODataResponse.Count` is the other half —
set it and `$count=true` reports the size of the filtered set rather than the
page.

Two related behaviours worth knowing, both good:

- **Mendix validates field names before the microflow runs.** `$filter=secretColumn eq 'x'`
  returns `400 Could not map 'secretColumn' to attribute or association`, and
  `$orderby=name;DROP TABLE x--` returns `400 Server cannot process the given uri`.
  So the microflow only ever sees names that exist in the published metadata.
  That is defence in depth, not a substitute for a whitelist — it constrains the
  *name*, not what you then do with it.
- `Countable: Yes` is required for the microflow to take `System.ODataResponse`,
  and forbidden without it. The two are checked in both directions.

## 21. Gap: `execute database query … dynamic $Variable` is written as the literal string

*Verified 2026-08-07 on mxcli `45ae6a6`. This one blocks runtime-built SQL entirely.*

The grammar allows an expression:

```antlr
executeDatabaseQueryStatement
    : … (DYNAMIC (STRING_LITERAL | DOLLAR_STRING | expression))? …
```

and the visitor captures it (`visitor_microflow_actions.go:576`,
`stmt.DynamicQuery = expr.GetText()`). But the builder then quotes anything that
does not already begin with a quote:

```go
// mdl/executor/cmd_microflows_builder_calls.go:1349
dynamicQuery := s.DynamicQuery
if dynamicQuery != "" && !strings.HasPrefix(dynamicQuery, "'") {
    dynamicQuery = "'" + strings.ReplaceAll(dynamicQuery, "'", "''") + "'"
}
```

So `dynamic $Sql` reaches the runtime as the string literal `'$Sql'`, and DuckDB
is asked to execute:

```
ERROR - ExternalDatabaseConnector: Parser Error: syntax error at or near "$"
LINE 1: $Sql
```

There is no discriminator on the AST — `DynamicQuery` is one string whether it
came from `STRING_LITERAL` or from `expression` — so the builder cannot tell a
literal from an expression. **Fix:** add `DynamicQueryIsExpression bool` to
`ast.ExecuteDatabaseQueryStmt`, set it in the `expr` branch of the visitor, and
skip the quoting when it is set.

**Workaround, and it is a good one to know:** write `dynamic '' + $Sql`. The
expression text then starts with a quote, so the builder leaves it alone, and
Mendix evaluates `'' + $Sql` to the string. Verified end to end — a microflow
building `… LIMIT ' + toString($Limit)` returns exactly that many rows.

## 22. Query pushdown, built and measured

*Verified 2026-08-07 against the running app.*

With §20 and §21 understood, the live service can do what a datagrid over an
external entity actually needs. `Read_Drivers` and `Read_RaceResults` now
translate `$skip` / `$top` / `$orderby` / `$filter` / `$count` into DuckDB SQL
(`model/backend/09-query-pushdown.mdl`, `10-live-pushdown.mdl`, and
`javasource/formula1backend/ODataQuery.java`).

The case from the request — a grid showing rows 80-100 sorted by driver name:

| | before pushdown | after |
|---|---|---|
| rows returned | 917 | **20** |
| bytes | 293422 | **6621** |
| `@odata.count` | not supported | **917** |
| order | ignored | applied in SQL |

And the resource that could not exist before: `RaceResults` on the live service
now serves all 27533 rows a page at a time — 20 rows in 7.6 KB with
`@odata.count: 27533`, straight from the CSVs with nothing materialised. Before,
the live service could only offer `LatestRaceResults` bounded to one season.

Both services now return **41** for Senna's race wins — one counting rows in
Postgres, the other scanning a 4 MB CSV per request.

**Injection.** `$orderby` and `$filter` name columns chosen by the caller and
those names end up in SQL, so every one is resolved through a whitelist the
caller passes (`exposedName:sqlExpression,…`). A name that is not in the map is
ignored in `$orderby` (a wrong sort is cosmetic) and **rejected** in `$filter` —
silently dropping a filter would hand back more rows than the client asked for,
which looks like data rather than an error.

Two bugs the unit tests caught that HTTP testing could not, because Mendix
pre-validates field names (§20):

- A naive `startsWith("'") && endsWith("'")` literal check accepted
  `name eq 'a' or name eq 'b'` as a single quoted value and emitted SQL with an
  OR this translator does not implement. Now a strict literal parser requires
  the closing quote to be the last character.
- OData escapes an inner quote by doubling it, so `'O''Brien'` is `O'Brien`.
  Stripping the outer quotes without un-doubling produced `O''Brien` and then
  re-escaped it to `O''''Brien`.

Both are in `tests/pushdown.test.mdl`, which runs under `--local` in about a
second.

## 23. Gap: `CREATE ODATA CLIENT` fetches `$metadata` without credentials

*Verified 2026-08-07 on mxcli `45ae6a6`.*

The statement accepts `UseAuthentication` / `HttpUsername` / `HttpPassword` — they
are parsed at `cmd_odata.go:1205-1218` and stored on the HTTP configuration for
the runtime. The design-time fetch ignores them:

```go
// mdl/executor/cmd_odata.go:1820, fetchODataMetadata
client := &http.Client{Timeout: 30 * time.Second}
resp, err := client.Get(metadataUrl)
```

No `SetBasicAuth`, no headers. Against a service with `authentication basic` the
result is:

```
Warning: could not fetch $metadata: $metadata fetch returned HTTP 401
Created OData client: F1Live.LiveApi
```

The client is created but unvalidated, with **no entity types cached**, so the
`CREATE EXTERNAL ENTITIES FROM …` that follows has nothing to import. It is a
warning rather than an error, so a script appears to succeed and produces an
empty module.

**Fix:** use the credentials already on the statement for the metadata fetch, and
send the `HEADERS (...)` too. Consider making an unreachable `MetadataUrl` an
error when the next statement depends on it.

**Workaround, and it turns out to be a better practice anyway:** `MetadataUrl`
accepts a file path as well as a URL. Fetch the contract once with credentials
and point the client at the file:

```bash
curl -u f1api:<pw> 'http://backend.local:8080/odata/f1-live/$metadata' \
  -o contracts/f1-live-metadata.xml
```
```sql
MetadataUrl: './contracts/f1-live-metadata.xml',
```

The contracts are committed, so the frontend model rebuilds without the backend
running, and a contract change shows up as a reviewable diff instead of silently
altering the generated entities.

## 24. Gap: generated external entities ignore the capabilities in the `$metadata`

*Verified 2026-08-07.*

`CREATE EXTERNAL ENTITIES FROM …` reads names, types and navigation properties
out of the contract correctly, then defaults **every capability to true**
regardless of what the contract says. Mendix compares the two at build time and
refuses:

```
ERROR at F1Live, Domain model, Entity 'F1Live.Seasons':
  'Seasons' is marked Countable=False in the OData service, but True in the app.
ERROR at F1Live, Domain model, Attribute 'F1Live.Circuits.latitude':
  'latitude' is marked Filterable=False in the OData service, but True in the app.
```

Eight errors from an eight-resource import. The whole point of generating from
`$metadata` is fidelity to the contract, and `Countable` / `Filterable` /
`Sortable` are in the document right there:

```xml
<Annotation Term="Org.OData.Capabilities.V1.CountRestrictions">
  <Record><PropertyValue Bool="false" Property="Countable"/></Record>
</Annotation>
```

**Fix:** read the capability annotations during import.

## 25. Gap: `CREATE OR MODIFY EXTERNAL ENTITY` corrupts the attributes it does not mention

*Verified 2026-08-07. Found while working around §24, and it is the more serious
of the two.*

The AST comments say scalar fields are pointers specifically so an omitted
property is preserved rather than zeroed — "Treating omitted fields as zero on
modify silently corrupted entities — see issue #594". Attributes are not
protected the same way. Modifying only the entity-level `Countable`:

```sql
create or modify external entity F1Live.Circuits
  from odata client F1Live.LiveApi
  (EntitySet: 'Circuits', RemoteName: 'Stg_Circuit', Countable: false);
```

leaves the attribute *count* intact but breaks the attributes themselves:

```
> describe entity F1Live.Circuits;
create or modify external entity F1Live.Circuits (
  circuitId: String(60),
  Stg_Circuitname: String(120),   <-- was `name`
  ...
```

`name` became `Stg_Circuitname` — the remote entity name prefixed onto it — and
every attribute lost its remote mapping, so the build fails with
`Attribute 'year' of external entity 'Stg_Season' is not supported.` on all of
them. The `from odata client` / `EntitySet` / `RemoteName` detail is missing from
the DESCRIBE output afterwards too.

Same class of bug as #594, one level down. **Fix:** when no attribute list is
given, leave the existing attributes and their remote mappings alone.

**What to do instead:** do not patch generated external entities. Make the
published contract say the right thing and regenerate. Here that meant giving
every live read microflow a `System.ODataResponse` and a count so all eight
resources are genuinely `Countable`, which removed the mismatch at the source.

## 26. `create or modify odata service` keeps stale published members and drops role grants

*Verified 2026-08-07, three separate times before the pattern was obvious.*

Re-running a `create or modify odata service` after editing a `publish entity`
block does **not** apply the change. Marking `latitude` as `Filterable` and
re-executing left the served `$metadata` unchanged; only
`drop odata service` + create picked it up. The same is true of `Countable`.

It also silently clears `AllowedModuleRoles`, so the next build fails with:

```
At least one allowed role must be selected for the published OData service to be accessible.
```

**Working recipe** for changing a published service:

```sql
drop odata service Module.Service;
-- re-execute the create script
grant access on odata service Module.Service to Module.Role;
```

**Fix:** either apply entity-set and member changes on modify, or refuse the
modify with a message saying a drop is required. Preserving the role grants
across a modify seems unambiguously right.

## 27. The frontend consumes both services

*Verified 2026-08-07 end to end: build green, and four retrieval tests passing
against the running backend.*

```
PASS  Live client retrieves all 917 drivers straight from the CSVs (1.799s)
PASS  Cached client retrieves all 917 drivers from Postgres (452ms)
PASS  Live client: Senna has 41 race wins (637ms)
PASS  Cached client: Senna has 41 race wins (416ms)
```

Two clients, two modules — `F1Live` and `F1Cached` — because both services
publish identically named resources and importing them into one module would
collide. 16 external entities. The contrast is visible in the domain model
itself: `F1Cached` carries six navigation associations (`season`, `circuit`,
`driver`, `constructor`) while `F1Live` has none, because its rows are flat and
DuckDB did the joins.

`RETRIEVE $Row FROM F1Live.Drivers WHERE driverId = 'ayrton-senna'` reaches
through the OData client, into the read microflow, into a `read_csv()` scan, and
back — 637 ms, and it returns the same 41 as the Postgres-backed one.

One thing that cost time and is worth repeating from §13: `RETRIEVE … LIMIT 1`
yields a **single object**, not a list, so `HEAD()` on it fails with
`The selected 'Rows' variable must be of type List`. Both spellings are useful;
the difference is invisible in the syntax.

## 28. Gap: `CREATE EXTERNAL ENTITIES FROM` renames an attribute called `name`

*Verified 2026-08-07 on mxcli `45ae6a6`, on a **fresh** generation.*

An attribute literally named `name` comes out of the generator prefixed with the
remote entity type:

| Service | Remote type | Contract says | Generated as |
|---|---|---|---|
| live | `Stg_Driver` | `name` | `Stg_Drivername` |
| live | `Stg_Circuit` | `name` | `Stg_Circuitname` |
| live | `Stg_Constructor` | `name` | `Stg_Constructorname` |
| cached | `Driver` | `name` | `Drivername` |
| cached | `Circuit` | `name` | `Circuitname` |

Presumably `name` collides with something in the generator's model and it
disambiguates by prefixing. Three consequences:

- The local attribute name no longer matches the contract, so a page written
  against the published `$metadata` fails with
  `The selected attribute 'F1Live.Drivers.name' no longer exists.`
- The **same field has a different name in each module** — `Stg_Drivername`
  versus `Drivername` — so two pages over two services cannot share a column
  definition, purely because the remote type names differ.
- The backend's internal entity name (`Stg_Driver`) leaks into the frontend's
  domain model.

**It is only a naming problem — the mapping is intact.** Proven rather than
assumed: `tests/name-mapping.test.mdl` reads the renamed attribute through both
clients and gets `Ayrton Senna` back from each.

This also corrects §25: the mangling is the **generator's**, not
`CREATE OR MODIFY EXTERNAL ENTITY`'s. The modify does its own separate damage
(stripping remote mappings from every attribute), but the rename was already
there from the first generation.

**Fix:** disambiguate only on a real collision, and prefer suffixing or quoting
over prefixing with the remote type. Failing that, say so at generation time
instead of leaving it to be discovered when a page will not build.

## 29. `mxcli lint` validates widget design properties against the widget, not the theme

*Verified 2026-08-07.*

`mxcli check` accepted this after two rounds of correction, and the values it
suggested were genuinely the right ones for the widget:

```
⚠ widget "dgDrivers" (datagrid) sets design property "Striped", which is not defined for this widget type [MDL-WIDGET11]
  → Valid design properties for this widget: Align self, Hide on, Hover style, Row size, Spacing, Style
⚠ design property "Row size" has value "Compact", which is not an allowed value [MDL-WIDGET12]
  → Allowed values (case-sensitive): Small, Large
```

`'Row size': 'Small'` then passed `check` cleanly — and failed the build:

```
ERROR: Design property Row size is not supported by your theme.
ERROR: Design property Hover style is not supported by your theme.
```

The `console` theme does not implement those Atlas design properties. The lint
rule knows the widget's catalogue but not which subset the applied theme
supports, so it can green-light a page that cannot build. Worth teaching the rule
to read the theme's `design-properties.json` — mxcli generates the theme, so it
knows.

## 30. The pages, and proof the grid really pushes down

*Verified 2026-08-08 with a real browser session (`run --screenshot` logs in as a
demo user and captures the rendered page).*

Seven pages on the external entities: Home, Seasons, Drivers ×2 (one per
service), Constructors, Circuits, Race results. Every grid is paged, sortable and
text-filterable, so every interaction is an OData request.

The claim worth proving was that a **datagrid** emits the query options, not just
that curl can. Temporarily logging `System.HttpRequest.Uri` inside
`Read_Drivers`, then loading `/p/drivers-live` in the browser:

```
F1Pushdown: Drivers URI: /odata/f1-live/Drivers?$select=driverId%2Cname%2Cnationality%2C…
                        &$count=true&$top=20&$orderby=driverId%20asc
F1Pushdown: Drivers SQL tail:  ORDER BY id ASC LIMIT 20
```

`$top=20` → `LIMIT 20`; `$orderby=driverId` → `ORDER BY id` via the whitelist
(the exposed name differs from the CSV column); `$count=true` runs the separate
count query. The pager renders **1 to 20 of 917** on the live page and
**1 to 25 of 27533** on race results — the full set, from CSVs, 25 rows at a time.

Two things learned from the log that were not obvious:

- The grid's **default sort is the key**, not the first column — `$orderby=driverId asc`
  even though no column was clicked. Worth having a sensible whitelist entry for
  the key attribute, which is why `driverId:id` is in the map.
- **`$select` is sent and currently ignored.** The grid asked for 8 of the 14
  attributes; the SQL still selects all 14. Harmless but wasteful, and an easy
  next improvement — the whitelist already has everything needed to honour it.

Also worth recording, since it looked like a bug and was not: the `console`
theme renders **light** in these screenshots. It is set to `auto`
(`$mxcli-theme-variant: auto` in `theme/web/main.scss`) and headless Chromium
reports `prefers-color-scheme: light`, so Console's light palette is correct
behaviour. The clipped labels in the collapsed navigation rail are likewise
known and deliberately not fixed in CSS — mxcli's own theme docs say so.

## 31. Tracing a page turn end to end: BCrypt is 60–80% of it, not the data

*Verified 2026-08-08 with `--trace-otlp` into a local OTLP collector
(`tools/observability/`), driving the real datagrid pager in Chromium.
`--metrics` corroborates. Both apps traced with distinct `--trace-service` names.*

Trace context propagates across the app boundary by itself, so one trace covers
browser → frontend → OData → backend → DuckDB. A single page turn on the live
Drivers grid:

```
POST /xas/                                    499 ms   frontend (browser click)
  Retrieve //F1Live.Drivers                   496 ms
    GET /odata/f1-live/Drivers?$top=20…       481 ms   frontend → backend
      GET /* (backend)                        479 ms
        5× SELECT system$user / roles / …       2 ms   @ 11 ms
        ── 315 ms with no spans ──                     @ 15–318 ms
        7× session bookkeeping                  3 ms   @ 318 ms
        Microflow Read_Drivers                149 ms   @ 330 ms
          Java ODataWhereSql                    0.3 ms
          Java ODataOrderLimitSql               0.3 ms
          ExecuteDatabaseQueryAction           77 ms
            SELECT read_csv (the page)         35 ms
          Java ODataWantsCount                  0.3 ms
          ExecuteDatabaseQueryAction           68 ms
            SELECT read_csv count(*)           33 ms
```

### The gap is per-request password hashing

The 315 ms hole sits between the first user lookup and
`UPDATE system$user SET lastlogin` — the shape of a **full login on every
request**. The frontend's OData client uses basic auth and holds no session, and
the model is `Hash: BCrypt`, which is deliberately slow.

Proven rather than inferred, by timing the same endpoint three ways:

| Request | Result | Time |
|---|---|---|
| correct password | 200 | ~350 ms |
| **wrong** password | 401 | ~350 ms |
| no credentials at all | 401 | **~10 ms** |

A wrong password costs the same as a right one — the hash is computed either
way — and skipping credentials skips the cost entirely. That is BCrypt, not
lookup or network.

### Steady-state cost, both services

Cold first load excluded (it is ~1.3–1.4 s, dominated by DuckDB native init):

| Phase | live (DuckDB/CSV) | cached (Postgres) |
|---|---|---|
| whole page turn | ~500 ms | ~370 ms |
| **BCrypt auth** | **303 ms (61%)** | **301 ms (81%)** |
| read microflow | 149 ms | — |
| ⤷ DuckDB `read_csv` ×2 | 68 ms (14%) | — |
| ⤷ connector overhead | 78 ms (16%) | — |
| Postgres queries | — | 3.5 ms (1%) |
| transport, session, client | ~48 ms | ~65 ms |

So the live path really does cost more than the cached one — about 130 ms —
but **both are dominated by authentication**. Optimising the SQL would be
optimising 14% of the request.

§40 is the follow-up: what can be done about it (the three documented options,
and which of them a Mendix OData *client* can actually use), what was done —
`BcryptCost 8`, taking the cached page turn to ~68 ms — and the mxcli gap that
rules out the fix which removes the cost rather than shrinking it.

### Three smaller things the trace showed

- **`$count=true` doubles the CSV work.** The count query scans the file again
  (33 ms) for the same cost as the page query (35 ms). The grid needs the total
  to draw its pager, but on a live resource it is not free — worth caching per
  filter, or dropping `Countable` where a grid can live without a total.
- **The Java actions are free.** Whitelisting, parsing and SQL construction total
  **0.9 ms** across three calls. The safety layer costs nothing.
- **The DuckDB connection is pooled and reused**, so the ~78 ms is per-query
  connector work, not connection setup. `commons_pool2` proves it: `pool2`
  (the external connector) shows **8 borrows from 1 created object** — exactly
  4 page turns × 2 queries, on one connection.

### Notes on the tooling itself

- The console exporter is unusable for timing, exactly as `analyze-runtime.md`
  warns. `--trace-otlp` plus ~90 lines of Python is the whole gap.
- **Metric names are prefixed `mx_runtime_stats_`** — the skill documents
  `connectionbus_selects_total`, the runtime serves
  `mx_runtime_stats_connectionbus_selects_total`. A copy-pasted grep from the
  skill returns nothing.
- Default span filters are on, and they are well chosen: microflow, Java action,
  database-activity and SQL spans all survive, which is enough to attribute every
  millisecond here without the ~10× unfiltered cost.
- **An unlicensed runtime caps concurrent sessions.** Repeated Playwright logins
  that never log out exhaust it, and the failure surfaces as a bare
  "Sign in failed." in the browser — the real message
  (`Maximum number of sessions exceeded! (You are currently using a trial license)`)
  is only in the runtime log. `page_grid.py` logs out at the end.

## 32. Folders: `MOVE` covers most documents, but not Java actions or OData services

*Verified 2026-08-08 against mxcli `45ae6a6`.*

Everything the eleven build scripts created landed at the module root — 41
documents in one flat list. `model/backend/12-folders.mdl` sorts 36 of them into
five folders (`Warehouse`, `Live`, `Cached`, `Health`, `TestSupport`); five
cannot be moved at all.

Three facts make a separate folder script the right shape, rather than a
`folder '…'` clause on each definition:

- **`CREATE OR REPLACE` preserves the folder.** Moving `Count_Live_Seasons` into
  `Health` and then re-running its original definition — no folder clause — left
  it in `Health`. So the layout survives re-running `00`–`11`, and does not have
  to be repeated in every script that touches a document.
- **`MOVE` is idempotent.** Running the same move twice reports
  `Moved … to new location` both times and changes nothing; `mxcli diff`
  afterwards reports `0 new, 0 modified`.
- **`MOVE` is doctype-agnostic where it works**, which matters because only
  microflows have a create-time folder clause. Constants and the database
  connection have none, so a create-time-only approach could not place them.

### What `MOVE … TO FOLDER` accepts

| Accepted | Rejected at parse time |
|---|---|
| `MICROFLOW`, `NANOFLOW`, `PAGE`, `SNIPPET`, `CONSTANT`, `ENUMERATION`, `DATABASE CONNECTION`, `FOLDER` | `JAVA ACTION`, `ODATA SERVICE`, `ODATA CLIENT`, `REST CLIENT`, `JSON STRUCTURE`, `IMPORT MAPPING`, `EXPORT MAPPING`, `LAYOUT`, `IMAGE`, `DOCUMENT` |

The rejection is a grammar error (`no viable alternative at input 'MOVEJAVA'`),
not a runtime one, so `mxcli check` catches it — but the message names the
mangled token rather than saying the doctype is unsupported.

So the three pushdown Java actions and both published OData services stay at the
module root. `CREATE OR MODIFY JAVA ACTION` has no folder clause either (tried
before `RETURNS`, after `EXPOSED AS`, and before `AS $$` — all parse errors), and
neither does `CREATE ODATA SERVICE`. There is no MDL path to placing them.

### Verifying a move needs the `.mpr`

mxcli can move a document but cannot show where a document is. `SHOW STRUCTURE`
lists documents flat, at every depth, with no folder headings; `DESCRIBE
MICROFLOW` round-trips the definition without a folder clause. So there is no way
to confirm from mxcli that a move landed, or to diff an intended layout against
the real one.

The `.mpr` answers directly — folders are units, and `ContainerID` is the parent:

```python
import sqlite3, collections
c = sqlite3.connect("Formula1Backend/Formula1Backend.mpr")
rows = list(c.execute("select UnitID, ContainerID, ContainmentName from Unit"))
docs = collections.Counter(r[1] for r in rows if r[2] == 'Documents')
# module 8cb93ff2: 5 direct documents, 5 folders holding 5/8/10/9/4
```

Before: 41 documents directly under the module. After: 5 (the three Java actions
and the two OData services), plus `Warehouse` 5, `Live` 8, `Cached` 10,
`Health` 9, `TestSupport` 4. Nested folders work too — `TO FOLDER
'Health/Consistency'` created both levels.

The move is model-level only: all 21 backend tests pass against the reorganised
project (`--attach`), and both services still answer — live `@odata.count` 27533
with pushdown intact, cached 917 drivers.

### The three cached tests that fail under `--local` here

Unrelated to folders, but worth recording because it looks alarming: on a fresh
container `formula1backend_test` is empty, so the three tests that assert on
materialised rows fail with 0. The dev database still has its 917 drivers. Run
the suite with `--attach` against a running app (which is faster anyway, §14) or
refresh the test database first.

## 33. Gap: the theme maps Atlas Core, and stops at the widget modules

*Verified 2026-08-08 against mxcli `45ae6a6`, theme `console v1`, variant `auto`,
by reading `deployment/web/theme.compiled.css` — what the browser actually
applies — rather than the source.*

The app is dark and on-palette, and then a few things are not: the pager caption
is missing, row-select checkboxes are Mendix blue, popovers cast light-mode
shadows. All of it has one cause.

### The mechanism

`mxcli theme --help` states the design: a theme is "a palette of `--mxt-*`
tokens … and a shared map wiring those onto **~60 Atlas variables**", and
"**Atlas Core is left untouched**". That is exactly what works — ground,
surfaces, ink, brand, type, cards, buttons and form controls all follow the
palette, in both variants, before first paint.

What the map cannot reach is the theme source shipped *by the widget modules*
under `themesource/`. Those files style things with **Sass** variables and
literals, which are resolved at compile time — before any custom property
exists. No `--mxt-*` value can move them; only a later CSS rule can.

| module | colour declarations with a literal no token can reach |
|---|---|
| `datawidgets` (Data Grid 2) | **23** |
| `atlas_web_content` | 6 |
| `administration` | 0 |
| `atlas_core`'s own SCSS | 492 — but nearly all legacy Bootstrap and `@media print` |

The console theme contains no rule for any of them: `grep -E
"pagination|paging|filter|datagrid"` over `_mxcli-atlas-map.scss` and
`_mxcli-console.scss` returns nothing.

### The one that is a real defect, not a nuance

```css
/* theme.compiled.css */
.pagination-bar { … color: #0a1325; }
```

From `themesource/datawidgets/web/variables.scss:18` —
`$pagination-caption-color: #0a1325 !default`. Against the ground (`#0e1116`)
that measures **1.02:1**; WCAG AA wants 4.5:1. The caption — "1–15 of 77", the
only thing telling you where you are in 27533 rows — is invisible. The pager
*buttons* either side render correctly, because they use
`color: var(--gray-darker, …)` and resolve through Atlas. Same widget, same bar,
two different mechanisms, one of them reachable.

### The full list, from `datawidgets`

| file | what it bakes | shows as |
|---|---|---|
| `variables.scss:18` | `$pagination-caption-color: #0a1325` | invisible pager caption |
| `_datagrid.scss:442` | `background-color: rgba(255,255,255,1)` | white flash on every page turn |
| `_three-state-checkbox.scss` (9 decls) | `#e7e7e9` borders, `#264ae5` checked/indeterminate | stock Mendix blue in a teal app |
| `_datagrid.scss:214,372` | `box-shadow: … rgba(32,43,54,.08)` | light-mode shadow under the column selector |
| `_datagrid-filters.scss:71,143,153,206` | `box-shadow: … rgba(5,15,129,.05)` | same under the filter-operator list |
| `_datagrid-dropdown-filter.scss:267` | `color: #000` | selected tag text lost on a dark chip |
| `_export-alert.scss`, `_export-progress.scss` (6) | white panel, `#264ae5`, `#e33f4e` | not rendered here |
| `_gallery-design-properties.scss:66`, `_tree-node.scss` (3) | `#fff` stripe, `#b6b8be` borders | not rendered here |

### Fixed in this project

`Formula1Frontend/theme/web/_f1-widget-dark.scss`, imported from `main.scss`
**outside** the `mxcli:theme` fence — mxcli guarantees it will not touch lines
outside its own block, so `mxcli theme apply` can still run. It re-points the
first six rows at `--mxt-*` and leaves the last two alone, since this app
renders neither. Every selector was read out of the compiled CSS, not guessed.

Verified in both variants by loading the app's real `theme.compiled.css` into a
probe page: caption `rgb(154,166,180)` dark / `rgb(85,96,110)` light, checked
box `--mxt-brand`, loader `--mxt-surface`, popovers hairline-bordered and
shadowless.

### The header logo, and a way to make a raster follow a palette

`Atlas_Default` renders `Atlas_Core.Layout.logo`, whose first element is
`<rect fill="white">` — a bright tile on a dark ground, and out of CSS's reach
because it is an `<img>`. The replacement is drawn as a **mask** rather than a
coloured image:

```scss
img[src*="Atlas_Core$Layout$logo"] {
  width: 0; height: 0; padding: 16px;      /* collapse the content box */
  background-color: var(--mxt-brand);      /* paint follows the palette */
  mask: url("./f1-logo.svg") center / contain no-repeat;
}
```

Zero-size content box plus padding swaps the image without `content:` on a
replaced element, which is not portable. And because the colour comes from the
background rather than the file, the mark re-brands and flips light/dark with
the rest of the theme — one asset, no variants.

**Trap worth writing down:** the first version of that SVG carried an XML
comment explaining `var(--mxt-brand)`. `--` is illegal inside an XML comment, so
the file never parsed — and the browser reports it as `complete: true` with
`naturalWidth: 0`, i.e. loaded and blank. `curl` returns 200 and the right
content type. Nothing anywhere says "malformed".

## 34. `c76d4b7`: fourteen of the eighteen open issues, re-verified here

*Verified 2026-08-08 on mxcli `c76d4b7` (was `45ae6a6`), built from source.
Every row below was executed against this project, not read from a commit
message. Both suites pass afterwards: **21 backend + 6 frontend**.*

### Fixed, and the workaround deleted

| # | Was | Verified how |
|---|---|---|
| 6 | `dynamic $Variable` written as a literal (§21) | All four `dynamic '' + $Sql` clauses rewritten bare. Live service still answers `@odata.count` 27533 with `$skip=80&$orderby=driverName` → Adrian Sutil. `a32fde9` |
| 15 | `MOVE` had no doctype for a Java action or an OData service (§32) | The last five documents moved: `Live/Pushdown` (3 Java actions) and `Services` (both services). **0 documents at the module root**, from 41. `30327d7` |
| 1 | `CREATE EXTERNAL ENTITIES FROM` renamed `name` (§28) | Both consumer modules dropped and regenerated: `name: String(120)`, not `Stg_Drivername`/`Drivername`. Page bindings and the smoke microflows now say `name`. `4291f1d` |
| 8 | `test --local` displaced the app's After-startup microflow (§19) | The three cached-service tests failed under `--local` on a fresh container and passed under `--attach`. Now **21/21 under `--local`** — `ASU_LoadCacheIfEmpty` runs and fills the test database. `00a6f51`, `9377fbb` |
| 14 | `create module role` had no `or modify` form | `06-security.mdl` and `05-navigation-security.mdl` now re-run end to end. `create or modify user role` exists too, which was the next thing to fail. `98ddb29` |
| 17 | Themes stopped at Atlas Core (§33) | `theme apply console` now writes `_mxcli-widgets.scss`, imported inside the fence. It covers everything this project's layer did *and more* — placeholder colour, export-alert focus ring, feedback and take-picture buttons. `f64115e` |
| 9 | `test --list` ignored a project-relative path (§15) | `mxcli test tests/ --list` lists all 21. `b2c4f20` |

### Fixed, partially

| # | What changed | What is still there |
|---|---|---|
| 4 | `CREATE ODATA CLIENT` now authenticates the `$metadata` fetch (§23) — with literal credentials it caches **8 entity types** where it used to 401 | Give the same credentials as **constant references** (`HttpUsername: '@Module.ApiUser'`) and it is still 401. The constants exist and resolve at runtime; the fetch does not read them. Sharpened by the same release making `ServiceUrl` a constant *mandatory* — so the documented-good shape of a client is exactly the shape whose metadata fetch cannot authenticate |
| 16 | `DESCRIBE MICROFLOW` now emits `folder 'Health'`, so a move can be confirmed (§32) | `SHOW STRUCTURE` is still flat at every depth — no folder grouping, so there is still no way to see a module's layout, only to interrogate one document at a time |

### Landed upstream, not re-verified here

`29481bc` (external-entity mapping read-back, §25), `b9827f1` (contract capability
annotations, §24), `7da49c0` (published-member changes on modify, §26), `bab4d42`
(publish `Integer` as `Int64`, §16) and `63f72e0` (MDL-ODATA01's hint, §15). This
project routed around all five — it regenerates rather than modifies, and every
whole number is already `long` — so re-verifying them would mean re-introducing
the shapes that were broken. Left for a project that hits them naturally.

### Still open, re-confirmed on `c76d4b7`

- **`.ai-context/skills/` does not follow a binary upgrade** (§15, issue 11) — the
  binary is `12:05`, the skills directory is still stamped `Aug 7 14:53`. A rebuild
  leaves stale guidance in place with no warning.
- **`theme apply` cannot help with the header logo** (§33, issue 18) — still a white
  tile from `Atlas_Core.Layout.logo`; the mask rule stays in this project's layer.
- **The filter-operator popover** — the generated widget layer handles
  `.column-selectors` but not `.filter-selectors` / `.dropdown-list` /
  `.dropdown-content`, which still carry `rgba(5,15,129,.05)`. Everything else this
  project patched is now redundant and has been deleted.

### Two things this round changed about the repo itself

Regenerating the consumer modules turned up two microflows that existed **only in
the `.mpr`** — `Probe_DynamicSql` and `Live_SennaName`/`Cached_SennaName`, written
by hand while §21 and §28 were being diagnosed. Both are asserted on by the test
suites, so a rebuild from `model/` produced a project whose tests could not run.
They are now in `11-pushdown-tests-support.mdl` and `03-smoke.mdl`. The repeated
lesson: a fix verified interactively has to be written back into the scripts, or
the scripts quietly stop being the source of truth.

## Suggested mxcli issues

### Still open
1. **`create external entities from` duplicates suffixed associations, unbounded**
   (§50) — an external entity's navigation property becomes an association named
   after it, and three F1Cached entities have a `season` property, so Mendix
   names them `season`, `season_2`, `season_3`. On a re-run the unsuffixed ones
   are matched and left alone; the suffixed ones never match, because the dedup
   compares association *names* and the generator computes a fresh suffix before
   it looks. Two more appear per run, for ever. This repo had accumulated
   `season_2` … `season_15` before anyone noticed — `mx check` is clean, every
   test passes, and the only symptom is duplicate links in Studio Pro's domain
   model. Reproduction and byte counts in §50.
2. ~~**Re-running a script rewrites the document with different bytes** (§50)~~ —
   **fixed by PR 125, verified here in §52.** A unit whose new content is
   canonically equal to the stored one is no longer written. The re-runnable
   script set now leaves both apps byte-identical across consecutive passes, and
   the control (`MXCLI_ALWAYS_WRITE=1`, 72 units churning, then 0 on the next
   normal run) shows the measurement can see a failure.
3. **`FilterRestrictions`/`SortRestrictions` have two shapes and only one is read**
   (§48) — `27ea1da` fixed exactly this for `TopSupported`/`SkipSupported`; the
   filter and sort terms have the same problem. `mdl/types/edmx.go:446` takes
   `NonFilterableProperties` out of the record and ignores the record's own
   `Filterable` property (`:452` the same for `Sortable`), so
   `cmd_contract.go:672` computes `Filterable: !nonFilterable[p.Name]` = true for
   every property. Mendix emits the whole-set form
   (`<PropertyValue Bool="false" Property="Filterable"/>`, no collection) when
   NO attribute of a resource is filterable, and the list form when some are —
   both appear in one document. Generating external entities from this repo's
   `F1OpsApi` gives 28 × CE6630. Reproduction in §48.
4. **`create or modify odata client` does not re-fetch `$metadata`** (§42, §51)
   — the fetch is in the create path only, so after a published service changes
   shape the client keeps its cached contract, reports "Modified OData client",
   and `create external entities` regenerates from stale metadata without
   saying so. Re-confirmed on `38a1137` while adding two attributes to an
   existing resource: `create or modify external entities from` then reports
   "10 updated" and adds nothing, and neither `alter entity … add attribute`
   (CE6612, no remote-name mapping) nor the explicit `create or modify external
   entity … from odata client …` form (CE6611, contract binding lost) can patch
   it by hand. Recovery is drop-and-recreate the client, which works — entities
   rebind in place — but takes every entity access rule on the module with it.
   A `REFRESH ODATA CLIENT Mod.Client` would make this a one-liner.
5. **A published resource hand-rolls its whole query surface** (§20, §22) — five
   Java actions doing regex over a URI to recover `$top`, `$skip`, `$orderby`,
   `$filter` and keys, re-implemented per resource, and every one of them a place
   to forget a case. Declaring what is filterable already happens in `expose (…)`;
   handing the microflow the parsed values rather than the raw request would
   remove the class instead of the instance.
6. **`--hub` makes the app unverifiable in a headless browser** (§38) — the hub
   sets `__Host-`/`Secure` cookies, so a headless browser over plain http can
   never hold a session (`--unsafely-treat-insecure-origin-as-secure` does not
   help). This is why five rendering defects survived — a white chart under every
   panel, a clipped nav rail, a header reading `COLOPENWEEKEND` — none of which
   `check`, the build, the log or `curl` can see. Whatever the mechanism (a
   loopback exemption, an http-safe cookie under `--hub`), being able to render
   the real app is the highest-leverage check missing here.
7. **A killed `mxcli run` leaves the mxbuild child holding the serve port** — the
   next boot then refuses, correctly, on the previous run's corpse: *"port 6643
   is already in use"*. The guard is right; the diagnosis is misleading, because
   the process it names is one you already killed. Reap the child on exit, or
   print the offending pid so the fix is one command rather than three.
8. **`theme apply` cannot help with the header logo** (§33) — `Atlas_Core.Layout.logo`
   is a white-filled SVG in an `<img>`, so a dark theme ships with a bright tile in the
   corner of every page. A theme could emit the mask-and-paint rule (§33 has it) so the
   default mark at least takes the brand colour.
9. **`.ai-context/skills/` does not follow a binary upgrade** (§15, §34) — re-confirmed
   on `c76d4b7`: binary rebuilt at 12:05, skills still stamped from the previous day.
   Stale guidance, no warning.
   `01ef224` puts the sync in `init`; after a rebuild to `b4a825e` the skills
   here are still stamped two days earlier, so a rebuild alone does not carry it.
10. **Lint idea:** `KEY` on a persistable attribute with no `unique` validation is always
   a build error (§17). `mxcli check` could catch it instead of `mxbuild`.
11. **Design-property lint does not know the theme** (§29) — `check` green-lights
   `Row size` / `Hover style`, the build rejects them as unsupported by the applied
   theme. mxcli generates the theme, so it can read its `design-properties.json`.


12. **A dangling `AfterStartupMicroflow` passes every check** (§41) — a setting
   naming a microflow that no longer exists throws on every startup and blocks
   the next `--test-endpoint` injection, while `mx check` reports 0 errors and
   the app serves normally. It got committed here and survived weeks. Resolvable
   statically: `check`/`lint` can compare the name against the model.
13. **Five page-widget properties are parsed, dropped and not reported** (§51) —
   `sort by` on a LISTVIEW's database datasource, `OnClick` on a LISTVIEW,
   `PageSize` on a GALLERY, and chart-level `CustomLayout` /
   `CustomConfigurations` when spelled with a capital. All four pass
   `mxcli check` with no MDL-WIDGET07 warning and are simply absent from the
   model afterwards. The chart case is the sharpest: series-level properties
   *are* matched case-insensitively, so one document can have
   `StaticBarColor` honoured and `CustomLayout` discarded on the capital letter
   alone — which reads as "custom layout is unsupported" rather than "you
   spelled it wrong". MDL-WIDGET07 already exists for exactly this; whatever
   path drops these should route through it.
14. **`LISTVIEW`'s `PageSize` does not round-trip** (§51) — the writer honours
   it (`TestBuildListViewV3_PageSize` guards that), but `describe page` never
   prints it back, so the round-trip this repo uses to verify every other
   change reports it as dropped. The default is 20, which silently ends a
   24-round season in a "Load more" button.
15. **Two expression traps that only `mx check` catches** (§51) — division is
   `div`, not `/` (CE0117 for any operand types, Decimal included), and `div`
   does *not* floor, so `77 div 5` is 15.4; and there is no cast from Decimal
   to Long, so a rounded percentage has to go through
   `parseInteger(formatDecimal($x, '0'))`. Neither `/` nor `round($x)` with one
   argument is rejected by `mxcli check`. Also `not contains(…)` does not parse
   where `contains(…) = false` does. A `check` that validated microflow
   expressions against Mendix's grammar would catch all four at write time.
16. **A marketplace module install collapses MPR v2 into v1** (§53) — one
   `mx module-import`, nothing else, turns 94 KB + 466 `.mxunit` files into a
   single 16 MB blob. That removes the diffable model, `diff-local`, mergeable
   units and the whole property PR 125 just established. `mx convert` only
   targets Mendix versions and mxcli has no convert command, so there is no way
   back. Any headless install path must preserve v2 or refuse; silently
   downgrading the storage format is the worst of the three. **Second instance
   found in §56:** `mx update-widgets` does the same thing (86 KB + 469 units →
   19.5 MB + 0 units), which puts it on the only headless path for installing a
   widget. `mxcli widget init` is the counter-example that preserves v2, so the
   behaviour is a property of the `mx` binary rather than of writing to a v2
   project.
17. **A module flagged `IsThemeModule` cannot be installed headlessly at all**
   (§53) — Conversational UI 7.2.0 carries `Projects$ModuleImpl.IsThemeModule =
   true` while its own `manifest.json` says `"type": "Module"`, and
   `mx module-import` refuses it (exit 112). Flipping that one boolean imports
   the identical package cleanly, so the flag is the sole gate. This blocks the
   only Mendix-supplied chat UI from any CLI-driven project. mxcli could at
   minimum detect the flag and say *why* instead of surfacing `exit status 112`.
18. **Installing a marketplace module resolves no dependencies** (§53) — the four
   Agents Kit 2 modules pull in `CommunityCommons`, `AgentCommons`, `Encryption`
   and two widgets, none of them named in the install output or the module docs.
   They are found by installing, reading CE1613s, and repeating; and the error
   count rises as often as it falls (156 → 16 → 227 → 211 → 1 → 0) because
   fixing a reference makes new documents checkable. `mxcli marketplace install`
   knows the content id — resolving or at least *listing* the dependency set
   would remove the loop.
19. **`mxcli widget sync` covers 7 of 40; `rename-design-properties` has no
   equivalent** (§53, corrected in §56) — after a headless widget install the
   project reports 210 × CE0463, which reads exactly like the malformed-template
   defect that has its own diagnosis skill. It is not: `mx update-widgets` takes
   it to 1 and `mx rename-design-properties` to 0. *This entry originally said
   mxcli had no equivalent at all, which was wrong* — `mxcli widget sync` exists,
   and its own help states it clears 7 of 40 CE0463 on the reference fixture
   where `mx update-widgets` clears all 40 but destroys `mprcontents/` on MPR v2.
   So the gap is coverage, not absence: finish `widget sync`, and wrap
   `rename-design-properties`, whose 158 renames across 44 documents currently
   require the v2-destroying binary.
20. **`CREATE MODEL` can author only `MxCloudGenAI`** (§53) —
   `agenteditor_write.go:70` and `:90` assign the provider unconditionally, so
   the other four providers Agents Kit 2 supports (OpenAI, Bedrock, Gemini,
   Mistral) cannot be expressed in MDL. A project not on Mendix Cloud GenAI
   cannot keep its model document as code.
21. **The agent doctypes have no version-registry entry** (§53) — `show features`
   on 11.13.0 lists nothing for agents or MCP, so there is no `checkFeature()`
   pre-check and no actionable error on an older project, though
   `mxcli syntax agents` states the requirement as Mendix 11.9+.
22. **A skill pack cannot carry Java source** (§54) — `Installs` has only
   `widgets` and `mdl`, pack files land inside `.claude/skills/<pack>/`, and
   MDL's `CREATE JAVA ACTION … AS $$ … $$` takes a method body with no
   standalone-class form. So `mendix-odata-pushdown` — the third pack the skill-
   packs proposal asks for by name — can ship its MDL and its prose but not the
   882 lines of parser its four action bodies delegate to, and the reader still
   copies a directory by hand. An `installs.java` target writing into
   `javasource/<module_path>/`, with the placeholder/whitelist/drift discipline
   the widget path already has, closes it. Pack drafted and validated in
   `.claude/skills/packs/mendix-odata-pushdown/`.

### Fixed upstream in `715bac5`
Verified against the reproduction each was filed with; §48 records how.
Four of them retired a workaround in this repo — the OData action, custom
authentication (which deleted `BcryptCost = 8`), the menu icons (which
deleted a CSS hack), and the service re-grants.

1. **MDL cannot declare a published OData action** (§47) — `create odata service`
   admits `publish entity` blocks and nothing else, so a microflow cannot be
   published as an action or function import. Mendix supports it in full:
   `ODataPublish$PublishedMicroflow` is in the metamodel,
   `PublishedODataService2` carries a `Microflows` collection, and
   `modelsdk/gen/odatapublish` already has `NewPublishedMicroflow()` and
   `NewPublishedMicroflowParameter()` with every setter wired —
   `mdl/backend/modelsdk/odata_write.go` simply never populates it. This is the
   one thing standing between MDL and putting an existing RDBMS's stored
   procedures behind an OData surface properly; the workaround (an entity set
   with an insert microflow) costs the operation's name, turns parameters into
   attributes, and returns 201 for a request the domain rejected.
2. **The external-entity generator ignores the contract's `$top`/`$skip`
   capabilities** (§42) — `cmd_contract.go:1214` stamps `SkipSupported` and
   `TopSupported` true whatever the metadata says, while deriving Creatable and
   Deletable from it two lines above. A service that honestly declares
   `TopSupported: No` then makes the consuming app unbuildable with CE6630, and
   MDL cannot correct it after the fact. This blocks the remedy MDL-ODATA03
   itself recommends.
3. **MDL-ODATA03 has a false negative** (§42) — it fires on the *absence* of a
   `System.HttpRequest` parameter, so adding one for an unrelated reason (the
   key lookup) silences it while `?$top=5` still returns all 77 rows. Check for
   a use of the request, not its presence. (The nine now really do page, §43,
   but the rule would not have noticed either way.)
4. **`authentication microflow` cannot name its microflow** (§40) — the type is
   accepted, the microflow is silently dropped, and the build then fails with
   CE0333 "Please select a microflow to use for authentication". Custom
   authentication is the one documented way off per-request password hashing,
   which is 60–80% of every API call here (§31); without it the only lever is
   `BcryptCost`, which shrinks the cost rather than removing it. The metamodel
   field, the writer and the reader all exist — `visitor_odata.go:323` recognises
   the keyword and captures no name, and nothing assigns `svc.AuthMicroflow`.
   `DESCRIBE` emits it as a comment, so such a service cannot round-trip either.
5. **`MENU ITEM` cannot carry an icon** (§36) — Atlas's collapsed sidebar is a 48px
   icon rail, and a text-only menu renders "Constru" down the left edge of every
   page. There is no way to fix it in the navigation model.
6. **`create or modify odata service` still drops role grants** (§34, §26) — the
   published-member half was fixed in `c76d4b7`; this half was not. Recreating a
   service silently revokes its access and the build fails with "At least one
   allowed role must be selected".
   `b4a825e` carries `28ce821`, which fixes this in `sdk/mpr/writer_odata.go`
   — and `mdl/backend/modelsdk/odata_write.go`, the writer this project's path
   uses, has no `AllowedModuleRoles` handling at all, so it still drops them.
   Reproduced twice on `b4a825e`. §41.

### Fixed upstream in `b4a825e`, verified against this project in §41

Kept because the reasoning is the record of why each mattered. Two of them —
the bundle and the popover — retired code in this repo when they landed.

1. **`mxcli run --local` deletes the web client bundle it just built** (§35) — the
   Gradle `package` pass during boot repopulates `deployment/web` without `dist/`,
   so the app serves a 200 HTML shell and a black screen. Highest impact of anything
   on this list: it makes the app unusable, and nothing in check, build, log or curl
   reports it. Bundle after the boot's packaging, or exclude `dist/` from it.
2. **A published resource declares a `KEY` its read microflow is never told about**
   (§37) — `publish entity … (ReadMode: microflow …)` promises the service can be
   asked for one row by key, but the microflow only sees a URI. Answer the key
   request with the collection default and the client adopts the first row as the
   object's identity, silently and permanently. Warn when a read microflow never
   reads its resource's KEY out of the request, or generate the branch.
3. **A read-microflow resource fails open: it answers a query option it cannot
   honour instead of refusing** (§37, §20, §22) — the flaw underneath both
   wrong-data bugs in this project. `Read_Calendar` could not parse
   `$filter=calendarKey eq '…'`, so it returned its collection default with a 200
   and a correct `$count`; the season standings did the same for `year`. Neither
   is distinguishable from a real answer. A resource that drops a query option
   should 400, and mxcli knows which attributes it published as filterable, so it
   could generate that refusal. Both bugs would have been two-minute bugs.
4. **Nothing shows what a published resource is being asked** (§37) — the
   diagnosis took ten app restarts of theorising and then two once
   `LOG INFO 'URI=' + $Request/Uri` went into the microflow. The URI is only
   otherwise visible at TRACE on the whole runtime. An `mxcli odata trace`, or a
   log node per published service, turns this class of bug from an afternoon into
   a minute. (`mxcli debug` may already cover some of this — untried here.)
5. **`DESCRIBE PAGE` drops a page-parameter mapping, and reads as though it were
   never there** (§39) — a grid column's drill-down round-trips as
   `linkbutton btn (Caption: 'Weekend', Action: show_page Module.Page)` with no
   `(Race: $currentObject)`. The mapping is in the model and the build is green;
   only the description loses it. Cost three restart cycles here, replacing a
   button that was correct. Small bug, outsized cost, because `DESCRIBE` is the
   thing you reach for when you distrust the model.
6. **A comment between two `+` operands lands inside the Mendix expression** (§34) —
   MDL passes it through and the build fails with "Error(s) in expression". Either
   strip comments from expression text or reject them at check time.
7. **`SHOW STRUCTURE` does not group by folder** (§32, §34) — `DESCRIBE` now reports a
   document's folder, which closes half the gap; there is still no way to see a
   module's layout in one place, or to diff an intended layout against the real one,
   without reading the `.mpr` as SQLite.
8. **The widget layer misses the filter-operator popover** (§33, §34) —
   `_mxcli-widgets.scss` re-points `.column-selectors` but not `.filter-selectors`,
   `.dropdown-list` or `.dropdown-content`, which still carry a baked
   `rgba(5,15,129,.05)` shadow. Four selectors from the same file as the ones already
   fixed.

9. **`CREATE ODATA CLIENT` cannot authenticate `$metadata` with credentials given as
   constants** (§23, §34) — literal `HttpUsername`/`HttpPassword` now work; a constant
   reference (`'@Module.ApiUser'`) still gets 401 and the client is created with no
   entity types. Same release made a constant `ServiceUrl` mandatory, so the shape the
   tool insists on for the URL is the shape whose credentials it will not read.
### Fixed upstream in `c76d4b7`, re-verified in §34

Kept because the reasoning is the record of why each mattered.

1. ~~**`CREATE EXTERNAL ENTITIES FROM` renames an attribute called `name`** (§28)~~ —
   prefixed with the remote type, so pages written against the contract did not build
   and the same field was named differently per module. Now `name` on both clients;
   this repo's page bindings were rewritten to match.
2. ~~**`dynamic $Variable` is written as a literal, so runtime-built SQL is impossible**
   (§21)~~ — blocked query pushdown outright, and the `dynamic '' + $Sql` workaround was
   not discoverable. All four clauses here are now bare, and the service still pages.
3. ~~**`MOVE … TO FOLDER` has no doctype for Java actions or published OData services**
   (§32)~~ — five documents were stuck at the module root; the backend now has none.
4. ~~**`mxcli test --local` silently displaces the app's After-startup microflow**
   (§19)~~ — a suite needing startup state passed under `--attach` and failed under
   `--local`. 21/21 under both now.
5. ~~**`create module role` has no `or modify` form**~~ — a security script could not be
   re-run. Both this repo's security scripts now do, `create or modify user role`
   included.
6. ~~**A theme needs a third layer for the widget modules** (§33)~~ — generated as
   `_mxcli-widgets.scss`, covering more than the hand-written version it replaced.
7. ~~**`mxcli test --list` ignores a project-relative path** (§15)~~.
8. ~~**`CREATE ODATA CLIENT` fetches `$metadata` unauthenticated** (§23)~~ — fixed for
   literal credentials; see still-open #1 for the constant-reference case.
9. Landed but not re-verified here, because this project routes around all of them:
   ~~`CREATE OR MODIFY EXTERNAL ENTITY` corrupting unmentioned attributes~~ (§25),
   ~~generated entities ignoring capability annotations~~ (§24),
   ~~`create or modify odata service` ignoring published-member changes~~ (§26),
   ~~a published `Integer` written as `Edm.Int32`~~ (§16), and
   ~~`MDL-ODATA01`'s incomplete hint~~ (§15).

### Fixed upstream in `45ae6a6`, re-verified in §14

The list below is kept because the reasoning is still the record of why each mattered.

1. ~~**`CREATE ODATA SERVICE` leaves `ServiceName` empty → every published service fails
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
6. **A module JAR dependency never reaches the generated Gradle build** (§12) —
   `list jar dependencies` reports it, `deployment/build.gradle` has no trace of it,
   and the only symptom is a runtime `SQLException` about a missing driver. Silent at
   model level, which is the worst place for it to be silent.
7. **Correct the database type table in `database-connections.md`** (§6) — drop
   `Redshift`, add `BYOD` ("Other"), which is the only way to use a JDBC driver Mendix
   does not ship a picker entry for. Now that §11 has proven `BYOD` works against a
   live runtime, the doc is the only thing standing between a user and this working.
8. **`mxcli init` from a solution root silently initialises one app** (§3) — refuse, or
   name the chosen project first.
9. **Warn on unknown `publish entity` properties.** `parsePublishEntityBlock`
   (`visitor_odata.go:344-359`) has a `switch` with no `default`, so a typo like
   `ReadMicroflow:` or `Pagesize:` is silently discarded. The service-level path already
   does this right — `alterODataService` returns
   `"unknown OData service property: %s"`. Applying the same rule at entity level would
   have saved most of an afternoon here.

10. **`$N = 0;` does not parse; `DECLARE $N Integer = 0;` does** (§13) — and the error
    (`no viable alternative at input '$N=0'`) names the token rather than the missing
    keyword. Bare assignment works for `HEAD(...)` and `execute database query`, so the
    rule is not guessable.

### Credit where due

`mxcli test --attach` (#109) took the DuckDB verification loop in §11 from 33.7 s to
2.0 s per iteration, and the per-test-microflow design meant the first (all-failing)
run reported four independent failures with timings instead of one dead log. The
ownership contract held exactly as documented across attach, edit, re-attach and host
shutdown. `mxcli lint`'s MDL044 message (§13) is the best error text in the tool.

## 35. The boot deletes the browser client it just built

*Verified 2026-08-08 on mxcli `c76d4b7`. Symptom: every page is a black screen.*

Both apps served a dark, empty page. Not the theme — `/dist/index.js` 404s, so
the shell paints `--mxt-ground` and the client never starts.

`mxcli run --local` bundles the web client on purpose, and the code says why:

```go
// 5b. Bundle the browser client (web/dist). The serve Deploy target writes the
// client source but not the rollup bundle, so without this the app 404s on
// /dist/index.js and renders blank.
```

It runs, and it succeeds — `Bundling web client... Web client bundled in 33.1s`,
and `deployment/log/web-client-build.log` records `Bundling finished` at
15:15:31. Then the runtime boot runs Gradle `clean-custom-classes compile
package`, and at **15:16:22** that repopulates `deployment/web` — `index.html`
and `index.js` rewritten, `dist/` gone. The bundle is deleted 51 seconds after
it was written, by a later step of the same command, and nothing reports it.

Ordering: build → **bundle** → hub register → **boot (Gradle package)**. The
bundle needs to happen after the packaging, or the packaging needs to leave
`dist/` alone.

### Why it only started now

Gradle has to have work to do. Adding the two `$filter` Java actions in §34
forced a full recompile (`Full recompilation is required because no incremental
change information is available`), and the package pass that follows is what
clears `web/`. That is why the app booted fine for most of this project and then
stopped: the same command, the same version, different Gradle state.

A restart with nothing for Gradle to do leaves the bundle intact — which is the
other half of the proof.

### Working around it

`scripts/run-app.sh` boots the app, waits for it to answer, and re-runs mxcli's
own bundler if `dist/index.js` is missing — mxbuild's bundled node plus
`tools/node/rollup-runner.mjs`, the exact command from
`cmd/mxcli/docker/webclient.go`. ~30s, and it prints which branch it took.

By hand:

```bash
M=~/.mxcli/mxbuild/11.13.0/modeler
cd <App>/deployment/web && NODE_ENV=production \
  $M/tools/node/linux-x64/node $M/tools/node/rollup-runner.mjs
```

### The trap inside the trap

A blank page with a 404 on one asset is invisible to every check this project
has. `mxcli check` passes, the build reports success, the runtime logs nothing,
`curl /` returns **200** with a valid HTML shell, and the OData services all
answer correctly. Only a browser sees it — which is exactly the gap that let it
survive several restarts and a commit. Rendering the real app, not a probe page,
is the only thing that catches this class.

### A second way in

`mxcli test --local` clears the bundle too. Its "project restored" step
repopulates `deployment/` the same way the boot's packaging does, so a test run
between a boot and a browser leaves the app serving a black screen even though
nothing was rebuilt. `scripts/run-app.sh` does not cover that path — it only
runs at boot. Re-run the bundler by hand after a local test, or re-run
`run-app.sh`.

## 36. Gap: `MENU ITEM` cannot carry an icon, and Atlas's collapsed rail assumes one

Atlas collapses its sidebar to `--navsidebar-width-closed`, which is **48px** —
one icon wide. That is a deliberate design: the closed state is meant to be a
rail of icons you can still navigate by.

MDL has no icon clause. `CREATE OR REPLACE NAVIGATION` accepts
`MENU ITEM 'Label' PAGE Module.Page` and nothing else, so every item is text
only, and the closed rail renders the first 48px of each label down the left
edge of every page:

```
Home
Live rac
Season
Drivers
Constru
Circuits
Race re
```

Not a rendering bug — Atlas is doing what it says, on a menu that cannot hold up
its end. There is no way to fix it in the navigation model, so the theme has to
opt out of the rail entirely:

```scss
.layout-atlas-responsive,
.layout-atlas-responsive-default,
.layout-atlas-responsive-sidebar { --navsidebar-width-closed: 0px; }
```

which trades a permanent nav affordance for not showing half a word. An icon
clause — `MENU ITEM 'Home' PAGE Module.Home ICON 'home'` — would make the rail
work as designed.

## 37. A published resource has two ways to be asked for one row, and answering
only one of them corrupts the client's object

The bug, as it looked: on the 2021 season page, the calendar lists the 22 rounds
of 2021 correctly — Bahrain, Imola, Portimão. Click *Weekend* on Bahrain and the
race weekend page opens **round 1 of 2026**. Click round 5 instead: still round 1
of 2026. The grid was right, the page was wrong, and the wrong answer was the
same for every row.

### What it was not

Four plausible causes, each disproved by measurement, because each one is the
kind of thing that looks obviously responsible:

| Suspected | Test | Result |
|---|---|---|
| The read microflow ignores `$filter` | `curl '…/Calendar?$filter=year eq 2021'` | 22 rows, all 2021. Correct. |
| The page's `url: 'weekend/{Race}'` re-resolves and discards the argument | removed the URL | unchanged |
| A grid column's button maps from the page context, not the row | replaced the link button with a microflow call, then with a container `OnClick`, then with a dataview on the grid's selection | unchanged, all three |
| A microflow datasource yields rows with no addressable identity | switched to `database from … where [year = $Season/year]` | unchanged |

The last one is worth keeping in mind for its own sake: the XPath form *does*
push down. It becomes `$filter=year eq 2021` and the backend parses it. That was
briefly blamed here and it was innocent.

What finally located it was logging `$Request/Uri` in the read microflow and
reading the sequence:

```
/odata/f1-fan/Calendar?$top=12&$orderby=round asc&$filter=year eq 2021     ← the grid
/odata/f1-fan/Calendar?$filter=calendarKey eq '1036-c'                     ← Bahrain 2021
/odata/f1-fan/Calendar?$filter=calendarKey eq '1150-c'                     ← ...and from here on
/odata/f1-fan/Calendar?$filter=calendarKey eq '1150-c'
```

### What it was

A client that is **holding** a row re-reads it by key, on its own, without being
asked to. `Read_Calendar` parsed `year` out of `$filter` and nothing else, so the
key request fell through to the collection default — "the most recent season" —
and returned 22 rows. The client took the first one and concluded *that* is the
object it was holding.

From that moment the corruption is self-sustaining: every later read asks for
`1150-c`, the key it was mistakenly handed, and gets a consistent answer. Two
different objects are now on screen at once — the row the grid painted, and the
row the client believes the row is — and nothing distinguishes them until one of
them travels to another page.

There is no error. The request is well-formed, the response is a valid
collection, the count is right, and the status is 200.

### The fix

Answer the key lookup. Both spellings, because clients choose between them and
Mendix's own OData client sends the one that is easiest to miss:

```
?$filter=calendarKey eq '1036-c'     ← what the runtime actually sends
/Calendar('1036-c')                  ← the bare path key
/Calendar(calendarKey='1036-c')      ← the named path key
```

`ODataQuery.entityKey` reads either path form; `filterIdentifier` already read
the `$filter` form. `Read_Calendar` now branches key → id → year → default.

### The rule this leaves

**Every microflow-backed OData resource whose rows a client can hold must answer
a lookup by its own key.** Not as a nicety — a resource that answers the key
request with its collection default actively teaches the client the wrong
identity for an object it is already displaying.

The resource is at risk exactly when its rows leave the widget that fetched
them: selected, passed as a page parameter, or written into a URL. In this app
that is `Calendar` and nothing else, which is why it took a while to find: the
three drill-downs that work — driver, season, constructor — happen to sit on
resources that already parse the id their pages filter by.

### For mxcli

Worth generating rather than remembering. `publish entity … as 'X' (ReadMode:
microflow …)` already knows which exposed attribute is `KEY`; it could either
warn when the read microflow never reads that attribute out of the request, or
emit the key branch. As it stands the KEY declaration is a promise the service
makes on the microflow's behalf, which the microflow has no idea it made.

## 38. What rendering the app found that nothing else did

Adding screenshots to the README meant driving the real pages in a browser for
the first time — the hub's `Secure` cookies had blocked headless login all
along, and running the frontend without `--hub` for the capture lifted that.
Five defects fell out of one pass, none of which any check, build, log or `curl`
had reported:

| | Symptom | Cause |
|---|---|---|
| §37 | Every calendar row opened the same race | key lookups unanswered |
| | Race control panel: *"An error occurred"* | `at` is reserved in DuckDB |
| | Running order unreadable: `N…`, `L…`, `M…` | 16 columns in a 1.6fr panel |
| | Every chart a white slab on a black page | Plotly paints its own paper |
| §36 | `Constru`, `Race re` down the left edge | Atlas's rail wants icons |

Three are worth keeping as rules.

**`at` is a reserved word in DuckDB.** It introduces time travel
(`FROM t AT (VERSION => …)`), so an unquoted `at` in a select list is a parse
error — and the `map` clause cannot reference a quoted identifier, so it has to
be aliased on the way out:

```sql
SELECT "at" AS atTime, …          -- map ( atTime as At, … )
```

The whole resource 500s until it is. The error surfaces as
`Exception occurred while processing REST request` on the wire, with the actual
`syntax error at or near ","` only in the runtime log.

**A chart is not themed by theming the page.** The line and column chart widgets
render through Plotly, which writes its own white `<rect class="bg">` and a
white `background` on `.main-svg` as *inline style*, plus dark grey ticks and
gridlines. None of it reads a custom property. On a `#0E1116` page every chart
came out as a bright slab. Plotly's own answer is a layout JSON per chart, which
would be five copies of the palette in the model; overriding the paint in CSS
keeps one source of truth, at the cost of the only `!important` in this theme:

```scss
.js-plotly-plot {
  .main-svg { background: transparent !important; }
  .bg { fill: var(--mxt-surface) !important; }
  .gridlayer path, .zerolinelayer path { stroke: var(--mxt-line) !important; }
  .xtick text, .ytick text, .legendtext { fill: var(--mxt-ink-muted) !important; }
}
```

**An empty column caption falls back to the column's name.** `column
colOpenWeekend (caption: '')` renders a header reading `COLOPENWEEKEND`. There
is no blank caption; give the column a real one.

### Two things about capturing them

Charts and the wide session table finish well after the network goes quiet — the
race weekend page needs the better part of a minute before the last series
appears. A screenshot taken at `networkidle` shows a spinner and half a legend,
which reads exactly like a broken page.

And the trial licence caps concurrent sessions. Enough probe runs and the client
gets a 401 at startup, clears its session and restarts, so pages come up empty
for reasons that have nothing to do with the code:

```bash
sudo -u postgres psql -d formula1frontend -c 'delete from system$session;'
```

## 39. `DESCRIBE PAGE` loses a page-parameter mapping, and the loss looks like a cause

Small bug, and it cost three of the fifteen restart cycles §37 took, because it
answered a question I was asking at exactly the wrong moment.

Mid-diagnosis, suspecting the drill-down was never handed the row, I asked the
model what it actually contained:

```
$ mxcli -p Formula1Frontend.mpr -c "DESCRIBE PAGE Formula1Frontend.Season_Summary"
...
column "Open" (Caption: 'Open', ShowContentAs: customContent) {
  linkbutton btnWeekend (Caption: 'Weekend', Action: show_page Formula1Frontend.Race_Weekend)
}
```

The source says:

```
linkbutton btnWeekend (Caption: 'Weekend',
  Action: SHOW_PAGE Formula1Frontend.Race_Weekend(Race: $currentObject))
```

The argument is gone from the description. It is **not** gone from the model —
`mx check` reports 0 errors, and an unmapped required page parameter is a
consistency error, so a truly missing mapping could not have built. All four
drill-downs in this app describe the same way, including the three that work.

Read cold, that output is a diagnosis: *the mapping was dropped, that is why the
page gets an empty object.* It is a plausible-looking, wrong answer arriving in
the middle of a hunt, and I spent three cycles acting on it — replacing the link
button with a microflow call, then a clickable container's `OnClick`, then a
dataview bound to the grid's selection. All three behaved identically, because
all three were fixing something that was never broken.

The general shape is worth more than the instance: **`DESCRIBE` is what you
reach for when you have stopped trusting the model, so a lossy `DESCRIBE` is
costliest exactly when it is most used.** Round-tripping is the contract §32
already leans on for navigation and settings; page action arguments should hold
to it too.

Reproduction is a one-liner against this repo: describe `Season_Summary`,
`Drivers_Live`, `Seasons_Overview` or `Constructors_Overview` and compare the
column's button against `model/frontend/04-pages.mdl` or `07-fan-pages.mdl`.

## 40. Custom authentication is the fix for the BCrypt cost, and MDL cannot name the microflow

§31 measured a page turn and found 60–80% of it was BCrypt: a consumed OData
service authenticates with basic auth on every request and holds no session, so
every call is a full login. This is the follow-up — what the options actually
are, measured rather than reasoned about.

### The three methods, and which one applies

[The reference guide][1] lists exactly three for a published OData service:

| Method | How | Usable here |
|---|---|---|
| Username and password | `Authorization: Basic …`, per request | yes — what we do, and what costs 300 ms |
| Active session | existing session + `X-Csrf-Token` | **no** — documented as JavaScript within the same app |
| Custom authentication | a microflow returning a User | yes, and it removes the cost entirely |

[1]: https://docs.mendix.com/refguide/published-odata-services/#authentication-methods

Active session is worth dwelling on, because the measurement invites the wrong
conclusion. Logging in through `/xas/` and reusing the cookie *does* work and
*is* fast:

```
GET /odata/f1/Drivers?$top=20
  basic auth                              200   ~360 ms
  wrong password                          401   ~346 ms   ← hashes either way
  session cookie, no Authorization        200   ~19 ms
  no credentials at all                   401   ~42 ms
```

19 ms against 360 ms looks like the answer. It is not: that path is only open to
same-origin JavaScript, and the thing making these calls is Mendix's own OData
*client*, which sends basic auth and keeps no cookie. The number is proof of
where the time goes, not a route to avoiding it.

### What custom authentication would buy

A microflow taking the `HttpHeader` list, checking a shared secret and returning
a User. No password hash anywhere, so the ~42 ms floor.

The neat part is that **the client needs no change at all**. The microflow can
read the `Authorization: Basic …` header itself and compare it against a
constant; the frontend keeps its existing username/password configuration and
the server simply stops calling BCrypt.

### The gap

MDL accepts the *type* and silently drops the *microflow*:

```
create or modify odata service Formula1Backend.ProbeApi ( … )
authentication microflow Formula1Backend.Read_Seasons
{ … };
```

`mxcli check` passes. `mxcli exec` reports `Created OData service`. Then:

```
$ mxcli -c "DESCRIBE ODATA SERVICE Formula1Backend.ProbeApi"
authentication Microflow                      ← no microflow named

$ mx check Formula1Backend.mpr
[error] [CE0333] "Please select a microflow to use for authentication"
```

The plumbing exists at both ends and only the middle is missing:

- `generated/metamodel/types.go` — `ODataPublishPublishedODataService2.AuthenticationMicroflow`
- `mdl/backend/modelsdk/odata_write.go:233` — writes it from `svc.AuthMicroflow`
- `mdl/backend/modelsdk/integration_read.go:115` — reads it back
- `mdl/visitor/visitor_odata.go:323` — `parseODataAuthTypes` recognises `basic`,
  `session`, `guest`, `microflow` … and captures no name for the last one
- nothing anywhere assigns `svc.AuthMicroflow`

So `svc.AuthMicroflow` is only ever populated by reading a model Studio Pro
wrote. And `DESCRIBE` emits it as a **comment** (`-- Auth Microflow: …`,
`cmd_odata.go:356`), so a custom-auth service cannot round-trip through MDL
either — the same shape as §39.

The grammar change is `authentication microflow <QualifiedName>`; the executor
change is one assignment. Until then this needs Studio Pro, which for a project
whose whole point is that the model is written as MDL means it does not get
done.

### What was done instead

`BcryptCost` **is** reachable — `ALTER SETTINGS MODEL BcryptCost = 8` in
`07-demo-users.mdl`. It shrinks the cost rather than removing it, and it is a
judgement about these two accounts specifically: both are machine accounts with
generated passwords, there is no human password in this database, and the
setting is per app so the frontend keeps the default 12 for its one real user.

Steady state after the change, three runs each:

| Resource | before | after |
|---|---|---|
| `f1/Drivers` (cached) | ~360 ms | **~68 ms** |
| `f1-live/Drivers` (DuckDB) | ~500 ms | **~165 ms** |
| `f1-now/Order` | — | ~71 ms |
| `f1-fan/Calendar` | — | ~857 ms |

Each step down the cost halves, so 10 ≈ 145 ms and 6 ≈ 36 ms; 8 is where the
hash stops dominating without becoming decorative.

And the table earns its keep by what it exposes: **`Calendar` is now the slowest
resource by an order of magnitude**, and that is its own SQL — two correlated
subqueries per race to name the winner and the team. It was always that slow.
While every request carried 300 ms of hashing, nobody could tell.

### One more thing this file cannot do twice

`07-demo-users.mdl` opens by explaining that 06 is not re-runnable because
`create module role` has no `or modify` form. Neither has `CREATE DEMO USER`, so
this file halts on "demo user already exists" too — which meant a setting added
at the *end* of it never ran on an existing project. It is now the first
statement, and the header says so.

## 41. `b4a825e`: seven of nineteen, one that did not take, and a new check that finds nine real bugs here

Verified against this project on 2026-08-09, not read off the changelog. Built
with `MXCLI_FORCE=1 sh scripts/build-mxcli.sh` from `ako/mxcli` main.

### Fixed, and confirmed here

| # | Issue | Evidence |
|---|---|---|
| 1 | §35 the boot deletes the web client it just built | deleted `deployment/web/dist`, touched a Java file so Gradle had work, booted **plain** `mxcli run --local` on both apps: bundle present, boot log now bundles *after* packaging |
| 5 | nothing shows what a resource is being asked | `mxcli log set "OData Publish" TRACE` |
| 6 | §39 `DESCRIBE PAGE` drops a page-parameter mapping | `Action: show_page …Race_Weekend(Race: $currentObject)` is back |
| 12 | a comment between two `+` operands | a microflow with one builds clean |
| 16 | the filter-operator popover | four selectors now in the generated `_mxcli-widgets.scss` |
| 14 | no way to see a module's layout | new `LIST FOLDERS [IN Module]`, which prints the tree `12-folders.mdl` writes |
| 13 | `CREATE ODATA CLIENT` could not use constant credentials | a client with `HttpUsername: '@F1Live.ApiUser'` against the live `$metadata` now imports **8 entity types**; it used to 401 into an empty client |
| — | `ALTER PAGE` could not reach a widget inside a `customContent` column | `SET Caption = … ON btnWeekend` now resolves |

Two of those retire code here: `scripts/run-app.sh` (74 lines that re-ran
mxcli's own bundler after every boot) and the `.filter-selectors` block in
`_f1-widget-dark.scss`. Both deleted.

The `log` one deserves a note out of proportion to its size. §37 took an
afternoon and ten app restarts, and what finally located it was patching
`LOG INFO 'URI=' + $Request/Uri` into a read microflow and rebooting. That is
now:

```
$ mxcli log set "OData Publish" TRACE -p Formula1Backend.mpr
$ curl -u … "…/Calendar?\$filter=calendarKey eq '1036-c'"
TRACE - OData Publish: Incoming request from 127.0.0.1:
  GET …/odata/f1-fan/Calendar?$filter=calendarKey%20eq%20%271036-c%27
```

One command, no model change, no restart.

### The new check is the interesting one

Issues 2 and 4 — a resource declaring a `KEY` its read microflow cannot answer,
and a resource that fails open on a query option it cannot honour — are now
`MDL-ODATA02` and `MDL-ODATA03` in `mxcli check`. Not a runtime fix; a check
that would have caught §37 before it shipped. `MDL-ODATA02`'s remedy text is
§37's own conclusion, down to the failure mode:

> A client holding a row re-reads it by key on its own … With no branch for it
> the request falls through to the collection default, the client adopts the
> FIRST row as that object's identity, and there is no error: valid collection,
> right count, 200.

And it immediately earns its keep, because **it finds nine live instances in
this project** — every one a §37 waiting to happen:

```
02-live-service.mdl   6   Seasons, Circuits, Constructors, Races, DriverStandings, ConstructorStandings
15-live.mdl           3   Order, Messages, Session
```

`14-weekend.mdl` passes clean, which is the control: those are the microflows
that were given `$Request` when §37 was fixed. Nobody has clicked through to a
row of the other nine yet — the season page reaches its standings through
`F1Cached`, not `F1Live` — so the bug is latent rather than absent. Fixing them
is a separate piece of work; the point here is that a tool now says so out loud
instead of a user reporting the wrong race two weeks later.

### One that did not take

**Issue 11 — `create or modify odata service` still drops role grants.**
Upstream has `28ce821 fix(odata): stop deleting a published service's role
grants on modify`, and the fix is real, and it does not apply on this project's
path. Reproduced twice on a throwaway service:

```
grant, then mx check              → 0 errors
create-or-modify, no grant clause → CE0307 "At least one allowed role must be selected"
```

The reason is that there are two writers, and the fix went into one of them:

- `sdk/mpr/writer_odata.go` — carries `AllowedModuleRoles` through, as the
  commit's test asserts;
- `mdl/backend/modelsdk/odata_write.go` — **zero** references to
  `AllowedModuleRoles`. It never writes the grants at all, so a modify through
  this path drops them however carefully the other writer is fixed.

So the trailing re-grants at the end of `13-fan-resources.mdl`,
`14-weekend.mdl` and `15-live.mdl` stay. Worth checking whether the two writers
have other divergences of this shape — a fix verified against one of them is
only half a fix, and nothing in the test suite would notice.

### Not addressed

`.ai-context/skills/` is still stamped 2026-08-07 against a binary built
2026-08-09 (issue 17). `01ef224` puts the sync in `init`, so it presumably needs
an `init`/`add-tool` run rather than following a rebuild; not re-tested here.

Untouched: the custom-authentication microflow (§40, issue 3 — filed after this
batch was cut), the hand-rolled query surface (7), `--hub` headless
verification (8, though `f1fa02b` moves the adjacent screenshot-login path),
the serve port held by a killed run's child (9), menu icons (10), the header
logo (15), and the two lint ideas (18, 19).

### A stale test harness, committed

Unrelated to `b4a825e`, found while re-running the suites on it. An interrupted
`mxcli test --attach` had left the frontend with
`AfterStartupMicroflow = 'MxTest.RegisterEndpoint'` pointing at a microflow that
no longer existed, plus an empty `MxTest` module — and that state was committed,
weeks ago, in `1d52a14` or thereabouts.

It is a quiet kind of broken. `mx check` reports **0 errors**, and the app boots
and serves every page, so nothing in the normal loop notices. What it does is
throw on every startup (263 lines of `at MxTest.RegisterEndpoint` in the runtime
log) and refuse the next `--test-endpoint` injection outright:

```
ERROR: could not remove the test endpoint — the project has been left modified:
DROP MICROFLOW MxTest.RegisterEndpoint: exit status 1: microflow not found
```

mxcli's own message is the thing that named it, and it says exactly the right
thing — *"Check the after-startup microflow and the MxTest module before
committing"* — which is a warning I evidently did not act on at the time.
Cleared the setting, dropped the module; 21/21 frontend tests pass again.

Worth a rule: an `AfterStartupMicroflow` naming a microflow that does not exist
is always wrong, and `mxcli check`/`lint` can see it without a runtime.


## 42. Fixing the nine: what the key lookup actually needed, and three things found on the way

§41 found nine resources whose read microflow could not answer a lookup by the
key the service declares — six on `F1LiveApi`, three on `F1LiveNowApi`, each a
latent §37. This is the fix.

### The shape

Each read microflow now takes `System.HttpRequest`, lifts the key out of
`$filter`, and passes it to its query as a **bound** parameter. The guard lives
in the query rather than the microflow, so the SQL stays in one place:

```sql
SELECT * FROM ( <the query as it was> ) t
WHERE {keyFilter} = '' OR CAST(t.<key> AS VARCHAR) = {keyFilter}
      OR TRY_CAST(t.<key> AS DOUBLE) = TRY_CAST({keyFilter} AS DOUBLE)
```

Empty means "the collection", anything else means "that row" — one query for
both callers, no dynamic SQL, no duplicated SELECT drifting from the original.
Verified per resource against the running service: every one returns the whole
collection unfiltered and exactly one row for a key.

| | collection | by key |
|---|---|---|
| Seasons | 77 | 1 (`year eq 1957`) |
| Circuits | 78 | 1 (`circuitId eq 'monza'`) |
| Constructors | 187 | 1 (`ferrari`) |
| Races | 1171 | 1 (`raceId eq 1036`) |
| DriverStandings | 1680 | 1 (`1957-juan-manuel-fangio`) |
| ConstructorStandings | — | 1 (`1979-ferrari`) |
| Order / Messages / Session | 22 / 80 / 1 | 1 each |

### Three things the fix needed that were not obvious

**A numeric key arrives unquoted.** `ODataFilterId` matches `field eq 'value'`;
Mendix sends `year eq 1957` for an `Edm.Int64` key, with no quotes, so the
identifier reader returns "" and the request falls straight back through to the
collection — the exact failure being fixed. Seasons and Races read the key both
ways and take whichever the client sent.

**The comparison has to survive the column's inferred type.** `CAST(t.year AS
VARCHAR) = '1957'` returned nothing where the same shape worked for a text id,
so the guard compares as text *and* as a number. Cheap insurance against
whatever `read_csv` decided a column was.

**The standings' key was not unique.** `driverId` identifies up to 77 rows — one
per season — so even a lookup that reached the backend could only return the
newest. A key matching many rows is worse than none: it is the §37 failure with
extra steps. Both standings now carry `<year>-<driverId>`, which is the pair
that actually identifies a standing.

Also: the six queries have other callers — the refresh jobs in `04-refresh.mdl`
and the counts in `08-health.mdl` — which now pass `keyFilter = ''`. And
modifying `F1LiveApi` dropped its role grant again (§41's unfixed item), so
`02-live-service.mdl` re-grants at the end like 13/14/15 already do.

### MDL-ODATA03 went quiet without the behaviour changing

Both rules now report zero. Only one of them should.

`MDL-ODATA03` fires when a resource advertises `$top`/`$skip` and its read
microflow "never sees the request (no `System.HttpRequest` parameter)". Giving
the microflow that parameter — for the *key*, which is a different concern —
satisfies the rule. But the paging is still not applied:

```
GET /odata/f1-live/Seasons?$top=5   →   77 rows
```

The rule can see whether a microflow *could* read the request, not whether it
does, so it has a false negative exactly where a resource has been half-fixed.
Worth tightening to look for a use of the parameter, not its presence.

### And the remedy it suggests cannot be used here

`MDL-ODATA03` offers the honest alternative: "declare `TopSupported: No,
SkipSupported: No`". Tried it on all nine. The backend accepts it, the contract
correctly says `Bool="false"` — and the **frontend then cannot build**:

```
[error] [CE6630] "'Seasons' is marked supports $top=False in the OData service,
                  but True in the app." at Entity 'F1Live.Seasons'
```

Because the external-entity generator hardcodes both:

```go
// mdl/executor/cmd_contract.go:1211
ent.Creatable    = entitySet.Insertable != nil && *entitySet.Insertable
ent.Deletable    = entitySet.Deletable  != nil && *entitySet.Deletable
ent.Updatable    = false
ent.SkipSupported = true      // ← ignores the contract
ent.TopSupported  = true      // ← ignores the contract
```

Creatable and Deletable are derived from the annotations; Skip and Top are
stamped true regardless. The comment directly above even explains that the app
must match the service "or mx check reports CE6630". MDL cannot correct it
afterwards either — `skipsupported`/`topsupported` exist only on the *published*
side (`visitor_odata.go:381`), not on an external entity.

So the declaration was reverted and the nine still advertise paging they do not
do. This is §24's family: the generator defaults a capability rather than
reading it, and the mismatch surfaces as a build error in the *other* app.

### One more, found while regenerating

**`create or modify odata client` does not re-fetch `$metadata`.** The fetch
lives in the create path (`cmd_odata.go:1131`); modify leaves the cached
contract alone. So after changing what a service publishes, re-running the
client script reports "Modified OData client" and imports nothing new — the
model keeps the old shape, and `create or modify external entities` then
faithfully regenerates from stale metadata. It reported "8 updated" while
silently omitting the new attribute.

The recovery is to drop the client and its external entities and recreate them,
which in this project also means re-running the pages and grants that bind them.
Either modify should re-fetch, or it should say that it did not.

## 43. Paging the nine, and why the count needs its own scan

§42 closed the key half and left the other one open: the nine resources still
advertised `$top` and `$skip` and applied neither, so a client asking for five
seasons got seventy-seven and believed it had a page. `MDL-ODATA03` had stopped
saying so, which made it worse rather than better.

### Values, not a clause

`ODataOrderLimitSql` splices `" ORDER BY … LIMIT n OFFSET m"` into a statement
the caller is assembling. These resources assemble nothing — their SQL lives in
the connection and takes bound parameters — so they need the *numbers*:

```java
public static long topValue(String uri, long fallback, long maxTop)
public static long skipValue(String uri)
```

and the query gained a bound window beside its bound key:

```sql
ORDER BY t.year DESC
LIMIT CAST({topN} AS BIGINT) OFFSET CAST({skipN} AS BIGINT)
```

Bound, so nothing a client sends reaches the SQL as text. `?$skip=drop%20table`
is 0.

**The fallback is the whole list, not a page size.** `orderLimit` defaults to
`maxTop` because an unbounded read microflow is how the Drivers grid once
returned 293 KB for twenty names. These nine are different: they returned
everything before they could page, and every existing caller — the frontend's
external entities, the refresh jobs, the health counts — expects that. A default
page here would be a silent behaviour change dressed as a fix.

### The count has to be the set, not the page

A grid draws its scrollbar from `$count`, so once a read returns a page,
`COUNT($Rows)` is the wrong answer — it reports the page size and the scrollbar
says there are five seasons. The full-set count needs its own scan.

The paged resources in `10-live-pushdown.mdl` keep a second named query for
this (`GetDriverCount`). These nine don't need one: the same query, run with the
window wide open, *is* the count. So the second scan is the same statement with
`topN = '1000000', skipN = '0'` — no new queries, no new entities, and the count
matches the filter by construction because it is the same WHERE.

It runs only when `$count=true`, so an unpaged read still costs one scan. These
are 77–1680 row tables; RaceResults, the one that would hurt, has had proper
pushdown since §22.

### Verified

```
GET /Seasons                      →  77 rows,  count absent
GET /Seasons?$top=5               →   5 rows,  2026 … 2022
GET /Seasons?$top=5&$skip=10      →   5 rows,  2016 … 2012
GET /Seasons?$top=5&$count=true   →   5 rows,  count=77      ← the set, not the page
GET /DriverStandings?$top=3&$count=true            →  3 rows, count=1680
GET /DriverStandings?$filter=standingKey eq '…'    →  1 row,  count=1
```

Five tests cover the readers directly, including the clamp and the junk input.
The published contract is byte-identical afterwards — capabilities were already
`true` and are now honest — so no client, external entity or page needed
regenerating. 26/26 backend, 23/23 frontend.

### What this left

`$orderby`, which §44 then closed — by the second of the two routes sketched
here, a column whitelist bound into a `CASE`.

## 44. Ordering by a bound CASE, so the SQL can stay where it is

The last of the three query options. `$filter`'s key half landed in §42 and
paging in §43, both as bound parameters. `$orderby` cannot be one: an ORDER BY
is SQL text, and a bound parameter is a value.

### Why not the obvious route

`10-live-pushdown.mdl` already solves this for Drivers and RaceResults — build
the statement in the microflow, splice in a whitelisted clause. Doing the same
here would mean lifting nine SELECTs out of the connection and into microflow
string concatenation, and three of them are the live snapshots whose `read_csv`
carries a full column-type spec:

```
columns = {'sessionKey': 'VARCHAR', 'driverNumber': 'BIGINT', 'code': 'VARCHAR', …}
```

Eighteen of those, as `+ '…'` fragments, duplicated from a query that still has
to exist for its mapping. That is the drift §42 was written to avoid.

### What was done instead

The order is chosen *inside* the query, by a CASE over the exposed names, with
the name and direction arriving as bound parameters:

```sql
ORDER BY
  CASE WHEN {sortDir} = 'A' THEN (CASE {sortCol}
       WHEN 'championDriver' THEN t.championDriverName … END) END ASC  NULLS LAST,
  CASE WHEN {sortDir} = 'D' THEN (CASE {sortCol} … END)               END DESC NULLS LAST,
  CASE WHEN {sortDir} = 'A' THEN (CASE {sortCol}
       WHEN 'year' THEN CAST(t.year AS DOUBLE) … END) END ASC  NULLS LAST,
  CASE WHEN {sortDir} = 'D' THEN (CASE {sortCol} … END)               END DESC NULLS LAST,
  t.year DESC                                        -- the query's own order
```

When `{sortCol}` is empty every CASE is NULL, every row ties, and the query's
own ORDER BY decides — so a caller that asks for nothing gets exactly what it
got before. Four terms rather than one because a direction cannot be bound
either, and because a CASE has a single type: text and numeric columns need
their own arms. Dates go in the text arm as `CAST(… AS VARCHAR)`, which sorts
correctly precisely because DuckDB renders them ISO; booleans go in the numeric
arm as 0/1.

96 sortable columns across the nine, so the blocks were generated from the
`expose` clauses and the entity types rather than typed out.

The two readers return values, not a clause, and the whitelist they check is
the same list of names the CASE matches on — one place to add a column, one
place to forget one.

### Verified

```
/Seasons?$top=4                              2026 | 2025 | 2024 | 2023   (default)
/Seasons?$top=4&$orderby=year asc            1950 | 1951 | 1952 | 1953
/Seasons?$top=4&$orderby=raceCount desc        24 | 24 | 22 | 22
/Circuits?$top=4&$orderby=length desc      25.579 | 8.36 | 8.302 | 8.3
/Seasons?$orderby=raceCount asc,year desc   7/1955 | 7/1950 | 8/1961      (first term)
/DriverStandings?$orderby=points desc&$top=3&$count=true
                                            575 | 454 | 437,  count=1680
```

Composes with the key and the page, and the published contract is unchanged —
these are query parameters, not model — so again nothing downstream needed
regenerating. Six tests on the readers; 32/32 backend, 23/23 frontend.

### A defence that turned out to be a second line

The whitelist exists so an unknown name cannot reach the SQL. It never gets the
chance: Mendix validates `$orderby` against the published entity first and
answers `400 "Could not map 'nonsense' to attribute or association."` before the
read microflow runs. Worth knowing that the platform does that much — and worth
keeping the whitelist anyway, since it is what stops an *exposed* column being
sorted on when the query has no arm for it.

## 45. What Mendix's OData client actually sends, since nothing says

Three sections of pushdown work — §42 the key, §43 the page, §44 the order —
were each built against a guess about what a client would ask for. Before
turning any of it into a reusable component it was worth finding out.

### There is nothing to read

Mendix's [consumed OData service
requirements](https://docs.mendix.com/refguide/consumed-odata-service-requirements/)
is the page you would expect to answer this. It lists the system query options a
service must support —

> It should support queries on the OData feed, including: `$filter`,
> `$orderby`, `$top`, `$skip`, `$expand`, `$count` (or `$inlinecount`)

— the OData versions, and the EDM types allowed for a key. It names not one
comparison operator, not one function, and says nothing about how `null` is
compared or how a key is addressed. It closes with "The OData implementation in
Mendix does not support all features of the OData specification" and a
recommendation to test third-party APIs with a proof of concept, which is fair
enough and also an admission that the set is not written down anywhere.

The published side is no better: nothing documents the XPath → OData mapping a
datagrid filter goes through. So it was captured instead.

### How

`b4a825e` added `mxcli log set`, which made this a five-minute job rather than a
packet capture:

```bash
./mxcli log set "OData Publish" TRACE -p Formula1Backend.mpr
```

The node logs each incoming request URI. Then two passes:

1. **Drive the real UI.** A Playwright script walked every page in the frontend
   and worked every grid — sorted columns, paged, typed in filter boxes, opened
   drill-downs. 81 requests.
2. **Force the shapes the UI does not reach.** Fourteen probe microflows in the
   *frontend*, each retrieving from an external entity with one XPath constraint
   — `=`, `!=`, `>`, `>=`, `<`, `and`, `or`, `contains`, `starts-with`,
   `ends-with`, `= empty`, a boolean, a decimal, and a mixed one — run through
   `mxcli test --attach` so the trace shows what each XPath became on the wire.

### The whole grammar, as emitted

```
name eq 'Ayrton Senna'              (raceWins gt 10) and (podiums gt 20)
name ne 'Ayrton Senna'              (name eq 'a') or (name eq 'b')
raceWins gt|ge|lt|le 40             contains(name,'Sen')
points gt 100.5                     startswith(name,'Ayr')
nationality eq null                 endswith(name,'nna')
championshipWon eq true
```

Plus `$select` (on nearly every request), `$top`, `$skip`, `$count=true`,
`$orderby` with **two** terms (`round asc,calendarKey asc` from a grid whose
default sort is composite), and `$expand` — but only on persistent entities with
navigation properties, never on the flat non-persistable rows this app publishes
from DuckDB.

Each XPath maps to exactly one OData term, with each term wrapped in its own
parentheses when there is more than one. No arithmetic, no lambdas, no `$apply`,
no date functions, no `any`/`all`. The set is small — which is the good news,
because covering all of it is achievable, and covering all of it is what makes a
widget over an external entity work rather than half-work.

### The one that mattered

`or`. The `where()` helper written in §21 split the filter on `and` and matched
each piece with a regex; it could not express `or` **at all**, and rejected any
request containing one. Mendix emits `or` the moment a datagrid filter has two
values selected — the second click on a filter chip. So the pushdown resources
had a defect that only appeared on the second interaction, and the honest
rejection meant it surfaced as a 500 rather than as wrong data. Better than
silent, still broken.

That single finding is what turned "tidy these Java actions up" into §46.

## 46. Extracting it: ten Java actions become one module

By §44 there were ten Java actions doing OData pushdown in this app, all
wrappers over one 469-line class in `javasource/formula1backend/`, and every
line of it was about OData and SQL rather than about Formula 1. Any app putting
an existing RDBMS or warehouse behind an OData surface needs the same thing.

It is now `ODataPushdown` — a module, a package, and an MDL script that installs
it into any project. See `model/odatapushdown/README.md`.

### One parse, not nine

The old shape had each action re-read the URI to answer one question about it:

```
$KeyText  = ODataFilterId(Uri, 'year');       $Top     = ODataTop(Uri, …);
$KeyNum   = ODataFilterYear(Uri, 'year', 0);  $Skip    = ODataSkip(Uri);
$SortCol  = ODataSortColumn(Uri, $Sortable);  $SortDir = ODataSortDirection(Uri);
$WantsCnt = ODataWantsCount(Uri);
```

Seven parses of the same string per request, in six microflows, and nothing
holding the seven answers to a single interpretation. Now:

```
$Q = CALL JAVA ACTION ODataPushdown.Parse(
  Uri = $Request/Uri, Columns = $Cols, Dialect = 'duckdb',
  MaxTop = 1000000, DefaultTop = 1000000, DefaultOrderBy = '',
  KeyField = 'year', RejectUnsupported = false);
```

Ten actions became three: `Parse`, and the short forms `Key` and `FilterNumber`
for resources whose whole contract is one value out of `$filter`.

### What changed on the way out, and why

**A real parser.** §45 found the old `where()` could not express `or`, so the
filter is now recursive descent — `parseOr → parseAnd → parseUnary → parsePrimary
→ parseTerm` — which gets precedence, `not` and nesting for free rather than
approximating them. `name eq 'a' and (raceWins gt 1 or raceWins lt 0)` becomes
`(name = 'a' AND ((totalRaceWins > 1 OR totalRaceWins < 0)))`.

**Typed columns.** The map grew a third field: `exposed:sql:type`, with type one
of text, number, bool, date. This closes a real hole. Mendix quotes a literal
according to what the *widget* believes the attribute is, so the same numeric
column arrives as `year eq 1957` from a grid header and `year eq '1957'` from a
combo box; the old helper passed the quotes through and handed DuckDB
`year = '1957'` against a BIGINT — zero rows, status 200. §42 patched that in SQL
with a `TRY_CAST(… AS DOUBLE)` arm per query. The parser does it once, for
everybody. An unrecognised type is a hard error, because a typo would otherwise
turn a numeric column into a text one silently.

**Dialects.** Five, differing in exactly two places: how a case-insensitive
`LIKE` is spelled and how a page is. DuckDB and PostgreSQL have `ILIKE` and
`LIMIT … OFFSET`; SQL Server and Oracle need `LOWER(…) LIKE LOWER(…)` and
`OFFSET … ROWS FETCH NEXT … ROWS ONLY`; MySQL puts the page the other way round.
Two tests run through SQL Server and MySQL precisely because nothing in this app
does — "not DuckDB-shaped" is only provable from outside DuckDB.

**Two sort terms.** §44 carried one and said a second "would need a second CASE
in every query". §45 found Mendix does emit two. The parse now returns both;
splice callers get both in `OrderBySql`. The nine bound queries still bind the
first only — that is the second CASE, and it has not been written.

**Rejection became a choice.** `RejectUnsupported`. Splice callers pass true: a
filter they cannot translate means an empty `WHERE`, which is every row in the
table under a 200. Bind callers pass false: they never look at `FilterSql`, so
failing over a filter they were never going to apply trades one wrong answer for
another.

### Both styles, both proved

The migration covers everything, which is the point — a component with one
consumer proves nothing.

| | resources | takes |
|---|---|---|
| splice | Drivers, RaceResults (`10`) | `FilterSql`, `OrderBySql` |
| bind | the six in `02`, the three in `15` | `Key`, `Top`, `Skip`, `SortColumn1`, `SortDirection1` |
| key only | five in `13`, five in `14` | `Key` / `FilterNumber` |

`Key` reading the path as well as `$filter` deleted a branch outright: Calendar
used to need `ODataFilterId` *and* `ODataEntityKeyId`, with a three-way `IF`
underneath, because the second returned a number. One call now answers all three
spellings — `?$filter=calendarKey eq '1036-c'`, `/Calendar('1036-c')` and
`/Calendar(calendarKey='1036-c')` — all three verified against the running app.

`09-query-pushdown.mdl` and `javasource/formula1backend/ODataQuery.java` are
deleted. `13-fan-resources.mdl` lost the 90-line block of action declarations it
opened with.

### Tested

The test-support wrappers were rewritten to go through the module, and the suite
grew from 32 to 49: the whole §45 grammar term by term, both the quoted and bare
spelling of a number, `eq null` both ways, precedence, `not`, the key in all
three forms, a key that is not an identifier, the two other dialects, and four
rejection cases. 57/57 backend overall.

Over HTTP, on the running app:

```
/Seasons?$filter=year eq 1957                 1 row, Fangio        (bind, numeric key)
/Seasons?$top=3&$orderby=year asc&$count=true 1950,1951,1952 of 77 (bind, page + sort)
/Drivers?$filter=name eq 'Ayrton Senna' or name eq 'Alain Prost'
                                              2 rows               (splice, or — new)
/Drivers?$filter=contains(name,'Sen')&$top=3  3 of 7               (splice, page + count)
/Calendar('1036-c')                           Bahrain 2021         (key in path)
```

### What is still owed

The nine bound resources apply no `$filter` beyond their key, while their
`expose` clauses declare every attribute `Filterable`. A grid filter on one of
them is accepted and ignored — the same class of defect as §37, one layer along.
Three ways out: bind a `{filterSql}`-shaped parameter (impossible — a bound
parameter is a value), move the nine to splice style (loses the readable SQL
that §44 went out of its way to keep), or stop declaring what is not applied
(blocked by the same `cmd_contract.go:1214` hardcode that made `TopSupported: No`
unusable in §42). Left as it was, filed rather than half-fixed.

### Roadmap: stored procedures, as OData actions

The bind style already reaches a procedure's *result set* — point a named query
at `CALL sp_x(?)` and the module supplies the arguments. What it cannot do is
expose the procedure as something a client can **invoke**: an OData action or
function, `POST /odata/x/RunReport`. That is the other half of putting an
existing RDBMS behind an OData surface, and the piece that turns this from a
read-only projection into a two-way integration. Not started.

## 47. Stored procedures over OData: everything except the action

§46 left stored procedures as roadmap. This is what happened when they were
built, which is: the database half works, the publishing half is one missing
piece of MDL, and four things bite on the way that nothing documents.

### The setup, so the finding is not a toy

`scripts/create-f1ops-db.sh` builds `f1ops`, a real Postgres database holding
the F1 data and two routines of deliberately different kinds:

- `f1ops.driver_form(p_driver_id, p_last_n)` — a **table-valued function**.
  plpgsql, with a loop and a running average, so it is procedural rather than a
  view in a hat.
- `f1ops.record_prediction(...)` — a **procedure** with INOUT parameters. It
  validates and then writes, because that is the other reason logic sits in a
  database: the rule lives next to the data and every caller gets it.

`model/backend/16-ops-procedures.mdl` puts both behind `F1OpsApi`
(`/odata/f1-ops/`). Nothing in this app owns that schema, which is the point.

### The module gained one action

`ODataPushdown.CallStatement(Routine, Kind, Parameters, Dialect)` renders the
invocation for the engine you are on. Five engines, three kinds, almost no two
agreeing:

```
             table                            procedure
pg/duckdb    SELECT * FROM f(a,b)             CALL p(a,b)      (duckdb: none)
sqlserver    SELECT * FROM f(a,b)             EXEC p @x=a, @y=b
oracle       SELECT * FROM TABLE(f(a,b))      BEGIN p(a,b); END;
mysql        none                             CALL p(a,b)
```

`Parameters` is a list of Mendix parameter **names**, never values, so it emits
`SELECT * FROM f1ops.driver_form({driverId}, {lastN})` — a template for
`execute database query` to bind. That is a stronger position than the `$filter`
translation can take: a `WHERE` clause has to be built as text because its shape
comes from the client, but a routine call's shape is fixed by the routine and
only its values vary. The only text emitted is the routine name, and that is
checked against an identifier pattern rather than escaped. Fourteen tests.

### Four things that bite

**1. MDL cannot declare an OData action.** This is the finding.

A procedure that changes something wants to be an action:
`POST /odata/f1-ops/RecordPrediction`, arguments in the body, an `ActionImport`
in `$metadata`. Mendix supports it — `ODataPublish$PublishedMicroflow` is in the
metamodel, `PublishedODataService2` has a `Microflows` collection, and
`modelsdk/gen/odatapublish` has `NewPublishedMicroflow()` and
`NewPublishedMicroflowParameter()` with every setter wired.

MDL has no syntax for it. `createODataServiceStatement` in `MDLService.g4`
admits `publishEntityBlock*` and nothing else; `publish microflow …`,
`publish action …` and every variant tried is a parse error at `missing ENTITY`.
And `mdl/backend/modelsdk/odata_write.go` has zero references to
`PublishedMicroflow`, so even the SDK path never populates the collection. The
`$metadata` this app publishes has an `EntityContainer` with two `EntitySet`
elements and no `ActionImport` — that is the gap, visible from outside.

Everything else in the metamodel is one grammar rule away:

```
publishMicroflowBlock
    : PUBLISH MICROFLOW qualifiedName (AS STRING_LITERAL)?
      (LPAREN publishedParam (COMMA publishedParam)* RPAREN)?
      (RETURNS dataType)?
      SEMICOLON?
```

**2. A returning procedure cannot be called at all.** The obvious statement,

```sql
CALL f1ops.record_prediction({driverId}, ..., NULL, NULL, NULL)
```

is correct Postgres and is exactly what `CallStatement` renders. Mendix will not
run it. The External Database Connector inspects the statement and dispatches a
`CALL` as an update —
`QueryDispatcher:153 -> JdbcConnector.executeStatement:118 -> executeUpdate` —
and PgJDBC then refuses, because a `CALL` with INOUT parameters answers with a
row: *"A result was returned when none was expected"*. There is no
`execute database statement` activity to reach for; the only door is
`execute database query`, and it wants a `SELECT`.

The workaround is a one-line function in the database that `CALL`s the procedure
and returns its row, so the invocation begins with `SELECT`. Every Mendix app
that needs a returning procedure will write it. The procedure is untouched and
is still what runs.

**3. A routine's arguments are not columns of its result.** Mendix validates
`$filter` against the published metadata *before* the read microflow runs, so
`?$filter=driverId eq 'ayrton-senna'` against a resource whose entity has no
`driverId` attribute is answered

```
400  Could not map 'driverId' to attribute or association.
```

and the microflow never sees it. A parameterised resource therefore has to carry
its own parameters as attributes and echo them back on every row —
`SELECT f.*, {driverId} AS driver_id, … FROM f1ops.driver_form(…) f`.

An OData action would take them as parameters and need none of this. It is the
sharpest single cost of finding 1: every parameterised resource pays it.

**4. The Postgres driver has to be declared and shipped, twice over.** Mendix
runs on Postgres, so a `type 'PostgreSQL'` connection looked like it needed
nothing. It needs both:

- **build**: without a module jar dependency, mxbuild fails CE5278 "The
  PostgreSQL JDBC driver (org.postgresql:postgresql) is missing from the module
  settings";
- **run**: declared but `included = false`, the build is green and the first
  request dies with *"No JDBC driver found in app for URL: jdbc:postgresql://…"*
  — the Connector resolves drivers from the app's classpath, not the runtime's.

So `included = true` and `mxcli sync-java-deps`, exactly as for DuckDB. Being
the same database Mendix itself runs on buys nothing.

### What shipped instead of an action

The procedure is published as an entity set whose `InsertMode` is a microflow —
the OData-v2-era idiom for an action. A client POSTs the arguments, the
microflow calls the routine and writes the answer back onto the same object, and
Mendix returns it in the 201. Note the insert microflow must return **Nothing**
(CE6588); Mendix serialises the parameter object itself, which is what lets the
answer come back.

```
POST /odata/f1-ops/Predictions  {"driverId":"max-verstappen","raceId":551,
                                 "position":1,"submittedBy":"fan"}
  201  {"predictionKey":"2", …, "accepted":true,  "message":"recorded"}

POST … {"driverId":"nobody-here", …}
  201  {"predictionKey":"",  …, "accepted":false, "message":"no such driver: nobody-here"}

POST … {"position":99, …}
  201  {"predictionKey":"",  …, "accepted":false, "message":"position must be between 1 and 20"}

GET  /odata/f1-ops/Predictions('2')
       {"predictionKey":"2","driverId":"max-verstappen","position":1, …}

GET  /odata/f1-ops/DriverForm?$filter=driverId eq 'ayrton-senna' and lastN eq 3
       three rows, rollingAvg 30.00 each  (1994: three DNFs)
```

The refusals come back as `accepted=false` with the database's own message
rather than as a 500, because they are answers and not failures: the procedure
validated the request and said no. A 500 would lose the reason.

What it costs against a real action: the operation is named `Predictions` rather
than `RecordPrediction`, the arguments are attributes rather than parameters,
and a POST that the domain rejects is still a 201. Swap it the day MDL grows the
syntax — the microflow underneath does not change.

`mxcli check` (MDL-ODATA02) caught the one thing that would have made this
another §37: `Predictions` declares a KEY, so a client that has just POSTed will
re-read by it. The predictions are in a table, so the lookup is answerable, and
`Read_Predictions` answers it. Dropping the KEY is not an alternative — Mendix
requires one (CE6585).


## 48. `715bac5`: six filed findings fixed, four workarounds deleted, one new bug

Eleven commits on `ako/mxcli` main since `b4a825e`, six of them citing a section
of this file by number. Verified each against the reproduction that was filed,
then deleted what they retire.

| Filed | Commit | Verified |
|---|---|---|
| §47.1 MDL cannot declare an OData action | `ededab1` `3509f2a` | **fixed** — and adopted |
| §42 external entities ignore the contract's `$top`/`$skip` | `27ea1da` | **fixed** |
| §42 MDL-ODATA03 false negative | `70a169b` | **fixed** |
| §40 `authentication microflow` cannot name its microflow | `109a55c` | **fixed** — and adopted |
| §41 the modelsdk writer drops `AllowedModuleRoles` | `dc780ec` | **fixed** |
| #9 `MENU ITEM` cannot carry an icon | `10ba2e1` `9364d43` | **fixed** — and adopted |

### The action, which was the top open issue

`publish microflow` exists, and the design is better than what §47 proposed:
parameter types and the return type are **not** restated in MDL, they are read
off the microflow. There is one declaration, so the two cannot drift.

```
publish microflow Formula1Backend.RecordPrediction as 'RecordPrediction'
  expose ( DriverId as 'driverId', RaceId as 'raceId', … );
```

`$metadata` grew what it was missing:

```xml
<Action Name="RecordPrediction">
  <Parameter Name="driverId"    Nullable="false" Type="Edm.String"/>
  <Parameter Name="raceId"      Nullable="false" Type="Edm.Int64"/>
  …
<EntityContainer Name="Entities">
  <ActionImport Action="Formula1Backend.Ops.RecordPrediction" Name="RecordPrediction"/>
```

```
POST /odata/f1-ops/RecordPrediction  {"driverId":"charles-leclerc", …}
  200  {"predictionKey":"4", …, "accepted":true,  "message":"recorded"}
POST … {"driverId":"nobody", …}
  200  {"predictionKey":"",  …, "accepted":false, "message":"no such driver: nobody"}
POST /odata/f1-ops/Predictions                                        405
```

The entity-set-with-an-insert-microflow workaround is deleted, the microflow
underneath is unchanged — which is what it was written for — and `DESCRIBE`
round-trips the block, so the service can be read back out of the `.mpr`.

**One constraint worth knowing**: an action's return type must be an entity the
same service publishes (CE7244). `Ops_Prediction` therefore keeps `accepted` and
`message`, which read like properties of a submission rather than of a record —
splitting them would mean inventing a second entity set to hold outcomes, which
is the worse lie.

### Custom authentication, which deletes a deliberate weakening

`authentication microflow Module.X` now carries the name through, and
`mxcli check` gained **MDL-ODATA04** for the unnamed form — confirmed both ways:
the rule fires on `authentication microflow` alone, and the named form builds.

This retires `BcryptCost = 8`. §31 measured BCrypt at 60–80% of a cached page
turn and §40's answer was to drop the work factor from 12 to 8 — faster, and a
deliberate weakening taken only because the real fix could not be written. Now
all five services authenticate through a microflow that reads a key off the
request headers, no password is presented per request, and the cost is back at
the Mendix default.

```
                       basic   X-Api-Key
/odata/f1-live/…        401       200
/odata/f1/…             401       200
/odata/f1-fan/…         401       200
/odata/f1-now/…         401       200
/odata/f1-ops/…         401       200
```

The frontend's four OData clients send the key with `HEADERS ('X-Api-Key': @Mod.ApiKey)`
instead of `HttpUsername`/`HttpPassword` — a constant reference, so the key is
not a literal in the model. 23/23 frontend tests pass, which is the real proof:
they drive the clients.

A shared key is the right shape for machine-to-machine here and the wrong shape
for anything with human users. The point of the microflow is that *what* gets
checked is now the app's decision.

### Icons, which delete a CSS hack

`MENU ITEM … ICON Atlas_Core.Atlas.home`, as a qualified name into an icon
collection rather than a string — so it is a model reference `mx check`
resolves, and `SHOW ICON COLLECTION` lists what is available.

`theme/web/_f1-widget-dark.scss` carried `--navsidebar-width-closed: 0px`,
collapsing Atlas's rail the whole way because MDL could not give the items
icons and the rail rendered "Constru", "Race re", "Live rac" down every page.
Deleted. The rail is back at Atlas's 48px with eight icons in it.

### The two that needed no change here

**`AllowedModuleRoles`** — `28ce821` fixed the `.mpr` writer and missed the
modelsdk one, so `create or modify odata service` kept dropping grants and every
file that modified a service had to re-grant. Tested directly: a bare modify
with no grant statement, then `DESCRIBE` — the grant survives. The grants stay
in the scripts because a fresh run still has to grant once; the paragraphs
explaining why they were repeated are gone.

**MDL-ODATA03** now looks for `$top`/`$skip` in the microflow *body* rather than
for a `System.HttpRequest` parameter, so answering the KEY no longer silences the
paging concern by accident. Clean across all six OData scripts here. Worth being
honest about why: these microflows hand the request to a Java action, and the
rule stops at a call it cannot read rather than guessing. That is the right
stance, and it does mean the rule is trusting this app rather than checking it.

### One new bug, the sibling of the one just fixed

`27ea1da` fixed `TopSupported`/`SkipSupported` by teaching the parser that the
capabilities vocabulary has **two annotation shapes** — a record, and a
standalone boolean. Verified: `F1OpsApi/DriverForm` declares `TopSupported: No`,
and the generated external entity now carries `TopSupported = false` where it
used to be hardcoded true.

`FilterRestrictions` and `SortRestrictions` have the same two-shape problem, and
only one shape is read. `mdl/types/edmx.go:446` takes `NonFilterableProperties`
out of the record and ignores the record's own `Filterable` property; the same
at `:452` for `Sortable`. `cmd_contract.go:672` then computes
`Filterable: !nonFilterable[p.Name]`, which is `true` for every property.

Mendix publishes **both** shapes, in one document, decided by whether *some* or
*no* attributes are filterable:

```xml
<!-- DriverForm: some are. mxcli reads this correctly. -->
<Annotation Term="Org.OData.Capabilities.V1.FilterRestrictions"><Record>
  <PropertyValue Bool="true" Property="Filterable"/>
  <PropertyValue Property="NonFilterableProperties"><Collection>
    <PropertyPath>raceName</PropertyPath> …

<!-- Predictions: none are. mxcli ignores this. -->
<Annotation Term="Org.OData.Capabilities.V1.FilterRestrictions"><Record>
  <PropertyValue Bool="false" Property="Filterable"/>
</Record></Annotation>
```

Generating external entities from `F1OpsApi` gives **28 × CE6630** — "'message'
is marked Sortable=False in the OData service, but True in the app" — 20 on
Sortable, 8 on Filterable. The publisher is right, the contract is right, only
the generated consumer is wrong: exactly §42, one layer along.

Reproduction: point an OData client at `/odata/f1-ops/` and
`create external entities from` it. `Predictions` exposes only a KEY with no
`Filterable`, which is what makes Mendix emit the whole-set form.


## 49. The rebuild, actually run

§48 ended with a claim worth testing: every document in both apps is created by
a script, so `model/` is the source of truth. A name-by-name audit said 146 of
146, zero drift. That audit proves every document is *mentioned*. It does not
prove the scripts rebuild the app.

So both apps were dropped — all seven modules — and rebuilt from `model/`.

### What "identical" can mean here

Not a byte-identical `.mpr`. Mendix keys every document by UUID, so recreating a
module mints a fresh id for every entity, attribute, microflow and page;
`git diff mprcontents/` after a rebuild is thousands of files and proves nothing
in either direction.

`scripts/fingerprint.sh` compares meaning instead: every document round-tripped
through `DESCRIBE` (which emits MDL, not ids), the security matrix, the
settings, the navigation, and the published `$metadata` of all five services.
13,000 lines per side.

### The result

**All five `$metadata` documents are byte-identical.** The contract a consumer
binds to — entity types, keys, capabilities, the `ActionImport` — is exactly
reproduced. 71/71 backend and 23/23 frontend tests pass against the rebuilt
apps, `mx check` is clean on both, and the cached-service tests still assert
917 drivers and 27533 results, so the startup job repopulated tables that did
not exist ten minutes earlier.

166 lines differ, in three classes:

- **`@Position`** on entities the scripts do not place explicitly. Auto-placement
  follows creation order, so the domain-model canvas differs. Cosmetic, and a
  real if minor gap: an entity with no `@Position` does not round-trip its
  layout.
- **Listing order** in the inventory and security matrix — creation order again.
- **Stale `User` grants**, below.

### Three real defects, which is why the test was worth running

**1. The set does not run in one pass.** Each file owns its documents *and* the
grants on them, so grants are forward references across files: `02` grants to a
module role `06` creates, `06` grants execute on a microflow `10` owns, `13`
grants on a service `14` declares. `02 → 06 → 10 → 02` is a cycle, so no single
ordering exists. Two passes converge; the frontend needs three, because its page
scripts open each other's pages. The README claimed one pass. It now says two,
and names the clean fix (split `06` into roles-then-grants).

**2. `12-folders.mdl` referenced a microflow deleted in §48.** `Insert_Prediction`
went when the OData action replaced it, and the folder move for it stayed. This
never failed a build, because moving a document that does not exist is a no-op
on a model that already has the layout — it only fails on a rebuild, where the
error is the first sign the line is dead. Fixed, and `RecordPrediction` and
`AuthenticateApiClient` now get their folder.

**3. Grants in the `.mpr` that no script creates.** Seven pages and two
microflows were granted to the default `User` module role — left from an early
iteration, never written back. The rebuild dropped them. Nothing reachable
changed: the `User` user role exists but no demo user holds it, and `fan` is
`Enthusiast`. This is the §34 lesson recurring in the other direction. §34 found
documents that lived only in the `.mpr`; this found *access rules* that did.
A name audit cannot catch it — the documents were all present, only their grants
differed — which is precisely why a rebuild is worth more than an inventory.

### What it settles

`model/` does rebuild both apps, and the published contracts come back
identical. The residue outside MDL is unchanged and is what §48 listed: three
hand-written Java classes, two SCSS files, the data and schema scripts, and the
four cached `$metadata` contracts.


## 50. Idempotent in meaning, not in bytes — and one bug that accumulates

§49 proved the scripts rebuild the apps. A different question: re-run them on a
project that is already built, and is nothing supposed to change? For version
control the answer needs to be yes, and it is not.

### Two separate problems, and only one of them is cosmetic

**Every re-run rewrites 74 backend and 69 frontend documents with different
bytes.** Zero added, zero deleted — the documents keep their own ids, so this is
not the GUID churn a rebuild causes. Three consecutive re-runs, hashing the
`mprcontents` tree each time:

```
HEAD          e98b9c80d6a344e7
after run 1   33c2fcc2e4b97371   74 files differ from HEAD
after run 2   d90a1cd72a927895   74 files differ from HEAD
after run 3   38a3cdf48ed636b9   74 files differ from HEAD
```

The same 74 files, a different hash every time, and the semantic fingerprint
identical throughout. So the model does not change and the bytes never settle.

**The cause is sub-element ids.** A `create or modify` regenerates the internal
element id of everything inside the document it rewrites, while the document's
own id (its filename) is stable. The differing bytes fall into 965 contiguous
runs averaging 14.2 bytes, 806 of them between 10 and 16 — the signature of
16-byte UUIDs where some bytes happen to coincide.

The minimal reproduction is a constant:

```
create or modify constant Formula1Backend.DuckDbUser type string default 'mendix';
```

Re-declared identically against an unchanged project: **241 bytes on disk,
exactly 16 differ.** One UUID. The database connection is 139837 bytes and 13733
differ (~858 ids, one per query parameter and mapping); the domain model is
232855 bytes and 10074 differ (~630, one per attribute).

What it costs: `git diff` can never answer "did this script change anything",
two people running the same scripts commit different bytes, and a merge on a
`.mxunit` is not resolvable by hand. A model-as-code workflow needs re-running a
script to be a no-op in the repository, not just in the model.

### The one that is not cosmetic

**`create external entities from` duplicates any association whose name needed a
numeric suffix, on every run, without bound.**

An external entity's navigation property becomes an association named after it.
Three F1Cached entities have a `season` property — `Races`, `DriverStandings`,
`ConstructorStandings` — so Mendix names them `season`, `season_2`, `season_3`.
Correct, and that is the state after exactly one generation.

Re-run it and `circuit`, `constructor`, `driver` and `season` are matched and
left alone, but `season_2` and `season_3` are not: two more appear as `season_4`
and `season_5`. The dedup match is by association *name*, and the generator
computes a fresh suffix before it looks, so a suffixed association can never
match itself. Two per run, for ever:

```
one generation      season  season_2  season_3            (correct: 6 in F1Cached)
+1 re-run           …       season_4  season_5
+2 re-runs          …       season_6  season_7
```

This had been running since the project started. The pre-rebuild `.mpr` carried
`season_2` … `season_15` — twelve spurious associations, committed, invisible
in every `mx check` and every test, and visible in Studio Pro's domain model as
duplicate links. §49's rebuild cut it to four only because that rebuild happened
to run the script four times, and the fix in this section brought it to zero.

It also means the two-pass rebuild §49 documents is itself harmful:
`02-external-entities.mdl` must run exactly **once**, and the procedure now says
so.

### Repaired here

The frontend was rebuilt with `02` run once, giving the correct six F1Cached
associations. Dropping the extras by hand is not enough on its own — external
entity access rules reference them by association, so removing one leaves
CE1613 "The selected association no longer exists" behind, which is how the
over-deletion showed up.

23/23 frontend tests pass, `mx check` clean.


---

## 51. Building the design comp for real: five silent property drops and two expression traps

*Verified 2026-08-09/10, on `ako/mxcli` main @ `38a1137`, Mendix 11.13.0.*

The four screens were already on the comp's palette; what was missing was its
*arrangement* — chip rows, banner cards with the numbers inline, a colour-coded
result strip, in-table bars, side-by-side charts, tinted highlight cards. None
of that is exotic, and almost all of it went in cleanly. What did not is
recorded here, because every one of these cost a build-and-look cycle and none
of them said anything at write time.

### The five silent drops

Each of these parses, passes `mxcli check` with no MDL-WIDGET07 warning, writes
without error, and is simply not in the model afterwards.

| Written | What happens |
|---|---|
| `LISTVIEW … (datasource: database from E **sort by** a desc)` | the entity is kept, the sort is dropped. A GALLERY keeps it. |
| `LISTVIEW … (**PageSize**: 40)` | honoured — but `describe page` never prints it back, so a round-trip looks like it was dropped |
| `LISTVIEW … (**OnClick**: …)` | dropped. The same property on a CONTAINER inside the list view works. |
| `GALLERY … (**PageSize**: 20)` | dropped |
| chart-level `**CustomLayout**` / `**CustomConfigurations**` (capitalised) | dropped. The exact lowercase property key — `customLayout` — is kept. |

The last is the sharpest. Series-level properties are matched
case-insensitively (`StaticBarColor`, `CustomSeriesOptions` both land), so the
same document can have one property honoured and its sibling silently discarded
purely on the capital letter. That produced a chart with per-series colours and
no axis configuration, which reads as "custom layout is not supported" rather
than "you spelled it wrong".

**Suggestion:** MDL-WIDGET07 already exists to catch an unrecognised property on
a built-in widget. It did not fire for any of the five. Whatever path drops
these should route through the same warning; a property that is parsed, not
persisted, and not reported is the worst of the three outcomes.

`LISTVIEW`'s `PageSize` deserves its own note: the writer honours it (there is a
test guarding exactly that, `TestBuildListViewV3_PageSize`), but `describe page`
omits it, so the round-trip that this repo uses to verify every other change
cannot see it. The default is 20, which means a 24-round season silently ends in
a "Load more" button — a truncation that looks like a design decision.

### Two expression traps, both silent until `mx check`

**Division is `div`, and `div` is not integer division.** `$a / $b` is CE0117
"Error(s) in expression" for any operand types — Decimal by Decimal included.
Mendix's operator is `div`, and unlike Pascal's it does not floor: `77 div 5`
is 15.4. A first attempt bucketed a percentage into 5% steps with
`x div 5 * 5`, which returned the input unchanged.

That mattered more than it should have, because the bucket named a CSS class.
`w-77` where only `w-75` and `w-80` exist is not a missing rule, it is *no width
rule*, and a fill with no width fills its track — every bar in the table drew at
100%. A wrong reading, not a missing one. The page now carries one rule per
whole percent and does no arithmetic at all.

**There is no cast from Decimal to Long.** `round(x)` is not a function either
(it is `round(value, precision)`), and even `round(x, 0)` is a Decimal, so
assigning it to a Long attribute is CE0117. What works:

```
set $Pct   = $Points div $Best * 100.0;
set $Share = parseInteger(formatDecimal($Pct, '0'));
```

**Also:** `not contains(…)` does not parse; `contains(…) = false` does.

### A comparison against `empty` throws, in the browser, at render

Not a parse error and not a build error — `mx check` reports 0 errors and the
page renders until the first row where the attribute is unset:

```
[Client] An error occurred while evaluating dynamic classes of
Formula1Frontend.Driver_Career.stripCell:
Operator > not supported in expression >(, 0)
```

`$currentObject/points > 0` is fine for every driver who scored and throws for
one who did not, and Mendix surfaces it as a modal that then swallows every
later click. Two of these shipped in one afternoon — a strip cell keyed on
points, a table cell keyed on positions gained — and both were found only by
driving the running app, because the data that triggers them is the exception
row. Every branch of a `dynamicclasses` or `DynamicCellClass` expression over a
nullable number now tests `= empty` before it compares.

This is the strongest argument in this file for the Playwright pass: `check`,
`mx check`, the build and the log were all clean, and the page was broken.

### Refreshing an external entity after the service grows a column

This is the workflow gap, not a bug in one command. The backend gained two
attributes on an existing resource. To get them into the frontend:

- `create external entities from` **skips** an entity that already exists;
- `create or **modify** external entities from` reports "10 updated" and adds
  nothing — the new attribute does not appear;
- `create or modify odata client` with a changed `MetadataUrl` re-reads
  nothing: `describe contract entity` still shows the old property list.

The cached contract inside the `.mpr` is only ever populated when the client is
*created*. The working sequence is therefore destructive:

```
drop odata client Mod.Client;
create or modify odata client Mod.Client (…);        -- caches $metadata afresh
create or modify external entities from Mod.Client into Mod;
<re-run the security script>                          -- grants do not survive
```

`mx check` is clean afterwards and the pages keep working — the entities are
rebound in place rather than duplicated — but every entity access rule on the
module is gone and has to be re-applied. On a real project that is a foot-gun.

**Suggestion:** either make `create or modify odata client` re-read the metadata
URL, or add an explicit `REFRESH ODATA CLIENT Mod.Client` that re-caches the
contract without dropping anything.

Trying to sidestep it by hand does not work either. `alter entity … add
attribute` adds the attribute but not its remote-name mapping (CE6612
"Attribute … of external entity … is not supported"), and the explicit
`create or modify external entity … from odata client … (EntitySet: …,
RemoteName: …)` form loses the contract binding entirely (CE6611 "External
entity … is not defined in OData service", plus one CE6612 per attribute). Both
were tried and reverted.

### What the widgets can do that was not obvious

Two things worth writing down because they turned "Mendix cannot draw this" into
"Mendix can draw this":

**There is no combination chart, but there is a combination.** A Column chart
series takes raw Plotly trace JSON in `customSeriesOptions`, and the chart takes
raw layout JSON in `customLayout`. So a second series declared as
`{"type":"scatter","mode":"lines+markers","yaxis":"y2",…}` against a
`{"yaxis2":{"overlaying":"y","side":"right","autorange":"reversed"}}` layout is
bars and a reversed line on one plot. The same two hooks give a scatter (a Line
chart with `lineStyle: 'custom'` and `{"mode":"markers"}`), a step line
(`{"line":{"shape":"hv"}}`) and a parity reference line (a layout `shapes`
entry). Every colour in those strings is a literal, because Plotly reads no CSS
variable — that is the one place in this app where a colour lives in the model.

**A data-driven bar needs no widget.** `style:` on a page widget is a literal,
so a width cannot be computed — but `dynamicclasses` can compute a *class name*,
and a hundred and one `.w-N { width: N% }` rules turn a 0–100 attribute into a
bar. Two nested containers, no third-party widget, and the DOM stays yours. The
Progress Bar widget was the obvious choice and is the wrong one: its dynamic
mode wants an attribute for the minimum as well as the maximum, and there is no
zero column to bind.

### Two more chart facts, both found by asking why the page looked wrong

**A series' legend label cannot carry data.** Every text template on a chart
series is bound to the series' datasource except one: `staticName`, which the
widget definition gives no `dataSource` at all. So five lines over a season's
progression can be labelled "1st".."5th" and nothing else — a driver's name is
not available to the legend, and there is no arrangement of parameters that
makes it so. `staticTooltipHoverText` *is* bound, so the name can be in the
hover; the names now also print under the chart as a strip that reads the same
resource, against the same five colours declared on both sides.

**A static series' bar colour is one colour.** `staticBarColor` is an
expression bound to the series' datasource, which reads as "evaluated per bar"
and is not: it resolves once, against the first row, and a ten-team
constructors' chart came out entirely in the leader's orange. Per-bar colour
needs a **dynamic** series — `dataSet: 'dynamic'` with `groupByAttribute`, so
each group is its own trace and a trace has its own colour. Same data, same
resource, one property different.

### Layout notes that are Mendix, not CSS

- A data view renders a wrapper div and puts its children one level down, so a
  grid declared on the data view lays out *one* item. `> .mx-dataview-content
  { display: contents }` takes the wrapper out of layout and the children become
  the grid's own items. This is the fix for every "my cards came back stacked".
- Atlas pads a list view's `<li>` by 16px through `.mx-listview > ul > li`, so a
  reset needs that depth or the padding survives.
- `repeat(auto-fit, …)` cannot count inside a flex item — the available width is
  indefinite, so it resolves to one track. `grid-auto-flow: column` with
  `grid-auto-columns` is what a variable-length stat row actually wants.
- A data grid's `ColumnWidth: manual` + `Size: n` is a *weight*, not pixels.
  `Size: 230` against eleven unset columns gave the one column 95% of the table
  and squeezed every caption to an ellipsis.
- The content region has **no padding of its own**. Atlas leaves the gutter to
  the page template, and a page built from bare containers therefore starts
  hard against the nav rail on the left and the window edge on the right. The
  padding belongs on `.region-content > .mx-scrollcontainer-wrapper >
  .mx-placeholder` and not on the region, which is also the scroll container —
  padding there scrolls the right-hand gutter away.

## 52. PR 125 verified: re-running the scripts is now a no-op in the repository

*Verified 2026-08-11 against `ako/mxcli` PR 125, head `9ab9afa`, built from
source. This closes open issue 2 (§50) — the one where a re-run rewrote 143
documents with different bytes and never settled.*

### What the PR does

Before writing a unit, mxcli compares the new document against the stored one in
**canonical form**: every element `$ID` replaced by its index in a deterministic
containment walk. If they match, the write is skipped. Byte comparison would
skip nothing, because a rebuild mints a fresh random `$ID` per sub-element —
which is exactly the churn §50 measured. A microflow's `StableId` is carried
from the stored document rather than re-minted, since the build derives every
client-callable microflow's operation id from it.

`MXCLI_ALWAYS_WRITE=1` disables the skipping (not the identity preservation) for
bisecting, which is what makes the measurement below falsifiable.

### Build the right binary, or measure nothing

The first round of measurements here was worthless and it took a while to notice.
`scripts/build-mxcli.sh` takes `MXCLI_REF` and defaults it to `main`, then does
`git fetch --depth 1 origin "$REF"` and `git checkout -q FETCH_HEAD` **inside
`.mxcli-src`** — so a manual `git checkout pr-125` in that directory is silently
clobbered before the build. Every number that round was `main` with no elision
code in it, and it looked exactly like "the PR does not work": 73 files changed
on both runs, `MXCLI_ALWAYS_WRITE=1` made no difference. The tell was that
`modelsdk/canon/` did not exist in the source tree.

```sh
MXCLI_FORCE=1 MXCLI_REF=pull/125/head sh scripts/build-mxcli.sh
```

Worth stating generally: **before measuring a feature flag, prove the feature is
compiled in.** Here that meant finding `modelsdk/canon/{canon,identity}.go` on
disk and `MXCLI_ALWAYS_WRITE` read at `identity.go:60`. A control run that
behaves identically with and without the flag does not mean the flag is broken —
it can equally mean neither path exists.

### The measurements

The minimal case from §50, one constant re-declared identically:

| | `38a1137` (main) | `9ab9afa` (PR 125) |
|---|---|---|
| run 1 | 2 files | **0** |
| run 2 | 2 files | **0** |
| run 3 | 2 files | **0** |

The full re-runnable script set — 12 backend scripts, 8 frontend — starting from
a clean tree. Excluded as one-shot *by construction*, each verified to halt on a
second run rather than churn: `00-dependencies.mdl` (`ADD JAR DEPENDENCY`),
`03-persistent-entities.mdl` ("entity already exists"), `07-demo-users.mdl` and
frontend `06-demo-user.mdl` ("demo user already exists: fan"), and frontend
`02-external-entities.mdl` (the association-duplication bug, issue 1).

```
              pass 1 vs HEAD   pass 2 vs pass 1   pass 3 vs pass 2
backend        2 files            0                  0
frontend       5 files            0                  -
```

Zero. Not "the same files with different bytes" — the same bytes. §50's three
different tree hashes from three identical runs are gone.

### The control, which is the part that proves anything

A test asserting "nothing changed" passes just as well against a build where
nothing runs. So the same backend set, same converged tree, with the elision
switched off and then on again:

```
MXCLI_ALWAYS_WRITE=1   72 units changed bytes
normal run after it     0 units changed bytes
```

72 is §50's number back again, so the probe can see a failure. And the second
line is the stronger result: after every `$ID` in 72 documents had been
re-minted, the next normal run recognised all 72 as equal and wrote none of
them. That is canonical comparison working, not byte comparison getting lucky.

### The 7 files that did change, and why they are the good news

Both apps had drift between the scripts and the committed model, which the old
behaviour made invisible — when every re-run rewrites 143 documents, a real
change is one needle in that haystack.

- **`Read_TeamSeason` (+4,340 bytes).** The script at HEAD declares a `$Round`
  pushdown and a `$Round != 0` branch; the committed `.mxunit` has neither. Both
  were committed in `bd03f44` — the script was edited after the last run and
  never re-executed, so the model has been one activity behind its source for a
  day.
- **Four `Rest$ConsumedODataService` units (−48 bytes each).** `MetadataUrl` was
  stored as `file:///home/user/mxcli-formula1/Formula1Frontend/contracts/…` and
  is now the `./contracts/…` the script actually says. An older build
  absolutized it; the current one stores it verbatim. Exactly 48 bytes of
  absolute host path per client, gone from a committed model.

Both are one-time convergences: reset to HEAD, run the set once, and the same 7
files appear — deterministically, and never an eighth. `mx check` reports **0
errors** on both apps afterwards.

### What this changes about working here

`git status` becomes a real answer to "is the model in sync with the scripts?".
That question had no cheap answer before — §50's whole point was that the diff
was noise, so the honest workflow was to regenerate and trust the semantic
fingerprint. Now a clean tree after a re-run *means* something, and a dirty one
points at the drift instead of burying it. The `Read_TeamSeason` gap above was
found by exactly that, on the first pass, without looking for it.

The corollary for `model/README.md`'s "Re-running is not free": re-running is
now free in the repository. It still is not free in *time* — the scripts still
execute, still parse, still compare — and the one-shot scripts still halt rather
than no-op, which is a separate and still-open shape of the same problem.

## 53. An MCP chat feature: buildable, and the install path collapses MPR v2

*Investigated 2026-08-11 on Mendix 11.13.0. The question was whether a fan-facing
chat over F1 data could be built with a **Mendix MCP server on the backend and a
Mendix MCP client on the frontend**. It can, entirely from supported components.
Getting them installed is where it goes wrong.*

### Both halves ship as Mendix modules

Agents Kit 2 covers exactly the split proposed. Everything below installed
against this project and reached `mx check` **0 errors on both apps**.

| Where | Module | Version | Min Mendix |
|---|---|---|---|
| Backend | MCP Server | 5.1.0 | 11.12.1 |
| Frontend | MCP Client | 4.1.1 | 11.12.2 |
| Frontend | GenAI Commons | 7.2.0 | 11.12.2 |
| Frontend | Conversational UI | 7.2.0 | 11.12.2 |
| Frontend | OpenAI Connector | 9.2.0 | 11.12.2 |

The server exposes microflows as tools — inputs are primitives or `MCPServer.Tool`
objects, the return must be `String` or `TextContent`, and an optional auth
microflow takes `System.HttpRequest` and returns a `System.User`, so ordinary
entity access still applies. Both modules speak `v2025-03-26` over streamable
HTTP, so they interoperate; the client also speaks `v2024-11-05`. `Request: Add
all tools from MCP server` hands discovered tools straight to a chat-completions
call, so there is no glue to write between MCP and the LLM.

**Three dependencies are not in that table and not in the docs**, and each one is
found only by installing and reading the errors: `CommunityCommons` (11.5.1),
`AgentCommons` (4.2.0) and `Encryption` (11.1.1), plus the `Markdown viewer`
(1.0.3) and `Events` (1.3.1) widgets. The error count does not decrease
monotonically while you chase them — 156 → 16 → **227** → 211 → 1 → 0 — because
resolving a broken reference makes a previously unreachable document checkable.
An install that resolved its own dependency graph would remove the whole
exercise.

### The headline: `mx module-import` rewrites MPR v2 as v1

One import, on a pristine worktree checked out at HEAD, nothing else run:

```
before   .mpr     94,208 bytes  +  466 .mxunit files
after    .mpr 16,019,456 bytes  +    0 .mxunit files
```

The `mprcontents/` tree is gone and the whole model is a single SQLite blob. The
frontend went the same way at 46 MB. Attribution is clean: the backend received
**only** `mx module-import` — no `update-widgets`, no `rename-design-properties`
— and collapsed identically.

The `_MetaData` row shows the format change directly. v2 carries a leading format
version and a `_Transaction` table; v1 has neither:

```
v2   (2, '11.13.0', '11.13.0', '{SHA256}5Fk3…')      tables: _MetaData, Unit, _Transaction
v1   (   '11.13.0', '11.13.0', '{SHA256}5Fk3…', 0)   tables: _MetaData, Unit
```

This is not cosmetic. It takes out the diffable model, the idempotent-re-run
property §52 had just established, `mxcli diff-local`, and any hope of merging
`.mxunit` files. Nothing in the Mendix documentation mentions it, `mx convert`
only targets *Mendix versions* rather than storage format, and mxcli has no
convert command — so there is no way back that we found. **Any headless
module-install path has to either preserve v2 or refuse.**

### Mendix ships its own chat UI flagged as a theme module

`mx module-import` rejects Conversational UI outright:

```
Importing theme module is not supported          (exit 112 = param error, arg 1, "is Theme module")
```

The package disagrees with the refusal — `manifest.json` says `"type": "Module"`.
Deleting all 50 `themesource/` entries did not help; nor did also stripping their
44 references from `package.xml` and `manifest.json`. The gate is a single BSON
boolean on the module document itself:

```
Projects$ModuleImpl → IsThemeModule = true
```

Flipping that one byte to `false` and re-importing the otherwise **identical**
package — theme files included — imports cleanly and checks clean. So the flag is
the sole cause, and the only Mendix-supplied chat UI for Agents Kit 2 cannot be
installed by any headless path. Studio Pro is required, which for a CLI-driven
project means the model can no longer be rebuilt from `model/*.mdl`.

### CE0463 × 210 after installing widgets is a false alarm

Installing the two widgets produced 210 × CE0463 "widget definition changed" —
the error whose usual diagnosis is a malformed template. Here it means only that
the project's stored widget type definitions have not been resynced. Two commands
clear it, and both are `mx` verbs with no mxcli equivalent:

```
mx update-widgets <project.mpr>              210 CE0463 → 1
mx rename-design-properties <project.mpr>    renamed 158 design properties across 44 documents → 0
```

Worth knowing before anyone spends a day in `diagnose-ce0463.md`: **after any
headless widget install, run `update-widgets` before believing the error list.**

### OpenRouter works without a custom connector

The OpenAI Connector's Configuration entity has an `Endpoint` field, and
OpenRouter is OpenAI-compatible: a `POST /api/v1/chat/completions` carrying a
`tools` array returns **401, not 404**. So pointing the stock connector at
`https://openrouter.ai/api/v1` should be a URL and a key, with duplicating the
connector as the documented fallback.

Tool-calling is the constraint that matters, since an MCP agent without it is
just a chatbot. Of OpenRouter's 405 models, 18 are free and **15 of those
advertise `tools`** — `openai/gpt-oss-20b:free` (131k), `google/gemma-4-31b-it:free`
(262k), `nvidia/nemotron-3-ultra-550b-a55b:free` (1M). Free-tier reliability at
chaining tool calls is another question, and the tier is rate-limited.

### Two mxcli gaps in the agent doctypes

- **`CREATE MODEL` can only author one provider.** `agenteditor_write.go:70` and
  `:90` both assign `m.Provider = "MxCloudGenAI"` unconditionally, and the
  grammar comment offers no alternative. Agents Kit 2 supports OpenAI, Bedrock,
  Gemini, Mistral and Mendix Cloud GenAI; MDL can express one of the five. Any
  project not on Mendix Cloud GenAI cannot author its model document as code.
- **The agent doctypes are absent from the version registry.** `show features` on
  11.13.0 lists nothing for agents or MCP, so there is no `checkFeature()` gate
  and no actionable error on an older project — even though `mxcli syntax agents`
  documents the requirement as "AgentEditorCommons, Mendix 11.9+".

## 54. The pushdown module as a skill pack: everything fits except the Java

*Investigated 2026-08-16 on mxcli `a8dc083` (main). The question was whether the
`ODataPushdown` module — four Java actions and 882 lines of parser — can become
one of the new skill packs. It can, and mxcli's own proposal already asks for it
by name. One manifest target is missing and it is the one this module needs.*

### The proposal names this module

`docs/11-proposals/PROPOSAL_skill_packs.md` (status `partial`) lists the two
packs it was built for, then:

> A third is wanted (`mendix-odata-pushdown`, Java actions that push `$filter` /
> `$orderby` / `$top` / `$skip` into database-connector SQL) and there will be
> more.

The module was already built to travel — "nothing in it is Formula 1, or DuckDB,
or the app it was extracted from" — and that holds up under grep: the only
`duckdb` mentions are as one of five dialects, and `Formula 1` appears once, in
the sentence saying nothing in it is Formula 1. The pieces map onto the pack
layout with no rework:

| Module | Pack slot |
|---|---|
| `module.mdl`, 272 lines | `mdl/` + `installs.mdl` — the `mendix-bulk-oql-dml` shape exactly |
| `README.md` | `SKILL.md` + `references/*.md` |
| the four Java actions | already `CREATE JAVA ACTION … AS $$ … $$`, which mxcli writes out itself |

### The one thing that does not fit

Every action body is a two-line delegation:

```
AS $$
return odatapushdown.QueryObject.parse(getContext(), Uri, Columns, Dialect, …);
$$;
```

The work is in three helper classes — `ODataQueryParser` (633 lines),
`RoutineCall` (185), `QueryObject` (64) — that MDL cannot author and a pack
cannot deliver. Three independent mechanisms say so, and they were checked
separately rather than inferred from one another:

1. **`Installs` has exactly two fields.** `cmd/mxcli/skillpack/skillpack.go`:
   `Widgets []string`, `MDL []string`.
2. **Pack files land inside the skills directory.** `Install` writes to
   `destDir/<pack-name>/`. Verified rather than read: installing
   `mendix-bulk-oql-dml` into an empty directory put all five files under
   `.claude/skills/mendix-bulk-oql-dml/` and nothing outside it.
3. **MDL has no standalone-class form.** `createJavaActionStatement` in
   `MDLMicroflow.g4` accepts `AS DOLLAR_STRING` and nothing else — a *method
   body*, with no class declaration and no imports clause.

So a pack today ships the prose and the MDL, and the reader still copies a
directory by hand — which is **exactly what this module's README already tells
them to do**. A pack that reproduces the manual step is not an improvement over
the README, and that is the sharpest statement of the gap.

### The fix is one target, and the discipline already exists

```yaml
installs:
  java:
    - java          # -> javasource/<module_path>/, preserving actions/
```

What makes this more than a file copy is that it needs the *same* treatment the
widget path already has, for the same reason. A widget id is its identity, so
the source ships with `{{NAMESPACE}}` and `skill add` substitutes the
destination project's. **A Java `package` declaration is the exact analogue** —
two projects whose classes share a package are two projects claiming the same
class — so all three of the proposal's properties transfer unchanged: placeholders
rather than a real namespace (an unsubstituted token fails to compile, loudly,
where a harvested name ships silently), a whitelist rather than a scan, and drift
in either direction refusing the install.

One branch worth deciding rather than defaulting into: `java/actions/` is worth
shipping for review, but on `--apply` mxcli generates those four classes from the
MDL, so writing both means overwriting the pack's copy immediately.

Both alternatives are worse. **Inlining** the helpers into the action bodies
means duplicating 882 lines four times, because Java local classes cannot be
shared between methods; the one-fat-action-plus-microflow-wrappers variant avoids
the duplication by distorting the public API to fit the packaging. **Shipping the
`.java` as inert assets** with a copy step in `SKILL.md` works today and is what
the drafted pack does meanwhile, but gets none of the three things that make a
pack better than a tarball: no pruning when v2 drops a file, no digest fence
refusing a locally-edited one, no namespace rewrite.

### The pack, drafted and validated

`.claude/skills/packs/mendix-odata-pushdown/` — 13 files, laid out to mirror the
mxcli repo's own `packs/` directory so it lifts across unchanged. `pack.yaml`
declares `installs.java` as a *proposed* target, commented as not-yet-implemented
rather than quietly assumed to work.

Three checks, because a pack that has not been round-tripped is a pack that has
not been tested:

- **The MDL round-trips exactly.** Substituting `{{MODULE}}` / `{{MODULE_PATH}}`
  back to this project's names reproduces `model/odatapushdown/module.mdl`
  byte-for-byte apart from the install block, which was rewritten on purpose.
- **All seven `.java` files round-trip byte-identical.**
- **`mxcli check` passes** on the substituted MDL — 8 statements, syntax OK.
- The manifest's own invariants hold both ways: every file in `rewrite.files`
  exists and carries a token, and every tokenised file the pack ships is
  declared.

### One more thing, which the proposal already flags

> A pack whose own verifier is not run in CI is a pack that rots.

This pack wants a `verify:` more than the other two. It is 882 lines of parser
across five dialects, and it has a genuinely cheap test surface:
`ODataQueryParser` takes no Mendix types in its signature, so it runs under
`jshell` or plain JUnit with no runtime around it — which is how the grammar was
established term by term in §45. A dialect regression there is invisible to
`mx check` and to every test that needs an app.

## 55. Running the solution in a devcontainer: four host assumptions mxcli makes

*Verified 2026-08-12, on `ako/mxcli` main @ `d53691b`, Mendix 11.13.0, Debian
bookworm, **linux/arm64**, inside a Docker devcontainer. First entry here not run
as root and not on amd64 — three of the four findings below are consequences of
exactly that.*

**Intent.** Make a fresh clone runnable by anyone with Docker and nothing else,
and drive it from Claude Code Desktop, whose environment dropdown offers Local,
Cloud, SSH and WSL — SSH being the only one that reaches inside a container.
One container, not one per app: the two apps address each other as
`backend.local` / `frontend.local` on `127.0.0.1`, so splitting them across a
compose network would mean rewriting those names and the `ServiceUrl` constants.

**What was built.** A root `.devcontainer/` — Dockerfile, `devcontainer.json`,
`post-create.sh`, `post-start.sh`, `authorize-ssh-key.sh`, README. It supplies
what `.claude/bootstrap-mxcli.sh` already assumes is present and otherwise stays
out of its way; the bootstrap is not duplicated.

**Outcome.** Both apps boot and serve — backend 200, frontend 200, `/xas/` 401,
27533 race results counted live off the CSVs, 917 drivers, `$top`/`$skip`/
`$filter` all pushed down. It took four workarounds to get there. Three are in
`.devcontainer/` and should not have to be.

### 55.1 `--ensure-db` shells out to `sudo -u postgres` and dies misleadingly

```
Ensuring database...
  Creating role "mendix"...
Error: ensuring database: creating role "mendix": exit status 1
sudo: a terminal is required to read the password; either use the -S option to
      read from standard input or configure an askpass helper
sudo: a password is required
```

The diagnosis this invites — "sudo is misconfigured" — is wrong. `sudo` *is*
passwordless: `sudo -n true` succeeds. The devcontainer base image grants
`vscode ALL=(root) NOPASSWD:ALL`, which is passwordless only when the target
user is **root**. `sudo -u postgres` targets somebody else, so it falls through
to a password prompt, and with no tty it fails. Widening the rule to
`(ALL)` fixes it, which is what `post-create.sh` now does.

Two things follow. First, the role already existed — `post-create.sh` had
created it — and mxcli still announced "Creating role"; once sudo worked, the
same command correctly reported only `Creating database "formula1backend" owned
by "mendix"`. So the existence check itself runs through the sudo path and its
failure is indistinguishable from "absent". Second, this is not only mxcli's
problem: `scripts/create-f1ops-db.sh` uses `sudo -u postgres psql` in five
places and the README's session-clearing command uses it too. All three break
identically on a stock devcontainer.

**Requirement.** Try the configured connection first — `--db-host/--db-user/
--db-password` are already flags — and only fall back to `sudo -u postgres`
when a TCP connection cannot be made. A container with trust auth on loopback,
which is the normal devcontainer shape, then needs no sudo at all.

**Requirement.** When the sudo path does run and fails, say which target user
was refused and that the rule may be `(root)`-only. The current message
describes the mechanism and not the cause.

### 55.2 The runtime binds `127.0.0.1` and nothing can change it

`mxcli run --local` reports `app serving at http://127.0.0.1:8080/`, and that is
literal:

```
LISTEN 0  50  [::ffff:127.0.0.1]:8080  *:*
LISTEN 0  50  [::ffff:127.0.0.1]:8090  *:*
LISTEN 0  500          127.0.0.1:6543  0.0.0.0:*
```

Docker publishes a port to the container's **eth0**, never to its loopback. So
with `-p 127.0.0.1:8080:8080` the app answers 200 from inside the container and
refuses the connection from the host. `mxcli run --help` has no `--bind`,
`--listen` or `--host` flag; `--db-host` is the only address flag and it points
the other way.

The workaround is a `socat` forwarder per port, bound to eth0's address
specifically — binding `0.0.0.0:8080` collides with the runtime's own
`127.0.0.1:8080`. `post-start.sh` starts six of them.

VS Code's `forwardPorts` would mask this, because its forwarder runs inside the
container and dials loopback. That is worth knowing when reading bug reports:
the same config works under VS Code and fails under `devcontainer exec`, a
desktop SSH session, or a plain `docker start`.

**Requirement.** `mxcli run --bind <addr>` (default `127.0.0.1`, so nothing
changes for existing users), passed through to the runtime's listen address.
Anything containerised, any remote dev box, and any published preview needs it.

### 55.3 `--runtime-setting MicroflowConstants` replaces the map instead of merging

The obvious way to make a model portable is to override one constant at boot:

```
--runtime-setting "MicroflowConstants={\"Formula1Backend.DataDir\":\"/workspaces/…\"}"
```

That boots further and then dies:

```
Could not find value for constant 'Formula1Backend.ApiKey'.
Input '$Presented != @Formula1Backend.ApiKey' could not be parsed
ERROR - Module: An error occurred while initializing modules
```

`MicroflowConstants` is one setting whose value is the whole map, so supplying
one key drops the other nine — including the ones the custom-auth microflow and
the two JDBC connections need. Overriding one constant means restating all ten,
on every `mxcli run`, every `mxcli test`, and in every documented example. The
`--runtime-setting` help says values are "merged into the boot configuration",
which is true of the settings map and not of this setting's contents.

**Requirement.** `mxcli run --constant Module.Name=value` (repeatable), folded
into `MicroflowConstants` on top of the model defaults rather than replacing
them. This is the single highest-value item here: it is what makes a `.mpr`
runnable in an environment other than the one it was authored in, and §55.5
below is a direct consequence of its absence.

### 55.4 `mxcli init` writes a per-app devcontainer; a solution needs one

`Formula1Backend/.devcontainer/` and `Formula1Frontend/.devcontainer/` were both
generated by `init`. Neither is usable here. Each covers one app, and each
`postCreateCommand` downloads a prebuilt `mendixlabs/mxcli` — while this repo
deliberately builds `ako/mxcli` main from source, and the root
`.claude/settings.json` is what Claude Code actually reads. The same asymmetry
§4 records for the bootstrap hook: root wins, and the generated per-app copies are
dead weight that reads like configuration.

The generated Dockerfile is also short of what its own repo needs — no Go, no
`python3`/`pip`, no Postgres **server** (only `postgresql-client`), so
`scripts/build-mxcli.sh` and `--ensure-db` both fail in it.

**Requirement.** When `init` runs in a directory holding more than one `.mpr`,
generate one `.devcontainer/` at the root covering every app — ports offset per
app, one Postgres, hostnames via `--add-host` — rather than one per app. Ship
the toolchain the project's own scripts need, not only the runtime's.

**Requirement.** Do not write a per-app `.devcontainer/` that a root-level one
will shadow, for the same reason `init` should not write a per-app
`.claude/settings.json` that a root one shadows.

### 55.5 The documented source build breaks on PEP 668

`scripts/build-mxcli.sh` does a bare `pip install 'antlr4-tools==0.2.2'`, which
Debian bookworm refuses: the system interpreter is marked externally-managed, so
pip exits rather than installing. §1 already records that the documented build
path stops short on the ANTLR version; on any modern distro it now stops short
one step earlier. The Dockerfile pre-installs the package with
`--break-system-packages` so the script's `command -v antlr4` guard
short-circuits and that branch never runs.

**Requirement.** `pip install --user` with a venv fallback, or state the
`--break-system-packages` requirement in the build instructions. Anything that
tells a new contributor to run `pip install` on a 2024-or-later distro is
telling them to hit this.

### Not mxcli: two things this repo owns

**`Formula1Backend.DataDir` is not portable.** It defaults to
`/home/user/mxcli-formula1/data/f1db` — the absolute path of the environment
this repo was first built in — and the backend fails its after-startup action
anywhere else:

```
ERROR - ExternalDatabaseConnector: IO Error: No files found that match the
        pattern "/home/user/mxcli-formula1/data/f1db/f1db-seasons.csv"
```

The README describes `ServiceUrl` as "a constant, not a literal, so the address
is environment-overridable". `DataDir` is a constant too, but with §55.3 open
nothing can override it, so in practice it is not. The workaround is a symlink
in `post-create.sh`; it also covers `data/facts/` and `data/laps/`, which
`DataDir` does not point at and which are reached by their own hardcoded paths.
The real fix is in the model: default `DataDir` relative to the project
directory, and give facts and laps constants of their own.

**`/$count` as a path segment returns `-1` on the live services.** The query
option is right and the path segment is not:

```
/odata/f1-live/RaceResults?$count=true   -> @odata.count = 27533   correct
/odata/f1-live/RaceResults/$count        -> -1
/odata/f1/RaceResults/$count             -> 27533                  (cached, Mendix's own)
```

§37 records that a resource has two ways to be asked for one row and that both
must be answered; this is the same shape one level along — two ways to be asked
for a count, and `ODataPushdown` answers one. `-1` is worse than a 501, because
a client cannot tell it from an answer.

### Summary for whoever productises this

| # | Requirement | Blocks | Size |
|---|---|---|---|
| 55.3 | `--constant Module.Name=value`, merged over model defaults | any `.mpr` running outside its authoring environment | small |
| 55.2 | `--bind <addr>` on `mxcli run` | containers, remote dev boxes, published previews | small |
| 55.1 | try TCP before `sudo -u postgres`; name the refused target on failure | `--ensure-db` on any non-root host | small |
| 55.4 | solution-level `.devcontainer/` from `init`, with the project's toolchain | multi-app repos | medium |
| 55.5 | PEP 668-safe `pip install` in the documented build | new contributors on any 2024+ distro | trivial |

None of these needed a change to the model, the theme, or MDL. They are all
about the gap between "mxcli runs the app on the machine that authored it" and
"mxcli runs the app somewhere else", which is the same gap a CI job, a cloud
preview and a teammate's laptop all sit in.

## 56. Every chart onto Vega: long format closes three §51 limitations

*Done 2026-08-16 on mxcli `a8dc083` (main), which ships skill packs that can
carry a pluggable widget. All ten charts in the app moved from the Mendix chart
widgets to `mendix-vega-charts`. `mx check` 0 errors, MPR v2 intact, verified in
a browser on all four pages.*

### The gate, and why it nearly stopped this

`mx update-widgets` is the command you normally run after a headless widget
install. On a pristine worktree checked out at HEAD, nothing else run:

```
before   .mpr     86,016 bytes  +  469 .mxunit files
after    .mpr 19,587,072 bytes  +    0 .mxunit files
```

The same v2 → v1 collapse §53 measured for `mx module-import`, from a second
command, and this one sits on the only documented path for installing a widget
without Studio Pro.

**`mxcli widget init` does not do this.** 86,016 bytes and 469 units before and
after, and it registers the widget definition — which is what the pack's install
guide actually tells you to run. That is the whole reason this migration was
possible at all with the model still diffable.

### A correction to §53

Open issue 19 said there is *no mxcli equivalent for `update-widgets`*. That is
wrong: `mxcli widget sync` exists, and its own `--help` is franker about the
problem than this document was —

> PARTIAL — this does not yet fully replace "Update all widgets". On the
> reference fixture it clears 7 of 40 CE0463 errors; Mendix's own
> `mx update-widgets` clears all 40 but **destroys the `mprcontents/` folder on
> MPR v2 projects**, which this does not.

So upstream already knew about the v2 destruction and had already started the
replacement. The issue is not "no equivalent" but "the equivalent covers 7 of
40". Corrected in the list below. Worth stating plainly because the wrong
version pointed the fix at the wrong place.

### What long format bought

The widget takes a spec plus a JSON array in a string attribute. Ten `DSJ_`
microflows emit long format — one row per (x, series, value) — onto a
non-persistent `Formula1Frontend.Chart`, and each chart is a data view over one.
All three of §51's chart limitations fall out of that shape rather than being
worked around:

| §51 said | Long format |
|---|---|
| A legend cannot carry data — `StaticName` is the one series text template not bound to the series datasource | The label is a column. Legends read *Denny Hulme, Jack Brabham, Jim Clark*, and *Lewis Hamilton / Charles Leclerc* instead of "1st".."5th" and "Seat 1"/"Seat 2" |
| Per-bar colour needs a **dynamic** series, because `StaticBarColor` resolves once against the first row | The colour is a column and the scale reads it (`"scale": null`) |
| A wide resource costs one datasource call per series | One call per chart |

The third is the measurable one. `WeekendShape` and `LapChart` are ten series
each and were fetched **ten times each**; the pace chart five. **38 datasource
invocations across ten charts become 10 microflow calls** — most of the 28×
page-parameter re-fetch §52 measured on the race weekend page, removed as a side
effect of the data shape rather than by tuning anything.

The names were never missing. `d1Name`…`d5Name`, `s1name`…`s10name` and
`driver1Name`/`driver2Name` have been on those resources since they were
published; no chart could read them.

### Two authoring traps, both invisible until rendered

**A sentinel value plots as a real measurement.** f1db carries an unclassified
season as a standing in the high hundreds. The career chart's finish axis
therefore ran to **1,000**, drawing a dramatic career arc out of "no position" —
a wrong reading rather than a missing one, and one that looks entirely plausible.
Only a classified season gets a point now.

**`~s` is the wrong axis format for seconds.** A blanket SI format renders a
0.35 s pace gap as **"350m"** — milli-seconds, read as metres. Formats have to be
per chart: integers with `tickMinStep: 1` for positions, rounds, laps and counts;
`.2f` for a gap in seconds.

Both were found by looking at the rendered page. Neither is visible in the spec,
in `mx check`, or in the headless spec checker — which reported all ten specs
compiling cleanly with the wrong formats in place. The pack's own instruction —
*measure the rendered output, do not reason about the spec* — earned itself
twice in one afternoon.

A third worth knowing: the checker's mark counts group by mark type, so a bar
chart **with** a colour legend reports `rect:1` where the same chart without one
reports `rect:3`. That reads as "my bars vanished". Counting `<path>` elements in
the rendered SVG settled it in one command — 42 paths for the 15-bar chart.

### One-line bug in the pack

`references/install.md` says `npm ci`, and the pack ships no `package-lock.json`,
so the documented command cannot work:

```
npm error The `npm ci` command can only install with an existing package-lock.json
```

`npm install` works. Either ship the lock file or change the instruction — the
lock file is the better answer for a pack whose whole point is a reproducible
build.

## 57. PR 202 verified: four defects fixed, one regression it says it does not have

*Verified 2026-08-20. `ako/mxcli` PR #202 head `e50ddac` built against its own
parent `48114de`, both from source, so every difference below is attributable to
the one commit and not to the run of main between it and the build this repo
carries.
Built with go1.26.5, not the go1.24.7 in the table above.*

The PR unifies the widget datasource switch — five copies on the read side, six
on the write side — into one reader and one renderer, and closes #941. Reading
the diff would not settle whether it works, so both sides were built and pointed
at real models: **50 before/after pairs over 47 distinct pages**, across this
solution's frontend (12) and backend (16) and a throwaway project (19) carrying
the PR's own reproduction MDL.

Measured twice, on two revisions of this repo: first at `946d6f1`, then re-run
against `bb1d35d` after §56 replaced every chart with Vega. The two disagree
about the blast radius, and the difference is itself a finding — see below.

### The four defects reproduce here, and the PR fixes all four

| Defect | On `48114de` | On `e50ddac` |
|---|---|---|
| pluggable/chart microflow source | `database from Formula1Frontend.DS_LapChart` | `microflow Formula1Frontend.DS_LapChart` |
| gallery over an association | *(datasource absent)* | `$currentObject/Bug941.Item_Bucket` |
| combobox on `System.UserRole` | WHERE + SORT dropped | both restored |
| combobox on `System.TimeZone` | SORT dropped | restored |

**31 datasources** changed across `Race_Weekend` (25), `Season_Summary` (5) and
`Constructor_Detail` (1) — every one of them `database from` → `microflow`, no
other kind of edit. That count is at `946d6f1`. Re-run at `bb1d35d` the frontend
changes **nothing**: §56 wraps each chart in a `dataview` whose microflow
datasource the old code already read correctly, so there is no pluggable-widget
datasource left to mis-render. The Vega migration sidestepped this defect
without meaning to. The backend and the probe project still reproduce it, so the
bug is live — it is the binding style, not the fix, that decides whether a
project ever meets it. The reporter's message is reproduced exactly and then goes
away:

```
$ mxcli check Race_Weekend.describe.mdl -p Formula1Frontend.mpr --references
48114de   - entity not found: Formula1Frontend.DS_WeekendShape
          - entity not found: Formula1Frontend.DS_LapChart
          - entity not found: Formula1Frontend.DS_WeekendSessions
e50ddac   ✓ All references valid
```

The two combobox rows are the interesting ones: they are stock
`Administration.Account_Edit` / `Account_New`, which ship in **every** project
from the Mendix template, and they reproduced in two independent projects. This
defect is not exotic.

The gallery row is the sharpest vindication of the PR's own argument that silent
loss is worse than a parse error. On `48114de` that page passes
`check --references` **because** the datasource vanished — there is nothing left
to fail on. No amount of validation catches it; only a before/after diff does.

`go test ./mdl/executor/` passes on the head (12.2 s), and the new datasource
tests genuinely exercise association, selection, context-scoped XPath and
microflow shapes. The reordering of `MDL-WIDGET07` warnings between the two runs
is nondeterministic map iteration over an identical set — confirmed by hashing
the sorted sets — not a behaviour change.

### 57.1 The regression: restoring the WHERE makes previously-parseable output unparseable

> The PR body: *"a restored WHERE clause could plausibly have introduced a parse
> error. It didn't."*

Here it did, on **both** revisions — this is the one result the Vega migration
does not change, because it lives in a stock Administration page.
`Administration.Account_New` describes to MDL that parses clean on the parent
and does not parse at all on the head:

```
48114de   ✓ Syntax OK (2 statements)
e50ddac   Syntax errors found:   (27 of them)
            - line 20:83 extraneous input '[' expecting {',', ')'}
```

Line 20, column 83, is the bracket in the constraint the PR correctly restored:

```
DataSource: database from System.UserRole where System.grantableRoles[reversed()]/System.UserRole/System.UserRoles = '[%CurrentUser%]' sort by Name asc,
```

The clause is right. It is emitted **unquoted** —
`mdl/executor/cmd_pages_describe_datasource.go:224`:

```go
expr += " where " + xpath
```

so defect 4's fix collides with *unquoted XPath containing `[`*, which the PR's
own "what this does not fix" list already names as an open round-trip defect.
Restoring the WHERE turned a latent gap into an active parse failure.

Isolated three ways on the emitted file — remove the WHERE: parses; quote the
XPath: parses; leave `sort by` alone in both cases: parses. The bracket is the
sole cause, and quoting at that line looks like the whole fix.

Across all 50 pairs:

| | count |
|---|---|
| parsed before, fails after | **2** |
| fails before, parses after | 0 |
| parses on both | 40 |
| fails on both (pre-existing) | 8 |

Those are the `946d6f1` pairs. The `bb1d35d` re-run over the backend's sixteen
pages reproduces the same shape: `Account_New` clean → broken, `Account_Edit`
broken on both sides, nothing else touched.

Nothing here argues against the change — the reference-validity axis strictly
improves and 31 wrong datasources become right. But the claim as written does
not hold, and the two pages it costs are template pages every project has.

### 57.2 Microflow datasources still lose their arguments — §39 one level along

`DS_LapChart` takes `$Race`. The source binds it:

```
DataSource: microflow Formula1Frontend.DS_LapChart(Race: $Race)
```

`describe` emits it without the argument, and `check --references` now calls
that valid:

```
DataSource: microflow Formula1Frontend.DS_LapChart,
```

At `946d6f1`, across the frontend's twelve pages and the probe's three: **46
microflow datasources emitted, 0 carrying an argument**, against 41 source-side
bindings that do pass one. At `bb1d35d`, across the frontend and backend: **35
emitted, 0 carrying an argument**, against 29 bindings that pass one. The ratio
does not move. It is not confined to pluggable widgets — plain `dataview`
loses them too (`dvWeekend`).

This is **pre-existing**, not a regression: `48114de` loses the arguments as
well, it merely printed the whole line wrong so the loss was invisible behind a
larger bug. It is the same defect as §39, which is `SHOW_PAGE` losing
`(Race: $currentObject)`, one level along — an argument list dropped between the
model and its description, so the description cannot re-execute into what it
came from. Worth filing on its own; the renderer is now one function
(`dataSourceExpr`, `case "microflow", "nanoflow"`), which is the right place to
fix it once instead of six times.

### 57.3 `strings.Trim(s, "")` is a no-op

Same function, four lines above the WHERE emission:

```go
if xpath := strings.Trim(ds.XPathConstraint, ""); xpath != "" {
```

An empty cutset trims nothing. Verified rather than assumed:

```
Trim(s,"")   = "  [Foo/Bar]  "   (unchanged: true)
TrimSpace(s) = "[Foo/Bar]"
```

So a whitespace-only constraint passes the `!= ""` guard and emits `where    `.
Almost certainly meant `strings.TrimSpace`. Harmless against today's models —
nothing in these three projects stores a blank constraint — but wrong as
written, and it sits directly above the line that needs the quoting fix.

### What to file

| # | Finding | Where | Size |
|---|---|---|---|
| 57.1 | quote the XPath constraint on emit; it regresses two template pages from parseable to unparseable | `cmd_pages_describe_datasource.go:224` | trivial |
| 57.2 | microflow/nanoflow datasources drop their arguments, as `SHOW_PAGE` does in §39 | same file, `case "microflow"` | small |
| 57.3 | `strings.Trim(s, "")` should be `TrimSpace` | same file, line 220 | trivial |

57.1 is worth raising before the PR merges, because it is one line and it is
inside the change. 57.2 and 57.3 are older than the PR and belong in their own
issues — the PR made the first one visible and gave the second one a single home.

---

## 58. The rate limiter that stored an empty race

Setting up to capture the Dutch GP (Sunday 23 August, session 11353), I pointed
the sync at a session from earlier the same day — Zandvoort FP1, 11343 — as a
rehearsal. It stored 692 laps and nothing else. No telemetry, no radio, no
track outline. Every table but one, empty.

Session 11342 — Hungary, captured a month earlier — was complete. Same code,
same endpoints, one session works and one does not.

### It was not the data

`car_data?session_key=11343&date>=…&date<=…` returns HTTP 200 and 2.4 MB from
curl, 14,652 rows in a three-minute window. The 11342 window returns 200 and
2.5 MB. Same keys, same shapes, same sizes:

```
11342 keys: brake date driver_number drs meeting_key n_gear rpm session_key speed throttle
11343 keys: brake date driver_number drs meeting_key n_gear rpm session_key speed throttle
```

The one visible difference is key *order*, which `from_json` does not care about.

### The tell was in the timings

`Sync_Telemetry` returned in **73 milliseconds** — having supposedly fetched
three responses of a couple of megabytes each. The same microflow against 11342
took four seconds. Whatever was happening, the requests were not going out and
coming back.

`Sync_Fetch` swallows everything with `ON ERROR CONTINUE` and substitutes `[]`
for an empty body, so there was nothing in the log. One line fixed that:

```
LOG INFO NODE 'F1LiveSync' 'fetch ' + $Url + ' -> ' + toString(length($Body)) + ' chars';
```

and the answer was immediate:

```
21:39:23.111  fetch …/stints?session_key=11343 -> 14235 chars     pass 2
21:39:43.461  fetch …/stints?session_key=11343 -> 2 chars         pass 3
```

**The same URL, twenty seconds apart, succeeded and then returned nothing.** No
API does that over its data. Rate limiters do it over their clock.

Twelve requests in a burst, from a shell:

```
0 200 14235
1 200 14235
2 200 14235
3 HTTP 429 {"detail":"Rate limit exceeded. Max 3 requests/second."}
4 200 14235
...
```

### What actually happened

The sync was written to be sequential, because parallel httpfs scans were what
tripped this limit the first time (§53). Sequential is necessary and it is not
sufficient: Mendix issues sequential REST calls *as fast as it can*, and a pass
fired nine of them in 240 ms — roughly 37 requests a second against an allowance
of three.

So requests four onward came back 429. `ON ERROR CONTINUE` turned each one into
an empty body, `Sync_Fetch` substituted `[]`, `[]` is valid JSON, and the
derivation read it as a session containing no data. The laps tier ran first and
got its three requests in under the wire, which is why exactly one table filled.

Nothing failed. Nothing logged. The result string said `pass 1 | pass 2 | pass 3`
for a cycle that stored a full race and for one that stored nothing, because it
reported that the passes *happened* and never looked at what they returned.

**A swallowed error plus a default that parses is indistinguishable from an
empty API.** Both halves are needed for the failure and both were deliberate
choices: `ON ERROR CONTINUE` so a 404 on a quiet window would not stop the sync,
`[]` so DuckDB would not choke on an empty string. Each is right on its own.

### The fix

Three parts, all in `19-live-sync.mdl` and `20-live-tiers.mdl`:

1. **An explicit gap before every fetch.** 700 ms unauthenticated (1.4/s against
   an allowance of 3), 250 ms with a bearer (4/s against 6). `Sync_Sleep` now
   takes milliseconds rather than seconds.

2. **One retry on an empty body**, after 1.5 s. Empty means either a genuine 404
   — the window holds no samples — or a 429. The two want opposite treatment and
   a single extra request tells them apart.

3. **The cycle sizes itself to the tier.** Three passes cost 28 requests, which
   is under half of the authenticated 60/min and *over* what the free 30/min
   leaves room to retry. Unauthenticated the cycle now runs one pass, 12
   requests, on a one-minute cadence. The budget comment in the model had been
   written against the authenticated allowance and the code ran unauthenticated.

Plus the result string now carries what each tier returned, not that it ran.

Zandvoort FP1, recaptured: 692 laps, 3,960 car samples, 1,826 location samples,
8 radio messages, and a 301-point track outline traced from Leclerc's flying lap.

### Two ordering bugs found on the way

**`SE_LiveSync` was defined in both scripts** — pointing at `Sync_Live` in 19 and
at `Sync_Cycle` in 20. Whichever ran last won, so the order the model scripts
were applied in silently decided whether a race captured one tier or all of
them. The definition now lives only in 20, next to the cycle it schedules.

**`Sync_Sleep` was declared in 20 and is now called from 19**, which made the
dependency circular: 19 needs 20's java action, 20 needs 19's entities. Moved
the declaration into 19, next to `Sync_Fetch`, its first caller.

### The scheduled event does fire locally

Recorded as unverified since the sync was built. It does not fire under a plain
`mxcli run --local`, and the boot log says why:

```
Core: Synchronizing scheduled events: None
```

That is the runtime's own setting, not an mxcli limitation, and mxcli passes it
through:

```
mxcli run --local -p Formula1Backend.mpr --runtime-setting 'ScheduledEventExecution=ALL'
```

```
Core: Synchronizing scheduled events: All
```

### And the thing none of this fixes

OpenF1 classes data as live **from 30 minutes before a session starts until 30
minutes after it ends**, and live data — REST, MQTT and WebSocket alike — is
sponsor-only at €9.90/month. The free tier is historical-only, at 3 requests a
second and 30 a minute.

So the sync cannot follow Sunday's race as it runs, at any cadence, with any
amount of pacing. It can capture the whole thing from half an hour after the
flag, at full fidelity, and for replay that is the same data — the store is
timestamped and append-only, so a race assembled afterwards replays exactly like
one assembled live. What is lost is watching it arrive.

---

## 59. Authenticating: the import mapping that cannot be written from MDL

Credentials went in as constants and `Sync_Cycle` started throwing:

```
com.mendix.modules.microflowengine.MicroflowException: key not found: Path(QName(None,),None,)
	at Formula1Backend.Sync_EnsureToken (CallRest : 'Call REST (POST)')
```

`Path(QName(None,),None,)` is a lookup for an element whose name is empty. It
names nothing that appears in the model, and `mx check` reports zero errors.

### First: whose fault is the response?

`Sync_EnsureToken` had never run against a real account — only against the
endpoint's error path — so the response was the obvious suspect. The probe that
settled it logs the *shape* and never a value, because the value is a bearer
token:

```
LOG INFO NODE 'F1LiveSync' 'token probe: len=' + toString(length($Raw))
  + ' head=' + substring($Raw, 0, 1)
  + ' has_access_token=' + toString(contains($Raw, 'access_token'))
  ...
```

```
token probe: len=975 head={ has_access_token=true has_expires_in=true
            has_token_type=true has_detail=false
```

Valid JSON, all three fields, credentials accepted. The response was never the
problem.

### Then: whose fault is the mapping?

The generated model reads back correctly. Decoding the `.mxunit` directly:

```
JsonStructures$JsonElement   Path (Object)|access_token   ExposedName Access_token
ImportMappings$ValueMappingElement
                             JsonPath (Object)|access_token
ImportMappings$ObjectMappingElement
                             JsonPath (Object)   ExposedName Root
```

Nothing empty anywhere. So the next question was whether the fault lay in the
mapping or in the REST call's `RETURNS MAPPING`, and MDL can ask that directly,
because an import mapping is also a standalone activity:

```
$Raw      = REST CALL POST … RETURNS String ON ERROR CONTINUE;
$Response = IMPORT FROM MAPPING Formula1Backend.IMM_OpenF1Token($Raw) FIRST;
```

Same failure, one frame over:

```
	at Formula1Backend.Sync_EnsureToken (Import with mapping : 'Import from JSON')
```

**Two ways of invoking it, one failure.** The mapping is the broken part.
Written from MDL, checked clean by both checkers, and unusable at runtime — an
mxcli defect, and a nasty class of one, because every static check passes.

### Two routes that looked promising and were not

**Jackson.** The runtime bundles `jackson-databind` — it is right there in
`runtime/bundles/`. It is not on the *compile* classpath for user Java actions:

```
Sync_JsonField.java:38: error: package com.fasterxml.jackson.databind does not exist
```

That is a build failure, not a runtime one, so the app stops starting entirely.

**JSLT.** Mendix 11.9+ has data transformers and mxcli can author them —
`CREATE DATA TRANSFORMER … SOURCE JSON '{…}' { JSLT '…'; }`. Two things rule it
out here. There is no MDL activity to *invoke* one from a microflow, and a
transformer turns JSON into JSON, so landing the result in an entity still needs
an import mapping — the thing that is broken.

### What it is now

The same parser every other OpenF1 response already uses. `GetOpenF1Token` in
`01-foundation.mdl`:

```sql
SELECT s.access_token AS accessToken, s.expires_in AS expiresIn
  FROM (SELECT from_json({tokenJson}::JSON,
        '{"access_token":"VARCHAR","expires_in":"BIGINT"}') AS s)
```

Object shape, not array — `from_json` with an array schema against an object
returns zero rows rather than failing, which would have been the next hour.
Verified in DuckDB before it went near the model.

The exposure argument is worth stating rather than assuming: routing a bearer
token through the warehouse costs nothing, because the token is written to
`LiveToken` a few activities later regardless. It is in the database either way.

```
F1LiveSync: OpenF1 token minted, valid for 60 minutes
```

and `LastResult` lost its `(unauthenticated)` suffix.

### The deadlock that authentication uncovered

The first authenticated cycle failed anyway:

```
com.mendix.datastorage.exception.UpdateConflictException
	at Formula1Backend.Sync_Live (JavaAction : 'OQL_Execute')
Caused by: org.postgresql.util.PSQLException: ERROR: deadlock detected
```

Two cycles in `Sync_Live` at once, both writing the staging table. The immediate
cause was mine — a manual `LiveCycleNow` while the scheduled event was running —
but the arithmetic says it would have happened on race day without any help:
authenticated, three passes with twenty seconds between them take about
sixty-four seconds, and the event fires every sixty.

The model's own comment had worried about exactly this ("a pass that runs long
overlaps the next minute's event and both are then in flight") and treated
request headroom as the remedy. Headroom was never the issue; wall clock was.

A guard flag on the state row does not fix it. **The whole cycle is one
transaction**, so a second cycle cannot see the first one's flag until the first
commits, by which point it has already done the writes that collide. Fitting
inside the minute is the only version that does not require two transactions to
agree:

```
DECLARE $Started DateTime = [%CurrentDateTime%];
WHILE $Pass < $Passes AND [%CurrentDateTime%] < addSeconds($Started, 45) BEGIN
```

with the inter-pass gap cut to twelve seconds. A slow network now shortens the
cycle instead of overrunning it.

### Operationally

Do not trigger `LiveCycleNow` by hand while `SE_LiveSync` is enabled and firing.
The ops action exists because the event did not fire locally; now that
`--runtime-setting 'ScheduledEventExecution=ALL'` makes it fire, the two
collide. One or the other.

---

## 60. Ten cores at 100%: a trial licence, and a supervisor that spins on a dead child

The container was pinned at 100% CPU. One process:

```
    PID USER      PR  NI    VIRT    RES  S  %CPU  %MEM     TIME+ COMMAND
 197669 vscode    20   0 5608596  39444  R 999.9   0.2      8,05 mxcli
```

`mxcli run --hub`, ten threads all runnable, eight hours and five minutes of CPU
burned. Load average 10.19 on ten cores.

### The app it was supervising had been dead for hours

```
$ ps -o pid,ppid,stat -p 198010
    PID    PPID STAT
 198010  197669 Z          <- the runtime, a zombie, never reaped

$ curl -o /dev/null -w '%{http_code}' http://localhost:8180/
000
```

So: the Java runtime exited, `mxcli` neither reaped it nor noticed, and went into
a busy-loop across every core. **Two mxcli defects in one process** — the spin,
and the unreaped child. The tunnel client kept cheerfully reconnecting
underneath it (`client: Connected (Latency 34.643ms)`), which is why the hub URL
still answered while the app behind it was gone.

### Why the runtime exited

Not OOM — `memory.events` reports `oom_kill 0`. The runtime shut *itself* down:

```
	at com.mendix.basis.util.license.LicenseContextImpl.shutdownRuntime(LicenseContext.scala:125)
	at com.mendix.basis.util.license.LicenseUtil.checkRuntimeDuration(LicenseUtil.scala:114)
```

```
LicenseService: Maximum run time exceeded, framework is now terminating
```

The local runtime runs on a built-in developer licence with a maximum run time,
and it had been saying so at every boot all along:

```
WARNING - LicenseService: The runtime has been started using a trial licence,
          the framework will be terminated when the maximum time is exceeded!
```

Measured on this machine, from licence-initialised to termination:

| app      | started  | terminated | ran for |
|----------|----------|------------|---------|
| frontend | 20:51:50 | 01:59:14   | 5h07m   |
| backend  | 22:37:59 | 02:30:40   | 3h52m   |

Not a fixed number, and shorter than a race weekend either way. `mxcli` has no
licence command — `mxcli auth` handles Personal Access Tokens and tunnel-hub
keys, nothing else — so the limit cannot be lifted from here.

### Why this was nearly a disaster and is now merely a nuisance

A race capture needs the app alive for the session plus the backfill. Four hours
is not comfortably more than that, and the failure is silent: the app stops, the
hub keeps answering, and the sync simply stops writing rows.

What saves it is that **the sync keeps no state in memory**. `LiveLap` and
friends are append-only, and `LiveSyncState.TelemetryCursor` records how far the
backfill has walked. Killed mid-backfill and restarted, it resumed exactly:

```
 sessionkey | telemetrycursor     | runcount
 11344      | 2026-08-21 17:30:00 |      120
```

with 253 laps of Sprint Qualifying already stored, and carried on from there.
That property was designed for replay and it turns out to pay for crash recovery
too.

So the answer is a supervisor rather than a licence: `scripts/keep-app-running.sh`
polls the app's own URL and restarts it when it stops answering. It polls health
rather than waiting for `mxcli` to exit, **because mxcli does not exit** — that
is the whole finding — and it kills the process *group*, because mxcli leaves
children behind.

### For anyone else running an mxcli app for hours

- The trial-licence warning at boot is not boilerplate. Budget for a restart.
- Do not infer "the app is up" from the hub URL answering. The tunnel outlives
  the app.
- A `mxcli run` process at several hundred percent CPU is not working hard, it
  is spinning on a dead child. Check for a zombie under it.

---

## 61. An admin screen over the raw tables, and the key that made it cheap

Every screen in the frontend is an answer — a lap chart, a standings table, a
track map. None of them can say what is *in* a table, so when a race looked
wrong the only way to ask was psql against the backend's database. That is not
available on Mendix Cloud, and not available at all to anyone who does not hold
the connection string.

Sixteen resources, one grid each, over five pages.

### The obstacle was the key

A published OData entity needs a key attribute carrying a unique validation rule
(CE6585, then CE6624). Thirteen of the fifteen live tables had none: their
natural keys are composite — `(SessionKey, DriverNumber, LapNumber)` and the
like — and Mendix will not accept a composite key.

The obvious answer was a computed string key on each, set on every write. That
is thirteen schema changes *and* thirteen microflow changes, to the code that
captures a race, the day before one.

`autonumber` costs one line per table and no microflow change, because the
runtime fills it in:

```
RowId: autonumber default 1 unique error 'LiveLap row id must be unique'
```

Two things worth knowing. It **needs a seed** — without `default 1` the build
fails CE7247 "Value cannot be empty". And it **backfills an existing table
cleanly**: LiveLap's 2,368 stored rows came out numbered 1..2368, all distinct,
on the first boot after the migration. That was worth checking rather than
assuming, so the live tables were pg_dumped first; the dump was not needed.

`mx check` accepts an autonumber as an OData key. That was the whole question,
and testing it on one table before touching the other twelve turned a day into
an afternoon.

### Where the key has to live

Added as `ALTER ENTITY … ADD ATTRIBUTE` from the admin script, the keys survived
exactly until the next run of 19 or 20:

```
[error] [CE1613] "The selected attribute 'Formula1Backend.LiveCarNow.RowId'
        no longer exists." at Published attribute RowId
```

`create or modify persistent entity` rewrites the attribute list it is given, so
an attribute added from elsewhere is dropped the next time the owning script
runs. **An attribute belongs in the entity definition, not in an ALTER in
another file** — the same lesson as the duplicated scheduled event in §59, in a
different costume. The RowIds now sit in 19 and 20 beside the tables.

### Do we already store the sync job history? Yes — twice, and neither is enough

Mendix keeps it without being asked:

```sql
select name, starttime, endtime, status from system$scheduledeventinformation;
 Formula1Backend.SE_LiveSync | 08:01:00.171 | 08:01:50.194 | Completed

select microflowname, status, count(*), round(avg(duration)) from system$processedqueuetask group by 1,2;
 Formula1Backend.Sync_Cycle | Completed |    74 | 205001
 Formula1Backend.Sync_Cycle | Failed    |     6 |    247
 Formula1Backend.Sync_Cycle | Aborted   |     3 |
```

`System.ProcessedQueueTask` carries status, duration and `ErrorMessage` per run;
`System.ScheduledEventInformation` carries the event's own start and end. Both
are genuinely useful and both are queryable right now — that 6 Failed / 3
Aborted is the deadlock of §59 and the licence kill of §60, recorded without
anyone building anything.

Neither is a record of a race, for two reasons. The runtime's cluster-management
job "cleanup old processed tasks from the database" prunes them, so the evidence
expires. And neither knows what the cycle was *doing* — which session it
followed, how many passes it fitted into its minute, whether it was
authenticated.

So `LiveSyncRun` is ours and holds what the System tables cannot:

```
 runid | startedat            |    ms | sessionkey | passes | outcome   | authenticated
     9 | 2026-08-22 08:38:00  | 49966 | 11344      |      3 | Completed | t
```

Fifty seconds, three passes, inside the minute — which is the §59 deadline fix
being confirmed by the thing it fixed.

It is written **last**, so a cycle that threw leaves no row at all. That absence
is the signal, read against the scheduled event's own record of having fired.

### Two things deliberately absent

`LiveToken` has no grid. It holds a bearer token, and an admin screen is exactly
the sort of convenience that ends up on a shared display.

Every grant is READ. The Admin screen is evidence, not a console — turning the
sync on or repointing it at a session stays behind the backend's ops API and its
shared key.

### Notes

- Sixteen grids on one visible surface is sixteen OData reads on open, so they
  are grouped -- five tab pages, whose contents are not fetched until shown.
- ~~MDL has no tab container, so the grouping is pages rather than tabs.~~
  **Wrong, and corrected in 69.** MDL has `TABCONTAINER` and `TABPAGE`. This was
  built as five separate pages with a hand-rolled chip row between them purely
  because of that mistaken belief; it is now one tabbed page.
- The menu item is `PAGE Formula1Frontend.Admin`, and Mendix does not render
  a menu item whose target the signed-in user cannot view — so the fan role never
  sees it, with no extra visibility rule.
- Atlas icon names are not discoverable through `describe icon collection` as the
  error message claims; `mxcli -c "describe icon collection Atlas_Core.Atlas"`
  lists all 366. There is no `database` or `table` icon; `layout-list` is the
  closest.

---

## 62. `mxcli test` blanks the running app

Both apps went black. Both answered HTTP 200.

```
$ curl -o /dev/null -w '%{http_code} %{size_download}' http://localhost:8180/
200 1718
```

1,718 bytes is Mendix's SPA shell — the `<div id="root">` and the script tag
that fills it. The runtime was fine. What it served the shell *for* was gone:

```
ERROR - Connector: 404 - file not found for file: dist%2Findex.js
```

```
$ ls deployment/web/dist
ls: cannot access 'deployment/web/dist': No such file or directory
```

The backend had its `dist/` and served the bundle 200; only the frontend was
broken. "Both are black" was one real failure and one page — the backend's
default `Home_Web` — that had simply never been looked at before.

### What removed it

`deployment/web/` was rewritten at 08:39:16 by something that was not the app,
which had booted at 08:38:05. The candidates were the two mxcli commands run
against the project in between. Testing it takes twenty seconds:

```
before:           deployment/web/dist
after mxcli test: MISSING
bundle now:       404
```

**`mxcli test … --local` rebuilds the deployment directory of a project that
another `mxcli run` is currently serving, and its build does not include the web
client bundle.** The tests pass, the run keeps running, and the app it is
serving goes blank. Nothing reports an error, at either end.

Reproduced on demand, so it is a defect rather than a coincidence, and a
mean-tempered one: the natural thing to do after changing a model is to run the
tests, and the natural thing to do after that is to look at the app.

### The health check that did not catch it

`keep-app-running.sh` from §60 polled `/`, which answered 200 throughout. That
is the §60 lesson again in a new costume — there, the hub tunnel outlived the
app; here, the runtime outlives the client it serves. **A 200 from the front
door does not mean the building is furnished.**

The supervisor now polls `/dist/index.js`: the bundle the shell loads, so a 404
there is exactly the failure a visitor sees. It caught the deliberate
reproduction in sixty seconds and restarted the app without being asked:

```
[supervisor 08:50:41] health check failed (1/3) on http://localhost:8180/dist/index.js
[supervisor 08:51:01] health check failed (2/3) on ...
[supervisor 08:51:21] health check failed (3/3) on ...
[supervisor 08:51:31] started pid 285504: mxcli run --hub ...
```

### Working rule

Run tests against an app you are *not* also serving, or expect to restart it
afterwards. With the supervisor in place the restart happens on its own, at the
cost of a minute of blankness — which is fine for a laptop and would not be fine
during a session you were capturing.

### And one about pkill, again

`pkill -f "keep-app-running.sh /workspaces"` matched the shell running it, which
died with 144 before killing anything — so a second supervisor started while the
first app still held port 8080. mxcli refused it, correctly and informatively:

```
A stale process is silently adopted otherwise, so edits appear to do nothing.
  Held by pid 273513: /usr/lib/jvm/…/java …
  That is not a process mxcli started, so it is not a leftover run —
  pick another port rather than killing it.
```

Enumerate with `ps` and kill by PID. The §55 note about pkill patterns matching
the invoking shell has now cost time three times in this project.

---

## 63. Four stubs, and the entry list that made a result unreadable

The Zandvoort sprint captured cleanly: 485 lap rows, 22 cars, 24 laps, gaps
matching OpenF1's official result to the millisecond. Reading it out, I put
Verstappen third.

He finished sixth. Car 1 is Norris this season; Verstappen is car 3.

The mapping was not in our database to check against. `LiveDriver` was empty —
and had been empty in every session ever captured, because `GetOpenF1Drivers`
was a stub:

```sql
SELECT '' AS sessionKey, 0 AS driverNumber, '' AS code,
       '' AS driverName, '' AS team, '' AS teamColour
 WHERE {dataDir} = 'never'
```

A shape with no rows behind it, and nothing called it. `GetOpenF1Session`,
`GetOpenF1Weather` and `GetOpenF1Messages` were the same: scaffolding from the
CSV era, left in place, silently returning nothing. Four of the sync's fifteen
tables could not fill by construction.

**The cost is not cosmetic.** A lap table keyed on `driver_number` with no entry
list is a table of anonymous numbers, and the only way to read it is to supply
the mapping from somewhere else — memory, in my case, using last season's. The
confirmation was sitting in a feed we were not storing:

```
INCIDENT INVOLVING CAR 3 (VER) NOTED - FAILING TO FOLLOW RACE DIRECTORS INSTRUCTIONS
```

I had that text on screen while fetching race control and read past it.

`race_control` also carries what *changes* a result — 65 messages in one sprint,
four investigations, a lap time deleted for track limits. All discarded.

The four queries are now real. Each was verified in DuckDB against the archived
session before going near the model, which is worth the two minutes every time:
`from_json` with an array schema against an object body returns zero rows rather
than failing, so a wrong schema looks exactly like no data.

`Sync_Entry` captures the entry list once per session and returns early
thereafter. `Sync_Context` rewrites session, weather and race control every
pass — 77 and 118 rows is cheaper than the watermark bookkeeping to avoid it,
and rewriting is idempotent by construction.

### A commit is not visible until the cycle ends

`Sync_Context` logged `1 session, 77 weather, 118 race control` while the tables
read empty from psql. Nothing had failed. **The whole cycle is one transaction**,
so `COMMIT` inside a sub-microflow is not visible to another connection until
the outer cycle finishes, forty seconds later. The same property that made a
guard flag useless against the §59 deadlock.

Worth knowing before diagnosing a write that "did not happen".

---

## 64. Archiving the API, and the mock that falls out of it

Two problems with one artefact, and the second was the user's idea.

The capture lived only in Postgres, so `mxcli setup` would take a race weekend
with it. Worse, what is stored is *derived* — `LiveLap` is an ASOF join of five
endpoints, `LiveCarNow` a downsample — so no dump of our tables can rebuild what
we did not already think to keep.

`scripts/archive-session.sh` stores the raw responses instead. The Zandvoort
sprint is 4.9 MB gzipped and holds **341,308 car_data and 331,958 location
rows** — the telemetry the sync itself only ever kept a rolling minute of.

### The backup had the bug the backup was written to prevent

The first version computed a row count and treated "could not parse one" as
"zero rows", deleting the file. Four sessions back to back tripped the rate
limit:

```
run 1:  location  185,306 rows
run 2:  location        0 rows
```

Both wrong, neither complained. That is §58 verbatim — an error swallowed, and a
default that parses, are indistinguishable from an empty API — written that
morning and committed again that afternoon. **Knowing a failure mode is not the
same as recognising it in new clothes.**

It now retries 429s with backoff, distinguishes a real 404 from a failure, and
exits non-zero rather than leaving a plausible archive. The corrected run gets
331,958.

### The recording was already in the design

`OpenF1BaseUrl` has been documented as *"override to point at a mirror or a
recording"* since it was written. `scripts/openf1-mock.py` is that recording:
the archive served with OpenF1's URL shape, so the whole sync runs against it
unchanged, at disk speed, with no rate limit and no live-session gate.

Verified row-for-row against the live API across five endpoints. Getting there
took one real bug worth recording:

**`date>=X` percent-encodes to `date%3E=X`, so `parse_qs` returns the key
`date>` — the `=` is eaten as the key/value separator.** Reading that as a
strict `>`, and truncating stored timestamps to the filter's width to compare
them, dropped every row in a window's first second. ISO-8601 compares correctly
as plain text and must not be truncated first.

---

## 65. Narrate was bound correctly and aimed at the wrong source

The screen showed the Hungarian Grand Prix of 26 July while the app captured
Zandvoort perfectly into tables nothing read.

The five resources behind it — Order, Session, Messages, Trace, Stints — were
read by microflows scanning `data/live/*.csv` through DuckDB. Those CSVs are
written by `scripts/fetch-f1-live.sh`, the thing the in-app sync replaced. So
the screen had been showing whatever was last on disk.

**The fix is backend-only.** The frontend was bound correctly all along: same
resources, same attribute names, same keys. Repointing the five read microflows
at `LiveLap`, `LiveDriver`, `LiveSessionRow`, `LiveWeatherRow` and
`LiveMessageRow` changed nothing about the published contract, so not one line
of the frontend moved. It is worth checking which end is wrong before rewiring
the end that is not.

Two details:

**The classification takes each driver's own latest lap, not the leader's.** A
car a lap down has no row on the current lap, and dropping it off the timing
screen would be wrong. Laps come back newest-first and a driver is taken the
first time it is seen.

**Stints are reconstructed rather than fetched.** `LiveStintRow` is still empty,
but `Sync_Live` already stamps compound and tyre age onto every lap, so a stint
is a run of consecutive laps on one compound. Sainz's three stints and his pit
stop fall out of the lap table with no extra request.

### The pushdown was dropped on purpose

The CSV readers used `ODataPushdown.Parse` to push `$filter` and `$top` into
DuckDB, because scanning a race of CSV is expensive. These read a few hundred
Postgres rows of one session, so the pushdown earns nothing and costs a Java
action per request. Removed.

### Two mxcli notes

`FIND($List, cond)` takes **one** condition. A two-part `AND` fails the build
with `CE0117 "Error(s) in expression"` naming only the activity, not the
expression. Match on a computed key instead.

`SORT($List, attr ASC)` is the documented syntax and the grammar rejects it —
`extraneous input 'ASC' expecting ')'`. Only `SORT($List, attr)` parses;
ascending is the default. Worth filing.

### Still empty, and honestly so

Interval, DRS and the sector marks stay blank. `LiveLap` does not carry interval
— the feed is read for the gap and discarded — and OpenF1 sent **null DRS for
the entire weekend**, which the per-lap aggregate had been averaging to a
confident `0.0000` across all 504 rows. A zero reads as a fact; empty does not.

---

## 66. The circuit was never wrong: five tracks drawn on top of each other

The track map rendered a spiky star. I diagnosed it twice and was wrong twice.

**First diagnosis:** the outline has 336 rows but only 26 distinct positions, so
tracing from one driver's single lap does not yield enough points. I proposed
rebuilding the derivation to use all twenty cars.

**Second diagnosis, after checking the other sessions:** three of four traced
cleanly (301, 343 and 300 distinct points, median step 131 units), so only
Hungary's capture was degenerate — bad luck with a stale feed on a month-old
session. I proposed a sanity check to refuse a degenerate outline.

**What it actually was:** `Read_TrackOutline` and `DS_TrackOutline` both did

```
RETRIEVE $Rows FROM ... SORT BY Seq ASC;
```

with no session filter. `LiveTrackOutline` accumulates one outline per session
and never clears, so by the Zandvoort weekend it held **1,630 points across five
sessions and two coordinate frames** — Hungary in one, four Zandvoort sessions
in another. Sorted by `Seq` and drawn as a single line, that is seq 0 of
Hungary, seq 0 of each Zandvoort session, then seq 1 of each, ricocheting
between circuits for 336 steps. The star.

Plot one session alone and it is unmistakably Zandvoort.

### The 26 distinct points were real, and a red herring

Hungary genuinely stored 336 rows with 26 distinct positions. That is a real
defect and it is not the one on the screen. Having found a true fact that
explained the symptom, I stopped looking — and the true fact was a coincidence.

**The question I never asked was "how many sessions does this read return?"**
One `SELECT sessionkey, count(*) GROUP BY 1` would have ended it in ten seconds,
at any point over two days. I ran percentile analyses of step distance,
reconstructed the loop closure, plotted the geometry, and never checked the
cardinality of the query feeding the chart.

A chart that draws the wrong thing has two candidate causes — bad data, or the
right data plus the wrong rows — and the second is cheaper to rule out.

### Both reads now filter to the session

`Live_CurrentKey()` supplies it, so the outline and the car positions agree with
the rest of the screen by construction.

---

## 67. Narrate at the comp's density, and what "above the fold" costs

The screen was built from the same comp as the other four and did not look like
it. Measuring rather than eyeballing:

| | comp | was |
|---|---|---|
| font-size, by frequency | 10px ×47, 11px ×34, 12px ×19, 9px ×9 | 24 / 22 / 14 |
| gap | 8px ×20, 1px ×17, 2px ×6, 3px ×5 | 12–18 |
| header row | 22px, labels 10px uppercase .06em | auto |
| main grid | `repeat(24, …)`, `subgrid` ×7 | flex stacks |
| shell | `100vh`, panes scroll internally | page scrolls |

The comp is an instrument panel: hairline rules instead of padding, everything
on one grid, data-ink maximised. What was built was airy Atlas panels wearing
the same palette.

The density pass is scoped to `.narrate-dense` rather than applied to `.panel`
globally — Season, Weekend, Constructor and Driver are reading screens where the
larger scale is right. This one is a timing screen.

### Layout was the bigger half

Type size was not the main problem. Five full-width panels stacked down the
page, with the track map alone a ~450px band holding one 330px figure, put the
classification — the screen's reason to exist — below the fold.

Regrouped to the comp's `minmax(0, 1fr) 336px`: classification in the main
column, circuit in the rail, the two lap-axis traces side by side as the small
multiples they are. The grid caps at 470px (22 rows plus header) and scrolls
internally rather than growing the page.

**A figure sized to the space it is given rather than to the job it does will
take the whole width if you let it.** The circuit is a locator; it needs about a
third of a screen.

### Numeric columns are monospace on purpose

Every column but Driver and Team is tabular-figure monospace. Comparing one row
against another down a column is the entire point of a timing screen, and
proportional digits do not line up.

### Not matched

The comp's inline per-row position sparkline — its `Position` column is a
sparkline, not a number — needs a per-row widget a Mendix datagrid column cannot
host. And the fixed-viewport shell with a 54px icon rail; ours scrolls inside
Atlas's layout. Both structural rather than cosmetic.

---

## 68. Verifying two mxcli PRs: a build step, and a defect that was not theirs

ako/mxcli #222 (generated widget docs become a real skill; bundled skills adopt
the Agent Skills standard) and #223 (the largest skills split into `SKILL.md`
plus `reference/` files). Both merge cleanly onto `origin/main` and the full
suite passes: **79 packages, 0 failures**.

### Six failures that were mine

The first run failed six tests, all in `cmd/mxcli`, all in the skills area the
PRs touch. It looked exactly like the PRs breaking their own subject.

```
--- FAIL: TestEmbeddedSkillsCarryAgentSkillsFrontmatter
    init_skills_standard_test.go:25: no embedded skills; the embed directive is broken
```

Isolating across refs made it look worse and then better: `origin/main` failed
4, #222 failed 4, #223 failed 6. A pre-existing breakage plus two new ones —
a tidy, plausible, wrong story.

`//go:embed all:skills` reads `cmd/mxcli/skills`, which is **generated**: the
Makefile's `sync-skills` target rsyncs it from `.claude/skills/mendix/`. I built
with `make grammar` and a bare `go build`, so that directory still held stale
flat files from an earlier build. `make sync-all` first and every ref is green.

Two things worth keeping:

**The error names the wrong thing.** "the embed directive is broken" points at
the `go:embed` line, which is fine; what is missing is a build step. A message
naming `cmd/mxcli/skills` and `make sync-skills` would have saved the detour.

**Comparing across refs did not save me.** Running the same wrong build on four
refs produced a clean-looking differential — the counts differed because #223
adds two tests, not because it breaks anything. **A differential is only as
sound as the procedure both sides share.**

### The claims, checked against a real project

Not just the fixtures. `mxcli widget docs` on this two-app solution produced 42
and 43 widget files plus a `SKILL.md` linking all of them, our own
`f1.widget.web.vegachart.VegaChart` among them with its full property table.

The substantive change is `_index.md` → `SKILL.md`. An `_`-prefixed file is
skipped by a plain `go:embed` and is not a skill entry point, so those property
tables sat in both apps undiscoverable.

#223's split holds: largest `SKILL.md` 1,906 → 647 lines, total 29,588 →
23,487. Its `TestEverySupportingFileIsLinkedFromItsSkill` is the better of its
two new tests — it stops a split orphaning content.

### One defect, and it was not the PR's

`custom-widgets/SKILL.md` carries **two frontmatter blocks**: the current one,
then the pre-rename `name: mendix-custom-widgets`. Everything after the first
`---` is body, so the skill opens with a stray YAML fence and a duplicate name.

I reported this as "a real defect from PR 222". It is not. `git log -S 'name:
mendix-custom-widgets'` puts it at **ff81a24**, the *"adopt the Agent Skills
standard"* commit itself — the new block was prepended and the old one left.
#222's diff on that file changes only the `description:` inside the first block,
and the stray `---` appears as *unchanged context* on the line below. The
evidence that it was pre-existing was inside the diff I had already read.

**Attributing a defect to the change you happen to be looking at is the same
error as blaming the code you happen to be reading.** `git log -S` on the
offending string costs one command and settles it.

**Fixed upstream.** Reported, and ako/mxcli#224 closed both halves: one
frontmatter block per skill (the two competing descriptions merged rather than
one discarded), a guard test for a stray second block, and the sync message now
names `make sync-skills` instead of blaming the embed directive.

`TestEmbeddedSkillsCarryAgentSkillsFrontmatter` could not see it:
`frontmatter.FindSubmatch` matches the **first** block and checks its `name`
against the directory, which is correct. A rename-and-prepend is invisible to a
first-block check, and it is exactly the shape of change that produces one.

---

## 69. `mxcli syntax page widgets` is not the grammar

The Admin screen was built as five separate pages with a hand-rolled chip row
linking them, plus a bespoke `.admin-nav` SCSS block, because I had concluded
MDL has no tab container.

It has had one all along.

```sql
tabcontainer tabs {
  tabpage tpA (caption: 'Cycle runs') { ... }
  tabpage tpB (caption: 'Laps')       { ... }
}
```

Built, read back with `describe` intact, `mx check` 0 errors. `TABCONTAINER` and
`TABPAGE` are lexer keywords in `MDLLexer.g4:380-381`; `buildTabContainerV3`
emits a proper `Forms$TabControl` with `Forms$TabPage` children and captions.

### How the wrong conclusion was reached

I searched the **documentation** — `mxcli syntax page widgets --json` — for
`TABCONTAINER|TABPAGE|GROUPBOX|ACCORDION`, got nothing, and wrote "MDL has no
tab container" into a design decision and twice into this document.

The grammar was one `grep` away and was never consulted.

**Absence from the documentation is not absence from the grammar.** For a
question of the form "does this tool support X", the authority is the parser,
and it is checkable in one command:

```sh
grep -iE 'TABCONTAINER|TABPAGE' .mxcli-src/mdl/grammar/MDLLexer.g4
# or, better, just try it:
mxcli check /tmp/probe.mdl -p app.mpr
```

Trying it costs twenty seconds and answers exactly the question asked. That is
what settled it in the end, two days late.

Worse: the evidence had already gone past. Verifying PRs 222/223 an hour earlier
printed

```
--- PASS: TestParseRawWidget_TabControlPreservesTabPages
--- PASS: TestOutputWidgetMDLV3_TabControlEmitsTabPageStructure
```

in output I read and summarised. A test named for the feature I had declared
missing.

### The documentation gap is real, and worth filing

`mxcli syntax page widgets` describes itself as covering "Widget types:
containers, data widgets, inputs, actions, display" and lists neither the tab
container nor several other widgets the grammar accepts. Confirmed by probing
each against `mxcli check`:

| keyword | in `MDLLexer.g4` | in `syntax page widgets` | `mxcli check` |
|---|---|---|---|
| `TABCONTAINER` | yes | **no** | passes |
| `TABPAGE` | yes | **no** | passes |
| `GROUPBOX` | yes | **no** | passes |
| `STATICIMAGE` | yes | **no** | passes |

Four widgets that parse and build, undocumented in the command whose entire job
is to say what can be written. The syntax reference is hand-maintained beside a
generated parser, so it drifts silently — and it drifts in the direction that
makes an agent reading it build the wrong thing, confidently.

A generated cross-check would close it: every widget keyword in the lexer should
appear in `syntax page widgets`, as a test.

**Still open** as of ako/mxcli `85c9708` (222, 223 and 224 all merged): all
four keywords remain absent from the command while parsing and building fine.
Unlike the duplicate frontmatter, this one has not been reported.

### What it cost

Five pages, a chip sub-navigation, a `.admin-nav` grid, and a paragraph in 61
explaining why tabs were impossible. All of it deleted. The replacement is one
page with five `tabpage` blocks, and tab pages have the property the five-page
split was reaching for anyway: **a tab's contents are not fetched until it is
shown**, so sixteen grids still cost one tab's worth of OData reads on open.

---

## 70. The same duplicate-definition bug, three times, and the third one reverted a day of work

The screen went back to showing the Hungarian Grand Prix of 26 July, and the
track map back to drawing five circuits at once. Both had been fixed hours
earlier and nothing had touched either fix.

What touched them was publishing an unrelated resource. `Story` is published on
`F1LiveNowApi`, which is defined in `15-live.mdl` — and `15-live.mdl` also
carried its own copies of the seven read microflows behind that service, the
CSV-and-DuckDB versions that `22-live-screen.mdl` was written to replace. One
`mxcli exec` of 15 silently reverted all seven.

The tell was a timestamp. `fetchedAt` read `2026-08-21 15:50:57Z` — space
separated, the CSV's format — where `Sync_Context` writes ISO-8601 with a `T`.
The screen was not showing stale data; it was running stale *code*.

### Three times, same shape

| | duplicated in | symptom |
|---|---|---|
| 59 | `SE_LiveSync` in 19 and 20 | script order decided which tiers a race captured |
| 61 | `RowId` in 21 vs 19/20 | `CE1613`, the publish blocks lost their key |
| 70 | seven `Read_Live*` in 15 and 22 | the screen reverted to CSVs a day after being repointed |

**A definition that lives in two files belongs to whichever ran last.** Three
times is no longer bad luck; it is what `create or replace` invites when a file
is organised by *topic* rather than by *ownership*. 15 owns the service, so it
felt natural to keep the service's read microflows beside it — and 22 was
written to replace exactly those.

The rule that would have prevented all three: **before adding a definition,
grep the model for its name.** One command, and it is the same command that
diagnosed each of them afterwards.

15 now carries only the service and its publish blocks, plus a comment saying
where the reads live and why they are not here.

### It also hid behind a real fix

Between the revert and noticing it, the circuit was "wrong" again — and I had
already written 66 about misdiagnosing that same star twice. The fourth
explanation was neither of the first three: the session filter was still in the
source, just not in the model.

**When a fixed thing breaks again, check that the fix is still deployed before
re-deriving it.** `describe` on the microflow would have shown the CSV version
immediately.

## 71. A watermark that only rises, and the cars it left behind

> "In the position by lap i would expect all (or most) lines to end at lap 24,
> but only 2 lines end there. Seems to suggest only 2 drivers finished the
> complete race?"

Two answers, and the first one hid the second for a day.

**The screen was showing qualifying, not a race.** The sync was parked on
Sunday's race, which had not run, so `Live_CurrentKey` fell back to the newest
session that had laps — Saturday's qualifying. In qualifying cars run wildly
different lap counts by design: knocked out in Q1 you do ten laps and go home,
survive to Q3 and you do twenty-five. Lines ending at different laps is what
qualifying *looks like*.

That explanation is true and it is not sufficient. Ground truth for the session
is 377 laps. The database held 255.

### The watermark

```
DECLARE $From Long = 1;
RETRIEVE $Seen FROM Formula1Backend.LiveLap
  WHERE SessionKey = $Key SORT BY LapNumber DESC LIMIT 1;
IF $Seen != empty AND $Seen/LapNumber > 2 THEN
  SET $From = $Seen/LapNumber - 1;
END IF;
```

Fetch only the laps you do not already have. Sound, and the comment beside it
was proud of the arithmetic: *steady state is twenty rows a minute, not
fourteen hundred.*

The flaw is in the first line of the retrieve. `SORT BY LapNumber DESC LIMIT 1`
is a maximum **across all cars**, and cars are not all on the same lap. The
moment one car's lap number runs ahead, the window closes over everyone behind
it — and because the watermark only ever rises, those laps are never asked for
again. Not fetched late. Fetched never.

Diffing the stored session against the API says it exactly:

| car | stored last lap | actual last lap |
|---|---|---|
| 44 | 25 | 25 |
| 30 | 25 | 25 |
| 16 | **8** | 23 |
| 41 | **9** | 22 |
| 1 | **9** | 21 |
| 27 | 19 | 19 |
| 11 | 10 | 10 |

The pattern is the mechanism. The two cars that ran the most laps are complete,
because they are the ones that set the watermark. The Q1 casualties are
complete, because they finished before the watermark passed them. Everyone in
the middle is cut off at whatever lap the leader had reached while they were
still running.

### It was not only qualifying

Qualifying is the extreme case, so it is where it became visible. The sprint —
a real race, everyone within a lap of each other — was quietly missing 21 of
506 rows, twenty of them a single lapped car's entire race after lap 1. It had
been captured live, checked, written up as complete, and committed as the mock
fixture.

**In a race the bug is rarer and worse.** Rarer because lap numbers stay
roughly synchronised; worse because the car it silently deletes is always a
lapped one, and a lapped car is exactly the car whose story the chart is there
to tell.

### The narrowing was not buying anything

The fix is to delete it. What made that easy was measuring what it saved, for
one full grand prix:

| endpoint | rows | raw |
|---|---:|---:|
| intervals | 29,593 | 4.36 MB |
| laps | 1,423 | 0.71 MB |
| position | 536 | 0.06 MB |
| stints | 67 | 0.01 MB |
| pit | 44 | 0.01 MB |

Four of the five were already unfiltered — the ASOF join wants position samples
from *before* the current lap, so trimming them would break the derivation
rather than speed it up. **Laps were 13% of the bytes and 100% of the data
loss.**

A load test settled the rest: pointed at Hungary — 70 laps, 1,423 laps, 29,593
intervals — a cycle completes all three passes in **49 seconds**, inside both
the 45-second internal deadline and the 60-second schedule.

### Repair

Because every fetch now asks for the whole session and merges over what is
stored, repairing a damaged capture is just pointing the sync at it for a
cycle:

| session | before | after | truth |
|---|---:|---:|---:|
| qualifying 11349 | 255 | 375 | 377 |
| sprint 11348 | 485 | 506 | 506 |

The two qualifying rows still missing are car 27 lap 1 and car 87 lap 1, both
of which OpenF1 returns with `date_start: null` and `lap_duration: null`. The
ASOF join needs a timestamp; dropping them is correct.

### What to take from it

An incremental fetch needs a watermark that is a **floor over the slowest
member**, not a maximum over the fastest — or no watermark at all. And the
check that would have caught this on day one is cheap: **after a capture,
count the rows against the source.** Both sessions had been eyeballed on screen
and both looked right, because a timing screen shows each car at its own last
lap and a car frozen ten laps ago looks identical to a car that retired.

# Findings

Durable notes for the next session, and feedback worth sending back upstream to
mxcli. Append, do not rewrite.

**Versions in play**

| | |
|---|---|
| mxcli | built from source, `ako/mxcli` main. §1–§10 on `9236202`; §11–§13 on `1bdd46a`; §14–§19 on **`45ae6a6`** |
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

## Suggested mxcli issues

### Still open

1. **A published `Integer` is written as `Edm.Int32`; Mendix wants `Edm.Int64`** (§16) —
   `mendixAttrTypeToEdm`, `cmd_odata.go:1625`. Every whole-number attribute in a
   published service fails the build until you switch it to `long`. One line, and the
   function's own comment flags Integer as unverified.
2. **`mxcli test --local` silently displaces the app's After-startup microflow** (§19) —
   a suite that needs startup state passes under `--attach` and fails under `--local`
   for reasons unrelated to the code. Say so in the output, or chain the original.
3. **`mxcli test --list` ignores a project-relative path** (§15) — `resolveTestPaths`
   sits below the `--list` branch in `cmd_test_run.go:136`.
4. **`MDL-ODATA01`'s hint omits `Countable`/`SkipSupported`/`TopSupported`** (§15),
   which `fa0cdb6` added and the checker accepts.
5. **`.ai-context/skills/` does not follow a binary upgrade** (§15) — stale skills after
   `mxcli` is rebuilt, with no warning.
6. **Lint idea:** `KEY` on a persistable attribute with no `unique` validation is always
   a build error (§17). `mxcli check` could catch it instead of `mxbuild`.
7. **`create module role` has no `or modify` form**, so a security script cannot be
   re-run — the reason this repo has a separate `07-demo-users.mdl`.

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

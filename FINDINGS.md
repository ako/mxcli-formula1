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

- `type 'BYOD'` has only been shown to *write* cleanly through mxcli and to be a
  valid value in the Studio Pro editor. It has **not** been round-tripped through
  `mx check` or exercised against a booted runtime. Do that before trusting it.
- The DuckDB numbers above come from a standalone JVM. Behaviour inside the
  Mendix runtime — driver discovery from `userlib/`, connection pooling against
  an in-memory DuckDB, and whether each pooled connection gets its own empty
  database — is untested.
- No `mx check` has been run against either app yet; both are still the blank
  template plus theme and `ApplicationRootUrl`.

# Warm Local Dev Loop — `mxcli run --local`

## Overview

`mxcli run --local` runs a Mendix app **without Docker**, keeping a
`mxbuild --serve` process and a standalone runtime hot so model changes apply in
~1 s instead of a ~30–60 s rebuild-and-restart. Use it as the fast inner loop when
iterating on an app; use `mxcli docker run` when you need the fully-rendered browser
client (see the limitation below).

## When to Use This Skill

Use this when:
- You want the fastest edit → running-app loop for a Mendix 11.x project.
- You're driving the model programmatically (`mxcli exec`/MDL) and want each change
  live immediately.
- You're iterating on **page design** (the app renders in a real browser) or doing
  runtime/model/API/headless verification.

Prefer `mxcli docker run` when:
- The project is Mendix 9/10 (JDK 11/17 — not yet supported by `run --local`).
- You want a container-parity deployment rather than a standalone runtime.

## Usage

```bash
# boot once and keep serving (Ctrl-C to stop)
mxcli run --local -p app.mpr

# boot and hot-apply on every project change
mxcli run --local -p app.mpr --watch
```

## How apply is chosen

Every warm rebuild reports whether a restart is required; `run --local` applies the
cheapest action automatically:

| Change | Apply | Cost |
|--------|-------|------|
| page / microflow / nanoflow / text | hot `reload_model` (no restart) | ~1 s |
| entity / view entity / association | runtime restart + DDL | ~9 s |

Structural changes need a restart because the runtime reconciles its entity/
association catalog only at startup; behavioural changes are hot-reloaded.

## Prerequisites

- **Mendix 11.x** project (runtime launches under **JDK 21**).
- A **PostgreSQL** database (defaults: `127.0.0.1:5432`, user `mendix`, db derived
  from the project name; override with `--db-host/--db-name/--db-user/--db-password`).
  - **`--ensure-db`** provisions it for a fresh session: starts local Postgres if the
    port is down and creates the role + database if missing (local superuser via
    `sudo -u postgres`). Remote hosts are only checked, not provisioned.
  - Without `--ensure-db`, create it once and the command errors if it's unreachable:

    ```bash
    createdb -h 127.0.0.1 -U mendix "$(basename app.mpr .mpr | tr '[:upper:]' '[:lower:]')"
    ```

## The intended loop

```bash
# terminal 1: keep the app hot
mxcli run --local -p app.mpr --watch

# terminal 2 (or an agent): edit the model — the change hot-applies automatically
mxcli exec add-page.mdl -p app.mpr
```

`--watch` observes two source trees and rebuilds when either changes: the **model
source** (`.mpr` + `mprcontents/`, v1 and v2 layouts) and the **theme source**
(`theme/` and `themesource/<module>/web/` — SCSS/CSS/JS). It ignores build output
(`deployment/`, `theme-cache/`, `.mendix-cache/`, `.mxcli/`). Both signals are mtime
polling, so they work on container filesystems where inotify is silent. Each apply is
logged with a build-generation counter (`build #2`, …) so you can confirm a change
landed.

## Editing themes (SCSS) — rebuild, never clear caches

A theme edit (`theme/web/main.scss`, module SCSS) needs a **rebuild**, not a
cache-clear. With `--watch`, just save the `.scss` — the theme source is watched and
the loop rebuilds and hot-applies. Without `--watch`, nothing is watched, so the save
does nothing until you restart `run --local` (or re-run with `--watch`). `mxbuild
--serve` recompiles the theme on its next build and correctly picks up SCSS content
changes, so **never** `rm -rf theme-cache/ .mendix-cache/ deployment/` — clearing
caches is a red herring.

A **theme compile error fails the build step, before the runtime starts** — the
error text is in the serve `/build` output (printed by `run --local`), not a
runtime problem. A common Dart Sass trap: `rgba()` needs a real color, so a
comma-list variable is rejected —

```scss
// WRONG: Dart Sass reports "$color: 168, 50, 30 is not a color"
$cf-over: 168, 50, 30;
background-color: rgba($cf-over, 0.1);

// RIGHT: make the variable a color, then adjust alpha
$cf-over: rgb(168, 50, 30);
background-color: rgba($cf-over, 0.1);
```

## "My edit didn't show up" — stale process, not stale cache

`run --local` refuses to boot when its ports (8080/8090/6543) are already answering,
because a leftover `run --local` / `mxbuild --serve` / runtime would otherwise be
silently adopted and keep serving old output (it looks like a cache but is a stale
**process**). If a background `run --local` died while its serve+runtime kept serving,
recover with:

```bash
pgrep -af 'mxbuild --serve|runtimelauncher|mxcli run'   # find them
kill <pid>                                              # stop each
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080  # want 000
```

Launch `run --local` as the **sole** command in its invocation (don't chain a trailing
`sleep`/`curl` whose non-zero exit can kill the backgrounded run); poll separately.

## Flags

| Flag | Default | Purpose |
|------|---------|---------|
| `--local` | — | Required; run without Docker (implied by `--hub`) |
| `--hub` | — | Expose the app in a browser at a tunnel-hub URL (see below) |
| `--hub-secret` | — | Shared auth (`user:pass`) matching an **open** hub's `--secret` |
| *(hub API key)* | — | For an **authenticated** hub: get one from `https://<hub>/cli`, set `MXCLI_HUB_KEY` (see below) |
| `--watch` | off | Rebuild + hot-apply on each change |
| `--ensure-db` | off | Provision local Postgres + app database if missing |
| `--setup` | off | Cache MxBuild+runtime + ensure DB, then exit (SessionStart bring-up) |
| `--screenshot` | off | Playwright PNG after boot + each change |
| `--screenshot-path` / `--screenshot-url` | `.mxcli/run-local.png` / app root | Screenshot output / page (URL or `/path`) |
| `--screenshot-user` / `--screenshot-password` | — | Log in once, reuse session (pages behind login) |
| `--runtime-log` | `.mxcli/runtime.log` | Runtime log file: JVM stdout/stderr **and** the application log (microflow `LOG` output + server stack traces, via an attached file log subscriber). `-` disables. |
| `--test-endpoint` | off | Host mxcli's token-guarded test endpoint so `mxcli test … --attach` can run a suite against this app with no boot of its own. Installed **before** the boot (the handler registers from after-startup), your own after-startup microflow is chained not displaced, and both are removed on exit. See `test-microflows.md`. |
| `--debug` | off | Enable the microflow debugger at boot + start a session, so `mxcli debug break/paused/…` works from another terminal (see `debug-microflows.md`). No breakpoints = no behaviour change; disabled on shutdown. |
| `--debug-pass` | `mxdebug` | Debugger password when `--debug` is set |
| `--metrics` | off | Register a Prometheus meter registry at boot; the runtime serves metrics at `http://127.0.0.1:<admin-port>/prometheus` |
| `--trace` | off | Enable OpenTelemetry tracing (bundled agent, console exporter → the runtime log) with default span filters |
| `--trace-service` | `.mpr` name | `OTEL_SERVICE_NAME` under `--trace` |
| `--trace-otlp` | off (console) | Export traces to this OTLP collector endpoint (e.g. `http://127.0.0.1:4318`) instead of the console. Implies `--trace`. Needed for flame charts |
| `--runtime-setting Key=Value` | — | Merge an extra runtime setting into the boot config (Value parsed as JSON when possible). Repeatable. |

## Metrics and OpenTelemetry

**Metrics (`--metrics`):** the Mendix runtime ships Micrometer registries but starts
with none. `--metrics` registers a **Prometheus** registry at boot, so
`http://127.0.0.1:8090/prometheus` (the admin port) serves ~70+ metric families
(`connectionbus_*`, `handler_requests_total`, `sessions_*`, `taskqueue_*`, …). For a
different registry use `--runtime-setting`, e.g.
`--runtime-setting 'Metrics.Registries=[{"type":"otlp","settings":{"step":"PT10S"}}]'`
(also `influx`, `statsd`, `jmx`).

**Why this is a flag, not a post-boot API call:** the admin `update_configuration`
action **replaces** the whole config (there's no read-back), so a separate call to add
metrics would wipe the DB/BasePath settings. `--metrics`/`--runtime-setting` merge into
mxcli's single boot `update_configuration`, which is the only safe way.

**Traces (`--trace`):** the runtime bundles the OpenTelemetry Java agent;
`--trace` attaches it to the runtime JVM and applies the default span filters:

```bash
mxcli run --local -p app.mpr --trace                 # spans -> runtime.log
mxcli run --local -p app.mpr --trace --runtime-log - # spans to console only
```

Spans (tracer `com.mendix.runtime`, attrs `mx.microflow.name`/`mx.microflow.depth`) go
to the console exporter → `runtime.log` (so `tail -f .mxcli/runtime.log` shows them).
`--trace` sets `OTEL_SERVICE_NAME` (default the `.mpr` name, override with
`--trace-service`) and, unless you set them yourself, `OTEL_TRACES_EXPORTER=console`
with metrics/logs exporters off.

**Why the default span filters matter:** unfiltered per-activity tracing is
**~10× slower**, so `--trace` ships `OpenTelemetry._RuntimeSpanFilters` =
`["CreateOrChangeVariable","Loop","Gateway","RetrieveFromCache"]` by default (keeping
the microflow-level spans). Override with
`--runtime-setting 'OpenTelemetry._RuntimeSpanFilters=[…]'`.

**Export to a collector (OTLP) instead of the console:** the console exporter
omits start/end timestamps and parent span IDs, so call trees and durations can't
be reconstructed from it — for flame charts, export to an OTLP collector. Pass
`--trace-otlp <endpoint>` (implies `--trace`); mxcli sets
`OTEL_TRACES_EXPORTER=otlp`, `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`, and
`OTEL_EXPORTER_OTLP_ENDPOINT` for you:

```bash
mxcli run --local -p app.mpr --trace-otlp http://127.0.0.1:4318
```

You can still set the `OTEL_*` env yourself for full control — `--trace` /
`--trace-otlp` never override an exporter you've already set:

```bash
export OTEL_TRACES_EXPORTER=otlp OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
mxcli run --local -p app.mpr --trace
```
| `--app-port` / `--admin-port` / `--serve-port` | 8080 / 8090 / 6543 | Ports |
| `--db-host` / `--db-name` / `--db-user` / `--db-password` | 127.0.0.1:5432 / derived / mendix / mendix | Database |

## Pages render in the browser

`run --local` bundles the browser client (`web/dist/`) with mxbuild's rollup tooling
after the deploy build, so the app renders in a real browser (verified with
Playwright + the devcontainer's Chromium).

- **`--watch`** keeps a long-lived incremental bundler hot (the client-side mirror of
  `mxbuild --serve`): a page/widget edit re-bundles in ~3–4 s; a microflow/entity edit
  skips the bundle and just hot-reloads. It uses `CHOKIDAR_USEPOLLING` because inotify
  is silent on container filesystems.
- Without `--watch`, a single one-shot bundle (~7 s) runs before boot.

## Pixel-perfect page loop

`--screenshot` captures a PNG (default `<projectDir>/.mxcli/run-local.png`) after boot
and after each applied change, via Playwright's built-in `screenshot` command
(Chromium from `PLAYWRIGHT_BROWSERS_PATH`):

```bash
mxcli run --local -p app.mpr --watch --screenshot
# edit a page -> auto rebuild -> re-bundle -> reload -> fresh screenshot
```

- `--screenshot-url /p/customers` shoots a specific page (bare path resolved against
  the app root; a full URL is used as-is). Repeat it for a multi-page set — each page
  gets its own PNG (`run-local-p-customers.png`, `run-local-home.png`).
- `--screenshot-user`/`--screenshot-password` log in once (Mendix form auth) and
  reuse the session, so pages behind login render authenticated. Best-effort: an
  anonymous app with no login form proceeds unauthenticated.

## Debugging a server-side error

When a page action throws, the browser shows the generic Mendix error dialog with no
detail. The runtime log — server stack traces and your microflow `LOG ERROR`/
`LOG INFO` output — is written to `<projectDir>/.mxcli/runtime.log` (the path is printed
at boot). `tail -f .mxcli/runtime.log` while you reproduce the action to see the stack
and correlate it.

Two things feed that file, because a standalone runtime attaches **no** log subscriber
by default (a Studio Pro / m2ee run does):

- mxcli tees the runtime **JVM's** stdout/stderr to it (startup output, JVM-level crashes).
- After start, mxcli attaches a Mendix **file log subscriber** so the **application** log
  — microflow `LOG` output and server-side exception stack traces — lands there too.
  Without this, application logs go nowhere and the file is nearly empty.

The file is appended across restarts (each boot writes a `=== runtime start … ===`
marker); the subscriber is re-attached on every restart and never rotates the file (so
the JVM tee's handle stays valid). Override the path with `--runtime-log <path>`, or
pass `--runtime-log -` to disable the file (and the subscriber) entirely.

## "Sign in failed" that is not about the password

The local runtime is **unlicensed**, and an unlicensed runtime caps concurrent
sessions at a handful. Past the cap it refuses the sign-in, and the login page
reports that as a plain **"Sign in failed"** — exactly what a wrong password
looks like. The real reason is written only to the runtime log:

```
Maximum number of sessions exceeded! (You are currently using a trial license)
```

So: when a login you know is correct starts failing, `grep -c "Maximum number of
sessions" .mxcli/runtime.log` before touching the credentials or the user's
password in the model. `--screenshot-user` does this for you — a rejected sign-in
now reads the log and says so instead of quietly screenshotting the login page.

Sessions are held until they expire; restarting `run --local` clears them all.
A script that drives the app through a browser should **sign out at the end**,
otherwise each run leaks a slot and the fifth or sixth run is the one that fails —
which makes it look like a change you just made broke authentication.

## External browser preview (`--hub`)

`--hub <url>` exposes the running app in a **browser at a public URL** without the app
leaving this machine and without committing — for reviewing work-in-progress from a
phone/tablet, or from an egress-only environment like Claude Code on the web. The app
stays here; a **chisel reverse tunnel** dials *out* to a hub over 443 and the hub proxies
browser requests back down it. Nothing is pushed — only live HTTP — and everything rides
one 443 connection, so it works through an egress-only proxy.

**You run your own hub — there is no hosted service.** Stand up `mxcli tunnel-hub` once on
a host you control (a small VPS with a domain), then point apps at it.

```bash
# on your VPS: *.example.com + hub.example.com -> this host, inbound 80+443 open
mxcli tunnel-hub --domain example.com --secret alice:s3cret

# where the app runs:
mxcli run --hub https://hub.example.com --hub-secret alice:s3cret -p app.mpr
#   -> registers and prints e.g. "Preview available at https://app.example.com"
```

The hub is **multi-tenant**: it fronts many previews at per-preview subdomains
(`<project>-<branch>.example.com`; `main`/`master` collapses to `<project>`) with a
sortable overview at `https://hub.example.com/`. Each `run --hub` self-registers:

- **Project** and **branch** auto-detect (`.mpr` name + git); override with
  `--hub-project` / `--hub-branch`. `--hub-worktree` distinguishes worktrees of one branch.
- **`--hub-prefix`** namespaces the hostname (org/solution/team/env) →
  `<prefix>-<project>-<branch>`; **`--hub-solution`** groups a solution's apps in the overview.
- The overview shows availability (a reaped/idle container goes **stale**), sortable by
  last-used / registered / project. Re-registering keeps a **stable URL**.
- `--hub` **implies `--local`**, boots the runtime with `ApplicationRootUrl` set to the
  assigned URL (so the SPA/`originURI` work), and the tunnel reconnects forever. Combine
  with `--watch` for the full loop: edit here → hot-apply → refresh the browser.

**Hub setup:** wildcard `*.example.com` A record (+ `hub.example.com`) → the VPS; inbound
80+443 open (per-subdomain Let's Encrypt on demand).

### Authenticated hub (GitHub)

A self-hosted hub started **without** the GitHub flags is open — the shared `--hub-secret`
is all `run --hub` needs. A hub started **with** `--github-oauth-client-id` (see
`mxcli tunnel-hub --help`) adds per-user isolation: browsers sign in with GitHub and see
only their own previews, and registration needs a **per-user hub API key** instead of the
shared secret.

**Get a key from the hub's browser page** (works from any device — desktop, or Claude
Code web/mobile, whose container can't reach GitHub's device endpoints):

1. Open `https://hub.mxcli.org/cli` in a browser and sign in with GitHub.
2. Click **Create a hub key** and copy it.
3. Set it as an environment/repo secret in your Claude Code environment — it's picked up
   automatically and survives container reaping:

```bash
export MXCLI_HUB_KEY=<key>
mxcli run --hub https://hub.mxcli.org -p app.mpr   # registers previews as you
```

The key is **durable** (no expiry, survives hub restarts) — you set it once. It stays valid
until you revoke it (sign out on the hub, or `mxcli auth hub logout`).

Headless alternative (CI, or a machine with a GitHub token): `mxcli auth hub login --token
<github-pat>` mints and caches a key in `~/.mxcli/auth.json` (mode 0600). The GitHub token
is used once for the mint and never stored.

**Registration failure is non-fatal:** if the hub is unreachable or the key is stale/rejected,
`run --hub` prints a warning and continues as a normal local run (the app boots on localhost;
only the public preview URL is lost). On an authenticated hub the shared `--hub-secret` still
works as a fallback registration credential — a valid key stamps the preview as yours, a valid
secret registers it owner-less.

## Validation checklist

- [ ] Project is Mendix 11.x.
- [ ] Postgres is running and the target database exists.
- [ ] `curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/` returns `200`,
      and `.../dist/index.js` also returns `200` (client bundle served).
- [ ] With `--watch`, editing a microflow logs `applied via reload`; adding an entity
      logs `applied via restart` and creates the table in Postgres.

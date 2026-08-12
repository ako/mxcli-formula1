# The solution devcontainer

One container holding both apps, a Postgres server and the whole toolchain, so
a clone needs Docker and nothing else. It is the same environment
`.claude/bootstrap-mxcli.sh` expects — the container supplies the dependencies
that script assumes are present, and then gets out of its way.

**Not** the two devcontainers under `Formula1Backend/` and `Formula1Frontend/`.
Those were written by `mxcli init`, cover one app each, and download a prebuilt
`mendixlabs/mxcli`; this repo runs both apps together and builds `ako/mxcli`
main from source. Root wins, for the same reason `.claude/settings.json` does.

## Starting it

Either way works, and neither is a prerequisite for the other:

```bash
npm i -g @devcontainers/cli && devcontainer up --workspace-folder .
```

or open the repo in VS Code and run **Dev Containers: Reopen in Container**.

First build is slow — a JDK, Node, Postgres, Go and a Chromium all arrive. The
first *session* is slower still, because the `SessionStart` hook then builds
mxcli from source, fetches ~25 MB of CSVs, and caches MxBuild plus the Mendix
runtime. Both are one-time; `~/.mxcli` is on a named volume so a rebuild does
not repeat the second one.

## Opening a Claude Code session in it

| You use | How |
|---|---|
| **VS Code** | `claude` in the integrated terminal, or the Claude Code extension panel — both already run inside the container |
| **Claude Code CLI** | `devcontainer exec --workspace-folder . claude` |
| **Claude Code Desktop** | over SSH — see below |

The desktop app's environment dropdown offers Local, Cloud, SSH and WSL. None of
those attach to a container directly, so SSH is the way in, and it is a
documented one: the docs name dev containers as an SSH target. That is why this
config includes the `sshd` feature and publishes 2222.

```bash
./.devcontainer/authorize-ssh-key.sh
```

Run that on your Mac once per rebuild. It pushes your public key in and prints
the connection settings to paste into **+ Add SSH connection**:

| Field | Value |
|---|---|
| SSH Host | `vscode@localhost` |
| SSH Port | `2222` |
| Identity File | `~/.ssh/id_ed25519` |

Desktop installs Claude Code on the far side itself the first time you connect,
so the container does not ship it.

Two things that follow from the session living in the container: `~/.claude/skills/`
resolves to the container's home, not your Mac's, so personal skills are not
there unless you put them there; and the `.claude` volume is what keeps you
signed in across rebuilds, together with `CLAUDE_CONFIG_DIR` — `~/.claude.json`
holds the OAuth account and sits outside `~/.claude`, so the volume alone would
not be enough.

## What is inside

| | |
|---|---|
| Temurin JDK 21 | MxBuild, and the `antlr4` launcher `build-mxcli.sh` needs |
| Go (current stable) | building mxcli; bookworm's own Go is 1.19, mxcli wants 1.24+ |
| `antlr4-tools` 0.2.2 | pre-installed, because bookworm's pip refuses the bare `pip install` in `build-mxcli.sh` (PEP 668) |
| Node 22 | the browser client bundle, and `scripts/shoot-screenshots.mjs` |
| Playwright + Chromium | the screenshots, pinned and arm64-aware — see the comments in the Dockerfile |
| Postgres | both Mendix databases and `f1ops`; roles `mendix` and `vscode`, trust auth |
| `python3`, `unzip`, `sed`, `make`, `git` | what the four fetch scripts and `create-f1ops-db.sh` shell out to |

`duckdb` is not installed and is not needed — DuckDB reaches the CSVs through
the JDBC driver that mxcli resolves into `vendorlib/`, not through a CLI.

## Ports

All published on the host's **loopback only**, so a laptop on an untrusted
network is not exposing a trust-auth Postgres.

| | |
|---|---|
| 8080 / 8090 / 6543 | backend — `http://backend.local:8080/` |
| 8180 / 8190 / 6643 | frontend — `http://frontend.local:8180/` |
| 8081 / 8091 / 6544 | `mxcli test --local` |
| 5432 | Postgres |
| 2222 | sshd |

`backend.local` and `frontend.local` are supplied with `--add-host` rather than
by the `/etc/hosts` append in the bootstrap script — Docker rewrites that file
at run time, and a non-root user cannot write it anyway, so the script's
`[ -w /etc/hosts ]` guard correctly skips it here.

Those hostnames resolve **inside** the container. To browse from the Mac, use
`http://localhost:8080/` and `http://localhost:8180/`, or add

```
127.0.0.1  backend.local frontend.local
```

to your Mac's `/etc/hosts` so the same URLs work on both sides. The cookie
problem the two names solve is a browser-side one, so if you browse from the
Mac, the Mac needs them too.

## Caveats

- **Postgres uses trust auth.** Any role, no password. Fine for a container
  whose 5432 is bound to loopback; do not copy this `pg_hba.conf` anywhere else.
- **No docker-in-docker.** `mxcli run --local` does not need it. Add
  `ghcr.io/devcontainers/features/docker-in-docker:2` to `features` if you want
  `./mxcli docker check`.
- **The trial licence caps concurrent sessions**, and a container makes it
  easier to accumulate them. The clear-out in the root README works here too:
  `sudo -u postgres psql -d formula1frontend -c 'delete from system$session;'`

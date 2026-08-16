#!/usr/bin/env bash
#
# Runs once, as root, when the container is first created.
#
# It provisions Postgres and fixes up the mounted volumes. It deliberately does
# NOT bootstrap the solution: .claude/settings.json already runs
# .claude/bootstrap-mxcli.sh on SessionStart, and that script is the same one a
# non-container clone uses. Duplicating it here would mean two things to keep in
# step, and the container would drift from the documented path.
set -euo pipefail

USER_NAME=vscode
USER_HOME="/home/$USER_NAME"

# ------------------------------------------------------------------ volumes
# Named volumes mount root-owned. Both of these are inside the user's home and
# are written by the user, so hand them over before anything else runs.
for d in "$USER_HOME/.claude" "$USER_HOME/.mxcli"; do
  mkdir -p "$d"
  chown -R "$USER_NAME:$USER_NAME" "$d"
done

# authorized_keys goes here; see authorize-ssh-key.sh. sshd is strict about
# these modes and fails closed, silently, if they are loose.
install -d -m 700 -o "$USER_NAME" -g "$USER_NAME" "$USER_HOME/.ssh"

# ---------------------------------------------------------------- ssh env
# sshd sanitises the environment, so neither the Dockerfile's ENV nor
# devcontainer.json's containerEnv survives into an SSH session — and SSH is how
# Claude Code Desktop gets in here. CLAUDE_CONFIG_DIR is the one that matters
# most: without it ~/.claude.json lands outside the mounted volume and the next
# rebuild signs you out, which is the exact failure the volume exists to
# prevent. A profile.d file is read by login shells, which is what sshd starts.
cat > /etc/profile.d/99-devcontainer-env.sh <<'ENV'
export CLAUDE_CONFIG_DIR=/home/vscode/.claude
export PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
export PLAYWRIGHT_CLI_SESSION=mendix-app
export ANTLR4_TOOLS_ANTLR_VERSION=4.13.2
export MXCLI_QUIET=1
ENV
chmod 0644 /etc/profile.d/99-devcontainer-env.sh

# -------------------------------------------------------------- data path
# A workaround, and it should not have to exist.
#
# Formula1Backend.DataDir defaults to /home/user/mxcli-formula1/data/f1db — the
# absolute path of the environment this repo was first built in, baked into the
# model. Anywhere else the backend fails its after-startup action with
# "No files found that match the pattern". The container is simply the first
# place that has been true.
#
# Overriding the constant at boot is the obvious fix and does not work:
# --runtime-setting MicroflowConstants REPLACES the whole map rather than
# merging with the model defaults, so passing DataDir alone leaves the other
# nine unset and the runtime dies on "Could not find value for constant
# 'Formula1Backend.ApiKey'". Passing all ten would mean restating every value on
# every boot command, including on `mxcli test` and the README's own examples.
#
# The symlink keeps all ten constants at their defaults, and covers data/facts/
# and data/laps/ too — which DataDir does not point at, and which are reached by
# their own hardcoded paths. The real fix is in the model: make DataDir relative
# to the project directory. Until then, this makes the documented commands work
# verbatim in here.
ln -sfn /workspaces/mxcli-formula1 /home/user/mxcli-formula1 2>/dev/null || {
  mkdir -p /home/user && ln -sfn /workspaces/mxcli-formula1 /home/user/mxcli-formula1
}

# ------------------------------------------------------------------- sudo
# The base image grants "vscode ALL=(root) NOPASSWD:ALL" — passwordless only
# when the target user is root. Everything in this repo that touches Postgres
# reaches it as somebody else: mxcli's --ensure-db, scripts/create-f1ops-db.sh
# and the session-clearing command in the README all run `sudo -u postgres`.
# Under the (root)-only rule that asks for a password, and with no tty it fails
# as "a terminal is required to read the password" — which reads like a sudo
# misconfiguration rather than what it is. Widening the target to (ALL) is what
# makes those three work unchanged.
echo "$USER_NAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/99-devcontainer-postgres
chmod 0440 /etc/sudoers.d/99-devcontainer-postgres
visudo -cf /etc/sudoers.d/99-devcontainer-postgres >/dev/null

# ----------------------------------------------------------------- postgres
# The Debian package usually creates a 'main' cluster in its postinst, but that
# depends on the package's own state at image build time, so do not assume it.
PGVER="$(ls /etc/postgresql 2>/dev/null | sort -V | tail -1 || true)"
if [ -z "$PGVER" ]; then
  PGVER="$(ls /usr/lib/postgresql | sort -V | tail -1)"
  pg_createcluster "$PGVER" main
fi
PGCONF="/etc/postgresql/$PGVER/main"
echo "configuring postgres $PGVER"

# Trust auth for everything. This is a development container whose Postgres is
# published only on the host's loopback (see appPort in devcontainer.json), so
# the reachability boundary is Docker's port binding rather than the password.
# It also means the connection strings in both .mpr files work whatever
# credentials they carry — nothing here has to match them.
cat > "$PGCONF/pg_hba.conf" <<'HBA'
# TYPE  DATABASE  USER  ADDRESS       METHOD
local   all       all                 trust
host    all       all   127.0.0.1/32  trust
host    all       all   ::1/128       trust
# Connections published from the host arrive from the Docker bridge gateway,
# not from 127.0.0.1, so they need a rule of their own.
host    all       all   all           trust
HBA

# Docker-bridge traffic does not arrive on the loopback interface either.
echo "listen_addresses = '*'" > "$PGCONF/conf.d/99-devcontainer.conf" 2>/dev/null \
  || echo "listen_addresses = '*'" >> "$PGCONF/postgresql.conf"

pg_ctlcluster "$PGVER" main start || service postgresql start

# 'mendix' is the role the two Mendix apps connect as, and the one
# scripts/create-f1ops-db.sh grants the f1ops database to. Superuser so that
# 'mxcli run --setup --ensure-db' can create its databases without a second
# credential. 'vscode' exists so a bare `psql` works for whoever is at the
# prompt — Postgres defaults the role name to the OS user.
for role in mendix "$USER_NAME"; do
  su postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='$role'\"" \
    | grep -q 1 \
    || su postgres -c "psql -q -c \"CREATE ROLE $role LOGIN SUPERUSER PASSWORD '$role';\""
done
# A bare `psql` also wants a database named after the role.
su postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='$USER_NAME'\"" \
  | grep -q 1 \
  || su postgres -c "createdb -O $USER_NAME $USER_NAME"

echo
echo "postgres $PGVER ready — roles: mendix, $USER_NAME (trust auth)"
echo "the solution itself is bootstrapped by .claude/bootstrap-mxcli.sh on SessionStart;"
echo "to do it by hand now:  sh .claude/bootstrap-mxcli.sh"

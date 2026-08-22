#!/usr/bin/env bash
#
# Runs as root on every container start, including after a plain `docker start`.
#
# A container has no init system, so nothing brings the Postgres cluster up by
# itself. Without this, a stopped-and-restarted container looks fine until the
# first query and then fails with "could not connect to server".
set -euo pipefail

PGVER="$(ls /etc/postgresql 2>/dev/null | sort -V | tail -1 || true)"
if [ -n "$PGVER" ]; then
  pg_ctlcluster "$PGVER" main start 2>/dev/null || service postgresql start || true
fi

# ----------------------------------------------------------------------- ssh
DCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Host keys are baked into the IMAGE (they are generated during the build, and
# say root@buildkitsandbox), not per container. So every image rebuild hands the
# container a brand new identity, and the client you connect from -- which
# rightly treats a changed host key as a possible man-in-the-middle -- refuses
# with "Host key verification failed" and makes you clear known_hosts again.
#
# Restoring one pinned set from the bind-mounted workspace makes the container's
# identity stable across rebuilds, so you trust it once and never again. Copied
# in BEFORE sshd starts, or it would come up on the old keys.
#
# The directory is gitignored: these are private host keys, and a shared one
# would let anyone holding the repo impersonate somebody else's container. Treat
# it as local-only. Delete the directory to go back to per-image keys.
HOSTKEYS="$DCDIR/ssh_host_keys"
if [ -d "$HOSTKEYS" ] && [ -n "$(ls -A "$HOSTKEYS" 2>/dev/null)" ]; then
  cp -a "$HOSTKEYS"/ssh_host_*_key "$HOSTKEYS"/ssh_host_*_key.pub /etc/ssh/ 2>/dev/null || true
  chown root:root /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
  chmod 600 /etc/ssh/ssh_host_*_key
  chmod 644 /etc/ssh/ssh_host_*_key.pub
  echo "ssh: restored pinned host keys ($(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}'))"
fi

# sshd is installed by the devcontainer feature but is likewise not started for
# us. Harmless when you are using VS Code or the CLI instead of the desktop app.
service ssh start 2>/dev/null || /usr/sbin/sshd 2>/dev/null || true

# ~/.ssh is not on a named volume, so an authorized key does not survive a
# rebuild -- which is why authorising used to be a once-per-rebuild chore run
# from the host. authorized_keys.local lives in the bind-mounted workspace
# instead, so it outlives both a rebuild and a `docker volume prune`, and this
# re-installs from it on every start. It is gitignored: it is your key, not the
# repo's. Public keys are not secrets; no private key ever enters the container.
#
# Merged rather than overwritten, so a key pushed in by authorize-ssh-key.sh
# (still the right tool for adding a second machine) is not clobbered.
KEYSRC="$DCDIR/authorized_keys.local"
if [ -s "$KEYSRC" ]; then
  AK=/home/vscode/.ssh/authorized_keys
  install -d -m 700 -o vscode -g vscode /home/vscode/.ssh
  touch "$AK"
  cat "$KEYSRC" >> "$AK"
  # Drop blanks and comment lines that the concatenation may have introduced.
  # The `|| true` matters: grep exits 1 on no match, which under `set -e` would
  # take the whole script down rather than leaving an empty key list.
  { grep -v '^[[:space:]]*\(#\|$\)' "$AK" || true; } | sort -u > "$AK.tmp"
  mv "$AK.tmp" "$AK"
  chown vscode:vscode "$AK"
  chmod 600 "$AK"
  echo "ssh: authorized $(wc -l < "$AK") key(s) for vscode"
fi

# ------------------------------------------------------------- app forwarders
# The Mendix runtime binds 127.0.0.1 only — mxcli reports "app serving at
# http://127.0.0.1:8080/" and `ss -ltn` confirms it. Docker's published ports
# forward to eth0, never to the container's loopback, so without this the apps
# answer 200 inside the container and refuse the connection from the host.
#
# Bind eth0's address specifically rather than 0.0.0.0: the runtime already
# holds 127.0.0.1:<port>, and a 0.0.0.0 bind would collide with it. socat
# listens straight away and dials 127.0.0.1 per connection, so it does not care
# that the app is not up yet — which is why starting it here, before either app
# boots, is fine.
#
# (VS Code's own forwardPorts reaches loopback services and would cover this,
# but only while VS Code is attached. This works for `devcontainer exec`, for a
# desktop SSH session, and for a plain `docker start` too.)
IP="$(hostname -I | awk '{print $1}')"
for port in 8080 8090 8180 8190 8081 8091; do
  pgrep -f "TCP-LISTEN:$port,bind=$IP" >/dev/null 2>&1 && continue
  socat "TCP-LISTEN:$port,bind=$IP,fork,reuseaddr" "TCP:127.0.0.1:$port" &
done

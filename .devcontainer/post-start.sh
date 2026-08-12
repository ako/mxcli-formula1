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

# sshd is installed by the devcontainer feature but is likewise not started for
# us. Harmless when you are using VS Code or the CLI instead of the desktop app.
service ssh start 2>/dev/null || /usr/sbin/sshd 2>/dev/null || true

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

#!/bin/sh
# Root SessionStart bootstrap for the Formula1 solution. COMMIT THIS FILE.
#
# Claude Code reads .claude/settings.json at the REPO ROOT, not the one that
# 'mxcli init' wrote inside each app folder — and it will not merge the two.
# So this script, not Formula1Backend/.claude/bootstrap-mxcli.sh, is what runs
# on session start, and it has to cover both apps.
#
# It differs from the generated per-app script in one more way: mxcli is BUILT
# from ako/mxcli main (scripts/build-mxcli.sh) rather than downloaded from the
# mendixlabs/mxcli nightly release.
#
# Everything it fetches is git-ignored and therefore absent from a fresh clone
# after an idle reap — that is exactly why it fetches rather than skips:
#   - ./mxcli and the two app hardlinks (~85 MB)
#   - data/f1db/*.csv (~25 MB, the historical F1 dataset)
# It then caches MxBuild + the Mendix runtime and provisions one Postgres
# database per app.
set -e

DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$DIR"

sh scripts/build-mxcli.sh
sh scripts/fetch-f1-data.sh

# The Wikipedia paragraphs behind the fan pages. Skipped when the file is
# already there; never fatal, because the backend only needs the CSV to exist
# and a header-only file yields an empty Facts resource rather than a 500.
if [ ! -f data/facts/f1db-facts.csv ]; then
  sh scripts/fetch-f1-facts.sh || echo "Facts fetch failed; pages will show no summaries."
fi

# Lap-by-lap traces from Jolpica — the one thing f1db does not carry. Same
# rules: skipped when present, never fatal, and the race weekend page falls back
# to an empty chart rather than an error.
if [ ! -f data/laps/f1db-laps.csv ]; then
  sh scripts/fetch-f1-laps.sh || echo "Lap fetch failed; the lap chart will be empty."
fi

# Two apps, two hostnames. Cookies are keyed on host name and ignore the port,
# so backend and frontend on localhost:8080 / localhost:8180 would share one
# cookie jar and silently overwrite each other's XASSESSIONID.
if [ -w /etc/hosts ] && ! grep -q 'backend\.local' /etc/hosts 2>/dev/null; then
  echo '127.0.0.1  backend.local frontend.local' >> /etc/hosts
fi

# Ports: the backend keeps the defaults (8080/8090/6543); the frontend is moved
# clear of them. Avoid 8081/8091/6544 — 'mxcli test --local' uses those.
(cd Formula1Backend  && ./mxcli run --local --setup --ensure-db -p Formula1Backend.mpr) || true
(cd Formula1Frontend && ./mxcli run --local --setup --ensure-db -p Formula1Frontend.mpr \
    --app-port 8180 --admin-port 8190 --serve-port 6643) || true

echo "Formula1 solution ready."
echo "  backend :  cd Formula1Backend  && ./mxcli run --local -p Formula1Backend.mpr"
echo "             http://backend.local:8080/"
echo "  frontend:  cd Formula1Frontend && ./mxcli run --local -p Formula1Frontend.mpr --app-port 8180 --admin-port 8190 --serve-port 6643"
echo "             http://frontend.local:8180/"

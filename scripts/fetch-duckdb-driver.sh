#!/bin/sh
# Fetch the DuckDB JDBC driver into Formula1Backend/userlib/.
#
# The backend reads the CSVs through Mendix's External Database Connector with
# database type 'BYOD' ("Other" — bring your own driver), which needs the JDBC
# jar on the app's classpath. The jar is 82 MB (it bundles native libraries for
# every platform), so it is git-ignored and re-fetched like the mxcli binary.
#
# userlib/ is used rather than a module JAR dependency because the dependency
# declared via `ALTER MODULE … ADD JAR DEPENDENCY` never reached the generated
# Gradle build under `mxbuild --serve` — see FINDINGS.md §12.
#
# Pin a version with DUCKDB_VERSION=x.y.z.n (default: the verified one).
set -e

DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION="${DUCKDB_VERSION:-1.5.5.1}"
DEST="$DIR/Formula1Backend/userlib"
JAR="$DEST/duckdb_jdbc-${VERSION}.jar"
URL="https://repo1.maven.org/maven2/org/duckdb/duckdb_jdbc/${VERSION}/duckdb_jdbc-${VERSION}.jar"

if [ -f "$JAR" ] && [ "${DUCKDB_FORCE:-0}" != 1 ]; then
  echo "DuckDB JDBC driver already present ($(basename "$JAR"))"
  exit 0
fi

mkdir -p "$DEST"
echo "Fetching DuckDB JDBC driver ${VERSION} (~82 MB) ..."
tmp="$JAR.part"
if ! curl -fsSL --max-time 600 -o "$tmp" "$URL"; then
  rm -f "$tmp"
  echo "Could not download $URL" >&2
  exit 1
fi

# Maven serves HTML error pages with a 200 in some proxy setups, so check that
# what arrived is actually a jar (PK zip magic) before putting it in userlib.
if ! head -c 2 "$tmp" | grep -q 'PK'; then
  rm -f "$tmp"
  echo "Downloaded file is not a jar — check the proxy or the version." >&2
  exit 1
fi

# Drop any older driver so two versions never sit on the classpath together.
rm -f "$DEST"/duckdb_jdbc-*.jar
mv "$tmp" "$JAR"
echo "DuckDB JDBC driver ready: $JAR"

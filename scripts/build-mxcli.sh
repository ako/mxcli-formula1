#!/bin/sh
# Build mxcli from source (ako/mxcli main) and install it at the repo root.
#
# This solution deliberately does NOT use the prebuilt mendixlabs/mxcli nightly
# binary that 'mxcli init' wires into each app's own bootstrap script. It builds
# ako/mxcli main instead, so the generated .claude/bootstrap-mxcli.sh inside
# Formula1Backend/ and Formula1Frontend/ is bypassed by the root hook.
#
# 'go install ...@latest' does not work: the ANTLR parser under
# mdl/grammar/parser/ is generated, not committed, so 'make grammar' has to run
# first. That needs a JVM and the antlr4 launcher (pip package antlr4-tools).
#
# Pin a commit with MXCLI_REF=<sha|tag> (default: main).
set -e

DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SRC="${MXCLI_SRC:-$DIR/.mxcli-src}"
REF="${MXCLI_REF:-main}"
ANTLR_VERSION="${ANTLR4_TOOLS_ANTLR_VERSION:-4.13.2}"
export ANTLR4_TOOLS_ANTLR_VERSION="$ANTLR_VERSION"

if [ -x "$DIR/mxcli" ] && [ "${MXCLI_FORCE:-0}" != 1 ]; then
  echo "mxcli already present: $("$DIR/mxcli" --version 2>/dev/null || echo unknown)"
  exit 0
fi

for tool in go java; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Cannot build mxcli: '$tool' is not installed." >&2
    echo "Install Go 1.24+ and a JDK, or drop a prebuilt mxcli binary at $DIR/mxcli." >&2
    exit 1
  }
done

if ! command -v antlr4 >/dev/null 2>&1; then
  echo "Installing antlr4-tools ..."
  pip install --quiet 'antlr4-tools==0.2.2' >/dev/null 2>&1 || {
    echo "Could not install antlr4-tools (needed to generate the MDL parser)." >&2
    exit 1
  }
fi

if [ -d "$SRC/.git" ]; then
  git -C "$SRC" fetch --depth 1 origin "$REF"
  git -C "$SRC" checkout -q FETCH_HEAD
else
  git clone --depth 1 --branch "$REF" https://github.com/ako/mxcli "$SRC" 2>/dev/null \
    || git clone --depth 1 https://github.com/ako/mxcli "$SRC"
fi

echo "Building mxcli from $(git -C "$SRC" rev-parse --short HEAD) ..."
make -C "$SRC" build

cp "$SRC/bin/mxcli" "$DIR/mxcli"
chmod +x "$DIR/mxcli"

# Each app folder needs its own ./mxcli — the app-level .claude/settings.json,
# AGENTS.md and devcontainer all invoke it as a relative path. Hardlink so the
# 85 MB binary is stored once.
for app in Formula1Backend Formula1Frontend; do
  if [ -d "$DIR/$app" ]; then
    rm -f "$DIR/$app/mxcli"
    ln "$DIR/mxcli" "$DIR/$app/mxcli" 2>/dev/null || cp "$DIR/mxcli" "$DIR/$app/mxcli"
  fi
done

echo "mxcli installed: $("$DIR/mxcli" --version)"

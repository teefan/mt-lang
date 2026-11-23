#!/usr/bin/env bash
# release_smoke.sh — verify a release package on a clean path.
#
# Usage: tools/release_smoke.sh PACKAGE.tar.gz [VERSION]
#
# Extracts the archive outside the repository and checks, with no repository on
# the compiler's ancestor path and no MILK_TEA_*_ROOT overrides:
#
#   0. `install.sh` installs the archive to a temporary prefix, and the
#      installed binary is used for the remaining checks;
#   1. `mtc version` reports the expected version;
#   2. a program importing `std.stdio` builds and runs (std resolution);
#   3. `mtc lsp --stdio` answers an initialize handshake;
#   4. `mtc docs` serves the reference page plus the packaged CSS/JS assets and
#      404s an unknown route.
#
# The docs check is skipped when curl is unavailable.  Exit status: 0 on
# success, 1 on the first failure.
set -euo pipefail

TARBALL="${1:-}"
VERSION="${2:-}"
if [ -z "$TARBALL" ] || [ ! -f "$TARBALL" ]; then
    echo "usage: tools/release_smoke.sh PACKAGE.tar.gz [VERSION]" >&2
    exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mtc-release-smoke-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

tar xzf "$TARBALL" -C "$WORK"
PKG="$(find "$WORK" -maxdepth 1 -mindepth 1 -type d | head -1)"
if [ -z "$PKG" ] || [ ! -x "$PKG/bin/mtc" ]; then
    echo "release_smoke: FAIL: archive has no bin/mtc" >&2
    exit 1
fi
MTC="$PKG/bin/mtc"

fail() {
    echo "release_smoke: FAIL: $*" >&2
    exit 1
}

REPORTED="$(env -u MILK_TEA_MODULE_ROOT -u MILK_TEA_STD_ROOT "$MTC" version)"
if [ -n "$VERSION" ] && [ "$REPORTED" != "mtc $VERSION" ]; then
    fail "version reports '$REPORTED', expected 'mtc $VERSION'"
fi

# ── 0. installer ─────────────────────────────────────────────────────────────

if [ ! -x "$PKG/install.sh" ]; then
    fail "archive has no executable install.sh"
fi
INSTALL_PREFIX="$WORK/prefix"
INSTALL_BIN="$WORK/install-bin"
if ! "$PKG/install.sh" --prefix "$INSTALL_PREFIX" --bin-dir "$INSTALL_BIN" \
    >"$WORK/install.log" 2>&1; then
    cat "$WORK/install.log" >&2
    fail "install.sh"
fi
MTC="$INSTALL_BIN/mtc"
ARCHIVE_VERSION="$(cat "$PKG/VERSION")"
INSTALLED="$(env -u MILK_TEA_MODULE_ROOT -u MILK_TEA_STD_ROOT "$MTC" version)"
if [ "$INSTALLED" != "mtc $ARCHIVE_VERSION" ]; then
    fail "installed compiler reports '$INSTALLED', expected 'mtc $ARCHIVE_VERSION'"
fi

# ── 1. std resolution and a real program ────────────────────────────────────

APP="$WORK/app"
mkdir -p "$APP"
cat > "$APP/hello.mt" <<'MT'
import std.stdio as stdio

function main() -> int:
    stdio.print_line("release ok")
    return 0
MT
if ! (cd "$APP" && env -u MILK_TEA_MODULE_ROOT -u MILK_TEA_STD_ROOT "$MTC" build hello.mt -o hello >build.log 2>&1); then
    cat "$APP/build.log" >&2
    fail "build hello.mt"
fi
OUTPUT="$(cd "$APP" && ./hello)"
if [ "$OUTPUT" != "release ok" ]; then
    fail "hello output '$OUTPUT'"
fi

# ── 2. LSP initialize handshake ─────────────────────────────────────────────

WS="$WORK/ws"
mkdir -p "$WS"
printf 'function main() -> int:\n    return 0\n' > "$WS/main.mt"
PAYLOAD="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"processId\":null,\"rootUri\":\"file://$WS\",\"capabilities\":{},\"workspaceFolders\":[{\"uri\":\"file://$WS\",\"name\":\"ws\"}]}}"
RESPONSE="$(
    { printf 'Content-Length: %d\r\n\r\n%s' "${#PAYLOAD}" "$PAYLOAD"; sleep 1; } \
        | timeout 8 "$MTC" lsp --stdio 2>/dev/null || true
)"
case "$RESPONSE" in
    *'"capabilities"'*) ;;
    *) fail "lsp initialize produced no capabilities" ;;
esac

# ── 3. docs server and packaged assets ──────────────────────────────────────

if command -v curl >/dev/null 2>&1; then
    PORT=$((20000 + RANDOM % 20000))
    ( cd "$WORK" && exec "$MTC" docs --port "$PORT" ) > "$WORK/docs.log" 2>&1 &
    DOCS_PID=$!
    STARTED=0
    for _ in $(seq 1 60); do
        if curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then
            STARTED=1
            break
        fi
        sleep 0.1
    done
    if [ "$STARTED" -ne 1 ]; then
        cat "$WORK/docs.log" >&2 || true
        kill "$DOCS_PID" 2>/dev/null || true
        fail "docs server did not start on port $PORT"
    fi
    curl -fsS "http://127.0.0.1:$PORT/css/docs.css" | grep -q "font-family" \
        || { kill "$DOCS_PID" 2>/dev/null || true; fail "docs css route"; }
    curl -fsS "http://127.0.0.1:$PORT/js/docs.js" | grep -q "function" \
        || { kill "$DOCS_PID" 2>/dev/null || true; fail "docs js route"; }
    STATUS="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/nope")"
    kill "$DOCS_PID" 2>/dev/null || true
    wait "$DOCS_PID" 2>/dev/null || true
    [ "$STATUS" = "404" ] || fail "docs unknown route returned $STATUS"
else
    echo "release_smoke: curl not found — docs routes skipped"
fi

echo "release_smoke: ok ($REPORTED, $PKG)"

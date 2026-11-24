#!/usr/bin/env bash
# release.sh — build and package a native Milk Tea release.
#
# Usage:
#   tools/release.sh [--version X.Y.Z] [--out DIR] [--refresh-seed]
#                    [--skip-build] [-j N]
#
#   --version X.Y.Z   Expected version; must match cli_help.VERSION.  The
#                     version is an authored source constant, never derived
#                     from git.
#   --out DIR         Artifact directory (default: dist/).
#   --refresh-seed    Copy the release compiler into vendor/bootstrap/<platform>
#                     and regenerate mtc.sha256.  Commit the result to make it
#                     the seed for the next release cycle.
#   --skip-build      Package the existing build/stage2/mtc.
#   -j N              Parallel compiler jobs (default: 4, hard-capped).
#
# The package layout is the runtime contract:
#
#   mtc-<version>-<platform>/
#     bin/mtc            the compiler; `/proc/self/exe` locates the root
#     std/               resolved by the compiler from the binary's ancestors
#     docs/              served by `mtc docs`
#     docs_public/       stylesheet and script assets
#     VERSION, README.md, LICENSE
#
# Exit status: 0 when the package builds, packs, and passes the clean-path
# smoke test.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

VERSION=""
OUT="$ROOT/dist"
REFRESH_SEED=0
SKIP_BUILD=0
JOBS="$(nproc 2>/dev/null || echo 1)"
[ "$JOBS" -gt 4 ] && JOBS=4
PLATFORM="$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)"

while [ $# -gt 0 ]; do
    case "$1" in
        --version)      VERSION="${2:-}"; shift 2 ;;
        --out)          OUT="${2:-}"; shift 2 ;;
        --refresh-seed) REFRESH_SEED=1; shift ;;
        --skip-build)   SKIP_BUILD=1; shift ;;
        -j)             JOBS="${2:-}"; shift 2 ;;
        -h|--help)
            sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "release.sh: unknown option $1" >&2
            exit 2
            ;;
    esac
done

# Parallel compiler fan-out is memory-bound: keep it at or below 4.
if [ "$JOBS" -gt 4 ]; then
    echo "warning: -j $JOBS capped at 4 (parallel compiler fan-out is memory-bound)" >&2
    JOBS=4
fi

# The release contract is the OpenSSL 3 ABI (libssl.so.3).  On hosts whose
# default is OpenSSL 4, build through the wrapper so the archive still runs on
# the documented OpenSSL 3 systems; an explicit CC overrides this.
if [ -z "${CC:-}" ] && [ -x "$SCRIPT_DIR/cc-openssl3.sh" ]; then
    export CC="$SCRIPT_DIR/cc-openssl3.sh"
fi

SOURCE_VERSION="$(sed -n 's/^public const VERSION: str = "\([^"]*\)"$/\1/p' projects/mtc/src/mtc/cli_help.mt)"
if [ -z "$SOURCE_VERSION" ]; then
    echo "error: cannot read cli_help.VERSION" >&2
    exit 1
fi
if [ -n "$VERSION" ] && [ "$VERSION" != "$SOURCE_VERSION" ]; then
    echo "error: --version $VERSION does not match cli_help.VERSION $SOURCE_VERSION" >&2
    exit 1
fi
VERSION="$SOURCE_VERSION"
if ! grep -q "emit_line(to_err, \"mtc $VERSION " projects/mtc/src/mtc/cli_help.mt; then
    echo "error: cli_help help banner does not carry version $VERSION" >&2
    exit 1
fi

if [ "$SKIP_BUILD" -eq 0 ]; then
    echo "── building release compiler (stage2, profile release)"
    tools/bootstrap.sh --stage 2 --profile release -j "$JOBS"
fi

BIN="$ROOT/build/stage2/mtc"
if [ ! -x "$BIN" ]; then
    echo "error: $BIN missing; run without --skip-build" >&2
    exit 1
fi
REPORTED="$("$BIN" version)"
if [ "$REPORTED" != "mtc $VERSION" ]; then
    echo "error: built compiler reports '$REPORTED', expected 'mtc $VERSION'" >&2
    exit 1
fi

NAME="mtc-$VERSION-$PLATFORM"
STAGE="$OUT/$NAME"
rm -rf "$STAGE"
rm -f "$OUT/$NAME.tar.gz" "$OUT/$NAME.tar.gz.sha256"
mkdir -p "$STAGE/bin"

cp "$BIN" "$STAGE/bin/mtc"
cp -R std "$STAGE/std"
cp -R config "$STAGE/config"
cp -R docs "$STAGE/docs"
cp -R projects/mtc/src/mtc/docs_public "$STAGE/docs_public"
cp README.md LICENSE "$STAGE/"
cp "$ROOT/tools/install.sh" "$STAGE/install.sh"
chmod +x "$STAGE/install.sh"
printf '%s\n' "$VERSION" > "$STAGE/VERSION"

# Reproducible metadata: sorted entries, fixed owner and mtime, and gzip -n so
# the archive stores no timestamp.  Two runs over the same binary must produce
# the same checksum.
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='UTC 2020-01-01' \
    -cf - -C "$OUT" "$NAME" | gzip -9 -n > "$OUT/$NAME.tar.gz"
(cd "$OUT" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256")

if [ "$REFRESH_SEED" -eq 1 ]; then
    SEED_DIR="$ROOT/vendor/bootstrap/$PLATFORM"
    mkdir -p "$SEED_DIR"
    cp "$BIN" "$SEED_DIR/mtc"
    (cd "$SEED_DIR" && sha256sum mtc > mtc.sha256)
    echo "── seed refreshed: vendor/bootstrap/$PLATFORM/mtc"
fi

echo "── artifact: $OUT/$NAME.tar.gz"
cat "$OUT/$NAME.tar.gz.sha256"

tools/release_smoke.sh "$OUT/$NAME.tar.gz" "$VERSION"

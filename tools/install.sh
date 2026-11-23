#!/usr/bin/env bash
# install.sh — install this Milk Tea release archive.
#
# Usage:
#   ./install.sh [--prefix DIR] [--bin-dir DIR] [--force] [--dry-run]
#   ./install.sh --uninstall [--prefix DIR] [--bin-dir DIR] [--dry-run]
#
# Defaults:
#   --prefix   ~/.local/opt/mtc
#   --bin-dir  ~/.local/bin
#
# Layout:
#   PREFIX/<version>/          the complete archive (bin/, std/, docs/, ...)
#   PREFIX/current -> <version>
#   BIN_DIR/mtc -> PREFIX/current/bin/mtc
#
# The compiler resolves std/ and docs/ from its own executable path, so the
# whole archive is installed and only the binary is symlinked into BIN_DIR.
# Shell startup files are never edited; when BIN_DIR is not on PATH the script
# prints the line to add.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${HOME}/.local/opt/mtc"
BIN_DIR="${HOME}/.local/bin"
FORCE=0
DRY_RUN=0
UNINSTALL=0

usage() {
    cat <<'EOF'
Install a Milk Tea release archive.

Usage:
  ./install.sh [--prefix DIR] [--bin-dir DIR] [--force] [--dry-run]
  ./install.sh --uninstall [--prefix DIR] [--bin-dir DIR] [--dry-run]

Options:
  --prefix DIR     Install root (default: ~/.local/opt/mtc).
                   Versions live in DIR/<version>; DIR/current is a symlink.
  --bin-dir DIR    Where to link mtc (default: ~/.local/bin).
  --force          Replace an existing version or a non-symlink at the link
                   paths.
  --dry-run        Print the actions without changing anything.
  --uninstall      Remove this archive's version and its links.
  -h, --help       Show this help.
EOF
}

fail() {
    echo "install.sh: $*" >&2
    exit 1
}

run() {
    if [ "$DRY_RUN" = 1 ]; then
        echo "would: $*"
    else
        "$@"
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)
            [ $# -ge 2 ] || fail "--prefix needs a directory"
            PREFIX="$2"
            shift 2
            ;;
        --prefix=*)
            PREFIX="${1#--prefix=}"
            shift
            ;;
        --bin-dir)
            [ $# -ge 2 ] || fail "--bin-dir needs a directory"
            BIN_DIR="$2"
            shift 2
            ;;
        --bin-dir=*)
            BIN_DIR="${1#--bin-dir=}"
            shift
            ;;
        --force)
            FORCE=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --uninstall)
            UNINSTALL=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1 (try --help)"
            ;;
    esac
done

[ -f "$SCRIPT_DIR/VERSION" ] || fail "VERSION not found; run install.sh from an extracted release archive"
VERSION="$(cat "$SCRIPT_DIR/VERSION")"
[ -n "$VERSION" ] || fail "VERSION is empty"
[ -x "$SCRIPT_DIR/bin/mtc" ] || fail "bin/mtc not found; run install.sh from an extracted release archive"

REPORTED="$("$SCRIPT_DIR/bin/mtc" version)"
[ "$REPORTED" = "mtc $VERSION" ] || fail "archive compiler reports '$REPORTED', expected 'mtc $VERSION'"

INSTALL_DIR="$PREFIX/$VERSION"
CURRENT="$PREFIX/current"
BIN_LINK="$BIN_DIR/mtc"

if [ "$UNINSTALL" = 1 ]; then
    [ -d "$INSTALL_DIR" ] || fail "$INSTALL_DIR is not installed"

    if [ "$DRY_RUN" = 1 ]; then
        echo "would remove $INSTALL_DIR"
        echo "would remove $CURRENT and $BIN_LINK when they point at it"
        exit 0
    fi

    if [ -L "$CURRENT" ] && [ "$(readlink -f "$CURRENT")" = "$(readlink -f "$INSTALL_DIR")" ]; then
        rm -f "$CURRENT"
    fi
    if [ -L "$BIN_LINK" ]; then
        case "$(readlink "$BIN_LINK")" in
            "$PREFIX"/*) rm -f "$BIN_LINK" ;;
        esac
    fi
    rm -rf "$INSTALL_DIR"
    echo "uninstalled mtc $VERSION from $PREFIX"
    exit 0
fi

if [ -e "$BIN_LINK" ] && [ ! -L "$BIN_LINK" ]; then
    [ "$FORCE" = 1 ] || fail "refusing to overwrite $BIN_LINK (not a symlink); use --force"
    run rm -f "$BIN_LINK"
fi
if [ -e "$CURRENT" ] && [ ! -L "$CURRENT" ]; then
    [ "$FORCE" = 1 ] || fail "refusing to overwrite $CURRENT (not a symlink); use --force"
    run rm -rf "$CURRENT"
fi

if [ -d "$INSTALL_DIR" ] && [ "$FORCE" != 1 ]; then
    echo "mtc $VERSION is already installed at $INSTALL_DIR"
else
    if [ "$DRY_RUN" = 1 ]; then
        echo "would install mtc $VERSION to $INSTALL_DIR"
        echo "would link $CURRENT -> $VERSION"
        echo "would link $BIN_LINK -> $CURRENT/bin/mtc"
        exit 0
    fi

    mkdir -p "$PREFIX" "$BIN_DIR"
    TMP="$(mktemp -d "$PREFIX/.install.XXXXXX")"
    cleanup() {
        if [ -n "${TMP:-}" ]; then
            rm -rf "$TMP"
        fi
    }
    trap cleanup EXIT

    cp -a "$SCRIPT_DIR/." "$TMP/"
    COPIED="$("$TMP/bin/mtc" version)"
    [ "$COPIED" = "mtc $VERSION" ] || fail "installed compiler reports '$COPIED'"

    if [ -e "$INSTALL_DIR" ]; then
        rm -rf "$INSTALL_DIR"
    fi
    mv "$TMP" "$INSTALL_DIR"
    TMP=""
    echo "installed mtc $VERSION to $INSTALL_DIR"
fi

run ln -sfn "$VERSION" "$CURRENT"
run ln -sfn "$CURRENT/bin/mtc" "$BIN_LINK"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        echo
        echo "$BIN_DIR is not on PATH. Add this to your shell startup file:"
        echo "  export PATH=\"$BIN_DIR:\$PATH\""
        ;;
esac

if [ "$DRY_RUN" = 0 ]; then
    INSTALLED="$("$BIN_LINK" version)"
    [ "$INSTALLED" = "mtc $VERSION" ] || fail "$BIN_LINK reports '$INSTALLED'"
    echo "mtc $VERSION is ready at $BIN_LINK"
fi

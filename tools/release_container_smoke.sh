#!/usr/bin/env bash
# release_container_smoke.sh — run a release archive in a clean container.
#
# Usage: tools/release_container_smoke.sh PACKAGE.tar.gz [VERSION]
#
# The compiler is built on the host, so the archive is only portable if its
# documented runtime libraries are present on the target.  This smoke verifies
# the release outside the checkout in a minimal Ubuntu 24.04 image (glibc 2.39;
# the binary currently requires glibc >= 2.38):
#
#   * `mtc version` starts the binary with only libc/libssl/libz installed;
#   * a program importing `std.stdio` builds and runs (a C compiler is present);
#   * `mtc check` resolves the packaged standard library.
#
# Docker or Podman is required.  Set CONTAINER_ENGINE to force one, or
# REQUIRE_CONTAINER=1 to fail instead of skipping when neither is installed.
set -euo pipefail

TARBALL="${1:-}"
VERSION="${2:-}"
if [ -z "$TARBALL" ] || [ ! -f "$TARBALL" ]; then
    echo "usage: tools/release_container_smoke.sh PACKAGE.tar.gz [VERSION]" >&2
    exit 2
fi
TARBALL="$(cd "$(dirname "$TARBALL")" && pwd)/$(basename "$TARBALL")"

ENGINE="${CONTAINER_ENGINE:-}"
if [ -z "$ENGINE" ]; then
    if command -v docker >/dev/null 2>&1; then
        ENGINE=docker
    elif command -v podman >/dev/null 2>&1; then
        ENGINE=podman
    else
        if [ "${REQUIRE_CONTAINER:-0}" = "1" ]; then
            echo "release_container_smoke: FAIL: no Docker or Podman" >&2
            exit 1
        fi
        echo "release_container_smoke: skipped (no Docker or Podman)"
        exit 0
    fi
fi

IMAGE="${CONTAINER_IMAGE:-ubuntu:24.04}"
echo "release_container_smoke: engine=$ENGINE image=$IMAGE"

"$ENGINE" run --rm \
    -e MTC_RELEASE_VERSION="$VERSION" \
    -v "$TARBALL:/release.tar.gz:ro" \
    "$IMAGE" bash -lc '
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends \
            ca-certificates gcc libc6-dev libssl3t64 zlib1g tar >/dev/null

        mkdir -p /opt /work
        tar xzf /release.tar.gz -C /opt
        PKG="/opt/$(tar tzf /release.tar.gz | sed -n '1p' | cut -d/ -f1)"
        test -x "$PKG/bin/mtc"

        REPORTED="$("$PKG/bin/mtc" version)"
        if [ -n "${MTC_RELEASE_VERSION:-}" ] && [ "$REPORTED" != "mtc $MTC_RELEASE_VERSION" ]; then
            echo "release_container_smoke: FAIL: version $REPORTED, expected mtc $MTC_RELEASE_VERSION" >&2
            exit 1
        fi

        cd /work
        cat > hello.mt <<"MT"
import std.stdio as stdio

function main() -> int:
    stdio.print_line("container ok")
    return 0
MT
        "$PKG/bin/mtc" build hello.mt -o hello
        test "$(./hello)" = "container ok"
        "$PKG/bin/mtc" check hello.mt
        echo "release_container_smoke: ok ($REPORTED)"
    '

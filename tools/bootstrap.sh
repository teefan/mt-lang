#!/usr/bin/env bash
# Milk Tea bootstrap — 3-stage compiler build with fixed-point verification.
#
# Usage:
#   tools/bootstrap.sh [OPTIONS]
#
# Options:
#   --bootstrap PATH     Path to stage0 mtc binary (default: auto-detect)
#   --stage {1,2,3}      Build target stage (default: 3)
#   --no-verify          Skip stage3 fixed-point check
#   --fast               Fixed point only: implies --keep-c, skips the redundant
#                        self-test rebuild and the test suite (run gates_dev_tests
#                        / test_mt separately).  ~12 min instead of ~26; the
#                        remaining cost is the two self-builds (~5 min each).
#   --profile PROFILE    Build profile: debug or release (default: debug)
#   --keep-c             Save generated C files alongside binaries
#   --print-stage0       Resolve and verify stage0, print its path, and exit.
#
# A stage build is one whole-program `mtc build` invocation, so there is no
# parallel fan-out to control here; per-file fan-out belongs to the test and
# sweep harnesses (tools/lib/jobs.rb).
#
# Stage0 resolution order:
#   1. --bootstrap PATH (explicit)
#   2. $MTC_BOOTSTRAP environment variable
#   3. vendor/bootstrap/<platform>/mtc (committed seed, sha256-verified)
#   4. Error
#
# Output:
#   build/stage1/mtc  — compiler built by stage0
#   build/stage2/mtc  — compiler built by stage1 (distributable)
#   build/stage3/mtc  — compiler built by stage2 (verification)
#   build/stage2.c    — generated C for stage2 (with --keep-c)
#   build/stage3.c    — generated C for stage3 (with --keep-c)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# ── defaults ────────────────────────────────────────────────────────────────

BOOTSTRAP_PATH=""
TARGET_STAGE=3
SKIP_VERIFY=0
FAST=0
PROFILE="debug"
KEEP_C=0
PRINT_STAGE0=0
BUILD_DIR="${MTC_BUILD_DIR:-build}"

# ── argument parsing ─────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bootstrap)
            BOOTSTRAP_PATH="$2"
            shift 2
            ;;
        --stage)
            TARGET_STAGE="$2"
            shift 2
            ;;
        --no-verify)
            SKIP_VERIFY=1
            shift
            ;;
        --fast)
            FAST=1
            KEEP_C=1
            shift
            ;;
        --profile)
            PROFILE="$2"
            shift 2
            ;;
        --keep-c)
            KEEP_C=1
            shift
            ;;
        --print-stage0)
            PRINT_STAGE0=1
            shift
            ;;
        *)
            echo "unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# ── validate ─────────────────────────────────────────────────────────────────

if [[ ! "$TARGET_STAGE" =~ ^[123]$ ]]; then
    echo "error: --stage must be 1, 2, or 3 (got $TARGET_STAGE)" >&2
    exit 1
fi

if [[ "$PROFILE" != "debug" ]] && [[ "$PROFILE" != "release" ]]; then
    echo "error: --profile must be debug or release (got $PROFILE)" >&2
    exit 1
fi

# ── stage0 resolution ────────────────────────────────────────────────────────

# Verify the committed seed against its recorded sha256.  A mismatched seed is
# fatal: it means the binary was replaced or corrupted and its behaviour cannot
# be trusted as a build base.
verify_seed() {
    local seed_dir="$1"
    if [[ ! -f "$seed_dir/mtc.sha256" ]]; then
        echo "error: seed checksum missing: $seed_dir/mtc.sha256" >&2
        exit 1
    fi
    if ! (cd "$seed_dir" && sha256sum -c --quiet mtc.sha256) >&2; then
        echo "error: seed checksum mismatch: $seed_dir/mtc" >&2
        echo "  Replace the seed or pass --bootstrap PATH to use another compiler." >&2
        exit 1
    fi
}

resolve_stage0() {
    # 1. explicit --bootstrap
    if [[ -n "$BOOTSTRAP_PATH" ]]; then
        if [[ -x "$BOOTSTRAP_PATH" ]]; then
            echo "stage0: $BOOTSTRAP_PATH (--bootstrap)" >&2
            echo "$BOOTSTRAP_PATH"
            return
        fi
        echo "error: --bootstrap path is not executable: $BOOTSTRAP_PATH" >&2
        exit 1
    fi

    # 2. $MTC_BOOTSTRAP environment variable
    if [[ -n "${MTC_BOOTSTRAP:-}" ]]; then
        if [[ -x "$MTC_BOOTSTRAP" ]]; then
            echo "stage0: $MTC_BOOTSTRAP (\$MTC_BOOTSTRAP)" >&2
            echo "$MTC_BOOTSTRAP"
            return
        fi
        echo "error: \$MTC_BOOTSTRAP is set but not executable: $MTC_BOOTSTRAP" >&2
        exit 1
    fi

    # 3. committed seed for this platform
    local seed_platform seed_dir
    seed_platform="$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)"
    seed_dir="$PROJECT_ROOT/vendor/bootstrap/$seed_platform"
    if [[ -f "$seed_dir/mtc" ]]; then
        chmod +x "$seed_dir/mtc"
        verify_seed "$seed_dir"
        echo "stage0: $seed_dir/mtc (seed, sha256 verified)" >&2
        echo "$seed_dir/mtc"
        return
    fi

    # 4. Error
    echo "error: no bootstrap compiler found for $seed_platform." >&2
    echo "  expected seed: $seed_dir/mtc" >&2
    echo "  Pass --bootstrap PATH or set \$MTC_BOOTSTRAP." >&2
    echo "  See docs/bootstrap-design.md." >&2
    exit 1
}

MTC_STAGE0="$(resolve_stage0)"

if [[ "$PRINT_STAGE0" -eq 1 ]]; then
    echo "$MTC_STAGE0"
    exit 0
fi

# ── build flags ──────────────────────────────────────────────────────────────

FLAGS=(-I . --no-cache)
if [[ "$PROFILE" == "release" ]]; then
    FLAGS+=(--profile release)
fi
# The native build takes its compiler from --cc, not $CC; forward it so a
# release wrapper (tools/cc-openssl3.sh) applies to every stage.
if [[ -n "${CC:-}" ]]; then
    FLAGS+=(--cc "$CC")
fi

# ── stage 1 ──────────────────────────────────────────────────────────────────

echo "" >&2
echo "═══ stage 1: building compiler with stage0 ═══" >&2
mkdir -p "$BUILD_DIR/stage1"

$MTC_STAGE0 build projects/mtc \
    "${FLAGS[@]}" \
    -o "$BUILD_DIR/stage1/mtc"

if [[ ! -x "$BUILD_DIR/stage1/mtc" ]]; then
    echo "error: stage1 build failed — no binary at $BUILD_DIR/stage1/mtc" >&2
    exit 1
fi

echo "stage1: built $BUILD_DIR/stage1/mtc" >&2

if [[ "$TARGET_STAGE" -eq 1 ]]; then
    echo "" >&2
    echo "═══ done (stage 1) ═══" >&2
    exit 0
fi

# ── stage 2 ──────────────────────────────────────────────────────────────────

echo "" >&2
echo "═══ stage 2: building compiler with stage1 ═══" >&2
mkdir -p "$BUILD_DIR/stage2"

STAGE2_FLAGS=("${FLAGS[@]}")
if [[ "$KEEP_C" -eq 1 ]]; then
    STAGE2_FLAGS+=(--keep-c "$BUILD_DIR/stage2.c")
fi

$BUILD_DIR/stage1/mtc build projects/mtc \
    "${STAGE2_FLAGS[@]}" \
    -o "$BUILD_DIR/stage2/mtc"

if [[ ! -x "$BUILD_DIR/stage2/mtc" ]]; then
    echo "error: stage2 build failed — no binary at $BUILD_DIR/stage2/mtc" >&2
    exit 1
fi

echo "stage2: built $BUILD_DIR/stage2/mtc" >&2

if [[ "$TARGET_STAGE" -eq 2 ]]; then
    echo "" >&2
    echo "═══ done (stage 2) ═══" >&2
    exit 0
fi

# ── stage 3 ──────────────────────────────────────────────────────────────────

echo "" >&2
echo "═══ stage 3: building compiler with stage2 (verification) ═══" >&2
mkdir -p "$BUILD_DIR/stage3"

STAGE3_C_FLAG=()
if [[ "$KEEP_C" -eq 1 ]]; then
    STAGE3_C_FLAG=(--keep-c "$BUILD_DIR/stage3.c")
fi

$BUILD_DIR/stage2/mtc build projects/mtc \
    "${FLAGS[@]}" \
    -o "$BUILD_DIR/stage3/mtc" \
    "${STAGE3_C_FLAG[@]}"

if [[ ! -x "$BUILD_DIR/stage3/mtc" ]]; then
    echo "error: stage3 build failed — no binary at $BUILD_DIR/stage3/mtc" >&2
    exit 1
fi

echo "stage3: built $BUILD_DIR/stage3/mtc" >&2

# ── fixed-point verification ─────────────────────────────────────────────────

if [[ "$SKIP_VERIFY" -eq 1 ]]; then
    echo "" >&2
    echo "═══ done (stage 3, verification skipped) ═══" >&2
    exit 0
fi

echo "" >&2
echo "═══ verifying fixed point (stage2.c vs stage3.c) ═══" >&2

if [[ "$KEEP_C" -eq 0 ]]; then
    echo "note: --keep-c was not set; rebuilding stage2 and stage3 with C output" >&2
    $BUILD_DIR/stage1/mtc build projects/mtc \
        "${FLAGS[@]}" \
        -o /dev/null \
        --keep-c "$BUILD_DIR/stage2.c"
    $BUILD_DIR/stage2/mtc build projects/mtc \
        "${FLAGS[@]}" \
        -o /dev/null \
        --keep-c "$BUILD_DIR/stage3.c"
fi

if diff -q "$BUILD_DIR/stage2.c" "$BUILD_DIR/stage3.c" &>/dev/null; then
    echo "stage2.c == stage3.c  (fixed point holds)" >&2
else
    echo "ERROR: fixed point broken — stage2.c != stage3.c" >&2
    diff "$BUILD_DIR/stage2.c" "$BUILD_DIR/stage3.c" || true
    exit 1
fi

# ── self-test ────────────────────────────────────────────────────────────────

# The stage-3 build above already *is* stage2 compiling itself; this rebuild is
# only kept for the full (non-fast) run, where its binary is the one the suite
# exercises.  Fast mode relies on gates_dev_tests / test_mt for the suite.

if [[ "$FAST" -eq 0 ]]; then
    echo "" >&2
    echo "═══ self-test: stage2 compiles itself ═══" >&2

    mkdir -p "$BUILD_DIR/stage2-self"
    $BUILD_DIR/stage2/mtc build projects/mtc \
        "${FLAGS[@]}" \
        -o "$BUILD_DIR/stage2-self/mtc"

    if [[ ! -x "$BUILD_DIR/stage2-self/mtc" ]]; then
        echo "error: self-test failed — stage2 cannot build itself" >&2
        exit 1
    fi

    echo "self-test: stage2 built itself successfully" >&2
fi

# ── run tests ────────────────────────────────────────────────────────────────

if [[ "$FAST" -eq 0 ]]; then
    echo "" >&2
    echo "═══ running self-host test suite ═══" >&2

    $BUILD_DIR/stage2/mtc test projects/mtc -I . --timeout 60
fi

echo "" >&2
echo "═══ done ═══" >&2
echo "bootstrap artifacts:" >&2
echo "  stage1: $BUILD_DIR/stage1/mtc" >&2
echo "  stage2: $BUILD_DIR/stage2/mtc  ← distributable compiler" >&2
echo "  stage3: $BUILD_DIR/stage3/mtc" >&2
if [[ "$KEEP_C" -eq 1 ]]; then
    echo "  C output: $BUILD_DIR/stage2.c  $BUILD_DIR/stage3.c" >&2
fi

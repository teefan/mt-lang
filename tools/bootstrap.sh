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
#   --profile PROFILE    Build profile: debug or release (default: debug)
#   --keep-c             Save generated C files alongside binaries
#   -j N                 Parallel jobs for C compilation (default: nproc)
#
# Stage0 resolution order:
#   1. --bootstrap PATH (explicit)
#   2. $MTC_BOOTSTRAP environment variable
#   3. bin/bootstrap-mtc in the repo root (if present)
#   4. ruby -Ilib bin/mtc (Ruby host fallback)
#   5. Error
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
PROFILE="debug"
KEEP_C=0
JOBS="$(nproc 2>/dev/null || echo 1)"
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
        --profile)
            PROFILE="$2"
            shift 2
            ;;
        --keep-c)
            KEEP_C=1
            shift
            ;;
        -j)
            JOBS="$2"
            shift 2
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

    # 3. bin/bootstrap-mtc in the repo root
    local repo_bootstrap="$PROJECT_ROOT/bin/bootstrap-mtc"
    if [[ -x "$repo_bootstrap" ]]; then
        echo "stage0: $repo_bootstrap (repo snapshot)" >&2
        echo "$repo_bootstrap"
        return
    fi

    # 4. Ruby host fallback
    if command -v ruby &>/dev/null; then
        local ruby_cmd="ruby -Ilib bin/mtc"
        if $ruby_cmd version &>/dev/null; then
            echo "stage0: ruby -Ilib bin/mtc (Ruby host)" >&2
            echo "$ruby_cmd"
            return
        fi
    fi

    # 5. Error
    echo "error: no bootstrap compiler found." >&2
    echo "  Install Ruby for stage0, or set \$MTC_BOOTSTRAP to an mtc binary." >&2
    echo "  See docs/bootstrap-design.md for details." >&2
    exit 1
}

MTC_STAGE0="$(resolve_stage0)"

# ── build flags ──────────────────────────────────────────────────────────────

FLAGS=(-I . --no-cache --no-debug-guards)
if [[ "$PROFILE" == "release" ]]; then
    FLAGS+=(--profile release)
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

# ── run tests ────────────────────────────────────────────────────────────────

echo "" >&2
echo "═══ running self-host test suite ═══" >&2

$BUILD_DIR/stage2/mtc test projects/mtc -I . --timeout 60

echo "" >&2
echo "═══ done ═══" >&2
echo "bootstrap artifacts:" >&2
echo "  stage1: $BUILD_DIR/stage1/mtc" >&2
echo "  stage2: $BUILD_DIR/stage2/mtc  ← distributable compiler" >&2
echo "  stage3: $BUILD_DIR/stage3/mtc" >&2
if [[ "$KEEP_C" -eq 1 ]]; then
    echo "  C output: $BUILD_DIR/stage2.c  $BUILD_DIR/stage3.c" >&2
fi

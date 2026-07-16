# Milk Tea Bootstrap & Release Design

Status: **Proposal** — not yet implemented. Last updated: 2026-07-14.

## 0. Motivation

Milk Tea is self-hosting: the compiler (`mtc`) compiles itself. Today the
bootstrap host is the Ruby compiler (`ruby -Ilib bin/mtc`). As the language
matures, we need:

1. A **Ruby-free bootstrap path** for contributors who don't have Ruby.
2. A **release pipeline** that ships pre-built `mtc` binaries.
3. **Reproducible fixed-point verification** so every build proves the compiler
   is self-consistent.
4. **Fast development shortcuts** that avoid rebuilding the full compiler-chain
   on every change.

This document draws from Rust, Go, and Zig bootstrap architectures and adapts
them to Milk Tea's constraints (Ruby host, C backend, source-only stdlib).

---

## 1. Stage Model — Current & Target

### 1.1 Current state (ad-hoc)

```
Ruby (stage0) ──build──→ stage1  (tmp/mtc-current)
stage1        ──build──→ stage2  (tmp/mtc-stage2)
stage2        ──build──→ stage3  (tmp/mtc-stage3)  ← must == stage2
```

This is run manually with no artifact persistence, no automation, and always
requires Ruby.

### 1.2 Target model (mirrors Rust/Go)

```
+----------+      +---------+      +---------+      +---------+
| stage0   | ───→ | stage1  | ───→ | stage2  | ───→ | stage3  |
| (pre-built|      | (boot   |      | (self   |      | (verify)|
|  mtc      |      |  by s0) |      |  by s1)  |      |  by s2) |
+----------+      +---------+      +---------+      +---------+
    |                 |                 |                 |
    v                 v                 v                 v
 Snapshotted      Fast dev         Distributable    Fixed-point
 binary           artifact         artifact         check only
```

| Stage | Built by | Uses std from | Purpose |
|-------|----------|---------------|---------|
| stage0 | Pre-built snapshot | Repo `std/` tree | Bootstrap host |
| stage1 | stage0 | Repo `std/` tree | Fast dev iteration (`--stage 1`) |
| stage2 | stage1 | Repo `std/` tree | Distributable artifact (`--stage 2`) |
| stage3 | stage2 | Repo `std/` tree | Fixed-point verification only |

All stages load the same `std/` source tree from the repository root — there is
no stage-specific standard library.  See §5 for rationale.

### 1.3 Why 3 stages?

Borrowed from Go's rationale:

1. **stage1** carries traces of stage0's code generation — not reproducible.
2. **stage2** is "new compiler built by new compiler" — clean, reproducible,
   suitable for distribution.
3. **stage3** proves stage2 is stable — `diff stage2.c stage3.c` must be empty.
   If the compiler has a self-consistency bug, it surfaces here.

Rust ships stage2. Go ships toolchain3. Zig ships stage3. Milk Tea should ship
stage2 (matching Rust) with stage3 as verification-only.

---

## 2. Binary Snapshots

### 2.1 Snapshot concept

A **snapshot** is a pre-built `mtc` binary from the last stable release. It
replaces Ruby as the stage0 compiler for contributors who don't have (or don't
want to install) Ruby. The snapshot is NOT committed to the repository — it is
either provided locally by the user or downloaded on demand (see §2.2).

### 2.2 Snapshot storage strategy

**Recommendation: user-provided or download-on-demand, locally cached.**

- The user sets `$MTC_BOOTSTRAP` to point at a pre-built `mtc` binary.
- Alternatively, the bootstrap script can download a snapshot from a configured
  URL into a local cache directory.
- The cache lives at `$XDG_CACHE_HOME/milk_tea/bootstrap/` (or `~/.cache/milk_tea/bootstrap/`).

We reject committing binaries to the repository (bloats history, opaque diffs)
and git-lfs (extra tooling requirement for every contributor).

### 2.3 Stage0 resolution order

The bootstrap script resolves the stage0 compiler in this order:

1. `--bootstrap PATH` (explicit, highest priority)
2. `$MTC_BOOTSTRAP` environment variable
3. `bin/bootstrap-mtc` in the repo root (if present — user places it there)
4. Download snapshot from `$MTC_BOOTSTRAP_URL` into local cache
5. `ruby -Ilib bin/mtc` (Ruby host — existing fallback)
6. Error: "No bootstrap compiler found. Install Ruby or set MTC_BOOTSTRAP."

### 2.4 Snapshot format

Minimum: a single native `mtc` binary for linux/x86-64 (the primary dev host).

Full: binaries for linux/x86-64 and windows/x86-64, plus the `std/` directory
tree (source files — no pre-compiled artifacts needed since stdlib is
source-only).

---

## 3. Bootstrap Script (`tools/bootstrap.sh`)

### 3.1 Design

A single-entry shell script that handles the entire bootstrap chain. Modeled on
Go's `src/make.bash` and Rust's `x.py`.

```sh
tools/bootstrap.sh [OPTIONS]

Options:
  --bootstrap PATH     Path to stage0 mtc binary (default: auto-detect)
  --stage {1,2}        Build target stage (default: 2)
  --no-verify          Skip stage3 fixed-point check
  --keep-c DIR         Save generated C files to DIR
  --profile {debug,release}  Build profile (default: release)
  -j N                 Parallel jobs for C compilation (default: nproc)
```

### 3.2 Build flow

```sh
set -euo pipefail

BUILD_DIR="${MTC_BUILD_DIR:-build}"
PROFILE="${MTC_PROFILE:-release}"
BOOTSTRAP="${MTC_BOOTSTRAP:-}"

# Resolve stage0 (see §2.3)
MTC_STAGE0="$(resolve_bootstrap "$BOOTSTRAP")"

# Stage 1: build by stage0
$MTC_STAGE0 build -I . --profile "$PROFILE" \
    --cc "$CC" \
    --no-cache \
    -o "$BUILD_DIR/stage1/mtc" \
    projects/mtc

# Stage 2: build by stage1 (distributable artifact)
$BUILD_DIR/stage1/mtc build -I . --profile "$PROFILE" \
    --cc "$CC" \
    --no-cache \
    -o "$BUILD_DIR/stage2/mtc" \
    --keep-c "$BUILD_DIR/stage2.c" \
    projects/mtc

if [ "${SKIP_VERIFY:-0}" = "1" ]; then
    exit 0
fi

# Stage 3: build by stage2 (verify fixed point)
$BUILD_DIR/stage2/mtc build -I . --profile "$PROFILE" \
    --cc "$CC" \
    --no-cache \
    -o "$BUILD_DIR/stage3/mtc" \
    --keep-c "$BUILD_DIR/stage3.c" \
    projects/mtc

# Fixed-point check
if ! diff "$BUILD_DIR/stage2.c" "$BUILD_DIR/stage3.c"; then
    echo "ERROR: Fixed point broken — stage2.c != stage3.c" >&2
    exit 1
fi
```

Notes on the flags:
- `-I .` is required so that `std/` at the repo root is visible as a module
  root during compilation.
- `--no-cache` forces a clean build from source — without it the build cache
  may serve stale output from a previous compiler version.

### 3.3 Development shortcuts

```sh
# Dev build: just stage1, no verification
tools/bootstrap.sh --stage 1 --no-verify

# Verify-only: assumes stage2 already built
tools/bootstrap.sh --verify-only
```

---

## 4. Standard Library Considerations

### 4.1 Current state

Milk Tea's standard library is source-only — `.mt` files under `std/`. There
are no pre-compiled artifacts. The compiler loads std sources at build time
from the module roots configured via `-I`.

### 4.2 Implications for bootstrapping

This simplifies bootstrapping significantly compared to Rust (which must manage
pre-compiled `std` artifacts across stage0/stage1):

- **No ABI coupling**: The compiler embeds prelude types at compile time, but
  std source files do not form a binary interface between stages.
- **No artifact management**: no `.rlib`/`.so`/`.a` files to ship or stage.
- **No stage-specific std**: all stages load the same `std/` source tree from
  the repository root. There is no `cfg(bootstrap)` equivalent because there
  is no separate std artifact to build with two compiler versions.

Caveat: if a new compiler release adds language features that stdlib source
files use, those std files cannot be built by an older compiler.  In practice
this is handled naturally — a snapshot binary from the prior release can still
bootstrap the current source because both read the same in-tree std sources.

### 4.3 Potential future concern

If stdlib ever grows pre-compiled C components (e.g., a bundled libuv, pcre2,
or similar native library), those would need to be shipped as part of the
release package. Today this is not needed.

---

## 5. Build Cache & Incremental Compilation

### 5.1 Current state

Milk Tea has a build cache. Consecutive `mtc build` invocations reuse compiled C
and binaries when source files haven't changed.  The cache is local to the build
directory and is not shared across stages.

### 5.2 Cache during bootstrapping

The bootstrap script uses `--no-cache` to ensure every stage builds from a
clean slate.  This avoids cache poisoning where stage0-built artifacts are
reused by stage1, which would defeat the purpose of stage isolation.

### 5.3 Cache location

```
$XDG_CACHE_HOME/milk_tea/
  bootstrap/           ← downloaded snapshot binaries
  build-cache/         ← existing .mt → C → binary cache (normal builds)
```

---

## 6. Implementation Plan

### Phase 1: Bootstrap script

- Write `tools/bootstrap.sh`
- Support `$MTC_BOOTSTRAP`, `--bootstrap`, Ruby fallback, snapshot download
- 3-stage build + fixed-point verification via `diff`
- `--stage 1` fast path for development
- `--no-verify` to skip stage3
- Cache snapshot downloads at `$XDG_CACHE_HOME/milk_tea/bootstrap/`

### Phase 2: Release tooling

- Script to build release binaries for linux/x86-64 (and windows/x86-64 via
  MinGW cross-compilation when supported)
- Package: `mtc` + `std/` + docs → `.tar.gz` / `.zip`
- Snapshot update: copy the release `mtc` binary to the snapshot cache and
  update `$MTC_BOOTSTRAP_URL`

### Phase 3: Developer tooling (future)

- `make bootstrap` / `make dev` targets
- Pre-commit hook: verify fixed point before allowing commits to `projects/mtc/`
- `mtc bootstrap` self-hosted subcommand (the bootstrap script itself written
  in Milk Tea)

---

## 7. Configuration Reference

| Variable | Purpose | Default |
|----------|---------|---------|
| `$MTC_BOOTSTRAP` | Path to stage0 mtc binary | auto-detect |
| `$MTC_BOOTSTRAP_URL` | URL to download snapshot from | none (user-configured) |
| `$CC` | C compiler for native builds | `cc` |
| `$MTC_BUILD_DIR` | Build output directory | `build/` |
| `$XDG_CACHE_HOME` | Cache root (bootstrap downloads) | `~/.cache` |

---

## 8. References

- [Rust bootstrap redesign (2025)](https://blog.rust-lang.org/inside-rust/2025/05/29/redesigning-the-initial-bootstrap-sequence/)
- [Rust Compiler Development Guide — Bootstrapping](https://rustc-dev-guide.rust-lang.org/building/bootstrapping/)
- [Go bootstrap design (`cmd/dist`)](https://golang.design/under-the-hood/en/part1overview/ch03life/bootstrap/)
- [Go install from source](https://go.dev/doc/install/source)
- [Zig multi-stage bootstrap](https://deepwiki.com/ziglang/zig/5.1-multi-stage-bootstrap)
- Milk Tea self-host plan: `docs/self-host-plan.md`

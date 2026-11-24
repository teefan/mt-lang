# Milk Tea Bootstrap & Release Design

Status: **complete, host retired**: `tools/bootstrap.sh` (3-stage build,
fixed-point verification, self-tests) with the committed native seed, and
`tools/release.sh` (deterministic archive, checksums, clean-path smoke, seed
refresh).  The Ruby host was retired in session 143; the seed is the only
stage0.  Bootstrap and release are CI-gated.  Last updated: 2026-11-24.

## 0. Motivation

Milk Tea is self-hosting: the compiler (`mtc`) compiles itself. The Ruby host
that originally bootstrapped the language is retired and archived (tag
`archive/host-ruby-0.4.26`). The requirements that drove this design were:

1. A **Ruby-free bootstrap path** for contributors who don't have Ruby.
2. A **release pipeline** that ships pre-built `mtc` binaries.
3. **Reproducible fixed-point verification** so every build proves the compiler
   is self-consistent.
4. **Fast development shortcuts** that avoid rebuilding the full compiler-chain
   on every change.

This document draws from Rust, Go, and Zig bootstrap architectures and adapts
them to Milk Tea's constraints (native seed, C backend, source-only stdlib).

---

## 1. Stage Model — Current & Target

### 1.1 Current state

Implemented by `tools/bootstrap.sh` (§3), which persists every stage:

```
stage0 (vendor/bootstrap/<platform>/mtc or $MTC_BOOTSTRAP)
        ──build──→ build/stage1/mtc   (fast dev path: --stage 1)
stage1  ──build──→ build/stage2/mtc   (distributable artifact, --stage 2)
stage2  ──build──→ build/stage3/mtc   (verification only)
                   verify: build/stage2.c == build/stage3.c
                   then:   build/stage2/mtc test projects/mtc
```

Stage 1/2/3 binaries, their generated C (`--keep-c`) and the fixed-point diff
all live under `$MTC_BUILD_DIR` (default `build/`), so a bootstrap run leaves
the artifacts behind for inspection.  The committed seed is the only stage0.

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

A **snapshot** (seed) is a pre-built `mtc` binary from the last stable release.
It replaces Ruby as the stage0 compiler.  A seed only has to compile the source
tree at its own commit; a language change in the compiler or `std/` is what
forces a refresh.

### 2.2 Snapshot storage strategy

**Decision: one committed seed per supported host.**

- `vendor/bootstrap/<platform>/mtc` plus `mtc.sha256`; `tools/bootstrap.sh`
  verifies the checksum before use and fails on a mismatch.
- Only `linux-x86_64` is present.  A missing platform is a hard error that
  names the expected path.
- The checked-in binary is a release-profile **stage2** compiler, so its code
  generation comes from Milk Tea, not from the Ruby host.  Provenance and the
  regeneration command are in `vendor/bootstrap/README.md`.

This supersedes the earlier "never commit binaries" recommendation:

- CI runs on GitHub and releases are published there, but a committed seed
  keeps a fresh clone buildable offline and without a release lookup — the
  exact dependency the seed exists to remove.
- One ~6 MB release binary per platform is bounded; it is replaced when a
  release is cut, not accumulated.
- `.gitattributes` marks `vendor/bootstrap/**` as binary so line-ending
  normalization cannot corrupt it.

### 2.3 Stage0 resolution order

The bootstrap script resolves the stage0 compiler in this order:

1. `--bootstrap PATH` (explicit, highest priority; not checksum-verified)
2. `$MTC_BOOTSTRAP` environment variable (not checksum-verified)
3. `vendor/bootstrap/<platform>/mtc` (committed seed; sha256 verified)
4. Error: names the expected seed path and the two ways to supply one

The `bin/bootstrap-mtc` path was removed; `vendor/bootstrap/` replaces it and
carries a checksum, which a user-placed file could not.

### 2.4 Snapshot format

The release archive is the distribution unit:

```
mtc-<version>-<platform>/
  bin/mtc   std/   docs/   docs_public/   VERSION   README.md   LICENSE
```

`tools/release.sh` builds it deterministically, writes
`mtc-<version>-<platform>.tar.gz` plus a `.sha256`, and `--refresh-seed` copies
the release binary into `vendor/bootstrap/<platform>/mtc` with a fresh
checksum.  The repository ships one seed per supported platform
(`linux-x86_64` today); adding a platform means committing its seed and
checksum.

---

## 3. Bootstrap Script (`tools/bootstrap.sh`)

### 3.1 Design

A single-entry shell script that handles the entire bootstrap chain. Modeled on
Go's `src/make.bash` and Rust's `x.py`.

```sh
tools/bootstrap.sh [OPTIONS]

Options:
  --bootstrap PATH     Path to stage0 mtc binary (default: auto-detect)
  --stage {1,2,3}      Build target stage (default: 3)
  --no-verify          Skip stage3 fixed-point check
  --fast               Fixed point only (implies --keep-c; skips the suite)
  --profile PROFILE    Build profile: debug or release (default: debug)
  --keep-c             Save generated C files alongside binaries
  --print-stage0       Resolve and verify stage0, print its path, and exit
  -j N                 Parallel compiler jobs (default: 4, hard-capped)
```

### 3.2 Build flow

```sh
set -euo pipefail

BUILD_DIR="${MTC_BUILD_DIR:-build}"
PROFILE="debug"
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

# Fixed point only (implies --keep-c; skips the self-test suite)
tools/bootstrap.sh --fast -j 4
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

### 4.3 Vendored C components

The stdlib's C-backed modules (raylib, libuv, pcre2, Box2D, …) are not shipped
as pre-compiled artifacts.  `mtc toolchain bootstrap` fetches the pinned
`third_party/` sources, and the compiler builds the static libraries on demand;
the release archive therefore stays source-only.

---

## 5. Build Cache & Incremental Compilation

### 5.1 Current state

Milk Tea has a build cache. Consecutive `mtc build` invocations reuse compiled C
and binaries when source files haven't changed.  The cache lives under
`$XDG_CACHE_HOME/milk_tea/mtc-cache` (falling back to `~/.cache`) and is not
shared across stages.

### 5.2 Cache during bootstrapping

The bootstrap script uses `--no-cache` to ensure every stage builds from a
clean slate.  This avoids cache poisoning where stage0-built artifacts are
reused by stage1, which would defeat the purpose of stage isolation.

### 5.3 Cache location

```
$XDG_CACHE_HOME/milk_tea/mtc-cache/   ← .mt → C → binary cache (normal builds)
```

---

## 6. Implementation Plan

### Phase 1: Bootstrap script — DONE (`tools/bootstrap.sh`)

- [x] `tools/bootstrap.sh`
- [x] Support `$MTC_BOOTSTRAP` and `--bootstrap` (committed seed; no download
      path)
- [x] Committed sha256-verified seed (`vendor/bootstrap/<platform>/`) as the
      only stage0; a fresh clone bootstraps with only a C compiler
- [x] 3-stage build + fixed-point verification via `diff`
- [x] `--stage 1` fast path for development (`--stage 2` stops after stage2)
- [x] `--no-verify` to skip stage3
- [x] `--profile debug|release`, `--keep-c`, `-j N`, `$MTC_BUILD_DIR`
- [x] version is the authored `cli_help.VERSION` constant (the old git-revision
      stamp produced an ignored generated file and was removed)
- [x] `build/stage2/mtc test projects/mtc` self-test step

### Phase 2: Release tooling — DONE (`tools/release.sh`)

- [x] `tools/release.sh` builds a release-profile stage2 with the seed and
      packages `bin/mtc` + `std/` + `docs/` + `docs_public/` + `VERSION` +
      `README.md` + `LICENSE`
- [x] deterministic `.tar.gz` (sorted entries, fixed owner/mtime, `gzip -n`)
      plus a `.sha256`
- [x] `--refresh-seed` updates `vendor/bootstrap/<platform>/` and its checksum
- [x] `tools/release_smoke.sh`: extracts the archive outside the checkout,
      builds/runs a std-importing program, completes an LSP initialize
      handshake, and checks the docs page/assets/404 routes
- [x] CI (`.github/workflows/ci.yml`) runs the bootstrap, gates, release and
      clean-container smoke; only `linux-x86_64` is packaged

---

## 7. Configuration Reference

| Variable | Purpose | Default |
|----------|---------|---------|
| `$MTC_BOOTSTRAP` | Path to stage0 mtc binary | auto-detect |
| `$CC` | C compiler for native builds | `cc` |
| `$MTC_BUILD_DIR` | Build output directory | `build/` |
| `$XDG_CACHE_HOME` | Build-cache root (`milk_tea/mtc-cache`) | `~/.cache` |

---

## 8. References

- [Rust bootstrap redesign (2025)](https://blog.rust-lang.org/inside-rust/2025/05/29/redesigning-the-initial-bootstrap-sequence/)
- [Rust Compiler Development Guide — Bootstrapping](https://rustc-dev-guide.rust-lang.org/building/bootstrapping/)
- [Go bootstrap design (`cmd/dist`)](https://golang.design/under-the-hood/en/part1overview/ch03life/bootstrap/)
- [Go install from source](https://go.dev/doc/install/source)
- [Zig multi-stage bootstrap](https://deepwiki.com/ziglang/zig/5.1-multi-stage-bootstrap)
- Milk Tea self-host plan: `docs/self-host-plan.md`

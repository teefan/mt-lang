# Milk Tea Bootstrap & Release Design

Status: **Proposal** — not yet implemented. Last updated: 2026-07-14.

## 0. Motivation

Milk Tea is self-hosting: the compiler (`mtc`) compiles itself. Today the
bootstrap host is the Ruby compiler (`ruby -Ilib bin/mtc`). As the language
matures, we need:

1. A **Ruby-free bootstrap path** for contributors who don't have Ruby.
2. A **release pipeline** that ships pre-built `mtc` binaries.
3. **Reproducible fixed-point verification** integrated into CI.
4. **Fast development shortcuts** that avoid rebuilding the compiler-chain from
   scratch on every change.

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

This works but has no artifact persistence, no CI automation, and always
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
 Downloaded       Fast dev         Distributable    Fixed-point
 snapshot         artifact         artifact         check only
```

| Stage | Built by | Links std | Purpose |
|-------|----------|-----------|---------|
| stage0 | Pre-built snapshot | Snapshot std sources | Bootstrap host |
| stage1 | stage0 | stage0 std sources | Fast dev iteration (`--stage 1`) |
| stage2 | stage1 | stage1 std sources | Distributable artifact (`--stage 2`) |
| stage3 | stage2 | stage2 std sources | Fixed-point verification only |

### 1.3 Why 3 stages?

Borrowed directly from Go's rationale:

1. **stage1** carries traces of stage0's code generation — not reproducible.
2. **stage2** is "new compiler built by new compiler" — clean, reproducible,
   suitable for distribution and caching.
3. **stage3** proves stage2 is stable — `diff stage2.c stage3.c` must be empty.
   If the compiler has a self-consistency bug, it surfaces here.

Rust ships stage2. Go ships toolchain3. Zig ships stage3. Milk Tea should ship
stage2 (matching Rust) with stage3 as CI-only verification.

---

## 2. Binary Snapshots

### 2.1 Snapshot concept

A **snapshot** is a pre-built `mtc` binary from the last stable release, stored
alongside the repository. It replaces Ruby as the stage0 compiler for
contributors who don't have (or don't want to install) Ruby.

```text
bin/
  bootstrap-mtc          ← Linux x86-64 snapshot
  bootstrap-mtc.exe      ← Windows x86-64 snapshot (MinGW-linked)
```

### 2.2 Snapshot lifecycle

```
Release v0.N.0
    │
    ├── Build release binaries (Linux, Windows)
    ├── Verify fixed point
    ├── Upload to GitHub Releases
    └── Commit snapshot binary to repo as bin/bootstrap-mtc

Next dev cycle
    │
    ├── `bin/bootstrap-mtc` is the stage0 compiler
    └── Contributors with Ruby can also use `ruby -Ilib bin/mtc`

Release v0.N+1.0
    │
    └── Snapshots are bumped to the new release
```

### 2.3 Snapshot storage strategy

**Option A: Commit binary to repo** (Rust-style, used by `rust-lang/rust`
before CI downloads)

- Pro: zero setup, `git clone` gives you a working bootstrap
- Con: bloats repo, binary diffs are opaque

**Option B: Download on demand** (current Rust: CI provides downloads)

- Pro: clean repo, binaries are cached in `$XDG_CACHE_HOME/milk_tea/`
- Con: requires network on first build, needs hosting infra

**Option C: CI-built, git-lfs stored** (hybrid)

- Pro: binary available locally, tracked in git-lfs, not bloating normal clones
- Con: requires git-lfs setup

**Recommendation: Option B** — download on demand from GitHub Releases, cached
in `$XDG_CACHE_HOME/milk_tea/bootstrap/`. This is the Rust model and requires
no repo bloat or extra tooling beyond what we already have (`mtc deps fetch`
already downloads from remotes).

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

### 3.2 Stage0 resolution order

The script resolves the stage0 compiler in this order:

1. `--bootstrap PATH` (explicit)
2. `$MTC_BOOTSTRAP` environment variable
3. `bin/bootstrap-mtc` in the repo root (committed snapshot)
4. Download latest release from `$MTC_BOOTSTRAP_URL` into cache
5. `ruby -Ilib bin/mtc` (Ruby host — existing fallback)
6. Error: "No bootstrap compiler found. Install Ruby or set MTC_BOOTSTRAP."

### 3.3 Build flow

```sh
# Stage 1: build by stage0
$MTC_STAGE0 build -I . --profile $PROFILE \
    --cc "$CC" \
    -o "$BUILD_DIR/stage1/mtc" \
    projects/mtc

# Stage 2: build by stage1 (distributable)
$BUILD_DIR/stage1/mtc build -I . --profile $PROFILE \
    --cc "$CC" \
    -o "$BUILD_DIR/stage2/mtc" \
    --keep-c "$BUILD_DIR/stage2.c" \
    projects/mtc

# Stage 3: build by stage2 (verify fixed point)
$BUILD_DIR/stage2/mtc build -I . --profile $PROFILE \
    --cc "$CC" \
    -o "$BUILD_DIR/stage3/mtc" \
    --keep-c "$BUILD_DIR/stage3.c" \
    projects/mtc

# Verify
diff "$BUILD_DIR/stage2.c" "$BUILD_DIR/stage3.c" || {
    echo "ERROR: Fixed point broken — stage2.c != stage3.c"
    exit 1
}
```

### 3.4 Development shortcuts

For quick iteration, skip the full chain:

```sh
# Dev build: just stage1, no verification
tools/bootstrap.sh --stage 1 --no-verify

# Verify-only: assumes stage2 already built
tools/bootstrap.sh --verify-only
```

---

## 4. CI/CD Pipeline

### 4.1 Per-commit CI (GitHub Actions or equivalent)

```yaml
jobs:
  bootstrap-test:
    # Full bootstrap from Ruby, verify fixed point, run tests
    steps:
      - uses: actions/checkout
      - uses: ruby/setup-ruby
      - run: tools/bootstrap.sh --bootstrap "ruby -Ilib bin/mtc"
      - run: ./build/stage2/mtc test projects/mtc -I .
      - run: diff build/stage2.c build/stage3.c  # verify fixed point

  snapshot-test:
    # Bootstrap from last known good snapshot
    # Skip if snapshot doesn't exist yet
    steps:
      - run: tools/bootstrap.sh
      - run: ./build/stage2/mtc test projects/mtc -I .
```

### 4.2 Release pipeline (on tag)

```
git tag v0.N.0
    │
    ├── Full bootstrap from Ruby (extra safety)
    ├── Build linux/x86-64 release binary
    ├── Build windows/x86-64 release binary (via MinGW cross)
    ├── Package: mtc + std/ + docs/ → tar.gz / zip
    ├── Upload to GitHub Releases
    ├── Update snapshot: stage2 binary → cache for next dev cycle
    └── Publish to package registry
```

### 4.3 Snapshot update automation

After each release, a CI job:

1. Builds the release `mtc` binary for linux/x86-64
2. Uploads it to a known URL (GitHub Releases API)
3. Updates `MTC_BOOTSTRAP_URL` in `tools/bootstrap.sh` to point to the new release

This ensures the bootstrap chain always has one release of runway — if a new
release introduces a compiler bug, the previous release's snapshot can still
bootstrap.

---

## 5. Standard Library Considerations

### 5.1 Current state

Milk Tea's standard library is source-only — `.mt` files under `std/`. There
are no pre-compiled artifacts. The compiler loads std sources at build time.

### 5.2 Implications for bootstrapping

This simplifies bootstrapping significantly compared to Rust (which must manage
pre-compiled `std` artifacts across stages):

- **No ABI coupling**: std source is always compatible with any compiler version
  (no `cfg(bootstrap)` equivalent needed)
- **No artifact management**: no `.rlib`/`.so`/`.a` files to ship
- **No stage-specific std**: stage1 and stage2 both load the same std sources

### 5.3 Potential future concern

If stdlib ever grows pre-compiled C components (e.g., a bundled libuv, pcre2,
or similar native library), those would need to be shipped as part of the
release package. Today this is not needed.

---

## 6. Build Cache & Incremental Compilation

### 6.1 Current state

Milk Tea has a build cache (hash-keyed `.mt` → compiled C → binary). The cache
persists across invocations but is not shared across stages.

### 6.2 Stage sharing (like Rust's `--keep-stage`)

Rust's `--keep-stage std` skips rebuilding std when the compiler ABI hasn't
changed. Milk Tea doesn't need this today (std is source-only, not compiled),
but the same principle applies to the compiler's own source:

- `--keep-stage 1` could skip rebuilding projects/mtc from stage1 if no source
  files changed — reuse the stage1 binary.
- The build cache already handles file-level caching.

### 6.3 Cache location

```
$XDG_CACHE_HOME/milk_tea/
  bootstrap/           ← downloaded snapshot binaries
  build-cache/         ← existing .mt → C → binary cache
```

---

## 7. Implementation Plan

### Phase 1: Bootstrap script (1-2 days)

- Write `tools/bootstrap.sh`
- Support `$MTC_BOOTSTRAP`, `--bootstrap`, Ruby fallback
- 3-stage build + fixed-point verification
- `--stage 1` fast path for development

### Phase 2: Snapshot storage (1 day)

- Add download-from-GitHub-Releases logic to bootstrap script
- Set up `$XDG_CACHE_HOME/milk_tea/bootstrap/` cache
- Test: `rm -rf tmp/` then `tools/bootstrap.sh` with no Ruby

### Phase 3: CI integration (1-2 days)

- GitHub Actions workflow: bootstrap + test + fixed-point
- Release workflow: build + package + upload
- Snapshot update automation

### Phase 4: Developer tooling (future)

- `make bootstrap` / `make dev` targets
- Pre-commit hook: verify fixed point
- `mtc bootstrap` subcommand (self-host the bootstrap)

---

## 8. Configuration Reference

| Variable | Purpose | Default |
|----------|---------|---------|
| `$MTC_BOOTSTRAP` | Path to stage0 mtc binary | auto-detect |
| `$MTC_BOOTSTRAP_URL` | URL to download snapshot from | GitHub Releases latest |
| `$CC` | C compiler for native builds | `cc` |
| `$MTC_BUILD_DIR` | Build output directory | `build/` |
| `$XDG_CACHE_HOME` | Cache root (bootstrap + build) | `~/.cache` |

---

## 9. References

- [Rust bootstrap redesign (2025)](https://blog.rust-lang.org/inside-rust/2025/05/29/redesigning-the-initial-bootstrap-sequence/)
- [Rust Compiler Development Guide — Bootstrapping](https://rustc-dev-guide.rust-lang.org/building/bootstrapping/)
- [Go bootstrap design (`cmd/dist`)](https://golang.design/under-the-hood/en/part1overview/ch03life/bootstrap/)
- [Go install from source](https://go.dev/doc/install/source)
- [Zig multi-stage bootstrap](https://deepwiki.com/ziglang/zig/5.1-multi-stage-bootstrap)
- Milk Tea self-host plan: `docs/self-host-plan.md`

# Milk Tea Testing Framework (`std.testing` + `mtc test`)

> Status: **T0 + T1 landed; remaining phases planned.**
> Implemented today: the `std.testing` core (§5) and `mtc test` with built-in `@[test]` discovery,
> runner synthesis, and a per-binary timeout + memory cap (§6, §7, §13). Still planned: tracking
> allocator, death/compile-fail tests, sanitizer mode, parallelism, machine output, and
> directory/package discovery. Companion to `docs/selfhost.md`.
>
> Surface note: the author-facing form is the **`@[test]` attribute**, not a `test "…"` block —
> Open Question 1 is resolved in favor of a built-in attribute (§5, §6, §14).

---

## 1. Purpose, Goals, Non-Goals

Milk Tea's testing story is **first-class and toolchain-built-in**, modeled on **Rust/Zig**, not
on pytest. The core (`std.testing` + `mtc test` with `@[test]` discovery) has landed (§5–§7, §13);
this document is both its specification and the plan for the remaining phases.

### Goals

- **First-class, zero-config testing.** `mtc test` discovers, builds, runs, and reports — one
  command, no external harness, no build glue.
- **In-language and dogfoodable.** Tests for Milk Tea programs (including the self-hosted `mtc`)
  are written *in Milk Tea*, not in a Ruby wrapper.
- **Systems-grade correctness checks** that VM-language frameworks cannot express: **leak
  detection**, **crash/abort isolation**, **timeouts/memory caps**, **sanitizers**, and
  **compile-fail** tests.
- **Minimal core, layered richness.** A small built-in surface; property testing, snapshots, and
  benchmarks are added later in `std`, the way Rust's ecosystem layers on libtest.

### Non-Goals

- **Not pytest parity.** No `assert`-rewriting magic, no dynamically-injected fixtures, no
  plugin/conftest hooks, no mocking framework. These depend on Python's dynamism + GC and fight a
  static, AOT, no-GC language (§11 explains the idiomatic alternatives).
- **Not a replacement for the differential oracle.** `mtc test` tests Milk Tea *programs*; the
  self-host differential harness (`selfhost.md` §9) tests *compiler correctness*. Different jobs.
- **Not a benchmarking suite (v1).** Benchmarks are a later `std` addition, not core.

---

## 2. Design stance: Rust/Zig, not pytest

How the reference ecosystems test, and what we take from each:

| | Built-in? | Discovery | Isolation | Compile-time | Systems extras |
|---|---|---|---|---|---|
| C | no (`assert()`) | manual / codegen scripts | best frameworks **fork per test** | — | valgrind/sanitizers (bolted on) |
| C++ | `static_assert`/`constexpr` | macro auto-registration | **death tests** (fork) | `constexpr`/concepts | sanitizers, gmock |
| Rust | **yes** `#[test]` | compiler/libtest | threaded; `nextest` forks | `compile_fail`, doctests | Miri, sanitizers |
| Zig | **yes** `test "…"` | compiler | in-process (safety-checked) | `comptime`, `@compileError` | **leak-detecting test allocator** |

Takeaways adopted here:

1. **Toolchain-built-in testing is table stakes** for a modern language (Rust/Zig/Go consensus);
   C/C++'s external-framework fragmentation is a known cost.
2. **Compiler-driven discovery** beats naming conventions and C's codegen-script hacks.
3. **For an unsafe/systems language, memory and crash semantics are part of testing** — the
   single biggest differentiator from minitest/pytest (Zig's leak-checking allocator; C's
   fork-per-test; gtest death tests).
4. **The core can be tiny**; comptime + a small `std` surface cover parameterization and more.

This matters *more* for Milk Tea than minitest/pytest do for Ruby/Python, because (a) it is a
systems language where leaks/crashes/UB are testable, (b) it is self-hosting and `mtc` needs
in-language unit tests, and (c) the status quo (§3) is brittle and anti-dogfooding.

---

## 3. Current state

**Landed (T0 + T1):**

- `std.testing` (§5): `Check`, `Failure`, `Stats`, the `expect_*` helpers, `ok`/`fail`/`skip`, and a
  hand-written-runner API (`record`/`summarize`) — written in Milk Tea.
- A built-in `@[test]` attribute (callable-target marker, no codegen effect) and `mtc test PATH`,
  which discovers `@[test]` functions, synthesizes a runner, and builds + runs it under a per-binary
  timeout and memory cap (§6, §7).

**Still tested from Ruby (migration pending):** the `std` library is still exercised by
`test/std/*_test.rb` Minitest wrappers that embed a `.mt` heredoc, compile + run it, and assert on
the **exit code** (entry point `function main() -> int`). This *C-without-a-framework* harness
(external driver, exit-code signaling) stays in place until the `std` suite is migrated onto
`mtc test` (§13, T6). The in-language path removes the need for it going forward.

---

## 4. Architecture Overview

```
file.mt (functions annotated @[test])
  → mtc test PATH
      → discover     parse via the compiler front-end; collect @[test] functions    (§6)
      → synthesize   generate a `main` that drives each test through std.testing     (§6)
      → build+run    compile the runner; run the binary sandboxed (timeout + mem cap)(§7)
      → report       per-test ok/FAIL/skip + a passed/failed/skipped summary         (§5,§10)
```

Components:

- **`std.testing`** (landed) — the in-language surface: expectations, the failure type, and the
  runner API (`record`/`summarize`). Written in Milk Tea (uses `Result`/`Option`/`?`, `std.fmt`,
  `std.string`, `std.stdio`). Building it dogfoods the language.
- **Built-in `@[test]` attribute** (landed) — a callable-target marker the compiler recognizes (no
  codegen effect), so `@[test] function … -> t.Check:` type-checks unqualified anywhere.
- **`mtc test` tooling** (landed) — parses the target file with the real front-end, discovers
  `@[test]` functions, synthesizes the runner, and builds + runs it sandboxed. Discovery is done by
  the tooling *using the parser*, not by userland language reflection (which is type-scoped and
  cannot enumerate a module's functions — see §6).

---

## 5. Authoring tests (landed)

A test is a no-parameter function annotated with `@[test]` that returns `t.Check`
(= `Result[bool, t.Failure]`, so `?` propagation works). Expectations are `?`-propagating
(fail-fast) — the idiomatic Milk Tea error path; there is no exception/panic control flow.

```mt
import std.testing as t

@[test]
function test_addition() -> t.Check:
    t.expect(1 + 1 == 2, "addition broke")?
    t.expect_equal_int(2 + 2, 4)?
    return t.ok()

@[test]
function test_skipped() -> t.Check:
    return t.skip("not implemented yet")
```

Surface that ships today:

- `t.ok()`, `t.fail(message: str)`, `t.skip(reason: str)`
- `t.expect(condition: bool, message: str)`
- `t.expect_true(condition)`, `t.expect_false(condition)`
- `t.expect_equal_int`, `t.expect_equal_bool`, `t.expect_equal_str` (render "expected X, got Y" via
  `std.fmt`)
- `t.expect_some[T](option)`, `t.expect_none[T](option)`
- `t.Check`, `t.Failure` (owned message + skip flag), `t.Stats`, `t.record`, `t.summarize` (the
  hand-written-runner API, still usable directly without `mtc test`)

Planned additions: a generic `t.expect_equal[T]` (needs an equality/format constraint),
`expect_not_equal`, `expect_null`/`expect_not_null`, `expect_error`, and source-location capture in
`Failure`. Teardown uses `defer` (no fixture runtime).

> Not yet implemented: a `when TEST` cfg-style exclusion. For now tests live in **dedicated files**
> (no `main`); a normal build does not pull them in. Co-locating tests with production code under
> `when TEST` is a later phase (§13, Open Question 3).

---

## 6. Discovery & build model

**Discovery uses the compiler front-end, not userland reflection.** Milk Tea's reflection is
*type-scoped* (`fields_of(T)`, `attributes_of(T)`, `callable_of(T, name)`); there is no primitive to
enumerate a module's free functions, so tests cannot be collected in-language. Instead `mtc test`
**parses the target file** and collects functions carrying the built-in `@[test]` attribute — the
same front-end the compiler uses.

**Author-facing surface: the built-in `@[test]` attribute** (Open Question 1, resolved). It is a
callable-target marker in the compiler's built-in attribute set, applied unqualified (`@[test]`).
It was chosen over a `test "…"` keyword block (more grammar/sema surface) and over a naming
convention (which §2 argues against); a `std.testing`-declared attribute was rejected because
imported attributes must be written module-qualified (`@[t.test]`).

**Runner synthesis (tooling-side).** `mtc test`:

1. parses `PATH`, requires it to `import std.testing` and to *not* define `main`, and requires each
   `@[test]` function to take no parameters;
2. synthesizes a `main` that calls `<alias>.record(stats, "<name>", <name>())` for each test and
   returns `<alias>.summarize(stats)`, reusing the file's `std.testing` import alias;
3. writes the combined source to a temp runner **beside the source** (preserving module
   resolution), builds it, runs it sandboxed (§7), and deletes the temp files.

**Build model (current slice): one test binary per test file.** A normal build never references
`@[test]` functions (no `main` → unreferenced → eliminated), so there is no release overhead.
Directory/package discovery, per-package `tests/` integration suites, and a `when TEST` exclusion
for co-located tests are planned (§13).

---

## 7. Execution model & sandboxing

Because a Milk Tea test compiles to C and runs as a **native binary**, a bug can segfault, call
`fatal()`, hang, or allocate unboundedly. `mtc test` sandboxes every test-binary run:

- **Address-space cap (landed).** The binary is spawned with `RLIMIT_AS` set (currently 1 GiB) via
  `Process.spawn(..., rlimit_as:)`, so runaway allocation hits `ENOMEM` (→ allocator `fatal`/abort,
  contained) instead of exhausting the host.
- **Wall-clock timeout (landed).** A watchdog (currently 30 s) kills the test's process group
  (`SIGKILL`) on timeout.
- **Crash/timeout classification (landed).** Timeouts and termination by signal are reported and
  produce a non-zero exit; otherwise the binary's own exit code is propagated.

Planned: a `--sanitize` mode (`-fsanitize=address,undefined`), a cgroup option
(`systemd-run … -p MemoryMax=`), configurable `--timeout`/`--mem` flags, parallel execution across
test files, and a per-test `--isolate` fork for death tests (§8.2). These reuse the same primitives
described in `selfhost.md` §9.

---

## 8. Systems-specific capabilities (the payoff vs pytest)

These are the features that justify a bespoke framework — none exist in minitest/pytest. **All of
this section is planned (T3/T4); the examples use the landed `@[test]` surface.**

### 8.1 Leak-checking via a tracking allocator

Milk Tea's allocators are explicit (`std.mem.{arena,heap,pool,stack}`). A `t.tracking_allocator()`
wraps `std.mem.heap`, counts outstanding allocations, and a test fails if any remain:

```mt
@[test]
function test_list_alloc_is_balanced() -> t.Check:
    var ta = t.tracking_allocator()
    defer t.expect_no_leaks(ref_of(ta))      # fails the test if outstanding != 0
    var list = List.create(ref_of(ta))
    list.push(ref_of(ta), 1)
    list.release(ref_of(ta))
    return t.ok()
```

**Caveat (honest):** leak-checking requires **allocator injection** — code under test must accept
the allocator (the Zig pattern). Code that hardcodes `std.mem.heap.*` is only checkable via
process-level RSS bounds or sanitizer LSan, not the tracking allocator. This is a design pressure
toward allocator-parameterized APIs in `std` and `mtc`.

### 8.2 Death / abort-expectation tests

Assert that code aborts via `fatal()` (e.g. a safe out-of-bounds index, which the language defines
as a `fatal` abort). Runs the body in a forked subprocess and asserts the abort:

```mt
# planned: an @[expect_fatal] companion attribute runs the test in a forked
# subprocess and passes iff the body aborts (e.g. a safe out-of-bounds index).
@[test] @[expect_fatal]
function test_oob_index_aborts() -> t.Check:
    let xs = [1, 2, 3]
    let ignored = xs[5]      # safe indexing → fatal() out of bounds
    return t.ok()
```

### 8.3 Compile-fail tests

Assert that invalid code is *rejected by the compiler with a specific diagnostic* — on-brand for a
safety-focused language (Rust `compile_fail`/`trybuild`, Zig `@compileError`). Fixture files carry
the expectation; `mtc test` runs the compiler and matches the emitted diagnostic:

```mt
# tests/compile_fail/assign_immutable.mt
# expect-error: cannot assign to immutable binding
function main() -> int:
    let x = 1
    x = 2
    return 0
```

### 8.4 Compile-time tests

`static_assert` already provides type/layout/const assertions that run at compile time — a test
module that exercises them passes simply by compiling:

```mt
static_assert(size_of(Point) == 8, "Point must be 8 bytes")
```

### 8.5 Comptime parameterization (table-driven tests)

`inline for` over a compile-time table unrolls type-safe parameterized cases — more powerful than
pytest `parametrize`, with no runtime DI:

```mt
const CASES = [Case(input = 0, want = 0), Case(input = 2, want = 4), Case(input = 3, want = 9)]

@[test]
function test_square_table() -> t.Check:
    inline for case in CASES:
        t.expect_equal_int(square(case.input), case.want)?
    return t.ok()
```

---

## 9. Assertion diagnostics without `assert`-rewriting

pytest's `assert a == b` value introspection comes from runtime AST rewriting — unavailable (and
undesirable) in a static language. Milk Tea uses typed helpers instead: the landed
`expect_equal_int`/`expect_equal_bool`/`expect_equal_str` render `actual`/`expected` into the
failure message via `std.fmt` (e.g. "expected 5, got 4"). Planned: a generic `expect_equal[T]` that
formats via a `Format` constraint, struct rendering via `fields_of(T)` reflection, and
source-location capture. No rewriting magic, fully static.

---

## 10. Output, filtering, CI

- **Human output (landed):** per-test `ok` / `FAIL - <name>: <message>` / `skip - <name>: <reason>`
  lines and a `passed=N failed=N skipped=N` summary.
- **Exit code (landed):** non-zero if any test fails, the run times out, or the binary crashes.
- **Planned:** machine output (`--format tap`/`--format junit`), name/tag filtering
  (`-n <substring>`), `--isolate`/`--sanitize`/`--timeout`/`--mem` flags, per-file progress, and
  rendered diffs with source locations.

---

## 11. What we deliberately do NOT build (and the idiomatic alternative)

| pytest/minitest feature | Why not | Milk Tea alternative |
|---|---|---|
| `assert`-rewriting introspection | requires runtime AST rewriting | typed `expect_*` + `std.fmt`/reflection rendering (§9) |
| Dynamic fixtures with DI | needs dynamism/GC; implicit ordering | explicit setup + `defer` teardown; comptime tables (§8.5) |
| Plugin / `conftest` hooks | runtime hook machinery; opaque | small, explicit `std.testing` surface; compose in Milk Tea |
| Mocking framework | needs dynamic dispatch/monkeypatch | seams via `interface` / `dyn` / `proc` + explicit fakes |
| Class-based suites / inheritance | ceremony | flat `@[test]` functions; group by module/file |

Keep the core minimal; property testing, snapshot/golden, and benchmarks are later `std` additions.

---

## 12. Relationship to the self-host effort

- **Distinct from the differential oracle.** `selfhost.md` §9 validates that `mtc` *compiles*
  correctly (JSON-boundary + behavioral parity vs the Ruby oracle). `mtc test` validates Milk Tea
  *programs* — including `mtc`'s own internal units (interner, type registry, pools).
- **Shared sandbox.** Both reuse the same timeout / memory-cap / sanitizer primitives (§7).
- **Synergy.** A working `mtc test` lets the self-hosted `mtc` be unit-tested in Milk Tea and lets
  the `std` suite migrate off the Ruby-heredoc-exit-code harness (§3). It is an **independent
  track** — buildable before or alongside the self-host work.

---

## 13. Phased Plan

- **T0 — `std.testing` core. ✅ Landed.** `Check`/`Failure`/`Stats`; `ok`/`fail`/`skip`;
  `expect`/`expect_true`/`expect_false`/`expect_equal_int`/`expect_equal_bool`/`expect_equal_str`/
  `expect_some`/`expect_none`; `record`/`summarize`; messages via `std.fmt`.
- **T1 — Built-in `@[test]` + `mtc test`. ✅ Landed (initial slice).** Built-in `@[test]` attribute;
  `mtc test PATH` parses + discovers `@[test]` functions, synthesizes a runner, and builds + runs it
  under a per-binary `RLIMIT_AS` cap + wall-clock timeout with crash/timeout classification. Scope
  of this slice: **single file**, parse-based discovery, tooling-synthesized runner.
- **T2 — Scale-out & richer sandbox.** Directory/package discovery and per-package `tests/`; a
  `when TEST` exclusion for co-located tests; parallel execution across files; cgroup option and
  configurable `--timeout`/`--mem`. *Verify:* a hanging/OOM test is contained; a package's tests run
  in one command.
- **T3 — Tracking allocator + death tests.** `t.tracking_allocator()` / `expect_no_leaks`;
  `expect_fatal` via forked subprocess. *Verify:* a deliberate leak fails; an OOB index passes an
  `expect_fatal` test.
- **T4 — Compile-fail tests.** `# expect-error:` fixtures matched against compiler diagnostics.
  *Verify:* negative fixtures pass only when rejected with the expected diagnostic.
- **T5 — Sanitizer mode + machine output.** `--sanitize` (ASan/UBSan); TAP/JUnit; filtering.
  *Verify:* sanitizer build catches a planted UB; CI consumes machine output.
- **T6 — Migration & dogfood.** Port representative `std` tests off the Ruby harness; add `mtc`
  unit tests in Milk Tea. *Verify:* migrated suites pass under `mtc test`.
- **T7 — Ecosystem (later, in `std`).** Property testing, snapshot/golden, benchmarks. Not core.

---

## 14. Open Questions

**Resolved:**

1. Author-facing form — **resolved: a built-in `@[test]` attribute** (not a `test "…"` block, not a
   naming convention). See §6.
2. Soft vs fail-fast assertions — **resolved: fail-fast** via `?` propagation. See §5.

**Open:**

3. Whether `when TEST` should be implicit around tests or explicit for surrounding helpers — and
   whether to support co-located tests at all vs dedicated test files.
4. Tracking-allocator ergonomics for code that does not take an injected allocator (LSan fallback
   vs requiring injection in `std`).
5. Death-test granularity: per-test fork cost vs a pooled subprocess worker.
6. `RLIMIT_AS`/timeout defaults and how to expose them as per-file/per-test configuration.

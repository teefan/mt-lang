# Milk Tea Testing Framework (`std.testing` + `mtc test`)

> Status: **T0–T6 landed.** Remaining roadmap: T7 (ecosystem). T6 migrated every in-language
> (no-FFI, deterministic) `std` module onto `mtc test`; the Ruby heredoc harness now covers only
> runtime/FFI modules (sockets, GPU, threads, compression, process/filesystem/clock I/O, external
> libs) and the `mtc` self-host units, which await the self-hosted compiler.
> Implemented today: the `std.testing` core (§5) and `mtc test` with built-in `@[test]` discovery,
> runner synthesis, a per-binary timeout + memory cap, directory/package discovery, parallel
> execution, death tests, compile-fail tests, a `--sanitize` mode (ASan/UBSan + LeakSanitizer),
> `-n` name filtering, and TAP/JUnit machine output (§6–§10, §13). Companion to `docs/selfhost.md`.
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
- **No co-located tests.** Tests live in **dedicated files** (no `main`); there is no `when TEST`
  cfg mechanism for mixing tests into production modules (Open Question 3, resolved). This keeps a
  normal build free of any test code and the discovery model simple.
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

**Migration (T6) landed for the in-language `std` suite.** Every pure, deterministic, no-FFI `std`
module now has its tests under `test/mt/` as `@[test]` functions run via `mtc test`, CI-enforced by
`test/std/in_language_tests_test.rb`. This covers the collections (`vec`, `deque`, `set`, `map`,
`counter`, `multiset`, `ordered_map`/`ordered_set`, `linked_map`/`linked_set`, `priority_queue`,
`binary_heap`, `stack`, `queue`, `span`, `bytes`), string/encoding helpers (`string`, `cstring`,
`uri`, `path`, `fmt`, `toml`, `binary`, `ctype`), `math`, `option`/`result`, `errno`, the `mem`
allocators (`heap`, `arena`, `pool`, `stack`; with `@[expect_fatal]` contract-abort death tests in
`heap`/`arena`/`pool`), the
AI/utility modules (`fsm`, `goap`, `behavior_tree`, `cli`, `spatial`, `random`, `net.sync`), and the
`pass` language-feature test. Their Ruby heredoc wrappers have been removed — the in-language tests
are the single source of truth.

What deliberately stays on the `test/std/*_test.rb` heredoc harness: modules that the in-language
runner cannot self-containedly exercise — external-library/FFI bindings (`json`, `gzip`, `zstd`,
`tar`, `sqlite3`, `pcre2`, `curl`, `raylib`, `glfw`/`gl`, `jobs`, `thread`/`thread_sync`), sockets
and network protocols (`net.*` except `net.sync`, `http`), process/filesystem/terminal/clock I/O
(`process`, `fs`, `stdio`, `libc`, `terminal`, `time`), and fixture-dependent tests (`asset_pack`,
which needs pre-built `.mtpack` files on disk). Those wrappers embed a `.mt` heredoc, compile + run
it, and assert on the **exit code** (plus link flags / pipeline outputs the in-language runner does
not check). `mtc`'s own internal unit tests in Milk Tea await the self-hosted compiler.

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
- `t.expect_not_equal_int`, `t.expect_not_equal_bool`, `t.expect_not_equal_str`
- `t.expect_some[T](option)`, `t.expect_none[T](option)`
- `t.expect_null[T](pointer)`, `t.expect_not_null[T](pointer)` (over `const_ptr[T]?`)
- `t.expect_error[T, E](result)` (passes iff the `Result` is a failure)
- `t.expect_equal[T](actual, expected)` — generic equality for any `T` with a canonical `equal` hook
  (primitives via `import std.hash`, `str` via `import std.str`, structs/variants that define
  `equal`); the failure message is value-less, so use the typed `expect_equal_int`/`_bool`/`_str`
  when you want the values rendered
- `t.Check`, `t.Failure` (owned message + skip flag), `t.Stats`, `t.record`, `t.summarize` (the
  hand-written-runner API, still usable directly without `mtc test`)

Generic equality works because the built-in `equal[T]` lowers to the canonical `T.equal` hook,
provided by `std.hash` for every primitive/integer width and by `std.str` for `str`; there is no
nominal `Eq` interface (constraints are enforced structurally at specialization, Zig-style).

Planned additions: source-location capture in `Failure` (needs a compiler builtin). A
*value-rendering* generic `expect_equal[T]` is **not** blocked by a missing equality constraint
(that exists); it is blocked by two compiler limitations described in §9. Teardown uses `defer` (no
fixture runtime).

> By design, tests live in **dedicated files** (no `main`); a normal build does not pull them in.
> Co-locating tests with production code (a `when TEST` cfg exclusion) is intentionally **not
> supported** — Open Question 3, resolved (§1, §14).

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

**Build model: one test binary per test file.** A normal build never references `@[test]` functions
(no `main` → unreferenced → eliminated), so there is no release overhead. `mtc test DIR` (or a
package root) recursively discovers every `.mt` file that contains `@[test]` functions, runs each as
its own binary, and prints an aggregate summary; non-test and unparseable files are skipped. Tests
live in **dedicated files** (no `main`); co-located tests and a `when TEST` exclusion are
intentionally not supported (§1, §14).

---

## 7. Execution model & sandboxing

Because a Milk Tea test compiles to C and runs as a **native binary**, a bug can segfault, call
`fatal()`, hang, or allocate unboundedly. `mtc test` sandboxes every test-binary run:

- **Address-space cap (landed).** The binary is spawned with `RLIMIT_AS` set (1 GiB default,
  override with `--mem MB`) via `Process.spawn(..., rlimit_as:)`, so runaway allocation hits
  `ENOMEM` (→ allocator `fatal`/abort, contained) instead of exhausting the host. (Disabled under
  `--sanitize`, since ASan reserves a very large virtual address space.)
- **Wall-clock timeout (landed).** A watchdog (30 s default, override with `--timeout SECONDS`)
  kills the test's process group (`SIGKILL`) on timeout.
- **Crash/timeout classification (landed).** Timeouts and termination by signal are reported and
  produce a non-zero exit; otherwise the binary's own exit code is propagated.

Planned: a cgroup memory option (`systemd-run … -p MemoryMax=`) and a per-test `--isolate` fork for
finer containment. These reuse the same primitives described in `selfhost.md` §9.

---

## 8. Systems-specific capabilities (the payoff vs pytest)

These are the features that justify a bespoke framework — none exist in minitest/pytest. Death
tests (§8.2) have landed; the rest are planned.

### 8.1 Leak checking (LeakSanitizer — landed)

The originally-planned *injected* `t.tracking_allocator()` is dropped: `std.mem.heap` is global
module functions with no `Allocator` interface, so nothing can inject a wrapping allocator (Open
Question 4, resolved). Because heap allocation funnels through `libc.malloc`/`free`, the right fit is
**LeakSanitizer**: `mtc test --sanitize` builds each test binary with `-fsanitize=address,undefined`,
so any leaked allocation is reported at exit (with a stack trace) and fails the run — zero code
changes, full coverage. The same build also enables AddressSanitizer (memory errors) and UBSan
(undefined behavior). See §13 (T5).

### 8.2 Death / abort-expectation tests (landed)

A `@[test]` function that also carries `@[expect_fatal]` is a **death test**: it must abort (via
`fatal()` or a failed safety check — both lower to `abort()`/SIGABRT). `mtc test` runs each death
test in its **own binary** and passes it iff the binary terminates abnormally; if the test returns
normally it fails ("expected a fatal abort, but the test returned"). Abort detection happens in the
runner via the real exit signal — reliable and portable, with no in-binary fork.

```mt
@[test] @[expect_fatal]
function test_explicit_fatal() -> t.Check:
    fatal("intentional abort")

@[test] @[expect_fatal]
function test_unwrap_none_aborts() -> t.Check:
    let absent: Option[int] = Option[int].none
    let value = absent.unwrap()      # unwrap on none → fatal abort
    return t.expect_equal_int(value, 0)
```

### 8.3 Compile-fail tests (landed)

A fixture file carrying a `# expect-error: <text>` directive is a **compile-fail test**: `mtc test`
runs it through the compiler and passes iff it is rejected with a diagnostic containing `<text>`
(otherwise it fails — either it compiled cleanly, or no diagnostic matched). Detection is by the
directive, so even syntax-error fixtures (which don't parse) are found.

```mt
# test/examples/compile_fail/assign_immutable.mt
# expect-error: cannot assign to immutable
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
failure message via `std.fmt` (e.g. "expected 5, got 4"). The generic `expect_equal[T]` (landed)
covers any type with a canonical `equal` hook but reports a **value-less** message.

A reflective `{any}`-style value formatter has landed. `field.type` is usable in type position
(language-manual §7.0) and the `inline for` body is checked **per element**, so `std.hash`'s
`equal_struct`/`hash_struct`/`order_struct` dispatch each field through its canonical hook
(content-correct, including `str` and **nested structs**), and `std.fmt.format_value[T]` recursively
renders any struct as `{ field = value, ... }`. (This also resolved the earlier bug where those
reflective helpers failed to lower.)

`expect_equal[T]` nonetheless stays **value-less**: rendering its `T` would require dispatching
scalar-vs-struct on the *bare type parameter* (`format_value[int]` cannot reflect a scalar's
fields), and `inline if T == int` on a bare type parameter is a separate, still-unresolved
limitation (distinct from `field.type`). Use the typed `expect_equal_int`/`_bool`/`_str` for
rendered scalar diagnostics, or `format_value` to render a struct. Source-location capture in
`Failure` is also planned. No rewriting magic, fully static.

---

## 10. Output, filtering, CI

- **Human output (landed):** per-test `ok` / `FAIL - <name>: <message>` / `skip - <name>: <reason>`
  lines and a `passed=N failed=N skipped=N` summary.
- **Exit code (landed):** non-zero if any test fails, the run times out, or the binary crashes.
- **Sanitize (landed):** `--sanitize` builds with ASan/UBSan + LeakSanitizer; a sanitizer error
  (leak, OOB, UB) fails the run (§8.1).
- **Filtering (landed):** `-n SUBSTRING` runs only `@[test]` functions (and compile-fail fixtures)
  whose name/filename contains the substring.
- **Machine output (landed):** `--format tap` / `--format junit` emits TAP or JUnit XML for CI
  (the human runner output is captured and transformed into structured results).
- **Planned:** an `--isolate` flag, per-file progress, and rendered diffs with source locations.

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
- **T2 — Scale-out & richer sandbox.**
  - ✅ Landed: **directory/package discovery** — `mtc test DIR` (or a package root) recursively runs
    every `.mt` file containing `@[test]` functions, each as its own sandboxed binary, with an
    aggregate `N test file(s), M failed` summary.
  - ✅ Landed: **per-file build-error isolation** — a file that fails to compile is reported and
    counted as a failed file; the suite continues.
  - ✅ Landed: **configurable limits** — `--timeout SECONDS` (default 30) and `--mem MB` (default
    1024) override the per-binary timeout and address-space cap.
  - ✅ Landed: **parallel execution** — `--jobs N` builds and runs N test files concurrently via a
    fork-per-file worker pool (process-isolated; output stays in file order).
  - Planned: a cgroup memory option. (Co-located tests / a `when TEST` exclusion are out of scope —
    tests live in dedicated files; see §1.)
- **T3 — Death tests. ✅ Landed.** `@[test] @[expect_fatal]` functions run in their own binary and
  pass iff they abort (`fatal()`/safety check → SIGABRT), detected via the real exit signal. (Leak
  checking, originally paired here, is reassigned to T5 as LeakSanitizer — §8.1, Open Question 4.)
- **T4 — Compile-fail tests. ✅ Landed.** A `# expect-error: <text>` fixture passes iff the compiler
  rejects it with a diagnostic containing `<text>` (syntax-error fixtures included).
- **T5 — Sanitizer mode, `-n` filtering, and machine output. ✅ Landed.** `mtc test --sanitize`
  builds test binaries with ASan/UBSan + LeakSanitizer (§8.1); `-n SUBSTRING` selects tests by name;
  `--format tap`/`--format junit` emits machine-readable results for CI.
- **T6 — Migration & dogfood. ✅ Landed (in-language `std` suite).** Every pure, deterministic,
  no-FFI `std` module has been migrated to `@[test]` functions under `test/mt/` (collections,
  string/encoding helpers, `math`, `option`/`result`, `errno`, the `mem` allocators (with
  `@[expect_fatal]` contract-abort death tests in `heap`/`arena`/`pool`), the
  `fsm`/`goap`/`behavior_tree`/`cli`/`spatial`/`random`/`net.sync`
  utilities, and the `pass` language test), run by `mtc test` and CI-enforced via
  `test/std/in_language_tests_test.rb`; the corresponding Ruby heredoc wrappers were removed.
  Intentionally **not** migrated (they cannot be exercised self-containedly in-language and remain
  on the heredoc harness): external-library/FFI bindings, sockets/network protocols, process/
  filesystem/terminal/clock I/O, and fixture-dependent tests. `mtc`'s own unit tests in Milk Tea
  await the self-hosted compiler (`selfhost.md`).
- **T7 — Ecosystem (later, in `std`).** Property testing, snapshot/golden, benchmarks. Not core.

---

## 14. Open Questions

**Resolved:**

1. Author-facing form — **resolved: a built-in `@[test]` attribute** (not a `test "…"` block, not a
   naming convention). See §6.
2. Soft vs fail-fast assertions — **resolved: fail-fast** via `?` propagation. See §5.
3. Co-located tests — **resolved: not supported.** Tests live in dedicated files (no `main`); there
   is no `when TEST` mechanism, keeping normal builds test-free and discovery simple. See §1, §6.
4. Tracking-allocator ergonomics — **resolved: dropped.** No injected `tracking_allocator()`
   (`std.mem.heap` is global, no `Allocator` interface); leak checking uses LeakSanitizer in T5
   (§8.1).

**Open:**

5. Death-test granularity: per-test fork cost vs a pooled subprocess worker.
6. `RLIMIT_AS`/timeout defaults and how to expose them as per-file/per-test configuration.

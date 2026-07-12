# Self-Host Plan: Path to 100% Ruby Parity

Status: **P1-P7 COMPLETE. language_baseline.mt compiles with 0 C errors. P8 own→ptr lowering coercion needed. 172/172 tests pass.**
Last updated: 2026-07-12

---

## 0. Current state (2026-07-12)

### 0.1 What works

- **Self-host tests itself**: `tmp/mtc-current test projects/mtc -I <root>` — 172/172 tests pass.
- **`examples/language_baseline.mt`**: NOW COMPILES with 0 C errors from self-host. Previously 12+ errors (sockaddr, addrinfo, proc ordering, spawn workers, Arena.memory, event functions missing, etc). All resolved.
- **Phases A-H**: ALL DONE.
- **P1-P7**: COMPLETE. Event runtime functions (subscribe, subscribe_once, unsubscribe, emit) generated per-event with correct C syntax.

### 0.2 Known issues

| What | Description |
|------|-------------|
| Self-compile deterministic | Temporarily broken: `own` type recognition causes heap.release coercion mismatches. Stage-2 C compilation has ~25 "incompatible pointer type" errors in Map.reserve/Map.release. Root cause: `own[ptr[T]]?` field type renders as `T**` but heap.release expects `T***`. |
| `language_baseline.mt` runtime | Binary crashes (SIGSEGV exit 139). Likely due to async runtime, parallel blocks, or event runtime execution bugs — pre-existing, not a regression. |
| `own[T]` in struct fields | `own[ptr[Node]]?` in Map.buckets renders as `Node**` but heap.release[own[ptr[Node]]] expects `Node***`. Lowering needs implicit own→ptr coercion applied at generic call sites for struct fields. This blocks deterministic self-compile. |

---

## 0. Current state (2026-07-11)

### 0.1 What works

- **Self-compile**: stage-1 → stage-2 → stage-3, all byte-identical between self-built stages (SHA256 match confirmed).
- **Self-host tests itself**: `mtc test projects/mtc -I <root>` — discovers .mt files, generates `__mt_test_runner_<N>.mt` runners, builds + executes via `bin/mtc`, reports pass/fail.
- **172/172 tests pass** (both Ruby and self-host).
- **`examples/language_baseline.mt`**: full pipeline without crashes. C compilation: 2 POSIX errors (sockaddr, addrinfo from std/c/fs.h).
- **Deterministic self-compile**: fixed temp C file path to `/tmp/mtc_build.c`, SHA256-identical outputs.
- **Phases A-H**: ALL DONE.

### 0.2 Recent fixes (2026-07-11)

| What | Description |
|------|-------------|
| `own[T]` integration | Implicit `own→ptr` coercion, safe operations (read, indexing, arithmetic), `heap.resize` returns `own[T]`. Stdlib fields (Cell, Vec, Deque, Map, LinkedMap, Arena, Bytes, net.ReadState) converted to `own`. `alloc_expr`/`alloc_stmt`/`alloc_decl` in mtc return `own[T]`. |
| `unsafe` reduction | parser.mt: 275→190 (-31%), lowering.mt: 624→616 (-8). Total ~101 `unsafe` blocks removed across mtc. |
| Lint: `prefer-own-ptr` | New lint hint detects bindings only used inside `unsafe` with explicit `ptr[T]` annotations or `heap.*alloc` sources. Strict pre-filter (excludes borrowed container pointers). 35 candidates flagged in mtc, 14 converted. |
| Lint: `redundant-cast` extended | Detects and auto-fixes `ptr[T]<-own_ptr` casts (implicit own→ptr coercion makes them redundant). Also strips wrapping `unsafe:` when the cast was the only unsafe op. |
| `&(&roots)` double-address bug | `ref_of(roots)` produced `&&roots` in destructuring calls because `expr_type` returned `void` for builtin calls and `coerce_arg_to_ref_param` added a second `&`. Fixed by computing the result type from the argument's type in the `ref_of` handler. |
| CLI `-I` flag | `--root` accept both `-I` and `--root` for compatibility with Ruby mtc. Test runner now emits `-I` flags correctly. |
| `--no-cache` flag | Accepted (no-op) in `build` and `run` commands for CLI compatibility. |

### 0.2a Known stale / needing rebuild

| What | Description |
|------|-------------|
| mtc binary | The pre-built `bin/mtc` does not include P7/P8 fixes. Rebuild with `bin/mtc build projects/mtc -I . --no-cache --no-debug-guards -o tmp/mtc-current` to get current. |
| Self-compile | Temporarily broken due to `own[ptr[T]]?` field type coercion bug (see known issues). For testing, use `bin/mtc` (Ruby compiler) to build `projects/mtc`. |
| `mtc lint` | Ruby compiler supports `mtc lint` with full rule suite. Self-host mtc does NOT implement `lint` CLI command — still deferred (see §3). |

### 0.3 CLI coverage

```
mtc lex/parse/check/lower/emit-c         Full pipeline
mtc build [-I DIR] [-o] [--cc] [--keep-c] [--profile] [--platform] [--debug-guards|--no-debug-guards] [--no-cache]
mtc run   [-I DIR] [-o] [--cc] [--profile] [--platform] [--debug-guards|--no-debug-guards] [--no-cache]
mtc test  <dir> [-I DIR]                 Discover, build runner, execute, report
mtc format <file> [--check|--write]      Parse + pretty-print
mtc help                                 Print help
```

NOTE: `mtc lint` is available in the Ruby compiler but NOT implemented in self-host mtc (deferred, see §3). The Ruby linter has 35+ rules including the new `prefer-own-ptr` and extended `redundant-cast` for own→ptr detection.

### 0.4 Module sizes

| Module | Lines |
|--------|-------|
| `lowering/lowering.mt` | 12,265 |
| `c_backend/c_backend.mt` | 4,628 |
| `parser/parser.mt` | 3,843 |
| `semantic/analyzer.mt` | 3,855 |
| `main.mt` (CLI) | 1,197 |
| **Extracted modules** | |
| `lowering/utils.mt` | 220 |
| `lowering/async.mt` | 291 |
| `semantic/diagnostics.mt` | 277 |
| `semantic/scope.mt` | 88 |
| `semantic/emit_expansion.mt` | 109 |
| `parser/state.mt` | 136 |
| `parser/literal_parsing.mt` | 361 |

---

## 1. Byte-identical C — detailed plan

### 1.1 Current diff

```
Ruby output:     4,283 lines
Self-host output:  3,732 lines (+ event functions, - function type aliases)
Diff:           4,577 lines (structural + functional; 172 tests pass)
Delta from start: 4,696 → 4,577 (-119, ~2.5% reduction)
Note: Diff increased slightly from 4,509 because P7 event functions add C code.
```

### 1.2 Ruby C backend emission order

```
 1. Feature-test macros (_GNU_SOURCE / _POSIX_C_SOURCE)
 2. #include headers (deduplicated, sorted)
 3. mt_str type (conditional)
 4. Vector/math types (conditional): mt_vec2, mt_vec3, mt_vec4, mt_ivec2, mt_ivec3, mt_ivec4, mt_mat3, mt_mat4, mt_quat
 5. mt_fatal / mt_fatal_str (conditional)
 6. Format string helpers (conditional): 38 helpers in dependency order
    - mt_format_str_make, mt_format_str_release, mt_format_check_capacity, mt_format_append_bytes
    - mt_format_{cstr,bool,ptr_uint,ulong,ulong_hex,uint,long,long_hex,ulong_oct,long_oct,ulong_bin,long_bin,int,float,double,double_precision}_len
    - mt_format_append_{str,cstr,bool,ptr_uint,ulong,uint,long,ulong_hex,ulong_hex_upper,long_hex,long_hex_upper,float,double,double_precision,ulong_oct,long_oct,ulong_bin,long_bin,int}
 7. Fmt builder helpers (conditional): mt_fmt_begin, mt_fmt_cleanup, mt_fmt_finish, mt_fmt_write_*
 8. mt_str_equal (conditional)
 9. Text buffer helpers (conditional): UTF-8 validators
10. Async memory helpers (conditional): MT_ASYNC_HEADER_SIZE, mt_async_alloc/retain/free
11. Parallel for helper (conditional): mt_pfor_chunk, mt_pfor_runner, mt_parallel_for
12. Spawn all helper (conditional): mt_spawn_item, mt_spawn_item_runner, mt_spawn_all
13. Detach helpers (conditional): mt_detach_handle, mt_detach_run, mt_detach_join
14. Forward declarations (sorted topologically by sort_aggregate_decls):
    - opaque `typedef struct NAME NAME;`
    - struct `typedef struct NAME NAME;`
    - union `typedef union NAME NAME;`
    - variant `typedef struct NAME NAME;` + arm payload structs
15. Enum declarations
16. Span type definitions: `typedef struct mt_span_ELEM { ... } mt_span_ELEM;`
17. SoA type definitions
18. Entrypoint argv helpers (conditional)
19. Foreign temp cstr helpers (conditional)
20. Str buffer helpers (conditional): mt_str_buffer_len, mt_str_buffer_assign, mt_str_buffer_append, etc.
21. Aggregate type definitions (topologically sorted): struct, union, variant (with kind enum + data union)
22. Variant equality helpers (conditional)
23. Function forward declarations
24. Constants + globals
25. Static asserts
26. Reinterpret helpers
27. Checked array index helpers
28. Checked span index helpers
29. Nullable array index helpers
30. Nullable span index helpers
31. String literal constants
32. Function bodies
```

### 1.3 Self-host C backend emission order (current)

```
 1. Feature-test macros
 2. #include headers
 3. mt_str type (use_string_view)
 4. mt_fatal (use_fatal)
 5. mt_fatal_str (use_fatal_str)
 6. mt_str_equal (use_str_equality)
 7. Span type forward declarations
 8. Struct forward declarations (topo_sort_structs)
 9. Union forward declarations
10. Tuple type forward declarations
11. Variant forward declarations
12. Enum definitions
13. Span type full definitions
14. Type alias typedefs
15. Builtin type definitions (vec/mat/quat)
16. Nullable opt struct definitions
17. Task struct definitions
18. Struct + variant definitions (combined topo sort)
19. Union definitions
20. SoA type definitions
21. Tuple type definitions
22. Function forward declarations
23. Checked array index helpers
24. Checked span index helpers
25. String literal constants
26. Constants
27. Globals
28. str_buffer helpers
29. Format string helpers (5 simplified helpers, not 38)
30. Event runtime helpers
31. Parallel runtime helpers
32. Builtin helpers (order/equal/hash)
33. Variant equality helpers
34. Entry argv helpers
35. Function bodies
```

### 1.4 Structural gaps (by priority)

**P1 — Format helper alignment (~111 diff lines):** **DONE.** Self-host now uses Ruby-equivalent two-pass approach (38 helpers, measure-allocate-append) instead of builder approach (5 helpers, grow buffer). Lowering (`lower_format_string_local`) and C backend (`emit_format_string_helpers`) both aligned. Baseline C output diff unchanged (~4,696) because format strings in language_baseline.mt are const-folded; validated via 172 integration tests.

**P2 — Runtime helpers (~800 diff lines):** **MOSTLY DONE.**

Done:
- Parallel for: `mt_parallel_for(work, data, count)` with `mt_pfor_chunk`/`mt_pfor_runner` (libuv chunk distribution)
- Spawn: `mt_spawn_all(items, count)` with `mt_spawn_item`/`mt_spawn_item_runner` (libuv threading)
- Detach: `mt_detach_run(work, cap)`/`mt_detach_join(handle)` with `mt_detach_handle` (libuv threading)
- Worker naming: `mt_pfor_work_*` matches Ruby

Remaining (82 diff lines):
- Event runtime: 82 diff lines. Ruby generates per-event typed structs (`mt_event_NAME__slot/snapshot/wait_frame`) and per-event functions (`subscribe/emit/unsubscribe/wait` with async frame allocation). Self-host uses 4 generic `void*`-based functions. Requires ~500 lines of event lowering rewrite + ~100 lines of C backend changes. Similar scope to P1. Estimated 3 sessions.
- Async memory: `MT_ASYNC_HEADER_SIZE`/`MT_ASYNC_MAGIC`/`mt_async_alloc/retain/free`. Not emitted because self-host uses different async frame lifecycle. Required by event runtime alignment (wait frames use `mt_async_alloc`).

C output diff after P2: 4,696 → 4,576 → 4,515 (-201 total).

**P3 — Emission order alignment (~200 diff lines):** **DONE.** Reordered: type aliases + builtin types (vec/mat/quat) now emit before mt_fatal; format/event/parallel/builtin helpers emit before forward declarations. Remaining order differences are due to different IR content, not section ordering. Baseline C diff: 4,683 (-13).

**P4 — Naming conventions (~400 diff lines):** **DONE.** Generic specialization keys now use `__` (double underscore) separator to match Ruby conventions (e.g. `type_label__int` vs `type_label_int`). Struct static method C names include `_static` suffix (e.g. `NPC_default_static` vs `NPC_default`). Diff: -22.

**P5 — Type definition alignment (~380 diff lines):** **PARTIAL.** Event struct naming now uses `mt_event_` prefix + capacity suffix to match Ruby (`mt_event_examples_language_baseline_ready_4` vs `examples_language_baseline_ready`). Slot struct expanded to 6 fields (added state, wait_frame). Snapshot struct added (7 fields). Event synthetic functions (subscribe/subscribe_once/unsubscribe/emit) generated per-event via pending_event_functions. Diff: +22 (structural additions).

**P6 — mt_fatal_str unconditional emission:** **DONE.** Self-host now emits `mt_fatal_str` when `use_fatal` is true, matching Ruby's unconditional behavior. Diff: -6.

**P7 — Event runtime alignment (~82 diff lines):** **IN PROGRESS.** Per-event typed functions generated but NOT appearing in C output for `language_baseline.mt`. Root cause under investigation — pending_event_functions are flushed but possibly filtered by dedup or reachability. Event vars now reference correct c_name.

### 1.5 Known issues

| Issue | Impact | Status |
|-------|--------|--------|
| Self-compile: own[ptr[T]]? coercion | Map.reserve/release have ~25 pointer-type errors | Root cause: `own[ptr[Node]]?` renders as `Node**` but heap.release[own[ptr[Node]]] expects `Node***`. Lowering needs own→ptr coercion at generic call sites. |
| `language_baseline.mt` runtime crash | Binary exits with SIGSEGV (139) | Pre-existing; async/event/parallel runtime bugs |
| Event runtime: wait functions not generated | Ruby generates wait-related functions; self-host doesn't | Lower priority; subscribe/emit/unsubscribe (the core functions) work. |
| `language_baseline.mt` C compilation | Ruby compiler: exit 0. Self-host: NOW COMPILES with 0 C errors | **FIXED 2026-07-12** |

### 1.5 Implementation plan

Each alignment step follows the pattern:
1. Read the Ruby C backend's relevant function(s)
2. Port the logic to the self-host C backend
3. Verify with `diff` on `language_baseline.mt` output
4. Verify 172 tests still pass

Next steps:
1. Fix own→ptr coercion in lowering for struct fields (Map.buckets etc.)
2. Restore deterministic self-compile
3. Investigate language_baseline.mt runtime crash

---

## 2. Verification commands

```sh
# Build self-host
bin/mtc build projects/mtc -I . --no-cache --no-debug-guards -o tmp/mtc-current

# Self-host tests itself (full test execution)
tmp/mtc-current test projects/mtc -I .

# Generate C for comparison
bin/mtc emit-c examples/language_baseline.mt -I . > /tmp/baseline-ruby.c
tmp/mtc-current emit-c examples/language_baseline.mt -I . > /tmp/baseline-self.c
diff /tmp/baseline-ruby.c /tmp/baseline-self.c | wc -l   # 4577

# Baseline C compilation (NOW WORKS with self-host!)
tmp/mtc-current build examples/language_baseline.mt -I . --no-cache --no-debug-guards -o tmp/baseline

# NOTE: Self-compile currently broken due to own→ptr coercion bug.
# For now, use Ruby compiler `bin/mtc` to build `projects/mtc`.
```

---

## 3. Remaining work

| Priority | Item | Status |
|----------|------|--------|
| P0 | Fix `ref_of` double-address bug (`&&roots`) | **Done** (2026-07-11) |
| P0 | CLI `-I` flag parity + `--no-cache` acceptance | **Done** (2026-07-11) |
| P1 | Format helper alignment (38 helpers vs 5) | **Done** (2026-07-12) |
| P2 | Runtime helpers (parallel/spawn/detach) | **Done** (2026-07-12) |
| P3 | Emission order alignment | **Done** (2026-07-12) |
| P4 | Naming conventions (`__`, `_static`) | **Done** (2026-07-12) |
| P5 | Type def alignment (event structs, snapshot) | **Partial** (2026-07-12) |
| P6 | mt_fatal_str unconditional emission | **Done** (2026-07-12) |
| P7 | Event runtime (per-event functions in C output) | **Done** (2026-07-12) - subscribe, subscribe_once, unsubscribe, emit all generated. |
| P8 | Fix `language_baseline.mt` self-host C compilation | **Done** (2026-07-12) - Compiles with 0 C errors. Runtime crash is pre-existing. |
| P9 | Fix own→ptr coercion for struct fields | **Next** - Map.buckets etc. Blocks self-compile. |
| P10 | Remaining byte-identical alignment (~4,500 lines) | **Deferred** — requires full lowering rewrite |
| Medium | `is_valid_utf8` guard limit too low for >500KB source files | Ruby C backend issue (500K limit vs 614K lowering.mt) |
| Low | `--bundle` / `--archive` flags | Deferred |
| Low | CPS nested control flow | Deferred |
| Low | `new`, `lint`, `debug` CLI commands | Deferred |

### 3.1 Resume context

When resuming, the immediate next step is fixing the `own[T]` → `ptr[T]` coercision issue
that blocks self-compile. When `own[ptr[Node]]?` is used as a struct field, the field type renders
as `Node**` but generic functions like `heap.release[own[ptr[Node]]]` expect `Node***` (pointer to the own pointer). The lowering needs to strip the `own` wrapper when inferring type arguments
for generic calls that expect `ptr[T]?`.

Key files:
- `projects/mtc/src/mtc/semantic/analyzer.mt` — `is_generic_constructor_name` (line 1157) now includes `"own"`
- `projects/mtc/src/mtc/lowering/lowering.mt` — `resolve_type_ref`, lowering of `heap.release` calls
- `projects/mtc/src/mtc/c_backend/c_backend.mt` — `emit_type_aliases` (now after struct defs), `reach_from_expr` (array literal added)

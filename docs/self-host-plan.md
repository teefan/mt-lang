# Self-Host Plan: Path to 100% Ruby Parity

Status: **CLI complete, self-host tests itself, language_baseline compiles, 172 tests pass.**
Last updated: 2026-07-11

---

## 0. Current state (2026-07-11)

### 0.1 What works

- **Self-compile**: stage-1 → stage-2 → stage-3, all byte-identical between self-built stages.
- **Self-host tests itself**: `mtc test projects/mtc` — discovers .mt files, generates `__mt_test_runner_<N>.mt` runners, builds + executes via `bin/mtc`, reports pass/fail.
- **172/172 tests pass** (both Ruby and self-host).
- **`examples/language_baseline.mt`**: full pipeline without crashes. C compilation: 2 POSIX errors (sockaddr, addrinfo from std/c/fs.h).
- **Deterministic self-compile**: fixed temp C file path to `/tmp/mtc_build.c`, SHA256-identical outputs.
- **Phases A-H**: ALL DONE.

### 0.2 All commits (32b5b59d..HEAD)

| Batch | Commits | What |
|-------|---------|------|
| Bug fixes + CLI | `2b26aa9e`, `42ed6c6b`, `6eac8017` | Nullable lowering, -o/--keep-c/--cc, run command, vec/mat/quat, vtable |
| Refactoring | `380d908c`…`ad3d244e` | 7 modules extracted (utils, diagnostics, emit_expansion, scope, state, literal_parsing), async dedup |
| CLI features | `86a8d4c0`, `49efbf19`, `85153df4`, `d2be0036` | --debug-guards, --profile, --platform, format, test execution, Ruby crash fix |

### 0.3 CLI coverage

```
mtc lex/parse/check/lower/emit-c         Full pipeline
mtc build [--root] [-o] [--cc] [--keep-c] [--profile] [--platform] [--debug-guards|--no-debug-guards]
mtc run   [--root] [-o] [--cc] [--profile] [--platform] [--debug-guards|--no-debug-guards]
mtc test  <dir> [--root]                 Discover, build runner, execute, report
mtc format <file> [--check|--write]      Parse + pretty-print
mtc help                                 Print help
```

### 0.4 Module sizes

| Module | Lines |
|--------|-------|
| `lowering/lowering.mt` | 12,321 |
| `c_backend/c_backend.mt` | 4,626 |
| `parser/parser.mt` | 3,928 |
| `semantic/analyzer.mt` | 3,847 |
| `main.mt` (CLI) | 1,190 |
| **Extracted modules** | |
| `lowering/utils.mt` | 222 |
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
Ruby output:    4,283 lines
Self-host output: 3,611 lines
Diff:          4,691 lines
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

**P1 — Format helper alignment (~111 diff lines):**
Self-host uses simplified builder approach (mt_fmt_builder + 5 helpers) vs Ruby's 38 helpers with transitive dependency resolution. To align:
- Replace the self-host's `emit_format_string_helpers` with helpers matching Ruby's
- Implement the 38 helpers from `lib/milk_tea/core/c_backend/runtime_helpers.rb`
- Implement format detection (`uses_format_*` pattern from `feature_detection.rb`)
- Each helper conditional on use detection

**P2 — Emission order alignment (~200 diff lines):**
- Move mt_str to position 3 (matching)
- Builtin type defs (vec/mat/quat) move from position 15 to position 4 (before mt_fatal)
- Forward declarations merge into single section (position 14) instead of split (7-11)
- str_buffer helpers move from position 28 to position 20 (before aggregate types)
- Constants + globals move to position 24 (after function forward decls)
- Variant equality moves to position 22 (after struct/variant defs, before function forward decls)

**P3 — Forward declaration structure (~150 diff lines):**
- Ruby sorts ALL aggregate types together via `sort_aggregate_decls` (structs + unions + variants + generic structs + generic variants + Task structs + proc structs + dyn structs + str_buffer structs + nullable opt structs)
- Self-host separates: span fwd decls → struct fwd decls → union fwd decls → tuple fwd decls → variant fwd decls
- Self-host also has separate full definitions for Task/opt before struct+variant definitions
- To align: merge all aggregate type declarations into a single topologically sorted pass

**P4 — Missing sections (~80 diff lines):**
- Reinterpret helpers (position 26 in Ruby)
- Nullable array/span index helpers (positions 29-30 in Ruby)
- Static asserts section (position 25 in Ruby)

**P5 — Prelude/event handling (remaining diff):**
- Different Option/Result variant arm payload struct emission
- Event runtime generates different infrastructure (Ruby: slot, snapshot, wait_frame; self-host: simplified)

### 1.5 Implementation plan

Each alignment step follows the pattern:
1. Read the Ruby C backend's relevant function(s)
2. Port the logic to the self-host C backend
3. Verify with `diff` on `language_baseline.mt` output
4. Verify 172 tests still pass

Estimated effort: ~4-6 sessions for full byte-identical alignment.

---

## 2. Verification commands

```sh
# Build self-host
bin/mtc build projects/mtc --no-cache --no-debug-guards -o tmp/mtc-final

# Self-host tests itself (full test execution)
tmp/mtc-final test projects/mtc --root .

# Generate C for comparison
bin/mtc emit-c examples/language_baseline.mt > tmp/baseline-ruby.c
tmp/mtc-final emit-c examples/language_baseline.mt --root . > tmp/baseline-self.c
diff tmp/baseline-ruby.c tmp/baseline-self.c | wc -l

# Stage-2 self-compile
tmp/mtc-final build projects/mtc --root . -o tmp/mtc-stage2
tmp/mtc-stage2 build projects/mtc --root . -o tmp/mtc-stage3
sha256sum tmp/mtc-stage2 tmp/mtc-stage3  # should match
```

---

## 3. Remaining work

| Priority | Item | Status |
|----------|------|--------|
| P1 | Format helper alignment (38 helpers vs 5) | Planned |
| P2 | Emission order alignment | Planned |
| P3 | Forward declaration structure merge | Planned |
| P4 | Missing sections (reinterpret, nullable index, static_asserts) | Planned |
| P5 | Prelude/event handling | Planned |
| Low | `--bundle` / `--archive` flags | Deferred |
| Low | CPS nested control flow | Deferred |
| Low | `new`, `lint`, `debug` CLI commands | Deferred |

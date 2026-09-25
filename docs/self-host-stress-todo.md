# Self-host: build `projects/stress` — DONE

Goal: `build/stage2/mtc build projects/stress` compiles, links, and runs with
output matching the Ruby host compiler's build of the same project.

**Status: achieved.** The self-host build of `projects/stress` compiles without
`cc` diagnostics, runs, and matches the host reference exactly — exit **242**,
empty stdout, empty stderr. The fixed-point gate holds (`stage2.c == stage3.c`)
and the self-host test suite gained coverage for every behavior fixed here.

Reference behavior: the host build of `projects/stress` (`ruby -Ilib bin/mtc
build projects/stress -I . --no-cache --keep-c /tmp/stress_host_ref.c -o
/tmp/stress_host2`) exits **242** with empty stdout/stderr.

## How to reproduce and verify

```sh
# 1. Build the self-host compiler from the current sources
ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o build/dev/mtc

# 2. Build the target project
timeout 300 bash -c 'ulimit -v 20000000; \
  build/dev/mtc build projects/stress -I . --no-cache -o /tmp/stress_self'

# 3. Compare against the host build (both must exit 242 with empty stdout)
timeout 20 bash -c 'ulimit -v 20000000; /tmp/stress_self'; echo $?

# 4. Gate: fixed point + compiler self-tests
tools/bootstrap.sh -j 16     # must print: stage2.c == stage3.c (fixed point holds)
```

Per-section parity was checked with a probe driver (a copy of the project whose
`main` prints each section's subtotal through `std.terminal`): all 12 sections —
including `compile_time`, `math` and `async` — are byte-identical to the host.

## What was broken (root causes, not symptoms)

| Area | Root cause | Fix |
| --- | --- | --- |
| `aio.wait(task_expr)` | a `Task[X]` argument passed to a `proc() -> Task[X]` parameter was handed over as a bare task value; the existing narrow bridge only matched same-module *bare-identifier* callees, so `atasks.task_pipeline()` (qualified) fell through, and its `lower_fn_to_proc` approach also dropped call arguments | the host's task-expression→root-proc bridge (`direct_task_to_proc_argument_compatible?` + `wrap_task_expression_in_root_proc`) is implemented in `lower_call_with_callee`: the argument AST is wrapped in a synthesized `proc() -> Task[X]` thunk (`lower_task_expression_as_root_proc`) and lowered through the proc path, capturing enclosing locals. `lower_proc_expression` was split so a proc with an already-resolved signature can be lowered (`lower_proc_expression_typed`), and the invoke builders take the resolved return type instead of a `TypeRef` |
| proc literal inside an async function | `build_proc_invoke_fn` / `build_capturing_invoke` cleared the CPS state but not `ctx.inside_async`, so `return x + offset` was wrapped in a `(mt_task_int){ .value = ... }` literal while the invoke returned `int32_t` | both builders save/clear/restore `inside_async` alongside the other CPS flags |
| `3.0 * v3` | builtin `vec3(...)`/`mat4(...)`/`quat(...)` constructor calls were unknown callables, so the local's analyzer type was `<error>`; `infer_binary` then fell through to the numeric fallback (float) and lowering emitted `(mt_vec3) 3.0 * v3` | `try_construction` resolves builtin vec/mat/quat names to their builtin types (mirrors host `lookup_named_type`), so the vector rules fire in the analyzer and `lower_vec_binary_op` expands component-wise (`{ .x = 3.0 * v3.x, ... }`) |
| `f"#{hex}"` on a format-string local | `lower_format_string_local` emitted the C local but never pushed a `LocalBinding`, so a later interpolation saw `<error>` and formatted the `str` value as an int (`aggregate value used where an integer was expected`) | the local binding is registered (mirrors `lower_match_expression_local`); capacity/append now use `.len` + `mt_format_append_str` like the host |
| `inline for` over `members_of` / `attributes_of` | qualified type arguments (`types.EntityKind`) were not resolved; member names and enum values were only looked up in the *current* module; `attributes_of` was hardcoded to a `Labeled`/`value` special case; `member.name` was never substituted | `comptime_type_arg_name` resolves module-qualified names; member names/values resolve program-wide; `attributes_of` counts real attribute applications — declaration-level from the analyzer's `attribute_applications`, field-level from the new `field_attribute_apps` (`Type.field`, recorded by the analyzer) with an optional attribute-name filter; `inline_for_member_subst` handles `.name` |

Earlier fixes that were already in place (guard-value projection, `defer` scopes,
qualified destructuring, type-parameter method fallback, dyn alias resolution,
proc-typed aliases/fields/elements, variant arm payloads, async proc captures,
`proc_struct_decl`) are unchanged.

## Regression tests

Added, and passing under both compilers:

* `test/mt/reflect_test.mt` — `inline for` over `members_of` (`.name`, `.value`),
  `attributes_of(Type)`, `attributes_of(Type, name)`,
  `attributes_of(field_of(Type, field)[, name])`.
* `test/mt/fmt_test.mt` — interpolating format-string locals (dynamic and
  all-static) into a later format string.
* `test/mt/linear_algebra_test.mt` (new) — vec/ivec/mat/quat arithmetic:
  component-wise, `scalar * vector` and `vector * scalar`, `vector / scalar`,
  negation, and the `std.linear_algebra` methods.

## Verification log

* `build/dev/mtc build projects/stress` → builds; binary exits 242, stdout and
  stderr empty; per-section probe identical to the host.
* `tools/bootstrap.sh -j 16` → `stage2.c == stage3.c (fixed point holds)`,
  compiler self-test `12 test file(s), 0 failed`.
* `build/stage2/mtc test test/mt -I . --timeout 60` → 56 files, **6 failed** —
  all six pre-existing and unrelated to this workstream (see below). Before
  these fixes 9 failed: the same six plus `fmt_test`, `reflect_test` and
  `linear_algebra_test`, i.e. the new tests fail on the pre-change compiler and
  pass now.
* `rake "cli:parity"` → 61 cases, 21 match, 39 differ, 1 pending. The differ set
  is **byte-identical** to the pre-change compiler's (compared case by case), so
  no CLI regression.
* Ruby host suite: `test/compiler/lowering_test.rb`,
  `test/compiler/semantic/*`, `test/compiler/examples_smoke_test.rb` and
  `test/std/in_language_tests_test.rb` (which runs `test/mt` through the host)
  all pass.

## Known gaps (pre-existing, out of scope here)

* Six `test/mt` files fail to *build* under the self-host compiler:
  `behavior_tree_test`, `fsm_test`, `goap_test`, `htn_test`, `net_sync_test`,
  `spatial_test`. The failure family is generic-instance naming/typing when the
  type argument is declared in a generated module — e.g. the diagnostic
  `std_goap_find_node_index__error__error__error` specialization key collapsing
  to `error` type names, and `Tree[<runner>Context]` instances whose C name is
  qualified with the generated test-runner module. Verified identical with a
  compiler built from the pre-change tree.
* `rake "cli:parity"` divergence set (39 cases, e.g. `build-library`,
  `build-broken-entry`, `build-unknown-option` diagnostics text/ordering) is
  unchanged by this work.
* Host-only quirk found while writing the reflection tests: inside
  `inline for member in members_of(...)`, the Ruby host folds `if name == "..."`
  with a stale per-iteration binding and silently drops the branch for every
  iteration after the first. The self-host substitutes each iteration's own
  value, so the two agree only when the name is consumed at runtime. Worth a
  separate look on the host side.

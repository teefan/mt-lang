# Self-host: build `projects/stress` — remaining work

Goal: `build/stage2/mtc build projects/stress` compiles, links, and runs with
output matching the Ruby host compiler's build of the same project.

Reference behavior: the host build of `projects/stress` (`ruby -Ilib bin/mtc
build projects/stress -I . --no-cache --keep-c /tmp/stress_host_ref.c -o
/tmp/stress_host2`) exits **242** with **empty stdout**. Parity means the
self-host build matches that.

Status: the front end is clear and codegen is nearly there. The self-host build
now produces C that fails only **7** `cc -fsyntax-only` diagnostics (down from
70), in the two clusters below. Every change on this path was verified against
the fixed-point gate (`tools/bootstrap.sh`), which has held at every step.

## How to reproduce and localize

```sh
# 1. Build the self-host compiler from the current sources
ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o build/dev/mtc

# 2. Build the target project (the driver saves the C it compiled)
timeout 300 bash -c 'ulimit -v 20000000; \
  build/dev/mtc build projects/stress -I . --no-cache -o /tmp/stress_self'

# 3. Get exact C line numbers.  The driver's source mapping is approximate
#    (it points at the call site, not the defect); the saved C does not lie.
C=$(ls -t /tmp/mtc_build_stress_self_*.c | head -1)
cc -fsyntax-only -I . -I std -I std/c "$C" 2>&1 | grep -A4 "error:" | head -30
```

Always run the fixed-point gate after every change, never only at the end of a
batch — several changes that looked correct at the CLI level broke the
compiler's own bootstrap (one aborted it outright with `lowering: match
requires known type, got Result_success`):

```sh
tools/bootstrap.sh -j 16     # must print: stage2.c == stage3.c (fixed point holds)
```

## TODO

### 1. `await` / `wait` typing

* **Symptom**: 4 errors — `incompatible type for argument 1 of
  'std_async_wait__int'` (x3, main.mt) and `incompatible types when returning
  type 'mt_task_int' but 'int32_t' was expected` (async_tasks.mt).
* **Cause**: task values are typed `mt_task_*` on one side of the call and the
  awaited/bare type on the other.  Note `std_async_libuv_runtime_wait_on__int`
  already calls `root.invoke(root.env)` correctly, so the fault is in how the
  *argument* to `wait` is typed, not in the call shape.
* **Verify**: the errors vanish; the async output still matches the host, and the
  fixed point holds.

### 2. `math.mt`: operator on a struct, and format-string arguments

* **Symptom**: 3 errors — `conversion to non-scalar type requested` at
  `let reversed = 3.0 * v3` (an `extending`-block operator taking a struct on the
  right) and `aggregate value used where an integer was expected` (x2) in
  `format_strings_demo`.
* **Verify**: the errors vanish; the fixed point holds.

### 3. End-to-end verification and gates

* `build/stage2/mtc build projects/stress` succeeds; run the binary and compare
  stdout + exit status against the Ruby host's build (expected: exit 242, empty
  stdout).
* Then: the self-test suite (`build/stage2/mtc test test/mt -I .`) and
  `rake "cli:parity"`.

## Already fixed on this path (do not re-investigate)

| Commit | Fix |
| --- | --- |
| `ade972cc` | guard-value projection (single storage local), match temp naming, absent-else shape |
| `a543165e` | `defer` inside `unsafe:` / nested blocks replayed after the block closed |
| `f3651dbd` | qualified destructuring (`let types.Transform(x, y, rot) = t`); `packed`/`align`/`deprecated`/`test`/`expect_fatal` builtin attributes |
| `47684ed8` | type-parameter method fallback (`entity_killed.emit(entity.id_value())`) |
| `18886806` | `dyn[alias.Interface]` lookup resolved through the import alias (`dyn lowering: interface not found`) |
| `ea010947` | dyn interface names sanitized for C (dotted alias leaked into symbols) |
| `a9eb5ec4` | proc-typed type aliases declare their shared `mt_proc_*` struct (`proc_struct_decl`); dyn symbols canonicalized on the declared interface name (`c_naming.dyn_iface_declared_name`) and the dead `InterfaceAnalysis.module_name` threading removed; user-defined generic variants collected into `Program.monomorphized_variants` with arm payload fields, module-qualified arm constructors, no-payload arms and kind-switch `match` routing (prelude `Option`/`Result` excluded — registering those generically breaks the bootstrap); async proc captures get a real C parameter instead of `int32_t __mt_frame->local_offset`; proc bodies no longer inherit the enclosing async function's CPS return state; qualified destructuring resolves fields in the value's declaring module; dyn wrapper casts use the concrete type's own module |
| this commit | a proc-typed alias resolves to its closure struct on the *qualified* path too (`proc_alias_struct_type`, shared with the local-alias path) — `var ops: array[types.Callback, 3]` declared as `int32_t (*ops[3])(int32_t)` before |
| this commit | calls through a proc-typed member go through `.invoke`/`.env` (`step.handler(x)`, `s.cb()` previously lowered to a nonexistent `<module>_<Struct>_<field>` function); variant-arm bindings resolve their payload field types from `arm_payload_fields` |
| this commit | a call through a proc value/field takes its type from the closure's own signature when the analyzer recorded none (`let _s = scaler(10.0)` declared `void`) |
| this commit | calling a proc held in an array element (`ops[selector](10)`) lowered to a zero-init `{ 0 }` — the `lower_call` default for an unhandled callee shape; an `expr_index_access` callee of proc type now calls through the element |

Regression tests are still owed for the `defer`-scope and dyn-alias fixes (both
produced crashes rather than diagnostics) and for qualified destructuring, the
type-parameter fallback, and the proc/variant/dyn changes above. Test location:
`test/mt/`.

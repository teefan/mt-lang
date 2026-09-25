# Self-host: build `projects/stress` — remaining work

Goal: `build/stage2/mtc build projects/stress` compiles, links, and runs with
output matching the Ruby host compiler's build of the same project.

Reference behavior: the host build of `projects/stress` (`ruby -Ilib bin/mtc
build projects/stress -I . --no-cache --keep-c /tmp/stress_host_ref.c -o
/tmp/stress_host2`) exits **242** with **empty stdout**. Parity means the
self-host build matches that.

Status: the front end is clear and codegen is nearly there. The self-host build
now produces C that fails only **22** `cc -fsyntax-only` diagnostics (down from
70), all in five clusters listed below. Every change on this path was verified
against the fixed-point gate (`tools/bootstrap.sh`), which has held at every
step.

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

### 1. Proc-typed array elements render as bare function pointers

* **Symptom**: 10 errors in `projects/stress/src/engine/closures.mt`:
  `incompatible types when assigning to type 'int32_t (*)(int32_t)' from type
  'mt_proc_int_int'` (x5), `type name declared as function returning an array`
  (x3), `expected expression before '{'` (x2).
* **Cause**: `var ops: array[types.Callback, 3]` — `Callback` is an imported
  type alias for `proc(int) -> int` — declares as
  `int32_t (*ops[3])(int32_t)` while the assigned values are the proc struct
  `mt_proc_int_int`.  A *qualified* alias reference does not resolve to the
  shared proc struct, so `c_declaration`'s array-of-function-pointer branch
  takes it.  The unqualified alias case is already handled in
  `resolve_type_ref` (~line 4238: "A `type Gen = proc(...) -> T` alias resolves
  to its closure struct"); the qualified/imported path is not.
* **Verify**: the local declares as `mt_proc_int_int ops[3]`, the errors vanish,
  and the fixed point holds.

### 2. Calls through a proc-typed member lower to a plain function call

* **Symptom**: 3 errors: `implicit declaration of function
  'engine_systems_PipelineStep_handler'` (systems.mt), `'engine_closures_mt_cb'`
  (closures.mt), and — from the same call site in `run_pipeline` — `incompatible
  types when assigning to type 'engine_types_Outcome_int_engine_types_EngineError'
  from type 'int'` (the call's result comes back as `int`).
* **Cause**: `step.handler(input)` and `s.cb()` (proc-typed struct field /
  variant-arm field) lower to `engine_systems_PipelineStep_handler(step,
  input)` — a module-qualified *associated function* call.  The host emits
  `step.handler.invoke(step.handler.env, input)` (with the retain/release pair
  around it).  Fixing the call shape should also fix the result type, since the
  invoke slot's signature carries the real return type.
* **Verify**: the call goes through `.invoke`/`.env`; all three errors disappear;
  the fixed point holds.

### 3. Result type of a call through a proc value is `void`

* **Symptom**: 2 errors: `variable or field '_s' declared void` /
  `'_a' declared void` in `main_closure_stress`.
* **Cause**: `let _s = scaler(10.0)` where `scaler` is a `proc(double) ->
  double` local emits `void _s = scaler.invoke(scaler.env, 10.0);`.  The call
  itself is right; the *declared type* came out `void` instead of the proc's
  return type.
* **Verify**: `double _s = ...`; the errors vanish; the fixed point holds.

### 4. `math.mt`: operators on structs and format-string arguments

* **Symptom**: 3 errors — `conversion to non-scalar type requested` at
  `let reversed = 3.0 * v3` (an `extending`-block operator on a struct) and
  `aggregate value used where an integer was expected` (x2) in
  `format_strings_demo`.
* **Verify**: the errors vanish; the fixed point holds.

### 5. `await` / `wait` typing

* **Symptom**: 4 errors — `incompatible type for argument 1 of
  'std_async_wait__int'` (x3, main.mt) and `incompatible types when returning
  type 'mt_task_int' but 'int32_t' was expected` (async_tasks.mt).
* **Cause**: task values are typed `mt_task_*` on one side of the call and the
  awaited/bare type on the other.
* **Verify**: the errors vanish; the fixed point holds, and the async output
  still matches the host.

### 6. End-to-end verification and gates

* `build/stage2/mtc build projects/stress` succeeds; run the binary and compare
  stdout + exit status against the Ruby host's build (expected: exit 242, empty
  stdout).
* Then: `tools/bootstrap.sh` (fixed point), the self-test suite
  (`build/stage2/mtc test test/mt -I .`) and `rake "cli:parity"`.

## Already fixed on this path (do not re-investigate)

| Commit | Fix |
| --- | --- |
| `ade972cc` | guard-value projection (single storage local), match temp naming, absent-else shape |
| `a543165e` | `defer` inside `unsafe:` / nested blocks replayed after the block closed |
| `f3651dbd` | qualified destructuring (`let types.Transform(x, y, rot) = t`); `packed`/`align`/`deprecated`/`test`/`expect_fatal` builtin attributes |
| `47684ed8` | type-parameter method fallback (`entity_killed.emit(entity.id_value())`) |
| `18886806` | `dyn[alias.Interface]` lookup resolved through the import alias (`dyn lowering: interface not found`) |
| `ea010947` | dyn interface names sanitized for C (dotted alias leaked into symbols) |
| this commit | proc-typed type aliases: `proc_struct_decl` factors the field shape out of `proc_ensure_struct_decl` so the program-level alias pass can declare the `mt_proc_*` struct an alias-only proc typedef points at |
| this commit | dyn symbols canonicalized on the declared interface name (`c_naming.dyn_iface_declared_name`), so `ifaces.Identifiable` and `Identifiable` emit one `mt_dyn_*` / `mt_vtable_*`; the dead `InterfaceAnalysis.module_name` / `iface_module_name` threading removed |
| this commit | user-defined generic variants: `ensure_generic_variant_decl` collects concrete instances into `Program.monomorphized_variants`, registers their arm payload fields, and `match` routes to the kind-switch path; arm constructors accept a module-qualified receiver and no-payload arms resolve (the prelude `Option`/`Result` `_phantom` pipeline is excluded — registering those generically breaks the bootstrap) |
| this commit | async proc captures: the synthetic `*__setup_env` parameter is a real C identifier (was `int32_t __mt_frame->local_offset`) and its body reads that parameter |
| this commit | proc bodies no longer inherit the enclosing async function's CPS return state (`__mt_frame->result` stores / `goto <caller>_resume_complete`) |
| this commit | qualified struct destructuring resolves field names/types in the value's declaring module (emitted `void x = <temp>.;` before) |
| this commit | dyn wrapper casts use the concrete type's own module (`(main_Enemy*)` → `(engine_types_Enemy*)`) |

Regression tests are still owed for the `defer`-scope and dyn-alias fixes (both
produced crashes rather than diagnostics) and for qualified destructuring, the
type-parameter fallback, and the changes above. Test location: `test/mt/`.

# Self-Host Plan: Path to 100% Ruby Parity

Status: **SELF-HOSTING FIXED POINT ACHIEVED.** The self-host compiles itself to a
byte-identical fixed point (stage2 == stage3) and 172/172 self-tests pass under
the self-built compiler. **10/13 examples match Ruby** (incl. `language_baseline`,
now correct through real await-driven CPS); `integration_test` also builds & runs
clean under the self-host (Ruby's own build warns-as-errors there). Format strings
are **done**. Async CPS core is **done** (direct awaits, nested async, Result
returns, awaits in loops); the two remaining async examples (`async_stress_test`,
`async_network_lobby`) need embedded-await hoisting, async-method Task typing, and
the async-`main` entrypoint (§2). The self-host itself uses no async, so this work
carries **zero fixed-point risk**.

Verified this round (Ruby stage-1 → self-host stage-2 → stage-3):
`diff stage2.c stage3.c` identical · 172/172 tests · example table below.
Last updated: 2026-07-13

---

## 0. Current State

### 0.1 Self-hosting bootstrap (the headline result)

```sh
# Stage 1: Ruby builds the self-host
ruby -Ilib bin/mtc build projects/mtc -I . --no-cache --no-debug-guards -o tmp/mtc-current

# Stage 2: the self-host builds itself — 0 C errors
tmp/mtc-current build projects/mtc -I . --no-cache --no-debug-guards -o tmp/mtc-stage2 --keep-c tmp/stage2.c

# Stage 3: stage-2 builds itself again — byte-identical to stage 2
tmp/mtc-stage2 build projects/mtc -I . --no-cache --no-debug-guards -o tmp/mtc-stage3 --keep-c tmp/stage3.c
diff tmp/stage2.c tmp/stage3.c        # identical
cmp  tmp/mtc-stage2 tmp/mtc-stage3    # identical binaries

# Self-tests pass under the self-built compiler
tmp/mtc-stage2 test projects/mtc -I .  # 172/172
```

Before this round the stage-2 bootstrap produced **66 C errors** and could not
compile itself. The root cause was a cross-module same-name type collision (see
§1.1). That is fixed; the compiler is now genuinely self-hosting.

### 0.2 Example parity (self-host vs Ruby, runtime output)

| Example | Status |
|---------|--------|
| `data_structures` | MATCH |
| `event_stress_test` | MATCH |
| `memory_stress_test` | MATCH |
| `multithreading_test` | MATCH |
| `nested_struct_stress_test` | MATCH |
| `nullable_and_variant_test` | MATCH |
| `option_and_result_surface` | MATCH |
| `reflection_advanced` | MATCH (fixed this round — comptime type dispatch) |
| `integration_test` | self-host builds & runs clean (Ruby's own build warns-as-errors here) |
| `language_baseline` | MATCH (async `await` now lowered through real CPS — see §2) |
| `string_test` | MATCH (format strings now fully implemented — see §3) |
| `async_stress_test` | partial: core CPS works; blocked on async-method Task typing + embedded-await hoisting + async-`main` entrypoint (§2) |
| `async_network_lobby` | partial: same blockers as `async_stress_test` (§2) |

---

## 1. Fixes landed this round

### 1.1 Cross-module same-name type collision (the self-hosting blocker)

`lower_monomorphized_method` / `struct_defining_module_for_type` resolved a
generic receiver's owning module by scanning the program analyses for the
**first** module that declared a struct with the receiver's simple name. When
two modules declare the same simple name (`map.Entries` vs `fs.Entries`,
`ir.Program` vs `loader.Program`), the wrong module won, producing C that
referenced `std_fs_Entries_*` methods on a `std_map_Entries_*` value (and
`mtc_ir_Program_*` on a `loader.Program`). 44 + ~18 of the 66 stage-2 errors.

Fix: `GenericReceiver` now carries an authoritative `owner_module` sourced from
the receiver **type** itself (`ty_imported.module_name`, or the registered
generic-instance entry). Method lowering prefers it and only falls back to the
by-name scan when the module is genuinely unknown. Instance registration sites
(`qualify_type`, `try_monomorphize_generic`, `ensure_generic_struct_decl_named`)
now record the module they resolved the struct in.

### 1.2 Nullable function-pointer local declarations

`c_declaration` emitted `void (*)(int32_t) pred` for a `fn(...)?` local — invalid
C. Added a `ty_nullable` case that unwraps to `c_fn_ptr_declarator(base, name)`
so the name lands inside the pointer parens: `void (*pred)(int32_t)`.

### 1.3 Global variable initializers were dropped

Module-level `var x = <initializer>` always zero-initialized in both lowering and
the C backend, so a `var p: proc(...) = proc(...)` global got a null vtable and
segfaulted on call. Now the initializer is lowered (in an empty local scope so a
no-capture proc is not treated as capturing stale locals), `render_global` emits
the C static initializer, and reachability seeds from global initializers so the
proc's synthetic invoke/release/retain wrappers are emitted and forward-declared.

### 1.4 `str_buffer[N]` capacity lost

The `N` in `str_buffer[N]` was resolved with `resolve_type_ref` (not a
`ty_literal_int`), so method lowering read capacity 0 and every `assign`/`append`
aborted with "exceeds capacity". Now resolved via
`types.literal_int(resolve_array_length(...))` like `array[T, N]`.

### 1.5 Compile-time comparison operators produced `cv_int`, not `cv_bool`

`const_binary_op` wrapped integer comparison results (`==`, `<`, …) as `cv_int`.
`inline if`/`when` only accept a `cv_bool` discriminant, so `inline if SELECTOR == 2`
silently dropped both branches. Comparisons now yield `cv_bool`.

### 1.6 Compile-time reflection / type dispatch (reflection_advanced)

Several related gaps, all now fixed:
- `inline if` ignored `else if` conditions (treated the 2nd branch as an
  unconditional `else`). Rewritten to evaluate every branch condition in order.
- `try_evaluate_const_expr` could not evaluate `field.type == T` or `T == int`.
  It now yields a `cv_type` for `field.type` (via `ctx.inline_for_element`), for
  bare type-name identifiers, and for in-scope generic type parameters (via
  `ctx.type_substitution`); the existing `cv_type == cv_type` path compares them.
- `fields_of(T)` / `members_of(T)` used the literal name `"T"`. They now resolve
  a type parameter through `ctx.type_substitution`, and search **all** program
  analyses so a reflective generic defined in one module (`std.fmt.format_value`)
  can reflect over a struct defined in another.
- The `inline for` binding local was emitted as `Vec3 field = 0` (invalid struct
  init) and `field.name` was not substituted. Fixed (zero-init + `.name` string
  substitution).
- Nested const-function calls (`cube` → `square(x)`) evaluated their arguments in
  a standalone scope, so `x` resolved to 0. Arguments now evaluate in the
  caller's variable scope.

---

## 2. `await`-driven async (CPS)

### 2.0 Status — core implemented

The continuation-passing async lowering is **implemented and verified** for the
common cases. `lower_async_fn` now emits, for every async function, a frame
struct, a goto-based resume state machine, the vtable, and a constructor; the
degenerate `lower_function(is_async=true)` path is gone.

Working and verified end-to-end (against real libuv timers):
- direct awaits — `let v = await f()`, `let _ = await aio.sleep(n)`;
- **nested** async awaiting async awaiting a timer (multi-level suspend + wake
  propagation);
- `Result`/`Option`-returning async functions;
- awaits **inside loops** (`while`/`for` bodies) — the resume `goto` re-enters
  the C loop mid-iteration;
- `return expr` (stores `frame->result`, gotos the completion label);
- `language_baseline` matches Ruby; 172/172 self-tests; stage2 == stage3.

Key implementation points (in `projects/mtc/src/mtc/lowering/lowering.mt`):
- **Spilling**: params → frame `param_<name>`, locals → `local_<name>`, awaited
  tasks → `await_<N>`. A spilled binding's C name is literally
  `"__mt_frame->field"`, so the existing `lower_expr`/`lower_stmt` machinery reads
  and writes through the frame automatically. `let`/`var` in CPS mode lower to
  frame-field assignments (`lower_async_local`).
- **Await**: `async_emit_await` stores the task in `frame->await_N`, guards on
  `ready`, and on suspend sets `state`, calls
  `await_N.set_waiter(await_N.frame, __mt_frame_raw, resume)`, and `return`s;
  the resume label takes the result into the target and `release`s the child.
- **Frame is `calloc`'d** (control fields + unassigned locals start zeroed).
- **`async_waiter_wake`** saves the waiter fn pointer to a temp before nulling
  the field, then calls the temp (nulling-then-calling was a null-call crash).
- CPS state is reset per function; nested proc bodies disable CPS mode.

### 2.1 Remaining blockers — reviewed root causes + accurate solutions

Verified by reproducing each against the current compiler. All three trace to a
small number of precise gaps; `std.net` (the async dependency of both examples)
is method-heavy, so **Blocker 1 was the largest contributor**.

#### Blocker 1 — async methods CPS-lowered — **DONE**

**Status: implemented and verified.** An async method with a `this` receiver
awaiting a real libuv timer now lowers to a correct CPS frame and runs
end-to-end. `async_network_lobby` dropped from ~30 → the remaining errors are all
Blocker 2 (embedded awaits); `async_stress_test` similarly.

**Two root causes were involved (both verified and fixed):**

1. **Definition side:** `lower_extending_block` skipped async methods
   (`if m.is_async … continue`), so they fell to `lower_method` as plain
   synchronous functions. Fixed: async non-generic methods now route to a
   generalized `lower_async_fn` that takes an optional receiver type; `this`
   becomes implicit frame field `param_this` (editable→`ptr[T]`, plain→value),
   constructor linkage = `method_link_name`.

2. **Call side (the subtle one):** `await w.run()` did **not** reach
   `resolve_method_info`. It was intercepted earlier by `try_generic_method_call`
   → `lower_monomorphized_method`, which reads the return type from a *plain,
   non-CPS* monomorphized lowering of the method body → returned the unwrapped
   `int` instead of `Task[int]`. Fixed: `try_generic_method_call` returns `none`
   for `gm.method.is_async`, so the call falls through to `resolve_method_info`,
   which returns the `Task[T]` type (from the analyzer's `is_async`-aware
   `FnSig`) and the eagerly-lowered CPS constructor's C name.

**Supporting analyzer change:** `FnSig` gained `is_async: bool`;
`collect_extending_methods` passes `m.is_async` to `build_fn_sig` (was hardcoded
`false`), so `build_fn_sig` wraps async method returns in `Task[T]`. All
`FnSig(...)` construction sites updated.

**Field-collection isolation:** `LowerCtx` gained `async_await_fields_ptr` /
`async_local_fields_ptr`; `lower_async_fn`'s has-await branch collects into
function-local vecs pointed to by these, immune to a nested `lower_async_fn`
reassigning the ctx vecs. (A harmless dead `await_N` field can still appear in a
caller frame when a method is eagerly lowered before the caller; it is not
referenced by the resume body. Cosmetic; can be tightened later.)

#### Blocker 1 (original) — historical root-cause note

**Root cause (verified).** `lower_module`'s extending-block pass skips async
methods: `lowering.mt:1230` `if m.is_async or m.type_params.len > 0: continue`.
They then fall to `lower_method`, which emits a **plain synchronous** function
(e.g. `static int32_t Worker_run(Worker this)`) — no frame/resume/vtable, return
type `int` not `Task[int]`. So `await w.run()` hands `async_emit_await` an `int`,
producing `int.ready/.frame/...` errors and `void`-typed spilled locals
(`extract_task_element_type(int)` → void → `void target;`).

**Accurate solution.**
1. **`FnSig` gains `is_async: bool`** (`semantic/analyzer.mt:42`). Populate it
   where method and function sigs are recorded (from the AST `is_async`). This is
   the only cross-file (analyzer) change; every `FnSig(...)` constructor site must
   pass the flag (there are a few, incl. the synthesized async-wait sig at
   `lowering.mt:~5749` → `false`).
2. **Lower async methods as CPS.** At `lowering.mt:1225-1236`, stop skipping
   `m.is_async` (keep skipping only `type_params > 0`). Route them to a new
   `lower_async_method` that reuses `lower_async_fn`'s machinery with `this`
   prepended as implicit param #0: generalize `lower_async_fn` to take a
   `receiver: Option[(name,ty)]` (or build `params = [this] + m.method_params`
   and share a core). Constructor linkage must be `method_link_name(module,
   type, m.name, is_static)` so call sites resolve it. Frame carries
   `param_this` + method params + locals + awaits (spilling already handles the
   rest).
3. **Wrap async-method call return types in `Task[T]`.** In
   `resolve_method_return_from_import` (`lowering.mt:5363`) and the two
   value-method-call return sites (`lowering.mt:~6964, ~7007`), when the resolved
   `sig.is_async`, return `make_task_type(ret)`. This makes `await w.run()` see
   `Task[int]`, and the existing CPS await handling takes over.
4. **Generic async methods** (`type_params > 0`) remain deferred — they need the
   monomorphization path to emit the CPS form. Rare; none in the two examples.

#### Blocker 2 — embedded-await hoisting — **DONE (core)**

**Status: implemented and verified.** Awaits nested in expressions and
conditions now hoist correctly and match Ruby. Verified end-to-end:
`(await m())?` → correct, `total += await f()`, `(await f()) * 2`,
`if (await f()) > 5`, `while (await f()) > 0`, and `let v = maybe else: … ; await …`
(guard spill). `async_stress_test` dropped 159 → 108 C errors.

**Implemented (all guarded by `ctx.async_cps_active`; the self-host uses no async
so the bootstrap fixed point is unaffected):**
- `async_hoist_awaits` (a recursive AST rewrite, `alloc_ast_expr` on the heap):
  emits each embedded await as a suspend/resume boundary into a fresh
  `local_await_tmp_N` frame field and replaces it with an identifier. Handles
  binary/unary/call/member/index/prefix_cast/unsafe. A top-level `?` is preserved
  so the caller routes it to `lower_propagate_let`.
- `lower_async_local`: hoists embedded awaits, routes a top-level `?` to
  `lower_propagate_let`, and wraps non-null inits for value-nullable locals.
- `lower_propagate_let` is CPS-aware: on `?` failure it stores the propagated
  value to `frame->result` and jumps to the completion label (not a value-return
  in the void resume); the success binding spills to a frame field.
- `lower_guard_local` (`let x = expr else:`): spills the bound local to a frame
  field in CPS mode.
- `stmt_assignment`: compound ops (`+=`) and embedded awaits hoist first, then
  emit the await-free assignment with the original operator.
- `stmt_while`: an await in the loop condition restructures to
  `while(true){ <cond awaits>; if(!cond) break; body }`.
- `stmt_if`: a single-branch `if (await X) …` hoists the condition beforehand.
- `return`: embedded awaits in the return value hoist first.

**Remaining async-example errors** (async_network_lobby ~30, async_stress_test ~86
C errors, down from ~34/108 after the nested-generic arm-payload fix):

Three distinct root causes, **all pre-existing and not async-CPS specific**:

1. **Nested-generic prelude arm-payload field types (FIXED).** `rp.value` where
   `rp` is a `Result.success` / `Option.some` arm binding whose payload is itself
   a generic (e.g. `Result[Option[Msg], int]`) mis-resolved to the arm struct type,
   cascading to `_phantom` / `declared void`. Fixed: `arm_payload_field_type` now
   falls back to the shared `prelude_arm_field_types` registry (populated by
   `ensure_generic_variant` with the concrete, possibly nested-generic type).
   Verified in both sync and async functions. (Commit `9b82552b`.)

2. **`std.net` member-access type resolution (pre-existing).** `declared void`
   and `int`-from-pointer errors in `udp_send_impl` and related `std.net`
   functions. The guard form `let x = read(state).inner.storage else:` resolves
   `.storage` on a struct field that itself holds a type-aliased pointer to an
   imported opaque type. Isolated reproductions work; the failure is specific to
   `std.net`'s exact guard + multi-nested read chain + platform-c-binding struct
   pattern. ~10 remaining errors in `async_network_lobby`, ~50 in
   `async_stress_test`.

3. **CPS spilling for `match`-statement bindings + `for`-loop bindings.** A
   `match` arm's `as name` or `for i in col` binding inside an async body
   produces a C local that does not survive suspend/resume. Fixes: intercept
   `match` and `for` in `lower_stmt` when `async_cps_active`, register the
   bindings as frame-spilled locals. ~5 remaining errors.

4. **Undefined completion labels** in CPS functions. The `_resume_complete`
   label gets used but not defined in some edge cases. ~3 errors.

5. **Async `main` entrypoint** (Blocker 3 — stub). `async function main` emits
   no C `main` → link error. Requires proc synthesis + `std.async.wait`
   specialization.

#### Blocker 2 (original design) — embedded-await hoisting

**Root cause (verified).** Awaits nested in expressions/conditions fall to
`lower_expr(expr_await)` → `unwrap_task_value` (synchronous; correct only for a
task that is *already* ready). Patterns: `(await f())?`, `while (await f()) > 0`,
`let w = if c: await g() else: 0`, `total += await g()`.

**Accurate solution — an AST pre-pass** run in `lower_async_fn`'s has-await branch
*before* `lower_function_body`, rewriting the body so **every await is the direct
value of a `stmt_local`/`stmt_assignment`/`stmt_expression`/`stmt_ret`** (which
the existing CPS handling already lowers). AST nodes are constructed with
`heap_mod.must_alloc[ast.Expr|Stmt](1)` (shapes: `expr_await(expression)`,
`expr_if(condition,then_expr,else_expr)`, `stmt_local(is_let,name,stmt_type,value,…)`,
`stmt_while(condition,body,…)`, `stmt_if(branches,else_body,…)`,
`stmt_ret(value,…)`).

- `hoist_expr(ep, out) -> ptr[ast.Expr]`: recurse over `expr_binary_op`,
  `expr_unary_op` (incl. `?`), `expr_call` (callee+args), `expr_member_access`,
  `expr_index_access`, `expr_prefix_cast`; for `expr_await`, first hoist the
  inner, then append `let __await_k = await <inner'>` to `out` and return
  `expr_identifier(__await_k)`. Non-await leaves return unchanged.
- Statement rewrite: for each `stmt_local`/`assignment`/`expression`/`ret` whose
  value has an embedded (non-direct) await, run `hoist_expr` on the value,
  splice the produced `out` statements before it, keep a trailing direct-await
  or await-free statement.
- **Conditional awaits** can't hoist unconditionally:
  - `while <c has await>: body` → `while true: <hoist c into stmts>; if not c': break; body`.
  - `for` with an awaiting iterable → hoist the iterable expr before the loop.
  - `let w = if c: await X else: Y` (await in an `if`-**expression**) → rewrite to
    `var w; if c: w = await X else: w = Y` (statement `if`; each branch's
    `w = await …` is then a direct-await assignment).
- Recurse into `if`/`while`/`for`/`match`/`block`/`unsafe` bodies.
- Hoist temps are ordinary `let`s → they become spilled `local_<k>` frame fields
  automatically.

#### Blocker 3 — async `main` entrypoint

**Root cause (verified).** `build_async_main_entrypoint` (`lowering.mt`, added last
round) is a stub returning `none`, so an `async function main` emits no C `main`
→ link error `undefined reference to 'main'`.
already CPS-lowered (constructor linkage `<module>_main` returning `Task[int]`);
the C entrypoint is a separate function with linkage `"main"`:
1. Build the zero-capture root proc wrapping the constructor:
   `lower_fn_to_proc(ctx, "<module>_main", fn(() -> Task[int]))` → proc IR value;
   bind to `__mt_async_main_root`.
2. Trigger the `std.async.wait[int]` specialization and get its C name via a new
   helper that replicates the cross-module generic path
   (`lowering.mt:~5731`): find `wait` in `std.async`'s analysis, build
   substitution `{T: int}`, compute `spec_key`, call
   `lower_and_cache_specialization_with_sub`, return `spec_key`
   (= `std_async_wait__int`). For a `void` main, use `run` instead.
3. Emit `let __mt_result = <wait_c>(__mt_async_main_root);
   __mt_async_main_root.release(__mt_async_main_root.env); return __mt_result;`
   (int main); for void main call `run` then `return 0`.
4. `main(argc, argv)` (a `span[str]` param) reuses the existing argv→`span[str]`
   bridge from `build_root_main_entrypoint`.
Return the `ir.Function(linkage_name = "main", entry_point = true)`; the dispatch
already calls `build_async_main_entrypoint` for a root async `main`.

**Recommended order:** Blocker 1 (unblocks most `std.net`), then 2 (embedded
awaits), then 3 (linking). 1+2 make the resume bodies correct; 3 makes the
programs link and run. Each is independently testable and, per §2.2, cannot
affect the bootstrap fixed point.

### 2.2 De-risking fact

**The self-host compiler uses no `async`/`await` in its own source** (verified),
so all async CPS work — done and remaining — **cannot affect the bootstrap fixed
point**; it only changes the async example programs.

### 2.3 Historical: original symptom / root cause

The following recorded the pre-implementation state.

`language_baseline` crashed (SIGSEGV) at `aio.wait(async_demo())`; the async
example programs failed to link (`undefined reference to main`).

### 2.2 Runtime contract the CPS must satisfy (from `std.async`)

The generated frames plug into the existing `std.async` libuv runtime, so the
CPS output must match its ABI exactly:

- **`Task[T]` vtable** (the aggregate the constructor returns): `frame: ptr[void]`,
  `ready: fn(ptr[void]) -> bool`, `set_waiter: fn(ptr[void], ptr[void], fn(ptr[void]) -> void) -> void`,
  `release: fn(ptr[void]) -> void`, `take_result: fn(ptr[void]) -> T` (absent for
  `void`), `cancel: fn(ptr[void]) -> void`. (Self-host constructor also stores a
  leading `value` field; harmless as long as designated initializers are used.)
- **Wake protocol** (`sleep_set_waiter` in `std/async/libuv_runtime.mt`):
  `set_waiter(child_frame, waiter_frame, waiter_fn)` stores `waiter_frame` +
  `waiter_fn`; **if the child is already ready it calls `waiter_fn(waiter_frame)`
  immediately**. When the underlying event (timer/UDP/work) completes, the
  callback calls `state.waiter(state.waiter_frame)`.
- **The waiter is the parent's resume function.** Its C signature is exactly
  `void resume(void* frame)` — which is what `lower_async_fn` already emits. So a
  suspending await must call
  `child.set_waiter(child.frame, __mt_frame_raw, <this fn's resume>)` and pass its
  **own** `__mt_frame_raw` as `waiter_frame`.
- **Driver** (`wait_on[T]`): `while (!task.ready(task.frame)) runtime_poll(rt);
  result = task.take_result(task.frame); task.release(task.frame);`. Each poll
  runs one libuv loop turn, firing callbacks that re-enter parent resumes. This
  is why null vtable pointers crash and why `set_waiter` is mandatory.

### 2.3 Root-cause audit (dispatch + 5 CPS gaps + main)

Dispatch in `lower_module` (lowering.mt ~813):
```
if fun.is_async:
    if async_mod.body_has_await(fun.body):
        functions.push(lower_function(..., is_async=true))   # ← degenerate path
    else:
        lower_async_fn(...)                                   # ← correct CPS (no-await)
else if lowerable_function(...):
    functions.push(lower_function(...))
    if is_root and name == "main": build_root_main_entrypoint(...)  # sync main only
```
The has-await path (`lower_function(..., is_async=true)`) evaluates each `await`
**synchronously** as `expr.value` and returns `{ .value=…, .ready=0, … }` (null
vtable). `lower_async_fn` *does* have a `has_await` branch (`lower_async_cps_body`
/ `lower_async_await_stmt`, lowering.mt ~14010) but it is **never reached** and is
a skeleton with five correctness gaps:

1. **`await_N` frame fields never declared.** `lower_async_await` writes
   `frame->await_N = task` and reads `.ready`/`.take_result` off it, but the frame
   struct only has ready/cancelled/waiter/waiter_frame/state/result/params — no
   `await_N` fields (which must be typed as the awaited `Task[T_N]`, not `ptr[void]`).
2. **`set_waiter` never called on suspend.** The suspend body only sets `state`
   and `return`s (an explicit "stub" comment). Without registering the waiter the
   event loop can never resume the parent — fatal for real timer/network I/O.
3. **Await result discarded + child never released.** The resume side calls
   `take_result` as a bare expression statement; `let v = await …` never receives
   the value, and `release(child)` is never emitted.
4. **Only top-of-`stmt_local`/`stmt_expression` awaits handled.** Awaits inside
   `if`/`while`/`for`/`match`/`return`, and awaits nested in larger expressions,
   are not split into states (see the pattern matrix in §2.4).
5. **No local spilling.** C locals declared in one state do not survive the
   `return` + switch re-entry at a later state. Every local (plus loop
   var/iterable/index) live across an await must be a **frame field**, not a C
   local. The current skeleton also uses `switch`-cases-with-bodies, which cannot
   fall through between states — a **goto**-based dispatch is required.

Async `main`: `build_root_main_entrypoint` exists (lowering.mt 1350) and is wired
for the **synchronous** main branch only. For `async function main` the dispatch
enters the `is_async` branch and never emits a C `main`.

`lowering/async.mt` currently provides await detection (`body_has_await`,
`stmt_has_await`, `expr_has_await`), state counting (`count_async_states`), type
helpers, and a `build_async_frame` that is **partial/unused** (the real frame is
built inline in `lower_async_fn`). It is the natural home for the new analysis
pass + full frame builder.

### 2.4 Await-pattern matrix (from the async examples)

The CPS must correctly handle every shape below (all present in
`language_baseline` / `async_stress_test` / `async_network_lobby`):

| # | Pattern | Example | Requires |
|---|---------|---------|----------|
| 1 | `let _ = await aio.sleep(10z)` | bg_increment_* | discard result; timer suspend/resume |
| 2 | `let v = await leaf_value()` | middle_value | bind result → spilled frame field |
| 3 | `let _ = await t` (pre-bound task) | test_completed_check | reuse existing task storage |
| 4 | `let w = if v > 40: await f() else: 0` | async_demo | await inside if-**expression** |
| 5 | `while (await f()) > 0 and i < 2:` | async_demo | await in **while condition** |
| 6 | `let v = (await inner())?` | outer_prop_async | await + `?` propagation (early return) |
| 7 | `for … : … await …` | test_async_in_loop, test_basic_timer | await in loop **body** + loop-var spill |
| 8 | `defer: …` in async fn | async_demo, with_cleanup | defer cleanup at every completion/return path |
| 9 | `await` of a `Result`-returning async | may_fail_*, test_result_propagation | result type = `Result[T,E]`; match/`?` after |
| 10 | fire-and-forget / nested tasks | test_fire_forget, test_nested_await | independent child frames; release |

Patterns 4, 5, 6 need the **await-hoisting pre-pass** (§2.6-E); 7, 8 need the
**CF-aware lowering** with loop labels + defer cleanup (§2.6-D); 2, 3, 7 need
**spilling** (§2.6-C).

### 2.5 De-risking fact

**The self-host compiler uses no `async`/`await` in its own source** (verified:
zero `async function` declarations and no `await` expressions outside the
compiler's own handling code). Therefore async CPS work **cannot affect the
bootstrap fixed point** — it changes only the three async example programs. Unlike
the format-string work (which `parser/state.mt` forced to be all-or-nothing), the
async transform can land **incrementally**, verifying one example/pattern at a
time.

### 2.6 Complete solution design (mirrors Ruby)

Ruby's transform: `lib/milk_tea/core/lowering/async/analysis.rb` (245),
`.../async/lowering.rb` (1416), `.../async.rb` (714).

**(A) Analysis pass — `async_info`.** Walk the AST once
(`analyze_async_statements!`) to build:
- `param_fields`: each parameter → `param_<name>` (type; `pointer` for an
  editable `this`).
- `local_fields`: **every** `let`/`var`, each range loop's induction var + a
  synthesized `<name>_stop`, and each collection loop's binding + iterable + index
  → `local_<name>` (`type`/`storage_type`, `mutable`). Spilling all locals (not
  just await-crossing ones) is simplest and matches Ruby.
- `await_fields`: keyed by the await expression's identity → `{ field_name:
  await_<N>, task_type, result_type, state: N }`; state ids assigned in source
  order, recursing into nested bodies. #states = #awaits.

**(B) Frame struct.** ready, cancelled, waiter_frame, waiter, `state:int`,
`result:T` (unless void), one `param_<p>`, one `local_<l>`, and one
`await_<N>: Task[resultType_N]` per await (typed, not `ptr[void]`).

**(C) Spilling trick (key to tractability).** Bind each param/local's
`LocalBinding.c_name` to the literal string `"__mt_frame->" + field_name`; then
every `expr_name(v)` the existing `lower_expr` already produces renders as
`__mt_frame->local_v` — **no reference rewriting**. A `let`/`var` **declaration**
lowers to an *assignment* to the frame field (not `Type name = …`). This is
exactly Ruby's `async_frame_field_c_name`.

**(D) Resume = goto state machine.**
```
Frame* frame = (Frame*) raw;
switch (frame->state) { case 0: goto S0; case 1: goto S1; ... default: return; }
S0: ;
  <body, with await sites emitting suspend + `SN:` labels>
__mt_async_return:                 // completion
  <run frame-stored defers>; waiter-wake; frame->ready = true; return;
```
Each await:
```
frame->await_N = <task>;                                  // unless reusing storage
if (!frame->await_N.ready(frame->await_N.frame)) {
    frame->state = N;
    frame->await_N.set_waiter(frame->await_N.frame, raw, <resume>);
    return;
}
SN: ;
frame->local_x = frame->await_N.take_result(frame->await_N.frame);  // bind (or discard)
frame->await_N.release(frame->await_N.frame);
```
CF (`if`/`while`/`for`/`match`): a branch/body containing an await recurses into
the CF path (may emit suspend/`return`/labels); one without uses plain lowering.
`while`/`for` with an await in the **condition** restructure to
`while(true){ <cond setup incl. await>; if(!cond) break; <body> }`.
`break`/`continue` jump to synthesized loop break/continue labels **after running
pending defers**; thread `loop_flow{break_label,continue_label}` +
`active_defers`.

**(E) Await-in-expression hoisting.** Awaits nested in expressions/conditions
(matrix #4, #5, #6) must be pulled into a preceding await-statement that writes a
temp, then the surrounding expression references the temp. The `expr_stmt_expr`
node added for format strings **does not apply** (an await suspends and `return`s,
which cannot live inside a value expression). Implement a small pre-pass over the
async AST that rewrites each await-bearing expression into
`let __await_tmp_k = await <inner>` + the expression with `__await_tmp_k`
substituted, run **before** CF lowering so every await is the top of a
`stmt_local`/`stmt_expression`/`stmt_assignment`/`stmt_return`. `expr?` on an
awaited value expands to the await-temp followed by the normal `?` early-return.

**(F) Vtable + constructor** already exist and are correct; they only need the
`await_N` fields present and the real `set_waiter`-driven suspend body.
`cancel`/`release` should additionally cancel/release any in-flight `await_N`
child and run frame-stored defers (Ruby `build_async_cancel_function` /
`build_async_release_function`).

**(G) Async `main` entrypoint.** When `main` is `async` and root, emit synchronous
`int main(...)` that wraps the async-main **constructor** in a zero-capture root
`proc() -> Task[int]` and calls `std_async_wait__int` (int) / the void `run`
variant, then releases the root proc and returns the result. Adapt
`build_root_main_entrypoint`; reuse `lower_proc_expression` for the root proc.

### 2.7 Implementation plan (staged; each independently testable)

1. **Async `main` entrypoint** (§2.6-G) — unblocks *linking* of
   `async_stress_test` / `async_network_lobby`; small and self-contained. (Note:
   they will still crash until CPS lands, but this removes the link error and lets
   later stages be tested against them.)
2. **Dispatch**: route **all** async functions to `lower_async_fn`; delete the
   degenerate `lower_function(..., is_async=true)` path.
3. **Analysis pass** (§2.6-A) in `async.mt`; extend the frame builder (§2.6-B)
   with param/local/await fields; make `lower_async_fn` consume it.
4. **Spilling** (§2.6-C): bind param/local c-names to `__mt_frame->field`; lower
   `let`/`var` to frame assignments.
5. **Real await suspend/resume** (§2.6-D core): `await_N` store, `ready` guard,
   `set_waiter`, goto `SN`, `take_result` bind, `release`. Validate against
   `language_baseline` matrix #1–#2 first.
6. **Await-hoisting pre-pass** (§2.6-E) for matrix #4/#5/#6.
7. **CF-aware lowering** (§2.6-D CF) — if/while/for/match, loop labels, defer
   cleanup (matrix #7/#8).
8. **`cancel`/`release` completeness** (§2.6-F) — nested-task cleanup + defers.

**Validation targets:** `language_baseline` runs to `0` and matches Ruby;
`async_stress_test` and `async_network_lobby` build and run (timers, UDP, nested
awaits, loops with awaits, `Result` propagation). Fixed point unaffected by
construction (§2.5).

**Files:** `projects/mtc/src/mtc/lowering/lowering.mt` (`lower_module` dispatch
~813, `lower_async_fn` ~13788, `lower_async_cps_body`/`lower_async_await*`
~14010, `build_root_main_entrypoint` ~1350) and
`projects/mtc/src/mtc/lowering/async.mt` (analysis + frame builder).

---

## 3. Remaining: format strings (`f"..."`)


**DONE.** Format strings are fully implemented and verified byte-identical to
the Ruby compiler for text interpolation, `:x`/`:X` hex, `:o`/`:O` octal,
`:b`/`:B` binary, `:.N` float precision, and static strings. `string_test` now
matches Ruby, and the self-host's own dynamic f-strings (in `parser/state.mt`)
compile through the same path — the bootstrap fixed point still holds. The
subsections below record the original problem and the implemented design.

### 3.1 Original symptom

`string_test`'s `test_format_string_compiler_support` fails: `f"hello"` compiles
to the string literal `f"hello"` (raw lexeme, including the `f` and quotes)
instead of `hello`.

### 3.2 Root cause

The lexer emits a single `fstring` token spanning the raw `f"…"` text. The
parser's `fstring` case produces `expr_string_literal(value = <raw lexeme>)` and
**never** builds `expr_format_string` / `FormatStringPart`s. In Ruby the lexer
pre-splits the literal into parts and the parser re-parses each interpolation.

The lowering side is already complete: `lower_format_string_local` handles both
all-static and interpolated parts given a `span[FormatStringPart]` — it is
currently dead code because the parser never produces that node.

### 3.3 Correct fix

1. Split the `f"…"` lexeme into `fmt_text` / `fmt_expr(+format_spec)` parts —
   either in the lexer (mirroring Ruby) or in the parser's `fstring` case — and
   re-parse each `#{expr}` through the expression grammar; produce
   `expr_format_string`.
2. Route `let x = f"…"` to the existing `lower_format_string_local` (works for
   static and interpolated).
3. `lower_expr`'s `expr_format_string` case must handle the general expression
   position. All-static parts collapse to a combined string literal (no hoist
   needed). **Interpolated** f-strings in a non-`let` expression position
   (e.g. `buffer.assign_format(f"count=#{42}")`) require statement hoisting,
   which `lower_expr` does not currently support — that hoisting mechanism is the
   real work here.

Files: `projects/mtc/src/mtc/lexer/lexer.mt` (`scan_format_string`),
`projects/mtc/src/mtc/parser/parser.mt` (`fstring` case),
`projects/mtc/src/mtc/lowering/lowering.mt` (`expr_format_string` in `lower_expr`).

### 3.4 Complete solution design (researched)

Current state audited across all four stages:

- **Lexer** emits one `fstring` token spanning the raw `f"…"` text (start/end
  offsets only; the self-host `Token` has no structured-parts field, unlike
  Ruby's whose `literal` carries pre-split parts).
- **Parser** (`fstring` case) produces `expr_string_literal` with the *raw*
  lexeme and never builds `expr_format_string`. So `FormatStringPart`,
  `FormatSpec`, and `lower_format_string_local` are all effectively dead code.
- **Lowering** `lower_format_string_local` exists but is incomplete: no
  `format_spec` handling; `fmt_len_helper_name` always returns
  `mt_format_int_len`; `fmt_append_helper_name` maps `float`/`double`/unknown to
  `mt_format_append_int`. `lower_expr`'s `expr_format_string` is a `"fmt"` stub.
- **Runtime** (`emit_format_string_helpers`) provides only:
  `mt_format_str_make/_release`, `mt_format_check_capacity`,
  `mt_format_append_bytes/_str/_ptr_uint/_int`, `mt_format_int_len`,
  `mt_format_ptr_uint_len`, and the hex/oct/bin *length* helpers. Missing all of:
  `append_uint/_long/_ulong/_bool/_cstr/_float/_double/_double_precision`, every
  `append_*_hex/_oct/_bin(+_upper)`, and their matching `_len` helpers.

Constraint that forces full expression-position support: the self-host's own
`parser/state.mt` uses **dynamic** f-strings in `str_buffer` argument position
(`buf.assign_format(f"…#{}…")`). Once the parser emits `expr_format_string`,
those must lower correctly in expression position or the compiler cannot compile
itself. There is no safe static-only partial.

Chosen mechanism — **GCC/Clang statement-expression** — avoids Ruby's invasive
`prepare_expression_for_inline_lowering` hoist pass. The project already mandates
a GNU-C toolchain (packed/aligned attributes, emcc=Clang), so `({ stmts; val; })`
is a legitimate, portable codegen strategy, not a hack. A dynamic f-string in any
expression position lowers to a single statement-expression; no flush points need
retrofitting.

Five coordinated changes:

1. **Parser** (`parser.mt` `fstring` case → new `parse_format_string_expr`):
   strip `f"`/`"` (or normalize an `f<<-TAG` heredoc), walk the content
   splitting `text` / `#{expr}` parts with brace-depth tracking and string-skip
   (mirror the lexer's `scan_format_interpolation_end`), decode escapes in text
   parts, split each interpolation `source` / `format_spec` at the last
   top-level `:` followed by a valid spec suffix, **re-lex+parse** the source via
   a sub-`ParserState` (copying `known_type_names` / `known_import_aliases` /
   `current_type_param_names`), parse the spec into `FormatSpec`, and build
   `expr_format_string(parts)`.

2. **IR** (`ir.mt`): add `expr_stmt_expr(setup: span[Stmt], result: ptr[Expr], ty)`.

3. **C backend** (`c_backend.mt`): render `expr_stmt_expr` as
   `({ <setup>; <result>; })`; emit the full `mt_format_append_*` / `mt_format_*_len`
   runtime set.

4. **Lowering** (`lowering.mt`): factor the build into
   `build_format_string(ctx) -> (setup_stmts, result_expr)` with **complete**
   type dispatch (`str`,`cstr`,`bool`,`float`,`double`, all integer widths,
   integer-backed enums/flags) and **format-spec** dispatch (`precision`→double,
   `hex`/`oct`/`bin`(+upper)→signed/unsigned long) plus correct length
   pre-sizing. `lower_format_string_local` and `lower_expr` both call it;
   `lower_expr` collapses all-static to a plain string literal and otherwise
   wraps `(setup, result)` in `expr_stmt_expr`.

5. **Runtime**: emit the missing `mt_format_*` helpers so every append/len C name
   the dispatch can select is defined.

Status: parser + static-collapse implemented and verified (fixes `string_test`);
full dynamic type/spec dispatch + `expr_stmt_expr` + runtime completion is the
remaining work for interpolated f-strings.

### 3.5 Implemented

All five changes landed and verified:

1. **Parser** — `parse_format_string_expr` in `parser.mt` splits the `f"…"`
   lexeme into `expr_format_string` parts, decodes text escapes, splits each
   interpolation `source`/`format_spec`, and re-lexes+parses the source through a
   sub-`ParserState` that shares the parent's known-name context. `FormatSpec`'s
   AST field is now `ptr[FormatSpec]?` (null = no spec).
2. **IR** — `expr_stmt_expr(setup, result, ty)` added to `ir.mt`.
3. **C backend** — `render_stmt_expr` emits `({ setup…; result; })`;
   reachability (`reach_from_expr`), call detection (`expr_calls`), and
   string-literal collection (`collect_from_expr`) all recurse into it, and the
   full `mt_format_*` append/len runtime set is emitted.
4. **Lowering** — `build_format_string_dynamic` + `fmt_plan` provide complete
   type dispatch (`str`/`cstr`/`bool`/`float`/`double`/all integer widths, with
   an int fallback for int-backed enums) and format-spec dispatch. Each
   interpolation lowers once into a typed temp reused by the length and append
   passes. `lower_format_string_local` handles `let x = f"…"`; `lower_expr`
   collapses all-static to a literal and wraps dynamic ones in `expr_stmt_expr`.
5. **Runtime** — the complete `mt_format_append_*` / `mt_format_*_len` helper set.

Verification: a focused test exercising `#{expr}` text interpolation, `:x`/`:X`,
`:o`, `:b`, `:.2`, and static strings produced byte-identical output between the
Ruby-built and self-host-built binaries; `string_test` matches Ruby; 172/172
self-tests pass; stage2 == stage3 (the self-host's own dynamic f-strings compile
through this path).

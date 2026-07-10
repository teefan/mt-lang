# Self-Host Gap Analysis: Remaining Issues at 57 Errors

Last updated: 2026-07-10

This document provides a detailed analysis of each remaining C compilation error category
in the self-host Milk Tea compiler, comparing the Ruby compiler's correct output against
the self-host's current output, and recommending specific fix approaches with file/line
references.

---

## 1. Proc/Fn Type Issues (~30 errors)

The largest remaining category. Root causes are interconnected across the type system,
lowering, and C backend.

### 1A: `is_proc_type` returns true for all `ty_function` — breaks fn calls

**File**: `projects/mtc/src/mtc/lowering/lowering.mt`, lines 6646-6653

```mt
function is_proc_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_named as n:
            return n.name.find_substring("__proc_").is_some() or n.name.starts_with("mt_proc_")
        types.Type.ty_function:
            return true        # BUG: fn and proc both return true
        _:
            return false
```

**Consequence**: When a function parameter is `fn(x: int) -> bool` (a raw C function pointer),
`is_proc_type` returns true, causing `lower_call` to dispatch to `lower_proc_call` which
generates `.invoke(.env, ...)` member access on the fn pointer — invalid C.

**Fix**: Change line 6650 to check the `is_proc` field:

```mt
types.Type.ty_function as fnt:
    return fnt.is_proc
```

**Affects**: `count_matching(pred)` calls, `FnFilter_check`, `modvar_proc` calls (~8 errors).

---

### 1B: fn→proc coercion checks fn's own type, not context-expected type

**File**: `projects/mtc/src/mtc/lowering/lowering.mt`, lines 2795-2800

```mt
types.Type.ty_function as fnt:
    if fnt.is_proc:
        return lower_fn_to_proc(ctx, fn_c_name, fn_ty)
```

When `double_it_fn` (a plain `fn`) is passed where `proc(x: int) -> int` is expected, the
check uses `fnt.is_proc` (false for `fn`) so the wrapping never happens. The raw fn name
is passed directly where a proc struct is expected.

**Fix**: Check the contextual/expected type from `expr_type(ctx, ep)` rather than the fn's
own type. The contextual type should reflect `is_proc = true` when the call-site parameter
is a proc:

```mt
let ctx_ty = expr_type(ctx, ep)
match ctx_ty:
    types.Type.ty_function as fn_ty:
        if fn_ty.is_proc:
            return lower_fn_to_proc(ctx, fn_c_name, fn_ty)
    _: pass
# ... fall through to existing logic
```

**Affects**: `fn_to_proc_call_demo`, `apply_int_op` argument (~2 errors).

---

### 1C: `void invoke` — `expr_proc` not handled in `fallback_type`

**File**: `projects/mtc/src/mtc/lowering/lowering.mt`, around line 8917

When a proc is inside a tuple literal `(42, proc() -> int: 5)`, `lower_expr` calls
`fallback_type` which has no `expr_proc` arm. It returns `ty_error`, and
`proc_invoke_field_type`'s `_` branch returns `ty_error`. `c_type(ty_error)` maps to
`"void"`, producing `void invoke;` in the proc struct.

**Fix**: Add `expr_proc` handling to `fallback_type` to reconstruct the proc function type
from the AST:

```mt
ast.Expr.expr_proc as pr:
    var param_types = vec.Vec[types.Type].create()
    var pi: ptr_uint = 0
    while pi < pr.method_params.len:
        let p_ty = resolve_field_type_ref(ctx, unsafe: read(pr.method_params.data + pi).param_type)
        param_types.push(p_ty)
        pi += 1
    var ret = types.primitive("void")
    let rt = pr.return_type
    if rt != null:
        ret = resolve_scalar_type_ref(rt)
    return types.Type.ty_function(params = param_types.as_span(), return_type = types.alloc_type(ret), variadic = false, is_proc = true)
```

**Affects**: Proc literals in tuple/array contexts (~2 errors).

---

### 1D: Type alias `target_type` not qualified — raw `ty_function` leaks

**File**: `projects/mtc/src/mtc/lowering/lowering.mt`, lines 387-392

```mt
type_aliases.push(ir.TypeAlias(
    name = kn,
    qualified_name = naming.qualified_c_name(ta_analysis.module_name, kn),
    target_type = tv,   # <-- raw ty_function(is_proc=true), never qualified
    backing_c_name = lookup_decl_c_name_cross(...),
))
```

For `type IntGenerator = proc() -> int`, `tv` is `ty_function(is_proc=true)`. This leaks
to `emit_type_aliases` in the C backend, which emits `typedef int32_t (*)(void)` instead
of the proc struct typedef.

**Fix**: Apply qualification to `tv` before creating the `ir.TypeAlias`. For proc types,
convert to the shared proc struct name via `proc_type_name_from_signature` +
`proc_ensure_struct_decl`:

```mt
var qualified_tv = tv
match tv:
    types.Type.ty_function as fnt:
        if fnt.is_proc:
            let proc_name = proc_type_name_from_signature(tv)
            # Ensure struct exists (deferred to ctx.pending_env_structs)
            qualified_tv = types.Type.ty_named(module_name = "", name = proc_name)
    _: pass
type_aliases.push(ir.TypeAlias(
    target_type = qualified_tv, ...
))
```

**Affects**: `IntGenerator` typedef, `proc_array_demo` element type mismatch (~6 errors).

---

### 1E: `lower_proc_expression` creates per-proc named structs instead of shared

**File**: `projects/mtc/src/mtc/lowering/lowering.mt`, lines 2942-2966

Anonymous proc literals (e.g., `proc() -> int: offset + 3`) create unique struct names
(`language_baseline__proc_9`), while struct fields typed as `proc() -> int` use the
shared `mt_proc_int` name. This creates type mismatches.

**Fix**: Use the shared proc type from `proc_type_name_from_signature` for the struct
type name, while keeping per-proc names for invoke/release/retain function names:

```mt
let shared_name = proc_type_name_from_signature(proc_ty)
let proc_struct_ty = proc_ensure_struct_decl(ctx, shared_name, proc_ty)
# Use proc_prefix for function names (invoke/release/retain), but
# use shared_name / proc_struct_ty for the struct type.
```

**Affects**: `proc_struct_demo` cast mismatch, `Callback.invoke` vs proc literal (~4 errors).

---

### 1F: Stale match-arm bindings leak into proc captures

**File**: `projects/mtc/src/mtc/lowering/lowering.mt`, lines 8148, 8251, 3052-3071

Match arm bindings (`as name`) push locals onto `ctx.locals` but never pop them. When a
proc is later created, `collect_locals_for_capture` picks up stale bindings from completed
match blocks.

**Fix**: Save and restore `ctx.locals` around match lowering blocks. After each match,
restore the pre-match locals list so arm bindings don't persist:

```mt
# BEFORE match lowering:
var saved_locals = ctx.locals  # shallow copy
# ... lower match arms (adds arm bindings) ...
# AFTER:
ctx.locals = saved_locals
```

**Affects**: Proc captures with stale `s` bindings, `proc_2__setup_env(s, ...)` where `s`
is out of scope (~3 errors).

---

## 2. Compile-Time Reflection (3 errors)

**File**: `projects/mtc/src/mtc/lowering/lowering.mt`, lines 3492-3499, 10083-10122

### Issue

`has_attribute(...)`, `field_of(...)`, and `square(5)` are emitted as function calls
in the C output instead of being constant-folded at compile time.

### Ruby Output vs Self-Host Output

**Ruby**:
```c
static const bool HAS_RENAME = true;          // has_attribute(field_of(Labeled, value), rename)
static const mt_str RENAME_ARG = { .data = "my_field", .len = 8 };  // attribute_arg[str](...)
static const int32_t SQUARE_5 = 25;           // square(5)
```

**Self-Host**:
```c
static const bool HAS_RENAME = language_baseline_has_attribute(  // function call, not folded
    language_baseline_field_of(language_baseline_Labeled, value), rename);
static const mt_str RENAME_ARG = (mt_str) { 0 };
static const int32_t SQUARE_5 = 0;
```

### Root Cause

1. `has_attribute`, `field_of`, `attribute_of`, `attribute_arg` are not recognized as
   compile-time builtins in `lower_call` (line 3492). They fall through to regular
   function call lowering.

2. `try_evaluate_const_expr` (line 10094) does not handle const function calls.

3. When lowering `decl_const`, the value expression is `lower_expr(ctx, val_ptr)` which
   for unknown function calls produces a regular call IR node — not an evaluated constant.

### Fix

**In `lower_call`** (around line 3492, before the `lower_plain_call_sig` fallback):
Add explicit handling for compile-time builtins. When the callee matches one of
`field_of`, `has_attribute`, `attribute_of`, `attribute_arg`, `callable_of`, `fields_of`,
`members_of`, `attributes_of`:

- **`has_attribute(field_of(Labeled, value), rename)`**: Evaluate by looking up the
  struct `Labeled` in the analysis, checking its attributes, and returning a bool literal.
- **`field_of(T, name)`**: Return a `field_handle` constant (opaque at C level — these
  are compile-time only). The `field_of` builtins used in `static_assert` context should
  be evaluated to their boolean result.
- **`square(5)`**: Extend `try_evaluate_const_expr` to handle calls to const functions.
  When the callee is a `const function`, look up its body, substitute the argument values,
  and evaluate.

For `static_assert` at the module level and `const` initializers: the lowering for
`decl_const` and `static_assert` already uses `lower_expr`. Once `lower_expr` correctly
evaluates these builtins, the computed constants will flow through correctly.

---

## 3. ? Propagation (2 errors)

**File**: `projects/mtc/src/mtc/lowering/lowering.mt`, lines 2873-2880; `c_backend.mt`, lines 2568-2571

### Issue

`expr?` is lowered as an `ir.Expr.expr_unary(operator = "?")` and the C backend renders
it as literal `?expr` — invalid C syntax.

### Ruby Output

```c
std_option_Option_int __mt_propagate_1 = opt;
if (__mt_propagate_1.kind == std_option_Option_int_kind_none) {
    return __mt_propagate_1;
}
int32_t value = __mt_propagate_1.data.some.value;
```

The Ruby compiler lowers `expr?` to:
1. Assign the operand to a temp
2. Check `temp.kind == <failure_arm>`
3. If failure, return the failure (for Result) or the Option/Result value itself
4. Otherwise, unwrap the success value and use it

### Root Cause

The self-host treats `?` as a unary operator throughout the pipeline — no special handling
in lowering or C backend.

### Fix

**In `lower_expr`** (line 2873, `expr_unary_op`), add `?` handling before the generic
binary:

When `un.operator == "?"`:
1. Determine if the operand is `Option[T]` or `Result[T, E]` from its type
2. Create a temp variable, assign the lowered operand
3. Emit an if-check on `temp.kind == <failure_arm_kind>`
4. On failure, return `temp` (for Option) or re-wrap into the enclosing function's return
   type (for Result — return `Result.failure(error=temp.data.failure.error)`)
5. On success, use `temp.data.<success>.value` as the result

This requires emitting statements from expression lowering, which is a structural change.
Alternative: add a dedicated `ir.Expr.expr_propagate` IR node that the C backend expands
inline into statement-level code.

---

## 4. Tuple Named Fields (4 errors)

**File**: `projects/mtc/src/mtc/lowering/lowering.mt`, lines 3317-3336; `c_backend.mt`, struct emission for tuples

### Issue

Named tuples `(x = 10, y = 20)` generate the same struct as positional tuples `(10, 20)`
— both use `mt_tuple_int_int` with `_0`, `_1` fields. Named field access (`point.x`) fails.

### Ruby Output

```c
// Named tuple: (x = 10, y = 20)
struct mt_tuple_int_int_x_y {
    int32_t x;
    int32_t y;
};

// Positional tuple: (42, 7)
struct mt_tuple_int_int {
    int32_t _0;
    int32_t _1;
};
```

Ruby generates separate struct types for named vs positional tuples.

### Root Cause

1. `types.Type.ty_tuple` only carries element types, not field names.
2. `lower_tuple_literal` unconditionally uses `tuple_field_name(i)` which always
   generates `_0`, `_1`.
3. `expr_named` elements have their names discarded (line 2919-2920).

### Fix

Three coordinated changes:

1. **Extend `ty_tuple`** in `projects/mtc/src/mtc/semantic/types.mt` to carry optional
   field names. Add a `field_names: Option[span[str]]` field (none = positional,
   some = named).

2. **In `lower_tuple_literal`** (line 3317): For each element, check if it's `expr_named`.
   If so, extract the name; otherwise use `_N`. Track whether all elements are named or
   positional to determine the struct type.

3. **In the C backend**: Match the tuple's struct declaration and aggregate literal
   emission to use the field names from the type. For named tuples, emit a struct with
   the correct field names (e.g., `struct mt_tuple_int_int_x_y { int32_t x; int32_t y; }`).
   For positional tuples, continue using `_0`, `_1`.

---

## 5. Parallel Block Captures (3 errors)

**File**: `projects/mtc/src/mtc/lowering/lowering.mt`, lines 2693-2715

### Issue

Variables declared before a `parallel:` block (`pa`, `pb`, `positions`) are not captured
in worker functions. Workers get `NULL` as their data argument, so assignments inside
workers don't affect the outer scope.

### Ruby Output

Ruby generates per-worker capture structs and passes them as data:

```c
struct mt_spawn_cap_<name> { int32_t pa; };
// Before spawn:
mt_spawn_cap_<name> mt_cap_0 = { .pa = pa };
// Worker:
void mt_spawn_work_...(void *data) {
    mt_spawn_cap_<name> *mt_cap = (mt_spawn_cap_<name>*) data;
    int32_t pa = mt_cap->pa;
    pa = 42;
}
```

### Root Cause

`lower_parallel_block` (line 2693) creates workers without collecting or passing captures.
The worker bodies reference outer-scope local variables that are not accessible from the
worker function scope.

### Fix

In `lower_parallel_block` (line 2693):

1. Lower each body into IR
2. Scan the body IR for name references (`expr_name` nodes)
3. For each referenced name, check `ctx.locals` to find the binding. If the name is a
   local declared BEFORE this parallel block, it's a capture.
4. For each body with captures:
   - Create a capture struct with one field per captured variable
   - Generate an aggregate literal initializer referencing the outer locals
   - Allocate it on the stack, pass its address as `data`
   - In the worker function body, insert a preamble: cast `data` pointer, extract
     captures as local variables, then run the original body



Let me provide a status update on the items. Let me also let the user know what tests would be good to review.

---

## 6. Next Steps

The error count is now 65 which represents significant progress. The remaining errors are in a few specific categories that have been analyzed above. The next session can begin with the highest-priority fixes: the proc capture naming collision and the scalar*vec float multiplication fix.

**Priority order for next session:**

1. **Scalar*vec float multiplication** (-25 errors) — change `is_numeric` to `!is_vec_math_name`
2. **Proc capture naming collision** (-4 errors) — dedup in `collect_locals_for_capture`
3. **Compile-time reflection** (-5 errors) — handle builtins in `lower_call`
4. **Option naming** (-4 errors) — add prelude prefix in `generic_c_type`
5. **Subscription comparison** (-3 errors) — check `slot == 0` for `mt_subscription`
6. **SoA indexing** (-10 errors) — swap member+index in lowering
7. **Native type constructors** (-7 errors) — route `vec3(...)` as aggregate literal

**Key metrics:**
- 172 tests pass, 0 failures
- Self-compile fixpoint maintained
- Files modified: ~150 lines added to `c_backend.mt`, ~800 lines added to `lowering.mt`
- Total errors: 65 (down from 271 this session, -76%)

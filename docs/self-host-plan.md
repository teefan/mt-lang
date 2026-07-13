# Self-Host Plan: Path to 100% Ruby Parity

Status: **SELF-HOSTING FIXED POINT ACHIEVED.** The self-host compiler compiles
itself and reaches a byte-identical fixed point (stage2 == stage3). 172/172
self-tests pass under the self-built compiler. Format strings are done; one
feature subsystem remains for full *example* parity: `await`-driven async CPS
(§2, fully designed — the self-host uses no async so it carries no fixed-point risk).
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
| `language_baseline` | all features pass **except** `await` (see §2) |
| `string_test` | MATCH (format strings now fully implemented — see §3) |
| `async_stress_test` | needs async `main` entrypoint + CPS (see §2) |
| `async_network_lobby` | needs async `main` entrypoint + CPS (see §2) |

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

## 2. Remaining: `await`-driven async (CPS)

### 2.1 Symptom

`language_baseline` crashes (SIGSEGV) at `aio.wait(async_demo())`; the async
example programs fail to link (`undefined reference to main`).

### 2.2 Root cause (audited)

Dispatch in `lower_module` (lowering.mt ~813) splits async functions:

- **no `await`** → `lower_async_fn`: correct full output — frame struct, resume,
  vtable (ready/set_waiter/release/take_result/cancel), constructor.
- **has `await`** → `lower_function(..., is_async=true)`: evaluates each `await`
  **synchronously** as `expr.value` and returns a **degenerate task with null
  vtable pointers** (`{ .value = …, .ready = 0, … }`). `std.async.wait` then calls
  `task.ready(task.frame)` through a null pointer → crash.

`lower_async_fn` *does* contain a `has_await` branch (`lower_async_cps_body` /
`lower_async_await_stmt`), but it is only reached for no-await functions and is a
skeleton with five correctness gaps:

1. **`await_N` frame fields are never declared.** `lower_async_await` writes
   `frame->await_N = task`, but the frame struct only has
   ready/cancelled/waiter/waiter_frame/state/result/params. `await_N` fields (typed
   as the awaited `Task[T]`) are missing.
2. **`set_waiter` is never called on suspend.** The suspend body only sets
   `state` and `return`s. Without `await_task.set_waiter(await_task.frame,
   __mt_frame_raw, resume)` the event loop can never wake the parent — fatal for
   real timer/network I/O.
3. **The await result is discarded.** The resume side calls `take_result` as a
   bare expression statement; `let v = await …` never receives the value, and the
   awaited task is never `release`d.
4. **Only top-of-`stmt_local`/`stmt_expression` awaits are split.** Awaits inside
   `if`/`while`/`for`/`match`/`return` and inside larger expressions (e.g.
   `while (await f()) > 0`, `let w = if c: await g() else: 0`) are not handled.
5. **No local spilling.** C locals declared in one state do not survive the
   `return`+re-entry at a later state. Every local (and loop var/iterable/index)
   that is live across an await must live in the frame, not as a C local.

Additionally an **async `main`** gets no synchronous entrypoint wrapper, so no C
`main` symbol is emitted.

### 2.3 De-risking fact

**The self-host compiler uses no `async`/`await` anywhere in its own source**
(verified). Therefore async CPS work **cannot affect the bootstrap fixed point** —
it only changes the three async example programs. This removes the fixed-point
risk that constrained the format-string work.

### 2.4 Complete solution design (researched, mirrors Ruby)

Ruby's transform lives in `lib/milk_tea/core/lowering/async/analysis.rb` (245
lines), `.../async/lowering.rb` (1416), and `.../async.rb` (714). The complete
self-host solution has five parts.

**(A) Analysis pass — `async_info`.** Before lowering the body, walk the AST once
(`analyze_async_statements!`) to build:
- `param_fields`: each parameter → frame field `param_<name>` (type; `pointer`
  for an editable `this`).
- `local_fields`: **every** `let`/`var` name, plus each range loop's induction
  var + a synthesized `<name>_stop`, plus each collection loop's binding +
  iterable + index → frame field `local_<name>` (with `type`/`storage_type`,
  `mutable`). Spilling all locals (not just await-crossing ones) is simplest and
  matches Ruby.
- `await_fields`: keyed by the await expression's identity → `{ field_name:
  await_<N>, task_type, result_type, state: N }`, assigned a state id `N` in
  source order (recursing into nested bodies). State count = await count.

**(B) Frame struct.** ready, cancelled, waiter_frame, waiter, `state:int`,
`result:T` (unless void), one `param_<p>` per param, one `local_<l>` per spilled
local, one `await_<N>: Task[resultType_N]` per await.

**(C) Local/param spilling trick (the key to tractability).** Bind each
param/local's `LocalBinding.c_name` to the string `"__mt_frame->" + field_name`.
Then every `expr_name(v)` the existing `lower_expr` produces renders as
`__mt_frame->local_v` with no reference rewriting. A `let`/`var` **declaration**
lowers to an *assignment* to the frame field (not a C `Type name = …`). Ruby does
exactly this via `async_frame_field_c_name`.

**(D) Resume function = goto state machine.** Body:
```
frame = (Frame*) raw;
switch (frame->state) { case 0: goto S0; case 1: goto S1; ... }
return;
S0: ;
  <lowered body with await suspend/resume + labels S1..Sn>
<completion>: waiter-wake; frame->ready = true; (result already stored); return;
```
Each await lowers to:
```
frame->await_N = <task>;                    // unless reusing storage
if (!frame->await_N.ready(frame->await_N.frame)) {
    frame->state = N;
    frame->await_N.set_waiter(frame->await_N.frame, raw, resume);
    return;
}
SN: ;
frame->local_x = frame->await_N.take_result(frame->await_N.frame);  // bind result
frame->await_N.release(frame->await_N.frame);
```
Control flow (`if`/`while`/`for`/`match`) is lowered recursively: a branch/body
containing an await uses the CF path (which can emit suspend/`return`/labels);
one without an await uses a plain lowering. `while`/`for` with an await in the
**condition** restructure to `while(true){ <cond-setup incl. await>; if(!cond)
break; <body> }`. `break`/`continue` become jumps to synthesized loop
break/continue labels (with defer cleanup run first). This requires threading a
`loop_flow { break_label, continue_label }` and an `active_defers` list.

**(E) Await-in-expression hoisting.** An await nested in an expression
(`(await f()) > 0`, `if c: await g() else: 0`) must be pulled into a preceding
await-statement writing a temp local, then the surrounding expression references
the temp. Ruby uses `prepare_expression_for_inline_lowering` returning
`[setup, expr]`. The self-host has no such general pass; the `expr_stmt_expr`
node added for format strings does **not** apply here (an await suspends and
`return`s, which cannot live inside a value expression). The correct approach is
a small await-hoisting pre-pass over the async AST that rewrites each
await-bearing expression into `let __await_tmp = await <inner>` + the expression
with `__await_tmp` substituted — run before CF lowering so every await is the top
of a `stmt_local`/`stmt_expression`/`stmt_assignment`/`stmt_return`.

**(F) Vtable + constructor** already exist in `lower_async_fn` and are correct;
they only need the `await_N` fields present and (for `set_waiter`) the real body.
`cancel`/`release` should additionally cancel/release any in-flight `await_N`
task and run frame-stored defers (Ruby's `build_async_cancel_function` /
`build_async_release_function`).

**(G) Async `main` entrypoint.** When `main` is `async` and is root, emit a
synchronous `int main(...)` that wraps the async-main constructor in a
zero-capture root `proc() -> Task[int]` and calls `std_async_wait__int` (int
return) or the void `run` variant, then releases the root proc and returns the
result. Mirror Ruby's `build_async_main_entrypoint`; reuse the existing proc
synthesis (`lower_proc_expression`).

### 2.5 Implementation plan (staged; each independently testable)

1. Dispatch: route **all** async functions to `lower_async_fn`; delete the
   degenerate `lower_function(..., is_async=true)` path.
2. Analysis pass producing `async_info`; extend the frame struct with
   param/local/await fields.
3. Spilling: bind param/local c-names to `__mt_frame->field`; lower `let`/`var`
   to frame assignments.
4. Goto state machine in resume; real await suspend/resume with `set_waiter`,
   result binding, and `release`.
5. Await-hoisting pre-pass for awaits embedded in expressions/conditions.
6. CF-aware lowering (if/while/for/match) with loop break/continue labels and
   defer cleanup.
7. Async `main` entrypoint.
8. `cancel`/`release` completeness (nested-task cleanup, defers).

Validation: `language_baseline` runs to `0` and matches Ruby; `async_stress_test`
and `async_network_lobby` build and run (timers, UDP, nested awaits, loops with
awaits, error propagation). The bootstrap fixed point is unaffected by
construction (self-host uses no async).

Files: `projects/mtc/src/mtc/lowering/lowering.mt` (`lower_module` dispatch,
`lower_async_fn`, `lower_async_cps_body`, `lower_async_await*`,
`build_root_main_entrypoint`), `projects/mtc/src/mtc/lowering/async.mt`
(analysis + frame builder).

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

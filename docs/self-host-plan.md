# Self-Host Plan: Path to 100% Ruby Parity

Status: **SELF-HOSTING FIXED POINT ACHIEVED.** The self-host compiler compiles
itself and reaches a byte-identical fixed point (stage2 == stage3). 172/172
self-tests pass under the self-built compiler. Two feature subsystems remain
for full *example* parity: `await`-driven async CPS and format strings.
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
| `string_test` | 1 failing case: `f"hello"` format string (see §3) |
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

### 2.2 Root cause

The self-host has two async paths in `lower_module`:

- **no `await`** → `lower_async_fn`: full CPS output — frame struct, resume,
  vtable (ready/set_waiter/release/take_result/cancel), and a constructor that
  returns a proper `Task`. This is correct.
- **has `await`** → `lower_function(..., is_async=true)`: evaluates each `await`
  **synchronously** as `expr.value` and returns a **degenerate task with null
  vtable pointers** (`{ .value = …, .ready = 0, … }`). When `std.async.wait`
  drives it through `task.ready(task.frame)` the null pointer call crashes.

Additionally, an **async `main`** is never given a synchronous entrypoint
wrapper, so no C `main` symbol is emitted (Ruby's `build_async_main_entrypoint`
wraps the async main in a root proc and calls `std_async_wait__int`).

### 2.3 Correct fix (per Ruby)

Route **all** async functions through a single real CPS lowering: build the
frame, a resume function containing a `switch(state)` state machine with a
`goto` label per await point, spill live locals into the frame across await
boundaries, and the vtable + constructor. A 0-await function is just the
single-state case. Then add the async-`main` entrypoint wrapper.

Reference: `lib/milk_tea/core/lowering/async.rb` and
`lib/milk_tea/core/lowering/async/lowering.rb`. This is a substantial subsystem
(~500+ lines); a synchronous approximation is **not** acceptable because it is
semantically wrong for real timer/network I/O.

Files: `projects/mtc/src/mtc/lowering/lowering.mt` (`lower_async_fn`,
`lower_module` async dispatch), `projects/mtc/src/mtc/lowering/async.mt`.

---

## 3. Remaining: format strings (`f"..."`)

### 3.1 Symptom

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

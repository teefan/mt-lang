# Milk Tea Compile-Time Evaluation

Compile-time evaluation in Milk Tea is a small, side-effect-free layer that runs ordinary-looking code at compile time and produces values that drop into the generated C as plain literals. It exists to remove the small, repetitive jobs — target dispatch, field iteration, type selection, table generation — that today force users into the build pipeline or into writing hand-written C.

It is **not** a macro system, **not** a code-generation system, and **not** a way to do IO at build time. The build pipeline (`docs/build-guide.md`) stays the right place for any task that touches the filesystem, runs a tool, or rewrites source text. The compile-time layer stays the right place for tasks that can be expressed as pure functions from compile-time inputs to compile-time values.

The contract is short:

- A compile-time expression is evaluated by the compiler during semantic analysis.
- It can read types, declarations, attributes, layout, and other consts. It cannot read files, sockets, environment variables, or host architecture.
- It cannot allocate memory that outlives the compile-time evaluation.
- It cannot call into ordinary runtime functions. Only other compile-time functions and a small set of whitelisted builtins.
- It cannot rewrite source text. There are no string-to-AST paths.
- The result is fully specialized. The generated C has no runtime residue: no dispatch table, no metadata, no "this came from compile time" tag.

## Quick Reference

| Construct | What it does | When to reach for it |
| --- | --- | --- |
| Block-bodied `const` | A `const` initializer that is a block of statements evaluated at compile time. | A `const` value needs logic, not just a literal. |
| `when` | Block-level conditional; only the chosen branch is type-checked and emitted. | Target, config, or feature-flag dispatch. |
| `inline for` | Loop over a compile-time-known array, unrolled at compile time. | Walking struct fields, enum members, or attributes. |
| `inline while` | Loop with a compile-time-known condition, unrolled at compile time. | Compile-time arithmetic with a bounded step count. |
| `inline match` | Match with a compile-time-known scrutinee, unrolled at compile time. | Compile-time dispatch on a compile-time tag (use `when` when the form is a tag list). |
| `type` as a return type | A function that returns a type expression chosen at compile time. | Picking a primitive type from a compile-time value (e.g. an int width). |
| `fields_of` / `members_of` / `attributes_of` | Compile-time arrays of handle values. | Iterating over a type's structure inside an `inline for`. |

## Why It Exists

Five small use cases, all of which currently leak into the build system or require hand-written C:

1. **Target and config dispatch.** Code that does different things on different platforms should not need three different files.
2. **Ad-hoc reflection.** Code that needs to walk a struct's fields, enumerate an enum's members, or read its own attributes should be able to do so in a single function body.
3. **Type-returning functions.** Code that picks a type from a value (an int width, a backend tag, a feature flag) should be able to write that selection once.
4. **Compile-time computation.** Code that wants a `const` table, a hash constant, a rounded-up size, or a build-time lookup should not have to be a single literal expression.
5. **Compile-time parameter enforcement.** A function that needs an integer known at the call site should be able to say so.

The first three are the common ones. The fourth and fifth are the cases where the build pipeline shows through today.

## The Five Constructs

Milk Tea's compile-time surface is five things. They compose; each is small.

### 1. Block-Bodied `const`

`const` has two forms. The expression form `const X: T = expr` is the existing one. The block form `const X -> T:` followed by a block is new.

```mt
const X: int = 1                        # expression form (existing)
const ROUNDED_UP -> int:                # block form (new)
    var n = 1
    while n < 1024:
        n = n * 2
    return n
```

The `->` reuses the same arrow mt uses for function return types. For a function, `->` says "this function produces a value of this type at runtime." For a `const`, the same arrow says "this `const` has a body that produces a value of this type at compile time." The `:` after the type is the block-introducer, the same colon `function` uses for its block body.

- The block is a pure function. No IO, no runtime calls, no observable state.
- Allowed inside the block: literals, names of other `const` values, arithmetic, control flow (`if`/`else if`/`else`, `while`, `match`), `let` and `var` declarations, calls to other compile-time functions, and calls to whitelisted builtins (`size_of`, `align_of`, `offset_of`, `fields_of`, `members_of`, `attributes_of`).
- Forbidden inside the block: ordinary function calls, foreign-function calls, IO, heap allocation that escapes the block, mutation of any `var` outside the block, `defer`, and `async`/`await`.
- The block must end with a `return` (or contain a `return` on every code path). The return type is checked against the `const` declaration.
- The body is type-checked and evaluated once. The result is memoized by content; identical block bodies in different translation units evaluate to the same constant.

A block body may also be used for a `type`-returning function (see below). The block's rules are the same in both positions.

### 2. `when`

A block-level conditional chosen at compile time. Only the chosen branch is type-checked and emitted.

```mt
enum TargetOs:
    linux
    windows
    macos

const TARGET_OS: TargetOs = TargetOs.linux    # set by the build system

function open(path: str) -> File:
    when TARGET_OS:
        TargetOs.linux:
            return open_linux(path)
        TargetOs.windows:
            return open_windows(path)
        TargetOs.macos:
            return open_macos(path)
```

- The discriminant must be a compile-time constant. It may be a `const`, an enum literal, a compile-time expression, or a name resolved at compile time.
- Only the chosen branch enters the type checker. The other branches are not checked, do not import their dependencies, and do not appear in the generated C.
- `else` is required when the discriminant is not a finite type. `else` is optional only when the discriminant is an enum and every member is covered.
- The discriminant must be resolvable at the `when`'s lexical position. A `when` whose discriminant depends on a runtime value is a compile error.
- Arm patterns use the same qualified form as `match` arms (`EnumName.member`, not the unqualified `.member` shorthand). This is consistent with the rest of the language.

A `when` is a block of statements. There is no `when` expression form. The `if` expression form handles the runtime case. The two keywords are distinct so the choice is explicit in source.

`when` and `inline match` overlap: both unroll a compile-time dispatch. Use `when` for tag-list dispatch (the common case). Use `inline match` when the dispatch reads more naturally as a value match.

### 3. `inline` on `for`, `while`, and `match`

The `inline` modifier tells the compiler that the loop or match is compile-time-driven. The body is unrolled once per compile-time element.

```mt
struct Particle:
    x: float
    y: float
    z: float

# inline for: walk the fields and assert each one is a float
inline for field in fields_of(Particle):
    static_assert(field.type == float, "Particle fields must be float")

# inline while: a compile-time-bounded step
const ROUNDED_UP -> int:
    var n: int = 1
    inline while n < 1024:
        n = n * 2
    return n

# inline match: dispatch on a compile-time tag
enum Backend:
    gl
    metal
    vulkan

const TARGET_BACKEND: Backend = Backend.gl

function draw(item: Item):
    inline match TARGET_BACKEND:
        Backend.gl:
            gl_draw(item)
        Backend.metal:
            metal_draw(item)
        Backend.vulkan:
            vk_draw(item)
```

- The iterable in `inline for` must be a compile-time-known array. The most common source is a reflection builtin (`fields_of`, `members_of`, `attributes_of`). A literal array is also fine.
- The condition in `inline while` must be a compile-time constant. The loop unrolls to a fixed number of iterations. The unrolled count must be a positive integer; a non-terminating or zero-iteration `inline while` is a compile error.
- The scrutinee in `inline match` must be a compile-time constant. Only the chosen arm emits code. The other arms are dropped the same way `when` drops branches. An `inline match` is not required to be exhaustive: the unchosen arms are dead code that the compiler drops.
- The loop or match variable is a compile-time handle, with the same type as the corresponding reflection builtin returns.
- Arm and loop bodies always use the block form (indented statements under `:`), consistent with the rest of the language.
- `inline` is **only** a compile-time control-flow modifier. It does not mean "inline at the C level" (the C compiler already does that). It does not apply to `if`. It does not apply to declarations.

### 4. `type` as a Return Type

A function may return a type when its return value is a compile-time type expression. The return type `type` is a single new built-in name.

```mt
function int_with_bits[N: int]() -> type:
    if N == 8:
        return byte
    else if N == 16:
        return short
    else if N == 32:
        return int
    else if N == 64:
        return long
    else:
        static_assert(false, "unsupported bit width")

const Wide = int_with_bits[64]
const WidePtr = ptr[Wide]
```

- The `type` keyword names the "type of types." It exists only in compile-time contexts.
- A function declared with return type `type` may be called only from another compile-time context: a block-bodied `const`, a `const` expression initializer, a `when` discriminant, an `inline for` body, another `type`-returning function, or a generic body.
- The body of a `type`-returning function is restricted the same way a block-bodied `const` is restricted.
- The function body must return a type expression in every code path. `static_assert(false, ...)` is the canonical way to reject unsupported inputs.
- The generic parameter form `[N: int]` is a small extension to mt's existing generic-parameter surface. Today, mt generic parameters are either a type (`T`) or a numeric literal used in a literal slot (`array[T, 32]`). The `[N: int]` form lets a generic parameter be a compile-time int usable in expressions, like Zig's `comptime N: int`. The call site specializes the function with a literal: `int_with_bits[64]`.

### 5. Reflection Builtins That Return Arrays of Handles

Three new builtins, each returning a compile-time-known array of the same handle types the existing reflection surface already exposes:

```mt
fields_of(T)                      -> array[field_handle, N]
members_of(E)                     -> array[member_handle, N]      # enums and variants
attributes_of(T, name?: str)      -> array[attribute_handle, N]
```

These extend the existing `field_of(T, name)`, `callable_of(...)`, and `attribute_of(...)` builtins. The one-element form (`field_of(T, "x")`) is the limit of the iterable form. There is one reflection surface, not two.

- `fields_of(T)` returns one `field_handle` per declared field of `T`, in declaration order. The handle exposes `.name` and `.type`. Field-level attributes reachable through `attributes_of(T, name)` are available when needed.
- `members_of(E)` returns one `member_handle` per enum member or variant arm. The handle exposes `.name`, the enum value (when applicable), and the payload shape (for variants).
- `attributes_of(T, name?)` returns the attributes on `T`. Without `name`, all attributes. With `name`, only attributes of that kind.
- The array length `N` is part of the return type. Iteration over a struct of `N` fields is unrolled `N` times by `inline for`.
- Reflection works on user-defined types and on imported types. It does not work on raw `external` ABI types that are not projected — those are part of the C side, not the Milk Tea side.

The reflection builtins run at compile time. Their return type is a compile-time constant. They are usable inside block-bodied consts, generic bodies, `when` discriminants, `inline for` iterables, and anywhere else a `const` would be.

## Rules of the Road

These rules are the discipline. They are not advisory.

### Hard Restrictions

A compile-time expression — the body of a block-bodied `const`, the body of a `type`-returning function, the iterable in `inline for`, the condition in `inline while`, the discriminant in `when`, the scrutinee in `inline match` — may not:

- Perform any IO. No file reads, no network, no environment access, no command execution.
- Observe the host. No `env`, no "size of void on the build machine." All size, alignment, and offset builtins return target values.
- Allocate memory that outlives the compile-time evaluation. Local buffers inside a block-bodied `const` are fine; heap allocation that escapes the block is not.
- Call into ordinary runtime functions. A compile-time function may call only other compile-time functions and the whitelisted builtins.
- Mutate runtime-observable state. Module-level `var`, foreign-state handles, and async runtime state are off-limits.
- Rewrite source text. There is no `format`, no `sprintf`-into-source, no AST manipulation.
- Use `defer`, `async`, `await`, or `unsafe`. These constructs are runtime-only.

The compile error for any of these is direct: the parser or checker rejects the construct at the lexical position where it appears inside a compile-time context. The error message names the rule.

### Soft Restrictions

- A compile-time block has a bounded evaluation budget. The compiler enforces a depth limit (default 64) and a total reduction limit (default 10,000). Exceeding either is a compile error, not a hang.
- A compile-time function's result is memoized by structural content. Two block-bodied consts with identical bodies and inputs produce the same constant; the compiler evaluates one and reuses the result.
- The interpreter is a restricted mt evaluator, not a full implementation. It supports the constructs listed in section 1 and nothing else. A construct the interpreter cannot evaluate is a compile error at the compile-time lexical position.

### Cross-Compilation

A `when` discriminant, an `inline match` scrutinee, and any compile-time expression that depends on layout (`size_of`, `align_of`, `offset_of`) is evaluated against the **target** triple, not the host. The same source code compiled for wasm and for linux produces different generated C, both correct for their target. This is the same rule `size_of` and `align_of` already follow.

## How It Composes With the Rest of the Language

| Existing feature | How it composes with compile-time evaluation |
| --- | --- |
| `const` | The expression form `const X: T = expr` keeps working. The block form `const X -> T: ...` is the multi-statement variant. The two spell the same idea at different complexity levels. |
| `field_of`, `callable_of`, `attribute_of`, `attribute_arg[T]` | Stay. The new iterable builtins (`fields_of`, `members_of`, `attributes_of`) return the same handle types. One reflection surface. |
| Generics `[T]` and `[N]` | A generic body can use `when`, `inline for`, `inline match`, and `type`-returning functions. The generic type parameter `T` is in scope as a compile-time type, and the reflection builtins work on it. |
| `implements` constraints | Orthogonal. Nominal constraints stay the right tool for polymorphism. Reflection and `inline for` are the right tool for ad-hoc structural checks. The two compose inside a generic body. |
| `static_assert` | Becomes natural inside `when` and `inline for` to express compile-time failure at the right lexical position. |
| `size_of`, `align_of`, `offset_of` | Already compile-time. Naturally usable inside block-bodied consts and as `when` discriminants. |
| `defer` | Stays runtime-only. A `defer` inside a block-bodied `const` is a compile error. |
| `unsafe` | Stays runtime-only. An `unsafe` inside a block-bodied `const` is a compile error. |
| Foreign functions | Stay runtime-only. A foreign function call inside a compile-time context is a compile error. |
| `async` and `await` | Stay runtime-only. Compile-time code does not produce `Task[T]` values. |
| Generated C | `when` emits one branch. `inline for` unrolls. `inline while` unrolls. `inline match` emits one arm. Block-bodied consts reduce to C literals. The generated C stays clean. |
| `cstr` and `str` | Stay. There is no compile-time string manipulation that produces a `cstr`. A `c"..."` or `"..."` literal inside a block-bodied `const` is a `str` value usable in compile-time string operations (concatenation, length, byte indexing) — but the result is a `str`, not a `cstr`, and cannot be passed to a foreign function. |
| `match` exhaustiveness | An ordinary runtime `match` on an enum is still required to be exhaustive. `inline match` is not: the unchosen arms are dead code that the compiler drops. |
| Generic value parameters `[N: int]` | New. Extends mt's existing generic-parameter surface so a generic int can be used in expressions, not just literal slots. Specialization stays a literal at the call site. |

## Lowering to C

A few examples showing the shape of the generated output. The pattern is consistent: the compile-time layer chooses; the C shows only the choice.

### Example 1: A `when` for Platform Dispatch

Milk Tea:

```mt
function open(path: str) -> File:
    when TARGET_OS:
        TargetOs.linux:
            return open_linux(path)
        TargetOs.windows:
            return open_windows(path)
```

Generated C (on a linux target):

```c
static game_File game_open(const char* path) {
    return game_open_linux(path);
}
```

The other branch is not in the file. There is no `switch`, no `if` chain, no runtime check.

### Example 2: An `inline for` over Fields

Milk Tea:

```mt
function describe(T: type) -> void:
    inline for field in fields_of(T):
        print_field(field.name)
```

Generated C (for a `Particle` with `x`, `y`, `z`):

```c
static void game_describe(void) {
    game_print_field("x");
    game_print_field("y");
    game_print_field("z");
}
```

The loop is unrolled. The reflection result is fixed at compile time; each iteration becomes an explicit call.

### Example 3: A Block-Bodied `const` Computing a Constant

Milk Tea:

```mt
const FNV_OFFSET: uint = 0x811c9dc5
const FNV_PRIME: uint = 0x01000193

const HELLO: array[ubyte, 5] = (0x68, 0x65, 0x6c, 0x6c, 0x6f)
const FNV_HASH_OF_HELLO -> uint:
    var h = FNV_OFFSET
    for b in HELLO:
        h = (h ^ b) * FNV_PRIME
    return h
```

Generated C:

```c
static const uint32_t game_FNV_HASH_OF_HELLO = 0x4d2505ca;
```

The loop runs once at compile time. The result is a single constant in the output.

### Example 4: A `type`-Returning Function

Milk Tea:

```mt
const Wide = int_with_bits[64]

function scale_wide(x: int) -> Wide:
    return Wide(x) * Wide(2)
```

Generated C (assuming `int64_t` for `long` on the target):

```c
static int64_t game_scale_wide(int32_t x) {
    return ((int64_t)x) * ((int64_t)2);
}
```

`Wide` is replaced with `int64_t` at every use site. The `type`-returning function participates in monomorphization, so the result type is fixed before code generation. There is no runtime residue.

## What Compile-Time Is Not

| Feature | Why mt doesn't need it here |
| --- | --- |
| Macros / AST rewriting | Explicit non-goal. The "generate code" need is met by the build pipeline (`mtc gen`, codegen tools). |
| Compile-time file reads | Wrong layer. The build system reads files; the language does not. |
| `anytype` duck-typed parameters | Incompatible with mt's explicit-typing rule. Use `implements` for constraints. |
| `type` as a runtime value | Would require runtime type metadata, which mt explicitly rejects. `type` is compile-time-only. |
| Compile-time heap allocation that escapes | Breaks "no user-invisible allocation." |
| `inline` for runtime loop or function inlining | Not a compile-time feature. The C compiler already inlines; we do not need to second-guess it. |
| Compile-time calls into ordinary code | Forbidden. Compile-time calls only other compile-time code and whitelisted builtins. |
| Runtime polymorphism through `inline match` | `inline match` unrolls a compile-time-known scrutinee. It does not turn a `match` into a vtable. |
| Reified generics with `type` instances | Generic instantiation already happens during monomorphization. `type`-returning functions participate in the same phase. |

## Implementation Note

The compiler is implemented in Ruby. Compile-time evaluation runs as a tree-walking interpreter over a restricted subset of Milk Tea, written in the host language. Three pragmatic decisions follow from this:

- The interpreter is a **whitelist**, not a sandbox. The set of constructs allowed inside a compile-time context is enumerated explicitly. Anything outside the whitelist is a compile error at the lexical position, not a runtime exception.
- Compile-time evaluation is **bounded** by depth and reduction count. A runaway block becomes a hard compile error, never a hang.
- Compile-time results are **memoized** by structural content. Two block-bodied consts with identical bodies and inputs share an evaluation.

The interpreter does not need to support `defer`, `async`/`await`, foreign calls, runtime allocation, or `unsafe`. Removing those from the allowed set cuts the implementation surface substantially. The whitelist approach is simpler to reason about than a full interpreter that happens to be safe by construction.

## Future Directions

Things that are deliberately out of scope for v1 but worth keeping in mind:

- Compile-time string interpolation in diagnostics, e.g. `@compile_error("expected type {T}, got {U}")`. Useful, but adds a string-formatting surface to the compile-time interpreter; defer until a concrete diagnostic need appears.
- Compile-time access to imported declarations from other modules. Already works through the type system; only the reflection builtins need module-qualified forms if a generic body wants to reflect on a foreign type.
- A clearer "compile-time interface" — a marker that says "this function is meant to be called at compile time." Not needed in v1, since the restriction is enforced by the whitelist.

The list is short on purpose. The discipline is the value.

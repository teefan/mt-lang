# Milk Tea Language Manual

This manual documents the Milk Tea language as implemented today in the lexer, parser, semantic checker, and compiler tests.

Package manifests and build or run workflow are documented separately in `docs/build-guide.md`.

## 1. Source Files And Modules

Milk Tea source files use the `.mt` extension.

A file can be either:

- an ordinary source file (the normal source form; no header; module name comes from the path)
- an external file (`external`) for raw ABI bindings

### 1.1 Ordinary file

```mt
function main() -> int:
    return 0
```

### 1.2 External file

```mt
external

include "raylib.h"
link "raylib"

struct Color:
    r: ubyte
    g: ubyte
    b: ubyte
    a: ubyte

external function InitWindow(width: int, height: int, title: cstr) -> void
```

Rules:

- In ordinary files, `import` statements are parsed only at the top.
- In external files, leading `import` statements are allowed after `external`.
- Only external files accept `include`, `link`, and `compiler_flag` directives.
- External files are the dedicated raw ABI surface, usually for `std.c.*` bindings and bindgen output.
- After leading imports and directives, external files are intentionally narrow: they contain raw ABI declarations, not ordinary module logic.
- Module lookup resolves `a.b.c` to `a/b/c.mt`.
- Module identity is inferred from the resolved source path.
- Platform-specific file variants are a compiler resolution rule, not a source-language import feature.
- For an active target platform `P`, the compiler resolves `a.b.c` by preferring `a/b/c.P.mt` and falling back to `a/b/c.mt`.
- Valid platform filename suffixes are `linux`, `windows`, and `wasm`.
- The platform suffix is not part of the module name. `import a.b.c` stays the same on every target.
- Milk Tea does not have a source-level conditional compilation syntax such as `#if`, `#ifdef`, or per-declaration platform attributes.

## 2. Lexical Rules

### 2.1 Indentation and newlines

- Blocks are indentation-based.
- `:` starts a block.
- Indentation must be spaces only.
- Tabs are rejected.
- Indentation must be a multiple of 4 spaces.
- Indentation can increase by only one level (4 spaces) at a time.
- Newlines end statements, except while inside `()` or `[]`, or when the previous physical line ends with a binary operator.

For long expressions, prefer delimiter-based wrapping:

```mt
let total = (
    subtotal
    + tax
    - discount
)
```

Milk Tea also accepts continuation after a line-ending binary operator:

```mt
let total = subtotal +
    tax -
    discount
```

Starting a new physical line with the operator is not part of the supported source contract; wrap in `()` instead if that layout is clearer.

### 2.2 Comments

- `#` starts a line comment.

Documentation comments use `##` and attach to the nearest next declaration
without a blank line in between.

```mt
## Draws a colorful triangle strip.
## Values are normalized to screen center.
function draw_strip() -> void:
    return
```

Rules for documentation comments:

- Only lines that start with `##` are documentation.
- Contiguous `##` lines form one markdown block.
- A blank line breaks attachment.
- Plain `#` comments are ignored by hover documentation.
- Documentation attaches only to declarations (`function`, `struct`, `union`, `enum`, `flags`, `variant`, `type`, `const`, `var`, `let`, `extending`, `opaque`, `interface`).

### 2.3 Literals

Supported literals:

- integer: `42`, `0xff`, `0b1010`, with `_` separators
- float: `3.14`, `1.2e-3`, `1.1920929E-7`, `1.0f` (float suffix), `1.0d` (double suffix)
- string: `"hello"` (`str`)
- cstring: `c"hello"` (`cstr`)
- heredoc string: `<<-TAG ... TAG` (`str`)
- heredoc cstring: `c<<-TAG ... TAG` (`cstr`)
- format string: `f"count=#{count}"`
- booleans: `true`, `false`
- null: `null`, typed null `null[ptr[char]]`

### 2.4 Operators and punctuation

Symbols:

- delimiters: `(` `)` `[` `]`
- separators/access: `:` `,` `.`
- type markers: `->` `?`
- arithmetic: `+ - * / %`
- bitwise: `~ & | ^ << >>`
- comparison: `== != < <= > >=`
- assignment: `= += -= *= /= %= &= |= ^= <<= >>=`
- variadic marker: `...`

Word operators:

- `and`, `or`, `not`
- `in`, `out`, `inout` (reserved for `foreign function` parameter modes; legacy call-site forms are rejected semantically)

## 3. Declarations

Top-level declarations:

- `const`
- `const function` — compile-time-evaluable function
- `var`
- `type`
- `attribute`
- `interface`
- `struct`
- `union`
- `variant`
- `enum`
- `flags`
- `opaque`
- `extending`
- `function`
- `async function`
- `external function`
- `foreign function`
- `event`
- `static_assert(...)`
- `emit` — compile-time code generation inside `const function` or `inline` bodies
- `when` — compile-time conditional; may appear at module level or inside function bodies

File-kind note:

- Ordinary files may use the full declaration surface above.
- External files use a restricted declaration surface: `const`, `type`, `struct`, `union`, `enum`, `flags`, `opaque`, and `external function`. External files cannot declare new attributes, but supported attribute applications such as `@[packed]` and `@[align(...)]` may still appear on declarations that accept them.
- `event` declarations are not allowed in external files.

### 3.1 Visibility

- `public` is supported for exportable ordinary declarations.
- `public` is rejected on `extending` blocks.
- `public` is rejected on ordinary `external` declarations and `static_assert`.
- In external files, declarations are implicitly exported and `public` is rejected.

### 3.2 Constants and variables

```mt
const WIDTH: int = 1280
var counter: int = 0
var scratch: array[ubyte, 256]
```

Block-bodied `const` uses `->` instead of `:`:

```mt
const NEXT_POW2 -> int:
    var n: int = 1
    while n < 1024:
        n = n * 2
    return n
```

The block body is evaluated at compile time. Allowed inside the block: literals, names of other `const` values, arithmetic, control flow (`if`/`else if`/`else`, `while`, `for`), `let` and `var` declarations, calls to other compile-time functions, and calls to whitelisted builtins (`size_of`, `align_of`, `offset_of`, `fields_of`, `members_of`, `attributes_of`).

Rules:

- `const` requires explicit type and initializer.
- A block-bodied form `const NAME -> TYPE:` followed by an indented block is also supported. The block is evaluated at compile time and must end with a `return` on every code path.
- Top-level `var` requires explicit type; initializer is optional.
- Top-level `var` initializer must be static-storage-safe.
- Local declarations:
  - `let` is immutable
  - `var` is mutable
- A local declaration without initializer requires explicit type and must be zero-initializable.
- `let` and `var` declarations may use a guard form over nullable values, `Option[T]`, and `Result[T, E]`:

```mt
let window = maybe_window else:
    return 1

let image = load_image(path) else:
    return 1

var runtime = maybe_runtime else:
    return 1
```

Rules for `let ... else:` and `var ... else:`:

- both `let` and `var` support an `else` block
- the initializer must have type `T?`, `Option[T]`, or `Result[T, E]`
- an explicit type annotation, if present, must name the success type `T`
- for `Option[T]`, the bound name is the `some.value`
- for `Result[T, E]`, the bound name is the `success.value`
- `let _ = expr else:` discards the success value and does not introduce a local binding
- for `Result[T, E]`, `else as error:` optionally binds the `failure.error` value inside the `else` block
- `Result[void, E]` uses the same surface via `let _ = expr else:`
- the `else` block must exit control flow (`return`, `break`, `continue`, or another terminating path)

Tuple destructuring:

```mt
let (a, b) = pair()
let (x, y) = (1, 2)
```

Destructuring binds each element of a tuple to a separate immutable local. The binding count must match the tuple element count.

Postfix Result propagation:

```mt
let parsed = parse(input)?
let lowered = lower(parsed)?
return Result[Output, Error].success(value= lowered)
```

- `expr?` requires `Result[T, E]` with a non-`void` success type
- on success, `expr?` evaluates to the unwrapped `T`
- on failure, `expr?` returns `Result[_, E].failure(error= ...)` from the enclosing function or proc
- as an expression statement, `expr?` also accepts `Result[void, E]`; success continues and failure returns early
- `expr?` is only allowed inside function and proc bodies
- inside `async` functions, failure completes the task early with the same `Result` failure
- `expr?` is not allowed inside `defer` blocks
- the enclosing function or proc must return `Result[_, E]` with the same error type `E`
- `let _ = expr else:` is still useful when you need an explicit `else` block or `else as error:` binding

### 3.3 Type aliases

```mt
type Seconds = float
type Callback = fn(level: int, message: cstr) -> void
```

Callable and `ref[...]` rules:

- Plain stored `ref[T]` values are rejected in constants, module variables, and nested local storage such as arrays or other generic containers.
- In struct or union fields, bare `ref[T]` auto-generates an implicit lifetime parameter. The struct becomes non-owning and inherits ref-like restrictions: allowed as function params and local `let` variables, rejected as returns and module storage. Explicit lifetimes (`ref[@a, T]`) are still supported when the lifetime needs to be shared across fields.
- Ordinary local bindings may still hold a direct `ref[T]` value, for example `let handle = ref_of(counter)`.
- `fn(...)` and `proc(...)` parameter types may use `ref[...]` directly in parameter position.
- Stored callable values may use `ref[...]` only in direct callable parameter positions. This includes `fn(...)` values and `proc(...)` closure values stored in locals, struct fields, and generic containers such as `array[...]`.
- Stored callable values may not use `ref[...]` in return types.
- Stored callable values may not nest `ref[...]` anywhere except direct callable parameter positions.
- External functions still cannot take `ref[...]` parameters, and ordinary functions still cannot return `ref[...]`.
- `proc` captures are value captures. A captured local is not a mutable alias back to the outer binding.
- Shared mutable proc state should use explicit storage such as `std.cell.alloc[T](...)` or other explicit pointer-backed state, not implicit mutable capture.

### 3.4 Struct, union, enum, flags, opaque

```mt
struct Vec2:
    x: float
    y: float

union Number:
    i: int
    f: float

enum State: ubyte
    idle = 0
    running = 1

flags Mask: uint
    a = 1 << 0
    b = 1 << 1

opaque SDL_Window

variant Token:
    ident(text: str)
    number(value: int)
    eof
```

`struct` and `opaque` declarations may add nominal interface conformance with `implements`:

```mt
struct NPC implements Damageable, Named:
    hp: int

opaque SDL_Window implements Closable
```

`variant` is a tagged union. Each arm may optionally carry named payload fields. Generic variants are supported via type arguments, for example `Option[int]`:

```mt
variant Option[T]:
    some(value: T)
    none

variant Result[T, E]:
    success(value: T)
    failure(error: E)
```

Arm constructors:

- Payload arm: `Token.ident(text = "hello")` — field names with `=`.
- No-payload arm: `Token.eof` — accessed as a bare member expression.

Declaration attributes use a leading `@[name(...)]` surface. User-defined attributes are declared with explicit targets such as `attribute[field] rename(name: str)`. Built-in `packed` and `align(bytes)` are predefined struct attributes; `deprecated(message: str)` is predefined and targets function, struct, const, enum, flags, union, variant, and event:

```mt
@[packed]
struct Header:
    tag: ubyte

@[align(16)]
struct Mat4:
    data: array[float, 16]
```

`align(...)` must be a positive power of two.

Compile-time reflection over validated attributes uses `has_attribute`, `attribute_of`, `attribute_arg[T]`, `field_of`, and `callable_of`.

The current C backend lowers `packed` / `align(...)` attributes with GNU-style `__attribute__((...))`, so these layout controls currently require a Clang/GCC-family compiler. On Windows that means Clang or GCC-family toolchains such as MinGW; `cl.exe` is not a supported backend for these attributes today. On wasm/browser targets the same feature works through Emscripten `emcc`, which is Clang-based.

### 3.5 Interfaces

```mt
public interface Damageable:
    editable function take_damage(amount: int) -> void
    function is_alive() -> bool
```

Rules:

- Interface bodies contain `function`, `editable function`, or `static function` signatures.
- Generic interfaces are supported: `interface Mapper[T]: function map(x: T) -> T`.
- Interface methods may not declare their own type params — the type params come from the interface.
- Interface methods may not be `async`.
- Interface methods do not have bodies.
- `public` is allowed on the interface declaration, not on individual interface methods.
- Bare interface names are not runtime storage types; they are contracts used by `implements` and constrained generics.
- Runtime interface values use the `dyn[InterfaceName]` type constructor. A `dyn[I]` value is a fat pointer carrying a data pointer and a vtable pointer. Construct with `adapt[I](value: ref[T])` which verifies `T implements I` at compile time.
- Conformance uses type substitution: `struct Foo implements Mapper[int]` checks methods against `Mapper` with `T = int`.
- Generic interfaces instantiated through `dyn` must be fully specified: `dyn[Mapper[int]]` is valid; `dyn[Mapper]` is rejected.

### 3.6 Methods

```mt
extending Counter:
    function read() -> int:
        return this.value

    editable function bump() -> void:
        this.value += 1

    static function zero() -> Counter:
        return Counter(value = 0)
```

Kinds:

- `function` (value receiver)
- `editable function` (editable receiver)
- `static function` (no receiver)

Names such as `init` and `default` are ordinary static functions. There is no constructor keyword or hidden initializer syntax.

Method capabilities:

- async methods are supported
- generic methods are supported

### 3.7 Functions

```mt
function add(a: int, b: int) -> int:
    return a + b
```

Rules:

- Parameters must be typed.
- Parameters are non-rebindable; copy into a local `var` to mutate by-value data.
- Mutation through referent surfaces (for example span element writes, `read(ref_value) = ...`, and pointer writes in `unsafe`) is allowed.
- Return type defaults to `void` if omitted.
- Generic functions are supported.
- Generic function and method type parameters may declare constraints with `implements`.

Examples:

```mt
function damage_one[T implements Damageable](target: ref[T], amount: int) -> void:
    if target.is_alive():
        target.take_damage(amount)

function tag[T implements Damageable and Named](target: ref[T]) -> str:
    return target.name()

function make_default[T]() -> T:
    return default[T]

function boot_screen[T implements ScreenState]() -> T:
    return default[T]
```

### 3.7a `const function`

A `const function` is evaluable at compile time and follows the same body restrictions as a block-bodied `const`. When called from a compile-time context, the call is constant-folded to its computed value:

```mt
const function square(x: int) -> int:
    return x * x

const SQUARE_5: int = square(5)  # folded to 25 at compile time
```

Rules:

- The body must be evaluable at compile time (literals, `const` values, arithmetic, `if`/`else`, `while`, `for`, `let`/`var`, calls to other `const` functions, and whitelisted builtins).
- Generates a normal runtime function as well — callable from ordinary runtime code.
- Called from `const` initializers, `when` discriminants, `inline for` bodies, and other compile-time contexts.
- Recursive calls between `const` functions are supported.

### 3.8 External functions

```mt
external function printf(format: cstr, ...) -> int
```

Raw `std.c.*` modules usually group many `external function` declarations inside an external file, but `external function` is also allowed in ordinary files for small manual ABI bridges.

Rules:

- no body
- variadic `...` supported
- cannot be generic
- cannot be async
- cannot take `ref` parameters
- cannot take `proc` parameters
- cannot take or return arrays

### 3.9 Foreign functions

```mt
foreign function init_window(width: int, height: int, title: str as cstr) -> void = c.InitWindow
foreign function load_file_data(file_name: str as cstr, out data_size: int) -> ptr[ubyte]? = c.LoadFileData
foreign function close_window(consuming window: Window) -> void = c.CloseWindow
```

Parameter modes:

- plain
- `in`
- `out`
- `inout`
- `consuming`

Boundary projections:

- `name: PublicType as BoundaryType`

Rules:

- `as` is only allowed on plain and `in` params.
- `in`, `out`, and `inout` are declared on the `foreign function` parameter; callers pass ordinary expressions or lvalues at those argument positions.
- Legacy imported-call syntax such as `load_file_data(path, out size)` or `set_shader_value(shader, loc, in value, kind)` is rejected semantically.
- consuming foreign calls must appear as top-level expression statements.
- foreign functions with consuming params must return `void`.

## 4. Statements

Supported statements:

- local declaration (`let`, `var`)
- assignment
- `if` / `else if` / `else`
- `match`
- `when` — compile-time conditional; only the chosen branch is type-checked and emitted
- `inline for` — loop over a compile-time-known array, unrolled at compile time
- `inline while` — loop with a compile-time-known condition, unrolled at compile time
- `inline match` — match with a compile-time-known scrutinee, unrolled at compile time
- `inline if` — if with a compile-time-known condition; only the chosen branch is type-checked and emitted
- `unsafe`
- `static_assert`
- `for`
- `while`
- `pass`
- `break`
- `continue`
- `return`
- `defer`
- `emit` — compile-time code generation; only valid inside `const function` or `inline for/while/if/match` bodies
- expression statement

### 4.1 If

Condition must be `bool`.

`pass` is an explicit no-op statement for intentionally empty block bodies.

### 4.2 Match

Scrutinee types supported:

- Enum: arm patterns must be members of that enum.
- Variant: arm patterns must be arms of that variant; a payload arm may bind its fields with `as name` or destructure them inline with struct patterns.
- Integer (`byte`, `short`, `int`, `long`, `ubyte`, `ushort`, `uint`, `ulong`, `ptr_int`, `ptr_uint`): arm patterns must be integer literals.

`_` is a wildcard arm that matches any value not covered by preceding arms. It maps to a C `default:` case.

Rules:

- For enum scrutinee: all members must be covered unless a `_` arm is present.
- For variant scrutinee: all arms must be covered unless a `_` arm is present; `as name` binds the payload struct for arms that have fields.
- For integer scrutinee: a `_` arm is required (integers are unbounded).
- Duplicate arm values (or duplicate `_`) are rejected.
- Match must be exhaustive (enum/variant without `_`) or include `_` (integer or partial enum/variant).

```mt
match kind:
    EventKind.quit:
        return 0
    _:
        return 1

match key_code:
    65:
        fire()
    27:
        quit()
    _:
        return

match token:
    Token.ident as t:
        use_name(t.text)
    Token.number as n:
        use_value(n.value)
    Token.eof:
        return
```

#### Struct patterns in variant match arms

When a variant arm carries payload fields, those fields may be destructured inline. Inside `VariantName.arm_name(...)`, each argument is one of:

- **Binding:** a bare field name creates an immutable local bound to that field.
- **Guard:** `field comparison_op expr` extracts the field and skips the arm if the condition is false. Supported operators: `==`, `!=`, `<`, `<=`, `>`, `>=`.
- **Equality pattern:** `field = expr` is a shorthand guard — the arm matches only when the field equals the expression value.

```mt
match entity:
    Entity.player(hp > 0, position):
        render(position)
    Entity.player:
        remove()
    Entity.enemy:
        return
```

Rules for struct patterns:

- Each field name must appear at most once per arm.
- Guards and equality patterns are refutable: they do not count toward exhaustiveness. Exception: when equality patterns for an enum-typed field collectively cover every member of the enum, the arm is considered exhaustive. An arm with only bindings and no guards counts as exhaustive.
- Struct patterns compose with `as name` bindings: `Entity.player(hp > 0) as p` binds both `hp` (guard-checked) and `p` (the full payload struct).
- Struct patterns do not apply to enum or integer match scrutinees.

### 4.3 Loops

Single-form `for` supports:

- `start..stop` — exclusive integer range via range expression
- `array[T, N]`
- `span[T]`
- custom structural iterables with a non-editable zero-argument `iter()` method

Iterator protocol for custom structural iterables:

- the iterable value must expose `iter()` with no parameters
- the returned iterator must expose either `next() ->` nullable pointer-like item or `next() -> bool` together with `current()`

Parallel `for` is also supported:

```mt
for entity, position, velocity in entities, positions, velocities:
    update(entity, position, velocity)
```

Rules for parallel `for`:

- each iterable must be an `array[T, N]` or `span[T]`
- ranges are not supported in the parallel form
- iterable counts must match the binding count
- static array lengths must match; span lengths are checked at runtime

`break` and `continue` must be inside loops.

### 4.4 Defer

Forms:

```mt
defer cleanup()

# or

defer:
    release_a()
    release_b()
```

`return` is not allowed inside defer blocks.

### 4.5 Unsafe

Forms:

```mt
unsafe: pointer[0] = 1
let raw = unsafe: read(ptr)

# or

unsafe:
    pointer[0] = 1
    pointer[1] = 2
```

Unsafe context is required for raw-pointer-level operations such as:

- pointer indexing
- raw dereference
- pointer arithmetic
- pointer casts
- `reinterpret[...]`

### 4.6 Range index assignment

Contiguous indexed slices may be assigned from an expression list:

```mt
var buf: array[float, 4]
buf[0..3] = (1.0, 2.0, 3.0)
```

Rules:

- the target must be an addressable array-, span-, or pointer-indexable lvalue
- the index must be a range expression with integer literal bounds
- the range is start-inclusive and end-exclusive
- the right-hand side must be an expression list whose length exactly matches the range width
- each element must be assignable to the indexed element type

### 4.7 When (compile-time conditional)

```mt
when TARGET_OS:
    TargetOs.linux:
        return open_linux(path)
    TargetOs.windows:
        return open_windows(path)
```

Rules:

- The discriminant must be a compile-time constant.
- Only the chosen branch is type-checked and emitted. The other branches are not checked.
- `else` is required when the discriminant is not a finite type. `else` is optional only when the discriminant is an enum and every member is covered.
- `when` may appear at module level to conditionally include declarations, imports, or type definitions.
- There is no `when` expression form.

### 4.8 Inline for

```mt
inline for field in fields_of(Particle):
    static_assert(field.type == float, "Particle fields must be float")
```

Rules:

- The iterable must be a compile-time-known array. The most common source is a reflection builtin (`fields_of`, `members_of`, `attributes_of`). A literal array is also accepted.
- The loop is unrolled once per element at compile time.

### 4.9 Inline while

```mt
inline while n < 1024:
    n = n * 2
```

Rules:

- The condition must be a compile-time constant.
- The loop unrolls to a fixed number of iterations, capped at 10,000.
- A non-terminating `inline while` is a compile error.

### 4.10 Inline match

```mt
inline match TARGET_BACKEND:
    Backend.gl:
        gl_draw(item)
    Backend.metal:
        metal_draw(item)
    Backend.vulkan:
        vk_draw(item)
```

Rules:

- The scrutinee must be a compile-time constant.
- Only the chosen arm is type-checked and emitted.
- An `inline match` is not required to be exhaustive; unchosen arms are dropped.

### 4.11 Inline if

```mt
const DEBUG_RENDER: bool = false

function draw() -> void:
    inline if DEBUG_RENDER:
        debug_overlay()
    else:
        normal_draw()
```

Rules:

- The condition must be a compile-time constant `bool`.
- Only the chosen branch is type-checked and emitted. The dead branch may reference types and symbols that do not exist.
- `inline if` supports `else` and `else if` branches with the same dead-branch elimination.

## 5. Expressions

### 5.1 Primary

- identifier
- literals
- parenthesized expression
- tuple literal: `(a, b)` — positional; `(x = 1, y = 2)` — named
- `size_of(T)` — accepts a type name or a compile-time type expression
- `align_of(T)` — accepts a type name or a compile-time type expression
- `offset_of(T, field)` — the field argument may be a literal field name or a compile-time `field_handle` expression
- `proc(...) -> T: ...` — anonymous function expression, e.g. `let fn_ptr = proc(x: int) -> int: return x + 1`
- `proc(...) -> T: expr` — expression-bodied anonymous function, implicitly returning `expr`
- `if cond: a else: b`

### 5.2 Postfix

- member access: `a.b`
- indexing: `a[i]`
- call: `f(x)`
- partial field update: `v.with(x = 10.0)` — returns a copy with specified fields replaced; supported on structs and native types (vector, matrix, quaternion)
- specialization: `name[T]`, `name[32]`, `mod.name[T]`
- explicit specialization is only accepted on bare or module-qualified names; `value.member[32](...)` remains indexed-call syntax, so value-member calls rely on inference instead of explicit literal specialization

### 5.3 Operator precedence (low to high)

1. `or`
2. `and`
3. `|`
4. `^`
5. `&`
6. `==`, `!=`
7. `<`, `<=`, `>`, `>=`
8. `<<`, `>>`
9. `+`, `-`
10. `*`, `/`, `%`

### 5.4 Assignment operators

- `=`
- `+=` `-=` `*=` `/=`
- `%=`
- `&=` `|=` `^=`
- `<<=` `>>=`

## 6. Type System

### 6.1 Primitive types

- `bool`
- `byte` `short` `int` `long`
- `ubyte` `ushort` `uint` `ulong`
- `char`
- `ptr_int` `ptr_uint`
- `float` `double`
- `void`
- `str`
- `cstr`
- `vec2` `vec3` `vec4` — float vectors with `.x` `.y` `.z` `.w` fields; support component-wise `+` `-` `*` `/` and unary `-`
- `ivec2` `ivec3` `ivec4` — integer vectors with `.x` `.y` `.z` `.w` fields
- `mat3` `mat4` — column-major matrices; `mat3` has columns `.col0`–`.col2` (each `vec3`), `mat4` has `.col0`–`.col3` (each `vec4`)
- `quat` — quaternion with `.x` `.y` `.z` `.w` fields; memory-layout compatible with `vec4`

Primitive type names are reserved. They cannot be reused for value bindings, parameters, locals, import aliases, or type parameters.

Native vector, matrix, and quaternion types support aggregate construction with named fields. Omitted fields default to zero:

```mt
let v = vec3(x = 1.0, y = 2.0, z = 3.0)
let m = mat4(col0 = vec4(x = 1.0, ...), ...)
let q = quat(x = 0.0, y = 0.0, z = 0.0, w = 1.0)
```

### 6.2 Type constructors

- `ptr[T]`
- `const_ptr[T]`
- `ref[T]`
  - receiver-modifier type: passes a stored value by reference, allowing methods to mutate the underlying storage
  - functions like `append(output: ref[string.String], text: str)` receive a safe pointer to stored data
    - passing a mutable addressable `T` to a `ref[T]` parameter borrows it implicitly, as if the call had written `ref_of(value)` at the call site
  - `ref` types are non-null and cannot be nullable
- `span[T]`
- `array[T, N]`
- `str_buffer[N]`
- `Task[T]`
- `fn(params...) -> R`
- `proc(params...) -> R`
- `Option[T]`
- `Result[T, E]`
- `SoA[T, N]` — Structure-of-Arrays: transforms `T`'s fields into separate arrays of length `N`; access as `soa[i].field`
- `dyn[InterfaceName]` — runtime interface value (fat pointer: data + vtable). Constructed via `adapt[Interface](value: ref[T])`. @see §3.5.
- `(T, U)` — tuple type. Positional fields auto-named `_0`, `_1`. Named fields use `(x = T, y = U)`. Copy by value, returns supported.

### 6.3 Nullability

- nullable form: `T?` for pointer-like/null-capable types
- `null` and typed `null[...]` supported
- typed null target must be pointer-like
- in nullable pointer-like contexts, use `null` instead of `zero[ptr[T]]`

### 6.4 Generics

Supported:

- generic structs
- generic variants
- generic interfaces
- generic functions
- generic methods
- generic foreign functions

Rules:

- Constraints are supported on generic structs, variants, interfaces, functions, and methods.
- Interface constraints use `implements`, and multiple interfaces on the same type parameter use `and`: `T implements A and B`.
- There are no separate `hashes` or `equates` constraints. Generic bodies that call `hash[T](...)`, `equal[T](...)`, or `order[T](...)` rely on specialization-time checking of the canonical associated functions.
- Current type parameters may be used as type expressions for associated function calls in generic bodies, such as `T.default()` or `T.tag()`.
- Constraint kinds compose with `and`: `T implements ScreenState and Named` remains valid.

Type arguments can be:

- types
- integer literals
- named integer constants

Generic value parameters use the form `[N: int]` to declare a compile-time integer usable in expressions within the generic body:

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
```

The call site specializes with a literal: `int_with_bits[64]`.

`type` is a built-in type name representing the type of types. A function may declare `-> type` as its return type to select and return a type expression at compile time. Such functions may only be called from compile-time contexts (block-bodied `const`, `when` discriminants, `inline for` bodies, generic bodies, or other `type`-returning functions). The body follows the same restrictions as a block-bodied `const`.

## 7. Built-In Callable Surface

Special recognized callables:

- `fatal(message)`
- `ref_of(x)`
- `const_ptr_of(x)`
- `read(r)`
- `read(p)`
- `ptr_of(x)`
- `T<-value`
- `reinterpret[T](value)`
- `zero[T]`
- `default[T]`
- `hash[T](value)`
- `equal[T](left, right)`
- `order[T](left, right)`
- `array[T, N](...)`
- `span[T](data = ..., len = ...)`
- `get(coll, index)` — recoverable array/span indexing returning `ptr[T]?`; null on out‑of‑bounds instead of aborting
- `adapt[I](value)` — constructs a `dyn[I]` runtime interface value; verifies `value`'s type implements `I` at compile time

`default[T]` requires an accessible zero-argument associated function `T.default()` that returns `T`.

`hash[T](value)` lowers to `T.hash(value: const_ptr[T]) -> uint`, `equal[T](left, right)` lowers to `T.equal(left: const_ptr[T], right: const_ptr[T]) -> bool`, and `order[T](left, right)` lowers to `T.order(left: const_ptr[T], right: const_ptr[T]) -> int`. Each argument must already be a `ref[T]`, `ptr[T]`, or `const_ptr[T]`, or be a safe stored `T` lvalue that can be borrowed implicitly.

`T.order(...) -> int` returns a negative value when `left < right`, `0` when the values compare equal, and a positive value when `left > right`.

There are no separate `hashes` or `equates` constraints; the builtins themselves force those hook requirements at specialization time.

There is no separate `defaults` constraint. A generic body that uses `default[T]` relies on specialization-time checking that `T.default()` exists.

For recoverable failures, use `Result[T, E]`. Its `.success(...)` and `.failure(...)` constructors are variant arms, not built-in callables.

For repeated pointer-plus-length span construction, use the built-in `span[T](data = ..., len = ...)` form directly. If the pattern repeats often in one codebase, define a small local helper in your own module instead of depending on a standard helper module.

When a `span[T]` is expected, an addressable `array[T, N]` value may be passed directly through the existing boundary coercion rules. Arrays also expose `.as_span()` for explicit conversion when the target type is not a call boundary.

### 7.0 Compile-time reflection builtins

Compile-time reflection builtins return handle values that represent type structure:

- `field_of(T, name)` — returns a `field_handle` for the named field of `T`.
- `callable_of(T, name)` — returns a `callable_handle` for the named callable of `T`.
- `attribute_of(T, name)` — returns an `attribute_handle` for the named attribute on `T`.
- `has_attribute(T, name)` — returns `bool`; true if `T` has the named attribute applied.
- `attribute_arg[T]` — returns the `T`-typed argument of a resolved attribute handle.
- `fields_of(T)` — returns `array[field_handle, N]` of all fields of struct `T`, in declaration order.
- `members_of(E)` — returns `array[member_handle, N]` of all members of enum or variant `E`.
- `attributes_of(T)` — returns `array[attribute_handle, N]` of all attributes on `T`.
- `attributes_of(T, name)` — returns `array[attribute_handle, N]` of attributes whose kind matches `name`.

Handle field access: `field_handle` exposes `.name` (`str`) and `.type` (the field's type). `member_handle` exposes `.name` (`str`) and, for enum members with explicit values, `.value` (an integer). `attribute_handle` provides access to attribute arguments via `attribute_arg[T]`.

`read(r)` still explicitly projects a `ref[T]` to its referent value, but ordinary member access and method calls auto-dereference `ref[T]` receivers. That means `handle.field`, `handle.edit_method()`, and `handle.read()` are accepted without writing `read(handle)` first. Calls in the other direction are also lighter now: if a function expects `ref[T]`, passing a mutable addressable `T` borrows it implicitly.

### 7.1 Current standard collection modules

The current shipped collection modules in `std` are:

- `std.vec.Vec[T]`: contiguous growable storage with `create`, `with_capacity`, `len`, `capacity`, `is_empty`, `iter`, `as_span`, `get`, `first`, `last`, `find`, `find_index`, `reserve`, `clear`, `release`, `append_span`, `append_array`, `insert`, `push`, `pop`, `remove`, and `swap_remove`.
- `std.deque.Deque[T]`: growable ring buffer with `create`, `with_capacity`, `len`, `capacity`, `is_empty`, `iter`, `get`, `first`, `last`, `reserve`, `clear`, `release`, `push_front`, `push_back`, `insert`, `pop_front`, `pop_back`, `remove`, `rotate_left`, and `rotate_right`.
- `std.binary_heap.BinaryHeap[T]`: max-heap keyed by the canonical `order[T](...)` hook, with `create`, `with_capacity`, `len`, `capacity`, `is_empty`, `iter`, `peek`, `reserve`, `clear`, `release`, `push`, and `pop`.
- `std.priority_queue.PriorityQueue[T]`: task-oriented facade over `BinaryHeap[T]`, with `create`, `with_capacity`, `len`, `capacity`, `is_empty`, `iter`, `peek`, `reserve`, `clear`, `release`, `enqueue`, and `dequeue`.
- `std.ordered_set.OrderedSet[T]`: AVL-backed unique sorted set keyed by the canonical `order[T](...)` hook, with `create`, `len`, `is_empty`, `get`, `contains`, `iter`, `clear`, `release`, `insert`, and `remove`.
- `std.ordered_map.OrderedMap[K, V]`: AVL-backed ordered map keyed by the canonical `order[K](...)` hook, with `create`, `len`, `is_empty`, `get`, `get_key`, `contains`, `keys`, `values`, `entries`, `iter`, `clear`, `release`, `set`, `get_or_insert`, `remove_entry`, and `remove`.
- `std.map.Map[K, V]`: hash table keyed by the canonical `hash[K](...)` and `equal[K](...)` hooks, with `create`, `with_capacity`, `len`, `capacity`, `is_empty`, `get`, `get_key`, `contains`, `keys`, `values`, `entries`, `iter`, `clear`, `release`, `reserve`, `set`, `get_or_insert`, `remove_entry`, and `remove` (`iter()` is the same traversal as `entries()`).
- `std.set.Set[T]`: hash set built on `Map[T, bool]`, with `create`, `with_capacity`, `len`, `capacity`, `is_empty`, `get`, `contains`, `iter`, `is_subset`, `union_with`, `intersection`, `difference`, `clear`, `release`, `reserve`, `insert`, and `remove`. Set union is spelled `union_with` because `union` is a reserved keyword.
- `std.linked_map.LinkedMap[K, V]`: insertion-ordered hash map keyed by the canonical `hash[K](...)` and `equal[K](...)` hooks, with `create`, `with_capacity`, `len`, `capacity`, `is_empty`, `get`, `get_key`, `contains`, `keys`, `values`, `entries`, `iter`, `clear`, `release`, `reserve`, `set`, `get_or_insert`, `remove_entry`, and `remove`.
- `std.linked_set.LinkedSet[T]`: insertion-ordered hash set built on `LinkedMap[T, bool]`, with `create`, `with_capacity`, `len`, `capacity`, `is_empty`, `get`, `contains`, `iter`, `is_subset`, `union_with`, `intersection`, `difference`, `clear`, `release`, `reserve`, `insert`, and `remove`.
- `std.counter.Counter[T]`: insertion-ordered frequency table built on `LinkedMap[T, ptr_uint]`, with `create`, `with_capacity`, `len`, `total_count`, `capacity`, `is_empty`, `count`, `contains`, `keys`, `counts`, `entries`, `iter`, `clear`, `release`, `reserve`, `add`, `increment`, `remove_one`, and `remove`.
- `std.multiset.MultiSet[T]`: insertion-ordered bag built on `Counter[T]`, with `create`, `with_capacity`, `len`, `total_count`, `distinct_len`, `capacity`, `is_empty`, `count`, `contains`, `values`, `entries`, `iter`, `is_subset`, `union_with`, `intersection`, `difference`, `symmetric_difference`, `clear`, `release`, `reserve`, `insert`, `add`, `remove_one`, and `remove_all`.
- `std.queue.Queue[T]`: FIFO facade over `Deque[T]`, with `create`, `with_capacity`, `len`, `capacity`, `is_empty`, `iter`, `peek`, `clear`, `release`, `reserve`, `enqueue`, and `dequeue`.
- `std.stack.Stack[T]`: LIFO facade over `Deque[T]`, with `create`, `with_capacity`, `len`, `capacity`, `is_empty`, `iter`, `peek`, `clear`, `release`, `reserve`, `push`, and `pop`.
- `std.linked_map_view.SnapshotValues[K, V]`: read-only snapshot view over `LinkedMap` values in insertion order, with `create(values: linked_map.Entries[K, V])` and `iter`.
- `std.linked_map_view.SnapshotEntries[K, V]`: read-only snapshot view over `LinkedMap` entries in insertion order, with `create(values: linked_map.Entries[K, V])` and `iter`.

Iterator notes for those collection modules:

- `Vec.iter()` and `Deque.iter()` use the pointer-returning iterator form.
- `BinaryHeap.iter()` uses the pointer-returning iterator form with read-only element pointers, and `peek()` is also read-only because arbitrary element mutation would violate the heap invariant.
- `PriorityQueue.iter()` uses the same read-only pointer-returning iterator form as `BinaryHeap.iter()`.
- `OrderedSet.iter()` uses the pointer-returning iterator form with read-only element pointers so in-place mutation cannot violate the sorted uniqueness invariant.
- `OrderedMap.keys()` uses the pointer-returning iterator form with read-only key pointers, `OrderedMap.values()` returns mutable value pointers in key order, and `OrderedMap.entries()` / `OrderedMap.iter()` use the `next() -> bool` plus `current()` iterator form in key order.
- `Map.keys()` and `Set.iter()` use the pointer-returning iterator form.
- `Map.values()` returns mutable value pointers during iteration.
- `Map.entries()` and `Map.iter()` use the `next() -> bool` plus `current()` iterator form.
- `LinkedMap.keys()` and `LinkedSet.iter()` use the pointer-returning iterator form with read-only key pointers in insertion order.
- `LinkedMap.values()` returns mutable value pointers in insertion order.
- `LinkedMap.entries()` and `LinkedMap.iter()` use the `next() -> bool` plus `current()` iterator form in insertion order.
- `Counter.keys()` uses the pointer-returning iterator form with read-only key pointers in first-seen order.
- `Counter.counts()` uses the `next() -> bool` plus `current()` iterator form and yields copied `ptr_uint` counts so totals cannot be mutated out of sync.
- `Counter.entries()` and `Counter.iter()` use the `next() -> bool` plus `current()` iterator form and yield immutable `{ key, count }` snapshots.
- `MultiSet.values()` uses the pointer-returning iterator form with read-only value pointers in first-seen order.
- `MultiSet.entries()` and `MultiSet.iter()` use the `next() -> bool` plus `current()` iterator form and yield immutable `{ value, count }` snapshots.
- `Queue.iter()` and `Stack.iter()` use the same mutable pointer-returning iterator form as `Deque.iter()`, and `peek()` returns a mutable element pointer because changing an element value does not violate FIFO/LIFO ordering invariants.
- `SnapshotValues.iter()` and `SnapshotEntries.iter()` use the `next() -> bool` plus `current()` iterator form in insertion order.

## 8. Strings, C Strings, And Format Strings

String categories:

- `str` -> string view
- `cstr` -> C ABI string
- `str_buffer[N]` -> fixed-capacity mutable UTF-8 text buffer

`str_buffer[N]` methods:

- `clear()`
- `assign(str)`
- `append(str)`
- `assign_format(str)`
- `append_format(str)`
- `len()`
- `capacity()`
- `as_str()`
- `as_cstr()`

Format string syntax:

```mt
f"count=#{count} ok=#{ready}"
```

Heredoc syntax:

```mt
const shader: cstr = c<<-GLSL
    #version 330
    void main()
    {
    }
GLSL
```

`<<-TAG`, `c<<-TAG`, and `f<<-TAG` read all following lines until a line containing only the terminator tag, optionally surrounded by spaces. Nonblank content lines are dedented by their shared leading spaces. The trailing newline before the terminator is preserved.

Ordinary `"..."` and `c"..."` literals may continue across following indented lines when each continued line starts with the same literal kind and contains nothing else. The segments concatenate exactly with no inserted separator, so any spaces or punctuation between pieces must be written explicitly.

In the VS Code extension, specific heredoc tags opt into embedded highlighting without changing the Milk Tea type: `GLSL`, `VERT`, `FRAG`, `COMP`, `JSON`, `JSONC`, and `SQL`. These still produce ordinary `str` or `cstr` values, and SQL heredocs should still use bound parameters rather than string interpolation.

Format strings have type `str` and are valid anywhere a `str` value is accepted. Interpolated expressions must be one of: `str`, `cstr`, `bool`, a numeric primitive, an integer-backed enum or flags type, or a type implementing both `format_len() -> ptr_uint` and `append_format(output: ref[std.string.String]) -> void`. A precision specifier `:.N` is allowed on `float` and `double` interpolations. Integer-base specifiers `:x` / `:X` (hex), `:o` / `:O` (octal), and `:b` / `:B` (binary) are allowed on integer primitives and integer-backed enum/flags interpolations.

The following standard library functions receive special lowering for format strings — they build the formatted output directly without an intermediate allocation:

- `std.fmt.format` — returns `string.String`
- `std.fmt.append_format` / `std.fmt.assign_format` — write directly into an existing `string.String` sink
- `std.string.String.append_format` / `std.string.String.assign_format` — same direct-sink lowering on the builder methods
- `str_buffer[N].append_format` / `str_buffer[N].assign_format` — same direct-sink lowering on fixed-capacity string buffers

Custom formatting hook notes:

- The hook pair is compiler-known; it is not declared through a separate interface.
- `format_len()` and `append_format(...)` must both be present, non-editable, and use the exact signatures above.
- Direct `string.String` sinks call the custom `append_format(...)` hook directly.
- Plain `f"..."` expressions and `str_buffer` sinks still need a raw `str` result, so the compiler passes each custom part a borrowed `string.String` view onto the destination slice.
- For those borrowed-slice paths, `append_format(...)` must write exactly `format_len()` bytes; writing fewer or more bytes raises a runtime error.

## 9. Safety And Conversion Rules

- conditions must be `bool`
- no truthy/falsy integer or pointer coercion
- mixed signed/unsigned integer arithmetic requires an explicit `T<-value` cast
- `%` requires integer-compatible operands
- bitwise operators require matching integer/flags types
- shift operators require integer operands
- safe array indexing requires an addressable array value
- safe indexing (`arr[i]`) is bounds-checked and calls `fatal` on out-of-bounds access
- use `get(arr, i)` for recoverable indexing that returns `ptr[T]?` (null on out-of-bounds) instead of aborting
- pointer indexing requires `unsafe`
- `read(...)` of raw pointer requires `unsafe`
- pointer casts require `unsafe`
- `reinterpret[...]` requires `unsafe` and non-array concrete sized types

## 10. Async Semantics

```mt
async function child() -> int:
    return 41

async function parent() -> int:
    let v = await child()
    return v + 1
```

Rules:

- async function return type is lifted to `Task[T]`
- `await` is only allowed inside async functions
- `async main` is compiler-bootstrapped, but async helpers remain library surface; import `std.async as aio` when you want helpers such as `sleep`, `completed`, `result`, `wait`, `run`, or runtime control
- `aio.wait(...)` and `aio.run(...)` accept either a zero-arg task root or a direct task expression; the compiler defers direct task expressions automatically
- `async main` pre-lift return type must be `int` or `void`

Current async limitations:

- `await` is supported inside `if` expressions, `if`/`else if`/`else` bodies and conditions, `while` bodies and conditions, single-form and parallel `for` bodies and iterables, `match` discriminants and arms, `let ... else:` initializers and else bodies, `unsafe` blocks, short-circuit `and`/`or` expressions, and assignment targets
- `defer` is supported in async functions, including cleanup bodies that `await`

## 11. Events

Event declarations provide a built-in typed publisher/subscriber surface with fixed-capacity listener storage.

### 11.1 Declaration

```mt
event name[capacity]
event name[capacity](PayloadType)
public event name[capacity]
public event name[capacity](PayloadType)
```

Examples:

```mt
public event closed[4]
public event resized[8](ResizeEvent)
```

Rules:

- The capacity expression must be a compile-time positive integer literal.
- An event carries either no payload or exactly one payload value.
- The payload type must be a storable type; `ref[T]` payloads are rejected.
- Event declarations are valid at top level and as struct members.
- `emit` is only callable from within the declaring module.

### 11.2 Built-in operations

- `event.subscribe(listener) -> Result[Subscription, EventError]` — register a stateless listener
- `event.subscribe_once(listener) -> Result[Subscription, EventError]` — register a one-shot listener
- `event.subscribe(state: ptr[State], listener: fn(ptr[State], ...)) -> Result[Subscription, EventError]` — register a stateful listener by passing 2 positional arguments; the state pointer is stored verbatim and passed to the listener on each dispatch
- `event.subscribe_once(state: ptr[State], listener: fn(ptr[State], ...)) -> Result[Subscription, EventError]` — register a stateful one-shot listener by passing 2 positional arguments
- `event.unsubscribe(subscription) -> bool` — remove a listener by subscription handle; returns `true` if the listener was active and removed, `false` if the handle was stale or invalid
- `event.emit()` or `event.emit(payload)` — synchronously dispatch to all listeners; only callable from the declaring module
- `event.wait() -> Task[Result[T, EventError]]` — async wait for the next emission; returns the payload for payload events, or `Result[void, EventError]` for no-payload events

`EventError` is a built-in enum with a single member `full` (value `0`), returned when listener capacity is exhausted.

`Subscription` is a built-in opaque handle type returned by `subscribe` and `subscribe_once`.

### 11.3 Example

```mt
struct ResizeEvent:
    width: int
    height: int

struct Window:
    public event closed[4]
    public event resized[8](ResizeEvent)

function on_close() -> void:
    stdio.println("closed")

function on_resize(event: ResizeEvent) -> void:
    stdio.println(f"resize -> #{event.width}x#{event.height}")

function attach(window: ref[Window]) -> Result[void, EventError]:
    let closed_sub = window.closed.subscribe(on_close)?
    let resized_sub = window.resized.subscribe(on_resize)?

    defer window.closed.unsubscribe(closed_sub)
    defer window.resized.unsubscribe(resized_sub)

    return Result[void, EventError].success()
```

## 12. Linting

The linter checks for common issues and style problems without changing program behavior.

### 12.1 Running the linter

```sh
mtc lint path/to/file.mt
mtc lint src/                              # lint all .mt files in a directory
mtc lint --fix path/to/file.mt             # apply auto-fixes in place
mtc lint --select prefer-let,dead-assignment file.mt
mtc lint --ignore shadow file.mt
```

### 12.2 Rules

The auto-fix column corresponds to `mtc lint --fix`.

| Code | Severity | Auto-fix | Description |
|---|---|---|---|
| `borrow-and-mutate` | warning | — | Local is borrowed with `ref_of` or `ptr_of` and also mutated in the same scope |
| `constant-condition` | warning | — | Branch or loop condition is provably always `true` or always `false` |
| `dead-assignment` | warning | — | Assigned value is overwritten before any read |
| `duplicate-if-condition` | warning | — | `if`/`else if` branch repeats a previous condition and is unreachable |
| `directional-ffi-arg` | hint | — | Legacy `ptr_of` / `ref_of` / `out` call-site wrapper is redundant for directional FFI parameters |
| `doc-tag` | hint | — | `##` documentation comment tag (`@param`, `@return`, `@throws`, `@see`) is invalid or inconsistent with the declaration |
| `event-capacity` | warning | — | Event capacity may copy too many listeners to stack on emit |
| `line-too-long` | warning | — | Source line exceeds configured maximum length |
| `loop-single-iteration` | warning | — | Loop body always exits on the first iteration |
| `missing-return` | error | — | Function with a non-void return type lacks a guaranteed return on all paths |
| `noop-compound-assignment` | hint | — | Compound assignment uses an identity value and has no effect |
| `platform-api-drift` | warning | — | Public API differs across sibling platform-specific variants of the same module |
| `prefer-let` | hint | yes | `var` binding is never mutated; use `let` instead |
| `prefer-let-else` | hint | yes | Nullable guard can be rewritten as `let ... else:` |
| `prefer-var-else` | hint | yes | Nullable guard can be rewritten as `var ... else:` |
| `redundant-bool-compare` | hint | yes | Comparing a boolean expression to `true`/`false` is redundant |
| `redundant-else` | warning | yes | `else` block is unnecessary because all prior branches return |
| `redundant-ignored-match-binding` | hint | yes | Ignored `as _` match binding is redundant |
| `redundant-null-check` | hint | — | Null check on a value already known to be non-null by flow analysis |
| `redundant-return` | hint | yes | Final bare `return` in a `void` function is unnecessary |
| `reserved-primitive-name` | warning | yes | Binding uses a reserved built-in type name in its active namespace |
| `self-assignment` | warning | — | Variable is assigned to itself |
| `self-comparison` | warning | — | Value is compared to itself, making the condition constant |
| `shadow` | warning | — | Local binding shadows an outer binding with the same name |
| `trailing-list-comma` | hint | yes | Trailing comma in call argument list is redundant |
| `unreachable-code` | warning | — | Code after a guaranteed terminator cannot execute |
| `unused-import` | warning | yes | Import alias is never referenced |
| `unused-local` | warning | — | Local binding is never referenced |
| `unused-param` | warning | — | Parameter is never referenced |
| `useless-expression` | warning | — | Expression statement has no side effects and its result is unused |

### 12.3 Config file

Create a default config with:

```sh
mtc lint --init
```

Or place `.mt-lint.yml` in the project root (or any ancestor directory):

```yaml
max_line_length: 120
select:
    - line-too-long
    - prefer-let
    - missing-return
ignore:
  - shadow
  - useless-expression
```

When both `select` and `ignore` are present, `select` takes precedence and `ignore` is unused.

`max_line_length` defaults to `120` when omitted.

`line-too-long` code actions currently rewrite only parser-valid same-line comma-delimited `()` groups and type-position `[]` groups. Tuple literals may be rewritten without a trailing comma when the parser requires it.

### 12.4 Per-line suppressions

```mt
var count = 0  # lint: ignore
var total = 0  # lint: ignore(prefer-let, dead-assignment)
```

`# lint: ignore` silences all rules on that line. `# lint: ignore(rule1, rule2)` silences only the listed rules.

## 13. Current Unsupported Or Rejected Surfaces

Current extending rejects:

- interface methods with `async` or generic signatures
- generic interface declarations
- runtime interface value types such as `Damageable` as a field, local, parameter, or return type

## 14. Example

```mt
import std.fmt as fmt

struct Counter:
    value: int

extending Counter:
    editable function bump() -> void:
        this.value += 1

    function read() -> int:
        return this.value

function main() -> int:
    var c = Counter(value = 0)

    for i in 0..3:
        c.bump()

    let text = f"count=#{c.read()}"
    return 0
```

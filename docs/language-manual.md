# Milk Tea Language Manual

This manual documents the Milk Tea language as implemented today in the lexer, parser, semantic checker, and compiler tests.

Package manifests and build or run workflow are documented separately in `docs/build-guide.md`.

## 1. Source Files And Modules

Milk Tea source files use the `.mt` extension.

A file can be either:

- an ordinary module (`module ...`)
- an external module (`external module ...`)

### 1.1 Ordinary module

```mt
module demo.main

function main() -> int:
    return 0
```

### 1.2 Extern module

```mt
external module std.c.raylib:
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

- In ordinary modules, `import` statements are parsed only at the top after `module`.
- In external modules, leading `import` statements are allowed inside the external-module body.
- Module lookup resolves `a.b.c` to `a/b/c.mt`.

## 2. Lexical Rules

### 2.1 Indentation and newlines

- Blocks are indentation-based.
- `:` starts a block.
- Indentation must be spaces only.
- Tabs are rejected.
- Indentation must be a multiple of 4 spaces.
- Indentation can increase by only one level (4 spaces) at a time.
- Newlines end statements, except while inside `()` or `[]`.

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
- Documentation attaches only to declarations (`function`, `struct`, `union`, `enum`, `flags`, `variant`, `type`, `const`, `var`, `let`, `methods`, `opaque`).

### 2.3 Literals

Supported literals:

- integer: `42`, `0xff`, `0b1010`, with `_` separators
- float: `3.14`, `1.2e-3`, `1.1920929E-7`
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
- `var`
- `type`
- `struct`
- `union`
- `variant`
- `enum`
- `flags`
- `opaque`
- `methods`
- `function`
- `async function`
- `external function`
- `foreign function`
- `static_assert(...)`

### 3.1 Visibility

- `public` is supported for exportable ordinary declarations.
- `public` is rejected on `methods` blocks.
- `public` is rejected on ordinary `external` declarations and `static_assert`.
- In external modules, declarations are implicitly exported and `public` is rejected.

### 3.2 Constants and variables

```mt
const WIDTH: int = 1280
var counter: int = 0
var scratch: array[ubyte, 256]
```

Rules:

- `const` requires explicit type and initializer.
- Top-level `var` requires explicit type; initializer is optional.
- Top-level `var` initializer must be static-storage-safe.
- Local declarations:
  - `let` is immutable
  - `var` is mutable
- A local declaration without initializer requires explicit type and must be zero-initializable.
- `let` declarations may use a nullable guard form:

```mt
let window = maybe_window else:
        return 1
```

Rules for `let ... else:`:

- only `let` supports an `else` block
- the initializer must have a nullable type
- an explicit type annotation, if present, must name the non-null success type
- the `else` block must exit control flow (`return`, `break`, `continue`, or another terminating path)

### 3.3 Type aliases

```mt
type Seconds = float
type Callback = fn(level: int, message: cstr) -> void
```

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

`variant` is a tagged union. Each arm may optionally carry named payload fields. Generic variants are supported via type arguments, for example `Maybe[int]`:

```mt
variant Maybe[T]:
    just(value: T)
    nothing

variant Status[T, E]:
    ok(value: T)
    err(error: E)
```

Arm constructors:

- Payload arm: `Token.ident(text = "hello")` — field names with `=`.
- No-payload arm: `Token.eof` — accessed as a bare member expression.

Layout modifiers for structs:

```mt
packed struct Header:
    tag: ubyte

align(16) struct Mat4:
    data: array[float, 16]
```

`align(...)` must be a positive power of two.

### 3.5 Methods

```mt
methods Counter:
    function read() -> int:
        return this.value

    editable function bump() -> void:
        this.value += 1

    static function zero() -> Counter:
        return Counter(value = 0)
```

Kinds:

- `function` (value receiver)
- `editable function` (mutable receiver)
- `static function` (no receiver)

Method capabilities:

- async methods are supported
- generic methods are supported

### 3.6 Functions

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

### 3.7 Extern functions

```mt
external function printf(format: cstr, ...) -> int
```

Rules:

- no body
- variadic `...` supported
- cannot be generic
- cannot be async
- cannot take or return arrays

### 3.8 Foreign functions

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
- `if` / `elif` / `else`
- `match`
- `unsafe`
- `static_assert`
- `for`
- `while`
- `break`
- `continue`
- `return`
- `defer`
- expression statement

### 4.1 If

Condition must be `bool`.

### 4.2 Match

Scrutinee types supported:

- Enum: arm patterns must be members of that enum.
- Variant: arm patterns must be arms of that variant; a payload arm may bind its fields with `as name`.
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

### 4.3 Loops

Single-form `for` supports:

- `start..stop` — exclusive integer range via range expression
- `array[T, N]`
- `span[T]`

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

## 5. Expressions

### 5.1 Primary

- identifier
- literals
- parenthesized expression
- `size_of(T)`
- `align_of(T)`
- `offset_of(T, field)`
- `proc(...) -> T: ...` — anonymous function expression, e.g. `let fn_ptr = proc(x: int) -> int: return x + 1`
- `if cond: a else: b`

### 5.2 Postfix

- member access: `a.b`
- indexing: `a[i]`
- call: `f(x)`
- specialization: `name[T]`, `name[32]`, `mod.name[T]`

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
- `byte`
- `char`
- `byte` `short` `int` `long`
- `ubyte` `ushort` `uint` `ulong`
- `ptr_int` `ptr_uint`
- `float` `double`
- `void`
- `str`
- `cstr`

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
- `str_builder[N]`
- `Task[T]`
- `fn(params...) -> R`
- `proc(params...) -> R`

### 6.3 Nullability

- nullable form: `T?` for pointer-like/null-capable types
- `null` and typed `null[...]` supported
- typed null target must be pointer-like
- in nullable pointer-like contexts, use `null` instead of `zero[ptr[T]]`

### 6.4 Generics

Supported:

- generic structs
- generic functions
- generic foreign functions

Type arguments can be:

- types
- integer literals
- named integer constants

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
- `array[T, N](...)`
- `span[T](data = ..., len = ...)`

For recoverable failures, use `import std.status as status` and the ordinary library type `status.Status[T, E]`. Its `.ok(...)` and `.err(...)` constructors are variant arms, not built-in callables.

For repeated pointer-plus-length span construction, prefer `std.span` helpers like `sp.from_ptr[T](ptr, len)` and `sp.from_nullable_ptr[T](ptr_or_null, len)`.

`read(r)` still explicitly projects a `ref[T]` to its referent value, but ordinary member access and method calls auto-dereference `ref[T]` receivers. That means `handle.field`, `handle.edit_method()`, and `handle.read()` are accepted without writing `read(handle)` first. Calls in the other direction are also lighter now: if a function expects `ref[T]`, passing a mutable addressable `T` borrows it implicitly.

## 8. Strings, C Strings, And Format Strings

String categories:

- `str` (string view)
- `cstr` (C ABI string)
- `str_builder[N]` (fixed-capacity mutable string buffer)

`str_builder[N]` methods:

- `clear()`
- `assign(str)`
- `append(str)`
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

`<<-TAG` and `c<<-TAG` read all following lines until a line containing only the terminator tag, optionally surrounded by spaces. Nonblank content lines are dedented by their shared leading spaces. The trailing newline before the terminator is preserved. Multiline format heredocs are not supported.

Ordinary `"..."` and `c"..."` literals may continue across following indented lines when each continued line starts with the same literal kind and contains nothing else. The segments concatenate exactly with no inserted separator, so any spaces or punctuation between pieces must be written explicitly.

In the VS Code extension, specific heredoc tags opt into embedded highlighting without changing the Milk Tea type: `GLSL`, `VERT`, `FRAG`, `COMP`, `JSON`, `JSONC`, and `SQL`. These still produce ordinary `str` or `cstr` values, and SQL heredocs should still use bound parameters rather than string interpolation.

Format strings have type `str` and are valid anywhere a `str` value is accepted. Interpolated expressions must be one of: `str`, `cstr`, `bool`, a numeric primitive, or an integer-backed enum or flags type. A precision specifier `:.N` is allowed on `float` and `double` interpolations.

The following standard library functions receive special lowering for format strings — they build the formatted output directly without an intermediate allocation:

- `std.fmt.format` — returns `string.String`

## 9. Safety And Conversion Rules

- conditions must be `bool`
- no truthy/falsy integer or pointer coercion
- mixed signed/unsigned integer arithmetic requires an explicit `T<-value` cast
- `%` requires integer-compatible operands
- bitwise operators require matching integer/flags types
- shift operators require integer operands
- safe array indexing requires an addressable array value
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

- `await` is supported inside `if` expressions, `if`/`elif`/`else` bodies and conditions, `while` bodies and conditions, single-form and parallel `for` bodies and iterables, `match` discriminants and arms, `let ... else:` initializers and else bodies, `unsafe` blocks, short-circuit `and`/`or` expressions, and assignment targets
- `defer` is supported in async functions, including cleanup bodies that `await`

## 11. Linting

The linter checks for common issues and style problems without changing program behavior.

### 11.1 Running the linter

```sh
mtc lint path/to/file.mt
mtc lint src/                              # lint all .mt files in a directory
mtc lint --fix path/to/file.mt             # apply auto-fixes in place
mtc lint --select prefer-let,dead-assignment file.mt
mtc lint --ignore shadow file.mt
```

### 11.2 Rules

| Code | Severity | Auto-fix | Description |
|---|---|---|---|
| `unused-import` | warning | yes | Import alias is never referenced |
| `missing-return` | error | — | Function with a non-void return type lacks a guaranteed return on all paths |
| `prefer-let` | warning | yes | `var` binding is never mutated; use `let` instead |
| `dead-assignment` | warning | yes | Assignment result is never read |
| `redundant-else` | warning | yes | `else` block is unnecessary because all prior branches return |
| `unreachable-code` | warning | — | Code after `return`, `break`, or `continue` |
| `useless-expression` | warning | — | Expression statement with no side effects |
| `shadow` | warning | — | Local binding shadows an outer binding with the same name |
| `borrow-and-mutate` | warning | — | Variable is borrowed via `ref_of` or `ptr_of` and also directly mutated |
| `constant-condition` | warning | — | `if` condition is always `true` or always `false` |
| `redundant-null-check` | warning | — | Null check on a value already known to be non-null by flow analysis |
| `loop-single-iteration` | warning | — | `while` loop that always exits after at most one iteration |

### 11.3 Config file

Place `.mt-lint.yml` in the project root (or any ancestor directory):

```yaml
ignore:
  - shadow
  - useless-expression
# select:
#   - prefer-let
#   - missing-return
```

When both `select` and `ignore` are present, `select` takes precedence and `ignore` is unused.

### 11.4 Per-line suppressions

```mt
var count = 0  # lint: ignore
var total = 0  # lint: ignore(prefer-let, dead-assignment)
```

`# lint: ignore` silences all rules on that line. `# lint: ignore(rule1, rule2)` silences only the listed rules.

## 12. Current Unsupported Or Rejected Surfaces

Current implementation rejects:

- generic constraints on type parameters
- interface declarations and interface constraints

## 13. Example

```mt
module demo.main

import std.fmt as fmt

struct Counter:
    value: int

methods Counter:
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

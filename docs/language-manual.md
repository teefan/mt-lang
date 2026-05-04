# Milk Tea Language Manual

This manual documents the Milk Tea language as implemented today in the lexer, parser, semantic checker, and compiler tests.

## 1. Source Files And Modules

Milk Tea source files use the `.mt` extension.

A file can be either:

- an ordinary module (`module ...`)
- an extern module (`extern module ...`)

### 1.1 Ordinary module

```mt
module demo.main

import std.io as io

def main() -> i32:
    return 0
```

### 1.2 Extern module

```mt
extern module std.c.raylib:
    include "raylib.h"
    link "raylib"

    struct Color:
        r: u8
        g: u8
        b: u8
        a: u8

    extern def InitWindow(width: i32, height: i32, title: cstr) -> void
```

Rules:

- In ordinary modules, `import` statements are parsed only at the top after `module`.
- In extern modules, leading `import` statements are allowed inside the extern-module body.
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
def draw_strip() -> void:
    return
```

Rules for documentation comments:

- Only lines that start with `##` are documentation.
- Contiguous `##` lines form one markdown block.
- A blank line breaks attachment.
- Plain `#` comments are ignored by hover documentation.
- Documentation attaches only to declarations (`def`, `struct`, `union`, `enum`, `flags`, `variant`, `type`, `const`, `var`, `let`, `methods`, `opaque`).

### 2.3 Literals

Supported literals:

- integer: `42`, `0xff`, `0b1010`, with `_` separators
- float: `3.14`, `1.2e-3`, `1.1920929E-7`
- string: `"hello"` (`str`)
- cstring: `c"hello"` (`cstr`)
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
- `in`, `out`, `inout` (only valid in foreign-call argument positions)

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
- `def`
- `async def`
- `extern def`
- `foreign def`
- `static_assert(...)`

### 3.1 Visibility

- `pub` is supported for exportable ordinary declarations.
- `pub` is rejected on `methods` blocks.
- `pub` is rejected on ordinary `extern` declarations and `static_assert`.
- In extern modules, declarations are implicitly exported and `pub` is rejected.

### 3.2 Constants and variables

```mt
const WIDTH: i32 = 1280
var counter: i32 = 0
var scratch: array[u8, 256]
```

Rules:

- `const` requires explicit type and initializer.
- Top-level `var` requires explicit type; initializer is optional.
- Top-level `var` initializer must be static-storage-safe.
- Local declarations:
  - `let` is immutable
  - `var` is mutable
- A local declaration without initializer requires explicit type and must be zero-initializable.

### 3.3 Type aliases

```mt
type Seconds = f32
type Callback = fn(level: i32, message: cstr) -> void
```

### 3.4 Struct, union, enum, flags, opaque

```mt
struct Vec2:
    x: f32
    y: f32

union Number:
    i: i32
    f: f32

enum State: u8
    idle = 0
    running = 1

flags Mask: u32
    a = 1 << 0
    b = 1 << 1

opaque SDL_Window

variant Token:
    ident(text: str)
    number(value: i32)
    eof
```

`variant` is a tagged union. Each arm may optionally carry named payload fields. Generic variants are supported via type arguments, for example `Box[i32]`.

Arm constructors:

- Payload arm: `Token.ident(text = "hello")` — field names with `=`.
- No-payload arm: `Token.eof` — accessed as a bare member expression.

Layout modifiers for structs:

```mt
packed struct Header:
    tag: u8

align(16) struct Mat4:
    data: array[f32, 16]
```

`align(...)` must be a positive power of two.

### 3.5 Methods

```mt
methods Counter:
    def read() -> i32:
        return this.value

    edit def bump() -> void:
        this.value += 1

    static def zero() -> Counter:
        return Counter(value = 0)
```

Kinds:

- `def` (value receiver)
- `edit def` (mutable receiver)
- `static def` (no receiver)

Method capabilities:

- async methods are supported
- generic methods are supported

### 3.6 Functions

```mt
def add(a: i32, b: i32) -> i32:
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
extern def printf(format: cstr, ...) -> i32
```

Rules:

- no body
- variadic `...` supported
- cannot be generic
- cannot be async
- cannot take or return arrays

### 3.8 Foreign functions

```mt
foreign def init_window(width: i32, height: i32, title: str as cstr) -> void = c.InitWindow
foreign def load_file_data(file_name: str as cstr, out data_size: i32) -> ptr[u8]? = c.LoadFileData
foreign def close_window(consuming window: Window) -> void = c.CloseWindow
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
- Integer (`i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64`, `isize`, `usize`): arm patterns must be integer literals.

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

`for` supports:

- `start..stop` — exclusive integer range via range expression
- `array[T, N]`
- `span[T]`

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

Unsafe context is required for raw-pointer-level operations such as:

- pointer indexing
- raw dereference
- pointer arithmetic
- pointer casts
- `reinterpret[...]`

## 5. Expressions

### 5.1 Primary

- identifier
- literals
- parenthesized expression
- `sizeof(T)`
- `alignof(T)`
- `offsetof(T, field)`
- `proc(...) -> T: ...`
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
- `i8` `i16` `i32` `i64`
- `u8` `u16` `u32` `u64`
- `isize` `usize`
- `f32` `f64`
- `void`
- `str`
- `cstr`

### 6.2 Type constructors

- `ptr[T]`
- `const_ptr[T]`
- `ref[T]`
- `span[T]`
- `array[T, N]`
- `str_builder[N]`
- `Result[T, E]`
- `Task[T]`
- `fn(params...) -> R`
- `proc(params...) -> R`

### 6.3 Nullability

- nullable form: `T?` for pointer-like/null-capable types
- `null` and typed `null[...]` supported
- typed null target must be pointer-like
- in nullable pointer-like contexts, use `null` instead of `zero[ptr[T]]()`

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

- `ok(value)` / `err(value)`
- `panic(message)`
- `ref_of(x)`
- `const_ptr_of(x)`
- `read(r)`
- `read(p)`
- `ptr_of(x)`
- `T<-value`
- `reinterpret[T](value)`
- `zero[T]()`
- `array[T, N](...)`
- `span[T](data = ..., len = ...)`

For repeated pointer-plus-length span construction, prefer `std.span` helpers like `sp.from_ptr[T](ptr, len)` and `sp.from_nullable_ptr[T](ptr_or_null, len)`.

`read(r)` still explicitly projects a `ref[T]` to its referent value, but ordinary member access and method calls auto-dereference `ref[T]` receivers. That means `handle.field`, `handle.edit_method()`, and `handle.read()` are accepted without writing `read(handle)` first.

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

Format strings have type `str` and are valid anywhere a `str` value is accepted. Interpolated expressions must be one of: `str`, `cstr`, `bool`, a numeric primitive, or an integer-backed enum or flags type. A precision specifier `:.N` is allowed on `f32` and `f64` interpolations.

The following standard library functions receive special lowering for format strings — they build the formatted output directly without an intermediate allocation:

- `std.fmt.string` — returns `string.String`
- `std.io.print` / `std.io.println`
- `std.io.write_error` / `std.io.write_error_line`

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
async def child() -> i32:
    return 41

async def parent() -> i32:
    let v = await child()
    return v + 1
```

Rules:

- async function return type is lifted to `Task[T]`
- `await` is only allowed inside async functions
- `async main` requires importing `std.async` or `std.libuv.async`
- `async main` pre-lift return type must be `i32` or `void`

Current async limitations:

- `await` is supported inside `if` expressions, `if`/`elif`/`else` bodies and conditions, `while` bodies and conditions, `for` bodies and iterables, `match` discriminants and arms, `unsafe` blocks, short-circuit `and`/`or` expressions, and assignment targets

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
    value: i32

methods Counter:
    edit def bump() -> void:
        this.value += 1

    def read() -> i32:
        return this.value

def main() -> i32:
    var c = Counter(value = 0)

    for i in 0..3:
        c.bump()

    let text = f"count=#{c.read()}"
    return 0
```

# Milk Tea

This README is the primary, implementation-focused language reference for the project.
It is the preferred first entry point for getting to know the language.

If this file conflicts with `docs/language-manual.md`, the manual wins.
`docs/language-design.md` is for design direction and rationale, not the authoritative implementation spec.

Package manifests, build workflow, and run workflow are documented separately in `docs/build-guide.md`.

## 1. File Kinds And Layout

- Source files use the `.mt` extension.
- Ordinary files are the normal source form. They have no module header; module identity is inferred from the file path.
- Raw ABI binding files use a leading `external` header.
- External files are the dedicated raw ABI surface, usually for generated or low-level `std.c.*` bindings.
- Module lookup resolves `a.b.c` to `a/b/c.mt`.
- Inside a package, the file path relative to `package.source_root` defines the module name; platform-specific files such as `name.linux.mt` still map to module `name`.
- In ordinary files, `import` statements appear only at the top.
- In external files, leading `import` statements are allowed after `external`.
- Only external files accept `include`, `link`, and `compiler_flag` directives.
- After those imports and directives, external files stay narrow: they contain raw ABI declarations, not ordinary module logic.

Blocks are indentation-based:

- `:` starts a block.
- Indentation must be spaces only.
- Tabs are rejected.
- Indentation must be a multiple of 4 spaces.
- Indentation can increase by only one level at a time.
- Newlines end statements except inside `()` and `[]`.

Comments:

- `#` starts a line comment.
- `##` starts documentation comments attached to the next declaration if no blank line intervenes.

## 2. Literals And Tokens

Supported literals:

- integers: `42`, `0xff`, `0b1010`, `_` separators allowed
- floats: `3.14`, `1.2e-3`
- booleans: `true`, `false`
- string: `"hello"` -> `str`
- cstring: `c"hello"` -> `cstr`
- heredoc string: `<<-TAG ... TAG`
- heredoc cstring: `c<<-TAG ... TAG`
- format string: `f"count=#{count}"`
- `null`, including typed forms like `null[ptr[char]]` when context does not determine the target type

Common punctuation and operators:

- delimiters: `(` `)` `[` `]`
- access and separators: `:` `,` `.`
- type markers: `->` `?`
- arithmetic: `+ - * / %`
- bitwise: `~ & | ^ << >>`
- comparison: `== != < <= > >=`
- assignment: `= += -= *= /= %= &= |= ^= <<= >>=`
- variadic marker: `...`
- word operators: `and`, `or`, `not`

## 3. Top-Level Declarations

Supported top-level declarations:

- `const`
- `var`
- `type`
- `interface`
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

File-kind note:

- Ordinary files may use the full declaration surface above.
- External files are intentionally narrower: after optional imports and directives, they allow only `const`, `type`, `struct`, `union`, `enum`, `flags`, `opaque`, and `external function`, plus `packed` / `align(...)` struct forms.

Visibility:

- `public` is allowed on exportable ordinary declarations.
- `public` is rejected on `methods` blocks.
- `public` is rejected on ordinary `external` declarations and `static_assert`.
- In external files, declarations are implicitly exported and `public` is rejected.

## 4. Variables And Guards

- `const` requires an explicit type and initializer.
- Top-level `var` requires an explicit type. Its initializer is optional but must be static-storage-safe when present.
- Local `let` is immutable.
- Local `var` is mutable.
- A local declaration without an initializer requires an explicit type and must be zero-initializable.

Guard form:

```mt
let value = maybe_value else:
    return 1

let parsed = parse(input) else as error:
    return error

let _ = initialize() else:
    return 1
```

Rules for `let ... else:`:

- Only `let` supports an `else` block.
- The initializer must have type `T?` or `std.status.Status[T, E]`.
- For `T?`, the bound name has type `T`.
- For `std.status.Status[T, E]`, the bound name is `ok.value`.
- `else as error:` optionally binds the `err.error` value.
- `let _ = expr else:` checks success without binding a name.
- The `else` block must terminate control flow.

## 5. Data Declarations

Examples:

```mt
type Seconds = float

struct Vec2:
    x: float
    y: float

packed struct Header:
    tag: ubyte

align(16) struct Mat4:
    data: array[float, 16]

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

Rules:

- `struct` and `opaque` may declare nominal interface conformance with `implements`.
- `variant` arms may carry named payload fields.
- Payload arm construction uses named fields: `Token.ident(text = "hello")`.
- No-payload arms are bare member expressions: `Token.eof`.
- `align(...)` must be a positive power of two.

Generic variants and structs are supported, for example `Maybe[int]`.

## 6. Interfaces And Methods

Interface example:

```mt
public interface Damageable:
    editable function take_damage(amount: int) -> void
    function is_alive() -> bool
```

Interface rules:

- Interface bodies contain `function`, `editable function`, or `static function` signatures.
- Interface methods may not be `async` or generic.
- Interface methods do not have bodies.
- Bare interface names are not runtime storage types.
- Interfaces are used by `implements` and constrained generics, not as runtime value types.

Method kinds:

- `function` -> value receiver
- `editable function` -> mutable receiver
- `static function` -> no receiver

Method notes:

- Async methods are supported.
- Generic methods are supported.
- There is no constructor keyword. Names like `init` and `default` are ordinary static methods.

## 7. Functions, Externals, And Foreign Functions

Ordinary functions:

- Parameters must be typed.
- Parameters are non-rebindable.
- Return type defaults to `void` if omitted.
- Generic functions are supported.
- Generic function and method type parameters may use `implements` and `defaults` constraints.

External functions:

```mt
external function printf(format: cstr, ...) -> int
```

Raw `std.c.*` modules usually group many `external function` declarations inside an external file, but `external function` is also allowed in ordinary files for small manual ABI bridges.

Rules:

- No body.
- Variadic `...` is supported.
- Cannot be generic.
- Cannot be async.
- Cannot take arrays.
- Cannot take `ref` parameters.
- Cannot take `proc` parameters.
- Cannot return arrays.

Foreign functions:

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

Boundary projection syntax:

- `name: PublicType as BoundaryType`

Foreign-function rules:

- `as` is only allowed on plain and `in` parameters.
- `in`, `out`, and `inout` are declared on the parameter, not at the call site.
- Legacy call syntax like `load_file_data(path, out size)` or `inspect(in value)` is rejected.
- `consuming` foreign functions must return `void`.
- Consuming foreign calls must appear as top-level expression statements.
- A consuming argument must be a bare nullable local or parameter binding.

## 8. Statements And Control Flow

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

Rules:

- Conditions must be `bool`.
- There is no truthy or falsy coercion from integers or pointers.

`match` supports:

- enum scrutinees
- variant scrutinees
- integer scrutinees

`match` rules:

- Enum and variant matches must be exhaustive unless `_` is present.
- Integer matches require `_`.
- Variant payload arms may bind with `as name`.

Loop forms:

- `for i in 0..count:` for exclusive integer ranges
- `for item in items:` for arrays and spans
- `for left, right in xs, ys:` for parallel array/span iteration
- Parallel `for` does not accept ranges.

`defer`:

- `defer expr`
- `defer:` block form
- `return` is not allowed inside defer blocks.

`unsafe` is required for:

- pointer indexing
- raw pointer dereference
- pointer arithmetic
- pointer casts
- `reinterpret[...]`

Range index assignment is supported:

```mt
buf[0..3] = (1.0, 2.0, 3.0)
```

Rules:

- The bounds must be integer literals.
- The range is start-inclusive and end-exclusive.
- The right-hand side must be an expression list with exactly matching width.

## 9. Expressions And Operators

Primary expressions:

- identifiers
- literals
- parenthesized expressions
- `size_of(T)`
- `align_of(T)`
- `offset_of(T, field)`
- `proc(...) -> T: ...`
- `if cond: a else: b`

Postfix forms:

- member access: `a.b`
- indexing: `a[i]`
- call: `f(x)`
- specialization: `name[T]`, `name[32]`, `mod.name[T]`

Operator precedence, low to high:

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

## 10. Type System

Primitive types:

- `bool`
- `byte`, `short`, `int`, `long`
- `ubyte`, `ushort`, `uint`, `ulong`
- `char`
- `ptr_int`, `ptr_uint`
- `float`, `double`
- `void`
- `str`
- `cstr`

Type constructors:

- `ptr[T]`
- `const_ptr[T]`
- `ref[T]`
- `span[T]`
- `array[T, N]`
- `str_builder[N]`
- `Task[T]`
- `fn(params...) -> R`
- `proc(params...) -> R`

Nullability:

- Nullable form is `T?` for pointer-like types.
- Use `null` for absence.
- In nullable pointer-like contexts, prefer `null` over `zero[ptr[T]]`.
- `ref[T]` is non-null and cannot be nullable.

Generics:

- Generic structs, variants, functions, methods, and foreign functions are supported.
- Generic type parameter constraints use `implements` and `defaults` on structs, variants, functions, and methods.
- Multiple interface constraints are joined with `and`.
- `defaults` requires an accessible zero-argument `T.default() -> T`.
- Current type parameters can be used as type expressions for associated function calls in generic bodies, for example `T.default()` or `T.tag()`.

## 11. Built-In Callable Surface

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
- `array[T, N](...)`
- `span[T](data = ..., len = ...)`

Reference and pointer notes:

- `read(ref_value)` explicitly projects the referent value.
- Member access and method calls auto-dereference `ref[T]` receivers.
- Passing a mutable addressable `T` to a parameter of type `ref[T]` implicitly borrows it.

## 12. Strings, Text, And Builders

Text categories:

- `str` -> string view
- `cstr` -> C ABI string
- `str_builder[N]` -> fixed-capacity mutable UTF-8 text buffer

`str_builder[N]` methods:

- `clear()`
- `assign(str)`
- `append(str)`
- `len()`
- `capacity()`
- `as_str()`
- `as_cstr()`

Format strings:

- `f"count=#{count}"` has type `str`.
- Allowed interpolations: `str`, `cstr`, `bool`, numeric primitives, integer-backed enums and flags.
- Float and double interpolations support `:.N` precision.
- `std.fmt.format(...)` receives special lowering and returns `string.String`.

Heredoc notes:

- `<<-TAG ... TAG` -> `str`
- `c<<-TAG ... TAG` -> `cstr`
- Content is dedented by shared leading spaces of nonblank lines.
- The trailing newline before the terminator is preserved.

## 13. Safety And Conversion Rules

- Conditions must be `bool`.
- No truthy or falsy coercion.
- Mixed signed and unsigned integer arithmetic requires an explicit cast.
- `%` requires integer-compatible operands.
- Bitwise operators require matching integer or flags types.
- Shift operators require integer operands.
- Safe array indexing requires an addressable array value.
- Pointer indexing requires `unsafe`.
- `read(ptr)` requires `unsafe`.
- Pointer casts require `unsafe`.
- `reinterpret[...]` requires `unsafe` and non-array concrete sized types.

## 14. Async

Example:

```mt
async function child() -> int:
    return 41

async function parent() -> int:
    let v = await child()
    return v + 1
```

Rules:

- `async function` lifts its declared return type to `Task[T]`.
- `await` is only allowed inside async functions.
- `async main` is compiler-bootstrapped.
- `async main` pre-lift return type must be `int` or `void`.
- `aio.wait(...)` and `aio.run(...)` accept either zero-arg task roots or direct task expressions.

Supported `await` contexts include:

- plain expression positions
- `if` expressions
- `if` / `elif` / `else` bodies and conditions
- `while` bodies and conditions
- single-form and parallel `for` bodies and iterables
- `match` discriminants and arms
- `let ... else:` initializers and else bodies
- `unsafe` blocks
- short-circuit `and` / `or`
- assignment targets
- `defer` cleanup bodies inside async functions

## 15. Common Rejections

Current implementation rejects:

- interface methods with `async` or generic signatures
- runtime interface value types such as `Damageable` as a field, local, parameter, or return type
- legacy `in` / `out` / `inout` markers at call sites
- consuming foreign calls used inside larger expressions
- external functions that are generic, async, or array-taking / array-returning
- ordinary truthy or falsy conditions on integers and pointers

## 16. Minimal Example

```mt
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

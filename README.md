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
- Newlines end statements except inside `()` and `[]`, or when the previous physical line ends with a binary operator such as `+`, `and`, or `==`.
- Comma-separated lists inside `()` and `[]` accept trailing commas. Prefer them for multiline parameters, arguments, and type lists.

Long expressions should usually be wrapped with delimiters, following the same broad shape as Python's implicit line joining:

```mt
let total = (
    subtotal
    + tax
    - discount
)
```

Milk Tea also accepts operator-led continuation when the previous line ends with a binary operator:

```mt
let total = subtotal +
    tax -
    discount
```

This also applies to range expressions:

```mt
let values = 1 ..
    4
```

Do not rely on starting the next physical line with the operator; wrap the expression in `()` instead if that layout reads better.

Comments:

- `#` starts a line comment.
- `##` starts documentation comments attached to the next declaration if no blank line intervenes.

## 2. Literals And Tokens

Supported literals:

- integers: `42`, `0xff`, `0b1010`, `_` separators allowed
- floats: `3.14`, `1.2e-3`, `1.0f` (float suffix), `1.0d` (double suffix)
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

- `const` (expression form and block-bodied form with `->`)
- `const function` — compile-time-evaluable function, callable from compile-time and runtime
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
- `when` (compile-time conditional; may appear at module level or inside function bodies)

File-kind note:

- Ordinary files may use the full declaration surface above.
- External files are intentionally narrower: after optional imports and directives, they allow only `const`, `type`, `struct`, `union`, `enum`, `flags`, `opaque`, and `external function`. External files cannot declare new attributes, but supported attribute applications such as `@[packed]` and `@[align(...)]` may still appear on declarations that accept them.
- `event` declarations are not allowed in external files.

Visibility:

- `public` is allowed on exportable ordinary declarations.
- `public` is rejected on `extending` blocks.
- `public` is rejected on ordinary `external` declarations and `static_assert`.
- In external files, declarations are implicitly exported and `public` is rejected.

## 4. Variables And Guards

- `const` requires an explicit type and initializer. A block-bodied form `const NAME -> TYPE:` followed by an indented block is also supported; the block is evaluated at compile time and must end with a `return`.
- Top-level `var` requires an explicit type. Its initializer is optional but must be static-storage-safe when present.
- Local `let` is immutable.
- Local `var` is mutable.
- A local declaration without an initializer requires an explicit type and must be zero-initializable.

Guard form:

```mt
let value = maybe_value else:
    return 1

var runtime = maybe_runtime else:
    return 1

let parsed = parse(input) else as error:
    return error

let _ = initialize() else:
    return 1
```

Tuple destructuring:

```mt
let (a, b) = pair()
let (x, y) = (1, 2)
```

Struct destructuring:

```mt
struct Vec2:
    x: float
    y: float
let p = Vec2(x = 1.0, y = 2.0)
let Vec2(x, y) = p
```

Rules for `let ... else:` and `var ... else:`:

- Both `let` and `var` support an `else` block.
- The initializer must have type `T?`, `Option[T]`, or `Result[T, E]`.
- For `T?`, the bound name has type `T`.
- For `Option[T]`, the bound name is `some.value`.
- For `Result[T, E]`, the bound name is `success.value`.
- `else as error:` optionally binds the `failure.error` value.
- `let _ = expr else:` checks success without binding a name.
- The `else` block must terminate control flow.

Postfix Result propagation:

```mt
let parsed = parse(input)?
let lowered = lower(parsed)?
return Result[Output, Error].success(value= lowered)
```

- `expr?` requires `Result[T, E]` with a non-`void` success type.
- On success, `expr?` evaluates to the unwrapped `T`.
- On failure, `expr?` returns `Result[_, E].failure(error= ...)` from the enclosing function or proc.
- As an expression statement, `expr?` also accepts `Result[void, E]`; success continues and failure returns early.
- `expr?` is only allowed inside function and proc bodies.
- Inside `async` functions, failure completes the task early with the same `Result` failure.
- `expr?` is not allowed inside `defer` blocks.
- The enclosing function or proc must return `Result[_, E]` with the same error type `E`.
- `let _ = expr else:` is still useful when you need an explicit `else` block or `else as error:` binding.

Callable and `ref[...]` rules:

- Plain stored `ref[T]` values are rejected in constants, module variables, and nested local storage such as arrays or other generic containers.
- In struct or union fields, bare `ref[T]` auto-generates an implicit lifetime parameter. The struct becomes non-owning, inheriting ref-like restrictions: allowed as function params and local `let` variables, rejected as returns and module storage. Explicit lifetime parameters (`struct Cursor[@a]: data: ref[@a, span[ubyte]]`) are still supported when the lifetime needs to be shared across multiple fields.
- Ordinary local bindings may still hold a direct `ref[T]` value, for example `let handle = ref_of(counter)`.
- `fn(...)` and `proc(...)` parameter types may use `ref[...]` directly in parameter position.
- Stored callable values may use `ref[...]` only in direct callable parameter positions. This includes `fn(...)` values and `proc(...)` closure values stored in locals, struct fields, and generic containers such as `array[...]`.
- Stored callable values may not use `ref[...]` in return types.
- Stored callable values may not nest `ref[...]` anywhere except direct callable parameter positions.
- External functions still cannot take `ref[...]` parameters, and ordinary functions still cannot return `ref[...]`.
- `proc` captures are value captures. A captured local is not a mutable alias back to the outer binding. Any storable type may be captured, including scalars, arrays, structs, and other `proc` values. Captured `proc` values participate in the ref-counted lifecycle: the capturing proc retains the captured proc on creation and releases it when the env is freed.
- `ref[T]` values are not capturable by design since they are non-owning.
- Shared mutable proc state should use explicit storage such as `std.cell.alloc[T](...)` or other explicit pointer-backed state, not implicit mutable capture.

## 5. Data Declarations

Examples:

```mt
type Seconds = float

struct Vec2:
    x: float
    y: float

@[packed]
struct Header:
    tag: ubyte

@[align(16)]
struct Mat4:
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
- `attribute[target, ...]` declares reusable declaration attributes for `struct`, `field`, and `callable` targets.
- Attributes are applied with one or more leading `@[name(...)]` blocks. Built-in `packed`, `align(bytes)`, and `deprecated(message)` are predefined attributes.
- `variant` arms may carry named payload fields.
- Payload arm construction uses named fields: `Token.ident(text = "hello")`.
- No-payload arms are bare member expressions: `Token.eof`.
- `enum` and `flags` backing types must be integer primitives.
- `enum` and `flags` members must be compile-time integer constants.
- `flags` members may reference earlier members to spell composite aliases such as `read_write = Permission.read | Permission.write`.
- `align(...)` must be a positive power of two.
- Compile-time reflection over validated attributes uses `has_attribute`, `attribute_of`, `attribute_arg[T]`, `field_of`, and `callable_of`.
- `field_of(...)`, `callable_of(...)`, and `attribute_of(...)` produce compile-time handle values with source-visible handle types `field_handle`, `callable_handle`, and `attribute_handle`.
- The current C backend lowers `packed` / `align(...)` attributes with GNU-style `__attribute__((...))`, so these layout controls currently require a Clang/GCC-family compiler. On Windows that means Clang or GCC-family toolchains such as MinGW; `cl.exe` is not a supported backend for these attributes today. On wasm/browser targets the same feature works through Emscripten `emcc`, which is Clang-based.

Generic variants and structs are supported, for example `Option[int]`.

## 6. Interfaces And Methods

Interface example:

```mt
public interface Damageable:
    editable function take_damage(amount: int) -> void
    function is_alive() -> bool
```

Interface rules:

- Interface bodies contain `function`, `editable function`, or `static function` signatures.
- Generic interfaces are supported: `interface Mapper[T]: function map(x: T) -> T`.
- Interface methods may not have their own type params — `T` comes from the interface.
- Interface methods may not be `async`.
- Interface methods do not have bodies.
- Bare interface names are not runtime storage types.
- Interfaces are used by `implements` and constrained generics, not as runtime value types.
- Runtime interface values use `dyn[InterfaceName]` — a fat pointer carrying a data pointer and a vtable pointer. Construct with `adapt[Interface](value: ref[T])`, which verifies `T implements Interface` at compile time.
- Generic interfaces instantiated through `dyn` must be fully specified: `dyn[Mapper[int]]` is valid; `dyn[Mapper]` is rejected.
- Conformance with generic interfaces uses type substitution: `struct Foo implements Mapper[int]` checks that `Foo`'s methods match `Mapper`'s methods with `T` replaced by `int`.

Method kinds:

- `function` -> value receiver
- `editable function` -> editable receiver
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
- Generic function and method type parameters may use `implements` constraints.

`const function`:

A `const function` is evaluable at compile time. Its body follows the same restrictions as a block-bodied `const`. When called from a compile-time context (`const`, `when`, `inline if`, `inline for`), the call is constant-folded:

```mt
const function square(x: int) -> int:
    return x * x

const RESULT: int = square(5)   # folded to 25 at compile time
```

`const function` also generates a normal runtime function, callable from ordinary runtime code.

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
- Calls may pass enum or flags values to same-width fixed-width integer parameters without an explicit cast for C ABI interop.

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
- `if` / `else if` / `else`
- `match`
- `unsafe`
- `static_assert`
- `for`
- `while`
- `when` — compile-time conditional; only the chosen branch is type-checked and emitted
- `inline for` — loop over a compile-time-known array, unrolled at compile time
- `inline while` — loop with a compile-time-known condition, unrolled at compile time
- `inline match` — match with a compile-time-known scrutinee, unrolled at compile time
- `inline if` — if with a compile-time-known condition; only the chosen branch is type-checked and emitted
- `pass`
- `break`
- `continue`
- `return`
- `defer`
- `emit` — only inside `const function` or `inline for/while/if/match` bodies
- expression statement

Rules:

- Conditions must be `bool`.
- There is no truthy or falsy coercion from integers or pointers.
- `pass` is an explicit no-op statement for intentionally empty block bodies.

`match` supports:

- enum scrutinees
- variant scrutinees
- integer scrutinees

`match` rules:

- Enum and variant matches must be exhaustive unless `_` is present.
- Integer matches require `_`.
- Variant payload arms may bind with `as name`.
- Variant payload arms may destructure fields inline with struct patterns: `Variant.arm(field > 0, other)` — comparisons are guards (arm skipped if false), identifiers are bindings (field becomes a local), and `field = value` is an equality guard.

```mt
match token:
    Token.ident(text):
        use_name(text)
    Token.number as n:
        use_value(n.value)
    Token.eof:
        return
```

Struct pattern rules:

- Guards (`hp > 0`, `level >= 3`) skip the arm if the condition is false; the match tries the next arm.
- Equality patterns (`kind = Kind.boss`) skip the arm if the field does not equal the value.
- Bindings (`position`) create immutable local variables bound to the field value.
- Guards and equality patterns are refutable: they do not count toward exhaustiveness. Exception: when equality patterns for an enum-typed field collectively cover every member of the enum, the arm is considered exhaustive.
- For variant payload arms, struct patterns compose with `as name` bindings.

Loop forms:

- `for i in 0..count:` for exclusive integer ranges
- `for item in items:` for arrays, spans, and custom iterables
- Custom iterable protocol: `items.iter()` must take no arguments, be a non-editable method, and return the iterator value.
- Iterator forms: either `next() ->` nullable pointer-like item, or `next() -> bool` together with `current() -> T`.
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

Compile-time control flow:

`when` evaluates its discriminant at compile time and emits only the chosen branch:

```mt
when TARGET_OS:
    TargetOs.linux:
        return open_linux(path)
    TargetOs.windows:
        return open_windows(path)
```

- The discriminant must be a compile-time constant.
- Only the chosen branch is type-checked and lowered.
- An `else` branch is required unless the discriminant is an enum and every member is covered.
- `when` may appear at module level to conditionally include declarations.

`inline for` unrolls a loop over a compile-time-known array:

```mt
inline for field in fields_of(Particle):
    static_assert(field.type == float, "Particle fields must be float")
```

- The iterable must be a compile-time-known array (from reflection builtins or a literal array).

`inline while` unrolls a loop with a compile-time-known condition:

```mt
inline while n < 1024:
    n = n * 2
```

- The condition must be a compile-time constant. The loop unrolls to a fixed number of iterations.

`inline match` unrolls a match with a compile-time-known scrutinee; only the chosen arm emits code. It is not required to be exhaustive.

`inline if` branches on a compile-time-known boolean condition:

```mt
const DEBUG_RENDER: bool = false

function draw() -> void:
    inline if DEBUG_RENDER:
        debug_overlay()
```

- The condition must be a compile-time constant.
- Only the chosen branch is type-checked and emitted. The dead branch may reference types and symbols that do not exist.
- `inline if` supports `else` and `else if` branches; the chosen branch follows the same dead-elimination rule.

## 9. Expressions And Operators

Primary expressions:

- identifiers
- literals
- parenthesized expressions
- tuple literal: `(a, b)` — positional; `(x = 1, y = 2)` — named
- `size_of(T)`
- `align_of(T)`
- `offset_of(T, field)`

`size_of` and `offset_of` accept compile-time expressions for the type and field arguments respectively, enabling generic per-field introspection through `inline for`:

```mt
inline for field in fields_of(Point):
    let s = size_of(field.type)
    let o = offset_of(Point, field)
```
- `proc(...) -> T: ...`
- `proc(...) -> T: expr` for a single expression body, implicitly returned
- `if cond: a else: b`

Postfix forms:

- member access: `a.b`
- indexing: `a[i]`
- call: `f(x)`
- partial field update: `v.with(x = 10.0)` — returns a copy with specified fields replaced
- specialization: `name[T]`, `name[32]`, `mod.name[T]`
- explicit specialization is only accepted on bare or module-qualified names; `value.member[32](...)` remains indexed-call syntax, so value-member calls rely on inference instead of explicit literal specialization

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

Native type operators:

- Vectors (`vecN`/`ivecN`): `+`, `-`, `*` (component-wise) with same-type vectors; `*`, `/` with scalar; unary `-`
- Matrices (`matN`): `+`, `-` with same-type matrices; `*`, `/` with scalar; unary `-`
- Quaternions (`quat`): `+`, `-`, `*` (component-wise) with same-type quaternions; unary `-`

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
- `vec2`, `vec3`, `vec4` — float vectors with `.x` `.y` `.z` `.w` fields
- `ivec2`, `ivec3`, `ivec4` — integer vectors with `.x` `.y` `.z` `.w` fields
- `mat3`, `mat4` — column-major matrices; `mat3` has `vec3` columns `.col0`–`.col2`, `mat4` has `vec4` columns `.col0`–`.col3`
- `quat` — quaternion with `.x` `.y` `.z` `.w` fields (layout-compatible with `vec4`)

Native vector, matrix, and quaternion types support aggregate construction with named fields, same as struct literals. Omitted fields default to zero.

```mt
let direction = vec3(x = 1.0, y = 0.0, z = 0.0)
let identity = mat4(
    col0 = vec4(x = 1.0, y = 0.0, z = 0.0, w = 0.0),
    col1 = vec4(x = 0.0, y = 1.0, z = 0.0, w = 0.0),
    col2 = vec4(x = 0.0, y = 0.0, z = 1.0, w = 0.0),
    col3 = vec4(x = 0.0, y = 0.0, z = 0.0, w = 1.0),
)
let q = quat(x = 0.0, y = 0.0, z = 0.0, w = 1.0)
```

Primitive type names are reserved. They cannot be reused for value bindings, parameters, locals, import aliases, or type parameters.

Type constructors:

- `ptr[T]`
- `const_ptr[T]`
- `ref[T]`
- `span[T]`
- `array[T, N]`
- `str_buffer[N]`
- `Task[T]`
- `Option[T]`
- `Result[T, E]`
- `fn(params...) -> R`
- `proc(params...) -> R`
- `SoA[T, N]` — Structure-of-Arrays: each struct field becomes a separate array of length `N`; access `soa[i].field` reads from column `field` at row `i`
- `dyn[InterfaceName]` — runtime interface value (fat pointer: `{ void* data, void* vtable }`). Constructed via `adapt[Interface](value: ref[T])`. @see §6.
- `(T, U)` — tuple type. Positional fields auto-named `_0`, `_1`. Named fields use `(x = T, y = U)`. Copy by value, returns supported.

When a `span[T]` is expected, an addressable `array[T, N]` value may be passed directly via implicit boundary coercion. For explicit conversion, `array.as_span()` returns `span[T]` without requiring a boundary context.

Nullability:

- Nullable form is `T?` for pointer-like types.
- Use `null` for absence.
- In nullable pointer-like contexts, prefer `null` over `zero[ptr[T]]`.
- `ref[T]` is non-null and cannot be nullable.

Generics:

- Generic structs, variants, functions, methods, and foreign functions are supported.
- Generic interfaces are supported: `interface Mapper[T]: function map(x: T) -> T`.
- Generic type parameter constraints use `implements` on structs, variants, interfaces, functions, and methods.
- `implements` is the interface constraint kind.
- Multiple interface constraints are joined with `and`.
- There are no separate `hashes` or `equates` constraints. Generic bodies that call `hash[T](...)`, `equal[T](...)`, or `order[T](...)` rely on specialization-time checking of the canonical associated functions.
- Current type parameters can be used as type expressions for associated function calls in generic bodies, for example `T.default()` or `T.tag()`.
- Generic value parameters use the form `[N: int]` to declare a compile-time integer usable in expressions. The call site specializes with a literal: `int_with_bits[64]`.
- `type` is a built-in type name representing the type of types. A function may return `type` to pick a type at compile time from its value parameters.

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
- `hash[T](value)`
- `equal[T](left, right)`
- `order[T](left, right)`
- `array[T, N](...)`
- `span[T](data = ..., len = ...)`
- `get(coll, index)` — recoverable array/span indexing returning `ptr[T]?`; null on out‑of‑bounds instead of aborting
- `adapt[I](value)` — constructs a `dyn[I]` runtime interface value; verifies `value`'s type implements interface `I` at compile time

Reference and pointer notes:

- `read(ref_value)` explicitly projects the referent value. Use `read(handle) = value` to write through a bare `ref[T]` value.
- Member access and method calls auto-dereference `ref[T]` receivers. For mutable field access through `ref[Struct]`, use `handle.field += x` directly — no `read()` needed.
- Passing a mutable addressable `T` to a parameter of type `ref[T]` implicitly borrows it.
- `hash[T](value)`, `equal[T](left, right)`, and `order[T](left, right)` lower to `T.hash(...)`, `T.equal(...)`, and `T.order(...)` associated functions. Each argument must be a safe stored `T` lvalue that can be borrowed, or an existing `ref[T]`, `ptr[T]`, or `const_ptr[T]`.
- `T.order(left: const_ptr[T], right: const_ptr[T]) -> int` returns a negative value when `left < right`, `0` when equal, and a positive value when `left > right`.
- There are no separate `hashes` or `equates` constraints; the builtins themselves force those hook requirements at specialization time.
- There is no separate `defaults` constraint. A generic body that uses `default[T]` relies on specialization-time checking that `T.default()` exists.

Compile-time reflection builtins:

- `field_of(T, name)` — returns a `field_handle` for the named field of `T`.
- `callable_of(T, name)` — returns a `callable_handle` for the named callable of `T`.
- `attribute_of(T, name)` — returns an `attribute_handle` for the named attribute on `T`.
- `has_attribute(T, name)` — returns `bool`; true if `T` has the named attribute applied.
- `attribute_arg[T]` — returns the `T`-typed argument of a resolved attribute handle.
- `fields_of(T)` — returns `array[field_handle, N]` of all fields of struct `T`, in declaration order.
- `members_of(E)` — returns `array[member_handle, N]` of all members of enum or variant `E`.
- `attributes_of(T)` — returns `array[attribute_handle, N]` of all attributes on `T`.
- `attributes_of(T, name)` — returns `array[attribute_handle, N]` of attributes whose kind matches `name`.

Handle types expose: `field_handle` has `.name` and `.type`; `member_handle` has `.name` and optionally `.value`; `attribute_handle` provides access to attribute arguments.

### Standard library

Core modules in `std/`:

- `std.linear_algebra` — extends native vector/matrix/quaternion types with `dot`, `cross`, `length`, `normalized`, `lerp`, `identity`, `transpose`, `conjugate` (pure Mt, no C dependency beyond `std.math` for `sqrt`)
- `std.graph.Graph[T]` — adjacency-list graph with `add_node`, `add_edge`, `has_edge`, `remove_edge`, `neighbors`, `bfs`, `dfs`, `toposort`; directed or undirected; `compile()` converts to CSR-based `DenseGraph[T]` for O(degree) neighbor iteration
- `std.str` — extends `str` with `byte_at`, `equal`, `starts_with`, `ends_with`, `find_substring`, `is_valid_utf8`, `slice`, `to_cstr`, `hash`, `order`
- `std.hash` — extends primitive types (`int`, `uint`, `bool`, `float`, `double`, `char`) with canonical `hash`/`equal`/`order` hooks; import once to use primitives as Map/Set/BinaryHeap/OrderedMap keys. Also provides generic `hash_struct[T]`, `equal_struct[T]`, `order_struct[T]` using compile-time reflection.
- `std.cstring` — C string helpers (`cstr_len`, `cstr_as_str`)
- `std.math` — `sqrt`, `sin`, `cos`, `abs`, `pow`, etc. via C math
- `std.encoding` — UTF-8 validation (`is_valid_utf8`, `utf8_codepoint_count`, `decode_utf8_codepoint`, `utf8_overlong_check`)
- `std.string.String` — growable owned UTF-8 text
- `std.mem.heap`, `std.mem.arena`, `std.mem.pool`, `std.mem.stack` — allocators
- `std.async` — task runtime (`sleep`, `work`, `completed`, `result`, `wait`, `run`)

**Collections**: `std.vec.Vec[T]`, `std.deque.Deque[T]`, `std.map.Map[K,V]`, `std.set.Set[T]`, `std.ordered_map.OrderedMap[K,V]`, `std.ordered_set.OrderedSet[T]`, `std.binary_heap.BinaryHeap[T]`, `std.priority_queue.PriorityQueue[T]`, `std.linked_map.LinkedMap[K,V]`, `std.linked_set.LinkedSet[T]`, `std.counter.Counter[T]`, `std.multiset.MultiSet[T]`, `std.queue.Queue[T]`, `std.stack.Stack[T]`

**Serialization**: `std.json`, `std.toml`, `std.uri`, `std.serialize`

**System**: `std.time`, `std.fs`, `std.path`, `std.process`, `std.cli`, `std.stdio`, `std.terminal`

**Concurrency**: `std.sync`, `std.thread`, `std.jobs`

**AI/State**: `std.fsm` (finite state machine), `std.goap` (goal-oriented action planning), `std.behavior_tree`

**Networking**: `std.http`, `std.tls`, `std.net` (see also `std.net.manager`, `std.net.discovery`)

**Compression**: `std.gzip`, `std.tar`

**Other**: `std.bytes`, `std.ctype`, `std.asset_pack`, `std.cell`

See module source for full method surface. Iterator forms:
- Pointer-returning (`next() -> nullable ptr[T]`): `Vec`, `Deque`, `BinaryHeap`/`PriorityQueue`/`OrderedSet` (read-only), `OrderedMap.keys`/`Map.keys`/`Set`/`LinkedMap.keys`/`LinkedSet`/`Counter.keys`/`MultiSet.values`, `Queue`/`Stack` (mutable)
- `next() -> bool` + `current()`: `OrderedMap.entries`/`iter`, `Map.entries`/`iter`, `LinkedMap.entries`/`iter`, `Counter.counts`/`entries`/`iter`, `MultiSet.entries`/`iter`, `SnapshotValues`/`SnapshotEntries`

## 12. Strings, Text, And Builders

Text categories:

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

Format strings:

- `f"count=#{count}"` has type `str`.
- Allowed interpolations: `str`, `cstr`, `bool`, numeric primitives, integer-backed enums and flags, plus types implementing `format_len() -> ptr_uint` and `append_format(output: ref[std.string.String]) -> void`.
- `f"..."` is a borrowed temporary on the stack — it cannot be returned from a function as `str`. Use `std.fmt.format(f"...")` returning `string.String` when ownership must escape.
- Float and double interpolations support `:.N` precision.
- Integer primitive and integer-backed enum/flags interpolations support `:x` (lowercase hex) and `:X` (uppercase hex).
- Integer primitive and integer-backed enum/flags interpolations support `:o` / `:O` (octal) and `:b` / `:B` (binary).
- `std.fmt.format(...)` receives special lowering and returns `string.String`.
- `std.fmt.append_format(...)` / `std.fmt.assign_format(...)` receive special lowering when passed a format string and write directly into an existing `string.String` sink.
- `string.String.append_format(...)` / `string.String.assign_format(...)` receive the same direct-sink lowering when passed a format string.
- `str_buffer[N].append_format(...)` / `str_buffer[N].assign_format(...)` receive the same direct-sink lowering for fixed-capacity buffers.
- Custom interpolation hooks use the direct sink when formatting into `string.String`; plain `f"..."` expressions and `str_buffer` sinks pass a borrowed `string.String` view onto the destination slice, so those paths stay allocation-free as long as the hook writes exactly `format_len()` bytes.

Heredoc notes:

- `<<-TAG ... TAG` -> `str`
- `c<<-TAG ... TAG` -> `cstr`
- `f<<-TAG ... TAG` -> `str`
- Content is dedented by shared leading spaces of nonblank lines.
- The trailing newline before the terminator is preserved.

## 13. Safety And Conversion Rules

- Conditions must be `bool`.
- No truthy or falsy coercion.
- Outside external-call boundaries, enum and flags values do not implicitly coerce to their backing integer types.
- Mixed signed and unsigned integer arithmetic requires an explicit cast.
- `%` requires integer-compatible operands.
- Bitwise operators require matching integer or flags types.
- Shift operators require integer operands.
- Safe array indexing requires an addressable array value.
- Safe indexing (`arr[i]`) is bounds-checked and calls `fatal` on out-of-bounds access.
- Use `get(arr, i)` for recoverable indexing that returns `ptr[T]?` (null on out-of-bounds) instead of aborting.
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
- `if` / `else if` / `else` bodies and conditions
- `while` bodies and conditions
- single-form and parallel `for` bodies and iterables
- `match` discriminants and arms
- `let ... else:` initializers and else bodies
- `unsafe` blocks
- short-circuit `and` / `or`
- assignment targets
- `defer` cleanup bodies inside async functions

## 15. Events

Event declarations provide a built-in typed publisher/subscriber surface with fixed-capacity listener storage.

Declaration forms:

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

Built-in event operations:

- `event.subscribe(listener) -> Result[Subscription, EventError]`
- `event.subscribe_once(listener) -> Result[Subscription, EventError]`
- `event.subscribe(state: ptr[State], listener: fn(ptr[State], ...)) -> Result[Subscription, EventError]` — stateful overload (detected by passing 2 positional arguments)
- `event.subscribe_once(state: ptr[State], listener: fn(ptr[State], ...)) -> Result[Subscription, EventError]` — stateful one-shot (detected by passing 2 positional arguments)
- `event.unsubscribe(subscription) -> bool` — returns `true` if the listener was active and removed
- `event.emit()` or `event.emit(payload)` — only callable from the declaring module
- `event.wait() -> Task[Result[T, EventError]]` — async wait for the next emission

`EventError` is a built-in enum with a single member `full`, returned when listener capacity is exhausted.

## 16. Common Rejections

Current compiler rejects:

- interface methods with `async` or generic signatures
- legacy `in` / `out` / `inout` markers at call sites
- consuming foreign calls with `consuming` parameters outside top-level expression statements
- external functions that are generic, async, or array-taking / array-returning
- ordinary truthy or falsy conditions on integers and pointers

## 17. CLI Commands

The `mtc` CLI is the primary tool for checking, building, and running Milk Tea programs.

Essential commands:

```
mtc check <path>              # Type-check + lint; reports all diagnostics sorted by line
mtc run   <path>              # Build and execute
mtc build <path>              # Build only (emit C, compile, link)
mtc lex   <file.mt>           # Print lexer token stream
mtc parse <path>              # Print parsed AST
mtc lower <path>              # Print lowered IR
mtc debug <file.mt>           # Print debug info (tokens, AST, facts, bindings, diagnostics)
mtc emit-c <path>             # Emit generated C to stdout
mtc format <path>             # Format sources in place (--check for dry-run)
mtc lint <path>               # Run linter (--fix to apply fixes, --select/--ignore to filter)
mtc new <name>                # Scaffold a new package (package.toml + src/main.mt)
mtc cache status              # Show build cache stats
```

Package management:

```
mtc deps tree <path>          # Print the dependency graph
mtc deps lock <path>          # Write/refresh package.lock
mtc deps add <path> <name>   # Add a dependency
mtc deps remove <path> <name> # Remove a dependency
mtc deps update <path>        # Update dependencies
mtc deps publish <path>       # Publish a package to the local registry
mtc deps fetch <path>         # Materialize cache-backed sources
```

Run a pre-built module (no compilation):

```
mtc run-module <module>       # Run compiled module by name (e.g. std.fmt.bench)
```

Toolchain maintenance:

```
mtc toolchain bootstrap       # Bootstrap the native toolchain
mtc toolchain doctor          # Diagnose toolchain setup
mtc toolchain tools           # List available native tools
```

Build and run commands support `--profile`, `--platform`, `--cc`, `--keep-c`, `--locked`, `--frozen`, and `-I` include paths. Dependency-locked flows support `--locked` (use package.lock) and `--frozen` (require current package.lock).

Diagnostic output uses standard compiler format (file:line:column with source context, error codes, and caret highlighting):

```
[E0001] error: unknown type floa
  --> file.mt:1:16
   |
   1 | type Seconds = floa
     |                ^~~~
  note: did you mean 'float'?

error: could not check due to 1 previous error
```

`mtc check` surfaces both errors and linter warnings:

| Severity | Label | Meaning |
|---|---|---|
| `error:` | red | semantic errors, linter errors |
| `warning:` | yellow | linter warnings (dead-assignment, etc.) |
| `hint:` | cyan | style suggestions (prefer-let, etc.) |

Exit code is 0 on success, 1 when errors are present (warnings/hints alone do not fail).

## 18. Minimal Example

```mt
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

# Milk Tea Language Design

Milk Tea is a statically typed, indentation-based systems language for games.
It draws from:

- C's data layout, ABI honesty, and pointer model
- C#'s type clarity, enums, flags, and explicit `unsafe` escape hatches
- Ruby's readable naming and low-ceremony feel
- Python's indentation, blocks, and approachable surface syntax

The output target is beautiful C. The generated C should be readable enough that a human can debug it, diff it, and ship it without feeling trapped inside a compiler's private IR.

## Primary goals

1. Be obvious to read. The language should look like code, not punctuation.
2. Stay statically typed. Public APIs must be explicit and unsurprising.
3. Feel good for game programming. Tight loops, structs, arrays, arenas, handles, and FFI should be first-class.
4. Interoperate with C as a native citizen. C libraries are not a side feature; they are part of the core story.
5. Generate C that mirrors the source closely. No hidden runtime, hidden heap traffic, or hidden dispatch.

## Non-goals

- No exceptions
- No inheritance
- No hidden virtual dispatch
- No operator overloading beyond the built-in operators
- No trait system or typeclass machinery
- No macro system that rewrites arbitrary ASTs
- No garbage collector
- No implicit conversions between unrelated primitive types
- No user-invisible allocation for strings, collections, closures, or method calls. If a surface allocates owned text or storage, the allocating surface must be spelled in source.

## Design rules

### 1. What you see is what runs

If code allocates, takes an address, dereferences a raw pointer, performs an FFI call, or enters unsafe territory, the source should say so directly.

FFI visibility belongs at the declaration site. Raw `extern module` declarations expose exact ABI types. Imported foreign declarations may project those raw types into ordinary Milk Tea types, but the projection rule, temporary-storage rule, and ownership rule must be declared there instead of repeated at every call site.

The same rule applies to text construction. Plain string literals and format string literals are borrowed `str` values. Any surface that builds owned text must say so explicitly, for example `std.fmt.string(f"...")` when ownership must escape.

### 2. C is the ABI ground truth

Milk Tea must represent C structs, unions, enums, flags, pointers, arrays, callbacks, and calling conventions without lossy translation.

### 3. Safe by default, unsafe by choice

The language should help with common mistakes, but it must not hide the machine model. Sharp operations are allowed, but only behind explicit syntax.

### 4. Data-oriented design comes first

Plain structs, arrays, spans, pools, and arenas matter more than elaborate object systems.

### 5. The language surface stays small

If a feature saves five lines but makes lowering, tooling, or debugging much harder, it does not belong in v1.

### 6. One job, one canonical surface

Milk Tea should not accumulate multiple everyday spellings for the same job.

When two surfaces overlap, one must be the normal user-facing form and the other must be either a low-level escape hatch or an implementation detail.

The intended reductions are deliberate:

- borrowed text is `str`
- raw ABI text is `cstr`
- fixed-capacity mutable text is `str_builder[N]`
- growable owned text is `std.string.String`
- raw character storage is `array[char, N]` or `span[char]`, not an alternate text object
- safe single-object aliasing is `ref[T]`
- raw writable pointers are `ptr[T]`
- raw read-only pointers are `const_ptr[T]`
- sized many-element borrows are `span[T]`
- pointer-like absence is `null`, not `zero[ptr[T]]()` in typed nullable contexts
- imported foreign declarations own marshalling policy; raw `std.c.*` declarations stay exact

If a new feature introduces a second ordinary way to express the same concept, the language should delete one of them instead of documenting both.

## Overall shape

- Indentation defines blocks.
- A colon starts a block.
- Newlines terminate statements.
- Newlines inside `()` and `[]` do not terminate statements.
- Tabs are illegal in source files; indentation is 4 spaces.
- Trailing commas are allowed in multiline call arguments and aggregate literals.
- Comments use `#`.
- Names are `snake_case` for modules, variables, and functions.
- Types use `PascalCase`.
- Generated binding modules preserve C names exactly at the ABI layer.
- Imported foreign modules use normal Milk Tea naming.

Example:

```mt
module game.main

import std.math as math
import std.raylib as rl

const screen_width: i32 = 1280
const screen_height: i32 = 720

struct Player:
	position: rl.Vector2
	velocity: rl.Vector2
	radius: f32

methods Player:
	edit def update(dt: f32):
		this.position.x += this.velocity.x * dt
		this.position.y += this.velocity.y * dt

def main() -> i32:
	rl.init_window(screen_width, screen_height, "Milk Tea")
	defer rl.close_window()

	var player = Player(
		position = rl.Vector2(x = 400.0, y = 300.0),
		velocity = rl.Vector2(x = 140.0, y = 100.0),
		radius = 18.0,
	)

	while not rl.window_should_close():
		let dt = rl.get_frame_time()
		player.update(dt)

		rl.begin_drawing()
		defer rl.end_drawing()

		rl.clear_background(rl.BLACK)
		rl.draw_circle_v(player.position, player.radius, rl.GOLD)

	return 0
```

## Syntax and readability rules

Milk Tea should use a deliberately small punctuation set. The only everyday symbolic forms are:

- `:` for blocks
- `->` for function return types
- `.` for field and module access
- `[]` for indexing and generic arguments
- `?` for nullable types

Everything else should prefer words over symbols.

Address formation and dereference stay as word forms: `ref_of(expr)`, `const_ptr_of(expr)`, `ptr_of(ref_value)`, `read(ref_value)`, and `read(ptr_value)`.

### Declarations

```mt
module demo.physics

import std.math

const gravity: f32 = 9.81

type EntityId = u32

struct Body:
	id: EntityId
	mass: f32
	velocity: f32

enum BodyKind: u8
	dynamic = 1
	static = 2

flags DrawFlags: u32
	visible = 1 << 0
	selected = 1 << 1
```

### Variables

- `let` creates an immutable local binding.
- `var` creates a mutable local binding.
- `const` defines a compile-time constant.
- A typed local declaration without `= ...` zero-initializes that local. This is the normal local-storage form and is only valid for types that `zero[T]()` already supports. Use `zero[T]()` or `Type()` only when you need a value expression.
- For pointer-like absence, use a nullable type plus `null`. `zero[ptr[T]]()` remains available for low-level zero-initialized pointer storage, but the compiler rejects it when the surrounding expected type is already a nullable pointer-like type. In those contexts, write `null`.

```mt
let width: i32 = 1280
var score: i32 = 0
var name_input: str_builder[64]
const max_players: i32 = 4
```

Local type inference is allowed when the initializer makes the type obvious:

```mt
let dt = rl.GetFrameTime()      # inferred as f32
var player_count = 0            # inferred as i32
```

Public items should always spell their types out.

### Functions

```mt
def clamp(value: f32, min_value: f32, max_value: f32) -> f32:
	if value < min_value:
		return min_value
	elif value > max_value:
		return max_value
	else:
		return value
```

There is no overloading. One function name maps to one callable symbol.

### Methods

Methods are syntax sugar over namespaced functions. They do not imply objects, inheritance, or dynamic dispatch.

```mt
struct Camera:
	position: Vec2
	zoom: f32

methods Camera:
	edit def move_by(delta: Vec2):
		this.position.x += delta.x
		this.position.y += delta.y

	def world_scale() -> f32:
		return this.zoom

	static def origin() -> Camera:
		return Camera(position = Vec2(x = 0.0, y = 0.0), zoom = 1.0)
```

Lowering rule, in emitted C:

- `camera.move_by(delta)` emits `game_Camera_move_by(&camera, delta)`.
- `camera.world_scale()` emits `game_Camera_world_scale(camera)`.
- `Camera.origin()` emits `game_Camera_origin()`.

Receiver rule:

- Plain `def` inside `methods T:` means an implicit `this: T` value receiver.
- `edit def` inside `methods T:` means an implicit writable `this` receiver and requires an addressable receiver.
- `static def` inside `methods T:` means there is no receiver.
- There is no hidden dynamic dispatch, vtable lookup, or heap allocation.

Value receivers are deliberate. They keep fluent calls on temporaries honest and let method calls lower directly to plain C value parameters. Writable methods are the only place where the compiler takes an address implicitly.

The rule is fixed and inspectable. There is no method lookup at runtime.

### Control flow

```mt
if ready:
	start_game()
elif wants_menu:
	open_menu()
else:
	show_intro()

while running:
	tick()

for i in range(0, count):
	update_enemy(i)

for body in bodies:
	simulate(body)

match event.kind:
	EventKind.quit:
		return 0
	EventKind.resize:
		resize(event.width, event.height)
```

Rules:

- Conditions must be `bool`. Integers and pointers do not become truthy implicitly.
- `match` must be exhaustive for enums.
- `break` and `continue` work exactly as in C and Python.

### Useful structured features

Milk Tea should include a small number of control-flow features that materially improve systems code without hiding behavior.

#### `defer`

`defer` registers cleanup code at scope exit and lowers to obvious cleanup labels in C.

```mt
def load_texture(path: str) -> Result[Texture, LoadError]:
	let texture = rl.load_texture(path)

	if texture.id == 0:
		return err(LoadError.file_not_found)

	return texture
```

#### `unsafe`

`unsafe` is required for:

- raw pointer dereference and field access through raw pointers
- raw pointer arithmetic
- unchecked casts and bit reinterpretation
- reading inactive union fields
- pointer indexing
- raw ABI work that is not covered by a declared foreign import contract

```mt
unsafe:
	let p = pixels + offset
	let pixel = read(ptr[u32]<-p)
```

The point is not to forbid sharp tools. The point is to mark them.
Calling a foreign import that already declares borrowed strings, ordinary `str` parameters, string lists, `out` parameters, or typed pointer projections is ordinary code. Crossing into raw `std.c.*` bindings, doing pointer reinterpretation, or manually walking foreign memory remains explicit low-level work.

## Type system

The type system must stay simple, explicit, and close to C.

### Primitive types

- `bool`
- `byte`
- `char`
- `i8`, `i16`, `i32`, `i64`
- `u8`, `u16`, `u32`, `u64`
- `isize`, `usize`
- `f32`, `f64`
- `void`
- `str`
- `cstr`

Notes:

- `str` is a UTF-8 string view, not a NUL-terminated C string.
- Every `str` value must contain valid UTF-8 bytes for its full length.
- `cstr` is the raw ABI-facing NUL-terminated C string type. It belongs primarily in raw `extern module` declarations and low-level interop code.
- `char` is the ABI-facing single-byte character type for C text and raw buffers. It is not a general arithmetic integer type.
- String literals produce `str`.
- Safe code does not fabricate `str` values from raw parts. Source code ordinarily obtains `str` values from literals, `str_builder.as_str()`, slicing an existing `str`, imported foreign boundaries that declare borrowed text, or other compiler/runtime surfaces that preserve the UTF-8 invariant.
- Low-level code may construct `str(data = ..., len = ...)` only inside `unsafe`, and the caller is then responsible for pointer validity, lifetime, and the UTF-8 invariant.
- A string literal may satisfy an expected `cstr` directly when the compiler has contextual type information, such as a typed local, an `array[cstr, N]` element, or a borrowed C-string argument position, because static storage is known.
- `c"hello"` produces `cstr` with static storage for raw ABI work and low-level interop.

### Composite types

```mt
array[T, N]      # fixed-size array
str_builder[N]   # fixed-capacity mutable UTF-8 text buffer
ptr[T]           # raw pointer
span[T]          # pointer + length view
fn(A, B) -> R    # function pointer type
```

Examples:

```mt
let pixels: span[u8]
let name_input: str_builder[64]
let labels: array[str, 8]
let texture_ptr: ptr[Texture]
let normal_table: array[f32, 256]
let callback: fn(ptr[void], i32) -> void
```

Notes:

- Fixed-array indexing is bounds-checked and safe by default.
- Safe array indexing requires an addressable array value; bind temporaries before indexing them.
- `array[char, N]` and `span[char]` are the ordinary source-level forms for raw writable character storage and byte-oriented foreign buffers. They are not alternate text objects and should not grow a parallel everyday text API.
- `str_builder[N]` is the one source-level mutable UTF-8 text type. It owns `N` editable text bytes plus an implementation-managed trailing NUL slot, tracks current text length, and refreshes that length when a writable buffer alias mutates the underlying storage.
- If low-level code needs to validate raw `array[char, N]` storage as text, that conversion belongs in an explicit helper or imported boundary, not as a built-in method family on raw arrays.
- Addressable `str_builder[N]` values also coerce to `span[char]`, so writable foreign text APIs can still accept builders directly when they do not want a second application-facing text abstraction.
- `str_builder[N]` is not an ABI type. Raw bindings still spell writable text as `ptr[char]` or `span[char]`; `str_builder[N]` is the caller-side text object.
- `str_builder[N]` has a built-in text surface: `.clear()`, `.assign(str)`, `.append(str)`, `.len()`, `.capacity()`, `.as_str()`, and `.as_cstr()`.
- `.assign(...)` replaces the current contents and traps at runtime if the new text exceeds capacity.
- `.append(...)` extends the current contents and traps at runtime if the appended text would exceed capacity.
- `.len()` returns the tracked text length, revalidating UTF-8 and rescanning for the trailing NUL if the builder was passed through a writable `span[char]` or `ptr[char]` alias.
- `.capacity()` reports the maximum editable text bytes, not counting the reserved trailing NUL slot.
- `.as_str()` and `.as_cstr()` borrow from the same builder storage and revalidate through that same dirty-refresh path before returning.
- `str.slice(start, len)` uses byte offsets and byte lengths, but both the start and end position must be UTF-8 code-unit boundaries or the slice traps at runtime.
- Ordinary string lists stay `array[str, N]` or `span[str]` in source. If an imported foreign declaration chooses that public surface for a raw `char **`, `span[cstr]`, or pointer-plus-length text-list API, the boundary owns the temporary marshalling.
- Imported foreign declarations may map `str_builder[N] as ptr[char]` directly when the public surface wants editable UTF-8 text with fixed caller capacity.
- If the raw call also needs the caller buffer size, a `str_builder[N]` public signature should pass `text_public.capacity() + 1` in the foreign mapping so the raw side sees the full writable byte count including the trailing NUL slot.
- `span[char] as ptr[char]` remains the right public surface when the writable storage is not semantically UTF-8 text or when the caller capacity is intentionally runtime-sized instead of part of the type.
- In an explicit foreign mapping, a parameter declared with `as` keeps the boundary value under its original name and exposes the public value as `<name>_public`.
- Pointer indexing follows the raw pointer model and requires `unsafe`.

### Nullability

Milk Tea keeps nullability explicit.

```mt
let window: ptr[Window]? = null
let name: cstr? = null
```

Only nullable pointer-like types may hold `null`.
When contextual typing already determines the nullable pointer-like type, prefer bare `null` over a typed form such as `null[ptr[Window]]`. Use a typed `null[...]` only when the surrounding context does not provide the target nullable pointer-like type.
Do not use `zero[ptr[T]]()` as a replacement for `null`; `null` expresses absence, while `zero[T]()` is the generic value-initialization surface. When the expected type is already a nullable pointer-like type, the compiler rejects `zero[ptr[T]]()` and requires `null`.

### User-defined types

#### Structs

Structs are plain data. Field order is preserved.

```mt
struct Vec2:
	x: f32
	y: f32
```

#### Enums

Enums always have an explicit backing type.

```mt
enum WeaponKind: u8
	sword = 1
	bow = 2
	wand = 3
```

#### Flags

Flags are named bitmasks with a fixed integer backing type.

```mt
flags WindowFlags: u32
	fullscreen = 1 << 0
	vsync = 1 << 1
	borderless = 1 << 2
```

#### Unions

Unions are allowed for FFI and low-level storage.

```mt
union Value:
	i: i32
	f: f32
	raw: ptr[void]
```

Reading a union field other than the last written field requires `unsafe`.

#### Variants

Variants are tagged unions. Each arm optionally carries named payload fields.

```mt
variant Token:
	ident(text: str)
	number(value: i32)
	eof
```

Arm constructors follow the same field-assignment form as struct literals. No-payload arms are bare member expressions. Match on a variant uses `as name` to bind a payload arm's fields. Generic variants are not yet supported.

#### Opaque types

Opaque types are essential for C handles.

```mt
opaque SDL_Window
opaque ma_engine
```

#### Type aliases

```mt
type Seconds = f32
type FileHandle = ptr[libc.FILE]
```

### Generics

Generics are useful, but they must stay boring.

Allowed in v1:

- generic structs
- generic functions
- explicit specialization calls
- monomorphized code generation

Not allowed in v1:

- generic constraints
- type-level computation
- arbitrary compile-time execution

Example:

```mt
struct Slice[T]:
	data: ptr[T]
	len: usize

def first[T](items: Slice[T]) -> ptr[T]?:
	if items.len == 0:
		return null
	return items.data

def capacity_of[N](buffer: str_builder[N]) -> usize:
	return buffer.capacity()

def explicit_capacity(buffer: str_builder[32]) -> usize:
	return capacity_of[32](buffer)
```

Explicit specialization arguments may be type references like `bytes_for[i32](4)` or numeric literals like `capacity_of[32](buffer)` when the generic parameter is used in a literal slot such as `str_builder[N]` or `array[T, N]`.

## Expressions and conversions

### Operators

Built-in operators should match familiar C behavior where possible:

- arithmetic: `+ - * / %`
- comparison: `== != < <= > >=`
- boolean: `and or not`
- bitwise: `& | ^ ~ << >>`

No user-defined operator overloading.

### Casts

Conversions are explicit. Prefer `T<-expr` in ordinary code; `cast[T](expr)` remains available when the call form is clearer or required.

```mt
let count64 = u64<-count32
let value = f32<-raw
let newline = char<-10
```

For bit reinterpretation, use a separate form inside `unsafe`:

```mt
unsafe:
	let bits = reinterpret[u32](value)
```

Binary arithmetic and numeric comparison operators may promote primitive operands to a common type locally.
This is limited to `+ - * / % == != < <= > >=` and does not change assignment, return, or aggregate-field typing rules.
Non-extern call boundaries remain strict, but extern calls may pass enum or flags values to same-width fixed-width integer parameters without an explicit cast for C ABI interop.
Mixed signed and unsigned integers still require an explicit cast.

`char` stays outside the general numeric-promotion rules. If code wants arithmetic on a character value, cast it to an integer type first. If code wants to write bytes back into a `char` buffer, either use `char<-...` explicitly or rely on the expected `char` boundary where a known `char` target is being initialized or assigned.

Example:

```mt
let newline = char<-10

unsafe:
	buffer[0] = 65
	buffer[1] = newline
	let code = i32<-buffer[0]
```

### Literals

```mt
42
0xff
0b1010
3.14159
"hello"
c"hello"
```

Integer literals are untyped until context resolves them, defaulting to `i32`.
Float literals default to `f64` when unconstrained.

Typed contexts may adopt the expected numeric type for a literal directly. This is limited to literal typing, not general implicit conversion.

There is one additional narrow boundary rule for float-heavy code: a primitive integer expression may flow into an expected float type for an explicitly typed local declaration, an `=` assignment to a float-typed lvalue, or a return expression from a float-returning function.

This is still a boundary cast, not a general usual-arithmetic-conversions model. It does not widen ordinary function arguments, aggregate field initializers, public constant initialization, or arbitrary expression typing. Integer arithmetic stays integer arithmetic until that final boundary cast, so `let ratio: f32 = hits / total` still performs integer division before the result is converted.

Examples of typed contexts:

- a declaration with an explicit type
- a function argument with a known parameter type
- a struct field initializer with a known field type
- a return expression with a known return type

This keeps `f32`-heavy game code readable while preserving the rule that ordinary expressions do not silently convert between numeric types.

### Composite literals

There are no constructors with hidden logic in v1. Aggregate construction uses field and element literals directly.
Multiline aggregate-style calls may use trailing commas so data-heavy code stays easy to diff.
Omitted fields in plain aggregate literals and omitted tail elements in fixed-array literals default to zero.
That means `Type()`, `Type(field = value)`, `array[T, N]()`, and `array[T, N](a, b)` are all just zero-default data literals, not constructor calls.
There are still no default field expressions, hidden initializer functions, or other non-local effects during construction.
Typed locals without `= ...` remain the declaration form for zero-initialized storage; these aggregate literals are the expression forms when code needs a value.

```mt
let player = Player(
	position = Vec2(x = 10.0, y = 20.0),
	velocity = Vec2(x = 0.0, y = 0.0),
)

let origin = Player()

let palette = array[u32, 4](0xff0000ff, 0x00ff00ff, 0x0000ffff, 0xffffffff)
let grayscale = array[u32, 4](0x111111ff, 0x555555ff)
```

This keeps data construction obvious and maps cleanly to C initializers.

## Memory model

The memory model must feel like C with better defaults and cleaner surfaces.

### Value semantics by default

- Scalars copy by value.
- Structs copy by value.
- Fixed arrays copy by value.
- Returning a struct is allowed and lowers to normal C return or out-parameter lowering as needed.

There is no hidden reference counting and no hidden heap boxing.

### Explicit allocation

Heap allocation is always explicit and allocator-driven.

```mt
import std.mem.heap as heap

def spawn_enemy(start: Vec2) -> ptr[Enemy]:
	let enemy = heap.must_alloc[Enemy](1)
	unsafe:
		enemy.position = start
		enemy.health = 100
	return enemy
```

The default heap allocation functions return nullable pointers because C allocation can fail: `alloc_bytes`, `alloc_zeroed_bytes`, `resize_bytes`, `alloc[T]`, `alloc_zeroed[T]`, and `resize[T]` all return `...?`. Code that wants explicit error handling checks for `null`. Code that wants simple fail-fast behavior uses `must_alloc*` or `must_resize*`, which panic on allocation failure.

Allocator surfaces are semantic, not stylistic. Heap, arena, pool, and stack model different ownership and lifetime stories; the language should not add alias APIs that make them feel interchangeable.

Recommended standard memory surfaces:

- `std.mem.heap` for general allocation and the raw `*_bytes` boundary
- `std.mem.arena` for frame, level, and scratch lifetimes
- `std.mem.pool` for fixed-size object pools
- `std.mem.stack` for explicit temporary allocators

Typed allocation helpers live on the module surface where generic methods are not available yet. For example, `heap.must_alloc[Enemy](1)`, `arena.alloc[Enemy](ref_of(scratch), 4)`, `pool.alloc[Enemy](ref_of(objects))`, and `stack.alloc[Enemy](ref_of(temp), 2)` all stay explicit about allocator choice, while raw byte APIs remain available for lower-level storage work.

### Pointers and references

Pointers are still first-class because game code needs raw memory and FFI. The source model is explicit and uniform.

```mt
let position_ref = ref_of(player.position)
let position_ptr = ptr_of(position_ref)

position_ref.x += 1

unsafe:
	position_ptr.x += 1
```

Rules for safe references:

- `ref[T]` is a non-null writable safe alias to one live object.
- `ref_of(expr)` requires a mutable addressable lvalue source and produces `ref[T]`.
- `const_ptr_of(expr)` requires an addressable lvalue source and produces `const_ptr[T]` for read-only raw interop.
- `read(ref_value)` is safe and yields the referenced lvalue/value.
- `ptr_of(ref_value)` converts a safe reference to `ptr[T]` explicitly.
- member access and method calls auto-project through refs, so `handle.field` and `handle.edit_method()` are the preferred forms.
- there is no implicit ref-to-value call conversion: if a function expects `T`, pass `read(handle)`.
- references do not support arithmetic, pointer indexing, or nullable semantics.
- writable references are non-escaping in the current implementation: they may be used in locals and non-extern function parameters, and imported foreign parameters may expose `out` or `inout` boundary forms that lower to raw pointers, but refs themselves still cannot be stored, nested inside other types, returned, or used directly in raw `extern module` declarations.

Rules for raw pointers:

- `ptr[T]`, `ptr[T]?`, `const_ptr[T]`, and `const_ptr[T]?` are raw pointer values.
- there is no source `&expr`, `*ptr`, or `ptr->field`.
- spell writable address formation as `ref_of(expr)`, read-only raw address formation as `const_ptr_of(expr)`, and writable raw pointer formation as `ptr_of(ref_of(expr))` when you truly need a raw pointer.
- `read(ptr)` dereferences a raw pointer and requires `unsafe`.
- `const_ptr[T]` is the read-only raw-pointer surface and lowers to C `const T*`. `const_ptr[void]` is valid and represents C `const void *`.
- `ptr.field` and `ptr.method()` access pointee fields and methods through a raw pointer and require `unsafe`.
- pointer arithmetic and pointer indexing remain `unsafe`.
- raw pointer offsets and indices may use ordinary integer expressions directly; code does not need a pre-emptive cast to `usize` just to write `ptr[i]` or `ptr + offset`.
- pointer comparison is explicit and never treated as boolean truthiness.
- `ptr[char]` is the ordinary representation for mutable C text and byte-oriented FFI buffers; writing control bytes such as NUL or newline uses `char` values, typically spelled with `char<-0` and `char<-10`.
- imported foreign declarations may project ABI-identical pointer forms at the boundary. A raw `ptr[void]` parameter may surface as `ptr[T]?` or an opaque handle type when the imported declaration says so. Reinterpretation inside user code still requires explicit `cast` and, when dereferenced, `unsafe`.

References are separate from methods:

- plain methods still receive values.
- `edit def` methods use the writable implicit receiver and require an addressable call target.
- `static def` methods receive nothing.
- `ref[T]` is for explicit aliasing in APIs, not hidden receiver lowering.

This gives the language clear aliasing tools instead of one overloaded surface:

- `ref[T]` for safe aliasing of one mutable object
- `ptr[T]` / `ptr[T]?` for writable raw memory and FFI
- `const_ptr[T]` / `const_ptr[T]?` for read-only raw memory and FFI
- `span[T]` for sized borrowed views over raw pointer data

### Spans

Raw pointers are necessary. Spans are the readable everyday view.

```mt
span[T] is conceptually:
	data: ptr[T]
	len: usize
```

`span[T]` should be built into the language surface as a standard view type because it is the right default for arrays, buffers, decoded file content, vertex streams, and audio samples.

`span[T]` is the many-element view. `ref[T]` is the safe writable single-object alias, while `const_ptr[T]` is the raw read-only single-object pointer form.

For frequent pointer-plus-length construction in game code, use `std.span` helpers such as `sp.from_ptr[T](ptr, len)` instead of repeating `span[T](data = ..., len = ...)` literals.

### Standard library foundation

The standard library follows the same rule as the language: no hidden allocation, no implicit ownership transfer, and no runtime machinery the source did not ask for.

Implemented core modules:

- `std.option` is a plain generic optional-value container for APIs where a nullable pointer would be the wrong surface.
- `std.ascii` provides byte-level classification and conversion helpers for lexers and parsers.
- `std.vec` is the owned heap-backed `Vec[T]`. It grows explicitly, releases explicitly, and exposes borrowed `span[T]` views.
- `std.bytes` is an owned byte buffer on top of `Vec[u8]`. It is a low-level substrate, not the default application-facing text tool.
- `std.string.String` is the normal growable owned UTF-8 text surface. Its public API should mirror the mutable-text shape of `str_builder[N]`: method-style `append`, `assign`, `clear`, `as_str`, `to_cstr`, and explicit constructors, not a parallel module-function vocabulary. Byte-level appends exist as low-level escape hatches.
- `std.str` provides borrowed string helpers: UTF-8 validation, byte lookup, prefix/suffix/equality, ASCII trimming, and byte search.
- `std.path`, `std.fs`, and `std.io` provide pure path helpers, byte/text file read/write, stdout printing, and stderr diagnostics.
- `std.fmt` is the explicit formatting subsystem. It should be the single normal formatting engine for owned and fixed-capacity text rather than one option among many formatting styles. `f"..."` produces borrowed `str`; `fmt.string(f"...")` is the explicit owned-text allocation path when you need a `std.string.String`. Low-level append helpers remain implementation building blocks.
- `std.log` is a tiny stderr logger built from `std.fmt` and `std.io`.
- `std.hash`, `std.map`, and `std.set` provide deterministic hash helpers plus policy-based hash collections.
- `std.str_map` and `std.str_set` provide borrowed-string-key wrappers for symbol tables and keyword sets.
- `std.alg` provides generic `span[T]` algorithms: search, predicates, equality, copy, fill, and insertion sort.
- `std.random` provides deterministic local PRNG state.
- `std.time` provides Unix time and explicit `strftime`-style UTC/local formatting.
- `std.process` exposes `argc`/`argv`, environment lookup, and explicit process exit.
- `std.json` provides an explicit JSON tokenizer and writer helpers. It is not reflection or automatic serialization.

Hash collections use explicit function pointers instead of traits:

```mt
import std.hash as hash
import std.map as map

def hash_i32(value: i32) -> u64:
	return hash.i32_value(value)

def equal_i32(left: i32, right: i32) -> bool:
	return hash.i32_equal(left, right)

def example() -> i32:
	var scores = map.create[i32, i32](hash_i32, equal_i32)
	defer map.release[i32, i32](ref_of(scores))

	map.put[i32, i32](ref_of(scores), 7, 42)

	var value = 0
	if map.get_into[i32, i32](scores, 7, ref_of(value)):
		return value
	return 0
```

This keeps lookup semantics visible at construction time and avoids a hidden global typeclass dictionary. If a future trait system exists, it should lower to something equally explicit and readable.

The self-hosting preparation boundary is now clear: the standard library has dynamic arrays, owned text, borrowed string helpers, maps/sets, path and file loading, process arguments, diagnostics, time, random, and JSON token/writer support. The remaining self-hosting work is not another hidden stdlib dependency; it is the actual compiler port: AST data structures, lexer, parser, type representation, semantic analysis, lowering, C generation, module loading, CLI behavior, and eventually bindgen strategy.

### Lifetime story

Milk Tea should not try to be Rust. It should instead make lifetime choices explicit at the API level.

The model:

- stack values for local temporaries
- arenas for frame and level data
- pools for stable object storage
- explicit heap allocation when needed
- `unsafe` for manual aliasing and lifetime tricks

This is enough to write fast engine and game code without dragging the user through ownership proofs.

## Error handling

Exceptions do not belong here.

Preferred strategy:

- `Result[T, E]` for recoverable failures
- `panic("message")` for programmer errors and impossible states
- explicit status codes for imported foreign APIs when that matches the C API better

Example:

```mt
enum LoadError: u8
	file_not_found = 1
	invalid_format = 2

def load_level(path: str, arena: ptr[Arena]) -> Result[Level, LoadError]:
	let json = read_text_file(path, arena)
	if json == null:
		return err(LoadError.file_not_found)

	return parse_level(json)
```

No implicit exception paths. Every failure path is visible in the type or the code.

## Modules and packaging

Source files should map directly to modules.

```mt
module game.rendering.sprite_batch

import std.raylib as rl
import game.assets
```

Rules:

- one top-level module per file
- explicit imports only
- no wildcard imports in v1
- no cyclic imports
- package naming stays filesystem-friendly

Recommended layout:

- `std.*` for core library modules and imported foreign modules
- `std.c.*` for raw bindgen-generated C modules
- project modules under their own root namespace

Handwritten wrappers may still exist for real policy or domain logic, but they are not the primary answer to FFI noise. The primary interop story should be raw `std.c.*` modules plus compiler-recognized imported foreign declarations.

## FFI design

FFI is a core feature, not a bolt-on.

Milk Tea needs two interop surfaces, not one:

1. a raw ABI surface for exact bindings
2. an imported foreign surface for ordinary Milk Tea code

This is the same split C# gets right with P/Invoke versus `unsafe` pointer code. The declaration site carries the boundary contract. Raw pointers, reinterpretation, and manual memory walking remain explicit.

### Raw C bindings

Milk Tea needs a dedicated `extern module` form for ABI-exact bindings.

Direct `extern def` declarations are also allowed in ordinary modules for small manual ABI bridges, but generated and standard-library bindings should prefer full `extern module` files so the raw surface stays grouped, auditable, and easy to regenerate.

```mt
extern module std.c.raylib:
	link "raylib"
	include "raylib.h"

	struct Vector2:
		x: f32
		y: f32

	struct Color:
		r: u8
		g: u8
		b: u8
		a: u8

	extern def InitWindow(width: i32, height: i32, title: cstr) -> void
	extern def WindowShouldClose() -> bool
	extern def BeginDrawing() -> void
	extern def EndDrawing() -> void
	extern def DrawCircleV(center: Vector2, radius: f32, color: Color) -> void
```

Capabilities required by the FFI surface:

- exact integer and float widths
- exact struct field order
- packed structs and explicit alignment
- unions
- opaque handles
- function pointers and callbacks
- `cdecl` and future calling convention markers
- C varargs for APIs like `printf`
- constant and macro import where clang can resolve the value

### Bindgen

Bindings for libc, libm, raylib, SDL3, Box2D, stb, miniaudio, json-c, and similar libraries should be generated with clang.

Bindgen output rules:

1. Preserve ABI-visible names exactly in raw `std.c.*` modules.
2. Emit the thinnest possible surface. No runtime marshaling.
3. Emit opaque types instead of guessing private layouts.
4. Emit comments or metadata that make the original C header traceable.
5. Prefer enums, flags, structs, unions, constants, and function declarations over clever wrappers.
6. When headers are clear enough, emit metadata that can drive generated imported foreign declarations for borrowed strings, transient strings, out parameters, spans, opaque handles, and release functions. If the header is not clear enough, stay raw instead of guessing.

The imported layer may also be generated, but only from an explicit checked-in policy file. clang bindgen is responsible for ABI facts; the policy file is responsible for semantic facts the header does not encode, such as `str as cstr`, `out`, `inout`, `consuming`, span fan-out, selected renames, and which raw declarations should remain exposed only through `std.c.*`.

The raw layer should be inspectable and boring. Handwritten wrappers are optional, but they are not the language's primary ergonomics mechanism.

### Imported foreign declarations

Most application code should call imported foreign declarations, not raw `std.c.*` bindings.

Imported foreign modules are ordinary `module` files. They import a raw `std.c.*` module and re-export compiler-recognized `foreign def` declarations.

```mt
module std.raylib

import std.c.raylib as c

pub type Vector2 = c.Vector2
pub type Texture = c.Texture
pub type Color = c.Color

pub const BLACK: Color = c.BLACK
pub const GOLD: Color = c.GOLD

pub foreign def init_window(width: i32, height: i32, title: str as cstr) -> void = c.InitWindow
pub foreign def close_window() -> void = c.CloseWindow
pub foreign def window_should_close() -> bool = c.WindowShouldClose
pub foreign def get_frame_time() -> f32 = c.GetFrameTime

pub foreign def load_texture(path: str as cstr) -> Texture = c.LoadTexture
pub foreign def load_file_data(file_name: str as cstr, out data_size: i32) -> ptr[u8]? = c.LoadFileData
pub foreign def save_file_data(file_name: str as cstr, data: span[u8]) -> bool = c.SaveFileData(file_name, data.data, i32<-data.len)
pub foreign def set_shader_value[T](shader: Shader, loc_index: i32, in value: T as const_ptr[void], uniform_type: i32) -> void = c.SetShaderValue

pub foreign def mem_alloc[T](count: usize) -> ptr[T]? = c.MemAlloc(count * u32<-sizeof(T))
pub foreign def mem_realloc[T](memory: ptr[T]?, count: usize) -> ptr[T]? = c.MemRealloc(memory, count * u32<-sizeof(T))
pub foreign def mem_free[T](memory: ptr[T]?) -> void = c.MemFree(memory)
```

Types, enums, flags, and constants that need no boundary conversion should usually be re-exported with ordinary `pub type`, `pub const`, `enum`, or `flags` declarations. `foreign def` is for call boundaries, not for everything else in the module.

These declarations are not handwritten wrappers:

- one imported declaration maps directly to one foreign symbol
- there is no extra function body, hidden dispatch, or policy object
- lowering stays inspectable in generated C
- boundary conversions are declared once on the import instead of repeated at every call site

Chosen v1 form:

- `foreign def` is a new declaration kind allowed in ordinary modules
- the left side is the public Milk Tea signature
- the right side is either a raw symbol name or a declarative raw call expression
- `= c.Symbol` is shorthand for positional lowering when surface parameters map directly to the raw ABI after boundary conversion
- `= c.Symbol(...)` is required when one surface parameter fans out into multiple raw arguments, when argument order changes, or when the raw API needs size arithmetic such as `count * sizeof(T)`

The right side is deliberately not a normal function body. It is a restricted lowering clause. It may use:

- the referenced raw foreign symbol
- imported parameters
- field access such as `data.data` and `data.len`
- `cast`, `sizeof`, `alignof`, literals, `null`, and simple arithmetic

It may not use:

- control flow
- local declarations
- arbitrary function calls
- heap allocation
- `unsafe` blocks

An imported foreign declaration must be able to express at least:

- a `str` parameter that lowers to `cstr` at the foreign boundary
- ordinary `span[str]` or `array[str, N]` inputs for foreign string-list APIs
- automatic transient boundary marshalling for dynamic text when the imported declaration chooses that public surface
- `in`, `out`, and `inout` parameters that lower to raw pointers
- release-style functions that consume a handle and null the caller binding afterward
- pointer-plus-length views that lower from `span[T]`
- identity ABI projections such as `ptr[T]?` to `ptr[void]` or `cstr?` to `ptr[char]?`

Parameter and boundary rules:

- `name: str as cstr` means the public Milk Tea type is `str`, while the raw foreign target expects `cstr` or `ptr[char]`
- imported foreign declarations do not spell this surface as `str as ptr[char]`; the public text boundary stays `str as cstr` even when the raw callee argument type is `ptr[char]`
- a string literal or existing `cstr` value may satisfy `str as cstr` without temporary storage
- a dynamic `str` argument for `str as cstr` is materialized automatically at the foreign boundary for the duration of the call
- imported foreign declarations may accept `span[str]` or `array[str, N]` for string-list APIs even when the raw callee wants `span[cstr]`, `span[ptr[char]]`, or pointer-plus-length forms; that marshalling belongs to the declaration, not to the call site
- `in name: T` means the raw foreign target takes a read-only pointer and the call site must pass `in expr`; the boundary lowers by taking a const address, materializing a temporary first when the expression is not directly addressable
- `out name: T` means the raw foreign target takes a writable pointer and the call site must pass `out lvalue`
- `inout name: T` means the raw foreign target reads and writes through a pointer and the call site must pass `inout lvalue`
- `consuming name: Handle` means the public Milk Tea parameter is a non-null opaque handle or `ptr[T]`, and v1 uses it only for release-style foreign calls that consume an existing nullable binding
- plain parameters and return values require exact compatibility or an explicitly permitted identity ABI projection

#### Sema rules for foreign defs

The checker should treat `foreign def` as its own declaration kind with dedicated rules.

Declaration rules:

- `foreign def` is allowed only in ordinary modules, not inside `extern module`, `methods`, or function bodies
- the right-hand side must resolve to an imported raw extern symbol from a `std.c.*` module
- `= c.Symbol` is shorthand symbol mapping; `c.Symbol` must resolve to an imported `extern def`
- `= c.Symbol(...)` is declarative RHS mapping; the callee must resolve to an imported `extern def`
- the right-hand side may reference only declaration parameters and imported raw symbols from the module scope
- a `consuming` parameter may not use `as`, must have a non-null `opaque Handle` or `ptr[T]` type, and any `foreign def` that has a `consuming` parameter must return `void`

Shorthand symbol mapping rules:

- the public parameter count must match the raw parameter count, excluding raw varargs
- parameters map positionally in source order
- each mapped pair must satisfy one of: exact type match, declared boundary mapping such as `str as cstr`, directional pointer mapping through `out` or `inout`, or an allowed identity ABI projection
- an `in` parameter may use `as const_ptr[...]`, including `as const_ptr[void]`, to express read-only foreign borrows such as Raylib shader uniform values
- aliasing a public imported-binding type to a different raw module type does not create a new identity ABI projection. Two raw structs from different `std.c.*` modules remain distinct unless the language grows an explicit foreign type-projection rule for that pair.
- the public return type must either exactly match the raw return type or be reachable through an allowed identity ABI projection
- shorthand mapping is rejected if any surface parameter must fan out into multiple raw arguments, if any raw argument needs arithmetic over more than one parameter, or if raw argument order differs from public argument order

Declarative RHS mapping rules:

- the RHS must be a raw call expression whose callee is an imported raw extern function
- raw call arity must match the raw target signature, respecting raw varargs rules
- the checker analyzes each raw argument expression in an environment containing the public parameters
- allowed RHS expression forms are: parameter identifiers, member access, index access, literals, `null`, `sizeof`, `alignof`, `offsetof`, `cast[...]`, and simple arithmetic or comparisons built from those forms
- disallowed RHS forms are: control flow, local declarations, assignment, `unsafe`, `defer`, heap allocation, and arbitrary non-builtin function calls
- every public parameter must be consumed by the RHS according to its mode

Parameter consumption rules:

- a plain parameter may be referenced one or more times in the RHS
- a `span[T]` parameter may be split into `.data` and `.len`
- an `out` parameter must appear exactly once as a bare parameter reference in the raw argument position that receives the writable pointer
- an `in` parameter must appear exactly once as a bare parameter reference in the raw argument position that receives the read-only pointer
- an `inout` parameter must appear exactly once as a bare parameter reference in the raw argument position that receives the mutable pointer
- a `consuming` parameter lowers through the same identity value as a plain handle parameter; v1 ownership affects call-site validation and post-call flow, not the RHS mapping expression shape
- a `str as cstr` parameter may appear only in raw argument positions whose target type is `cstr` or `ptr[char]`

Call-site checking rules:

- a call to a `foreign def` with `out` parameters requires `out lvalue` at the corresponding argument position
- a call to a `foreign def` with `in` parameters requires `in expr` at the corresponding argument position
- a call to a `foreign def` with `inout` parameters requires `inout lvalue` at the corresponding argument position
- a call to a `foreign def` with `consuming` parameters requires a bare identifier naming a nullable local or parameter binding
- the current flow type of that binding must already be the non-null handle type required by the `consuming` parameter
- in v1, a foreign call with any `consuming` parameter must be a top-level expression statement; `defer`, local initializers, assignments, returns, and larger expressions are rejected
- after a `consuming` foreign call, continuation flow refines each consumed binding to `null`
- `in`, `out`, and `inout` are rejected outside calls to `foreign def`
- `in` accepts ordinary expressions; if an expression is not addressable, lowering creates a short-lived temporary before taking its const address
- `out` requires a mutable addressable lvalue and does not read the old value before the call
- `inout` requires a mutable addressable lvalue and exposes both the old and new value to the callee
- automatic foreign text marshalling is part of imported-boundary checking, not an extra source clause
- string literals and existing `cstr` values lower directly where possible, so the compiler only materializes temporary storage when the public argument actually needs it

Allowed identity ABI projections in v1 are deliberately narrow:

- `ptr[T]` or `ptr[T]?` to `ptr[void]` or `ptr[void]?`
- `ptr[T]` or `ptr[T]?` to `const_ptr[void]` or `const_ptr[void]?` for read-only foreign pointer projections
- `ptr[void]` or `ptr[void]?` to `opaque Handle` or `opaque Handle?` when the imported declaration chooses that handle surface
- `ptr[char]` or `ptr[char]?` to `cstr` or `ptr[char]?` when mutability rules permit the raw direction
- raw opaque pointer returns to typed pointer-like public returns when the representation is unchanged

Anything outside those cases requires the raw layer or an explicit later language feature. `foreign def` is not a general coercion system.

#### Lowering rules for foreign calls

`foreign def` lowers directly to the referenced raw call boundary. It does not lower as a normal Milk Tea function body.

Shorthand symbol mapping lowering:

- the call target is the referenced raw symbol
- arguments are lowered left-to-right in public parameter order
- each public argument lowers through its declared boundary rule and then into the matching raw parameter slot
- if the return type needs an allowed identity ABI projection, the backend emits the minimal explicit C cast required by the target types

Declarative RHS mapping lowering:

- the lowering clause is expanded by substituting lowered public arguments into the restricted RHS expression tree
- the expanded raw call becomes the emitted call target and raw argument list
- field access such as `data.data` and `data.len` lowers exactly as the corresponding member access on the public argument value
- builtin forms such as `cast`, `sizeof`, `alignof`, and `offsetof` lower exactly as they do elsewhere in the language

Automatic text marshalling lowering:

- if a public foreign boundary uses `str`, `span[str]`, or `array[str, N]` and the raw callee needs C-compatible text storage, the compiler materializes that storage automatically for the duration of the call
- materialization happens in left-to-right argument order so evaluation stays inspectable
- literal-backed and already-compatible arguments lower directly with no temporary storage
- dynamic `str` values lower to temporary NUL-terminated C strings when needed
- string lists lower to temporary C-string arrays or pointer-plus-length views when needed
- the temporary storage is released immediately after the raw call completes
- if code needs exact storage control or wants to avoid boundary marshalling entirely, it may call the raw `std.c.*` layer or pass already-compatible `cstr` / `span[char]` values directly

Directional pointer lowering:

- `out x` lowers to address-taking of `x` at the raw call boundary without exposing `ptr_of(ref_of(x))` in user source
- `in value` lowers to const address-taking at the raw call boundary without exposing `const_ptr_of(value)` or casts in user source; non-addressable operands lower through a visible temporary in statement-shaped foreign calls
- `inout x` lowers to the same address-taking form, but sema preserves the read-write contract instead of pure output
- if the raw target expects `ptr[void]` or another identity-projection pointer type, lowering inserts only the minimal cast required by the raw C signature

Release-function ownership lowering:

- a `consuming` argument lowers through the same raw boundary value as the corresponding plain handle argument
- immediately after the raw foreign call completes, lowering emits `binding = null` for each consumed binding
- the same statement updates continuation flow so later code sees that binding as `null`
- v1 does not add a general move checker; this null-after-call rule is limited to bare nullable local or parameter bindings in top-level expression statements

Generated C quality rule:

- lowering may introduce short-lived temporaries for foreign text marshalling, result spilling, or identity casts
- lowering should not emit an extra helper function for each `foreign def` in the ordinary case
- the preferred output is one visible raw call site whose surrounding temporaries make the boundary work obvious in C

Call sites should read like this:

```mt
rl.init_window(screen_width, screen_height, "Milk Tea")
let texture = rl.load_texture(path)
let file_data = rl.load_file_data("storage.data", out data_size)
let success = rl.save_file_data("storage.data", bytes)
let ints = rl.mem_alloc[i32](16)
```

`str as cstr` and `span[str]` foreign boundaries use ordinary imported-call syntax. When the boundary needs synthesized temporary C-compatible storage or other statement-shaped setup, lowering hoists that work into visible temporary locals and branch-local control flow as needed, so nested call arguments, arithmetic, `if ... then ... else ...` expressions, and short-circuit boolean expressions still read like ordinary Milk Tea while generated C stays explicit about the temporary storage.

`in name`, `out name`, and `inout name` are foreign-boundary forms, not raw pointer expressions. They lower to address-taking at the imported call site without exposing `const_ptr_of(...)`, `ptr_of(ref_of(...))`, or ABI casts in ordinary code.

This is the C# part worth copying: declarations say how the boundary works, while raw pointer code remains explicitly low-level.

### Strings and buffers at the FFI boundary

String and buffer rules must stay explicit, but the explicitness belongs in imported declarations, not in every call site:

- raw `extern module` declarations stay exact and continue to use `cstr`, `ptr[T]`, and `ptr[void]`
- a string literal may satisfy a contextual `cstr` position directly; ordinary UI code should not need `c"..."` just to populate `cstr` locals, `array[cstr, N]`, or borrowed C-string arguments
- converting a dynamic `str` or `span[str]` to foreign C-compatible text is automatic when an imported declaration chooses that public surface
- `cstr` remains available for raw ABI work, returned native strings, and low-level code
- pointer-plus-length APIs should import as `span[T]` when the native contract is a view rather than untyped memory
- single-object output parameters should import as `out T` or `inout T` instead of naked pointer syntax
- `ptr[void]` should stay in the raw layer, but imported declarations may project it to typed pointers or opaque handles when the ABI conversion is identity-only

This keeps the important distinction intact:

- source code thinks in `str`, `array[str, N]`, `span[str]`, and one mutable text buffer type
- raw memory work still requires raw syntax
- call sites stop spelling C representation details that the import declaration already knows

### Callbacks

Callbacks must map directly to C function pointers.

```mt
type LogCallback = fn(level: i32, message: cstr, user_data: ptr[void]) -> void
```

Capturing closures should not be lowered to hidden heap objects. If user state is needed, pass it explicitly as `user_data`.

## Data layout and ABI controls

The language must expose a small set of layout controls for interop and SIMD-friendly code.

```mt
packed struct FileHeader:
	magic: array[u8, 4]
	version: u16

align(16) struct Mat4:
	m: array[f32, 16]
```

Required controls:

- `packed struct`
- `align(n)`
- `sizeof(T)`
- `alignof(T)`
- `offsetof(T, field)`
- `static_assert(condition, message)`

These are not niche. They are mandatory for FFI and engine code.

## Generated C quality bar

Milk Tea only succeeds if the generated C is respectable.

### Generated C requirements

1. Keep one obvious symbol mapping from source to C.
2. Preserve source names as much as the C target allows.
3. Emit straightforward local variables and control flow.
4. Lower methods to plain functions.
5. Lower `match` to `switch` where possible.
6. Lower `defer` to readable cleanup labels or scoped cleanup blocks.
7. Avoid a mandatory runtime beyond what is needed for startup, panic hooks, and core helper intrinsics.

Example lowering:

Milk Tea:

```mt
struct Player:
	position: Vec2
	velocity: Vec2

methods Player:
	edit def update(dt: f32):
		this.position.x += this.velocity.x * dt
		this.position.y += this.velocity.y * dt
```

Target C:

```c
typedef struct game_Vec2 {
	float x;
	float y;
} game_Vec2;

typedef struct game_Player {
	game_Vec2 position;
	game_Vec2 velocity;
} game_Player;

static void game_Player_update(game_Player* this, float dt) {
	this->position.x += this->velocity.x * dt;
	this->position.y += this->velocity.y * dt;
}
```

This is the standard to protect. If the generated C becomes harder to read than hand-written C, the language has drifted.

## Feature set recommendation for v1

The full vision should be staged. A shippable v1 needs the smallest feature set that still proves the language works for real game code.

### Ship in v1

- indentation-based parser
- modules and imports
- `let`, `var`, `const`
- functions and method sugar via `methods`
- structs, enums, flags, unions, opaque types, type aliases
- arrays, pointers, spans, function pointers
- `if`, `while`, `for`, `match`, `defer`, `unsafe`
- explicit casts
- `extern module` declarations
- clang-driven bindgen for `std.c.*`
- readable C backend

### Defer until later

- generic constraints
- interfaces
- async
- exceptions
- metaprogramming
- custom operators
- package registry
- hidden managed runtime features

## Summary

Milk Tea should be a language where:

- the syntax is calm and readable
- the type system is explicit but not academic
- the memory model is fast and honest
- pointers are available without shame
- C libraries fit naturally
- the generated C remains clean enough to trust

That combination is the point. The language should feel like a better place to write the kind of code people currently force into C, C++, or Rust even when those languages are fighting the job.

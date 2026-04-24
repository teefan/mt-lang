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
- No hidden allocation for strings, collections, closures, or method calls

## Design rules

### 1. What you see is what runs

If code allocates, takes an address, dereferences a raw pointer, performs an FFI call, or enters unsafe territory, the source should say so directly.

### 2. C is the ABI ground truth

Milk Tea must represent C structs, unions, enums, flags, pointers, arrays, callbacks, and calling conventions without lossy translation.

### 3. Safe by default, unsafe by choice

The language should help with common mistakes, but it must not hide the machine model. Sharp operations are allowed, but only behind explicit syntax.

### 4. Data-oriented design comes first

Plain structs, arrays, spans, pools, and arenas matter more than elaborate object systems.

### 5. The language surface stays small

If a feature saves five lines but makes lowering, tooling, or debugging much harder, it does not belong in v1.

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

Example:

```mt
module game.main

import std.math as math
import std.c.raylib as rl

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
	rl.InitWindow(screen_width, screen_height, c"Milk Tea")
	defer rl.CloseWindow()

	var player = Player(
		position = rl.Vector2(x = 400.0, y = 300.0),
		velocity = rl.Vector2(x = 140.0, y = 100.0),
		radius = 18.0,
	)

	while not rl.WindowShouldClose():
		let dt = rl.GetFrameTime()
		player.update(dt)

		rl.BeginDrawing()
		defer rl.EndDrawing()

		rl.ClearBackground(rl.BLACK)
		rl.DrawCircleV(player.position, player.radius, rl.GOLD)

	return 0
```

## Syntax and readability rules

Milk Tea should use a deliberately small punctuation set. The only everyday symbolic forms are:

- `:` for blocks
- `->` for function return types
- `.` for field and module access
- `[]` for indexing and generic arguments
- `&` for address-of
- `*` for dereference
- `?` for nullable types

Everything else should prefer words over symbols.

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

```mt
let width: i32 = 1280
var score: i32 = 0
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
def load_texture(path: str, space: ref[Arena]) -> Result[Texture, LoadError]:
	let temp = value(space).mark()
	defer value(space).reset(temp)

	let c_path = path.to_cstr(space)
	let texture = rl.LoadTexture(c_path)

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
- direct ABI edge work that the compiler cannot validate

```mt
unsafe:
	let p = pixels + offset
	let pixel = value(cast[ptr[u32]](p))
```

The point is not to forbid sharp tools. The point is to mark them.

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
- `cstr` is a NUL-terminated C string reference for ABI calls.
- `char` is the ABI-facing single-byte character type for C text and raw buffers. It is not a general arithmetic integer type.
- String literals produce `str`.
- `c"hello"` produces `cstr` with static storage.

### Composite types

```mt
array[T, N]      # fixed-size array
ptr[T]           # raw pointer
span[T]          # pointer + length view
fn(A, B) -> R    # function pointer type
```

Examples:

```mt
let pixels: span[u8]
let texture_ptr: ptr[Texture]
let normal_table: array[f32, 256]
let callback: fn(ptr[void], i32) -> void
```

Notes:

- Fixed-array indexing is bounds-checked and safe by default.
- Safe array indexing requires an addressable array value; bind temporaries before indexing them.
- Pointer indexing follows the raw pointer model and requires `unsafe`.

### Nullability

Milk Tea keeps nullability explicit.

```mt
let window: ptr[Window]? = null
let name: cstr? = null
```

Only nullable pointer-like types may hold `null`.

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
- monomorphized code generation

Not allowed in v1:

- specialization
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
```

## Expressions and conversions

### Operators

Built-in operators should match familiar C behavior where possible:

- arithmetic: `+ - * / %`
- comparison: `== != < <= > >=`
- boolean: `and or not`
- bitwise: `& | ^ ~ << >>`

No user-defined operator overloading.

### Casts

Conversions are explicit.

```mt
let count64 = cast[u64](count32)
let value = cast[f32](raw)
let newline = cast[char](10)
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

`char` stays outside the general numeric-promotion rules. If code wants arithmetic on a character value, cast it to an integer type first. If code wants to write bytes back into a `char` buffer, either use an explicit `cast[char](...)` or rely on the expected `char` boundary where a known `char` target is being initialized or assigned.

Example:

```mt
let newline = cast[char](10)

unsafe:
	buffer[0] = 65
	buffer[1] = newline
	let code = cast[i32](buffer[0])
```

### Literals

```mt
42
0xff
0b1010
3.14159
'a'
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
	let enemy = heap.alloc[Enemy](1)
	unsafe:
		value(enemy).position = start
		value(enemy).health = 100
	return enemy
```

Recommended standard memory surfaces:

- `std.mem.heap` for general allocation and the raw `*_bytes` boundary
- `std.mem.arena` for frame, level, and scratch lifetimes
- `std.mem.pool` for fixed-size object pools
- `std.mem.stack` for explicit temporary allocators

Typed allocation helpers live on the module surface where generic methods are not available yet. For example, `heap.alloc[Enemy](1)`, `arena.alloc[Enemy](addr(scratch), 4)`, and `stack.alloc[Enemy](addr(temp), 2)` all stay explicit about allocator choice, while raw byte APIs remain available for lower-level storage work.

### Pointers and references

Pointers are still first-class because game code needs raw memory and FFI. The source model is explicit and uniform.

```mt
let position_ref = addr(player.position)
let position_ptr = raw(position_ref)

value(position_ref).x += 1

unsafe:
	value(position_ptr).x += 1
```

Rules for safe references:

- `ref[T]` is a non-null writable safe alias to one live object.
- `addr(expr)` requires a mutable addressable lvalue source and produces `ref[T]`.
- `value(ref_value)` is safe and yields the referenced lvalue/value.
- `raw(ref_value)` converts a safe reference to `ptr[T]` explicitly.
- there is no auto projection through refs: use `value(handle).field` and `value(handle).edit_method()`.
- there is no implicit ref-to-value call conversion: if a function expects `T`, pass `value(handle)`.
- references do not support arithmetic, pointer indexing, or nullable semantics.
- writable references are non-escaping in the current implementation: they may be used in locals and non-extern function parameters, but they cannot be stored, nested inside other types, returned, or accepted by extern functions.

Rules for raw pointers:

- `ptr[T]` and `ptr[T]?` are raw pointer values.
- there is no source `&expr`, `*ptr`, or `ptr->field`.
- spell address formation as `addr(expr)` and raw pointer formation as `raw(addr(expr))` when you truly need a raw pointer.
- `value(ptr)` dereferences a raw pointer and requires `unsafe`.
- `value(ptr).field` accesses a member through a raw pointer and requires `unsafe`.
- pointer arithmetic and pointer indexing remain `unsafe`.
- raw pointer offsets and indices may use ordinary integer expressions directly; code does not need a pre-emptive cast to `usize` just to write `ptr[i]` or `ptr + offset`.
- pointer comparison is explicit and never treated as boolean truthiness.
- `ptr[char]` is the ordinary representation for mutable C text and byte-oriented FFI buffers; writing control bytes such as NUL or newline uses `char` values, typically spelled with `cast[char](0)` and `cast[char](10)`.

References are separate from methods:

- plain methods still receive values.
- `edit def` methods use the writable implicit receiver and require an addressable call target.
- `static def` methods receive nothing.
- `ref[T]` is for explicit aliasing in APIs, not hidden receiver lowering.

This gives the language clear aliasing tools instead of one overloaded surface:

- `ref[T]` for safe aliasing of one mutable object
- `ptr[T]` and `ptr[T]?` for raw memory and FFI
- `span[T]` for sized borrowed views over raw pointer data

### Spans

Raw pointers are necessary. Spans are the readable everyday view.

```mt
span[T] is conceptually:
	data: ptr[T]
	len: usize
```

`span[T]` should be built into the language surface as a standard view type because it is the right default for arrays, buffers, decoded file content, vertex streams, and audio samples.

`span[T]` is the many-element view. `ref[T]` and `ref[const T]` are the single-object references.

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
- explicit status codes for thin FFI wrappers when that matches the C API better

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

import std.c.raylib as rl
import game.assets
```

Rules:

- one top-level module per file
- explicit imports only
- no wildcard imports in v1
- no cyclic imports
- package naming stays filesystem-friendly

Recommended layout:

- `std.*` for core library modules
- `std.c.*` for raw bindgen-generated C modules
- `std.wrap.*` for optional ergonomic wrappers over raw C modules
- project modules under their own root namespace

## FFI design

FFI is a core feature, not a bolt-on.

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

The raw layer should be inspectable and boring. Higher-level wrapper modules may exist, but they must remain optional.

### Strings and buffers at the FFI boundary

String and buffer rules must stay explicit:

- `str` does not silently become `cstr`
- string literals can use `c"..."` when a static C string is required
- converting `str` to `cstr` requires an explicit allocator or temporary arena copy
- binary data crosses FFI as `ptr[T]`, `span[T]`, or fixed arrays

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

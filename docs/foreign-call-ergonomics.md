# Foreign Call Ergonomics V2

This note turns the highest-impact ergonomics backlog items into a concrete language direction.

The goal is not to add more helper modules on top of rough APIs. The goal is to make imported foreign declarations strong enough that ordinary application code can call C libraries as if they were ordinary Milk Tea modules, while the raw `std.c.*` layer remains exact.

## Problem statement

The current language already has the right high-level shape for game code:

- `defer` is good enough for resource cleanup.
- loops and data-oriented structs are good enough for gameplay code.
- imported `foreign function` already owns marshalling policy instead of forcing every call site to spell C ABI details.

The remaining friction is concentrated at the imported foreign boundary.

Observed recurring pain in the current examples:

- repeated borrow syntax such as `ptr_of(...)`, `const_ptr_of(...)`, `out ...`, and `in ...`
- repeated raw failure checks such as `if window == null:` and `if not sdl.init(...):`
- imported surfaces that still leak raw `cstr`, raw pointer, or raw loader concerns into application code
- helper modules that exist mainly because the imported call surface is not yet expressive enough

Examples:

```mt
# current raylib / SDL3 style
let window = sdl.create_window(window_title, window_width, window_height, window_flags)
if window == null:
    return 1

# current SDL3 style
if not sdl.create_window_and_renderer(window_title, window_width, window_height, window_flags, out window, out renderer):
    return 1

if not sdl.get_window_size_in_pixels(window, out width, out height):
    return 1

# current imported pointer-borrow style
rl.set_shader_value(shader, location, in matrix, uniform_type)
```

That is still too close to raw interop for the intended user-facing surface.

## Goals

1. Imported libraries should read like authored Milk Tea APIs.
2. Raw `std.c.*` bindings should remain exact and explicitly low-level.
3. Generated C should stay direct and inspectable.
4. The design should remove helper-module demand rather than institutionalize it.
5. The surface should stay small. One canonical form per job.

## Non-goals

1. Do not add hidden runtime ownership machinery.
2. Do not add exceptions.
3. Do not make raw pointers implicit in ordinary code.
4. Do not solve interop pain by proliferating handwritten wrapper layers that only paper over boundary weaknesses.

## Decision 1: Directional borrows are declaration-owned, not call-site-owned

### Summary

Keep `in`, `out`, and `inout` as imported-declaration concepts.

Remove them from ordinary call syntax.

Application code should pass ordinary expressions or lvalues. The callee declaration already knows whether the boundary needs a const borrow, writable borrow, or read-write borrow.

### Why

The current call-site markers repeat information that is already present in the imported declaration.

They are honest, but they are still noise.

The declaration site is where ABI policy belongs. The call site should show program intent, not borrow mechanics.

This matches the existing design rule already used elsewhere in the language:

- methods own receiver mutability
- imported foreign declarations own marshalling policy
- raw pointer syntax is reserved for raw code

### Proposed rule

Imported declarations continue to declare parameter direction:

```mt
public foreign function set_shader_value[T](shader: Shader, loc_index: int, in value: T as const_ptr[void], uniform_type: int) -> void = c.SetShaderValue
public foreign function get_render_output_size(renderer: Renderer, out width: int, out height: int) -> bool = c.GetRenderOutputSize
public foreign function update_camera(inout camera: Camera, mode: CameraMode) -> void = c.UpdateCamera
```

But ordinary call sites become:

```mt
rl.set_shader_value(shader, location, matrix, uniform_type)
sdl.get_render_output_size(renderer, width, height)
rl.update_camera(camera, rl.CameraMode.CAMERA_FREE)
```

Not:

```mt
rl.set_shader_value(shader, location, in matrix, uniform_type)
sdl.get_render_output_size(renderer, out width, out height)
rl.update_camera(inout camera, rl.CameraMode.CAMERA_FREE)
```

### Sema rules

For ordinary calls to imported `foreign function` only:

- `in` parameters accept any expression
- `out` parameters require a mutable addressable lvalue
- `inout` parameters require a mutable addressable lvalue
- plain parameters behave exactly as they do today

For raw `external function` calls:

- nothing changes
- raw code still spells raw pointer operations explicitly

This preserves the clean split between imported ergonomics and raw ABI exactness.

### Lowering rules

- `in` lowers to a const address-taking borrow at the boundary
- non-addressable `in` expressions materialize a short-lived temporary before the raw call
- `out` lowers to writable address-taking at the boundary
- `inout` lowers to writable address-taking with ordinary read-write semantics
- generated C may still contain explicit temporaries and address operations, but user source should not

### Imported surface defaults

This decision only pays off if imported declarations also stop choosing raw pointer-heavy public types unnecessarily.

Imported policy should prefer:

- `str` over `cstr` for immutable inbound text
- `span[T]` over pointer-plus-length pairs
- `array[str, N]` or `span[str]` over raw `char **` families
- `out T` or `inout T` over naked single-object pointer parameters
- opaque handle types over raw `ptr[void]` or raw library pointer aliases when representation is identity-only

Examples of the intended imported surfaces:

```mt
public foreign function render_rects(renderer: Renderer, rects: span[FRect]) -> void = c.SDL_RenderRects(renderer, rects.data, int<-rects.len)
public foreign function get_render_output_size(renderer: Renderer, out width: int, out height: int) -> bool = c.SDL_GetRenderOutputSize
public foreign function set_shader_value[T](shader: Shader, loc_index: int, in value: T as const_ptr[void], uniform_type: int) -> void = c.SetShaderValue
```

Application code should then read like this:

```mt
sdl.render_rects(renderer, rects)
sdl.get_render_output_size(renderer, width, height)
rl.set_shader_value(shader, location, matrix, uniform_type)
```

### Impact

This removes the most repetitive interop syntax from ordinary code without weakening the raw layer.

It also reduces pressure to add helper modules whose only job is to hide borrow spelling.

## Decision 2: Imported failures should be modeled explicitly, then handled with one small core control-flow form

### Summary

Imported declarations should model operational failure directly.

Then the language should provide one canonical success-binding form:

```mt
let value = fallible_expr else:
    handle_failure()
```

This is the recommended core feature for imported-call failure handling.

### Why

The examples repeatedly do one of two things:

```mt
let window = sdl.create_window(...)
if window == null:
    return 1
```

or:

```mt
if not sdl.init(sdl.INIT_VIDEO):
    return 1
```

That is explicit but repetitive. It also keeps ordinary source tied to the raw failure sentinel shape instead of the semantic meaning of the call.

The imported layer should know whether a function fails by returning `null`, `false`, `-1`, or some other sentinel. The user-facing surface should expose either:

- a nullable value when absence is ordinary and expected
- a `status.Status[T, E]` when the API represents operational failure

### Proposed modeling rule

Imported declarations should distinguish two cases.

#### 2.1 Optional absence

Use a nullable return only when the API really means “might legitimately be absent”.

Examples:

- optional clipboard content
- monitor lookup that may not exist
- lookup APIs where null means “not found” rather than “operation failed”

These remain `T?`.

#### 2.2 Operational failure

Use `status.Status[T, ForeignError]` or `status.Status[void, ForeignError]` when a sentinel means the operation failed and the library provides error context or a meaningful failure contract.

Examples:

- window creation
- renderer creation
- device or context creation
- subsystem initialization
- image, texture, and audio loading where failure is not an ordinary optional case

That means imported SDL3 surfaces and similar setup-oriented APIs should usually stop exporting raw `bool` or raw nullable handle failure contracts for setup and creation APIs.

### Core language feature: binding else

Add one small control-flow form:

```mt
let value = expr else:
    failure_path
```

Semantics:

- if `expr` has type `T?`, the `else` block runs when the value is `null`; otherwise `value` is bound as non-null `T`
- if `expr` has type `status.Status[T, E]`, the `else` block runs on `.err`; otherwise `value` is bound as `T`
- the `else` block must exit the current control-flow path via `return`, `break`, `continue`, or `panic`

Examples:

```mt
let window = sdl.create_window(window_title, window_width, window_height, window_flags) else:
    return 1

let renderer = sdl.create_renderer(window, null) else:
    return 1

let texture = rl.load_texture(path) else:
    return 1
```

For status-style imported calls, the imported surface should prefer `status.Status[void, ForeignError]` so the same feature works:

```mt
let _ = sdl.init(sdl.INIT_VIDEO) else:
    return 1

let _ = sdl.set_app_metadata("game", "0.1.0", "dev.example.game") else:
    return 1
```

`let _ =` is acceptable here because status-only setup calls are a boundary concern, not the hot path of everyday gameplay code.

### Why not keep raw bool and nullable checks everywhere

Because the imported surface then fails to do its main job.

The imported layer exists specifically so application code does not have to keep spelling raw ABI contracts.

If the user still writes `if value == null` and `if not ok` for every foreign call, the imported layer is only partially succeeding.

### Why not add exceptions

Because that would violate the existing language design. Failures should stay explicit in source and easy to lower to readable C.

`let ... else:` is explicit, local, and inspectable.

## Recommended imported-binding policy changes

These language changes only pay off if imported policy generation follows the same direction.

Recommended policy defaults:

1. Immutable text arguments default to `str as cstr`.
2. Pointer-plus-length inputs default to `span[T]`.
3. Single writable pointer parameters default to `out T` or `inout T`.
4. Identity-only `void *` handles default to imported opaque handle types.
5. Creation and initialization functions default to `status.Status[...]` when failure is operational.
6. Null-return lookups stay nullable only when absence is semantically ordinary.

If a header is too ambiguous to classify honestly, keep that API raw rather than guessing.

## Before and after

### Current SDL3 setup

```mt
if not sdl.init(sdl.INIT_VIDEO):
    return 1

if not sdl.create_window_and_renderer(window_title, window_width, window_height, window_flags, out window, out renderer):
    return 1

if not sdl.get_window_size_in_pixels(window, out width, out height):
    return 1
```

### Intended SDL3 setup

```mt
let _ = sdl.init(sdl.INIT_VIDEO) else:
    return 1

let window = sdl.create_window(window_title, window_width, window_height, window_flags) else:
    return 1

let renderer = sdl.create_renderer(window) else:
    return 1

sdl.get_window_size_in_pixels(window, width, height)
```

### Current imported borrow-heavy call

```mt
rl.set_shader_value(shader, location, in matrix, uniform_type)
```

### Intended call

```mt
rl.set_shader_value(shader, location, matrix, uniform_type)
```

## Anti-goal

Do not respond to these problems by adding more wrapper modules whose only job is hiding imported-call syntax.

If a helper exists only to hide imported-call syntax that the compiler and imported-binding system should already know how to lower, the design is still wrong at the root.

Helper modules are acceptable only when they add real domain logic or policy, not when they patch routine foreign-boundary friction.

## Recommended implementation order

1. Change imported-call sema and lowering so `in`, `out`, and `inout` are declaration-owned and disappear from ordinary call syntax.
2. Extend imported-binding policy metadata so generated imported APIs can classify operational failure versus optional absence.
3. Add `let value = expr else:` for nullable and `Result` success binding.
4. Regenerate imported SDL3 and raylib surfaces toward the new defaults.
5. Delete helper APIs that only existed to compensate for the old boundary limitations.

## Expected outcome

When this work is done, the language should converge on a clear split:

- raw modules are exact, pointer-heavy, and explicit
- imported modules are honest but pleasant
- gameplay code reads like Milk Tea, not like lightly disguised C

That is the correct direction for the project goal of a friendly core language design without wrapper sprawl.

# Multiplayer Networking Attributes And Compiler Hooks

Status: locked (Phase D)

This document proposes a compiler-assisted multiplayer surface for Milk Tea.
It does not add new declaration keywords.
Instead, it standardizes a small set of compiler-recognized attributes exported by `std.multiplayer` and a narrow pair of descriptor hooks consumed by the standard library:

- `state_descriptor[T]()`
- `rpc_descriptor(callable_of(...))`

V1 fixes three implementation-sensitive choices up front:

- `@[rpc(...)]` marks inbound handlers only; ordinary local calls stay ordinary local calls
- the only compiler hooks are `state_descriptor[T]()` and `rpc_descriptor(callable_of(...))`
- the wire-safe subset is closed and exact instead of open-ended or codec-driven

The design targets server-authoritative multiplayer first.
It is intended to support a friendly standard-library surface over ENet now and future ICE/libjuice backends later, without turning the language into an engine-specific runtime.

This RFC is the language-facing half of the larger design described in [Multiplayer Standard Library Design](multiplayer-standard-library.md) and [std.multiplayer.enet Implementation Plan](multiplayer-enet-implementation-plan.md).

## Summary

Milk Tea should support multiplayer state replication and typed remote procedure calls through standard attribute syntax:

```mt
import std.multiplayer as mp

@[mp.replicated(authority = mp.Authority.server)]
public struct PlayerState:
    @[mp.sync(mode = mp.TransferMode.unreliable_ordered, channel = 0, rate_hz = 30, target = mp.SyncTarget.observers)]
    position: math.Vec3

    @[mp.sync(mode = mp.TransferMode.unreliable_ordered, channel = 0, rate_hz = 30, target = mp.SyncTarget.observers)]
    velocity: math.Vec3

    @[mp.sync(mode = mp.TransferMode.reliable, channel = 0, rate_hz = 0, target = mp.SyncTarget.observers)]
    health: int

    @[mp.sync(mode = mp.TransferMode.reliable, channel = 0, rate_hz = 0, target = mp.SyncTarget.owner)]
    ammo: int


@[mp.rpc(
    direction = mp.RpcDirection.client_to_server,
    mode = mp.TransferMode.unreliable_ordered,
    channel = 1,
    require_owner = true,
)]
public function submit_input(context: mp.RpcContext, entity: mp.EntityId, input: PlayerInput) -> void:
    ...


@[mp.rpc(direction = mp.RpcDirection.server_to_owner, mode = mp.TransferMode.reliable, channel = 0, require_owner = false)]
public function respawn(context: mp.RpcContext, entity: mp.EntityId, at: math.Vec3) -> void:
    ...


function build_registry() -> mp.Registry:
    var registry = mp.Registry.create()
    let _ = registry.add_state(mp.state_descriptor[PlayerState]()) else:
        fatal(c"state registration failed")
    let _ = registry.add_rpc(mp.rpc_descriptor(callable_of(submit_input))) else:
        fatal(c"rpc registration failed")
    let _ = registry.add_rpc(mp.rpc_descriptor(callable_of(respawn))) else:
        fatal(c"rpc registration failed")
    return registry
```

The compiler validates the attribute usage, synthesizes hidden encode/decode/dispatch helpers, and exposes those helpers only through the narrow `std.multiplayer` descriptor surface.

## Goals

1. Reuse Milk Tea's existing declaration-attribute system instead of inventing a second networking-specific syntax family.
2. Make server-authoritative multiplayer state and typed RPCs easy to declare and hard to mis-wire.
3. Keep the runtime explicit: networking remains a standard-library stack over concrete transports such as ENet.
4. Avoid string-named RPCs, runtime reflection scans, and engine-owned object hierarchies.
5. Generate concrete serializers, delta encoders, RPC dispatch tables, and protocol hashes at compile time.
6. Keep the public language surface narrow enough that ordinary game code can understand what is being replicated and what is not.

## Non-goals

1. This RFC does not add a new `network`, `replicated`, or `rpc` declaration keyword.
2. This RFC does not add runtime attribute reflection, runtime declaration walking, or dynamic registration by string name.
3. This RFC does not add general schema evolution or backwards-compatible wire negotiation. In this repository, schema changes are allowed to be final and breaking.
4. This RFC does not add full client-side prediction or rollback/replay netcode.
5. This RFC does not add matchmaking, room discovery, lobby services, or cloud hosting APIs.
6. This RFC does not add automatic scene replication, object hierarchies, or engine-style component discovery.
7. This RFC does not make arbitrary heap-owning library types automatically wire-safe.
8. This RFC does not define the ICE/libjuice transport backend. That backend is a follow-on library concern.

## Rationale

Milk Tea already has the right basic ingredients for a small compiler-assisted multiplayer model:

- declaration attributes are implemented and semantically validated already
- compile-time callable handles already exist through `callable_of(...)`
- the standard library already prefers explicit ownership, `Result` return values, and small opinionated wrappers over low-level primitives
- raw ENet and libjuice bindings already exist in `std.enet` and `std.libjuice`

The language does not have, and should not grow, a C#-style runtime reflection system, a Unity-style `NetworkBehaviour` inheritance tree, or a Godot-style scene tree built into the language core.

The correct direction is smaller:

- attributes remain passive metadata
- sema validates a narrow, compiler-recognized attribute vocabulary exported by `std.multiplayer`
- lowering synthesizes concrete helpers from those validated declarations
- the standard library consumes the generated descriptors and helper functions

That keeps the language aligned with the rest of the codebase:

- no hidden global registry scans
- no string dispatch for gameplay RPCs
- no magical runtime object ownership model
- no special engine object base class

## Design Overview

This RFC standardizes exactly three compiler-recognized attribute names when they resolve to declarations exported by `std.multiplayer`:

- `replicated`
- `sync`
- `rpc`

Those are ordinary attributes in source.
They become special only after ordinary semantic name resolution proves that they refer to the exported `std.multiplayer` declarations.

That means:

- module aliases are fine, for example `import std.multiplayer as mp`
- renaming or shadowing still follows ordinary semantic resolution rules
- a user-defined `replicated` attribute in another module does not get special compiler behavior

V1 also fixes a few cost-sensitive boundaries explicitly:

- all networking attribute arguments are written explicitly in source unless the struct uses `@[sync_defaults(...)]` and fields use marker-form `@[sync]`; in that case `sync_defaults` is the single explicit source of channel/rate/target/mode
- `@[rpc(...)]` changes descriptor generation and inbound dispatch only; it does not rewrite ordinary function calls into network sends
- send-side ergonomics remain ordinary library APIs in v1 rather than additional compiler hooks (for example budgeted, weighted, fair, and tick-dispatch session helpers in `std.multiplayer.enet`)

## Standard Attribute Vocabulary

The `std.multiplayer` module should export this attribute vocabulary:

```mt
public attribute[struct] replicated(authority: Authority)
public attribute[field] sync(
    mode: TransferMode,
    channel: ubyte,
    rate_hz: uint,
    target: SyncTarget,
)
public attribute[callable] rpc(
    direction: RpcDirection,
    mode: TransferMode,
    channel: ubyte,
    require_owner: bool,
)
```

The compiler-recognized attribute shape is exactly the one above.
V1 does not invent default `require_owner` values during semantic analysis or lowering.
For sync metadata, v1 accepts either fully explicit `@[sync(...)]` per field or marker-form `@[sync]` when the enclosing replicated struct provides explicit `@[sync_defaults(...)]`.

Recommended enum surface:

```mt
public enum Authority: ubyte
    server = 0
    owner = 1

public enum TransferMode: ubyte
    unreliable = 0
    unreliable_ordered = 1
    reliable = 2

public enum SyncTarget: ubyte
    observers = 0
    owner = 1

public enum RpcDirection: ubyte
    client_to_server = 0
    server_to_owner = 1
    server_to_connection = 2
    server_to_observers = 3
    server_to_all = 4
```

## Syntax

### Replicated state declarations

A replicated state declaration is an ordinary struct declaration with a `@[replicated(...)]` attribute:

```mt
@[mp.replicated(authority = mp.Authority.server)]
public struct ProjectileState:
    @[mp.sync(mode = mp.TransferMode.unreliable_ordered, channel = 0, rate_hz = 30, target = mp.SyncTarget.observers)]
    position: math.Vec3

    @[mp.sync(mode = mp.TransferMode.unreliable_ordered, channel = 0, rate_hz = 30, target = mp.SyncTarget.observers)]
    velocity: math.Vec3

    @[mp.sync(mode = mp.TransferMode.reliable, channel = 0, rate_hz = 0, target = mp.SyncTarget.observers)]
    active: bool
```

Only fields marked with `@[sync(...)]` participate in the replicated wire schema.
Unannotated fields remain local-only state.

### RPC declarations

An RPC declaration is an ordinary top-level function with an `@[rpc(...)]` attribute:

```mt
@[mp.rpc(direction = mp.RpcDirection.client_to_server, mode = mp.TransferMode.unreliable_ordered, channel = 1, require_owner = true)]
public function submit_input(context: mp.RpcContext, entity: mp.EntityId, input: PlayerInput) -> void:
    ...
```

The runtime dispatches the RPC handler on receipt.
Outbound sending stays a library concern and is described in [Multiplayer Standard Library Design](multiplayer-standard-library.md).
Applying `@[rpc(...)]` does not change the semantics of an ordinary local call to `submit_input(...)`.
Reading `RpcContext` or payload values is ordinary safe code; `unsafe:` is only relevant for Milk Tea's raw-pointer operations.

For gameplay-loop ergonomics, ENet exposes one-call inbound processing in addition to low-level queue pop APIs:

- `process_incoming_snapshots()` applies queued snapshot payloads to `World`
- `process_incoming_rpcs_typed(table)` dispatches queued RPC payloads through typed handlers

### Descriptor hook functions

The compiler must support these narrow library hooks in `std.multiplayer`.
The relevant user-facing surface is a narrow typed hook plus one required call shape, not a general runtime reflection API:

```mt
state_descriptor[T]()
rpc_descriptor(target: callable_handle)
```

Rules:

1. `state_descriptor[T]()` is valid only when `T` resolves to a `@[replicated(...)]` struct.
2. `rpc_descriptor(target: callable_handle)` is valid only when `target` is written directly as `callable_of(name)` and `name` resolves to a top-level `@[rpc(...)]` callable.
3. These hooks lower directly to generated static descriptor objects. They are not general runtime reflection.
4. No additional send-side multiplayer compiler hook is part of v1.

Send-side note:

- Outbound replication and RPC send ergonomics are library-level APIs on sessions (`std.multiplayer.enet`) and may include convenience helpers such as budget planning or fair/weighted fanout.
- These helpers are runtime APIs, not compiler hooks.

## Semantic Rules

### `replicated`

`@[replicated(...)]` is valid only on ordinary non-generic struct declarations.

Rules:

1. `replicated` targets only `struct`.
2. `replicated` is rejected in raw `external` files.
3. Generic replicated structs are rejected in v1.
4. At least one field in the struct must carry `@[sync(...)]`.
5. Event members on the outer replicated struct are allowed as ordinary local functionality, but are ignored by the network schema. This exception does not make nested event-bearing structs wire-safe.
6. The attribute argument `authority` is required in v1. The standard library may offer helpers to spell the default explicitly.

### `sync`

`@[sync(...)]` is valid only on fields inside a `@[replicated(...)]` struct.

Rules:

1. Applying `sync` outside a replicated struct is an error.
2. Field order in source defines the generated field index and bit position used by delta masks in v1.
3. `channel` must be a compile-time integer in range `0 .. 255`.
4. `rate_hz` must be a compile-time non-negative integer. `0` means "eligible every snapshot tick when changed".
5. `target = owner` is only valid when the enclosing struct authority is `server` or `owner` and the runtime entity has a meaningful owner.
6. Duplicate `sync` applications on one field are rejected.

### `rpc`

`@[rpc(...)]` is valid only on ordinary top-level functions in v1.

Rules:

1. Methods inside `extending` blocks are rejected in v1.
2. `async`, `foreign`, and `external` functions are rejected.
3. Generic RPC handlers are rejected in v1.
4. The return type must be `void`.
5. The first parameter must be `std.multiplayer.RpcContext`.
6. All remaining parameters must be wire-safe types.
7. `require_owner` is only meaningful for `direction = client_to_server`; other directions must use `require_owner = false`.
8. Applying `@[rpc(...)]` does not change ordinary local call semantics. Local calls remain local-only.
9. Accessing `RpcContext` and other RPC parameters is ordinary safe code. `unsafe:` is required only if the handler itself performs unsafe raw-pointer operations.
10. Duplicate `rpc` applications on one callable are rejected.

## Wire-Safe Type Subset

V1 networking code generation should accept only a narrow wire-safe subset.

Supported exactly in v1:

- scalar primitives `bool`, `byte`, `ubyte`, `char`, `short`, `ushort`, `int`, `uint`, `long`, `ulong`, `float`, and `double`
- `enum` and `flags` declarations whose underlying type is one of the supported scalar primitives
- `type` aliases whose resolved target type is itself supported
- fixed-size `array[T, N]` when `T` is supported
- ordinary non-generic `struct` types with no event members whose stored fields are recursively supported
- imported foreign scalar aliases only when sema resolves them to one of the supported scalar primitives

Rejected in v1:

- `void`
- `ptr_int`, `ptr_uint`
- `ptr[T]`, `const_ptr[T]`, `ref[T]`
- `span[T]`
- nullable types such as `T?`
- `str`, `cstr`, `str_buffer[N]`
- `Task[T]`
- `Option[T]`, `Result[T, E]`, and arbitrary `variant`
- `proc` / `fn` values
- any generic type instance other than `array[T, N]`
- `union`, opaque, and raw `external` ABI struct/union/handle types
- structs that contain any rejected field type or any event member
- ordinary heap-owning library wrapper types and dynamically sized containers unless a future RFC adds explicit codec support

This restriction is deliberate.
It keeps the first implementation concrete, deterministic, and easy to validate.
Wire encoding in v1 is field-wise and descriptor-driven, not raw ABI `memcpy` of host struct layout.
Resolved scalar and enum backing widths must feed schema generation and protocol hashing.
Complex payloads should use explicit custom-message or codec layers later rather than silently becoming half-supported.

## Compiler Hooks

### Parsing

No grammar changes are required.
This RFC relies on the existing attribute syntax and the existing `callable_of(...)` reflection handle.

### Semantic analysis

Sema must:

1. Recognize when a resolved attribute binding is one of the exported `std.multiplayer` multiplayer attributes.
2. Validate the target kinds and the argument shapes.
3. Validate the wire-safe type subset for replicated fields and RPC payload parameters.
4. Validate the RPC handler signature.
5. Build internal networking metadata for each participating struct field and RPC callable.
6. Reject invalid uses with explicit diagnostics such as:
    - `sync may only appear on fields inside a replicated struct`
    - `rpc handlers must be top-level ordinary functions in v1`
    - `multiplayer field Foo.bar has unsupported wire type str`
    - `rpc handler submit_input must take RpcContext as its first parameter`
    - `rpc annotations do not turn local calls into network sends; use the multiplayer runtime's explicit send path`

### Lowering

Lowering must synthesize static artifacts for each replicated struct and RPC handler.

For each `@[replicated(...)]` struct:

- one immutable state descriptor object
- field metadata entries in source order
- one full-state encoder
- one full-state decoder
- one delta encoder that compares current state to a baseline state
- one delta apply function
- one per-struct schema hash contribution

For each `@[rpc(...)]` handler:

- one immutable RPC descriptor object
- one argument encoder
- one argument decoder
- one dispatch trampoline that calls the user handler with `RpcContext` and decoded parameters
- one per-RPC schema hash contribution

These symbols are implementation details.
They should be accessed only through the `std.multiplayer` descriptor hooks.
V1 lowering does not rewrite ordinary calls to `@[rpc(...)]` functions into outbound network sends.

### C backend

The C backend must emit the synthesized structs, constants, and helper functions in the same style as other lowering-generated runtime support.

The existing event runtime in `lib/milk_tea/core/lowering.rb` is the closest precedent:

- sema validates the declaration surface
- lowering synthesizes helper structs and functions
- the backend emits those helpers as ordinary generated C

Multiplayer support should follow the same broad pattern instead of adding a second out-of-band code generator.

## Protocol Hashing

Every registry assembled from `StateDescriptor` and `RpcDescriptor` values must produce a protocol hash.

That hash must change when any of the following change:

- replicated struct name
- replicated field order
- replicated field type
- resolved scalar or enum backing width for any replicated field or RPC parameter
- `sync` mode, target, channel, or rate
- RPC name
- RPC direction, mode, channel, or ownership requirement
- RPC parameter list

Because this repository does not prioritize backwards-compatible wire evolution, the default v1 behavior on mismatch should be simple: reject the connection with a protocol mismatch error.

## Interaction With Existing Attribute Reflection

These networking attributes remain ordinary attribute declarations in source.
That means the existing attribute reflection rules still apply for compile-time introspection.

However, networking code generation must not rely on user code calling general attribute reflection intrinsics at runtime.
The generated descriptor objects are the runtime bridge.

## Implementation Outline

1. Add the `std.multiplayer` attribute declarations, enums, descriptor types, and descriptor hook declarations in the standard library.
2. Extend semantic analysis to recognize the resolved `std.multiplayer` attribute bindings.
3. Validate the wire-safe type subset and RPC handler signatures.
4. Extend the semantic-analysis output snapshot with internal networking metadata maps for structs, fields, and callables.
5. Teach lowering to synthesize state and RPC descriptor objects.
6. Teach lowering to synthesize full-state and delta-state codec helpers for replicated structs.
7. Teach lowering to synthesize RPC encode/decode/dispatch helpers.
8. Lower `state_descriptor[T]()` and `rpc_descriptor(callable_of(...))` to the synthesized static descriptor objects.
9. Accumulate protocol-hash contributions in the generated descriptor data.
10. Add codegen tests that assert descriptor lookup and generated helper emission.
11. Add sema tests that cover invalid target usage, invalid handler signatures, and invalid wire types.
12. Add runtime library tests through `std.multiplayer.enet` once the first backend exists.

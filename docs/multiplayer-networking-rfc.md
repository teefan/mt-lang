# Multiplayer Networking Attributes And Compiler Hooks

Status: finalized (implemented)

This document is the current compiler/runtime contract for multiplayer declarations.
It describes shipped behavior in this repository.

## Shipped Compiler Hooks

The implemented multiplayer compile-time hooks are:

- `state_descriptor[T]()`
- `rpc_descriptor(callable_of(...))`
- `state_wire_size[T]()`
- `rpc_payload_size(callable_of(...))`
- `std.multiplayer.rpc.dispatch_typed_payload(callable_of(...), context, payload)`

## Shipped Attribute Vocabulary

Exported by `std.multiplayer`:

```mt
public attribute[struct] replicated(authority: Authority)
public attribute[struct] sync_defaults(mode: TransferMode, channel: ubyte, rate_hz: uint, target: SyncTarget)
public attribute[field] sync(mode: TransferMode, channel: ubyte, rate_hz: uint, target: SyncTarget)
public attribute[callable] rpc(direction: RpcDirection, mode: TransferMode, channel: ubyte, require_owner: bool)
```

Attributes are compiler-special only when semantic resolution proves they belong to `std.multiplayer`.

## Implemented Semantic Rules

The current sema implementation enforces:

1. `sync` appears only on fields in a replicated struct.
2. Marker-form `@[sync]` requires `@[sync_defaults(...)]` on the enclosing struct.
3. `state_descriptor[T]` and `state_wire_size[T]` require a concrete `@[replicated(...)]` struct.
4. `rpc_descriptor(...)` and `rpc_payload_size(...)` require direct `callable_of(name)` targeting a top-level `@[rpc(...)]` function.
5. RPC handlers require `std.multiplayer.RpcContext` as the first parameter.
6. Unsupported wire types are rejected.
7. v1 sync fields in one replicated struct must share mode/channel/rate_hz/target.

Primary implementation file: `lib/milk_tea/core/sema.rb`.

## Implemented Lowering Rules

Lowering maps multiplayer hooks to static descriptor-backed artifacts consumed by runtime modules.
Descriptor binding IDs and payload sizes are exposed through lowered values used by `registry`, `world`, and `rpc` runtime checks.

Primary implementation file: `lib/milk_tea/core/lowering.rb`.

## Runtime Contract Surface

Root declarations live in `std/multiplayer.mt` and alias runtime modules:

- `std/multiplayer/registry.mt`
- `std/multiplayer/world.mt`
- `std/multiplayer/protocol.mt`
- `std/multiplayer/rpc.mt`
- `std/multiplayer/snapshot.mt`
- `std/multiplayer/session.mt`
- `std/multiplayer/relevancy.mt`
- `std/multiplayer/spatial.mt`
- `std/multiplayer/wire.mt`
- `std/multiplayer/enet.mt`
- `std/multiplayer/enet_sync.mt` (small observer-state helpers layered over `enet`)

## Wire-Safe Boundary (Current)

The implementation intentionally keeps replicated/RPC wire types narrow.

Accepted boundary (summary):

- scalar primitives
- enums/flags with scalar backing
- fixed-size arrays of supported element types
- non-generic structs that recursively satisfy the same constraints

Rejected boundary (summary):

- pointer/reference-like types
- dynamic string/container payloads
- unsupported generic payload forms
- external ABI struct/union handle payload fields

## Behavioral Contract

1. `@[rpc(...)]` marks inbound dispatch metadata only.
2. Local calls to RPC-marked functions remain local calls.
3. Send-side networking remains explicit runtime API in `std.multiplayer.enet`.
4. Session-orchestration helpers such as `std.multiplayer.session.SlotRoster` and deterministic turn helpers such as `std.multiplayer.lockstep.TurnCollector[T]` are ordinary runtime utilities layered above transport; compiler hooks do not synthesize or manage them.

## Implemented Coverage

Compiler coverage:

- `test/compiler/sema_test.rb` multiplayer sections
- `test/compiler/codegen_test.rb` multiplayer sections

Runtime coverage includes world/snapshot/relevancy/hooks/enet suites under `test/std/std_multiplayer_*`.

## Out Of Scope Here
This RFC does not prescribe matchmaking, lobby, platform-level orchestration for session discovery, or higher-level deterministic lockstep deadline policy.

Current repository boundary:

- `std.multiplayer.enet` is the concrete gameplay/network transport runtime.
- `std.multiplayer.enet_sync` is the small observer-state sync layer above `enet`; it does not add a separate transport.
- `std.multiplayer.session` is the current small runtime layer for slot occupancy and ready-state bookkeeping.
- `std.multiplayer.lockstep` is the current small runtime layer for deterministic turn submission, sealing, checksum reporting, and desync detection. Raw ENet-facing command/checksum transport helpers live alongside it; the wire-shape design lives in `docs/multiplayer-lockstep-rfc.md`.
- Higher-level matchmaking, dedicated relay services, and any NAT traversal/punching layer remain outside the core runtime and require application-level integration.
- Broader Warcraft-style deterministic command-turn networking (deadline policy, replay capture, desync recovery) still continues in `docs/multiplayer-lockstep-rfc.md`.

# Multiplayer Standard Library Design

Status: finalized (implemented)

This document describes the current multiplayer standard-library layout as implemented.
It is no longer a proposal.

## Implemented Layering

```mermaid
flowchart TD
    gameplay[Gameplay code]
    root[std.multiplayer]
    enet_backend[std.multiplayer.enet]
    registry[std.multiplayer.registry]
    world[std.multiplayer.world]
    rpc[std.multiplayer.rpc]
    snapshot[std.multiplayer.snapshot]
    relevancy[std.multiplayer.relevancy]
    spatial[std.multiplayer.spatial]
    wire[std.multiplayer.wire]
    protocol[std.multiplayer.protocol]
    std_enet[std.enet]

    gameplay --> root
    gameplay --> enet_backend
    root --> registry
    root --> world
    root --> rpc
    root --> snapshot
    root --> relevancy
    root --> spatial
    snapshot --> wire
    rpc --> wire
    enet_backend --> std_enet
    enet_backend --> world
    enet_backend --> rpc
    enet_backend --> snapshot
    registry --> protocol
    world --> protocol
    rpc --> protocol
```

## Public Import Story

Typical gameplay imports:

```mt
import std.multiplayer as mp
import std.multiplayer.enet as mp_enet
```

## Implemented Modules

### `std.multiplayer`

Public root vocabulary and compiler-lowered hook declarations.

Exports include:

- ids and enums (`ConnectionId`, `EntityId`, `Authority`, `TransferMode`, `RpcDirection`, ...)
- core types (`Config`, `Error`, `Registry`, `World`, descriptor aliases)
- ergonomic binding builder (`BindingsBuilder.create()`, `bind_state[T](...)`, `bind_rpc(...)`, `bind_typed_rpc(...)`)
- attributes (`replicated`, `sync_defaults`, `sync`, `rpc`)
- hook surface (`state_descriptor`, `rpc_descriptor`, `state_wire_size`, `rpc_payload_size`)

### `std.multiplayer.registry`

Descriptor collection and protocol hash agreement.

Implemented API highlights:

- `Registry.create()`
- `add_state(...)`, `add_rpc(...)`
- `freeze()`
- `protocol_hash()`
- descriptor binding checks (`expected_state_*`, `expected_rpc_*`)

For gameplay code that does not want to wire descriptors manually, prefer `std.multiplayer.BindingsBuilder` plus `bind_state`, `bind_rpc`, and `bind_typed_rpc`, then pass `builder.registry` and `builder.typed_rpcs` into the backend/session setup that needs them.

### `std.multiplayer.world`

Entity storage, ownership, snapshot payload encoding/decoding, and descriptor-aware state access.

Implemented API highlights:

- `World.create(...)`
- `spawn[T](...)`, `spawn_with_descriptor[T](...)`
- `despawn(...)`, `transfer_ownership(...)`
- `state_ptr[T](...)`, `state_ptr_with_descriptor[T](...)`
- `state_copy[T](...)`, `state_copy_with_descriptor[T](...)`
- `snapshot_state_signature(...)`
- `encode_snapshot_payload()` / `apply_snapshot_payload(...)`

### `std.multiplayer.rpc`

RPC packet framing, queueing, descriptor-backed dispatch, and typed dispatch hook target.

Implemented API highlights:

- `RpcDispatchTable.create()`, `register_route(...)`, `dispatch(...)`
- `dispatch_with_routes(...)`
- `dispatch_typed_payload(callable_of(...), context, payload)` compiler-lowered path
- shared typed inbound queue drain helper used by ENet and ICE session wrappers
- `encode_header(...)`, `decode_header(...)`, `build_payload(...)`
- incoming queue helpers

### `std.multiplayer.snapshot`

Snapshot signatures, baseline tracking, packet header encode/decode, and incoming queue helpers.

### `std.multiplayer.relevancy`

Implemented policies and checks:

- `all()`, `owner()`, `callback(...)`
- `grid(...)`, `owner_or_grid(...)`, `owner_or_grid_index(...)`
- `allows(...)`

### `std.multiplayer.spatial`

Grid indexing and helper math for relevancy-driven policies.

### `std.multiplayer.wire`

Shared big-endian primitives (`u32`/`u64`) used by protocol framing.

### `std.multiplayer.protocol`

Protocol/shared types and scheduling primitives.

Implemented API highlights:

- packet and handshake structs
- tick scheduler (`create_tick_scheduler`, `reserve`, `remaining_bytes`, ...)
- budget plan (`create_tick_budget_plan`)

### `std.multiplayer.enet`

Current concrete backend.

Implemented types:

- `Server`, `Client`
- `SessionEvent`, `SessionEventRecord`
- `WeightedConnection`
- `TypedRpcRoute`, `TypedRpcDispatchTable`

Implemented capabilities include:

- host/client setup (`listen`, `connect`, localhost helpers)
- protocol verification handshake
- event pump/flush/release lifecycle
- snapshot and RPC incoming queue draining (`process_incoming_snapshots`, `process_incoming_rpcs_typed`) backed by shared world/RPC queue-drain utilities
- explicit send helpers (`send_snapshot_to`, `send_rpc_to`, `broadcast_snapshot`, `broadcast_rpc`)
- fair/weighted/budgeted scheduling helpers
- world-signature-aware tick dispatch (`dispatch_world_tick_fair`, which encodes snapshot bytes from the current world state internally)

## Behavioral Boundaries (Current)

1. Networking send paths are explicit runtime calls.
2. Compiler annotations do not rewrite ordinary gameplay calls into network sends.
3. Protocol compatibility is enforced through registry protocol hash checks.
4. Session lifecycle is exposed through queued events plus low-level queue accessors.

## Matchmaking and NAT Boundary

Matchmaking/lobby/discovery are outside the core multiplayer runtime.

Direct public-IP join remains an ENet + UDP forwarding/firewall concern in user applications.

## ICE/libjuice Status

Current state:

- `std.libjuice` and `std.c.libjuice` bindings exist.
- `std.multiplayer.ice` runtime module is implemented (libjuice-backed ICE transport).
- `std.multiplayer.signal` runtime module is implemented (signaling/session negotiation primitives).
- Binding coverage: `std.libjuice` and `std.c.libjuice` bindings exist.
- Higher-level NAT punching orchestration and matchmaking remain outside the core runtime and require application-level integration.

Future ICE/NAT work should layer on existing core runtime modules instead of changing core ENet behavior.

## Existing Runtime Coverage

Primary coverage files:

- `test/std/std_multiplayer_world_test.rb`
- `test/std/std_multiplayer_snapshot_runtime_test.rb`
- `test/std/std_multiplayer_relevancy_test.rb`
- `test/std/std_multiplayer_enet_test.rb`
- `test/std/std_multiplayer_enet_friendly_api_test.rb`
- `test/std/std_multiplayer_enet_fair_budget_test.rb`
- `test/std/std_multiplayer_enet_scheduled_fair_test.rb`
- `test/std/std_multiplayer_enet_world_dispatch_signature_test.rb`
- `test/std/std_multiplayer_enet_snapshot_baseline_test.rb`
- `test/std/std_multiplayer_enet_maturity_soak_test.rb`
- `test/std/std_multiplayer_enet_stress_test.rb`

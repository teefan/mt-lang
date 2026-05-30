# `std.multiplayer.enet` Implementation Plan

Status: draft implementation plan

This document describes the first implementation pass for `std.multiplayer.enet` on top of the current codebase.
It is intentionally narrow.
The goal is to ship one correct, game-usable, server-authoritative ENet backend before adding host-mode conveniences, ICE/libjuice transport, or prediction work.

This plan assumes the design in [Multiplayer Networking Attributes And Compiler Hooks](multiplayer-networking-rfc.md) and [Multiplayer Standard Library Design](multiplayer-standard-library.md).

## First-Pass Scope

Include in v1:

- `@[replicated]`, `@[sync]`, and `@[rpc]` compiler recognition
- `state_descriptor[T]()` and `rpc_descriptor(callable_of(...))`
- a `Registry` that produces one protocol hash
- a `World` that stores replicated entities and compares them against snapshot baselines
- one ENet server path and one ENet client path
- server-authoritative replicated state snapshots
- typed RPC dispatch in both directions
- protocol mismatch rejection
- focused compiler and runtime tests

Exclude from v1:

- libjuice / ICE transport
- host migration
- lobby or matchmaking helpers
- full client-side prediction or rollback
- generic wire codecs for heap-owning types
- scene replication or object graphs
- listen-server convenience if it meaningfully delays the dedicated-server path

## What The Current Codebase Already Gives Us

### Attribute infrastructure

The attribute machinery already exists.

Relevant files:

- `lib/milk_tea/core/parser.rb`
- `lib/milk_tea/core/ast.rb`
- `lib/milk_tea/core/sema.rb`

The parser already accepts declaration attributes and field attributes.
That means multiplayer should reuse the existing syntax instead of adding a new parser feature.

### Compile-time callable handles

The semantic-analysis layer already understands compile-time handles such as `callable_of(...)`, `field_of(...)`, `attribute_of(...)`, and `has_attribute(...)` in `lib/milk_tea/core/sema.rb`.

That existing handle model is the cleanest bridge for `rpc_descriptor(callable_of(...))`.

### Synthetic lowering support

`lib/milk_tea/core/lowering.rb` already synthesizes runtime support for events.
That path is the closest precedent for multiplayer support:

- sema validates the source surface
- lowering synthesizes helper structs and helper functions
- the C backend emits them as ordinary generated C

Multiplayer should follow that pattern rather than bolt on a separate external code generator.

### C backend integration

The backend entrypoints already run through:

- `lib/milk_tea/core/lowering.rb`
- `lib/milk_tea/core/c_backend.rb`

If multiplayer support is lowered into normal IR declarations and helper functions, most of the backend can remain unchanged.

### ENet bindings

The ENet binding surface already exists:

- `std/c/enet.mt`
- `std/enet.mt`

That removes the need for any new binding-generation work in the first implementation.

### Test style and runtime test shape

The existing runtime tests in `test/std/std_net_test.rb` and `test/std/std_net_channel_test.rb` show the expected style for compile-and-run networking tests over localhost.

That is the right pattern for the first `std.multiplayer.enet` runtime suite.

## Phase Plan

### Phase 1: Standard-library scaffolding

Goal:
Check in the public type and attribute vocabulary before touching lowering.

Files to add:

- `std/multiplayer.mt`
- `std/multiplayer/registry.mt`
- `std/multiplayer/world.mt`
- `std/multiplayer/protocol.mt`
- `std/multiplayer/rpc.mt`
- `std/multiplayer/snapshot.mt`
- `std/multiplayer/relevancy.mt`
- `std/multiplayer/enet.mt`

Expected contents in the first pass:

- enums such as `Authority`, `TransferMode`, `RpcDirection`, `SyncTarget`
- `ErrorCode` and `Error`
- `ConnectionId`, `EntityId`, `Tick`
- `RpcContext`
- placeholder `StateDescriptor` and `RpcDescriptor` structs
- `Registry` and `World` shell types
- attribute declarations for `replicated`, `sync`, and `rpc`
- declarations for `state_descriptor[T]()` and `rpc_descriptor(callable_of(...))`

Why first:

- it gives sema something real to resolve
- it makes the compiler behavior key off semantic names instead of hard-coded strings with no owning library surface

### Phase 2: Semantic-analysis metadata

Goal:
Recognize the multiplayer attribute vocabulary after ordinary name resolution and store validated metadata in the sema output.

Primary files:

- `lib/milk_tea/core/sema.rb`

Likely change shape:

1. Extend `MilkTea::Sema::Analysis` to carry networking metadata maps in addition to the existing `attributes`, `values`, `functions`, and method data.
2. During attribute validation, detect when an attribute binding resolves to `std.multiplayer.replicated`, `std.multiplayer.sync`, or `std.multiplayer.rpc`.
3. Validate target placement and argument shapes.
4. Validate the wire-safe type subset.
5. Validate RPC handler signatures.
6. Record normalized metadata keyed by declaration object identity or binding identity.

Important constraint:

Do not try to infer dirty writes from arbitrary field assignment in sema.
The first implementation should diff snapshots in the runtime instead.

### Phase 3: Descriptor hook lowering

Goal:
Make `state_descriptor[T]()` and `rpc_descriptor(callable_of(...))` lower to concrete static descriptor objects.

Primary files:

- `lib/milk_tea/core/sema.rb`
- `lib/milk_tea/core/lowering.rb`

Concrete work:

1. Teach sema to type-check the descriptor hooks.
2. Teach lowering to map those calls to generated descriptor globals.
3. Reject invalid uses early with precise diagnostics.

Why this phase deserves its own step:

- registry construction becomes possible before the full ENet backend exists
- codegen tests can start asserting stable descriptor generation immediately

### Phase 4: Replicated-state helper synthesis

Goal:
Synthesize state descriptor data and full/delta codec helpers for each replicated struct.

Primary file:

- `lib/milk_tea/core/lowering.rb`

Expected generated artifacts per replicated struct:

- one state descriptor global
- one array of field metadata entries in source order
- one full encoder
- one full decoder
- one delta encoder comparing current state to a baseline state
- one delta apply helper for incoming state updates
- one schema hash contribution constant

Design choice for v1:

- compare `current` and `baseline` at snapshot-build time
- do not add setter rewriting, hidden mutation hooks, or automatic dirty-bit propagation through normal field writes

This keeps the first pass aligned with the project's preference for obvious runtime behavior.

### Phase 5: RPC helper synthesis

Goal:
Synthesize RPC descriptor data and per-RPC encode/decode/dispatch helpers.

Primary file:

- `lib/milk_tea/core/lowering.rb`

Expected generated artifacts per RPC handler:

- one RPC descriptor global
- one outgoing argument encoder
- one incoming argument decoder
- one dispatch trampoline that constructs `RpcContext` and calls the user handler
- one schema hash contribution constant

V1 restriction:

- top-level ordinary functions only
- no methods, no async handlers, no generic handlers

That keeps dispatch and symbol lookup straightforward.

### Phase 6: Backend-neutral runtime core

Goal:
Implement registry, world, snapshot, and RPC runtime code in Milk Tea itself.

Primary files:

- `std/multiplayer/registry.mt`
- `std/multiplayer/world.mt`
- `std/multiplayer/protocol.mt`
- `std/multiplayer/rpc.mt`
- `std/multiplayer/snapshot.mt`
- `std/multiplayer/relevancy.mt`

Concrete deliverables:

1. `Registry.create`, `add_state`, `add_rpc`, `freeze`, and `protocol_hash`.
2. `World.create`, `spawn`, `despawn`, `transfer_ownership`, and state lookup helpers.
3. Packet header definitions and encode/decode helpers for handshake, snapshot, and RPC packets.
4. Runtime-side RPC queue and dispatch plumbing.
5. Snapshot baseline bookkeeping and ack tracking.
6. Minimal relevancy policy evaluation for always, owner-only, and callback-driven inclusion.

Keep this runtime backend-neutral.
No ENet symbols should leak into these modules.

### Phase 7: ENet session backend

Goal:
Build the first concrete transport backend on top of `std.enet`.

Primary file:

- `std/multiplayer/enet.mt`

Planned server flow:

1. Initialize ENet if needed.
2. Create one ENet host.
3. On connect, exchange protocol hash handshake packets.
4. On accepted peers, create connection records.
5. Pump ENet events with `host_service(...)`.
6. Route receive events into handshake, snapshot, or RPC decode paths.
7. On each server tick, build per-peer state deltas based on relevancy and last acknowledged baseline.
8. Send snapshots over the configured ENet channels.

Planned client flow:

1. Create one ENet host for the client.
2. Connect to the server peer.
3. Perform protocol-hash handshake.
4. Pump ENet events.
5. Apply spawn, despawn, and state delta packets into the client `World`.
6. Decode and dispatch incoming RPCs.

V1 ENet mapping rules:

- use ENet channels directly for the logical `channel` field from `sync` and `rpc` metadata
- use ENet reliable packets for `TransferMode.reliable`
- use ENet unreliable packets for `TransferMode.unreliable`
- treat `TransferMode.unreliable_ordered` as channel-isolated ENet traffic where later packets supersede older deltas when the runtime can safely do so

### Phase 8: User-facing send helpers

Goal:
Add the friendly API layer once the runtime path is already working.

Primary files:

- `std/multiplayer/enet.mt`
- possibly `std/multiplayer/rpc.mt`

Possible public surface once the descriptor-driven path is proven:

- `Client.send_rpc(...)`
- `Server.send_rpc_to(...)`
- `Server.broadcast_rpc(...)`

Constraint:

Do not expand the v1 compiler surface for send-side call rewriting.
Do not commit the final typed wrapper signature until the descriptor-driven path is working end-to-end.
If the friendly API still needs extra compiler help after the descriptor-driven path is green, treat that as a separate follow-on slice instead of folding it into the first ENet implementation.

### Phase 9: Tests

Goal:
Add narrow validation at each layer instead of waiting for one large end-to-end suite.

Compiler tests to add:

- `test/compiler/sema_test.rb`
  - rejects `sync` outside replicated structs
  - rejects unsupported wire types
  - rejects invalid RPC handler signatures
  - accepts valid replicated structs and RPC handlers
- `test/compiler/codegen_test.rb`
  - emits state descriptors
  - emits RPC descriptors
  - lowers `state_descriptor[T]()` and `rpc_descriptor(callable_of(...))`

Potential parser tests:

- probably none beyond existing attribute syntax coverage unless the checked-in `std.multiplayer` declarations expose an overlooked parser edge case

Runtime tests to add:

- `test/std/std_multiplayer_registry_test.rb`
- `test/std/std_multiplayer_world_test.rb`
- `test/std/std_multiplayer_enet_test.rb`

First runtime scenarios:

1. Registry hash matches across client and server builds.
2. Protocol mismatch rejects the connection.
3. Server spawn reaches client.
4. Server state delta updates reach client.
5. Client `client_to_server` RPC reaches server with the correct sender ID.
6. Server `server_to_owner` RPC reaches only the owning client.
7. Server `server_to_all` RPC reaches all connected clients.
8. Ownership transfer changes allowed `require_owner` behavior.

### Phase 10: Example and docs cleanup

Goal:
Check in one small example after the runtime is real enough to be honest.

Potential example targets:

- a tiny lobby-less movement sync demo
- a headless authoritative server plus one client-controlled entity

Do not start with a large gameplay sample.
The first example should exist to prove the programming model, not to market it.

## Suggested Validation Corridor

Once the implementation exists, the focused validation corridor should look roughly like this:

```sh
bundle exec ruby -Itest test/compiler/sema_test.rb -n '/multiplayer/'
bundle exec ruby -Itest test/compiler/codegen_test.rb -n '/multiplayer/'
bundle exec ruby -Itest test/std/std_multiplayer_registry_test.rb
bundle exec ruby -Itest test/std/std_multiplayer_world_test.rb
bundle exec ruby -Itest test/std/std_multiplayer_enet_test.rb
```

The exact test names can change, but the intent should stay the same:

- validate sema first
- validate lowering second
- validate runtime slices last

## Main Risks

### 1. Overreaching on the first pass

The fastest way to stall this work is to mix ENet transport, ICE, prediction, schema evolution, and user-facing sugar into one initial patch series.

Recommendation:
Ship the dedicated ENet server/client path first.

### 2. Too-broad wire-type support

If the first implementation tries to serialize arbitrary library-owned heap types, the compiler and runtime work will sprawl immediately.

Recommendation:
Keep the v1 wire-safe subset narrow and explicit.

### 3. Hidden dirty-state tracking

Trying to rewrite ordinary field assignment to maintain dirty masks would make the first pass much more invasive.

Recommendation:
Diff current state against baselines during snapshot generation first.

### 4. Leaking backend concerns into the core runtime

If `Registry`, `World`, or snapshot code depend directly on ENet peer types, the later ICE backend will be much harder.

Recommendation:
Keep ENet symbols inside `std.multiplayer.enet`.

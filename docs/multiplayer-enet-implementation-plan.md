# `std.multiplayer.enet` Implementation Status

Status: finalized (implemented ENet backend)

This document records the current shipped implementation of `std.multiplayer.enet`.
It replaces the earlier phase-plan view.

## What Is Implemented

### Compiler/runtime bridge

The multiplayer compiler hooks and descriptor model are integrated and used by runtime modules.
Implemented hooks include:

- `state_descriptor[T]()`
- `rpc_descriptor(callable_of(...))`
- `state_wire_size[T]()`
- `rpc_payload_size(callable_of(...))`
- `rpc.dispatch_typed_payload(callable_of(...), context, payload)`

### Core multiplayer runtime modules

Implemented in stdlib:

- `std/multiplayer.mt`
- `std/multiplayer/registry.mt`
- `std/multiplayer/world.mt`
- `std/multiplayer/protocol.mt`
- `std/multiplayer/rpc.mt`
- `std/multiplayer/snapshot.mt`
- `std/multiplayer/relevancy.mt`
- `std/multiplayer/spatial.mt`
- `std/multiplayer/wire.mt`
- `std/multiplayer/enet.mt`

### ENet server/client session backend

`std.multiplayer.enet` currently provides:

1. Server listen and client connect helpers, including localhost convenience wrappers.
2. Protocol-hash handshake verification before normal gameplay traffic.
3. Session event queueing (`connected`, `disconnected`, `snapshot_received`, `rpc_received`).
4. Snapshot and RPC inbound queues plus one-call processing APIs.
5. Explicit send helpers for snapshots and RPCs.
6. Budgeted, weighted, scheduled, and fair-dispatch send APIs.
7. World-signature-aware dispatch with `dispatch_world_tick_fair(...)`, which encodes snapshot bytes from the current world state internally.
8. Baseline tracking accessors for snapshot flow.

## Current Intended Usage

1. Group gameplay registration behind one installer function per feature/module, and build frozen bindings via `std.multiplayer.build_frozen_bindings_with(...)`.
2. Start server/client via `listen(...)` / `connect(...)` (or localhost helpers).
3. Pump ENet events each frame.
4. Use one-call inbound processing (`process_incoming_snapshots`, `process_incoming_rpcs_typed`) or low-level pop APIs.
5. Use explicit send APIs for outbound snapshots and RPCs.
6. Use fair/budgeted dispatch APIs when per-tick network budgets matter.

Installer pattern:

```mt
function install_combat_bindings(builder: ptr[mp.BindingsBuilder]) -> Result[ptr_uint, mp.Error]:
	let builder_ref = unsafe: ref_of(read(builder))
	var applied: ptr_uint = 0

	let state_bound = mp.bind_state[CombatState](builder_ref) else as bind_error:
		return Result[ptr_uint, mp.Error].failure(error = bind_error)
	if state_bound:
		applied += 1

	let rpc_bound = mp.bind_typed_rpc(builder_ref, callable_of(submit_attack), dispatch_submit_attack) else as bind_error:
		return Result[ptr_uint, mp.Error].failure(error = bind_error)
	if rpc_bound:
		applied += 1

	return Result[ptr_uint, mp.Error].success(value = applied)

let bindings = mp.build_frozen_bindings_with(install_combat_bindings) else:
	fatal(c"combat bindings setup failed")
```

## Implemented Validation and Guardrails

1. Registry mutation is blocked once frozen.
2. World creation requires a frozen registry.
3. Descriptor binding hashes are checked at runtime in world/rpc paths.
4. Direction and ownership rules are enforced on send/dispatch paths.
5. Client outbound RPC is gated behind protocol readiness.

## Existing Test Coverage

Compiler:

- `test/compiler/sema_test.rb` multiplayer sema sections
- `test/compiler/codegen_test.rb` multiplayer codegen sections

Runtime:

- `test/std/std_multiplayer_world_test.rb`
- `test/std/std_multiplayer_world_snapshot_signature_test.rb`
- `test/std/std_multiplayer_snapshot_runtime_test.rb`
- `test/std/std_multiplayer_wire_size_hooks_test.rb`
- `test/std/std_multiplayer_relevancy_test.rb`
- `test/std/std_multiplayer_enet_test.rb`
- `test/std/std_multiplayer_enet_friendly_api_test.rb`
- `test/std/std_multiplayer_enet_snapshot_baseline_test.rb`
- `test/std/std_multiplayer_enet_world_dispatch_signature_test.rb`
- `test/std/std_multiplayer_enet_fair_budget_test.rb`
- `test/std/std_multiplayer_enet_scheduled_fair_test.rb`
- `test/std/std_multiplayer_enet_maturity_soak_test.rb`
- `test/std/std_multiplayer_enet_stress_test.rb`

## Explicitly Not Implemented Here

1. NAT punching orchestration integrated into multiplayer sessions.
2. Lobby/matchmaking services.
3. Prediction/rollback netcode.

## libjuice/NAT Punching Status

Current repository state:

- `std.libjuice` exists as imported bindings.
- `std.c.libjuice` raw binding surface exists.
- Binding registration tests exist under `test/bindings/*`.
- `std.multiplayer.ice` and `std.multiplayer.signal` runtime modules are implemented and provide libjuice-backed ICE and signaling primitives.

This means basic ICE and signaling support is available in the runtime; higher-level matchmaking, lobby services, and any broader orchestration remain outside the core multiplayer runtime and require application-level integration.

## Remaining Follow-On Work

When prioritized, ICE/NAT work should be introduced as additive modules that reuse the existing registry/world/rpc/snapshot contract, rather than changing ENet semantics.

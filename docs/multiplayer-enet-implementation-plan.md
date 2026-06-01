# `std.multiplayer.enet` Implementation Status

Status: implemented ENet backend, plus rollback primitives

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
- `std/multiplayer/rollback.mt`
- `std/multiplayer/relevancy.mt`
- `std/multiplayer/spatial.mt`
- `std/multiplayer/wire.mt`
- `std/multiplayer/enet.mt`
- `std/multiplayer/enet_sync.mt`

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
- `test/std/std_multiplayer_ice_test.rb`
- `test/std/std_multiplayer_signal_test.rb`
- `test/std/std_multiplayer_rollback_test.rb`

## Explicitly Not Implemented Here

1. Automatic NAT traversal or NAT punching.
2. Lobby/matchmaking services.
3. Full prediction/rollback netcode.
4. Dedicated built-in relay or discovery services.

## Remaining Follow-On Work

When prioritized, multiplayer follow-on work should stay additive and explicit, reusing the existing registry/world/rpc/snapshot contract instead of hiding costs or forcing false backend symmetry.

Current prioritized plan:

1. Explicit reusable snapshot preparation.
Status: done.
Work completed:
- `World.prepare_snapshot(tick, baseline_tick)` now returns an owned prepared snapshot with header, signature, and payload
- ENet world dispatch now uses that explicit prepared snapshot surface internally instead of reassembling header and payload ad hoc
- focused world runtime coverage validates prepared snapshot reuse and payload round-trip

2. Transport-neutral gameplay session abstraction.
Status: deferred pending clearer backend convergence.
Why deferred:
- the runtime intentionally centers ENet as the gameplay/network transport
- introducing another generic session abstraction without a second truthful backend would only add indirection

Preferred next step when this becomes worth doing:
- only revisit this if another truthful transport backend returns or if dedicated-server/client orchestration needs a smaller common facade

3. Prediction/rollback primitives.
Status: started.
Work completed:
- `std.multiplayer.rollback` now provides explicit rollback history storage for inputs or states
- history recording enforces nondecreasing ticks unless callers explicitly `discard_after(...)` first
- `resimulate_from(...)` now rebuilds future state from a known authoritative tick plus recorded inputs and a caller-supplied simulation step
- multiplayer docs and focused runtime coverage now include a gameplay-style authoritative correction example for replaying predicted player state
- `std.multiplayer.enet_sync.drain_observer_state_with_info(...)` now preserves the latest authoritative snapshot tick for simple gameplay clients instead of discarding it during decode
- Pong now retains the latest authoritative snapshot tick through its observer-sync session path, which makes the next rollback gap concrete
- Pong client input RPCs now carry an explicit simulation tick alongside input flags, and the host preserves monotonic join-input application by ignoring stale input ticks
- Pong client now keeps explicit local join-paddle prediction history and rewrites that local predicted paddle from authoritative snapshot ticks plus retained input history
- Pong smoke validation now round-trips both authoritative snapshot ticks and a ticked input RPC through the typed dispatch path
- focused runtime coverage validates append/replace, lookup, capacity trimming, rollback-boundary trimming, and explicit replay

What is still not implemented:
- no automatic prediction loop
- no automatic rollback/resimulation scheduler
- no authoritative reconciliation policy layered over gameplay state
- no gameplay path yet reconciles full gameplay state from authoritative snapshots plus retained input history

Preferred next step:
- stop here for Pong until there is additional client-owned predicted state worth reconciling; in the current game, join-paddle input is the only honest local prediction surface and broader state remains authoritative host simulation

4. Lobby/matchmaking services.
Status: deferred outside core runtime boundary.
Why deferred:
- the repository does not yet contain a truthful service boundary for room discovery, tickets, persistence, or platform identity
- adding a stdlib lobby surface now would be fake orchestration with no concrete backend contract behind it

Preferred next step when this becomes worth doing:
- choose one real service boundary first, for example an explicit HTTP service contract or platform SDK adapter
- keep the boundary additive to ENet-facing runtime modules instead of baking discovery policy into core transport/runtime code

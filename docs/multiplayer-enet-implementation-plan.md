# `std.multiplayer.enet` Implementation Status

Status: shipped ENet backend with explicit snapshot/RPC/lockstep transport, explicit rollback primitives, and slot/ready-state session helpers

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
- `std/multiplayer/session.mt`
- `std/multiplayer/relevancy.mt`
- `std/multiplayer/spatial.mt`
- `std/multiplayer/wire.mt`
- `std/multiplayer/enet.mt`
- `std/multiplayer/enet_sync.mt` (observer-state sync helpers layered on top of `enet`)

### Deterministic lockstep transport helpers

In addition to the snapshot/RPC transport, `std.multiplayer.enet` ships narrow ENet-facing
lockstep transport:

- Server-side `broadcast_lockstep_commands`, `broadcast_lockstep_checksum`,
  `send_lockstep_commands_to`, `send_lockstep_checksum_to`
- Client-side `send_lockstep_commands`, `send_lockstep_checksum`
- Inbound queues with `pop_lockstep_command`, `pop_lockstep_checksum`,
  `pending_lockstep_command_count`, `pending_lockstep_checksum_count`,
  and matching `SessionEvent.lockstep_command_received` / `SessionEvent.lockstep_checksum_received` events
- Turn collection, sealing, checksum reporting, and desync detection live in
  `std.multiplayer.lockstep` and are intentionally separate from the transport layer

End-to-end coverage is in `test/std/std_multiplayer_enet_lockstep_test.rb`.

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
- `test/std/std_multiplayer_rollback_test.rb`
- `test/std/std_multiplayer_session_test.rb`
- `test/std/std_multiplayer_enet_lockstep_test.rb`
- `test/std/std_multiplayer_lockstep_test.rb`

## Explicitly Not Implemented Here

1. Automatic NAT traversal or NAT punching.
2. Lobby/matchmaking services.
3. Full prediction/rollback netcode (explicit `std.multiplayer.rollback` primitives exist; higher-level automatic prediction is still caller-owned).
4. Dedicated built-in relay or discovery services.
5. Per-peer `ConnectionStats` exposure (the struct is defined in `std.multiplayer.protocol` but the ENet backend does not yet populate it; peer RTT is available but not wired through).

## Remaining Follow-On Work

When prioritized, multiplayer follow-on work should stay additive and explicit, reusing the existing registry/world/rpc/snapshot contract instead of hiding costs or forcing false backend symmetry.

Current prioritized plan:

1. Explicit reusable snapshot preparation.
Status: done.
Work completed:
- `World.prepare_snapshot(tick, baseline_tick)` now returns an owned prepared snapshot with header, signature, and payload
- ENet world dispatch now uses that explicit prepared snapshot surface internally instead of reassembling header and payload ad hoc
- focused world runtime coverage validates prepared snapshot reuse and payload round-trip

2. Per-peer outbound snapshot baselines and fair-dispatch correctness.
Status: done.
Work completed:
- ENet server outbound snapshot baselines now track state per verified connection instead of one shared server-wide baseline
- world-signature suppression now evaluates per peer, so unchanged world state is still sent to peers skipped by earlier fair or budgeted dispatch passes
- direct server snapshot sends, broadcast sends, budgeted sends, weighted sends, and fair scheduled sends now only advance the peers that actually received the snapshot
- focused runtime coverage now includes a skipped-peer regression proving unchanged world state is not starved behind another peer's baseline progress

3. Prediction/rollback primitives.
Status: implemented as explicit primitives; higher-level gameplay policy remains caller-owned.
Work completed:
- `std.multiplayer.rollback` now provides explicit rollback history storage for inputs or states
- history recording enforces nondecreasing ticks unless callers explicitly `discard_after(...)` first
- `resimulate_from(...)` now rebuilds future state from a known authoritative tick plus recorded inputs and a caller-supplied simulation step
- `reconcile_authoritative(...)` now provides the next explicit rollback layer for caller-owned correction flows: trim stale inputs, rewrite the authoritative base state at tick `T`, and replay retained inputs from there
- multiplayer docs and focused runtime coverage now include a gameplay-style authoritative correction example for replaying predicted player state
- `std.multiplayer.enet_sync.drain_observer_state_with_info(...)` now preserves the latest authoritative snapshot tick for simple gameplay clients instead of discarding it during decode
- focused runtime coverage validates append/replace, lookup, capacity trimming, rollback-boundary trimming, and explicit replay

What is still not implemented:
- no automatic prediction loop
- no automatic rollback/resimulation scheduler
- no built-in authoritative reconciliation policy layered over arbitrary gameplay state
- no deterministic lockstep or command-turn runtime for RTS-style simulation

Preferred next step:
- add higher-level helpers only when a second real gameplay use case proves the contract, rather than promoting one application's correction flow into hidden stdlib policy

4. Gameplay session orchestration helpers.
Status: implemented as initial runtime primitives; first gameplay-facing adoption is now validated.
Work completed:
- `std.multiplayer.session` now provides a backend-neutral `SlotRoster` for fixed slot occupancy and ready-state tracking
- slot claims stay explicit: claim a specific slot, claim the first open slot, release a disconnected connection, and clear ready-state between rounds or scene transitions
- aggregate readiness checks now let games gate host-started transitions on "at least one occupied slot and every occupied slot is ready"
- `begin_transition(min_players)` now provides the first explicit host-started scene-transition barrier: validate minimum occupied players, require all occupied slots to be ready, and clear ready-state only after a transition actually starts
- `std.multiplayer` now re-exports `SlotRoster` and `SlotEntry` so gameplay code can stay on the root import for common cases
- focused runtime coverage now validates claim, conflict rejection, release, ready toggling, aggregate ready-state behavior, host-started transition gating, and repeated transition reuse after ready-state reset
- the shipped Pong smoke path now validates the gameplay-facing contract directly: a verified remote connection alone is not enough to start, and the lobby transition gate only opens after real join input is received

What is still not implemented:
- no reconnect-safe player identity or reclaim token model
- no built-in host-start signal transport or scene-specific barrier payload beyond the ready gate itself
- no team metadata, seat metadata beyond slot index, or per-slot arbitrary payload storage

Why this is the right current scope:
- 4-player and 8-player games usually need repeated join/leave, ready-state, seat assignment, and scene-transition handling even when transport stays ENet-only
- the current repository can truthfully implement slot and ready-state bookkeeping now, but it does not yet have the shared gameplay demand to justify a larger hidden session runtime

Preferred scope if started:
- add reconnect-safe player identity and richer scene-transition signaling only when a second gameplay package needs the same policy
- keep service discovery, persistence, and internet matchmaking out of stdlib

5. Transport-neutral gameplay session abstraction.
Status: deferred pending clearer backend convergence.
Why deferred:
- the runtime intentionally centers ENet as the gameplay/network transport
- introducing another generic session abstraction without a second truthful backend would only add indirection

Preferred next step when this becomes worth doing:
- only revisit this if another truthful transport backend returns or if dedicated-server/client orchestration needs a smaller common facade

6. Lobby/matchmaking services.
Status: deferred outside core runtime boundary.
Why deferred:
- the repository does not yet contain a truthful service boundary for room discovery, tickets, persistence, or platform identity
- adding a stdlib lobby surface now would be fake orchestration with no concrete backend contract behind it

Preferred next step when this becomes worth doing:
- choose one real service boundary first, for example an explicit HTTP service contract or platform SDK adapter
- keep the boundary additive to ENet-facing runtime modules instead of baking discovery policy into core transport/runtime code

7. Deterministic lockstep helpers.
Status: implemented as the initial narrow runtime surface; ENet transport path validated.
Work completed:
- `std.multiplayer.lockstep` now ships `TurnCollector[T]`, `CommandEnvelope[T]`, `ChecksumReport`, `DesyncReport`, and `TurnStatus`
- per-slot submission tracking, sealing, application, checksum reporting, and refusal-to-advance on desync are all enforced at runtime
- raw ENet-facing command and checksum packet codecs plus owned incoming queue helpers are in place
- the `std.multiplayer.enet` backend ships server-side `broadcast_lockstep_*` / `send_lockstep_*_to` and client-side `send_lockstep_*`, plus `pop_lockstep_command` / `pop_lockstep_checksum` and matching `SessionEvent` entries
- focused runtime coverage in `test/std/std_multiplayer_lockstep_test.rb` and end-to-end transport coverage in `test/std/std_multiplayer_enet_lockstep_test.rb` validate the contract
- the full design and remaining surface lives in `docs/multiplayer-lockstep-rfc.md`

Why this is the right current scope:
- the runtime can truthfully run deterministic turn collection and per-peer checksum exchange now
- richer deadline and recovery policy should wait for a second RTS-style gameplay package that proves the contract, rather than baking one application's policy into stdlib

8. Surface and housekeeping cleanups.
Status: known, low priority.
Items:
- `Server.dispatch_tick_fair(...)` is a one-line wrapper around `dispatch_world_tick_fair(...)` and should be removed; the world-snapshot-aware version is the only one callers need
- inbound snapshots currently decode the header twice: once when `enqueue_incoming` validates the packet, then again in `apply_from_packet`; the receiver path should decode once and reuse the parsed header
- `RpcContext.tick` is always 0 on inbound RPCs; either populate it from the snapshot tick the server is currently emitting (when the connection has a known baseline) or document the field as caller-reserved
- `ConnectionStats` is defined in `std.multiplayer.protocol` but the ENet backend never populates it; expose a per-`Server` accessor that fills the struct from ENet peer RTT/loss fields
- `runtime_ref_count` in `std.multiplayer.enet` is a plain counter; safe in the current single-threaded runtime but should be re-evaluated before any concurrent host/client usage

These are intentionally not blocking: they do not change wire compatibility, do not affect the public surface area exposed through `std.multiplayer`, and do not break any covered behavior.

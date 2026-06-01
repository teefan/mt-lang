# Deterministic Lockstep For LAN Strategy Games

Status: draft

This RFC defines the intended path for Warcraft-style LAN multiplayer so it stays separate from the current snapshot/rollback guidance.

## Why This Is Separate

The current multiplayer runtime is strongest at authoritative snapshot replication plus explicit RPCs. That is a good fit for party games, action games, and simple host-authoritative simulations.

It is not the right primary model for classic RTS-style games with 4 to 8 players sharing one large deterministic simulation. Those games benefit more from synchronized command turns, replayability, and desync detection than from continuously correcting rich world state through snapshots.

## Target Games

This path is for games with properties closer to Warcraft 1 than to Mario Party:

- many shared world entities simulated by the same deterministic rules on every machine
- low-frequency player commands with high gameplay impact
- LAN or stable-peer environments where command delays are acceptable if they preserve simulation agreement
- strong need for replay, checksum validation, and desync diagnosis

## Non-Goals

This RFC does not define:

- internet matchmaking, discovery, or relay services
- NAT traversal or punching
- graphical interpolation or client-side prediction for action gameplay
- replacement of the current snapshot/RPC runtime for games that do not need lockstep

## Proposed Layer Boundary

Lockstep is now a separate runtime layer that sits above ENet transport and beside snapshot replication rather than inside rollback helpers.

Likely shape:

- transport: `std.multiplayer.enet` still carries packets and session events
- session bookkeeping: `std.multiplayer.session` continues to manage slot occupancy, ready-state, and simple host-started lobby transition gates
- lockstep layer: `std.multiplayer.lockstep` now manages turn collection, sealing, deterministic checksum reporting, and desync detection for one active turn at a time

## Core Runtime Responsibilities

The current lockstep layer now provides the first truthful subset of these primitives:

1. Turn schedule management.
Each simulation step belongs to a command turn with an explicit command budget. Deadline policy is still caller-owned.

2. Per-player command collection.
Each participating slot submits zero or more commands for a future turn. The runtime tracks which slots have submitted and which are still pending.

3. Turn sealing.
When all required slots have submitted, callers can seal the turn and expose its ordered command batch for deterministic simulation.

4. Deterministic checksum reporting.
After applying a sealed turn, peers report a checksum or digest for the resulting simulation frame so desyncs can be detected quickly.

5. Desync diagnostics.
The runtime reports who diverged, on which turn, and with which checksum mismatch. It does not let the turn advance after a detected checksum mismatch.

## Likely API Direction

The stdlib API current local proof surface includes:

- fixed-size `CommandEnvelope` values carrying `slot`, `turn_id`, and gameplay payload
- explicit command kinds for move, harvest, worker training, and militia training
- queued future-turn submission through `pending_input_turn(...)` and `enqueue_*` helpers
- deterministic per-turn application through `apply_due_commands(...)`
- reproducible smoke coverage over the resulting checksum

The first honest runtime surface now stays close to that shape:

- `TurnId`
- `CommandEnvelope[T]` with `slot`, `turn`, and payload
- `TurnStatus` for collecting, sealed, applied, and desynced states
- `ChecksumReport`
- `DesyncReport`
- `TurnCollector[T]` for slot submission, sealing, checksum reporting, and safe turn advance

What it should not do initially:

- simulate arbitrary gameplay itself
- hide deadlines or correction policy behind opaque background threads
- assume internet-facing discovery or persistence services

## Interaction With Existing Snapshot/Rollback Helpers

Snapshot replication and rollback remain useful, but not as the primary simulation model for RTS lockstep.

- snapshots can still support spectators, late join state transfer, or debugging tools
- rollback helpers can still support local tooling or deterministic replay utilities
- neither should become the default command-turn runtime for Warcraft-style games

## Recommended Implementation Order

If a Warcraft-style package becomes active work, the order should be:

1. Define deterministic gameplay rules and checksum surface in the game package.
2. Done: add a narrow lockstep turn-collection runtime with no discovery or service layer.
3. Add desync reporting and replay capture before adding convenience abstractions.
4. Only then consider rejoin, spectator sync, or partial state snapshots.

## When We Can Start

We can start the Warcraft-style networking implementation now, but only in the right order.

The first honest milestone is not a generic lockstep runtime. It is a deterministic RTS gameplay package with:

- fixed-tick simulation that avoids hidden frame-time dependence
- integer or otherwise deterministic gameplay state
- a narrow command surface for unit orders and production
- a reproducible checksum over gameplay-relevant state

That extracted runtime surface now covers:

- `TurnId`
- command envelopes for move, harvest, and production orders
- submission tracking per slot
- checksum exchange and desync reporting

The next pass should build the ENet-facing command exchange on top of that runtime surface rather than expanding the runtime toward service-layer concerns.

That means networking work can begin now on top of the proven LAN RTS command surface. It should still begin with narrow turn collection and checksum exchange, not with matchmaking, relay services, or a broad generic framework.

## Current Repository Boundary

Today this repository implements an initial lockstep runtime helper layer. That is intentional and limited.

The active multiplayer runtime currently ships:

- ENet transport and authoritative snapshot/RPC flow
- explicit rollback primitives
- initial session slot, ready-state, and host-started transition-gate helpers
- initial lockstep turn collection, sealing, checksum reporting, and desync detection in `std.multiplayer.lockstep`
- raw ENet-facing lockstep command/checksum packet codecs plus incoming queue helpers for deterministic turn transport

The dedicated lockstep path described here exists so future RTS work has a truthful target that does not distort the rest of the multiplayer docs.

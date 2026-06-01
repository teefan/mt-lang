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

If implemented, lockstep should be a separate runtime layer that sits above ENet transport and beside snapshot replication rather than inside rollback helpers.

Likely shape:

- transport: `std.multiplayer.enet` still carries packets and session events
- session bookkeeping: `std.multiplayer.session` continues to manage slot occupancy, ready-state, and simple host-started lobby transition gates
- lockstep layer: future `std.multiplayer.lockstep` manages turn windows, command collection, deterministic checksums, and desync reporting

## Core Runtime Responsibilities

The future lockstep layer should provide these primitives:

1. Turn schedule management.
Each simulation step belongs to a command turn with an explicit deadline and command budget.

2. Per-player command collection.
Each participating slot submits zero or more commands for a future turn. The runtime tracks which slots have submitted and which are still pending.

3. Turn sealing.
When all required slots have submitted, or when a configured deadline policy fires, the turn seals and exposes an ordered command batch for deterministic simulation.

4. Deterministic checksum reporting.
After applying a sealed turn, peers report a checksum or digest for the resulting simulation frame so desyncs can be detected quickly.

5. Desync diagnostics.
The runtime reports who diverged, on which turn, and with which checksum mismatch. It should not silently continue as if simulation agreement still exists.

## Likely API Direction

The exact API should be proven by a real gameplay package, but the first honest surface will likely need types in this shape:

- `TurnId`
- `SlotMask` or equivalent participant set tracking
- `CommandEnvelope[T]` with `slot`, `turn`, and payload
- `TurnStatus` for collecting, sealed, applied, and desynced states
- `ChecksumReport`
- manager type for turn collection and sealing

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
2. Add a narrow lockstep turn-collection runtime with no discovery or service layer.
3. Add desync reporting and replay capture before adding convenience abstractions.
4. Only then consider rejoin, spectator sync, or partial state snapshots.

## Current Repository Boundary

Today this repository does not implement lockstep runtime helpers. That is intentional.

The active multiplayer runtime currently ships:

- ENet transport and authoritative snapshot/RPC flow
- explicit rollback primitives
- initial session slot, ready-state, and host-started transition-gate helpers

The dedicated lockstep path described here exists so future RTS work has a truthful target that does not distort the rest of the multiplayer docs.

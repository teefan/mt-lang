# Pong (Multiplayer)

This package is a multiplayer Pong prototype built with Milk Tea, raylib, and raygui.

## Run

Build:

```sh
./bin/mtc build projects/pong --keep-c /tmp/pong.c
```

Run GUI:

```sh
projects/pong/build/bin/linux/debug/pong
```

Run deterministic headless smoke check:

```sh
projects/pong/build/bin/linux/debug/pong --smoke
```

## Gameplay Flow

1. Start one instance and click `Host Game`.
2. Start a second instance and click `Join Localhost`.
3. In host lobby, wait until remote input is detected, then click `Start Match`.

## Controls

- Host paddle: `W` / `S`
- Join paddle: `Up` / `Down`
- `Esc`: back to lobby/menu

## Notes

- Join target is configurable in the menu host/port fields.
- Host is authoritative and broadcasts snapshots.
- Client sends input RPC packets to host.

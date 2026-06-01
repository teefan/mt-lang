import networking as pong_net
import std.multiplayer as mp
import std.multiplayer.enet as mp_enet
import std.multiplayer.enet_sync as mp_enet_sync

const local_snapshot_tick_hz: uint = 60


public function broadcast_state_snapshot(
    server: ref[mp_enet.Server],
    tick: mp.Tick,
    state: pong_net.PongNetState,
) -> Result[bool, mp.Error]:
    return mp_enet_sync.broadcast_observer_state(
        snapshot_sync(),
        server,
        tick,
        state,
        pong_net.encode_state_snapshot,
    )


public function drain_state_snapshots(
    client: ref[mp_enet.Client],
    state: ref[pong_net.PongNetState],
) -> Result[ptr_uint, mp.Error]:
    return mp_enet_sync.drain_observer_state(
        snapshot_sync(),
        client,
        state,
        pong_net.decode_state_snapshot,
    )


public function drain_state_snapshots_with_info(
    client: ref[mp_enet.Client],
    state: ref[pong_net.PongNetState],
) -> Result[mp_enet_sync.DrainObserverStateResult, mp.Error]:
    return mp_enet_sync.drain_observer_state_with_info(
        client,
        state,
        pong_net.decode_state_snapshot,
    )


function snapshot_sync() -> mp_enet_sync.ObserverStateSync[pong_net.PongNetState]:
    return mp_enet_sync.ObserverStateSync[pong_net.PongNetState](
        descriptor = pong_net.state_descriptor(),
        local_tick_hz = local_snapshot_tick_hz,
        entity_count = 1,
    )

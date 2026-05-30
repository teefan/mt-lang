import std.enet as enet
import std.multiplayer as mp
import std.multiplayer.snapshot as snapshot_runtime
import std.multiplayer.rpc as rpc_runtime
import std.multiplayer.wire as wire
import std.vec as vec

var runtime_ref_count: ptr_uint = 0

public struct Server:
    host: ptr[enet.Host]?
    world: mp.World
    session_events: vec.Vec[SessionEventRecord]
    incoming_snapshots: vec.Vec[snapshot_runtime.IncomingSnapshotPacket]
    incoming_rpcs: vec.Vec[rpc_runtime.IncomingRpcPacket]
    unknown_packet_count: ptr_uint
    snapshot_budget_cursor: ptr_uint
    outbound_snapshot_baseline: snapshot_runtime.BaselineSet
    inbound_snapshot_baseline: snapshot_runtime.BaselineSet
    outbound_world_signature_baseline: snapshot_runtime.BaselineSet

public struct Client:
    host: ptr[enet.Host]?
    peer: ptr[enet.Peer]?
    protocol_verified: bool
    connection_id_value: Option[mp.ConnectionId]
    world: mp.World
    session_events: vec.Vec[SessionEventRecord]
    incoming_snapshots: vec.Vec[snapshot_runtime.IncomingSnapshotPacket]
    incoming_rpcs: vec.Vec[rpc_runtime.IncomingRpcPacket]
    unknown_packet_count: ptr_uint
    outbound_snapshot_baseline: snapshot_runtime.BaselineSet
    inbound_snapshot_baseline: snapshot_runtime.BaselineSet

public enum SessionEvent: ubyte
    connected = 0
    disconnected = 1
    snapshot_received = 2
    rpc_received = 3

public struct SessionEventRecord:
    kind: SessionEvent
    connection: Option[mp.ConnectionId]

public struct WeightedConnection:
    connection: mp.ConnectionId
    weight: uint

public struct TypedRpcRoute:
    descriptor: mp.RpcDescriptor
    handler: fn(context: mp.RpcContext, payload: span[ubyte]) -> Result[bool, rpc_runtime.DispatchError]

public struct TypedRpcDispatchTable:
    routes: vec.Vec[TypedRpcRoute]


extending TypedRpcDispatchTable:
    public static function create() -> TypedRpcDispatchTable:
        return TypedRpcDispatchTable(routes = vec.Vec[TypedRpcRoute].create())


    public function route_count() -> ptr_uint:
        return this.routes.len()


    public mutable function release() -> void:
        this.routes.release()


    public mutable function register_route(
        descriptor: mp.RpcDescriptor,
        handler: fn(context: mp.RpcContext, payload: span[ubyte]) -> Result[bool, rpc_runtime.DispatchError],
    ) -> Result[bool, mp.Error]:
        if typed_rpc_find_route(this.routes.as_span(), descriptor) != null:
            return Result[bool, mp.Error].failure(
                error = mp.error(mp.ErrorCode.already_registered, "typed rpc route is already registered")
            )

        this.routes.push(TypedRpcRoute(descriptor = descriptor, handler = handler))
        return Result[bool, mp.Error].success(value = true)


    public function dispatch_packet(
        context: mp.RpcContext,
        header: mp.RpcPacketHeader,
        payload: span[ubyte],
    ) -> Result[bool, mp.Error]:
        return typed_rpc_dispatch_packet(this.routes.as_span(), context, header, payload)


extending Server:
    public mutable function world_ptr() -> ptr[mp.World]:
        return ptr_of(this.world)


    public mutable function pump(timeout_ms: uint) -> Result[ptr_uint, mp.Error]:
        let host = this.host else:
            return Result[ptr_uint, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "server host is not initialized"
            ))

        var processed: ptr_uint = 0
        var evt = empty_event()
        let serviced = enet.host_service(host, ptr_of(evt), timeout_ms)
        if serviced < 0:
            return Result[ptr_uint, mp.Error].failure(error = mp.error(
                mp.ErrorCode.unsupported,
                "enet host_service failed"
            ))

        if serviced > 0:
            processed += 1
            this.apply_server_event(ptr_of(evt))

        while true:
            let polled = enet.host_check_events(host, ptr_of(evt))
            if polled < 0:
                return Result[ptr_uint, mp.Error].failure(error = mp.error(
                    mp.ErrorCode.unsupported,
                    "enet host_check_events failed"
                ))
            if polled == 0:
                break

            processed += 1
            this.apply_server_event(ptr_of(evt))

        return Result[ptr_uint, mp.Error].success(value = processed)


    public function flush() -> void:
        let host = this.host else:
            return

        enet.host_flush(host)


    public function disconnect_connection(connection: mp.ConnectionId, data: uint) -> Result[bool, mp.Error]:
        let host = this.host else:
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "server host is not initialized"
            ))

        let peer = find_verified_peer(host, connection) else:
            return Result[bool, mp.Error].success(value = false)

        enet.peer_disconnect_later(peer, data)
        return Result[bool, mp.Error].success(value = true)


    public function disconnect_all(data: uint) -> Result[ptr_uint, mp.Error]:
        let host = this.host else:
            return Result[ptr_uint, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "server host is not initialized"
            ))

        var disconnected: ptr_uint = 0
        unsafe:
            let peers = read(host).peers
            let peer_count = read(host).peerCount
            var index: ptr_uint = 0
            while index < peer_count:
                let peer = peers + index
                if read(peer).state == enet.PeerState.ENET_PEER_STATE_CONNECTED and is_peer_verified(peer):
                    enet.peer_disconnect_later(peer, data)
                    disconnected += 1
                index += 1

        return Result[ptr_uint, mp.Error].success(value = disconnected)


    public mutable function release() -> void:
        if this.host != null:
            unsafe:
                enet.host_destroy(ptr[enet.Host]<-this.host)
            this.host = null
            release_runtime()

        this.session_events.release()
        snapshot_runtime.release_queue(ref_of(this.incoming_snapshots))
        rpc_runtime.release_queue(ref_of(this.incoming_rpcs))
        this.unknown_packet_count = 0
        this.snapshot_budget_cursor = 0
        reset_snapshot_baseline(ref_of(this.outbound_snapshot_baseline))
        reset_snapshot_baseline(ref_of(this.inbound_snapshot_baseline))
        reset_snapshot_baseline(ref_of(this.outbound_world_signature_baseline))
        this.world.release()


    public function pending_snapshot_count() -> ptr_uint:
        return this.incoming_snapshots.len()


    public function pending_rpc_count() -> ptr_uint:
        return this.incoming_rpcs.len()


    public function pending_unknown_count() -> ptr_uint:
        return this.unknown_packet_count


    public function pending_session_event_count() -> ptr_uint:
        return this.session_events.len()


    public function outbound_snapshot_baseline_state() -> snapshot_runtime.BaselineSet:
        return this.outbound_snapshot_baseline


    public function inbound_snapshot_baseline_state() -> snapshot_runtime.BaselineSet:
        return this.inbound_snapshot_baseline


    public function connected_peer_count() -> ptr_uint:
        let host = this.host else:
            return 0

        unsafe:
            return read(host).connectedPeers


    public function verified_peer_count() -> ptr_uint:
        let host = this.host else:
            return 0

        var count: ptr_uint = 0
        unsafe:
            let peers = read(host).peers
            let peer_count = read(host).peerCount
            var index: ptr_uint = 0
            while index < peer_count:
                let peer = peers + index
                if read(peer).state == enet.PeerState.ENET_PEER_STATE_CONNECTED and is_peer_verified(peer):
                    count += 1
                index += 1

        return count


    public function has_verified_connection(connection: mp.ConnectionId) -> bool:
        let host = this.host else:
            return false

        unsafe:
            let peers = read(host).peers
            let peer_count = read(host).peerCount
            var index: ptr_uint = 0
            while index < peer_count:
                let peer = peers + index
                if read(peer).state == enet.PeerState.ENET_PEER_STATE_CONNECTED and is_peer_verified(peer):
                    if peer_connection_id(peer) == connection:
                        return true
                index += 1

        return false


    public function first_verified_connection() -> Option[mp.ConnectionId]:
        let host = this.host else:
            return Option[mp.ConnectionId].none

        unsafe:
            let peers = read(host).peers
            let peer_count = read(host).peerCount
            var index: ptr_uint = 0
            while index < peer_count:
                let peer = peers + index
                if read(peer).state == enet.PeerState.ENET_PEER_STATE_CONNECTED and is_peer_verified(peer):
                    return Option[mp.ConnectionId].some(value = peer_connection_id(peer))
                index += 1

        return Option[mp.ConnectionId].none


    public function listening_port() -> Result[ushort, mp.Error]:
        let host = this.host else:
            return Result[ushort, mp.Error].failure(
                error = mp.error(mp.ErrorCode.not_found, "server host is not initialized"),
            )

        unsafe:
            return Result[ushort, mp.Error].success(value = read(host).address.port)


    public mutable function pop_session_event() -> Option[SessionEventRecord]:
        return dequeue_session_event(ref_of(this.session_events))


    public mutable function pop_snapshot() -> Option[snapshot_runtime.IncomingSnapshotPacket]:
        return snapshot_runtime.dequeue_incoming(ref_of(this.incoming_snapshots))


    public mutable function pop_rpc() -> Option[rpc_runtime.IncomingRpcPacket]:
        return rpc_runtime.dequeue_incoming(ref_of(this.incoming_rpcs))


    public mutable function process_incoming_snapshots() -> Result[ptr_uint, mp.Error]:
        var processed: ptr_uint = 0
        while true:
            var packet = this.pop_snapshot() else:
                return Result[ptr_uint, mp.Error].success(value = processed)

            match this.world.apply_snapshot_payload(packet.payload.as_span()):
                Result.success:
                    snapshot_runtime.apply_payload(
                        packet.header.tick,
                        packet.header.entity_count,
                        packet.payload.as_span(),
                        ref_of(this.inbound_snapshot_baseline)
                    )
                    processed += 1
                Result.failure as payload:
                    packet.release()
                    return Result[ptr_uint, mp.Error].failure(error = payload.error)

            packet.release()


    public mutable function process_incoming_rpcs_typed(
        table: ref[TypedRpcDispatchTable],
    ) -> Result[ptr_uint, mp.Error]:
        var processed: ptr_uint = 0
        while true:
            var packet = this.pop_rpc() else:
                return Result[ptr_uint, mp.Error].success(value = processed)

            let dispatched = table.dispatch_packet(
                packet.context,
                packet.header,
                packet.payload.as_span()
            ) else as dispatch_error:
                packet.release()
                return Result[ptr_uint, mp.Error].failure(error = dispatch_error)

            if dispatched:
                processed += 1

            packet.release()


    public mutable function broadcast_snapshot(
        channel: uint,
        transfer_mode: mp.TransferMode,
        header: mp.SnapshotPacketHeader,
        payload: span[ubyte]
    ) -> Result[bool, mp.Error]:
        let host = this.host else:
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "server host is not initialized"
            ))

        var encoded = snapshot_runtime.build_payload(header, payload)
        defer encoded.release()
        let sent = broadcast_wire_payload(
            host,
            channel,
            transfer_mode,
            mp.PacketKind.snapshot,
            encoded.as_span()
        ) else as send_error:
            return Result[bool, mp.Error].failure(error = send_error)

        if sent:
            snapshot_runtime.apply_payload(
                header.tick,
                header.entity_count,
                payload,
                ref_of(this.outbound_snapshot_baseline)
            )

        return Result[bool, mp.Error].success(value = sent)


    public function estimate_snapshot_wire_bytes(header: mp.SnapshotPacketHeader, payload: span[ubyte]) -> ptr_uint:
        return snapshot_wire_bytes(header, payload)


    public function broadcast_rpc(
        channel: uint,
        transfer_mode: mp.TransferMode,
        direction: mp.RpcDirection,
        payload: span[ubyte]
    ) -> Result[bool, mp.Error]:
        let host = this.host else:
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "server host is not initialized"
            ))
        let _ = validate_server_outbound_direction(direction) else as direction_error:
            return Result[bool, mp.Error].failure(error = direction_error)

        let header = mp.RpcPacketHeader(channel = channel, direction = direction, payload_size = payload.len)
        var encoded = rpc_runtime.build_payload(header, payload)
        defer encoded.release()
        return broadcast_wire_payload(host, channel, transfer_mode, mp.PacketKind.rpc, encoded.as_span())


    public function estimate_rpc_wire_bytes(
        channel: uint,
        direction: mp.RpcDirection,
        payload: span[ubyte]
    ) -> ptr_uint:
        return rpc_wire_bytes(channel, direction, payload)


    public mutable function broadcast_snapshot_scheduled(
        scheduler: ref[mp.TickScheduler],
        channel: uint,
        transfer_mode: mp.TransferMode,
        header: mp.SnapshotPacketHeader,
        payload: span[ubyte],
    ) -> Result[bool, mp.Error]:
        let required_bytes = snapshot_wire_bytes(header, payload)
        let _ = scheduler.reserve(required_bytes) else:
            return Result[bool, mp.Error].success(value = false)
        return this.broadcast_snapshot(channel, transfer_mode, header, payload)


    public mutable function broadcast_snapshot_scheduled_fair(
        scheduler: ref[mp.TickScheduler],
        channel: uint,
        transfer_mode: mp.TransferMode,
        header: mp.SnapshotPacketHeader,
        payload: span[ubyte],
    ) -> Result[ptr_uint, mp.Error]:
        let host = this.host else:
            return Result[ptr_uint, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "server host is not initialized"
            ))

        var connections = vec.Vec[mp.ConnectionId].create()
        defer connections.release()
        append_verified_connections(host, ref_of(connections))
        if connections.len() == 0:
            return Result[ptr_uint, mp.Error].success(value = 0)

        let start_index = this.snapshot_budget_cursor % connections.len()
        var ordered_connections = vec.Vec[mp.ConnectionId].with_capacity(connections.len())
        defer ordered_connections.release()
        append_rotated_connections(connections.as_span(), start_index, ref_of(ordered_connections))

        let sent = send_snapshots_scheduled_fair_impl(
            host,
            scheduler,
            ordered_connections.as_span(),
            channel,
            transfer_mode,
            header,
            payload
        ) else as send_error:
            return Result[ptr_uint, mp.Error].failure(error = send_error)

        if sent == 0:
            this.snapshot_budget_cursor = (start_index + 1) % connections.len()
        else:
            this.snapshot_budget_cursor = (start_index + sent) % connections.len()
            snapshot_runtime.apply_payload(
                header.tick,
                header.entity_count,
                payload,
                ref_of(this.outbound_snapshot_baseline)
            )

        return Result[ptr_uint, mp.Error].success(value = sent)


    public function broadcast_rpc_scheduled(
        scheduler: ref[mp.TickScheduler],
        channel: uint,
        transfer_mode: mp.TransferMode,
        direction: mp.RpcDirection,
        payload: span[ubyte],
    ) -> Result[bool, mp.Error]:
        let required_bytes = rpc_wire_bytes(channel, direction, payload)
        let _ = scheduler.reserve(required_bytes) else:
            return Result[bool, mp.Error].success(value = false)
        return this.broadcast_rpc(channel, transfer_mode, direction, payload)


    public mutable function broadcast_rpc_scheduled_fair(
        scheduler: ref[mp.TickScheduler],
        channel: uint,
        transfer_mode: mp.TransferMode,
        direction: mp.RpcDirection,
        payload: span[ubyte],
    ) -> Result[ptr_uint, mp.Error]:
        let host = this.host else:
            return Result[ptr_uint, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "server host is not initialized"
            ))
        let _ = validate_server_outbound_direction(direction) else as direction_error:
            return Result[ptr_uint, mp.Error].failure(error = direction_error)

        var connections = vec.Vec[mp.ConnectionId].create()
        defer connections.release()
        append_verified_connections(host, ref_of(connections))
        if connections.len() == 0:
            return Result[ptr_uint, mp.Error].success(value = 0)

        let start_index = this.snapshot_budget_cursor % connections.len()
        var ordered_connections = vec.Vec[mp.ConnectionId].with_capacity(connections.len())
        defer ordered_connections.release()
        append_rotated_connections(connections.as_span(), start_index, ref_of(ordered_connections))

        let sent = send_rpcs_scheduled_fair_impl(
            host,
            scheduler,
            ordered_connections.as_span(),
            channel,
            transfer_mode,
            direction,
            payload
        ) else as send_error:
            return Result[ptr_uint, mp.Error].failure(error = send_error)

        if sent == 0:
            this.snapshot_budget_cursor = (start_index + 1) % connections.len()
        else:
            this.snapshot_budget_cursor = (start_index + sent) % connections.len()

        return Result[ptr_uint, mp.Error].success(value = sent)


    public mutable function dispatch_tick_fair(
        tick: mp.Tick,
        plan: mp.TickBudgetPlan,
        snapshot_channel: uint,
        snapshot_transfer_mode: mp.TransferMode,
        snapshot_header: mp.SnapshotPacketHeader,
        snapshot_payload: span[ubyte],
        rpc_channel: uint,
        rpc_transfer_mode: mp.TransferMode,
        rpc_direction: mp.RpcDirection,
        rpc_payload: span[ubyte],
    ) -> Result[mp.TickDispatchReport, mp.Error]:
        var snapshot_scheduler = mp.create_tick_scheduler(plan.snapshot_bytes)
        snapshot_scheduler.begin_tick(tick)
        let snapshots_sent = this.broadcast_snapshot_scheduled_fair(
            ref_of(snapshot_scheduler),
            snapshot_channel,
            snapshot_transfer_mode,
            snapshot_header,
            snapshot_payload
        ) else as snapshot_error:
            return Result[mp.TickDispatchReport, mp.Error].failure(error = snapshot_error)

        var rpc_scheduler = mp.create_tick_scheduler(plan.rpc_bytes)
        rpc_scheduler.begin_tick(tick)
        let rpcs_sent = this.broadcast_rpc_scheduled_fair(
            ref_of(rpc_scheduler),
            rpc_channel,
            rpc_transfer_mode,
            rpc_direction,
            rpc_payload
        ) else as rpc_error:
            return Result[mp.TickDispatchReport, mp.Error].failure(error = rpc_error)

        return Result[mp.TickDispatchReport, mp.Error].success(
            value = mp.TickDispatchReport(
                snapshots_sent = snapshots_sent,
                rpcs_sent = rpcs_sent,
                consumed_bytes = snapshot_scheduler.consumed_bytes() + rpc_scheduler.consumed_bytes()
            )
        )


    public mutable function dispatch_world_tick_fair(
        tick: mp.Tick,
        plan: mp.TickBudgetPlan,
        snapshot_channel: uint,
        snapshot_transfer_mode: mp.TransferMode,
        snapshot_payload: span[ubyte],
        rpc_channel: uint,
        rpc_transfer_mode: mp.TransferMode,
        rpc_direction: mp.RpcDirection,
        rpc_payload: span[ubyte],
    ) -> Result[mp.TickDispatchReport, mp.Error]:
        let current_signature = this.world.snapshot_state_signature(tick)
        let should_send_snapshot = snapshot_runtime.should_send_against_baseline(
            current_signature,
            this.outbound_world_signature_baseline
        )

        var snapshot_scheduler = mp.create_tick_scheduler(plan.snapshot_bytes)
        snapshot_scheduler.begin_tick(tick)

        var snapshots_sent: ptr_uint = 0
        if should_send_snapshot:
            var world_payload = this.world.encode_snapshot_payload() else as world_payload_error:
                return Result[mp.TickDispatchReport, mp.Error].failure(error = world_payload_error)
            defer world_payload.release()

            let snapshot_header = mp.SnapshotPacketHeader(
                tick = tick,
                baseline_tick = this.outbound_world_signature_baseline.last_applied_tick,
                entity_count = current_signature.entity_count
            )

            if snapshot_payload.len > 0:
                let sent = this.broadcast_snapshot_scheduled_fair(
                    ref_of(snapshot_scheduler),
                    snapshot_channel,
                    snapshot_transfer_mode,
                    snapshot_header,
                    snapshot_payload
                ) else as snapshot_error:
                    return Result[mp.TickDispatchReport, mp.Error].failure(error = snapshot_error)
                snapshots_sent = sent
            else:
                let sent = this.broadcast_snapshot_scheduled_fair(
                    ref_of(snapshot_scheduler),
                    snapshot_channel,
                    snapshot_transfer_mode,
                    snapshot_header,
                    world_payload.as_span()
                ) else as snapshot_error:
                    return Result[mp.TickDispatchReport, mp.Error].failure(error = snapshot_error)
                snapshots_sent = sent

            if snapshots_sent > 0:
                snapshot_runtime.apply(current_signature, ref_of(this.outbound_world_signature_baseline))

        var rpc_scheduler = mp.create_tick_scheduler(plan.rpc_bytes)
        rpc_scheduler.begin_tick(tick)
        let rpcs_sent = this.broadcast_rpc_scheduled_fair(
            ref_of(rpc_scheduler),
            rpc_channel,
            rpc_transfer_mode,
            rpc_direction,
            rpc_payload
        ) else as rpc_error:
            return Result[mp.TickDispatchReport, mp.Error].failure(error = rpc_error)

        return Result[mp.TickDispatchReport, mp.Error].success(
            value = mp.TickDispatchReport(
                snapshots_sent = snapshots_sent,
                rpcs_sent = rpcs_sent,
                consumed_bytes = snapshot_scheduler.consumed_bytes() + rpc_scheduler.consumed_bytes()
            )
        )


    public function send_rpc_to(
        connection: mp.ConnectionId,
        channel: uint,
        transfer_mode: mp.TransferMode,
        direction: mp.RpcDirection,
        payload: span[ubyte]
    ) -> Result[bool, mp.Error]:
        let host = this.host else:
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "server host is not initialized"
            ))
        let _ = validate_server_outbound_direction(direction) else as direction_error:
            return Result[bool, mp.Error].failure(error = direction_error)

        let peer = find_verified_peer(host, connection) else:
            return Result[bool, mp.Error].failure(
                error = mp.error(
                    mp.ErrorCode.not_found,
                    "verified target connection was not found",
                ),
            )

        let header = mp.RpcPacketHeader(channel = channel, direction = direction, payload_size = payload.len)
        var encoded = rpc_runtime.build_payload(header, payload)
        defer encoded.release()
        return send_wire_payload(peer, channel, transfer_mode, mp.PacketKind.rpc, encoded.as_span())


    public function send_rpc_to_scheduled(
        scheduler: ref[mp.TickScheduler],
        connection: mp.ConnectionId,
        channel: uint,
        transfer_mode: mp.TransferMode,
        direction: mp.RpcDirection,
        payload: span[ubyte],
    ) -> Result[bool, mp.Error]:
        let host = this.host else:
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "server host is not initialized"
            ))

        if find_verified_peer(host, connection) == null:
            return Result[bool, mp.Error].failure(
                error = mp.error(
                    mp.ErrorCode.not_found,
                    "verified target connection was not found"
                )
            )

        let required_bytes = rpc_wire_bytes(channel, direction, payload)
        let _ = scheduler.reserve(required_bytes) else:
            return Result[bool, mp.Error].success(value = false)
        return this.send_rpc_to(connection, channel, transfer_mode, direction, payload)


    public mutable function send_snapshot_to(
        connection: mp.ConnectionId,
        channel: uint,
        transfer_mode: mp.TransferMode,
        header: mp.SnapshotPacketHeader,
        payload: span[ubyte]
    ) -> Result[bool, mp.Error]:
        let host = this.host else:
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "server host is not initialized"
            ))

        let peer = find_verified_peer(host, connection) else:
            return Result[bool, mp.Error].failure(
                error = mp.error(
                    mp.ErrorCode.not_found,
                    "verified target connection was not found",
                ),
            )

        var encoded = snapshot_runtime.build_payload(header, payload)
        defer encoded.release()
        let sent = send_wire_payload(
            peer,
            channel,
            transfer_mode,
            mp.PacketKind.snapshot,
            encoded.as_span()
        ) else as send_error:
            return Result[bool, mp.Error].failure(error = send_error)

        if sent:
            snapshot_runtime.apply_payload(
                header.tick,
                header.entity_count,
                payload,
                ref_of(this.outbound_snapshot_baseline)
            )

        return Result[bool, mp.Error].success(value = sent)


    public mutable function send_snapshot_to_scheduled(
        scheduler: ref[mp.TickScheduler],
        connection: mp.ConnectionId,
        channel: uint,
        transfer_mode: mp.TransferMode,
        header: mp.SnapshotPacketHeader,
        payload: span[ubyte],
    ) -> Result[bool, mp.Error]:
        let host = this.host else:
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "server host is not initialized"
            ))

        if find_verified_peer(host, connection) == null:
            return Result[bool, mp.Error].failure(
                error = mp.error(
                    mp.ErrorCode.not_found,
                    "verified target connection was not found"
                )
            )

        let required_bytes = snapshot_wire_bytes(header, payload)
        let _ = scheduler.reserve(required_bytes) else:
            return Result[bool, mp.Error].success(value = false)
        return this.send_snapshot_to(connection, channel, transfer_mode, header, payload)


    public mutable function send_snapshots_budgeted(
        prioritized_connections: span[mp.ConnectionId],
        channel: uint,
        transfer_mode: mp.TransferMode,
        header: mp.SnapshotPacketHeader,
        payload: span[ubyte],
        max_bytes: ptr_uint,
    ) -> Result[ptr_uint, mp.Error]:
        let host = this.host else:
            return Result[ptr_uint, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "server host is not initialized"
            ))

        let sent = send_snapshots_budgeted_impl(
            host,
            prioritized_connections,
            channel,
            transfer_mode,
            header,
            payload,
            max_bytes
        ) else as send_error:
            return Result[ptr_uint, mp.Error].failure(error = send_error)

        if sent > 0:
            snapshot_runtime.apply_payload(
                header.tick,
                header.entity_count,
                payload,
                ref_of(this.outbound_snapshot_baseline)
            )

        return Result[ptr_uint, mp.Error].success(value = sent)


    public mutable function broadcast_snapshot_budgeted(
        channel: uint,
        transfer_mode: mp.TransferMode,
        header: mp.SnapshotPacketHeader,
        payload: span[ubyte],
        max_bytes: ptr_uint,
    ) -> Result[ptr_uint, mp.Error]:
        let host = this.host else:
            return Result[ptr_uint, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "server host is not initialized"
            ))

        var connections = vec.Vec[mp.ConnectionId].create()
        defer connections.release()
        append_verified_connections(host, ref_of(connections))
        return this.send_snapshots_budgeted(connections.as_span(), channel, transfer_mode, header, payload, max_bytes)


    public mutable function send_snapshots_budgeted_weighted(
        weighted_connections: span[WeightedConnection],
        channel: uint,
        transfer_mode: mp.TransferMode,
        header: mp.SnapshotPacketHeader,
        payload: span[ubyte],
        max_bytes: ptr_uint,
    ) -> Result[ptr_uint, mp.Error]:
        let host = this.host else:
            return Result[ptr_uint, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "server host is not initialized"
            ))

        let sent = send_snapshots_budgeted_weighted_impl(
            host,
            weighted_connections,
            channel,
            transfer_mode,
            header,
            payload,
            max_bytes
        ) else as send_error:
            return Result[ptr_uint, mp.Error].failure(error = send_error)

        if sent > 0:
            snapshot_runtime.apply_payload(
                header.tick,
                header.entity_count,
                payload,
                ref_of(this.outbound_snapshot_baseline)
            )

        return Result[ptr_uint, mp.Error].success(value = sent)


    public mutable function broadcast_snapshot_budgeted_weighted(
        channel: uint,
        transfer_mode: mp.TransferMode,
        header: mp.SnapshotPacketHeader,
        payload: span[ubyte],
        max_bytes: ptr_uint,
    ) -> Result[ptr_uint, mp.Error]:
        let host = this.host else:
            return Result[ptr_uint, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "server host is not initialized"
            ))

        var weighted_connections = vec.Vec[WeightedConnection].create()
        defer weighted_connections.release()
        append_weighted_verified_connections(host, ref_of(weighted_connections))

        let sent = send_snapshots_budgeted_weighted_impl(
            host,
            weighted_connections.as_span(),
            channel,
            transfer_mode,
            header,
            payload,
            max_bytes
        ) else as send_error:
            return Result[ptr_uint, mp.Error].failure(error = send_error)

        if sent > 0:
            snapshot_runtime.apply_payload(
                header.tick,
                header.entity_count,
                payload,
                ref_of(this.outbound_snapshot_baseline)
            )

        return Result[ptr_uint, mp.Error].success(value = sent)


    public mutable function broadcast_snapshot_budgeted_fair(
        channel: uint,
        transfer_mode: mp.TransferMode,
        header: mp.SnapshotPacketHeader,
        payload: span[ubyte],
        max_bytes: ptr_uint,
    ) -> Result[ptr_uint, mp.Error]:
        let host = this.host else:
            return Result[ptr_uint, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "server host is not initialized"
            ))

        var connections = vec.Vec[mp.ConnectionId].create()
        defer connections.release()
        append_verified_connections(host, ref_of(connections))
        if connections.len() == 0:
            return Result[ptr_uint, mp.Error].success(value = 0)

        let start_index = this.snapshot_budget_cursor % connections.len()
        var ordered_connections = vec.Vec[mp.ConnectionId].with_capacity(connections.len())
        defer ordered_connections.release()
        append_rotated_connections(connections.as_span(), start_index, ref_of(ordered_connections))

        let sent = send_snapshots_budgeted_impl(
            host,
            ordered_connections.as_span(),
            channel,
            transfer_mode,
            header,
            payload,
            max_bytes
        ) else as send_error:
            return Result[ptr_uint, mp.Error].failure(error = send_error)

        if sent == 0:
            this.snapshot_budget_cursor = (start_index + 1) % connections.len()
        else:
            this.snapshot_budget_cursor = (start_index + sent) % connections.len()
            snapshot_runtime.apply_payload(
                header.tick,
                header.entity_count,
                payload,
                ref_of(this.outbound_snapshot_baseline)
            )

        return Result[ptr_uint, mp.Error].success(value = sent)


    public mutable function apply_server_event(evt: ptr[enet.Event]) -> void:
        unsafe:
            match read(evt).type_:
                enet.EventType.ENET_EVENT_TYPE_CONNECT:
                    enqueue_session_event(
                        ref_of(this.session_events),
                        SessionEvent.connected,
                        Option[mp.ConnectionId].some(value = peer_connection_id(read(evt).peer))
                    )
                    mark_peer_unverified(read(evt).peer)
                enet.EventType.ENET_EVENT_TYPE_DISCONNECT:
                    enqueue_session_event(
                        ref_of(this.session_events),
                        SessionEvent.disconnected,
                        Option[mp.ConnectionId].some(value = peer_connection_id(read(evt).peer))
                    )
                    mark_peer_unverified(read(evt).peer)
                enet.EventType.ENET_EVENT_TYPE_RECEIVE:
                    let kind = packet_kind(read(evt).packet) else:
                        increment_unknown_count(ref_of(this.unknown_packet_count))
                        enet.packet_destroy(read(evt).packet)
                        return

                    let payload = packet_payload_span(read(evt).packet)
                    let connection = peer_connection_id(read(evt).peer)
                    let sender = Option[mp.ConnectionId].some(value = connection)
                    match kind:
                        mp.PacketKind.handshake_hello:
                            let hello = decode_handshake_hello(payload) else:
                                increment_unknown_count(ref_of(this.unknown_packet_count))
                                enet.packet_destroy(read(evt).packet)
                                return

                            if hello.protocol_hash != this.world.protocol_hash():
                                let _ = send_handshake_reject(
                                    read(evt).peer,
                                    this.world.protocol_hash(),
                                    mp.ErrorCode.invalid_argument
                                )
                                enet.peer_disconnect_later(read(evt).peer, 0)
                            else:
                                mark_peer_verified(read(evt).peer)
                                let _ = send_handshake_welcome(read(evt).peer, this.world.protocol_hash(), connection)
                        mp.PacketKind.handshake_welcome:
                            increment_unknown_count(ref_of(this.unknown_packet_count))
                        mp.PacketKind.handshake_reject:
                            increment_unknown_count(ref_of(this.unknown_packet_count))
                        mp.PacketKind.snapshot:
                            if is_peer_verified(read(evt).peer):
                                enqueue_session_event(
                                    ref_of(this.session_events),
                                    SessionEvent.snapshot_received,
                                    sender
                                )
                                handle_received_packet(
                                    ref_of(this.world),
                                    ref_of(this.incoming_snapshots),
                                    ref_of(this.incoming_rpcs),
                                    ref_of(this.inbound_snapshot_baseline),
                                    ref_of(this.unknown_packet_count),
                                    read(evt).packet,
                                    uint<-read(evt).channelID,
                                    mp.RpcDirection.client_to_server,
                                    sender
                                )
                            else:
                                increment_unknown_count(ref_of(this.unknown_packet_count))
                        mp.PacketKind.rpc:
                            if is_peer_verified(read(evt).peer):
                                enqueue_session_event(ref_of(this.session_events), SessionEvent.rpc_received, sender)
                                handle_received_packet(
                                    ref_of(this.world),
                                    ref_of(this.incoming_snapshots),
                                    ref_of(this.incoming_rpcs),
                                    ref_of(this.inbound_snapshot_baseline),
                                    ref_of(this.unknown_packet_count),
                                    read(evt).packet,
                                    uint<-read(evt).channelID,
                                    mp.RpcDirection.client_to_server,
                                    sender
                                )
                            else:
                                increment_unknown_count(ref_of(this.unknown_packet_count))

                    enet.packet_destroy(read(evt).packet)
                enet.EventType.ENET_EVENT_TYPE_NONE:
                    pass


extending Client:
    public mutable function world_ptr() -> ptr[mp.World]:
        return ptr_of(this.world)


    public mutable function pump(timeout_ms: uint) -> Result[ptr_uint, mp.Error]:
        let host = this.host else:
            return Result[ptr_uint, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "client host is not initialized"
            ))

        var processed: ptr_uint = 0
        var evt = empty_event()
        let serviced = enet.host_service(host, ptr_of(evt), timeout_ms)
        if serviced < 0:
            return Result[ptr_uint, mp.Error].failure(error = mp.error(
                mp.ErrorCode.unsupported,
                "enet host_service failed"
            ))

        if serviced > 0:
            processed += 1
            this.apply_client_event(ptr_of(evt))

        while true:
            let polled = enet.host_check_events(host, ptr_of(evt))
            if polled < 0:
                return Result[ptr_uint, mp.Error].failure(error = mp.error(
                    mp.ErrorCode.unsupported,
                    "enet host_check_events failed"
                ))
            if polled == 0:
                break

            processed += 1
            this.apply_client_event(ptr_of(evt))

        return Result[ptr_uint, mp.Error].success(value = processed)


    public function flush() -> void:
        let host = this.host else:
            return

        enet.host_flush(host)


    public mutable function disconnect(data: uint) -> Result[bool, mp.Error]:
        let peer = this.peer else:
            return Result[bool, mp.Error].success(value = false)

        enet.peer_disconnect_later(peer, data)
        reset_snapshot_baseline(ref_of(this.outbound_snapshot_baseline))
        reset_snapshot_baseline(ref_of(this.inbound_snapshot_baseline))
        return Result[bool, mp.Error].success(value = true)


    public mutable function release() -> void:
        if this.peer != null:
            unsafe:
                enet.peer_reset(ptr[enet.Peer]<-this.peer)
            this.peer = null
            this.protocol_verified = false
            this.connection_id_value = Option[mp.ConnectionId].none

        if this.host != null:
            unsafe:
                enet.host_destroy(ptr[enet.Host]<-this.host)
            this.host = null
            release_runtime()

        this.session_events.release()
        snapshot_runtime.release_queue(ref_of(this.incoming_snapshots))
        rpc_runtime.release_queue(ref_of(this.incoming_rpcs))
        this.unknown_packet_count = 0
        reset_snapshot_baseline(ref_of(this.outbound_snapshot_baseline))
        reset_snapshot_baseline(ref_of(this.inbound_snapshot_baseline))
        this.world.release()


    public mutable function apply_client_event(evt: ptr[enet.Event]) -> void:
        unsafe:
            match read(evt).type_:
                enet.EventType.ENET_EVENT_TYPE_CONNECT:
                    this.peer = read(evt).peer
                    this.protocol_verified = false
                    this.connection_id_value = Option[mp.ConnectionId].none
                    enqueue_session_event(
                        ref_of(this.session_events),
                        SessionEvent.connected,
                        Option[mp.ConnectionId].none
                    )
                    match send_handshake_hello(read(evt).peer, this.world.protocol_hash()):
                        Result.success:
                            pass
                        Result.failure:
                            increment_unknown_count(ref_of(this.unknown_packet_count))
                enet.EventType.ENET_EVENT_TYPE_DISCONNECT:
                    enqueue_session_event(
                        ref_of(this.session_events),
                        SessionEvent.disconnected,
                        this.connection_id_value
                    )
                    this.peer = null
                    this.protocol_verified = false
                    this.connection_id_value = Option[mp.ConnectionId].none
                    reset_snapshot_baseline(ref_of(this.outbound_snapshot_baseline))
                    reset_snapshot_baseline(ref_of(this.inbound_snapshot_baseline))
                enet.EventType.ENET_EVENT_TYPE_RECEIVE:
                    let kind = packet_kind(read(evt).packet) else:
                        increment_unknown_count(ref_of(this.unknown_packet_count))
                        enet.packet_destroy(read(evt).packet)
                        return

                    let payload = packet_payload_span(read(evt).packet)
                    match kind:
                        mp.PacketKind.handshake_welcome:
                            let welcome = decode_handshake_welcome(payload) else:
                                increment_unknown_count(ref_of(this.unknown_packet_count))
                                enet.packet_destroy(read(evt).packet)
                                return

                            if welcome.protocol_hash != this.world.protocol_hash():
                                this.protocol_verified = false
                                increment_unknown_count(ref_of(this.unknown_packet_count))
                            else:
                                this.protocol_verified = true
                                this.connection_id_value = Option[mp.ConnectionId].some(value = welcome.connection)
                        mp.PacketKind.handshake_reject:
                            this.protocol_verified = false
                            increment_unknown_count(ref_of(this.unknown_packet_count))
                            if this.peer != null:
                                enet.peer_disconnect_now(ptr[enet.Peer]<-this.peer, 0)
                                this.peer = null
                            reset_snapshot_baseline(ref_of(this.outbound_snapshot_baseline))
                            reset_snapshot_baseline(ref_of(this.inbound_snapshot_baseline))
                        mp.PacketKind.handshake_hello:
                            increment_unknown_count(ref_of(this.unknown_packet_count))
                        mp.PacketKind.snapshot:
                            if this.protocol_verified:
                                enqueue_session_event(
                                    ref_of(this.session_events),
                                    SessionEvent.snapshot_received,
                                    this.connection_id_value
                                )
                                handle_received_packet(
                                    ref_of(this.world),
                                    ref_of(this.incoming_snapshots),
                                    ref_of(this.incoming_rpcs),
                                    ref_of(this.inbound_snapshot_baseline),
                                    ref_of(this.unknown_packet_count),
                                    read(evt).packet,
                                    uint<-read(evt).channelID,
                                    mp.RpcDirection.server_to_owner,
                                    this.connection_id_value
                                )
                            else:
                                increment_unknown_count(ref_of(this.unknown_packet_count))
                        mp.PacketKind.rpc:
                            if this.protocol_verified:
                                enqueue_session_event(
                                    ref_of(this.session_events),
                                    SessionEvent.rpc_received,
                                    this.connection_id_value
                                )
                                handle_received_packet(
                                    ref_of(this.world),
                                    ref_of(this.incoming_snapshots),
                                    ref_of(this.incoming_rpcs),
                                    ref_of(this.inbound_snapshot_baseline),
                                    ref_of(this.unknown_packet_count),
                                    read(evt).packet,
                                    uint<-read(evt).channelID,
                                    mp.RpcDirection.server_to_owner,
                                    this.connection_id_value
                                )
                            else:
                                increment_unknown_count(ref_of(this.unknown_packet_count))

                    enet.packet_destroy(read(evt).packet)
                enet.EventType.ENET_EVENT_TYPE_NONE:
                    pass


    public function pending_snapshot_count() -> ptr_uint:
        return this.incoming_snapshots.len()


    public function pending_rpc_count() -> ptr_uint:
        return this.incoming_rpcs.len()


    public function pending_unknown_count() -> ptr_uint:
        return this.unknown_packet_count


    public function pending_session_event_count() -> ptr_uint:
        return this.session_events.len()


    public function outbound_snapshot_baseline_state() -> snapshot_runtime.BaselineSet:
        return this.outbound_snapshot_baseline


    public function inbound_snapshot_baseline_state() -> snapshot_runtime.BaselineSet:
        return this.inbound_snapshot_baseline


    public function is_connected() -> bool:
        return this.peer != null


    public mutable function pop_session_event() -> Option[SessionEventRecord]:
        return dequeue_session_event(ref_of(this.session_events))


    public mutable function pop_snapshot() -> Option[snapshot_runtime.IncomingSnapshotPacket]:
        return snapshot_runtime.dequeue_incoming(ref_of(this.incoming_snapshots))


    public mutable function pop_rpc() -> Option[rpc_runtime.IncomingRpcPacket]:
        return rpc_runtime.dequeue_incoming(ref_of(this.incoming_rpcs))


    public mutable function process_incoming_snapshots() -> Result[ptr_uint, mp.Error]:
        var processed: ptr_uint = 0
        while true:
            var packet = this.pop_snapshot() else:
                return Result[ptr_uint, mp.Error].success(value = processed)

            match this.world.apply_snapshot_payload(packet.payload.as_span()):
                Result.success:
                    snapshot_runtime.apply_payload(
                        packet.header.tick,
                        packet.header.entity_count,
                        packet.payload.as_span(),
                        ref_of(this.inbound_snapshot_baseline)
                    )
                    processed += 1
                Result.failure as payload:
                    packet.release()
                    return Result[ptr_uint, mp.Error].failure(error = payload.error)

            packet.release()


    public mutable function process_incoming_rpcs_typed(
        table: ref[TypedRpcDispatchTable],
    ) -> Result[ptr_uint, mp.Error]:
        var processed: ptr_uint = 0
        while true:
            var packet = this.pop_rpc() else:
                return Result[ptr_uint, mp.Error].success(value = processed)

            let dispatched = table.dispatch_packet(
                packet.context,
                packet.header,
                packet.payload.as_span()
            ) else as dispatch_error:
                packet.release()
                return Result[ptr_uint, mp.Error].failure(error = dispatch_error)

            if dispatched:
                processed += 1

            packet.release()


    public function protocol_ready() -> bool:
        return this.protocol_verified


    public function connection_id() -> Option[mp.ConnectionId]:
        return this.connection_id_value


    public mutable function send_snapshot(
        channel: uint,
        transfer_mode: mp.TransferMode,
        header: mp.SnapshotPacketHeader,
        payload: span[ubyte]
    ) -> Result[bool, mp.Error]:
        let peer = this.peer else:
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "client peer is not connected"
            ))
        if not this.protocol_verified:
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.unsupported,
                "protocol handshake is not complete"
            ))

        var encoded = snapshot_runtime.build_payload(header, payload)
        defer encoded.release()
        let sent = send_wire_payload(
            peer,
            channel,
            transfer_mode,
            mp.PacketKind.snapshot,
            encoded.as_span()
        ) else as send_error:
            return Result[bool, mp.Error].failure(error = send_error)

        if sent:
            snapshot_runtime.apply_payload(
                header.tick,
                header.entity_count,
                payload,
                ref_of(this.outbound_snapshot_baseline)
            )

        return Result[bool, mp.Error].success(value = sent)


    public function send_rpc(
        channel: uint,
        transfer_mode: mp.TransferMode,
        direction: mp.RpcDirection,
        payload: span[ubyte]
    ) -> Result[bool, mp.Error]:
        let peer = this.peer else:
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "client peer is not connected"
            ))
        if not this.protocol_verified:
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.unsupported,
                "protocol handshake is not complete"
            ))
        let _ = validate_client_outbound_direction(direction) else as direction_error:
            return Result[bool, mp.Error].failure(error = direction_error)

        let header = mp.RpcPacketHeader(channel = channel, direction = direction, payload_size = payload.len)
        var encoded = rpc_runtime.build_payload(header, payload)
        defer encoded.release()
        return send_wire_payload(peer, channel, transfer_mode, mp.PacketKind.rpc, encoded.as_span())


public function listen(
    address: enet.Address,
    peer_count: ptr_uint,
    channel_limit: ptr_uint,
    registry: mp.Registry,
    config: mp.Config
) -> Result[Server, mp.Error]:
    let _ = acquire_runtime() else as runtime_error:
        return Result[Server, mp.Error].failure(error = runtime_error)

    var bind_address = address
    let host = enet.host_create(ptr_of(bind_address), peer_count, channel_limit, 0, 0) else:
        release_runtime()
        return Result[Server, mp.Error].failure(error = mp.error(
            mp.ErrorCode.unsupported,
            "enet host_create failed for server"
        ))

    let world = mp.World.create(registry, config, mp.WorldRole.server) else as world_error:
        enet.host_destroy(host)
        release_runtime()
        return Result[Server, mp.Error].failure(error = world_error)

    return Result[Server, mp.Error].success(value = Server(
        host = host,
        world = world,
        session_events = vec.Vec[SessionEventRecord].create(),
        incoming_snapshots = vec.Vec[snapshot_runtime.IncomingSnapshotPacket].create(),
        incoming_rpcs = vec.Vec[rpc_runtime.IncomingRpcPacket].create(),
        unknown_packet_count = 0,
        snapshot_budget_cursor = 0,
        outbound_snapshot_baseline = empty_snapshot_baseline(),
        inbound_snapshot_baseline = empty_snapshot_baseline(),
        outbound_world_signature_baseline = empty_snapshot_baseline()
    ))


public function listen_localhost(
    peer_count: ptr_uint,
    channel_limit: ptr_uint,
    registry: mp.Registry,
    config: mp.Config,
) -> Result[Server, mp.Error]:
    var address = enet.Address(host = uint<-enet.HOST_ANY, port = ushort<-0)
    return listen(address, peer_count, channel_limit, registry, config)


public function localhost_address(port: ushort) -> Result[enet.Address, mp.Error]:
    var remote = enet.Address(host = uint<-enet.HOST_ANY, port = port)
    if enet.address_set_host_ip(ptr_of(remote), "127.0.0.1") != 0:
        return Result[enet.Address, mp.Error].failure(
            error = mp.error(mp.ErrorCode.invalid_argument, "failed to set localhost endpoint")
        )

    return Result[enet.Address, mp.Error].success(value = remote)


public function connect(
    address: enet.Address,
    channel_count: ptr_uint,
    registry: mp.Registry,
    config: mp.Config
) -> Result[Client, mp.Error]:
    let _ = acquire_runtime() else as runtime_error:
        return Result[Client, mp.Error].failure(error = runtime_error)

    var client_address = enet.Address(
        host = uint<-enet.HOST_ANY,
        port = ushort<-enet.PORT_ANY
    )
    let host = enet.host_create(ptr_of(client_address), 1, channel_count, 0, 0) else:
        release_runtime()
        return Result[Client, mp.Error].failure(error = mp.error(
            mp.ErrorCode.unsupported,
            "enet host_create failed for client"
        ))

    var remote_address = address
    let peer = enet.host_connect(host, ptr_of(remote_address), channel_count, 0) else:
        enet.host_destroy(host)
        release_runtime()
        return Result[Client, mp.Error].failure(error = mp.error(mp.ErrorCode.unsupported, "enet host_connect failed"))

    let world = mp.World.create(registry, config, mp.WorldRole.client) else as world_error:
        enet.peer_reset(peer)
        enet.host_destroy(host)
        release_runtime()
        return Result[Client, mp.Error].failure(error = world_error)

    return Result[Client, mp.Error].success(value = Client(
        host = host,
        peer = peer,
        protocol_verified = false,
        connection_id_value = Option[mp.ConnectionId].none,
        world = world,
        session_events = vec.Vec[SessionEventRecord].create(),
        incoming_snapshots = vec.Vec[snapshot_runtime.IncomingSnapshotPacket].create(),
        incoming_rpcs = vec.Vec[rpc_runtime.IncomingRpcPacket].create(),
        unknown_packet_count = 0,
        outbound_snapshot_baseline = empty_snapshot_baseline(),
        inbound_snapshot_baseline = empty_snapshot_baseline()
    ))


public function connect_localhost(
    port: ushort,
    channel_count: ptr_uint,
    registry: mp.Registry,
    config: mp.Config,
) -> Result[Client, mp.Error]:
    let address = localhost_address(port) else as address_error:
        return Result[Client, mp.Error].failure(error = address_error)

    return connect(address, channel_count, registry, config)


function empty_event() -> enet.Event:
    return zero[enet.Event]


function empty_snapshot_baseline() -> snapshot_runtime.BaselineSet:
    return snapshot_runtime.BaselineSet(
        last_applied_tick = 0,
        last_applied_entity_count = 0,
        last_applied_payload_bytes = 0,
        last_applied_payload_hash = 0
    )


function reset_snapshot_baseline(baseline: ref[snapshot_runtime.BaselineSet]) -> void:
    unsafe:
        read(baseline) = empty_snapshot_baseline()


function consume_event_packet(evt: ptr[enet.Event]) -> void:
    unsafe:
        if read(evt).type_ == enet.EventType.ENET_EVENT_TYPE_RECEIVE:
            enet.packet_destroy(read(evt).packet)


function packet_kind(packet: ptr[enet.Packet]) -> Option[mp.PacketKind]:
    unsafe:
        if read(packet).dataLength == 0:
            return Option[mp.PacketKind].none

        let first = read(ptr[ubyte]<-read(packet).data)
        if first == ubyte<-mp.PacketKind.handshake_hello:
            return Option[mp.PacketKind].some(value = mp.PacketKind.handshake_hello)
        if first == ubyte<-mp.PacketKind.handshake_welcome:
            return Option[mp.PacketKind].some(value = mp.PacketKind.handshake_welcome)
        if first == ubyte<-mp.PacketKind.handshake_reject:
            return Option[mp.PacketKind].some(value = mp.PacketKind.handshake_reject)
        if first == ubyte<-mp.PacketKind.snapshot:
            return Option[mp.PacketKind].some(value = mp.PacketKind.snapshot)
        if first == ubyte<-mp.PacketKind.rpc:
            return Option[mp.PacketKind].some(value = mp.PacketKind.rpc)

        return Option[mp.PacketKind].none


function packet_payload_span(packet: ptr[enet.Packet]) -> span[ubyte]:
    unsafe:
        let base = ptr[ubyte]<-read(packet).data
        if read(packet).dataLength <= 1:
            return span[ubyte](data = base, len = 0)

        return span[ubyte](data = base + 1, len = read(packet).dataLength - 1)


function increment_unknown_count(unknown_packet_count: ref[ptr_uint]) -> void:
    unsafe:
        let current = read(unknown_packet_count)
        read(unknown_packet_count) = current + 1


function enqueue_session_event(
    queue: ref[vec.Vec[SessionEventRecord]],
    kind: SessionEvent,
    connection: Option[mp.ConnectionId],
) -> void:
    queue.push(SessionEventRecord(kind = kind, connection = connection))


function dequeue_session_event(queue: ref[vec.Vec[SessionEventRecord]]) -> Option[SessionEventRecord]:
    let item = queue.remove(0) else:
        return Option[SessionEventRecord].none
    return Option[SessionEventRecord].some(value = item)


function typed_rpc_descriptor_matches(left: mp.RpcDescriptor, right: mp.RpcDescriptor) -> bool:
    return left.schema_hash == right.schema_hash and left.name == right.name


function typed_rpc_find_route(routes: span[TypedRpcRoute], descriptor: mp.RpcDescriptor) -> ptr[TypedRpcRoute]?:
    var index: ptr_uint = 0
    while index < routes.len:
        unsafe:
            let route = routes.data + index
            if typed_rpc_descriptor_matches(read(route).descriptor, descriptor):
                return route
        index += 1

    return null


function typed_rpc_dispatch_packet(
    routes: span[TypedRpcRoute],
    context: mp.RpcContext,
    header: mp.RpcPacketHeader,
    payload: span[ubyte],
) -> Result[bool, mp.Error]:
    var matched_index: ptr_uint = 0
    var matched_count: ptr_uint = 0

    var index: ptr_uint = 0
    while index < routes.len:
        unsafe:
            let descriptor = read(routes.data + index).descriptor
            if (
                descriptor.channel == header.channel
                and descriptor.direction == header.direction
                and descriptor.payload_size == payload.len
            ):
                if matched_count == 0:
                    matched_index = index
                matched_count += 1
        index += 1

    if matched_count == 0:
        return Result[bool, mp.Error].failure(
            error = mp.error(mp.ErrorCode.not_registered, "typed rpc route is not registered for incoming packet")
        )

    if matched_count > 1:
        return Result[bool, mp.Error].failure(
            error = mp.error(mp.ErrorCode.invalid_argument, "typed rpc route is ambiguous for incoming packet")
        )

    unsafe:
        let route = routes.data + matched_index
        let handler = read(route).handler
        match handler(context, payload):
            Result.success as payload_value:
                return Result[bool, mp.Error].success(value = payload_value.value)
            Result.failure as payload_error:
                return Result[bool, mp.Error].failure(
                    error = mp.error(payload_error.error.code, payload_error.error.message)
                )


function handle_received_packet(
    world: ref[mp.World],
    incoming_snapshots: ref[vec.Vec[snapshot_runtime.IncomingSnapshotPacket]],
    incoming_rpcs: ref[vec.Vec[rpc_runtime.IncomingRpcPacket]],
    inbound_snapshot_baseline: ref[snapshot_runtime.BaselineSet],
    unknown_packet_count: ref[ptr_uint],
    packet: ptr[enet.Packet],
    channel: uint,
    inferred_direction: mp.RpcDirection,
    sender: Option[mp.ConnectionId],
) -> void:
    let kind = packet_kind(packet) else:
        increment_unknown_count(unknown_packet_count)
        return

    let payload = packet_payload_span(packet)
    match kind:
        mp.PacketKind.snapshot:
            let snapshot_status = snapshot_runtime.enqueue_incoming(
                incoming_snapshots,
                sender,
                channel,
                payload
            )
            match snapshot_status:
                Result.failure:
                    increment_unknown_count(unknown_packet_count)
                Result.success:
                    unsafe:
                        # snapshot header is fixed at 20 bytes (tick u64 + baseline_tick u64 + entity_count u32)
                        let snapshot_body = span[ubyte](
                            data = payload.data + 20,
                            len = payload.len - 20
                        )
                        match world.apply_snapshot_payload(snapshot_body):
                            Result.success:
                                pass
                            Result.failure:
                                pass

                    match snapshot_runtime.apply_from_packet(payload, inbound_snapshot_baseline):
                        Result.success:
                            pass
                        Result.failure:
                            pass
        mp.PacketKind.rpc:
            let rpc_direction = infer_inbound_rpc_direction(payload, inferred_direction) else:
                increment_unknown_count(unknown_packet_count)
                return

            let rpc_status = rpc_runtime.enqueue_incoming(
                incoming_rpcs,
                sender,
                channel,
                rpc_direction,
                payload
            )
            match rpc_status:
                Result.failure:
                    increment_unknown_count(unknown_packet_count)
                Result.success:
                    pass
        mp.PacketKind.handshake_hello:
            increment_unknown_count(unknown_packet_count)
        mp.PacketKind.handshake_welcome:
            increment_unknown_count(unknown_packet_count)
        mp.PacketKind.handshake_reject:
            increment_unknown_count(unknown_packet_count)


function acquire_runtime() -> Result[bool, mp.Error]:
    if runtime_ref_count == 0:
        if enet.initialize() != 0:
            return Result[bool, mp.Error].failure(error = mp.error(mp.ErrorCode.unsupported, "enet initialize failed"))

    runtime_ref_count += 1
    return Result[bool, mp.Error].success(value = true)


function release_runtime() -> void:
    if runtime_ref_count == 0:
        return

    runtime_ref_count -= 1
    if runtime_ref_count == 0:
        enet.deinitialize()


function send_wire_payload(
    peer: ptr[enet.Peer],
    channel: uint,
    transfer_mode: mp.TransferMode,
    kind: mp.PacketKind,
    payload: span[ubyte]
) -> Result[bool, mp.Error]:
    let channel_id = encode_channel_id(channel) else as channel_error:
        return Result[bool, mp.Error].failure(error = channel_error)

    let packet_flags = packet_flags_for_transfer_mode(transfer_mode)
    let packet = create_wire_packet(kind, payload, packet_flags) else as packet_error:
        return Result[bool, mp.Error].failure(error = packet_error)

    let send_status = enet.peer_send(peer, channel_id, packet)
    if send_status < 0:
        enet.packet_destroy(packet)
        return Result[bool, mp.Error].failure(error = mp.error(mp.ErrorCode.unsupported, "enet peer_send failed"))

    return Result[bool, mp.Error].success(value = true)


function broadcast_wire_payload(
    host: ptr[enet.Host],
    channel: uint,
    transfer_mode: mp.TransferMode,
    kind: mp.PacketKind,
    payload: span[ubyte]
) -> Result[bool, mp.Error]:
    let channel_id = encode_channel_id(channel) else as channel_error:
        return Result[bool, mp.Error].failure(error = channel_error)

    let packet_flags = packet_flags_for_transfer_mode(transfer_mode)
    let packet = create_wire_packet(kind, payload, packet_flags) else as packet_error:
        return Result[bool, mp.Error].failure(error = packet_error)

    enet.host_broadcast(host, channel_id, packet)
    return Result[bool, mp.Error].success(value = true)


function create_wire_packet(
    kind: mp.PacketKind,
    payload: span[ubyte],
    packet_flags: enet.PacketFlag
) -> Result[ptr[enet.Packet], mp.Error]:
    var framed = vec.Vec[ubyte].with_capacity(payload.len + 1)
    defer framed.release()

    framed.push(ubyte<-kind)
    framed.append_span(payload)

    let framed_span = framed.as_span()
    let packet = enet.packet_create(unsafe: const_ptr[void]<-framed_span.data, framed_span.len, packet_flags) else:
        return Result[ptr[enet.Packet], mp.Error].failure(error = mp.error(
            mp.ErrorCode.unsupported,
            "enet packet_create failed"
        ))

    return Result[ptr[enet.Packet], mp.Error].success(value = packet)


function packet_flags_for_transfer_mode(transfer_mode: mp.TransferMode) -> enet.PacketFlag:
    match transfer_mode:
        mp.TransferMode.reliable:
            return enet.PacketFlag.ENET_PACKET_FLAG_RELIABLE
        mp.TransferMode.unreliable:
            return enet.PacketFlag<-0
        mp.TransferMode.unreliable_ordered:
            return enet.PacketFlag<-0


function encode_channel_id(channel: uint) -> Result[ubyte, mp.Error]:
    if channel > 255:
        return Result[ubyte, mp.Error].failure(error = mp.error(
            mp.ErrorCode.invalid_argument,
            "channel must be <= 255 for ENet"
        ))

    return Result[ubyte, mp.Error].success(value = ubyte<-channel)


function send_handshake_hello(peer: ptr[enet.Peer], protocol_hash: ulong) -> Result[bool, mp.Error]:
    var encoded = wire.encode_u64_be(protocol_hash)
    return send_wire_payload(peer, 0, mp.TransferMode.reliable, mp.PacketKind.handshake_hello, encoded)


function send_handshake_welcome(
    peer: ptr[enet.Peer],
    protocol_hash: ulong,
    connection: mp.ConnectionId
) -> Result[bool, mp.Error]:
    var payload = vec.Vec[ubyte].with_capacity(16)
    defer payload.release()
    payload.append_array(wire.encode_u64_be(protocol_hash))
    payload.append_array(wire.encode_u64_be(connection))
    return send_wire_payload(peer, 0, mp.TransferMode.reliable, mp.PacketKind.handshake_welcome, payload.as_span())


function send_handshake_reject(
    peer: ptr[enet.Peer],
    protocol_hash: ulong,
    reason: mp.ErrorCode
) -> Result[bool, mp.Error]:
    var payload = vec.Vec[ubyte].with_capacity(12)
    defer payload.release()
    payload.append_array(wire.encode_u64_be(protocol_hash))
    payload.append_array(wire.encode_u32_be(uint<-reason))
    return send_wire_payload(peer, 0, mp.TransferMode.reliable, mp.PacketKind.handshake_reject, payload.as_span())


function decode_handshake_hello(payload: span[ubyte]) -> Result[mp.HandshakeHello, mp.Error]:
    if payload.len < 8:
        return Result[mp.HandshakeHello, mp.Error].failure(error = mp.error(
            mp.ErrorCode.invalid_argument,
            "handshake hello packet is too small"
        ))
    return Result[
        mp.HandshakeHello,
        mp.Error
    ].success(value = mp.HandshakeHello(protocol_hash = wire.decode_u64_be(payload, 0)))


function decode_handshake_welcome(payload: span[ubyte]) -> Result[mp.HandshakeWelcome, mp.Error]:
    if payload.len < 16:
        return Result[mp.HandshakeWelcome, mp.Error].failure(error = mp.error(
            mp.ErrorCode.invalid_argument,
            "handshake welcome packet is too small"
        ))
    return Result[mp.HandshakeWelcome, mp.Error].success(
        value = mp.HandshakeWelcome(
            protocol_hash = wire.decode_u64_be(payload, 0),
            connection = wire.decode_u64_be(payload, 8)
        )
    )


function peer_connection_id(peer: ptr[enet.Peer]) -> mp.ConnectionId:
    unsafe:
        return mp.ConnectionId<-read(peer).incomingPeerID


function is_peer_verified(peer: ptr[enet.Peer]) -> bool:
    unsafe:
        return read(peer).eventData == 1


function mark_peer_verified(peer: ptr[enet.Peer]) -> void:
    unsafe:
        read(peer).eventData = 1


function mark_peer_unverified(peer: ptr[enet.Peer]) -> void:
    unsafe:
        read(peer).eventData = 0


function find_verified_peer(host: ptr[enet.Host], connection: mp.ConnectionId) -> ptr[enet.Peer]?:
    unsafe:
        let peers = read(host).peers
        let peer_count = read(host).peerCount
        var index: ptr_uint = 0
        while index < peer_count:
            let peer = peers + index
            if read(peer).state == enet.PeerState.ENET_PEER_STATE_CONNECTED and is_peer_verified(peer):
                if peer_connection_id(peer) == connection:
                    return peer
            index += 1

    return null


function append_verified_connections(host: ptr[enet.Host], out_connections: ref[vec.Vec[mp.ConnectionId]]) -> void:
    unsafe:
        let peers = read(host).peers
        let peer_count = read(host).peerCount
        var index: ptr_uint = 0
        while index < peer_count:
            let peer = peers + index
            if read(peer).state == enet.PeerState.ENET_PEER_STATE_CONNECTED and is_peer_verified(peer):
                out_connections.push(peer_connection_id(peer))
            index += 1


function append_weighted_verified_connections(
    host: ptr[enet.Host],
    out_connections: ref[vec.Vec[WeightedConnection]]
) -> void:
    unsafe:
        let peers = read(host).peers
        let peer_count = read(host).peerCount
        var index: ptr_uint = 0
        while index < peer_count:
            let peer = peers + index
            if read(peer).state == enet.PeerState.ENET_PEER_STATE_CONNECTED and is_peer_verified(peer):
                out_connections.push(WeightedConnection(connection = peer_connection_id(peer), weight = 1))
            index += 1


function append_rotated_connections(
    source: span[mp.ConnectionId],
    start_index: ptr_uint,
    destination: ref[vec.Vec[mp.ConnectionId]],
) -> void:
    if source.len == 0:
        return

    var index = start_index
    while index < source.len:
        unsafe:
            destination.push(read(source.data + index))
        index += 1

    var prefix_index: ptr_uint = 0
    while prefix_index < start_index:
        unsafe:
            destination.push(read(source.data + prefix_index))
        prefix_index += 1


function send_snapshots_budgeted_impl(
    host: ptr[enet.Host],
    prioritized_connections: span[mp.ConnectionId],
    channel: uint,
    transfer_mode: mp.TransferMode,
    header: mp.SnapshotPacketHeader,
    payload: span[ubyte],
    max_bytes: ptr_uint,
) -> Result[ptr_uint, mp.Error]:
    if max_bytes == 0:
        return Result[ptr_uint, mp.Error].success(value = 0)

    var encoded = snapshot_runtime.build_payload(header, payload)
    defer encoded.release()

    let framed_bytes = encoded.len + 1
    if framed_bytes > max_bytes:
        return Result[ptr_uint, mp.Error].success(value = 0)

    var sent_count: ptr_uint = 0
    var consumed_bytes: ptr_uint = 0
    var index: ptr_uint = 0
    while index < prioritized_connections.len:
        if consumed_bytes + framed_bytes > max_bytes:
            break

        unsafe:
            let connection = read(prioritized_connections.data + index)
            let peer = find_verified_peer(host, connection)
            if peer == null:
                index += 1
                continue

            let sent = send_wire_payload(
                ptr[enet.Peer]<-peer,
                channel,
                transfer_mode,
                mp.PacketKind.snapshot,
                encoded.as_span()
            ) else as send_error:
                return Result[ptr_uint, mp.Error].failure(error = send_error)
            if sent:
                sent_count += 1
                consumed_bytes += framed_bytes

        index += 1

    return Result[ptr_uint, mp.Error].success(value = sent_count)


function send_snapshots_scheduled_fair_impl(
    host: ptr[enet.Host],
    scheduler: ref[mp.TickScheduler],
    ordered_connections: span[mp.ConnectionId],
    channel: uint,
    transfer_mode: mp.TransferMode,
    header: mp.SnapshotPacketHeader,
    payload: span[ubyte],
) -> Result[ptr_uint, mp.Error]:
    var encoded = snapshot_runtime.build_payload(header, payload)
    defer encoded.release()

    let framed_bytes = encoded.len + 1
    var sent_count: ptr_uint = 0
    var index: ptr_uint = 0
    while index < ordered_connections.len:
        unsafe:
            let connection = read(ordered_connections.data + index)
            let peer = find_verified_peer(host, connection)
            if peer == null:
                index += 1
                continue

            match scheduler.reserve(framed_bytes):
                Option.some:
                    pass
                Option.none:
                    break

            let sent = send_wire_payload(
                ptr[enet.Peer]<-peer,
                channel,
                transfer_mode,
                mp.PacketKind.snapshot,
                encoded.as_span()
            ) else as send_error:
                return Result[ptr_uint, mp.Error].failure(error = send_error)
            if sent:
                sent_count += 1

        index += 1

    return Result[ptr_uint, mp.Error].success(value = sent_count)


function send_snapshots_budgeted_weighted_impl(
    host: ptr[enet.Host],
    weighted_connections: span[WeightedConnection],
    channel: uint,
    transfer_mode: mp.TransferMode,
    header: mp.SnapshotPacketHeader,
    payload: span[ubyte],
    max_bytes: ptr_uint,
) -> Result[ptr_uint, mp.Error]:
    if max_bytes == 0:
        return Result[ptr_uint, mp.Error].success(value = 0)

    var encoded = snapshot_runtime.build_payload(header, payload)
    defer encoded.release()

    let framed_bytes = encoded.len + 1
    if framed_bytes > max_bytes:
        return Result[ptr_uint, mp.Error].success(value = 0)

    var remaining_budget = max_bytes
    var sent_count: ptr_uint = 0
    var sent_mask = vec.Vec[bool].with_capacity(weighted_connections.len)
    defer sent_mask.release()
    var init_index: ptr_uint = 0
    while init_index < weighted_connections.len:
        sent_mask.push(false)
        init_index += 1

    while remaining_budget >= framed_bytes:
        var next_index: ptr_uint = 0
        match pick_highest_weight_unsent(weighted_connections, sent_mask.as_span()):
            Option.some as next_payload:
                next_index = next_payload.value
            Option.none:
                break

        let sent_flag_ptr = sent_mask.get(next_index) else:
            return Result[ptr_uint, mp.Error].failure(error = mp.error(
                mp.ErrorCode.unsupported,
                "weighted snapshot sent mask missing slot"
            ))
        unsafe:
            read(sent_flag_ptr) = true

        unsafe:
            let candidate = read(weighted_connections.data + next_index)
            let peer = find_verified_peer(host, candidate.connection)
            if peer == null:
                continue

            let sent = send_wire_payload(
                ptr[enet.Peer]<-peer,
                channel,
                transfer_mode,
                mp.PacketKind.snapshot,
                encoded.as_span()
            ) else as send_error:
                return Result[ptr_uint, mp.Error].failure(error = send_error)
            if sent:
                sent_count += 1
                remaining_budget -= framed_bytes

    return Result[ptr_uint, mp.Error].success(value = sent_count)


function pick_highest_weight_unsent(
    weighted_connections: span[WeightedConnection],
    sent_mask: span[bool],
) -> Option[ptr_uint]:
    if weighted_connections.len == 0:
        return Option[ptr_uint].none

    var best_index: ptr_uint = 0
    var best_weight: uint = 0
    var found = false
    var index: ptr_uint = 0
    while index < weighted_connections.len:
        unsafe:
            if read(sent_mask.data + index):
                index += 1
                continue

            let weight = read(weighted_connections.data + index).weight
            if not found or weight > best_weight:
                found = true
                best_index = index
                best_weight = weight
        index += 1

    if not found:
        return Option[ptr_uint].none
    return Option[ptr_uint].some(value = best_index)


function send_rpcs_scheduled_fair_impl(
    host: ptr[enet.Host],
    scheduler: ref[mp.TickScheduler],
    ordered_connections: span[mp.ConnectionId],
    channel: uint,
    transfer_mode: mp.TransferMode,
    direction: mp.RpcDirection,
    payload: span[ubyte],
) -> Result[ptr_uint, mp.Error]:
    let header = mp.RpcPacketHeader(channel = channel, direction = direction, payload_size = payload.len)
    var encoded = rpc_runtime.build_payload(header, payload)
    defer encoded.release()

    let framed_bytes = encoded.len + 1
    var sent_count: ptr_uint = 0
    var index: ptr_uint = 0
    while index < ordered_connections.len:
        unsafe:
            let connection = read(ordered_connections.data + index)
            let peer = find_verified_peer(host, connection)
            if peer == null:
                index += 1
                continue

            match scheduler.reserve(framed_bytes):
                Option.some:
                    pass
                Option.none:
                    break

            let sent = send_wire_payload(
                ptr[enet.Peer]<-peer,
                channel,
                transfer_mode,
                mp.PacketKind.rpc,
                encoded.as_span()
            ) else as send_error:
                return Result[ptr_uint, mp.Error].failure(error = send_error)
            if sent:
                sent_count += 1

        index += 1

    return Result[ptr_uint, mp.Error].success(value = sent_count)


function validate_client_outbound_direction(direction: mp.RpcDirection) -> Result[bool, mp.Error]:
    if direction != mp.RpcDirection.client_to_server:
        return Result[bool, mp.Error].failure(
            error = mp.error(
                mp.ErrorCode.invalid_argument,
                "client send_rpc requires direction = client_to_server"
            )
        )

    return Result[bool, mp.Error].success(value = true)


function validate_server_outbound_direction(direction: mp.RpcDirection) -> Result[bool, mp.Error]:
    if direction == mp.RpcDirection.client_to_server:
        return Result[bool, mp.Error].failure(
            error = mp.error(
                mp.ErrorCode.invalid_argument,
                "server rpc send requires a server_to_* direction"
            )
        )

    return Result[bool, mp.Error].success(value = true)


function infer_inbound_rpc_direction(
    payload: span[ubyte],
    inferred_direction: mp.RpcDirection,
) -> Option[mp.RpcDirection]:
    if inferred_direction == mp.RpcDirection.client_to_server:
        return Option[mp.RpcDirection].some(value = mp.RpcDirection.client_to_server)

    let header = rpc_runtime.decode_header(payload) else:
        return Option[mp.RpcDirection].none
    if header.direction == mp.RpcDirection.client_to_server:
        return Option[mp.RpcDirection].none

    return Option[mp.RpcDirection].some(value = header.direction)


function snapshot_wire_bytes(header: mp.SnapshotPacketHeader, payload: span[ubyte]) -> ptr_uint:
    var encoded = snapshot_runtime.build_payload(header, payload)
    defer encoded.release()
    return encoded.len + 1


function rpc_wire_bytes(channel: uint, direction: mp.RpcDirection, payload: span[ubyte]) -> ptr_uint:
    let header = mp.RpcPacketHeader(channel = channel, direction = direction, payload_size = payload.len)
    var encoded = rpc_runtime.build_payload(header, payload)
    defer encoded.release()
    return encoded.len + 1

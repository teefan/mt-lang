# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdMultiplayerEnetTest < Minitest::Test
  def test_snapshot_and_rpc_codecs_roundtrip_and_validate_headers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.multiplayer.protocol as protocol
import std.multiplayer.snapshot as snapshot
import std.multiplayer.rpc as rpc
import std.multiplayer as mp
import std.multiplayer.enet as mp_enet
import std.enet as enet
import std.vec as vec

@[mp.rpc(direction = mp.RpcDirection.client_to_server, mode = mp.TransferMode.reliable, channel = 9, require_owner = false)]
function typed_route_a(context: mp.RpcContext, value: short) -> void:
    return

@[mp.rpc(direction = mp.RpcDirection.client_to_server, mode = mp.TransferMode.reliable, channel = 9, require_owner = false)]
function typed_route_b(context: mp.RpcContext, value: short) -> void:
    return

function typed_dispatch_stub(context: mp.RpcContext, payload: span[ubyte]) -> Result[bool, rpc.DispatchError]:
    return Result[bool, rpc.DispatchError].success(value = true)

function expect_snapshot_roundtrip() -> int:
    let header = protocol.SnapshotPacketHeader(tick = 42, baseline_tick = 40, entity_count = 3)
    var encoded = snapshot.encode_header(header)
    let decoded = snapshot.decode_header(encoded) else:
        return 1

    if decoded.tick != 42:
        return 2
    if decoded.baseline_tick != 40:
        return 3
    if decoded.entity_count != 3:
        return 4

    var queue = vec.Vec[snapshot.IncomingSnapshotPacket].create()
    defer snapshot.release_queue(ref_of(queue))

    var baselines = snapshot.BaselineSet(
        last_applied_tick = 0,
        last_applied_entity_count = 0,
        last_applied_payload_bytes = 0,
        last_applied_payload_hash = 0,
    )

    var body = array[ubyte, 3](9, 8, 7)
    var framed = snapshot.build_payload(header, body)
    defer framed.release()

    let queued = snapshot.parse_and_enqueue(ref_of(queue), ref_of(baselines), Option[protocol.ConnectionId].none, 5, framed.as_span())
    if not queued:
        return 5

    let dequeued_snapshot = snapshot.dequeue_incoming(ref_of(queue)) else:
        return 7
    var packet = dequeued_snapshot

    if packet.header.tick != 42:
        packet.release()
        return 8
    if packet.channel != 5:
        packet.release()
        return 9

    let payload = packet.payload.as_span()
    if payload.len != 3:
        packet.release()
        return 10
    if payload[0] != 9 or payload[1] != 8 or payload[2] != 7:
        packet.release()
        return 11

    packet.release()
    return 0

function expect_rpc_roundtrip() -> int:
    let header = protocol.RpcPacketHeader(channel = 7, direction = protocol.RpcDirection.client_to_server, payload_size = 2)
    var encoded = rpc.encode_header(header)
    let decoded = rpc.decode_header(encoded) else:
        return 20

    if decoded.channel != 7:
        return 21
    if decoded.direction != protocol.RpcDirection.client_to_server:
        return 22
    if decoded.payload_size != 2:
        return 23

    var queue = vec.Vec[rpc.IncomingRpcPacket].create()
    defer rpc.release_queue(ref_of(queue))

    var body = array[ubyte, 2](1, 2)
    var framed = rpc.build_payload(header, body)
    defer framed.release()

    let queued = rpc.parse_and_enqueue(
        ref_of(queue),
        Option[protocol.ConnectionId].none,
        7,
        protocol.RpcDirection.client_to_server,
        77,
        framed.as_span(),
    )

    if not queued:
        return 24

    let dequeued_rpc = rpc.dequeue_incoming(ref_of(queue)) else:
        return 25
    var packet = dequeued_rpc
    if packet.header.channel != 7:
        packet.release()
        return 26
    if packet.header.direction != protocol.RpcDirection.client_to_server:
        packet.release()
        return 27
    if packet.context.tick != 77:
        packet.release()
        return 28

    let payload = packet.payload.as_span()
    if payload.len != 2 or payload[0] != 1 or payload[1] != 2:
        packet.release()
        return 29

    packet.release()
    return 0

function expect_rpc_invalid_direction_is_rejected() -> int:
    var queue = vec.Vec[rpc.IncomingRpcPacket].create()
    defer rpc.release_queue(ref_of(queue))

    var invalid_payload = array[ubyte, 11](
        0,
        0,
        0,
        7,
        9,
        0,
        0,
        0,
        2,
        1,
        2,
    )

    let parsed = rpc.parse_incoming(invalid_payload) else:
        return 0

    let accepted = rpc.enqueue_parsed(
        ref_of(queue),
        Option[protocol.ConnectionId].none,
        7,
        protocol.RpcDirection.client_to_server,
        0,
        parsed,
    )
    if accepted:
        return 40

    return 0


function expect_typed_rpc_wire_identity_collision_is_rejected() -> int:
    var table = mp.TypedRpcDispatchTable.create()
    defer table.release()

    let descriptor_a = mp.rpc_descriptor(callable_of(typed_route_a))
    let descriptor_b = mp.rpc_descriptor(callable_of(typed_route_b))

    let added_a = table.register_route(descriptor_a, typed_dispatch_stub) else:
        return 68
    if not added_a:
        return 69

    match table.register_route(descriptor_b, typed_dispatch_stub):
        Result.success as _:
            return 70
        Result.failure as payload:
            if payload.error.code != protocol.ErrorCode.already_registered:
                return 71

    return 0


function expect_loopback_send_receive() -> int:
    var registry = mp.Registry.create()
    registry.freeze()
    defer registry.release()

    var address = enet.Address(host = uint<-enet.HOST_ANY, port = 0)
    let server_result = mp_enet.listen(address, 2, 4, registry, mp.default_config())
    match server_result:
        Result.failure as payload:
            return 50
        Result.success as payload:
            var server = payload.value
            defer server.release()

            let server_host = server.host else:
                return 51

            unsafe:
                let port = int<-read(server_host).address.port
                if port <= 0:
                    return 52

                var remote = enet.Address(host = uint<-enet.HOST_ANY, port = ushort<-port)
                if enet.address_set_host_ip(ptr_of(remote), "127.0.0.1") != 0:
                    return 53
                let client_result = mp_enet.connect(remote, 4, registry, mp.default_config())
                match client_result:
                    Result.failure as client_payload:
                        return 54
                    Result.success as client_payload:
                        var client = client_payload.value
                        defer client.release()

                        var handshake_rounds: ptr_uint = 0
                        while handshake_rounds < 64:
                            let _ = server.pump(1) else:
                                return 55
                            let _ = client.pump(1) else:
                                return 56
                            if client.peer != null and client.protocol_ready():
                                break
                            handshake_rounds += 1

                        if client.peer == null or not client.protocol_ready():
                            return 57

                        if server.current_tick() != 0:
                            return 200
                        if client.current_tick() != 0:
                            return 201

                        server.set_current_tick(77)
                        if server.current_tick() != 77:
                            return 202

                        let snapshot_header = protocol.SnapshotPacketHeader(tick = 91, baseline_tick = 90, entity_count = 1)
                        var snapshot_payload = array[ubyte, 3](5, 4, 3)
                        var snapshot_sent = false
                        match client.send_snapshot(1, protocol.TransferMode.reliable, snapshot_header, snapshot_payload):
                            Result.success as send_payload:
                                if not send_payload.value:
                                    return 58
                                snapshot_sent = true
                            Result.failure as _:
                                let _ = server.pump(1) else:
                                    return 59
                                let _ = client.pump(1) else:
                                    return 60
                                match client.send_snapshot(1, protocol.TransferMode.reliable, snapshot_header, snapshot_payload):
                                    Result.success as retry_payload:
                                        if not retry_payload.value:
                                            return 61
                                        snapshot_sent = true
                                    Result.failure as _:
                                        return 62

                        if not snapshot_sent:
                            return 63
                        client.flush()

                        match client.send_rpc(1, protocol.TransferMode.reliable, protocol.RpcDirection.server_to_owner, snapshot_payload):
                            Result.success as _:
                                return 130
                            Result.failure as send_error:
                                if send_error.error.code != protocol.ErrorCode.invalid_argument:
                                    return 131

                        let rpc_send = client.send_rpc(1, protocol.TransferMode.reliable, protocol.RpcDirection.client_to_server, snapshot_payload) else:
                            return 64
                        if not rpc_send:
                            return 65
                        client.flush()

                        var transfer_rounds: ptr_uint = 0
                        while transfer_rounds < 40:
                            let _ = server.pump(1) else:
                                return 66
                            let _ = client.pump(0) else:
                                return 67
                            if server.pending_snapshot_count() > 0 and server.pending_rpc_count() > 0:
                                break
                            transfer_rounds += 1

                        if server.pending_snapshot_count() != 1:
                            return 68
                        if server.pending_rpc_count() != 1:
                            return 69
                        if server.pending_protocol_anomaly_count() != 0:
                            return 70

                        let snapshot_packet = server.pop_snapshot() else:
                            return 71
                        var received_snapshot = snapshot_packet
                        defer received_snapshot.release()
                        if received_snapshot.header.tick != 91:
                            return 72
                        if received_snapshot.header.baseline_tick != 90:
                            return 73
                        if received_snapshot.channel != 1:
                            return 74

                        let received_snapshot_payload = received_snapshot.payload.as_span()
                        if received_snapshot_payload.len != 3:
                            return 75
                        if received_snapshot_payload[0] != 5 or received_snapshot_payload[1] != 4 or received_snapshot_payload[2] != 3:
                            return 76

                        let rpc_packet = server.pop_rpc() else:
                            return 77
                        var received_rpc = rpc_packet
                        defer received_rpc.release()
                        if received_rpc.header.channel != 1:
                            return 78
                        if received_rpc.header.direction != protocol.RpcDirection.client_to_server:
                            return 79
                        if received_rpc.context.tick != 77:
                            return 210

                        let received_rpc_payload = received_rpc.payload.as_span()
                        if received_rpc_payload.len != 3:
                            return 80
                        if received_rpc_payload[0] != 5 or received_rpc_payload[1] != 4 or received_rpc_payload[2] != 3:
                            return 81

                        let verified_connection = server.first_verified_connection() else:
                            return 134

                        match server.connection_stats_for(verified_connection):
                            Option.some as stats_payload:
                                let _stats_check = stats_payload.value
                            Option.none:
                                return 220

                        match server.connection_stats_for(999999):
                            Option.some as _:
                                return 221
                            Option.none:
                                pass

                        var server_stats = server.connection_stats()
                        defer server_stats.release()
                        if server_stats.len() != 1:
                            return 222

                        let _client_stats = client.connection_stats() else:
                            return 223

                        let _server_frame = server.frame(1) else:
                            return 224

                        let client_frame = client.frame(1) else:
                            return 226
                        if client_frame.snapshots_pending != 0:
                            return 227

                        let server_snapshot_header = protocol.SnapshotPacketHeader(tick = 101, baseline_tick = 100, entity_count = 2)
                        let server_snapshot_send = server.broadcast_snapshot(2, protocol.TransferMode.reliable, server_snapshot_header, snapshot_payload) else:
                            return 82
                        if not server_snapshot_send:
                            return 83

                        let server_rpc_send = server.broadcast_rpc(2, protocol.TransferMode.reliable, protocol.RpcDirection.server_to_owner, snapshot_payload) else:
                            return 84
                        if not server_rpc_send:
                            return 85

                        match server.broadcast_rpc(2, protocol.TransferMode.reliable, protocol.RpcDirection.client_to_server, snapshot_payload):
                            Result.success as _:
                                return 132
                            Result.failure as send_error:
                                if send_error.error.code != protocol.ErrorCode.invalid_argument:
                                    return 133

                        let targeted_snapshot_header = protocol.SnapshotPacketHeader(tick = 102, baseline_tick = 101, entity_count = 3)
                        let targeted_snapshot_send = server.send_snapshot_to(verified_connection, 3, protocol.TransferMode.reliable, targeted_snapshot_header, snapshot_payload) else:
                            return 158
                        if not targeted_snapshot_send:
                            return 159

                        var prioritized_connections = vec.Vec[protocol.ConnectionId].create()
                        defer prioritized_connections.release()
                        prioritized_connections.push(verified_connection)
                        prioritized_connections.push(protocol.ConnectionId<-999999)
                        let budgeted_header = protocol.SnapshotPacketHeader(tick = 103, baseline_tick = 102, entity_count = 4)
                        let budgeted_sent = server.send_snapshots_budgeted(
                            prioritized_connections.as_span(),
                            1,
                            protocol.TransferMode.reliable,
                            budgeted_header,
                            snapshot_payload,
                            24,
                        ) else:
                            return 167
                        if budgeted_sent != 1:
                            return 168

                        let budgeted_skipped = server.send_snapshots_budgeted(
                            prioritized_connections.as_span(),
                            1,
                            protocol.TransferMode.reliable,
                            budgeted_header,
                            snapshot_payload,
                            0,
                        ) else:
                            return 169
                        if budgeted_skipped != 0:
                            return 170

                        let budgeted_broadcast_header = protocol.SnapshotPacketHeader(tick = 104, baseline_tick = 103, entity_count = 5)
                        let budgeted_broadcast_sent = server.broadcast_snapshot_budgeted(
                            0,
                            protocol.TransferMode.reliable,
                            budgeted_broadcast_header,
                            snapshot_payload,
                            24,
                        ) else:
                            return 171
                        if budgeted_broadcast_sent != 1:
                            return 172

                        let targeted_rpc_send = server.send_rpc_to(verified_connection, 3, protocol.TransferMode.reliable, protocol.RpcDirection.server_to_connection, snapshot_payload) else:
                            return 135
                        if not targeted_rpc_send:
                            return 136

                        let observers_rpc_send = server.broadcast_rpc(0, protocol.TransferMode.reliable, protocol.RpcDirection.server_to_observers, snapshot_payload) else:
                            return 144
                        if not observers_rpc_send:
                            return 145

                        let all_rpc_send = server.broadcast_rpc(1, protocol.TransferMode.reliable, protocol.RpcDirection.server_to_all, snapshot_payload) else:
                            return 146
                        if not all_rpc_send:
                            return 147

                        match server.send_rpc_to(999999, 3, protocol.TransferMode.reliable, protocol.RpcDirection.server_to_connection, snapshot_payload):
                            Result.success as _:
                                return 137
                            Result.failure as send_error:
                                if send_error.error.code != protocol.ErrorCode.not_found:
                                    return 138

                        match server.send_snapshot_to(999999, 3, protocol.TransferMode.reliable, targeted_snapshot_header, snapshot_payload):
                            Result.success as _:
                                return 160
                            Result.failure as send_error:
                                if send_error.error.code != protocol.ErrorCode.not_found:
                                    return 161

                        let scheduled_snapshot_header = protocol.SnapshotPacketHeader(tick = 105, baseline_tick = 104, entity_count = 6)
                        let scheduled_snapshot_bytes = server.estimate_snapshot_wire_bytes(scheduled_snapshot_header, snapshot_payload)
                        let scheduled_rpc_bytes = server.estimate_rpc_wire_bytes(1, protocol.RpcDirection.server_to_connection, snapshot_payload)
                        var tick_scheduler = mp.create_tick_scheduler(scheduled_snapshot_bytes + scheduled_rpc_bytes)
                        tick_scheduler.begin_tick(105)

                        let scheduled_snapshot_sent = server.send_snapshot_to_scheduled(
                            ref_of(tick_scheduler),
                            verified_connection,
                            1,
                            protocol.TransferMode.reliable,
                            scheduled_snapshot_header,
                            snapshot_payload,
                        ) else:
                            return 183
                        if not scheduled_snapshot_sent:
                            return 184

                        let scheduled_rpc_sent = server.send_rpc_to_scheduled(
                            ref_of(tick_scheduler),
                            verified_connection,
                            1,
                            protocol.TransferMode.reliable,
                            protocol.RpcDirection.server_to_connection,
                            snapshot_payload,
                        ) else:
                            return 185
                        if not scheduled_rpc_sent:
                            return 186

                        let scheduled_over_budget = server.broadcast_snapshot_scheduled(
                            ref_of(tick_scheduler),
                            0,
                            protocol.TransferMode.reliable,
                            scheduled_snapshot_header,
                            snapshot_payload,
                        ) else:
                            return 187
                        if scheduled_over_budget:
                            return 188

                        if tick_scheduler.consumed_bytes() != scheduled_snapshot_bytes + scheduled_rpc_bytes:
                            return 189

                        server.flush()

                        var broadcast_rounds: ptr_uint = 0
                        while broadcast_rounds < 40:
                            let _ = server.pump(0) else:
                                return 86
                            let _ = client.pump(1) else:
                                return 87
                            if client.pending_snapshot_count() > 3 and client.pending_rpc_count() > 3:
                                break
                            broadcast_rounds += 1

                        if client.pending_snapshot_count() != 5:
                            return 88
                        if client.pending_rpc_count() != 5:
                            return 89
                        if client.pending_protocol_anomaly_count() != 0:
                            return 90

                        let client_snapshot_packet = client.pop_snapshot() else:
                            return 91
                        var client_snapshot = client_snapshot_packet
                        defer client_snapshot.release()
                        if client_snapshot.header.tick != 101:
                            return 92
                        if client_snapshot.channel != 2:
                            return 93

                        let client_snapshot_payload = client_snapshot.payload.as_span()
                        if client_snapshot_payload.len != 3:
                            return 94
                        if client_snapshot_payload[0] != 5 or client_snapshot_payload[1] != 4 or client_snapshot_payload[2] != 3:
                            return 95

                        let client_targeted_snapshot_packet = client.pop_snapshot() else:
                            return 162
                        var client_targeted_snapshot = client_targeted_snapshot_packet
                        defer client_targeted_snapshot.release()
                        if client_targeted_snapshot.header.tick != 102:
                            return 163
                        if client_targeted_snapshot.channel != 3:
                            return 164

                        let client_targeted_snapshot_payload = client_targeted_snapshot.payload.as_span()
                        if client_targeted_snapshot_payload.len != 3:
                            return 165
                        if client_targeted_snapshot_payload[0] != 5 or client_targeted_snapshot_payload[1] != 4 or client_targeted_snapshot_payload[2] != 3:
                            return 166

                        let client_budgeted_snapshot_packet = client.pop_snapshot() else:
                            return 173
                        var client_budgeted_snapshot = client_budgeted_snapshot_packet
                        defer client_budgeted_snapshot.release()
                        if client_budgeted_snapshot.header.tick != 103:
                            return 174
                        if client_budgeted_snapshot.channel != 1:
                            return 175

                        let client_budgeted_snapshot_payload = client_budgeted_snapshot.payload.as_span()
                        if client_budgeted_snapshot_payload.len != 3:
                            return 176
                        if client_budgeted_snapshot_payload[0] != 5 or client_budgeted_snapshot_payload[1] != 4 or client_budgeted_snapshot_payload[2] != 3:
                            return 177

                        let client_budgeted_broadcast_snapshot_packet = client.pop_snapshot() else:
                            return 178
                        var client_budgeted_broadcast_snapshot = client_budgeted_broadcast_snapshot_packet
                        defer client_budgeted_broadcast_snapshot.release()
                        if client_budgeted_broadcast_snapshot.header.tick != 104:
                            return 179
                        if client_budgeted_broadcast_snapshot.channel != 0:
                            return 180

                        let client_budgeted_broadcast_snapshot_payload = client_budgeted_broadcast_snapshot.payload.as_span()
                        if client_budgeted_broadcast_snapshot_payload.len != 3:
                            return 181
                        if client_budgeted_broadcast_snapshot_payload[0] != 5 or client_budgeted_broadcast_snapshot_payload[1] != 4 or client_budgeted_broadcast_snapshot_payload[2] != 3:
                            return 182

                        let client_scheduled_snapshot_packet = client.pop_snapshot() else:
                            return 190
                        var client_scheduled_snapshot = client_scheduled_snapshot_packet
                        defer client_scheduled_snapshot.release()
                        if client_scheduled_snapshot.header.tick != 105:
                            return 191
                        if client_scheduled_snapshot.channel != 1:
                            return 192

                        let client_scheduled_snapshot_payload = client_scheduled_snapshot.payload.as_span()
                        if client_scheduled_snapshot_payload.len != 3:
                            return 193
                        if client_scheduled_snapshot_payload[0] != 5 or client_scheduled_snapshot_payload[1] != 4 or client_scheduled_snapshot_payload[2] != 3:
                            return 194

                        let client_rpc_packet = client.pop_rpc() else:
                            return 96
                        var client_rpc = client_rpc_packet
                        defer client_rpc.release()
                        if client_rpc.header.channel != 2:
                            return 97
                        if client_rpc.header.direction != protocol.RpcDirection.server_to_owner:
                            return 98

                        let client_rpc_payload = client_rpc.payload.as_span()
                        if client_rpc_payload.len != 3:
                            return 99
                        if client_rpc_payload[0] != 5 or client_rpc_payload[1] != 4 or client_rpc_payload[2] != 3:
                            return 100

                        let client_targeted_rpc_packet = client.pop_rpc() else:
                            return 139
                        var client_targeted_rpc = client_targeted_rpc_packet
                        defer client_targeted_rpc.release()
                        if client_targeted_rpc.header.channel != 3:
                            return 140
                        if client_targeted_rpc.header.direction != protocol.RpcDirection.server_to_connection:
                            return 141

                        let client_targeted_rpc_payload = client_targeted_rpc.payload.as_span()
                        if client_targeted_rpc_payload.len != 3:
                            return 142
                        if client_targeted_rpc_payload[0] != 5 or client_targeted_rpc_payload[1] != 4 or client_targeted_rpc_payload[2] != 3:
                            return 143

                        let client_observers_rpc_packet = client.pop_rpc() else:
                            return 148
                        var client_observers_rpc = client_observers_rpc_packet
                        defer client_observers_rpc.release()
                        if client_observers_rpc.header.channel != 0:
                            return 149
                        if client_observers_rpc.header.direction != protocol.RpcDirection.server_to_observers:
                            return 150

                        let client_observers_rpc_payload = client_observers_rpc.payload.as_span()
                        if client_observers_rpc_payload.len != 3:
                            return 151
                        if client_observers_rpc_payload[0] != 5 or client_observers_rpc_payload[1] != 4 or client_observers_rpc_payload[2] != 3:
                            return 152

                        let client_all_rpc_packet = client.pop_rpc() else:
                            return 153
                        var client_all_rpc = client_all_rpc_packet
                        defer client_all_rpc.release()
                        if client_all_rpc.header.channel != 1:
                            return 154
                        if client_all_rpc.header.direction != protocol.RpcDirection.server_to_all:
                            return 155

                        let client_all_rpc_payload = client_all_rpc.payload.as_span()
                        if client_all_rpc_payload.len != 3:
                            return 156
                        if client_all_rpc_payload[0] != 5 or client_all_rpc_payload[1] != 4 or client_all_rpc_payload[2] != 3:
                            return 157

                        let client_scheduled_rpc_packet = client.pop_rpc() else:
                            return 195
                        var client_scheduled_rpc = client_scheduled_rpc_packet
                        defer client_scheduled_rpc.release()
                        if client_scheduled_rpc.header.channel != 1:
                            return 196
                        if client_scheduled_rpc.header.direction != protocol.RpcDirection.server_to_connection:
                            return 197

                        let client_scheduled_rpc_payload = client_scheduled_rpc.payload.as_span()
                        if client_scheduled_rpc_payload.len != 3:
                            return 198
                        if client_scheduled_rpc_payload[0] != 5 or client_scheduled_rpc_payload[1] != 4 or client_scheduled_rpc_payload[2] != 3:
                            return 199

                        let client_peer = client.peer else:
                            return 101

                        var malformed_rpc_packet = array[ubyte, 10](
                            ubyte<-protocol.PacketKind.rpc,
                            0,
                            0,
                            0,
                            1,
                            9,
                            0,
                            0,
                            0,
                            0,
                        )
                        let enet_packet = enet.packet_create(
                            unsafe: const_ptr[void]<-ptr_of(malformed_rpc_packet),
                            10,
                            enet.PacketFlag.ENET_PACKET_FLAG_RELIABLE,
                        ) else:
                            return 102

                        if enet.peer_send(client_peer, 1, enet_packet) < 0:
                            enet.packet_destroy(enet_packet)
                            return 103
                        client.flush()

                        var malformed_rounds: ptr_uint = 0
                        while malformed_rounds < 40:
                            let _ = server.pump(1) else:
                                return 104
                            let _ = client.pump(0) else:
                                return 105
                            if server.pending_protocol_anomaly_count() > 0:
                                break
                            malformed_rounds += 1

                        if server.pending_protocol_anomaly_count() != 1:
                            return 106

                        return 0


@[mp.replicated(authority = mp.Authority.server)]
struct MismatchState:
    @[mp.sync(mode = mp.TransferMode.unreliable_ordered, channel = 0, rate_hz = 20, target = mp.SyncTarget.observers)]
    value: int


function expect_protocol_mismatch_rejected() -> int:
    var server_registry = mp.Registry.create()
    server_registry.freeze()
    defer server_registry.release()

    var client_registry = mp.Registry.create()
    let _ = client_registry.add_state(mp.state_descriptor[MismatchState]()) else:
        return 110
    client_registry.freeze()
    defer client_registry.release()

    if server_registry.protocol_hash() == client_registry.protocol_hash():
        return 111

    var address = enet.Address(host = uint<-enet.HOST_ANY, port = 0)
    let server_result = mp_enet.listen(address, 2, 4, server_registry, mp.default_config())
    match server_result:
        Result.failure as _:
            return 112
        Result.success as payload:
            var server = payload.value
            defer server.release()

            let server_host = server.host else:
                return 113

            unsafe:
                let port = int<-read(server_host).address.port
                if port <= 0:
                    return 114

                var remote = enet.Address(host = uint<-enet.HOST_ANY, port = ushort<-port)
                if enet.address_set_host_ip(ptr_of(remote), "127.0.0.1") != 0:
                    return 115

                let client_result = mp_enet.connect(remote, 4, client_registry, mp.default_config())
                match client_result:
                    Result.failure as _:
                        return 116
                    Result.success as client_payload:
                        var client = client_payload.value
                        defer client.release()

                        var rounds: ptr_uint = 0
                        while rounds < 80:
                            let _ = server.pump(1) else:
                                return 117
                            let _ = client.pump(1) else:
                                return 118
                            if client.peer == null:
                                break
                            rounds += 1

                        if client.protocol_ready():
                            return 119
                        if client.peer != null:
                            return 120
                        if client.pending_protocol_anomaly_count() == 0:
                            return 121

                        return 0

function main() -> int:
    let snapshot_status = expect_snapshot_roundtrip()
    if snapshot_status != 0:
        return snapshot_status

    let rpc_status = expect_rpc_roundtrip()
    if rpc_status != 0:
        return rpc_status

    let invalid_rpc_status = expect_rpc_invalid_direction_is_rejected()
    if invalid_rpc_status != 0:
        return invalid_rpc_status

    let typed_collision_status = expect_typed_rpc_wire_identity_collision_is_rejected()
    if typed_collision_status != 0:
        return typed_collision_status

    let loopback_status = expect_loopback_send_receive()
    if loopback_status != 0:
        return loopback_status

    return expect_protocol_mismatch_rejected()

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-multiplayer-enet") do |dir|
      source_path = File.join(dir, "program.mt")
      File.write(source_path, source)
      return MilkTea::Run.run(source_path, cc: compiler)
    end
  end

  def compiler_available?(compiler)
    return File.executable?(compiler) if compiler.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, compiler)
      File.file?(candidate) && File.executable?(candidate)
    end
  end
end

# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdMultiplayerEnetFriendlyApiTest < Minitest::Test
  def test_enet_friendly_disconnect_and_typed_dispatch_helpers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.multiplayer as mp
import std.multiplayer.protocol as protocol
import std.multiplayer.enet as mp_enet
import std.multiplayer.rpc as rpc

const NET_CHANNEL: uint = 1

var routed_value: ubyte = 0

@[mp.rpc(direction = mp.RpcDirection.server_to_connection, mode = mp.TransferMode.reliable, channel = NET_CHANNEL, require_owner = false)]
function receive_marker(context: mp.RpcContext, marker: ubyte) -> void:
    routed_value = marker


function dispatch_receive_marker(context: mp.RpcContext, payload: span[ubyte]) -> Result[bool, rpc.DispatchError]:
    let dispatched = rpc.dispatch_typed_payload(callable_of(receive_marker), context, payload) else as dispatch_error:
        return Result[bool, rpc.DispatchError].failure(
            error = rpc.DispatchError(code = dispatch_error.code, message = dispatch_error.message),
        )

    return Result[bool, rpc.DispatchError].success(value = dispatched)

function build_registry() -> mp.Registry:
    var registry = mp.Registry.create()
    registry.freeze()
    return registry

function main() -> int:
    var registry = build_registry()
    defer registry.release()

    let server_result = mp_enet.listen_localhost(8, 4, registry, mp.default_config()) else:
        return 1
    var server = server_result
    defer server.release()

    let port = server.listening_port() else:
        return 2

    if port == ushort<-0:
        return 3

    let client0_result = mp_enet.connect_localhost(port, 4, registry, mp.default_config()) else:
        return 5
    let client1_result = mp_enet.connect_localhost(port, 4, registry, mp.default_config()) else:
        return 6

    var client0 = client0_result
    var client1 = client1_result
    defer client0.release()
    defer client1.release()

    var rounds: ptr_uint = 0
    while rounds < 240:
        let _ = server.pump(1) else:
            return 7
        let _ = client0.pump(1) else:
            return 8
        let _ = client1.pump(1) else:
            return 9

        if server.verified_peer_count() == 2 and client0.protocol_ready() and client1.protocol_ready():
            break
        rounds += 1

    if server.verified_peer_count() != 2:
        return 10

    let conn0 = client0.connection_id() else:
        return 11

    var payload = array[ubyte, 1](7)
    let sent = server.send_rpc_to(
        conn0,
        NET_CHANNEL,
        protocol.TransferMode.reliable,
        protocol.RpcDirection.server_to_connection,
        payload,
    ) else:
        return 12
    if not sent:
        return 13

    server.flush()
    client0.flush()
    client1.flush()

    var pump_round: ptr_uint = 0
    while pump_round < 32:
        let _ = server.pump(0) else:
            return 14
        let _ = client0.pump(1) else:
            return 15
        let _ = client1.pump(0) else:
            return 16
        pump_round += 1

    let rpc_descriptor = mp.rpc_descriptor(callable_of(receive_marker))
    var typed_routes = mp_enet.TypedRpcDispatchTable.create()
    defer typed_routes.release()
    let route_added = typed_routes.register_route(rpc_descriptor, dispatch_receive_marker) else:
        return 17
    if not route_added:
        return 18

    let processed_rpcs = client0.process_incoming_rpcs_typed(ref_of(typed_routes)) else:
        return 19
    if processed_rpcs != 1:
        return 20
    if routed_value != 7:
        return 21

    var world_payload = server.world.encode_snapshot_payload() else:
        return 30
    defer world_payload.release()

    let snapshot_header = protocol.SnapshotPacketHeader(tick = 200, baseline_tick = 0, entity_count = 0)
    let snapshot_sent = server.broadcast_snapshot(0, protocol.TransferMode.reliable, snapshot_header, world_payload.as_span()) else:
        return 31
    if not snapshot_sent:
        return 32

    server.flush()
    client0.flush()

    var snapshot_rounds: ptr_uint = 0
    while snapshot_rounds < 32:
        let _ = server.pump(0) else:
            return 33
        let _ = client0.pump(1) else:
            return 34
        if client0.pending_snapshot_count() > 0:
            break
        snapshot_rounds += 1

    let processed_snapshots = client0.process_incoming_snapshots() else:
        return 35
    if processed_snapshots != 1:
        return 36
    if client0.pending_snapshot_count() != 0:
        return 37

    let missing_disconnect = server.disconnect_connection(ulong<-999999, 0) else:
        return 22
    if missing_disconnect:
        return 23

    let disconnected = server.disconnect_connection(conn0, 0) else:
        return 24
    if not disconnected:
        return 25

    let all_disconnected = server.disconnect_all(0) else:
        return 26
    if all_disconnected == 0:
        return 27

    let client_disconnect = client1.disconnect(0) else:
        return 28
    if not client_disconnect:
        return 29

    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-multiplayer-enet-friendly-api") do |dir|
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

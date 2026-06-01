# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdMultiplayerEnetWorldDispatchSignatureTest < Minitest::Test
  def test_world_signature_dispatch_skips_unchanged_snapshots
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.multiplayer as mp
import std.multiplayer.protocol as protocol
import std.multiplayer.enet as mp_enet
import std.enet as enet

const NET_CHANNEL_SNAPSHOT: uint = 0
const NET_CHANNEL_RPC: uint = 1

@[mp.replicated(authority = mp.Authority.server)]
struct PlayerState:
    @[mp.sync(mode = mp.TransferMode.unreliable_ordered, channel = 0, rate_hz = 20, target = mp.SyncTarget.observers)]
    x: float
    @[mp.sync(mode = mp.TransferMode.unreliable_ordered, channel = 0, rate_hz = 20, target = mp.SyncTarget.observers)]
    hp: int

function build_registry() -> mp.Registry:
    var registry = mp.Registry.create()
    let _ = registry.add_state(mp.state_descriptor[PlayerState]()) else:
        fatal(c"failed to add state descriptor")
    registry.freeze()
    return registry

function main() -> int:
    var registry = build_registry()
    defer registry.release()

    var bind_address = enet.Address(host = uint<-enet.HOST_ANY, port = 0)
    let server_result = mp_enet.listen(bind_address, 4, 4, registry, mp.default_config()) else:
        return 1
    var server = server_result
    defer server.release()

    let server_host = server.host else:
        return 2

    unsafe:
        let port = int<-read(server_host).address.port
        if port <= 0:
            return 3

        var remote = enet.Address(host = uint<-enet.HOST_ANY, port = ushort<-port)
        if enet.address_set_host_ip(ptr_of(remote), "127.0.0.1") != 0:
            return 4

        let client_result = mp_enet.connect(remote, 4, registry, mp.default_config()) else:
            return 5
        var client = client_result
        defer client.release()

        var rounds: ptr_uint = 0
        while rounds < 240:
            let _ = server.pump(1) else:
                return 6
            let _ = client.pump(1) else:
                return 7
            if server.verified_peer_count() == 1 and client.protocol_ready():
                break
            rounds += 1

        if server.verified_peer_count() != 1:
            return 8

        let entity = server.world.spawn[PlayerState](PlayerState(x = 1.0, hp = 100), Option[mp.ConnectionId].none) else:
            return 9

        var rpc_payload = array[ubyte, 2](8, 9)
        let plan = mp.create_tick_budget_plan(2048, 70)

        var initial_world_payload = server.world.encode_snapshot_payload() else:
            return 10
        defer initial_world_payload.release()

        let report1 = server.dispatch_world_tick_fair(
            1,
            plan,
            NET_CHANNEL_SNAPSHOT,
            protocol.TransferMode.reliable,
            NET_CHANNEL_RPC,
            protocol.TransferMode.reliable,
            protocol.RpcDirection.server_to_all,
            rpc_payload,
        ) else:
            return 11

        if report1.snapshots_sent == 0:
            return 12

        let connection = client.connection_id() else:
            return 29

        let outbound_after_first = server.outbound_snapshot_baseline_state(connection) else:
            return 30
        if outbound_after_first.last_applied_payload_bytes != initial_world_payload.as_span().len:
            return 13

        server.flush()
        client.flush()

        var pump_rounds_1: ptr_uint = 0
        while pump_rounds_1 < 64:
            let _ = server.pump(0) else:
                return 14
            let _ = client.pump(1) else:
                return 15
            pump_rounds_1 += 1

        if client.pending_snapshot_count() == 0:
            return 16
        while true:
            match client.pop_snapshot():
                Option.some as payload:
                    var packet = payload.value
                    packet.release()
                Option.none:
                    break

        let report2 = server.dispatch_world_tick_fair(
            2,
            plan,
            NET_CHANNEL_SNAPSHOT,
            protocol.TransferMode.reliable,
            NET_CHANNEL_RPC,
            protocol.TransferMode.reliable,
            protocol.RpcDirection.server_to_all,
            rpc_payload,
        ) else:
            return 17

        if report2.snapshots_sent != 0:
            return 18

        server.flush()
        client.flush()

        var pump_rounds_2: ptr_uint = 0
        while pump_rounds_2 < 64:
            let _ = server.pump(0) else:
                return 19
            let _ = client.pump(1) else:
                return 20
            pump_rounds_2 += 1

        if client.pending_snapshot_count() != 0:
            return 21

        let state_ptr = server.world.state_ptr[PlayerState](entity) else:
            return 22
        unsafe:
            read(state_ptr).hp = 80

        var changed_world_payload = server.world.encode_snapshot_payload() else:
            return 23
        defer changed_world_payload.release()

        let report3 = server.dispatch_world_tick_fair(
            3,
            plan,
            NET_CHANNEL_SNAPSHOT,
            protocol.TransferMode.reliable,
            NET_CHANNEL_RPC,
            protocol.TransferMode.reliable,
            protocol.RpcDirection.server_to_all,
            rpc_payload,
        ) else:
            return 24

        if report3.snapshots_sent == 0:
            return 25

        let outbound = server.outbound_snapshot_baseline_state(connection) else:
            return 31
        if outbound.last_applied_tick != 3:
            return 26
        if outbound.last_applied_entity_count != 1:
            return 27
        if outbound.last_applied_payload_bytes != changed_world_payload.as_span().len:
            return 28

        return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-multiplayer-enet-world-dispatch-signature") do |dir|
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

  def test_world_signature_fair_dispatch_delivers_unchanged_state_to_skipped_peers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.multiplayer as mp
import std.multiplayer.protocol as protocol
import std.multiplayer.enet as mp_enet
import std.enet as enet

const NET_CHANNEL_SNAPSHOT: uint = 0
const NET_CHANNEL_RPC: uint = 1

@[mp.replicated(authority = mp.Authority.server)]
struct PlayerState:
    @[mp.sync(mode = mp.TransferMode.unreliable_ordered, channel = 0, rate_hz = 20, target = mp.SyncTarget.observers)]
    x: float

function build_registry() -> mp.Registry:
    var registry = mp.Registry.create()
    let _ = registry.add_state(mp.state_descriptor[PlayerState]()) else:
        fatal(c"failed to add state descriptor")
    registry.freeze()
    return registry

function drain_snapshot_count(client: ref[mp_enet.Client]) -> ptr_uint:
    var count: ptr_uint = 0
    while true:
        match client.pop_snapshot():
            Option.some as payload:
                var packet = payload.value
                packet.release()
                count += 1
            Option.none:
                break
    return count

function main() -> int:
    var registry = build_registry()
    defer registry.release()

    var bind_address = enet.Address(host = uint<-enet.HOST_ANY, port = 0)
    let server_result = mp_enet.listen(bind_address, 4, 4, registry, mp.default_config()) else:
        return 1
    var server = server_result
    defer server.release()

    let server_host = server.host else:
        return 2

    unsafe:
        let port = int<-read(server_host).address.port
        if port <= 0:
            return 3

        var remote = enet.Address(host = uint<-enet.HOST_ANY, port = ushort<-port)
        if enet.address_set_host_ip(ptr_of(remote), "127.0.0.1") != 0:
            return 4

        let client_a_result = mp_enet.connect(remote, 4, registry, mp.default_config()) else:
            return 5
        let client_b_result = mp_enet.connect(remote, 4, registry, mp.default_config()) else:
            return 6

        var client_a = client_a_result
        var client_b = client_b_result
        defer client_a.release()
        defer client_b.release()

        var rounds: ptr_uint = 0
        while rounds < 240:
            let _ = server.pump(1) else:
                return 7
            let _ = client_a.pump(1) else:
                return 8
            let _ = client_b.pump(1) else:
                return 9
            if server.verified_peer_count() == 2 and client_a.protocol_ready() and client_b.protocol_ready():
                break
            rounds += 1

        if server.verified_peer_count() != 2:
            return 10

        let conn_a = client_a.connection_id() else:
            return 11
        let conn_b = client_b.connection_id() else:
            return 12

        let _ = server.world.spawn[PlayerState](PlayerState(x = 1.0), Option[mp.ConnectionId].none) else:
            return 13

        let plan = mp.create_tick_budget_plan(64, 0)
        var rpc_payload = array[ubyte, 0]()

        let report1 = server.dispatch_world_tick_fair(
            1,
            plan,
            NET_CHANNEL_SNAPSHOT,
            protocol.TransferMode.reliable,
            NET_CHANNEL_RPC,
            protocol.TransferMode.reliable,
            protocol.RpcDirection.server_to_all,
            rpc_payload,
        ) else:
            return 14
        if report1.snapshots_sent != 1:
            return 15

        server.flush()
        var pump_rounds_1: ptr_uint = 0
        while pump_rounds_1 < 64:
            let _ = server.pump(0) else:
                return 16
            let _ = client_a.pump(1) else:
                return 17
            let _ = client_b.pump(1) else:
                return 18
            pump_rounds_1 += 1

        let first_a = drain_snapshot_count(ref_of(client_a))
        let first_b = drain_snapshot_count(ref_of(client_b))
        if first_a + first_b != 1:
            return 19

        let sent_a_first = first_a == 1
        var skipped_connection = conn_a
        if sent_a_first:
            skipped_connection = conn_b

        let skipped_before = server.outbound_world_signature_baseline_state(skipped_connection) else:
            return 20
        if skipped_before.last_applied_tick != 0:
            return 21

        let report2 = server.dispatch_world_tick_fair(
            2,
            plan,
            NET_CHANNEL_SNAPSHOT,
            protocol.TransferMode.reliable,
            NET_CHANNEL_RPC,
            protocol.TransferMode.reliable,
            protocol.RpcDirection.server_to_all,
            rpc_payload,
        ) else:
            return 22
        if report2.snapshots_sent != 1:
            return 23

        server.flush()
        var pump_rounds_2: ptr_uint = 0
        while pump_rounds_2 < 64:
            let _ = server.pump(0) else:
                return 24
            let _ = client_a.pump(1) else:
                return 25
            let _ = client_b.pump(1) else:
                return 26
            pump_rounds_2 += 1

        let second_a = drain_snapshot_count(ref_of(client_a))
        let second_b = drain_snapshot_count(ref_of(client_b))
        if second_a + second_b != 1:
            return 27
        if sent_a_first and second_b != 1:
            return 28
        if not sent_a_first and second_a != 1:
            return 29

        let skipped_after = server.outbound_world_signature_baseline_state(skipped_connection) else:
            return 30
        if skipped_after.last_applied_tick != 2:
            return 31

        return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end
end

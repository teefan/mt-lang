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

        var snapshot_payload = array[ubyte, 4](1, 2, 3, 4)
        var rpc_payload = array[ubyte, 2](8, 9)
        let plan = mp.create_tick_budget_plan(2048, 70)

        let report1 = server.dispatch_world_tick_fair(
            1,
            plan,
            NET_CHANNEL_SNAPSHOT,
            protocol.TransferMode.reliable,
            snapshot_payload,
            NET_CHANNEL_RPC,
            protocol.TransferMode.reliable,
            protocol.RpcDirection.server_to_all,
            rpc_payload,
        ) else:
            return 10

        if report1.snapshots_sent == 0:
            return 11

        server.flush()
        client.flush()

        var pump_rounds_1: ptr_uint = 0
        while pump_rounds_1 < 64:
            let _ = server.pump(0) else:
                return 12
            let _ = client.pump(1) else:
                return 13
            pump_rounds_1 += 1

        if client.pending_snapshot_count() == 0:
            return 14
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
            snapshot_payload,
            NET_CHANNEL_RPC,
            protocol.TransferMode.reliable,
            protocol.RpcDirection.server_to_all,
            rpc_payload,
        ) else:
            return 15

        if report2.snapshots_sent != 0:
            return 16

        server.flush()
        client.flush()

        var pump_rounds_2: ptr_uint = 0
        while pump_rounds_2 < 64:
            let _ = server.pump(0) else:
                return 17
            let _ = client.pump(1) else:
                return 18
            pump_rounds_2 += 1

        if client.pending_snapshot_count() != 0:
            return 19

        let state_ptr = server.world.state_ptr[PlayerState](entity) else:
            return 20
        unsafe:
            read(state_ptr).hp = 80

        let report3 = server.dispatch_world_tick_fair(
            3,
            plan,
            NET_CHANNEL_SNAPSHOT,
            protocol.TransferMode.reliable,
            snapshot_payload,
            NET_CHANNEL_RPC,
            protocol.TransferMode.reliable,
            protocol.RpcDirection.server_to_all,
            rpc_payload,
        ) else:
            return 21

        if report3.snapshots_sent == 0:
            return 22

        let outbound = server.outbound_snapshot_baseline_state()
        if outbound.last_applied_tick != 3:
            return 23
        if outbound.last_applied_entity_count != 1:
            return 24

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
end

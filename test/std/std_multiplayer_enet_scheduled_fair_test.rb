# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdMultiplayerEnetScheduledFairTest < Minitest::Test
  def test_scheduled_fair_snapshot_and_rpc_rotation
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.multiplayer as mp
import std.multiplayer.protocol as protocol
import std.multiplayer.enet as mp_enet
import std.enet as enet


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


function drain_rpc_count(client: ref[mp_enet.Client]) -> ptr_uint:
    var count: ptr_uint = 0
    while true:
        match client.pop_rpc():
            Option.some as payload:
                var packet = payload.value
                packet.release()
                count += 1
            Option.none:
                break
    return count


function main() -> int:
    var registry = mp.Registry.create()
    registry.freeze()
    defer registry.release()

    var bind_address = enet.Address(host = uint<-enet.HOST_ANY, port = 0)
    let server_result = mp_enet.listen(bind_address, 6, 4, registry, mp.default_config()) else:
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
        while rounds < 120:
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

        var payload = array[ubyte, 3](4, 5, 6)

        var tick: ulong = 501
        while tick <= 502:
            let snapshot_header = protocol.SnapshotPacketHeader(tick = tick, baseline_tick = tick - 1, entity_count = 1)
            let snapshot_bytes = server.estimate_snapshot_wire_bytes(snapshot_header, payload)
            let rpc_bytes = server.estimate_rpc_wire_bytes(1, protocol.RpcDirection.server_to_observers, payload)
            var scheduler = mp.create_tick_scheduler(snapshot_bytes + rpc_bytes)
            scheduler.begin_tick(tick)

            let sent_snapshots = server.broadcast_snapshot_scheduled_fair(
                ref_of(scheduler),
                0,
                protocol.TransferMode.reliable,
                snapshot_header,
                payload,
            ) else:
                return 11
            if sent_snapshots != 1:
                return 12

            let sent_rpcs = server.broadcast_rpc_scheduled_fair(
                ref_of(scheduler),
                1,
                protocol.TransferMode.reliable,
                protocol.RpcDirection.server_to_observers,
                payload,
            ) else:
                return 13
            if sent_rpcs != 1:
                return 14

            let blocked = server.broadcast_snapshot_scheduled_fair(
                ref_of(scheduler),
                0,
                protocol.TransferMode.reliable,
                snapshot_header,
                payload,
            ) else:
                return 15
            if blocked != 0:
                return 16

            server.flush()

            var delivery_rounds: ptr_uint = 0
            while delivery_rounds < 50:
                let _ = server.pump(0) else:
                    return 17
                let _ = client_a.pump(1) else:
                    return 18
                let _ = client_b.pump(1) else:
                    return 19
                delivery_rounds += 1

            tick += 1

        let snapshots_a = drain_snapshot_count(ref_of(client_a))
        let snapshots_b = drain_snapshot_count(ref_of(client_b))
        let rpcs_a = drain_rpc_count(ref_of(client_a))
        let rpcs_b = drain_rpc_count(ref_of(client_b))

        let total_snapshots = snapshots_a + snapshots_b
        let total_rpcs = rpcs_a + rpcs_b
        if total_snapshots != 2:
            return 20
        if total_rpcs != 2:
            return 21

    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-multiplayer-enet-scheduled-fair") do |dir|
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

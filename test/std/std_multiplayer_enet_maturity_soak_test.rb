# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdMultiplayerEnetMaturitySoakTest < Minitest::Test
  def test_weighted_and_tick_dispatch_under_jittered_pump
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.multiplayer as mp
import std.multiplayer.protocol as protocol
import std.multiplayer.enet as mp_enet
import std.enet as enet
import std.vec as vec


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
    let server_result = mp_enet.listen(bind_address, 8, 4, registry, mp.default_config()) else:
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
        let client_c_result = mp_enet.connect(remote, 4, registry, mp.default_config()) else:
            return 7

        var client_a = client_a_result
        var client_b = client_b_result
        var client_c = client_c_result
        defer client_a.release()
        defer client_b.release()
        defer client_c.release()

        var rounds: ptr_uint = 0
        while rounds < 150:
            let _ = server.pump(1) else:
                return 8
            let _ = client_a.pump(1) else:
                return 9
            let _ = client_b.pump(1) else:
                return 10
            let _ = client_c.pump(1) else:
                return 11
            if server.verified_peer_count() == 3 and client_a.protocol_ready() and client_b.protocol_ready() and client_c.protocol_ready():
                break
            rounds += 1

        let conn_a = client_a.connection_id() else:
            return 12
        let conn_b = client_b.connection_id() else:
            return 13
        let conn_c = client_c.connection_id() else:
            return 14

        var weighted = vec.Vec[mp.WeightedConnection].create()
        defer weighted.release()
        weighted.push(mp.WeightedConnection(connection = conn_a, weight = 8))
        weighted.push(mp.WeightedConnection(connection = conn_b, weight = 4))
        weighted.push(mp.WeightedConnection(connection = conn_c, weight = 1))

        var payload = array[ubyte, 3](4, 2, 0)
        var total_weighted_sent: ptr_uint = 0
        var total_snapshots_sent: ptr_uint = 0
        var total_rpcs_sent: ptr_uint = 0

        var tick: ulong = 1100
        while tick < 1112:
            let header = protocol.SnapshotPacketHeader(tick = tick, baseline_tick = tick - 1, entity_count = 1)

            if tick % 3 == 0:
                let one_packet_budget = server.estimate_snapshot_wire_bytes(header, payload)
                let weighted_sent = server.send_snapshots_budgeted_weighted(
                    weighted.as_span(),
                    0,
                    protocol.TransferMode.reliable,
                    header,
                    payload,
                    one_packet_budget,
                ) else:
                    return 15
                total_weighted_sent += weighted_sent
            else:
                let snapshot_bytes = server.estimate_snapshot_wire_bytes(header, payload)
                let rpc_bytes = server.estimate_rpc_wire_bytes(1, protocol.RpcDirection.server_to_observers, payload)
                let plan = mp.create_tick_budget_plan((snapshot_bytes + rpc_bytes) * 2, 55)
                let report = server.dispatch_tick_fair(
                    tick,
                    plan,
                    0,
                    protocol.TransferMode.reliable,
                    header,
                    payload,
                    1,
                    protocol.TransferMode.reliable,
                    protocol.RpcDirection.server_to_observers,
                    payload,
                ) else:
                    return 16
                total_snapshots_sent += report.snapshots_sent
                total_rpcs_sent += report.rpcs_sent

            server.flush()

            var jitter_rounds: ptr_uint = 0
            while jitter_rounds < 20:
                let server_timeout: uint = uint<-(jitter_rounds % 3)
                let client_timeout: uint = uint<-((jitter_rounds + 1) % 3)
                let _ = server.pump(server_timeout) else:
                    return 17
                let _ = client_a.pump(client_timeout) else:
                    return 18
                let _ = client_b.pump(client_timeout) else:
                    return 19
                let _ = client_c.pump(client_timeout) else:
                    return 20
                jitter_rounds += 1

            tick += 1

        let received_snapshots = drain_snapshot_count(ref_of(client_a)) + drain_snapshot_count(ref_of(client_b)) + drain_snapshot_count(ref_of(client_c))
        let received_rpcs = drain_rpc_count(ref_of(client_a)) + drain_rpc_count(ref_of(client_b)) + drain_rpc_count(ref_of(client_c))

        if total_weighted_sent == 0:
            return 21
        if total_snapshots_sent == 0:
            return 22
        if total_rpcs_sent == 0:
            return 23
        if received_snapshots != total_weighted_sent + total_snapshots_sent:
            return 24
        if received_rpcs != total_rpcs_sent:
            return 25

    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-multiplayer-enet-maturity-soak") do |dir|
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

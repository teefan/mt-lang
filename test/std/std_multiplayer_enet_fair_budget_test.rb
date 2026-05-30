# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdMultiplayerEnetFairBudgetTest < Minitest::Test
  def test_fair_budgeted_snapshot_rotation_across_clients
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
        while rounds < 120:
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

        if server.verified_peer_count() != 3:
            return 12

        var payload = array[ubyte, 3](9, 8, 7)

        var tick: ulong = 301
        while tick <= 303:
            let header = protocol.SnapshotPacketHeader(tick = tick, baseline_tick = tick - 1, entity_count = 1)
            let one_packet_budget = server.estimate_snapshot_wire_bytes(header, payload)
            let sent = server.broadcast_snapshot_budgeted_fair(
                0,
                protocol.TransferMode.reliable,
                header,
                payload,
                one_packet_budget,
            ) else:
                return 13
            if sent != 1:
                return 14

            server.flush()

            var delivery_rounds: ptr_uint = 0
            while delivery_rounds < 40:
                let _ = server.pump(0) else:
                    return 15
                let _ = client_a.pump(1) else:
                    return 16
                let _ = client_b.pump(1) else:
                    return 17
                let _ = client_c.pump(1) else:
                    return 18
                delivery_rounds += 1

            tick += 1

        let snapshots_a = drain_snapshot_count(ref_of(client_a))
        let snapshots_b = drain_snapshot_count(ref_of(client_b))
        let snapshots_c = drain_snapshot_count(ref_of(client_c))

        if snapshots_a != 1:
            return 19
        if snapshots_b != 1:
            return 20
        if snapshots_c != 1:
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
    Dir.mktmpdir("milk-tea-std-multiplayer-enet-fair-budget") do |dir|
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

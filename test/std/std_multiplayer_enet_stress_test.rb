# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdMultiplayerEnetStressTest < Minitest::Test
  def test_multi_client_tick_budget_scheduler_throughput_and_drop
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.multiplayer as mp
import std.multiplayer.protocol as protocol
import std.multiplayer.enet as mp_enet
import std.enet as enet


function increment(target: ref[ptr_uint]) -> void:
    unsafe:
        read(target) = read(target) + 1
    return


function drain_client(client: ref[mp_enet.Client], snapshot_total: ref[ptr_uint], rpc_total: ref[ptr_uint]) -> void:
    while true:
        match client.pop_snapshot():
            Option.some as payload:
                var snapshot = payload.value
                snapshot.release()
                increment(snapshot_total)
            Option.none:
                break

    while true:
        match client.pop_rpc():
            Option.some as payload:
                var rpc = payload.value
                rpc.release()
                increment(rpc_total)
            Option.none:
                break

    return


function main() -> int:
    var registry = mp.Registry.create()
    registry.freeze()
    defer registry.release()

    var address = enet.Address(host = uint<-enet.HOST_ANY, port = 0)
    let server_result = mp_enet.listen(address, 8, 4, registry, mp.default_config()) else:
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

        var handshake_rounds: ptr_uint = 0
        while handshake_rounds < 120:
            let _ = server.pump(1) else:
                return 8
            let _ = client_a.pump(1) else:
                return 9
            let _ = client_b.pump(1) else:
                return 10
            let _ = client_c.pump(1) else:
                return 11

            if client_a.protocol_ready() and client_b.protocol_ready() and client_c.protocol_ready() and server.verified_peer_count() == 3:
                break
            handshake_rounds += 1

        if not client_a.protocol_ready() or not client_b.protocol_ready() or not client_c.protocol_ready():
            return 12
        if server.verified_peer_count() != 3:
            return 13

        let connection_a = client_a.connection_id() else:
            return 14
        let connection_b = client_b.connection_id() else:
            return 15
        let connection_c = client_c.connection_id() else:
            return 16

        var payload = array[ubyte, 8](1, 2, 3, 4, 5, 6, 7, 8)
        var total_sent_snapshots: ptr_uint = 0
        var total_sent_rpcs: ptr_uint = 0
        var budget_blocked: ptr_uint = 0
        var tick: protocol.Tick = 1

        while tick <= 8:
            let header = protocol.SnapshotPacketHeader(tick = tick, baseline_tick = tick - 1, entity_count = 3)
            let snapshot_bytes = server.estimate_snapshot_wire_bytes(header, payload)
            let rpc_bytes = server.estimate_rpc_wire_bytes(1, protocol.RpcDirection.server_to_connection, payload)
            let tick_budget = snapshot_bytes * 2 + rpc_bytes * 1

            var scheduler = mp.create_tick_scheduler(tick_budget)
            scheduler.begin_tick(tick)

            let sent_snapshot_a = server.send_snapshot_to_scheduled(ref_of(scheduler), connection_a, 1, protocol.TransferMode.reliable, header, payload) else:
                return 20
            if sent_snapshot_a:
                increment(ref_of(total_sent_snapshots))
            else:
                increment(ref_of(budget_blocked))

            let sent_snapshot_b = server.send_snapshot_to_scheduled(ref_of(scheduler), connection_b, 1, protocol.TransferMode.reliable, header, payload) else:
                return 21
            if sent_snapshot_b:
                increment(ref_of(total_sent_snapshots))
            else:
                increment(ref_of(budget_blocked))

            let sent_snapshot_c = server.send_snapshot_to_scheduled(ref_of(scheduler), connection_c, 1, protocol.TransferMode.reliable, header, payload) else:
                return 22
            if sent_snapshot_c:
                increment(ref_of(total_sent_snapshots))
            else:
                increment(ref_of(budget_blocked))

            let sent_rpc_a = server.send_rpc_to_scheduled(ref_of(scheduler), connection_a, 1, protocol.TransferMode.reliable, protocol.RpcDirection.server_to_connection, payload) else:
                return 23
            if sent_rpc_a:
                increment(ref_of(total_sent_rpcs))
            else:
                increment(ref_of(budget_blocked))

            let sent_rpc_b = server.send_rpc_to_scheduled(ref_of(scheduler), connection_b, 1, protocol.TransferMode.reliable, protocol.RpcDirection.server_to_connection, payload) else:
                return 24
            if sent_rpc_b:
                increment(ref_of(total_sent_rpcs))
            else:
                increment(ref_of(budget_blocked))

            let sent_rpc_c = server.send_rpc_to_scheduled(ref_of(scheduler), connection_c, 1, protocol.TransferMode.reliable, protocol.RpcDirection.server_to_connection, payload) else:
                return 25
            if sent_rpc_c:
                increment(ref_of(total_sent_rpcs))
            else:
                increment(ref_of(budget_blocked))

            if scheduler.consumed_bytes() > tick_budget:
                return 26

            server.flush()

            var delivery_rounds: ptr_uint = 0
            while delivery_rounds < 30:
                let _ = server.pump(0) else:
                    return 27
                let _ = client_a.pump(1) else:
                    return 28
                let _ = client_b.pump(1) else:
                    return 29
                let _ = client_c.pump(1) else:
                    return 30
                delivery_rounds += 1

            tick += 1

        if budget_blocked == 0:
            return 31
        if total_sent_snapshots == 0 or total_sent_rpcs == 0:
            return 32

        var received_snapshots: ptr_uint = 0
        var received_rpcs: ptr_uint = 0
        drain_client(ref_of(client_a), ref_of(received_snapshots), ref_of(received_rpcs))
        drain_client(ref_of(client_b), ref_of(received_snapshots), ref_of(received_rpcs))
        drain_client(ref_of(client_c), ref_of(received_snapshots), ref_of(received_rpcs))

        if received_snapshots != total_sent_snapshots:
            return 33
        if received_rpcs != total_sent_rpcs:
            return 34

    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-multiplayer-enet-stress") do |dir|
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

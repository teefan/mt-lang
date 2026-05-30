# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdMultiplayerEnetSnapshotBaselineTest < Minitest::Test
  def test_enet_tracks_snapshot_baselines_for_send_and_receive
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.multiplayer as mp
import std.multiplayer.protocol as protocol
import std.multiplayer.enet as mp_enet
import std.enet as enet

const NET_CHANNEL: uint = 1

function build_registry() -> mp.Registry:
    var registry = mp.Registry.create()
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

        let connection = client.connection_id() else:
            return 9

        var payload_client = array[ubyte, 3](1, 2, 3)
        let header_client = protocol.SnapshotPacketHeader(
            tick = 21,
            baseline_tick = 20,
            entity_count = 3,
        )

        let sent_client = client.send_snapshot(
            NET_CHANNEL,
            protocol.TransferMode.reliable,
            header_client,
            payload_client,
        ) else:
            return 10
        if not sent_client:
            return 11

        client.flush()
        server.flush()

        var pump_client_rounds: ptr_uint = 0
        while pump_client_rounds < 64:
            let _ = server.pump(1) else:
                return 12
            let _ = client.pump(0) else:
                return 13
            if server.pending_snapshot_count() > 0:
                break
            pump_client_rounds += 1

        if server.pending_snapshot_count() == 0:
            return 14

        let server_inbound = server.inbound_snapshot_baseline_state()
        let client_outbound = client.outbound_snapshot_baseline_state()
        if server_inbound.last_applied_tick != 21:
            return 15
        if server_inbound.last_applied_entity_count != 3:
            return 30
        if server_inbound.last_applied_payload_bytes != 3:
            return 16
        if client_outbound.last_applied_tick != 21:
            return 17
        if client_outbound.last_applied_entity_count != 3:
            return 31
        if client_outbound.last_applied_payload_hash != server_inbound.last_applied_payload_hash:
            return 18

        let incoming_server = server.pop_snapshot() else:
            return 19
        var snapshot_server = incoming_server
        snapshot_server.release()

        var payload_server = array[ubyte, 2](9, 9)
        let header_server = protocol.SnapshotPacketHeader(
            tick = 34,
            baseline_tick = 33,
            entity_count = 2,
        )

        let sent_server = server.send_snapshot_to(
            connection,
            NET_CHANNEL,
            protocol.TransferMode.reliable,
            header_server,
            payload_server,
        ) else:
            return 20
        if not sent_server:
            return 21

        server.flush()
        client.flush()

        var pump_server_rounds: ptr_uint = 0
        while pump_server_rounds < 64:
            let _ = server.pump(0) else:
                return 22
            let _ = client.pump(1) else:
                return 23
            if client.pending_snapshot_count() > 0:
                break
            pump_server_rounds += 1

        if client.pending_snapshot_count() == 0:
            return 24

        let server_outbound = server.outbound_snapshot_baseline_state()
        let client_inbound = client.inbound_snapshot_baseline_state()
        if server_outbound.last_applied_tick != 34:
            return 25
        if server_outbound.last_applied_entity_count != 2:
            return 32
        if server_outbound.last_applied_payload_bytes != 2:
            return 26
        if client_inbound.last_applied_tick != 34:
            return 27
        if client_inbound.last_applied_entity_count != 2:
            return 33
        if client_inbound.last_applied_payload_hash != server_outbound.last_applied_payload_hash:
            return 28

        let incoming_client = client.pop_snapshot() else:
            return 29
        var snapshot_client = incoming_client
        snapshot_client.release()

        return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-multiplayer-enet-snapshot-baseline") do |dir|
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

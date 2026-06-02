# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdMultiplayerEnetSessionBindingsTest < Minitest::Test
  def test_sync_slot_roster_with_server_claims_and_releases_on_lifecycle
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.multiplayer as mp
import std.multiplayer.enet as mp_enet
import std.multiplayer.session as session_runtime
import std.enet as enet

function main() -> int:
    var server_registry = mp.Registry.create()
    server_registry.freeze()
    defer server_registry.release()

    var client_registry = mp.Registry.create()
    client_registry.freeze()
    defer client_registry.release()

    var address = enet.Address(host = uint<-enet.HOST_ANY, port = 0)
    let server_result = mp_enet.listen(address, 2, 4, server_registry, mp.default_config())
    match server_result:
        Result.failure:
            return 50
        Result.success as server_payload:
            var server = server_payload.value
            defer server.release()

            let server_host = server.host else:
                return 51

            var server_roster = session_runtime.SlotRoster.create(4)
            defer server_roster.release()

            if server_roster.occupied_count() != 0:
                return 60

            let initial_sync = mp_enet.sync_slot_roster_with_server(
                ref_of(server),
                ref_of(server_roster),
            )
            match initial_sync:
                Result.success as applied_payload:
                    if applied_payload.value != 0:
                        return 61
                Result.failure:
                    return 62

            if server_roster.occupied_count() != 0:
                return 63

            unsafe:
                let port = int<-read(server_host).address.port
                if port <= 0:
                    return 52

                var remote = enet.Address(host = uint<-enet.HOST_ANY, port = ushort<-port)
                if enet.address_set_host_ip(ptr_of(remote), "127.0.0.1") != 0:
                    return 53

                let client_result = mp_enet.connect(remote, 4, client_registry, mp.default_config())
                match client_result:
                    Result.failure:
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
                            if client.peer != null and client.protocol_ready() and server.connected_peer_count() > 0:
                                break
                            handshake_rounds += 1

                        if client.peer == null or not client.protocol_ready():
                            return 57
                        if server.connected_peer_count() == 0:
                            return 58

                        let claim_sync = mp_enet.sync_slot_roster_with_server(
                            ref_of(server),
                            ref_of(server_roster),
                        )
                        match claim_sync:
                            Result.success as applied_payload:
                                if applied_payload.value != 1:
                                    return 71
                            Result.failure:
                                return 72

                        if server_roster.occupied_count() != 1:
                            return 73

                        client.disconnect(0)
                        client.flush()

                        var teardown_rounds: ptr_uint = 0
                        while teardown_rounds < 64:
                            let _ = server.pump(1) else:
                                return 91
                            let _ = client.pump(1) else:
                                return 92
                            if server.connected_peer_count() == 0:
                                break
                            teardown_rounds += 1

                        if server.connected_peer_count() != 0:
                            return 93

                        let release_sync = mp_enet.sync_slot_roster_with_server(
                            ref_of(server),
                            ref_of(server_roster),
                        )
                        match release_sync:
                            Result.success as applied_payload:
                                if applied_payload.value != 1:
                                    return 94
                            Result.failure:
                                return 95

                        if server_roster.occupied_count() != 0:
                            return 96
    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  def test_sync_slot_roster_with_client_releases_on_disconnect
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.multiplayer as mp
import std.multiplayer.enet as mp_enet
import std.multiplayer.session as session_runtime
import std.enet as enet

function main() -> int:
    var server_registry = mp.Registry.create()
    server_registry.freeze()
    defer server_registry.release()

    var client_registry = mp.Registry.create()
    client_registry.freeze()
    defer client_registry.release()

    var address = enet.Address(host = uint<-enet.HOST_ANY, port = 0)
    let server_result = mp_enet.listen(address, 2, 4, server_registry, mp.default_config())
    match server_result:
        Result.failure:
            return 50
        Result.success as server_payload:
            var server = server_payload.value
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

                let client_result = mp_enet.connect(remote, 4, client_registry, mp.default_config())
                match client_result:
                    Result.failure:
                        return 54
                    Result.success as client_payload:
                        var client = client_payload.value
                        defer client.release()

                        var client_roster = session_runtime.SlotRoster.create(4)
                        defer client_roster.release()

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

                        match client.connection_id():
                            Option.some as connection_payload:
                                match client_roster.claim_slot(connection_payload.value, 0):
                                    Result.success as claim_payload:
                                        if not claim_payload.value:
                                            return 64
                                    Result.failure:
                                        return 65
                            Option.none:
                                return 66

                        if client_roster.occupied_count() != 1:
                            return 67

                        let initial_client_sync = mp_enet.sync_slot_roster_with_client(
                            ref_of(client),
                            ref_of(client_roster),
                        )
                        match initial_client_sync:
                            Result.success as applied_payload:
                                if applied_payload.value != 0:
                                    return 68
                            Result.failure:
                                return 69

                        if client_roster.occupied_count() != 1:
                            return 70

                        client.disconnect(0)
                        client.flush()

                        var teardown_rounds: ptr_uint = 0
                        while teardown_rounds < 64:
                            let _ = server.pump(1) else:
                                return 91
                            let _ = client.pump(1) else:
                                return 92
                            teardown_rounds += 1

                        let release_client_sync = mp_enet.sync_slot_roster_with_client(
                            ref_of(client),
                            ref_of(client_roster),
                        )
                        match release_client_sync:
                            Result.success as applied_payload:
                                if applied_payload.value != 1:
                                    return 92
                            Result.failure:
                                return 93

                        if client_roster.occupied_count() != 0:
                            return 94
    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-multiplayer-enet-session-bindings") do |dir|
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

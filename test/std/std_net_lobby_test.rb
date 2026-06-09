# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdNetLobbyTest < Minitest::Test
  def test_lobby_join_and_events
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.async as aio
import std.bytes as bytes
import std.net as net
import std.net.lobby as lobby
import std.net.mux as mux
import std.string as string
import std.vec as vec

async function main() -> int:
    match net.ipv4("127.0.0.1", 0):
        Result.failure:
            return 1
        Result.success as bind_payload:
            var server_addr = bind_payload.value
            defer server_addr.release()
            let config = mux.MuxedConfig.default()
            var info = lobby.LobbyInfo(
                name = string.String.from_str("TestLobby"),
                player_count = 0,
                max_players = 4,
                player_names = vec.Vec[string.String].create(),
                game_data = bytes.Bytes.empty()
            )
            match lobby.create_lobby(server_addr, info, config):
                Result.failure:
                    return 2
                Result.success as host_payload:
                    var host = host_payload.value
                    defer host.release()
                    match host.local_address():
                        Result.failure:
                            return 3
                        Result.success as local_payload:
                            var resolved = local_payload.value
                            defer resolved.release()
                            match net.ipv4("127.0.0.1", 0):
                                Result.failure:
                                    return 4
                                Result.success as client_local:
                                    var cl = client_local.value
                                    defer cl.release()
                                    match await lobby.join_lobby(cl, resolved, "Player1", config):
                                        Result.failure:
                                            return 5
                                        Result.success as client_payload:
                                            var client = client_payload.value
                                            defer client.release()
                                            var joined: bool = false
                                            var frame: uint = 0
                                            while frame < 120 and not joined:
                                                await client.tick(frame)
                                                await host.tick(frame)

                                                var drain_rounds: uint = 0
                                                while drain_rounds < 5:
                                                    let event_opt = client.try_recv()
                                                    match event_opt:
                                                        Option.some as ev:
                                                            var e = ev.value
                                                            defer e.release()
                                                            if e.kind == lobby.LobbyEventKind.joined:
                                                                joined = true
                                                        Option.none:
                                                            pass
                                                    drain_rounds += 1
                                                frame += 1

                                            if joined:
                                                return 0
                                            return 30
    return 99

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_lobby_discovery_response
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.async as aio
import std.bytes as bytes
import std.net as net
import std.net.lobby as lobby
import std.net.mux as mux
import std.string as string
import std.vec as vec

async function main() -> int:
    match net.ipv4("127.0.0.1", 0):
        Result.failure:
            return 1
        Result.success as bind_payload:
            var server_addr = bind_payload.value
            defer server_addr.release()
            let config = mux.MuxedConfig.default()
            var info = lobby.LobbyInfo(
                name = string.String.from_str("DiscLobby"),
                player_count = 0,
                max_players = 2,
                player_names = vec.Vec[string.String].create(),
                game_data = bytes.Bytes.empty()
            )
            match lobby.create_lobby(server_addr, info, config):
                Result.failure:
                    return 2
                Result.success as host_payload:
                    var host = host_payload.value
                    defer host.release()
                    match host.local_address():
                        Result.failure:
                            return 3
                        Result.success as local_payload:
                            var resolved = local_payload.value
                            defer resolved.release()
                            match net.ipv4("127.0.0.1", 0):
                                Result.failure:
                                    return 4
                                Result.success as client_local:
                                    var cl = client_local.value
                                    defer cl.release()
                                    match mux.mux_connect(cl, resolved, config):
                                        Result.failure:
                                            return 5
                                        Result.success as conn_payload:
                                            var conn = conn_payload.value
                                            defer conn.release()
                                            match await conn.connect_to_peer():
                                                Result.failure:
                                                    return 6
                                                Result.success:
                                                    pass

                                            var frame: uint = 0
                                            var discovered: bool = false
                                            while frame < 120 and not discovered:
                                                await conn.tick(frame)
                                                await host.tick(frame)

                                                if frame == 3:
                                                    var empty = bytes.Bytes.empty()
                                                    let _ = await conn.mux_send(0, 0x0007, empty.as_span(), mux.flag_reliable)

                                                var drain_rounds: uint = 0
                                                while drain_rounds < 5:
                                                    let msg_opt = conn.try_recv()
                                                    match msg_opt:
                                                        Option.some as mp:
                                                            var m = mp.value
                                                            defer m.release()
                                                            if m.channel_id == 0 and m.type_id == 0x0008:
                                                                discovered = true
                                                        Option.none:
                                                            pass
                                                    drain_rounds += 1
                                                frame += 1

                                            if discovered:
                                                return 0
                                            return 30
    return 99

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_beacon_probe_and_response
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.bytes as bytes
import std.net as net
import std.net.lobby as lobby
import std.string as string
import std.vec as vec

function main() -> int:
    var probe = lobby.build_beacon_probe()
    defer probe.release()
    let probe_data = probe.as_span()

    if probe_data.len != 8:
        return 1
    if not lobby.is_beacon_probe(probe_data):
        return 2

    var info = lobby.LobbyInfo(
        name = string.String.from_str("TestBeacon"),
        player_count = 2,
        max_players = 8,
        player_names = vec.Vec[string.String].create(),
        game_data = bytes.Bytes.empty()
    )
    var response = lobby.build_beacon_response(ref_of(info))
    defer response.release()
    info.release()

    let resp_data = response.as_span()
    let parsed = lobby.parse_beacon_response(resp_data)
    match parsed:
        Result.failure:
            return 3
        Result.success as pp:
            var info2 = pp.value
            defer info2.release()
            if info2.player_count != 2:
                return 4
            if info2.max_players != 8:
                return 5
            return 0
    return 99

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-net-lobby") do |dir|
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

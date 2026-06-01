# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdMultiplayerEnetLockstepTest < Minitest::Test
  def test_enet_transports_lockstep_command_and_checksum_packets
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

      import std.multiplayer as mp
      import std.multiplayer.enet as mp_enet
      import std.multiplayer.lockstep as lockstep

      const NET_CHANNEL: uint = 2

      function main() -> int:
          var bindings = mp.BindingsBuilder.create()
          defer bindings.release()
          bindings.freeze()

          let server_result = mp_enet.listen_localhost(4, 4, bindings.registry, mp.default_config()) else:
              return 1
          var server = server_result
          defer server.release()

          let port = server.listening_port() else:
              return 2

          let client_result = mp_enet.connect_localhost(port, 4, bindings.registry, mp.default_config()) else:
              return 3
          var client = client_result
          defer client.release()

          var rounds: ptr_uint = 0
          while rounds < 240:
              let _ = server.pump(1) else:
                  return 4
              let _ = client.pump(1) else:
                  return 5

              if server.verified_peer_count() == 1 and client.protocol_ready():
                  break
              rounds += 1

          if server.verified_peer_count() != 1:
              return 6

          let connection = client.connection_id() else:
              return 7

          var outbound = zero[array[ubyte, 3]]
          outbound[0] = 9
          outbound[1] = 8
          outbound[2] = 7
          let sent_up = client.send_lockstep_commands(
              NET_CHANNEL,
              mp.TransferMode.reliable,
              lockstep.CommandPacketHeader(turn_id = 40, slot = 0, command_count = 3),
              outbound
          ) else:
              return 8
          if not sent_up:
              return 9

          let checksum_up = client.send_lockstep_checksum(
              NET_CHANNEL,
              mp.TransferMode.reliable,
              lockstep.ChecksumReport(slot = 0, turn_id = 40, checksum = ulong<-444)
          ) else:
              return 10
          if not checksum_up:
              return 11

          server.flush()
          client.flush()

          var receive_rounds: ptr_uint = 0
          while receive_rounds < 64:
              let _ = server.pump(1) else:
                  return 12
              let _ = client.pump(0) else:
                  return 13
              if server.pending_lockstep_command_count() > 0 and server.pending_lockstep_checksum_count() > 0:
                  break
              receive_rounds += 1

          let server_command = server.pop_lockstep_command() else:
              return 14
          match server_command.sender:
              Option.some as payload:
                  if payload.value != connection:
                      return 15
              Option.none:
                  return 16
          if server_command.channel != NET_CHANNEL:
              return 17
          if server_command.header.turn_id != 40 or server_command.header.slot != 0:
              return 18
          if server_command.header.command_count != 3:
              return 19
          let server_payload = server_command.payload.as_span()
          if server_payload.len != 3:
              return 20
          if server_payload[0] != 9 or server_payload[1] != 8 or server_payload[2] != 7:
              return 21
          var owned_server_command = server_command
          owned_server_command.release()

          let server_checksum = server.pop_lockstep_checksum() else:
              return 22
          if server_checksum.channel != NET_CHANNEL:
              return 23
          if server_checksum.report.turn_id != 40:
              return 24
          if server_checksum.report.slot != 0:
              return 25
          if server_checksum.report.checksum != ulong<-444:
              return 26

          var reply = zero[array[ubyte, 2]]
          reply[0] = 1
          reply[1] = 2
          let sent_down = server.send_lockstep_commands_to(
              connection,
              NET_CHANNEL,
              mp.TransferMode.reliable,
              lockstep.CommandPacketHeader(turn_id = 41, slot = 1, command_count = 2),
              reply
          ) else:
              return 27
          if not sent_down:
              return 28

          let checksum_down = server.send_lockstep_checksum_to(
              connection,
              NET_CHANNEL,
              mp.TransferMode.reliable,
              lockstep.ChecksumReport(slot = 1, turn_id = 41, checksum = ulong<-555)
          ) else:
              return 29
          if not checksum_down:
              return 30

          server.flush()
          client.flush()

          var reply_rounds: ptr_uint = 0
          while reply_rounds < 64:
              let _ = server.pump(0) else:
                  return 31
              let _ = client.pump(1) else:
                  return 32
              if client.pending_lockstep_command_count() > 0 and client.pending_lockstep_checksum_count() > 0:
                  break
              reply_rounds += 1

          let client_command = client.pop_lockstep_command() else:
              return 33
          if client_command.channel != NET_CHANNEL:
              return 34
          if client_command.header.turn_id != 41 or client_command.header.slot != 1:
              return 35
          let client_payload = client_command.payload.as_span()
          if client_payload.len != 2:
              return 36
          if client_payload[0] != 1 or client_payload[1] != 2:
              return 37
          var owned_client_command = client_command
          owned_client_command.release()

          let client_checksum = client.pop_lockstep_checksum() else:
              return 38
          if client_checksum.report.turn_id != 41:
              return 39
          if client_checksum.report.slot != 1:
              return 40
          if client_checksum.report.checksum != ulong<-555:
              return 41

          return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-multiplayer-enet-lockstep") do |dir|
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

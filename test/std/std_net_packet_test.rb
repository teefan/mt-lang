# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdNetPacketTest < Minitest::Test
  def test_packet_stream_frames_bidirectional_messages_over_tcp
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.bytes as bytes
import std.net as net
import std.net.packet as packet
import std.str as text

function expect_utf8_bytes(value: bytes.Bytes, expected: str, failure_code: int) -> int:
    match value.as_str():
        Option.none:
            return failure_code
        Option.some as payload:
            if not payload.value.equal(expected):
                return failure_code + 1
            return 0

async function main() -> int:
    match net.ipv4("127.0.0.1", 0):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 1
        Result.success as payload:
            var bind_address = payload.value
            defer bind_address.release()
            match packet.listen(bind_address, 16, 1024):
                Result.failure as listen_payload:
                    var error = listen_payload.error
                    defer error.release()
                    return 2
                Result.success as listen_payload:
                    var listener = listen_payload.value
                    defer listener.release()
                    match listener.local_address():
                        Result.failure as local_payload:
                            var error = local_payload.error
                            defer error.release()
                            return 3
                        Result.success as local_payload:
                            var local_address = local_payload.value
                            defer local_address.release()
                            let pending_accept = listener.accept()
                            let connect_result = await packet.connect(local_address, 1024)
                            match connect_result:
                                Result.failure as connect_payload:
                                    var error = connect_payload.error
                                    defer error.release()
                                    return 4
                                Result.success as connect_payload:
                                    var client = connect_payload.value
                                    defer client.release()
                                    let accept_result = await pending_accept
                                    match accept_result:
                                        Result.failure as accept_payload:
                                            var error = accept_payload.error
                                            defer error.release()
                                            return 5
                                        Result.success as accept_payload:
                                            var server = accept_payload.value
                                            defer server.release()

                                            let pending_server_read = server.read_packet()
                                            let client_write_result = await client.write_packet(text.as_byte_span("ping"))
                                            match client_write_result:
                                                Result.failure as write_payload:
                                                    var error = write_payload.error
                                                    defer error.release()
                                                    return 6
                                                Result.success as write_payload:
                                                    if write_payload.value != 4:
                                                        return 7

                                            let server_read_result = await pending_server_read
                                            match server_read_result:
                                                Result.failure as read_payload:
                                                    var error = read_payload.error
                                                    defer error.release()
                                                    return 8
                                                Result.success as read_payload:
                                                    var request = read_payload.value
                                                    defer request.release()
                                                    let request_status = expect_utf8_bytes(request, "ping", 9)
                                                    if request_status != 0:
                                                        return request_status

                                            let pending_client_read = client.read_packet()
                                            let server_write_result = await server.write_packet(text.as_byte_span("pong"))
                                            match server_write_result:
                                                Result.failure as write_payload:
                                                    var error = write_payload.error
                                                    defer error.release()
                                                    return 11
                                                Result.success as write_payload:
                                                    if write_payload.value != 4:
                                                        return 12

                                            let client_read_result = await pending_client_read
                                            match client_read_result:
                                                Result.failure as read_payload:
                                                    var error = read_payload.error
                                                    defer error.release()
                                                    return 13
                                                Result.success as read_payload:
                                                    var response = read_payload.value
                                                    defer response.release()
                                                    return expect_utf8_bytes(response, "pong", 14)

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  def test_packet_stream_rejects_packets_larger_than_configured_limit
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.bytes as bytes
import std.net as net
import std.net.packet as packet
import std.str as text

function expect_utf8_bytes(value: bytes.Bytes, expected: str, failure_code: int) -> int:
    match value.as_str():
        Option.none:
            return failure_code
        Option.some as payload:
            if not payload.value.equal(expected):
                return failure_code + 1
            return 0

async function main() -> int:
    match net.ipv4("127.0.0.1", 0):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 1
        Result.success as payload:
            var bind_address = payload.value
            defer bind_address.release()
            match packet.listen(bind_address, 16, 4):
                Result.failure as listen_payload:
                    var error = listen_payload.error
                    defer error.release()
                    return 2
                Result.success as listen_payload:
                    var listener = listen_payload.value
                    defer listener.release()
                    match listener.local_address():
                        Result.failure as local_payload:
                            var error = local_payload.error
                            defer error.release()
                            return 3
                        Result.success as local_payload:
                            var local_address = local_payload.value
                            defer local_address.release()
                            let pending_accept = listener.accept()
                            let connect_result = await packet.connect(local_address, 1024)
                            match connect_result:
                                Result.failure as connect_payload:
                                    var error = connect_payload.error
                                    defer error.release()
                                    return 4
                                Result.success as connect_payload:
                                    var client = connect_payload.value
                                    defer client.release()
                                    let accept_result = await pending_accept
                                    match accept_result:
                                        Result.failure as accept_payload:
                                            var error = accept_payload.error
                                            defer error.release()
                                            return 5
                                        Result.success as accept_payload:
                                            var server = accept_payload.value
                                            defer server.release()

                                            let write_result = await client.write_packet(text.as_byte_span("hello"))
                                            match write_result:
                                                Result.failure as write_payload:
                                                    var error = write_payload.error
                                                    defer error.release()
                                                    return 6
                                                Result.success as write_payload:
                                                    if write_payload.value != 5:
                                                        return 7

                                            let read_result = await server.read_packet()
                                            match read_result:
                                                Result.failure as read_payload:
                                                    var error = read_payload.error
                                                    defer error.release()
                                                    if error.code != -2:
                                                        return 8
                                                Result.success as read_payload:
                                                    var packet_bytes = read_payload.value
                                                    defer packet_bytes.release()
                                                    return 9

                                            let second_write_result = await client.write_packet(text.as_byte_span("ok"))
                                            match second_write_result:
                                                Result.failure as write_payload:
                                                    var error = write_payload.error
                                                    defer error.release()
                                                    return 10
                                                Result.success as write_payload:
                                                    if write_payload.value != 2:
                                                        return 11

                                            let second_read_result = await server.read_packet()
                                            match second_read_result:
                                                Result.failure as read_payload:
                                                    var error = read_payload.error
                                                    defer error.release()
                                                    return 12
                                                Result.success as read_payload:
                                                    var packet_bytes = read_payload.value
                                                    defer packet_bytes.release()
                                                    return expect_utf8_bytes(packet_bytes, "ok", 13)

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-net-packet") do |dir|
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

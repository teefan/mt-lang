# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdNetChannelTest < Minitest::Test
  def test_udp_channel_bind_connect_wraps_connected_socket_and_delivers_unreliable_messages
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.bytes as bytes
import std.net as net
import std.net.channel as channel
import std.str as text

function expect_utf8_bytes(value: bytes.Bytes, expected: str, failure_code: int) -> int:
    match value.as_str():
        Option.none:
            return failure_code
        Option.some as payload:
            if not payload.value.equal(expected):
                return failure_code + 1
            return 0

function expect_connected(result: Result[bool, net.Error], failure_code: int) -> int:
    match result:
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return failure_code
        Result.success as payload:
            if not payload.value:
                return failure_code + 1
            return 0

async function main() -> int:
    let config = channel.Config.default(256)

    match net.ipv4("127.0.0.1", 0):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 1
        Result.success as payload:
            var left_bind_address = payload.value
            defer left_bind_address.release()

            match net.ipv4("127.0.0.1", 0):
                Result.failure as right_payload:
                    var error = right_payload.error
                    defer error.release()
                    return 2
                Result.success as right_payload:
                    var right_bind_address = right_payload.value
                    defer right_bind_address.release()

                    match net.udp_bind(right_bind_address):
                        Result.failure as bind_payload:
                            var error = bind_payload.error
                            defer error.release()
                            return 3
                        Result.success as bind_payload:
                            var right_socket = bind_payload.value
                            match right_socket.local_address():
                                Result.failure as local_payload:
                                    var error = local_payload.error
                                    defer error.release()
                                    right_socket.release()
                                    return 4
                                Result.success as local_payload:
                                    var right_local = local_payload.value
                                    defer right_local.release()

                                    match channel.bind_connect(left_bind_address, right_local, config):
                                        Result.failure as left_payload:
                                            var error = left_payload.error
                                            defer error.release()
                                            right_socket.release()
                                            return 5
                                        Result.success as left_payload:
                                            var left = left_payload.value
                                            defer left.release()

                                            match left.local_address():
                                                Result.failure as left_local_payload:
                                                    var error = left_local_payload.error
                                                    defer error.release()
                                                    right_socket.release()
                                                    return 6
                                                Result.success as left_local_payload:
                                                    var left_local = left_local_payload.value
                                                    defer left_local.release()

                                                    let connect_status = expect_connected(right_socket.connect(left_local), 7)
                                                    if connect_status != 0:
                                                        right_socket.release()
                                                        return connect_status

                                                    var right = channel.wrap_connected(right_socket, config)
                                                    defer right.release()

                                                    let send_result = await left.send(text.as_byte_span("ping"))
                                                    match send_result:
                                                        Result.failure as send_payload:
                                                            var error = send_payload.error
                                                            defer error.release()
                                                            return 9
                                                        Result.success as send_payload:
                                                            if send_payload.value != 0:
                                                                return 10

                                                    let recv_result = await right.recv()
                                                    match recv_result:
                                                        Result.failure as recv_payload:
                                                            var error = recv_payload.error
                                                            defer error.release()
                                                            return 11
                                                        Result.success as recv_payload:
                                                            match recv_payload.value:
                                                                Option.none:
                                                                    return 12
                                                                Option.some as message_payload:
                                                                    var message = message_payload.value
                                                                    defer message.release()
                                                                    if message.reliable:
                                                                        return 13
                                                                    return expect_utf8_bytes(message.payload, "ping", 14)

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  def test_udp_channel_reliable_messages_resend_until_acked_and_drop_duplicates
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.bytes as bytes
import std.net as net
import std.net.channel as channel
import std.str as text

function expect_utf8_bytes(value: bytes.Bytes, expected: str, failure_code: int) -> int:
    match value.as_str():
        Option.none:
            return failure_code
        Option.some as payload:
            if not payload.value.equal(expected):
                return failure_code + 1
            return 0

function expect_connected(result: Result[bool, net.Error], failure_code: int) -> int:
    match result:
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return failure_code
        Result.success as payload:
            if not payload.value:
                return failure_code + 1
            return 0

function build_config() -> channel.Config:
    return channel.Config(max_payload_bytes = 256, max_pending_reliable = 8, resend_after_frames = 1)

async function main() -> int:
    let config = build_config()

    match net.ipv4("127.0.0.1", 0):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 1
        Result.success as payload:
            var left_bind_address = payload.value
            defer left_bind_address.release()

            match net.ipv4("127.0.0.1", 0):
                Result.failure as right_payload:
                    var error = right_payload.error
                    defer error.release()
                    return 2
                Result.success as right_payload:
                    var right_bind_address = right_payload.value
                    defer right_bind_address.release()

                    match net.udp_bind(right_bind_address):
                        Result.failure as bind_payload:
                            var error = bind_payload.error
                            defer error.release()
                            return 3
                        Result.success as bind_payload:
                            var right_socket = bind_payload.value
                            match right_socket.local_address():
                                Result.failure as local_payload:
                                    var error = local_payload.error
                                    defer error.release()
                                    right_socket.release()
                                    return 4
                                Result.success as local_payload:
                                    var right_local = local_payload.value
                                    defer right_local.release()

                                    match channel.bind_connect(left_bind_address, right_local, config):
                                        Result.failure as left_payload:
                                            var error = left_payload.error
                                            defer error.release()
                                            right_socket.release()
                                            return 5
                                        Result.success as left_payload:
                                            var left = left_payload.value
                                            defer left.release()

                                            match left.local_address():
                                                Result.failure as left_local_payload:
                                                    var error = left_local_payload.error
                                                    defer error.release()
                                                    right_socket.release()
                                                    return 6
                                                Result.success as left_local_payload:
                                                    var left_local = left_local_payload.value
                                                    defer left_local.release()

                                                    let connect_status = expect_connected(right_socket.connect(left_local), 7)
                                                    if connect_status != 0:
                                                        right_socket.release()
                                                        return connect_status

                                                    var right = channel.wrap_connected(right_socket, config)
                                                    defer right.release()

                                                    let send_result = await left.send_reliable(text.as_byte_span("reliable"), 0)
                                                    match send_result:
                                                        Result.failure as send_payload:
                                                            var error = send_payload.error
                                                            defer error.release()
                                                            return 9
                                                        Result.success as send_payload:
                                                            if send_payload.value != 0:
                                                                return 10

                                                    let first_recv = await right.recv()
                                                    match first_recv:
                                                        Result.failure as recv_payload:
                                                            var error = recv_payload.error
                                                            defer error.release()
                                                            return 11
                                                        Result.success as recv_payload:
                                                            match recv_payload.value:
                                                                Option.none:
                                                                    return 12
                                                                Option.some as message_payload:
                                                                    var message = message_payload.value
                                                                    defer message.release()
                                                                    if not message.reliable:
                                                                        return 13
                                                                    let body_status = expect_utf8_bytes(message.payload, "reliable", 14)
                                                                    if body_status != 0:
                                                                        return body_status

                                                    let tick_result = await left.tick(1)
                                                    match tick_result:
                                                        Result.failure as tick_payload:
                                                            var error = tick_payload.error
                                                            defer error.release()
                                                            return 16
                                                        Result.success as tick_payload:
                                                            if tick_payload.value != 1:
                                                                return 17

                                                    let duplicate_recv = await right.recv()
                                                    match duplicate_recv:
                                                        Result.failure as recv_payload:
                                                            var error = recv_payload.error
                                                            defer error.release()
                                                            return 18
                                                        Result.success as recv_payload:
                                                            match recv_payload.value:
                                                                Option.none:
                                                                    let _ = 0
                                                                Option.some as message_payload:
                                                                    var message = message_payload.value
                                                                    defer message.release()
                                                                    return 19

                                                    let ack_recv = await left.recv()
                                                    match ack_recv:
                                                        Result.failure as ack_payload:
                                                            var error = ack_payload.error
                                                            defer error.release()
                                                            return 20
                                                        Result.success as ack_payload:
                                                            match ack_payload.value:
                                                                Option.none:
                                                                    let _ = 0
                                                                Option.some as message_payload:
                                                                    var message = message_payload.value
                                                                    defer message.release()
                                                                    return 21

                                                    if left.pending_reliable_len() != 0:
                                                        return 22

                                                    let second_tick = await left.tick(2)
                                                    match second_tick:
                                                        Result.failure as tick_payload:
                                                            var error = tick_payload.error
                                                            defer error.release()
                                                            return 23
                                                        Result.success as tick_payload:
                                                            if tick_payload.value != 0:
                                                                return 24

                                                    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  def test_udp_channel_host_routes_messages_between_multiple_peers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.bytes as bytes
import std.net as net
import std.net.channel as channel
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
    let config = channel.Config.default(256)

    match net.ipv4("127.0.0.1", 0):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 1
        Result.success as payload:
            var host_bind_address = payload.value
            defer host_bind_address.release()

            match channel.listen(host_bind_address, config):
                Result.failure as host_payload:
                    var error = host_payload.error
                    defer error.release()
                    return 2
                Result.success as host_payload:
                    var host = host_payload.value
                    defer host.release()

                    match host.local_address():
                        Result.failure as host_local_payload:
                            var error = host_local_payload.error
                            defer error.release()
                            return 3
                        Result.success as host_local_payload:
                            var host_local = host_local_payload.value
                            defer host_local.release()

                            match net.ipv4("127.0.0.1", 0):
                                Result.failure as left_bind_payload:
                                    var error = left_bind_payload.error
                                    defer error.release()
                                    return 4
                                Result.success as left_bind_payload:
                                    var left_bind_address = left_bind_payload.value
                                    defer left_bind_address.release()

                                    match net.ipv4("127.0.0.1", 0):
                                        Result.failure as right_bind_payload:
                                            var error = right_bind_payload.error
                                            defer error.release()
                                            return 5
                                        Result.success as right_bind_payload:
                                            var right_bind_address = right_bind_payload.value
                                            defer right_bind_address.release()

                                            match channel.bind_connect(left_bind_address, host_local, config):
                                                Result.failure as left_payload:
                                                    var error = left_payload.error
                                                    defer error.release()
                                                    return 6
                                                Result.success as left_payload:
                                                    var left = left_payload.value
                                                    defer left.release()

                                                    match channel.bind_connect(right_bind_address, host_local, config):
                                                        Result.failure as right_payload:
                                                            var error = right_payload.error
                                                            defer error.release()
                                                            return 7
                                                        Result.success as right_payload:
                                                            var right = right_payload.value
                                                            defer right.release()

                                                            let left_send = await left.send(text.as_byte_span("left"))
                                                            match left_send:
                                                                Result.failure as send_payload:
                                                                    var error = send_payload.error
                                                                    defer error.release()
                                                                    return 8
                                                                Result.success as send_payload:
                                                                    unsafe: send_payload.value

                                                            let right_send = await right.send(text.as_byte_span("right"))
                                                            match right_send:
                                                                Result.failure as send_payload:
                                                                    var error = send_payload.error
                                                                    defer error.release()
                                                                    return 9
                                                                Result.success as send_payload:
                                                                    unsafe: send_payload.value

                                                            var saw_left = false
                                                            var saw_right = false
                                                            var received_count: ptr_uint = 0
                                                            while received_count < 2:
                                                                let recv_result = await host.recv()
                                                                match recv_result:
                                                                    Result.failure as recv_payload:
                                                                        var error = recv_payload.error
                                                                        defer error.release()
                                                                        return 10
                                                                    Result.success as recv_payload:
                                                                        match recv_payload.value:
                                                                            Option.none:
                                                                                return 11
                                                                            Option.some as message_payload:
                                                                                var message = message_payload.value
                                                                                defer message.release()

                                                                                let left_status = expect_utf8_bytes(message.payload, "left", 12)
                                                                                if left_status == 0:
                                                                                    if saw_left:
                                                                                        return 14
                                                                                    saw_left = true
                                                                                    let reply_result = await host.send(message.source, text.as_byte_span("left-ack"))
                                                                                    match reply_result:
                                                                                        Result.failure as reply_payload:
                                                                                            var error = reply_payload.error
                                                                                            defer error.release()
                                                                                            return 15
                                                                                        Result.success as reply_payload:
                                                                                            unsafe: reply_payload.value
                                                                                            received_count += 1
                                                                                            continue

                                                                                let right_status = expect_utf8_bytes(message.payload, "right", 20)
                                                                                if right_status == 0:
                                                                                    if saw_right:
                                                                                        return 22
                                                                                    saw_right = true
                                                                                    let reply_result = await host.send(message.source, text.as_byte_span("right-ack"))
                                                                                    match reply_result:
                                                                                        Result.failure as reply_payload:
                                                                                            var error = reply_payload.error
                                                                                            defer error.release()
                                                                                            return 23
                                                                                        Result.success as reply_payload:
                                                                                            unsafe: reply_payload.value
                                                                                            received_count += 1
                                                                                            continue

                                                                                return 24

                                                            if not saw_left or not saw_right:
                                                                return 25
                                                            if host.peer_count() != 2:
                                                                return 26

                                                            let left_recv = await left.recv()
                                                            match left_recv:
                                                                Result.failure as recv_payload:
                                                                    var error = recv_payload.error
                                                                    defer error.release()
                                                                    return 27
                                                                Result.success as recv_payload:
                                                                    match recv_payload.value:
                                                                        Option.none:
                                                                            return 28
                                                                        Option.some as message_payload:
                                                                            var message = message_payload.value
                                                                            defer message.release()
                                                                            if message.reliable:
                                                                                return 29
                                                                            let ack_status = expect_utf8_bytes(message.payload, "left-ack", 30)
                                                                            if ack_status != 0:
                                                                                return ack_status

                                                            let right_recv = await right.recv()
                                                            match right_recv:
                                                                Result.failure as recv_payload:
                                                                    var error = recv_payload.error
                                                                    defer error.release()
                                                                    return 40
                                                                Result.success as recv_payload:
                                                                    match recv_payload.value:
                                                                        Option.none:
                                                                            return 41
                                                                        Option.some as message_payload:
                                                                            var message = message_payload.value
                                                                            defer message.release()
                                                                            if message.reliable:
                                                                                return 42
                                                                            let ack_status = expect_utf8_bytes(message.payload, "right-ack", 43)
                                                                            if ack_status != 0:
                                                                                return ack_status

                                                            return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-net-channel") do |dir|
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

# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdMultiplayerEnetFrameWithRpcsTest < Minitest::Test
  def test_frame_with_rpcs_dispatches_typed_rpcs_in_one_call
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.multiplayer as mp
import std.multiplayer.protocol as protocol
import std.multiplayer.enet as mp_enet
import std.multiplayer.rpc as rpc

const NET_CHANNEL: uint = 1

var routed_value: ubyte = 0

@[mp.rpc(direction = mp.RpcDirection.server_to_connection, mode = mp.TransferMode.reliable, channel = NET_CHANNEL, require_owner = false)]
function receive_marker(context: mp.RpcContext, marker: ubyte) -> void:
    routed_value = marker


function dispatch_receive_marker(context: mp.RpcContext, payload: span[ubyte]) -> Result[bool, rpc.DispatchError]:
    let dispatched = rpc.dispatch_typed_payload(callable_of(receive_marker), context, payload) else as dispatch_error:
        return Result[bool, rpc.DispatchError].failure(
            error = rpc.DispatchError(code = dispatch_error.code, message = dispatch_error.message),
        )

    return Result[bool, rpc.DispatchError].success(value = dispatched)


function install_bindings(builder: ptr[mp.BindingsBuilder]) -> Result[ptr_uint, mp.Error]:
    let builder_ref = unsafe: ref_of(read(builder))
    let rpc_bound = mp.bind_typed_rpc(builder_ref, callable_of(receive_marker), dispatch_receive_marker) else as bind_error:
        return Result[ptr_uint, mp.Error].failure(error = bind_error)
    if not rpc_bound:
        return Result[ptr_uint, mp.Error].success(value = 0)

    return Result[ptr_uint, mp.Error].success(value = 1)


function main() -> int:
    let built_bindings = mp.build_frozen_bindings_with(install_bindings) else:
        return 1
    var bindings = built_bindings
    defer bindings.release()

    let server_result = mp_enet.listen_localhost(4, 4, bindings.registry, mp.default_config()) else:
        return 2
    var server = server_result
    defer server.release()

    let port = server.listening_port() else:
        return 3
    if port == ushort<-0:
        return 4

    let client_result = mp_enet.connect_localhost(port, 4, bindings.registry, mp.default_config()) else:
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
    if not client.protocol_ready():
        return 9

    let conn = client.connection_id() else:
        return 10

    var payload = array[ubyte, 1](9)
    let sent = server.send_rpc_to(
        conn,
        NET_CHANNEL,
        protocol.TransferMode.reliable,
        protocol.RpcDirection.server_to_connection,
        payload,
    ) else:
        return 11
    if not sent:
        return 12

    server.flush()
    client.flush()

    var drained: bool = false
    var pump_round: ptr_uint = 0
    while pump_round < 64:
        let report = client.frame_with_rpcs(0, ref_of(bindings.typed_rpcs)) else:
            return 13
        if report.rpcs_dispatched == 1:
            drained = true
            break
        pump_round += 1

    if not drained:
        return 14
    if routed_value != 9:
        return 15

    let sent_again = server.send_rpc_to(
        conn,
        NET_CHANNEL,
        protocol.TransferMode.reliable,
        protocol.RpcDirection.server_to_connection,
        payload,
    ) else:
        return 16
    if not sent_again:
        return 17

    server.flush()
    client.flush()

    var drained_again: bool = false
    var pump_round2: ptr_uint = 0
    while pump_round2 < 64:
        let report = client.frame_with_rpcs(0, ref_of(bindings.typed_rpcs)) else:
            return 18
        if report.rpcs_dispatched == 1:
            drained_again = true
            break
        pump_round2 += 1

    if not drained_again:
        return 19
    if routed_value != 9:
        return 20

    let plain_report = client.frame(0) else:
        return 21
    if plain_report.rpcs_dispatched != 0:
        return 22

    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-multiplayer-enet-frame-with-rpcs") do |dir|
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

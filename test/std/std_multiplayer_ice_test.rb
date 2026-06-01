# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdMultiplayerIceTest < Minitest::Test
  def test_ice_offer_answer_orchestration_and_protocol_guard
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)
    skip "libjuice not available for linker/compiler: #{compiler}" unless libjuice_available?(compiler)
    skip "std.libjuice bindings are unavailable in this toolchain" unless libjuice_mt_bindings_available?(compiler)

    source = <<~'MT'

import std.multiplayer as mp
import std.multiplayer.ice as ice
  import std.multiplayer.protocol as protocol
  import std.multiplayer.rpc as rpc
import std.multiplayer.signal as signal

  const NET_CHANNEL: uint = 7

  var routed_value: ubyte = 0
  var routed_sender: mp.ConnectionId = 0

  @[mp.rpc(direction = mp.RpcDirection.client_to_server, mode = mp.TransferMode.reliable, channel = NET_CHANNEL, require_owner = false)]
  function receive_marker(context: mp.RpcContext, marker: ubyte) -> void:
    routed_value = marker
    match context.sender:
      Option.some as payload:
        routed_sender = payload.value
      Option.none:
        routed_sender = 0


  function dispatch_receive_marker(context: mp.RpcContext, payload: span[ubyte]) -> Result[bool, rpc.DispatchError]:
    let dispatched = rpc.dispatch_typed_payload(callable_of(receive_marker), context, payload) else as dispatch_error:
      return Result[bool, rpc.DispatchError].failure(
        error = rpc.DispatchError(code = dispatch_error.code, message = dispatch_error.message),
      )

    return Result[bool, rpc.DispatchError].success(value = dispatched)


function resolve_connection_id(is_server: bool, session_id: str) -> Option[mp.ConnectionId]:
  if is_server and session_id.len == 0:
    pass

  return Option[mp.ConnectionId].some(value = 1)

function main() -> int:
    var bindings = mp.BindingsBuilder.create()
    defer bindings.release()

    let rpc_bound = mp.bind_typed_rpc(ref_of(bindings), callable_of(receive_marker), dispatch_receive_marker) else:
      return 1
    if not rpc_bound:
      return 2

    bindings.freeze()

  var ice_config = ice.default_ice_config()
  ice_config.identity_provider = resolve_connection_id

  let server_result = ice.listen(bindings.registry, mp.default_config(), ice_config) else:
        return 3
  let client_result = ice.connect(bindings.registry, mp.default_config(), ice_config) else:
        return 4

    var server = server_result
    var client = client_result
    defer server.release()
    defer client.release()

    let offer_result = client.create_offer("session-a") else:
      return 5
    var offer = offer_result
    defer offer.release()

    let answer_result = server.create_answer(offer) else:
      return 6
    var answer = answer_result
    defer answer.release()

    let applied = client.apply_answer(answer) else:
      return 7
    if not applied:
      return 8

    let verified_connection = server.first_verified_connection() else:
      return 9
    if verified_connection != 1:
      return 10

    var wrong_answer = signal.answer("session-a", registry.protocol_hash() + ulong<-1, answer.description(), true)
    defer wrong_answer.release()
    match client.apply_answer(wrong_answer):
        Result.success as _:
            return 11
        Result.failure as payload:
            if payload.error.code != mp.ErrorCode.invalid_argument:
                return 12

    let mapped_sender = server.map_inbound_channel_sender(NET_CHANNEL, 77) else:
      return 13
    if not mapped_sender:
      return 14

    var rpc_payload = array[ubyte, 1](9)
    let sent_rpc = client.send_rpc(
      NET_CHANNEL,
      protocol.TransferMode.reliable,
      protocol.RpcDirection.client_to_server,
      rpc_payload,
    ) else:
      return 15
    if not sent_rpc:
      return 16

    var rpc_rounds: ptr_uint = 0
    while rpc_rounds < 480:
      let _ = server.pump(1) else:
        return 17
      let _ = client.pump(1) else:
        return 18

      if server.pending_rpc_count() > 0:
        break
      rpc_rounds += 1

    let processed_rpcs = server.process_incoming_rpcs_typed(ref_of(bindings.typed_rpcs)) else:
      return 19
    if processed_rpcs != 1:
      return 20
    if routed_value != 9:
      return 21
    if routed_sender != 77:
      return 22

    var world_payload = server.world.encode_snapshot_payload() else:
      return 23
    defer world_payload.release()

    let snapshot_header = protocol.SnapshotPacketHeader(tick = 300, baseline_tick = 0, entity_count = 0)
    let snapshot_sent = server.broadcast_snapshot(NET_CHANNEL, protocol.TransferMode.reliable, snapshot_header, world_payload.as_span()) else:
      return 24
    if not snapshot_sent:
      return 25

    var snapshot_rounds: ptr_uint = 0
    while snapshot_rounds < 480:
      let _ = server.pump(1) else:
        return 26
      let _ = client.pump(1) else:
        return 27
      if client.pending_snapshot_count() > 0:
        break
      snapshot_rounds += 1

    let processed_snapshots = client.process_incoming_snapshots() else:
      return 28
    if processed_snapshots != 1:
      return 29
    if client.pending_snapshot_count() != 0:
      return 30

    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-multiplayer-ice") do |dir|
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

  def libjuice_available?(compiler)
    Dir.mktmpdir("milk-tea-libjuice-probe") do |dir|
      source_path = File.join(dir, "probe.c")
      output_path = File.join(dir, "probe")
      File.write(source_path, "int main(void) { return 0; }\n")
      return system(compiler, source_path, "-o", output_path, "-ljuice", out: File::NULL, err: File::NULL)
    end
  end

  def libjuice_mt_bindings_available?(compiler)
    Dir.mktmpdir("milk-tea-libjuice-mt-probe") do |dir|
      source_path = File.join(dir, "probe.mt")
      output_path = File.join(dir, "probe")
      File.write(source_path, <<~'MT')

import std.libjuice as juice

function main() -> int:
    if juice.ERR_SUCCESS != 0:
        return 1
    return 0

      MT

      begin
        MilkTea::Build.build(source_path, output_path:, cc: compiler)
      rescue MilkTea::BuildError
        return false
      end
      true
    end
  end
end

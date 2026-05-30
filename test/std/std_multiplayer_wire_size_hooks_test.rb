# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdMultiplayerWireSizeHooksTest < Minitest::Test
  def test_wire_size_hooks_return_expected_values
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.multiplayer as mp

@[mp.replicated(authority = mp.Authority.server)]
struct PlayerState:
    @[mp.sync(mode = mp.TransferMode.unreliable_ordered, channel = 0, rate_hz = 20, target = mp.SyncTarget.observers)]
    x: float
    @[mp.sync(mode = mp.TransferMode.unreliable_ordered, channel = 0, rate_hz = 20, target = mp.SyncTarget.observers)]
    hp: int

@[mp.rpc(direction = mp.RpcDirection.client_to_server, mode = mp.TransferMode.reliable, channel = 2, require_owner = true)]
function submit_input(context: mp.RpcContext, entity: mp.EntityId, input: int) -> void:
    return

function main() -> int:
    if mp.state_wire_size[PlayerState]() != 8:
        return 1
    if mp.rpc_payload_size(callable_of(submit_input)) != 12:
        return 2
    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-multiplayer-wire-size-hooks") do |dir|
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

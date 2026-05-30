# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdMultiplayerWorldSnapshotSignatureTest < Minitest::Test
  def test_world_snapshot_signature_tracks_entity_state_changes
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.multiplayer as mp
import std.multiplayer.snapshot as snapshot

@[mp.replicated(authority = mp.Authority.server)]
struct PlayerState:
    @[mp.sync(mode = mp.TransferMode.unreliable_ordered, channel = 0, rate_hz = 20, target = mp.SyncTarget.observers)]
    x: float
    @[mp.sync(mode = mp.TransferMode.unreliable_ordered, channel = 0, rate_hz = 20, target = mp.SyncTarget.observers)]
    hp: int

function build_registry() -> mp.Registry:
    var registry = mp.Registry.create()
    let _ = registry.add_state(mp.state_descriptor[PlayerState]()) else:
        fatal(c"failed to add state descriptor")
    registry.freeze()
    return registry

function main() -> int:
    var registry = build_registry()
    defer registry.release()

    let world_result = mp.World.create(registry, mp.default_config(), mp.WorldRole.server) else:
        return 1
    var world = world_result
    defer world.release()

    let entity = world.spawn[PlayerState](PlayerState(x = 1.5, hp = 90), Option[mp.ConnectionId].none) else:
        return 2

    let signature0 = world.snapshot_state_signature(100)
    if signature0.entity_count != 1:
        return 3
    if signature0.payload_bytes != mp.state_wire_size[PlayerState]():
        return 4
    if signature0.payload_hash == 0:
        return 5

    var baselines = snapshot.BaselineSet(
        last_applied_tick = 0,
        last_applied_entity_count = 0,
        last_applied_payload_bytes = 0,
        last_applied_payload_hash = 0,
    )

    world.apply_snapshot_signature(100, ref_of(baselines))
    if baselines.last_applied_tick != 100:
        return 6
    if baselines.last_applied_entity_count != 1:
        return 13
    if baselines.last_applied_payload_bytes != signature0.payload_bytes:
        return 7
    if baselines.last_applied_payload_hash != signature0.payload_hash:
        return 8

    let state_ptr = world.state_ptr[PlayerState](entity) else:
        return 9
    unsafe:
        read(state_ptr).hp = 70

    let signature1 = world.snapshot_state_signature(101)
    if signature1.payload_hash == signature0.payload_hash:
        return 10

    world.apply_snapshot_signature(101, ref_of(baselines))
    if baselines.last_applied_tick != 101:
        return 11
    if baselines.last_applied_payload_hash != signature1.payload_hash:
        return 12

    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-multiplayer-world-snapshot-signature") do |dir|
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

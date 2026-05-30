# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdMultiplayerSnapshotRuntimeTest < Minitest::Test
  def test_snapshot_payload_capture_diff_and_apply_track_baselines
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.multiplayer.snapshot as snapshot

function main() -> int:
    var payload_a = array[ubyte, 3](1, 2, 3)
    var payload_b = array[ubyte, 3](1, 2, 4)

    let base = snapshot.capture_payload(10, 3, payload_a)
    let current = snapshot.capture_payload(11, 3, payload_b)

    if base.payload_bytes != 3:
        return 1
    if base.payload_hash == 0:
        return 2
    if current.payload_hash == base.payload_hash:
        return 3

    let delta = snapshot.diff(current, base)
    if not delta.payload_changed:
        return 4
    if delta.changed_entity_count != 3:
        return 5

    let same = snapshot.diff_payload(11, 3, payload_b, 11, 3, payload_b)
    if same.payload_changed:
        return 6
    if same.changed_entity_count != 0:
        return 7

    var baselines = snapshot.BaselineSet(
        last_applied_tick = 0,
        last_applied_entity_count = 0,
        last_applied_payload_bytes = 0,
        last_applied_payload_hash = 0,
    )

    snapshot.apply(current, ref_of(baselines))
    if baselines.last_applied_tick != 11:
        return 8
    if baselines.last_applied_entity_count != 3:
        return 13
    if baselines.last_applied_payload_bytes != 3:
        return 9
    if baselines.last_applied_payload_hash != current.payload_hash:
        return 10

    snapshot.apply_payload(12, 2, payload_a, ref_of(baselines))
    if baselines.last_applied_tick != 12:
        return 11
    if baselines.last_applied_payload_bytes != 3:
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
    Dir.mktmpdir("milk-tea-std-multiplayer-snapshot-runtime") do |dir|
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

# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdSyncTest < Minitest::Test
  def test_sync_value_dirty_tracking
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.net.sync as sync

function main() -> int:
    var hp = sync.SyncValue[float](value = 100.0, dirty = false)

    if hp.dirty:
        return 1

    hp.set(90.0)
    if not hp.dirty:
        return 2
    if hp.get() != 90.0:
        return 3

    hp.mark_clean()
    if hp.dirty:
        return 4
    if hp.get() != 90.0:
        return 5

    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_sync_value_with_uint
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.net.sync as sync

function main() -> int:
    var score = sync.SyncValue[uint](value = 0, dirty = false)

    if score.has_changed():
        return 1

    score.set(42)
    if not score.has_changed():
        return 2
    if score.get() != 42:
        return 3

    score.mark_clean()
    if score.has_changed():
        return 4
    if score.get() != 42:
        return 5

    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_sync_list_push_and_length
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.vec as vec
import std.net.sync as sync

function main() -> int:
    var list = sync.SyncList[uint](items = vec.Vec[uint].create(), dirty = false)

    if list.dirty:
        return 1
    if list.len() != 0:
        return 2

    list.push(10)
    if not list.dirty:
        return 3
    if list.len() != 1:
        return 4

    let ptr = list.get(0) else:
        return 5
    if unsafe: read(ptr) != 10:
        return 6

    list.mark_clean()
    if list.dirty:
        return 7

    list.clear()
    if not list.dirty:
        return 8
    if list.len() != 0:
        return 9

    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_sync_list_multiple_items
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.vec as vec
import std.net.sync as sync

function main() -> int:
    var events = sync.SyncList[uint](items = vec.Vec[uint].create(), dirty = false)

    events.push(100)
    events.push(200)
    events.push(300)

    if events.len() != 3:
        return 1
    if not events.dirty:
        return 2

    # Verify all items present
    let p0 = events.get(0) else:
        return 3
    let p1 = events.get(1) else:
        return 4
    let p2 = events.get(2) else:
        return 5

    if unsafe: read(p0) != 100:
        return 6
    if unsafe: read(p1) != 200:
        return 7
    if unsafe: read(p2) != 300:
        return 8

    events.mark_clean()
    if events.dirty:
        return 9

    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-sync") do |dir|
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

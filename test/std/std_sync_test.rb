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

  def test_lerp_interpolates_between_values
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.net.sync as sync

function main() -> int:
    var lerp = sync.Lerp(
        previous = 0.0,
        target = 100.0,
        elapsed = 0.0,
        duration = 1.0
    )

    # At t=0, should be at previous (0.0)
    if lerp.current() != 0.0:
        return 1

    lerp.tick(0.5)
    # At t=0.5, should be at halfway (50.0)
    var mid = lerp.current()
    if mid < 49.0 or mid > 51.0:
        return 2

    lerp.tick(0.5)
    # At t=1.0, should be at target (100.0)
    if lerp.current() != 100.0:
        return 3

    if not lerp.has_arrived():
        return 4

    # Set new target from current position
    lerp.set_target(200.0, 1.0)
    if lerp.current() != 100.0:
        return 5

    lerp.tick(1.0)
    if lerp.current() != 200.0:
        return 6

    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_compressed_u16_roundtrip
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.net.sync as sync

function main() -> int:
    var c = sync.CompressedUshort(min = 0.0, max = 1000.0)

    var original: float = 500.0
    var encoded = c.encode(original)
    var decoded = c.decode(encoded)

    # Should be within precision (range / 65536 ≈ 0.015)
    if decoded < 499.9 or decoded > 500.1:
        return 1

    # Min value
    var lo = c.decode(c.encode(0.0))
    if lo < -0.1 or lo > 0.1:
        return 2

    # Max value
    var hi = c.decode(c.encode(1000.0))
    if hi < 999.9 or hi > 1000.1:
        return 3

    # Below min should clamp
    var clamped = c.decode(c.encode(-500.0))
    if clamped < -0.1 or clamped > 0.1:
        return 4

    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_compressed_u8_roundtrip
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.net.sync as sync

function main() -> int:
    var c = sync.CompressedUbyte(min = -1.0, max = 1.0)

    var original: float = 0.5
    var encoded = c.encode(original)
    var decoded = c.decode(encoded)

    # Within u8 precision (range / 256 ≈ 0.008)
    if decoded < 0.48 or decoded > 0.52:
        return 1

    # Zero should be near zero
    var zero = c.decode(c.encode(0.0))
    if zero < -0.02 or zero > 0.02:
        return 2

    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_tick_buffer_push_and_get
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.vec as vec
import std.net.sync as sync

function main() -> int:
    var buf = sync.TickBuffer[uint](
        entries = vec.Vec[uint].create(),
        base_tick = 0
    )

    buf.push(0, 100)
    buf.push(1, 200)
    buf.push(2, 300)

    match buf.get(0):
        Option.some as r0:
            if r0.value != 100:
                return 1
        Option.none:
            return 2

    match buf.get(1):
        Option.some as r1:
            if r1.value != 200:
                return 3
        Option.none:
            return 4

    match buf.get(2):
        Option.some as r2:
            if r2.value != 300:
                return 5
        Option.none:
            return 6

    if buf.earliest_tick() != 0:
        return 7

    buf.push(1, 999)
    match buf.get(1):
        Option.some as r1b:
            if r1b.value != 999:
                return 8
        Option.none:
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

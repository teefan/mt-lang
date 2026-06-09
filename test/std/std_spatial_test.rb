# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdSpatialTest < Minitest::Test
  def test_new_grid_has_correct_dimensions
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.spatial as sp

function main() -> int:
    var grid = sp.new[uint](10.0, 100.0, 50.0)
    defer grid.release()

    # 100/10 = 10 cols, 50/10 = 5 rows, total 50 cells
    let nc = grid.cell_count()
    if nc != ptr_uint<-50:
        return 1
    if grid.cols != uint<-10:
        return 2
    if grid.rows != uint<-5:
        return 3
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_insert_and_query_finds_entity
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.spatial as sp
import std.vec as vec

function main() -> int:
    var grid = sp.new[uint](10.0, 100.0, 100.0)
    defer grid.release()

    grid.insert(42, 15.0, 25.0)
    grid.insert(99, 85.0, 85.0)

    # Query near (15, 25)
    var results = grid.query_radius(15.0, 25.0, 5.0)
    defer results.release()

    if results.len() == 0:
        return 1

    let ptr = results.get(0) else:
        return 2
    if unsafe: read(ptr) != 42:
        return 3
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_clear_removes_all_entities
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.spatial as sp

function main() -> int:
    var grid = sp.new[uint](10.0, 100.0, 100.0)
    defer grid.release()

    grid.insert(1, 5.0, 5.0)
    grid.insert(2, 15.0, 25.0)
    grid.insert(3, 55.0, 65.0)

    if grid.entity_count() != ptr_uint<-3:
        return 1

    grid.clear()
    if grid.entity_count() != ptr_uint<-0:
        return 2

    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_query_outside_bounds_is_empty
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.spatial as sp

function main() -> int:
    var grid = sp.new[uint](10.0, 100.0, 100.0)
    defer grid.release()

    grid.insert(42, 5.0, 5.0)

    # Query far outside
    var results = grid.query_radius(200.0, 200.0, 5.0)
    defer results.release()

    if results.len() != ptr_uint<-0:
        return 1
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_multiple_entities_in_same_cell
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.spatial as sp
import std.vec as vec

function main() -> int:
    var grid = sp.new[uint](20.0, 100.0, 100.0)
    defer grid.release()

    grid.insert(10, 5.0, 5.0)
    grid.insert(20, 8.0, 8.0)
    grid.insert(30, 12.0, 12.0)

    var results = grid.query_radius(10.0, 10.0, 15.0)
    defer results.release()

    if results.len() != ptr_uint<-3:
        return 1
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_cell_index_with_origin_offset
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.spatial as sp

function main() -> int:
    var grid = sp.new_with_origin[uint](10.0, 100.0, 100.0, 50.0, 30.0)
    defer grid.release()

    # Position (55, 35) should be at cell (0, 0) since origin is (50, 30)
    grid.insert(42, 55.0, 35.0)

    var results = grid.query_radius(55.0, 35.0, 1.0)
    defer results.release()

    if results.len() != ptr_uint<-1:
        return 1
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-spatial") do |dir|
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

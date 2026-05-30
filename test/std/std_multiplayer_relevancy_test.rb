# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdMultiplayerRelevancyTest < Minitest::Test
  def test_grid_and_owner_or_grid_policies
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.multiplayer as mp
import std.multiplayer.relevancy as relevancy
import std.multiplayer.spatial as spatial

function connection_cell(connection: mp.ConnectionId) -> relevancy.CellCoord:
    if connection == 1:
        return relevancy.CellCoord(x = 5, y = 5)
    return relevancy.CellCoord(x = 20, y = 20)


function entity_cell(entity: mp.EntityId) -> relevancy.CellCoord:
    if entity == 10:
        return relevancy.CellCoord(x = 6, y = 4)
    return relevancy.CellCoord(x = 100, y = 100)


function main() -> int:
    let grid_policy = relevancy.grid(connection_cell, entity_cell, 2)
    if not relevancy.allows(grid_policy, 1, 10, Option[mp.ConnectionId].none):
        return 1
    if relevancy.allows(grid_policy, 1, 11, Option[mp.ConnectionId].none):
        return 2

    let owner_or_grid_policy = relevancy.owner_or_grid(connection_cell, entity_cell, 2)
    if not relevancy.allows(owner_or_grid_policy, 1, 11, Option[mp.ConnectionId].some(value = 1)):
        return 3
    if relevancy.allows(owner_or_grid_policy, 2, 11, Option[mp.ConnectionId].none):
        return 4

    var index = spatial.GridIndex.create()
    defer index.release()
    index.set_connection_cell(1, spatial.GridCell(x = 5, y = 5))
    index.set_entity_cell(11, spatial.GridCell(x = 6, y = 5))

    if not relevancy.owner_or_grid_index(index, 1, 11, Option[mp.ConnectionId].none, 1):
        return 5
    if relevancy.owner_or_grid_index(index, 2, 11, Option[mp.ConnectionId].none, 1):
        return 6

    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-multiplayer-relevancy") do |dir|
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

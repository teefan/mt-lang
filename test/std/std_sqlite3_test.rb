# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdSqlite3Test < Minitest::Test
  def test_host_runtime_exposes_sqlite3_vtab_and_vfs_surface
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.sqlite3 as sqlite

function main() -> int:
    if sqlite.libversion_number() <= 0:
        return 1

    var module_: sqlite.sqlite3_module = zero[sqlite.sqlite3_module]
    var vtab = zero[sqlite.sqlite3_vtab]
    var cursor = zero[sqlite.sqlite3_vtab_cursor]
    var info = zero[sqlite.sqlite3_index_info]

    if module_.iVersion != 0:
        return 2

    vtab.nRef = 7
    cursor.pVtab = ptr_of(vtab)
    if cursor.pVtab != ptr_of(vtab):
        return 3

    info.idxNum = 42
    if info.idxNum != 42:
        return 4

    if sqlite.INDEX_CONSTRAINT_EQ != 2:
        return 5

    if sqlite.VTAB_CONSTRAINT_SUPPORT <= 0:
        return 6

    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_includes result.link_flags, "-lsqlite3"
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-sqlite3") do |dir|
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

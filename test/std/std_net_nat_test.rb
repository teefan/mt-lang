# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdNetNatTest < Minitest::Test
  def test_nat_type_enum_values
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.net.nat as nat

function main() -> int:
    # Verify NatType enum values can be constructed and compared
    var blocked = nat.NatType.blocked
    var open_type = nat.NatType.open_internet
    var cone = nat.NatType.cone
    var sym = nat.NatType.symmetric

    if ubyte<-blocked != 0:
        return 1
    if ubyte<-open_type != 1:
        return 2
    if ubyte<-cone != 2:
        return 3
    if ubyte<-sym != 3:
        return 4

    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_nat_result_construction
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.net as net
import std.net.nat as nat

function main() -> int:
    let addr_result = net.ipv4("127.0.0.1", 1234)
    match addr_result:
        Result.failure:
            return 1
        Result.success as ap:
            var addr = ap.value
            defer addr.release()
            let copy_result = addr.copy()
            match copy_result:
                Result.failure:
                    return 2
                Result.success as cp:
                    var public_addr = cp.value
                    var result = nat.NatResult(
                        nat_type = nat.NatType.cone,
                        public_address = public_addr
                    )
                    defer result.release()
                    if ubyte<-result.nat_type != 2:
                        return 3
                    return 0
    return 99

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-net-nat") do |dir|
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

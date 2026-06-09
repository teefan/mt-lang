# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdNetPunchTest < Minitest::Test
  def test_builds_valid_probe
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.bytes as bytes
import std.net.punch as punch

function main() -> int:
    var probe = punch.build_punch_probe()
    defer probe.release()
    let data = probe.as_span()

    if data.len != 4:
        return 1
    if data[0] != 0x4D:
        return 2
    if data[1] != 0x54:
        return 3
    if data[2] != 0x50:
        return 4
    if data[3] != 0x43:
        return 5
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_is_punch_probe_detects_valid_and_invalid
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.bytes as bytes
import std.binary as bin
import std.net.punch as punch

function main() -> int:
    var w = bin.Writer.with_capacity(4)
    w.write_ubyte(0x4D)
    w.write_ubyte(0x54)
    w.write_ubyte(0x50)
    w.write_ubyte(0x43)
    var valid = w.finish()
    defer valid.release()
    if not punch.is_punch_probe(valid.as_span()):
        return 1

    var w2 = bin.Writer.with_capacity(4)
    w2.write_ubyte(0x00)
    w2.write_ubyte(0x00)
    w2.write_ubyte(0x00)
    w2.write_ubyte(0x00)
    var invalid = w2.finish()
    defer invalid.release()
    if punch.is_punch_probe(invalid.as_span()):
        return 2
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_punch_send_burst_to_remote
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.async as aio
import std.net as net
import std.net.punch as punch
import std.vec as vec

async function main() -> int:
    match net.ipv4("127.0.0.1", 0):
        Result.failure:
            return 1
        Result.success as bp_a:
            match net.ipv4("127.0.0.1", 0):
                Result.failure:
                    return 2
                Result.success as bp_b:
                    var addr_a = bp_a.value
                    defer addr_a.release()
                    var addr_b = bp_b.value
                    defer addr_b.release()

                    let bind_a = net.udp_bind(addr_a)
                    match bind_a:
                        Result.failure:
                            return 3
                        Result.success as sp_a:
                            var sa = sp_a.value
                            defer sa.release()

                            let bind_b = net.udp_bind(addr_b)
                            match bind_b:
                                Result.failure:
                                    return 4
                                Result.success as sp_b:
                                    var sb = sp_b.value
                                    defer sb.release()

                                    let la = sa.local_address()
                                    let lb = sb.local_address()
                                    match la:
                                        Result.failure:
                                            return 5
                                        Result.success as lap:
                                            match lb:
                                                Result.failure:
                                                    return 6
                                                Result.success as lbp:
                                                    let addr_copy = lbp.value.copy()
                                                    match addr_copy:
                                                        Result.failure:
                                                            return 7
                                                        Result.success as ac:
                                                            var candidates = vec.Vec[punch.Candidate].create()
                                                            candidates.push(punch.Candidate(
                                                                address = ac.value,
                                                                kind = punch.CandidateKind.local
                                                            ))

                                                            var probe = punch.build_punch_probe()
                                                            defer probe.release()
                                                            let send_result = await sb.send_to(probe.as_span(), lap.value)
                                                            match send_result:
                                                                Result.failure:
                                                                    return 8
                                                                Result.success:
                                                                    pass

                                                            let punch_result = await punch.punch(sa, candidates)
                                                            match punch_result:
                                                                Result.failure:
                                                                    return 9
                                                                Result.success:
                                                                    return 0
    return 99

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-net-punch") do |dir|
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

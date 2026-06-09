# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdNetRpcTest < Minitest::Test
  def test_build_and_parse_rpc_frame
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.binary as bin
import std.bytes as bytes
import std.net.rpc as rpc

function main() -> int:
    # Build payload "hello" = h(104) e(101) l(108) l(108) o(111)
    var pw = bin.Writer.with_capacity(5)
    pw.write_ubyte(104)
    pw.write_ubyte(101)
    pw.write_ubyte(108)
    pw.write_ubyte(108)
    pw.write_ubyte(111)
    var payload = pw.finish()
    defer payload.release()
    var call = rpc.build_call(42, payload.as_span())
    defer call.release()

    let data = call.as_span()
    let id_result = rpc.parse_request_id(data)
    match id_result:
        Result.failure:
            return 1
        Result.success as ip:
            if ip.value != 42:
                return 2

    let remaining = rpc.payload_after_header(data)
    if remaining.len != 5:
        return 3
    if remaining[0] != 104:
        return 4
    if remaining[4] != 111:
        return 5
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_build_reply_is_identical_format
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.binary as bin
import std.bytes as bytes
import std.net.rpc as rpc

function main() -> int:
    var pw = bin.Writer.with_capacity(6)
    pw.write_ubyte(114)
    pw.write_ubyte(101)
    pw.write_ubyte(115)
    pw.write_ubyte(117)
    pw.write_ubyte(108)
    pw.write_ubyte(116)
    var data = pw.finish()
    defer data.release()
    var reply = rpc.build_reply(99, data.as_span())
    defer reply.release()

    let reply_data = reply.as_span()
    let id_result = rpc.parse_request_id(reply_data)
    match id_result:
        Result.failure:
            return 1
        Result.success as ip:
            if ip.value != 99:
                return 2

    let remaining = rpc.payload_after_header(reply_data)
    if remaining.len != 6:
        return 3
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_empty_payload
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.bytes as bytes
import std.net.rpc as rpc

function main() -> int:
    var empty = bytes.Bytes.empty()
    defer empty.release()
    var call = rpc.build_call(1, empty.as_span())
    defer call.release()

    let data = call.as_span()
    # 4-byte header + 0-byte payload = 4 bytes
    if data.len != 4:
        return 1

    let remaining = rpc.payload_after_header(data)
    if remaining.len != 0:
        return 2
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-net-rpc") do |dir|
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

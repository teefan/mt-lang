# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdNetTurnTest < Minitest::Test
  def test_build_allocate_request_header
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.bytes as bytes
import std.net.turn as turn

function main() -> int:
    var tid = zero[array[ubyte, 12]]
    tid[0] = 0x01
    tid[11] = 0xFF

    var request = turn.build_allocate_request(tid)
    defer request.release()
    let data = request.as_span()

    # Header: 20 bytes + 8 byte REQUESTED-TRANSPORT attribute
    if data.len != 28:
        return 1

    # Message type: u16 BE = 0x0003 (allocate request)
    if data[0] != 0x00:
        return 2
    if data[1] != 0x03:
        return 3

    # Message length: u16 BE = 0x0008 (8-byte attribute)
    if data[2] != 0x00:
        return 4
    if data[3] != 0x08:
        return 5

    # Magic cookie at offset 4: 0x2112A442
    if data[4] != 0x21:
        return 6
    if data[5] != 0x12:
        return 7
    if data[6] != 0xA4:
        return 8
    if data[7] != 0x42:
        return 9

    # Transaction ID at offset 8-19
    if data[8] != 0x01:
        return 10
    if data[19] != 0xFF:
        return 11

    # REQUESTED-TRANSPORT attribute at offset 20:
    # Type: 0x0019, Length: 0x0004, Protocol: 0x11 (UDP) + 3 bytes padding
    if data[20] != 0x00:
        return 12
    if data[21] != 0x19:
        return 13
    if data[22] != 0x00:
        return 14
    if data[23] != 0x04:
        return 15
    if data[24] != 0x11:
        return 16
    if data[25] != 0x00:
        return 17
    if data[26] != 0x00:
        return 18
    if data[27] != 0x00:
        return 19

    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_parse_allocate_response
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.bytes as bytes
import std.binary as bin
import std.net as net
import std.net.turn as turn
import std.string as string

function main() -> int:
    var tid = zero[array[ubyte, 12]]
    var i: ptr_uint = 0
    while i < ptr_uint<-12:
        tid[i] = ubyte<-(ptr_uint<-0xAA + i)
        i += 1

    # Build mock allocate success response:
    # Header: 20 bytes (msg_type=0x0103, msg_len=12, cookie, tid)
    var w = bin.Writer.with_capacity(32)
    w.write_ubyte(0x01)
    w.write_ubyte(0x03)
    w.write_ubyte(0x00)
    w.write_ubyte(12)

    w.write_ubyte(0x21)
    w.write_ubyte(0x12)
    w.write_ubyte(0xA4)
    w.write_ubyte(0x42)

    var j: ptr_uint = 0
    while j < ptr_uint<-12:
        w.write_ubyte(tid[j])
        j += 1

    # XOR-RELAYED-ADDRESS (type 0x0016, len 8)
    w.write_ubyte(0x00)
    w.write_ubyte(0x16)
    w.write_ubyte(0x00)
    w.write_ubyte(8)
    w.write_ubyte(0)
    w.write_ubyte(1)

    # Relay port: 9999, XOR'd: 0x270F ^ 0x2112 = 0x061D
    w.write_ubyte(0x06)
    w.write_ubyte(0x1D)

    # Relay IP: 192.0.2.1 = 0xC0000201 ^ 0x2112A442 = 0xE112A643
    w.write_ubyte(0xE1)
    w.write_ubyte(0x12)
    w.write_ubyte(0xA6)
    w.write_ubyte(0x43)

    var packet = w.finish()
    defer packet.release()

    let parse_result = turn.parse_allocate_response(packet, tid)
    match parse_result:
        Result.failure as pp:
            return 1
        Result.success as rp:
            var alloc = rp.value
            defer alloc.release()
            let host_result = alloc.relay_address.host()
            match host_result:
                Result.failure:
                    return 2
                Result.success as hp:
                    var host = hp.value
                    defer host.release()
                    let addr_str = host.as_str()
                    if addr_str != "192.0.2.1":
                        return 3
                    return 0
    return 99

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-net-turn") do |dir|
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

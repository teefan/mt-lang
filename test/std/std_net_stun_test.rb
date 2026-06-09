# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdNetStunTest < Minitest::Test
  def test_stun_binding_request_has_valid_header
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.bytes as bytes
import std.net.stun as stun

function main() -> int:
    var tid = zero[array[ubyte, 12]]
    tid[0] = 1
    tid[1] = 2
    tid[2] = 3
    tid[11] = 0xff

    var request = stun.build_binding_request(tid)
    defer request.release()

    let data = request.as_span()

    # Header is 20 bytes
    if data.len != 20:
        return 1

    # Message type should be 0x0001 (binding request) in big-endian
    if data[0] != 0x00:
        return 2
    if data[1] != 0x01:
        return 3

    # Message length should be 0
    if data[2] != 0x00:
        return 4
    if data[3] != 0x00:
        return 5

    # Magic cookie at offset 4: 0x2112A442 in big-endian
    if data[4] != 0x21:
        return 6
    if data[5] != 0x12:
        return 7
    if data[6] != 0xA4:
        return 8
    if data[7] != 0x42:
        return 9

    # Transaction ID at offset 8
    if data[8] != 1:
        return 10
    if data[9] != 2:
        return 11
    if data[10] != 3:
        return 12
    if data[11] != 0:
        return 13
    if data[19] != 0xff:
        return 14

    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_parse_mock_binding_response
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.bytes as bytes
import std.binary as bin
import std.net as net
import std.net.stun as stun
import std.string as string

function main() -> int:
    var tid = zero[array[ubyte, 12]]
    var i: ptr_uint = 0
    while i < ptr_uint<-12:
        tid[i] = ubyte<-(ptr_uint<-0xAA + i)
        i += 1

    # Build a mock binding success response (all fields in big-endian / network byte order)
    var w = bin.Writer.with_capacity(32)
    # Message Type: u16 BE = 0x0101
    w.write_ubyte(0x01)
    w.write_ubyte(0x01)
    # Message Length: u16 BE = 12 (one XOR-MAPPED-ADDRESS attribute: 4 header + 8 data)
    w.write_ubyte(0x00)
    w.write_ubyte(12)
    # Magic Cookie: u32 BE = 0x2112A442
    w.write_ubyte(0x21)
    w.write_ubyte(0x12)
    w.write_ubyte(0xA4)
    w.write_ubyte(0x42)
    # Transaction ID: 12 bytes
    var j: ptr_uint = 0
    while j < ptr_uint<-12:
        w.write_ubyte(tid[j])
        j += 1

    # XOR-MAPPED-ADDRESS attribute
    # Type: u16 BE = 0x0020
    w.write_ubyte(0x00)
    w.write_ubyte(0x20)
    # Length: u16 BE = 8
    w.write_ubyte(0x00)
    w.write_ubyte(8)
    # Reserved: 0
    w.write_ubyte(0)
    # Family: IPv4 = 0x01
    w.write_ubyte(1)
    # X-Port: 12345 xor 0x2112 = 0x3039 xor 0x2112 = 0x112B
    w.write_ubyte(0x11)
    w.write_ubyte(0x2B)
    # X-Address: 192.0.2.1 = 0xC0000201 xor 0x2112A442 = 0xE112A643
    w.write_ubyte(0xE1)
    w.write_ubyte(0x12)
    w.write_ubyte(0xA6)
    w.write_ubyte(0x43)

    var packet = w.finish()
    defer packet.release()

    let parse_result = stun.parse_binding_response(packet, tid)
    match parse_result:
        Result.failure as p:
            return 1
        Result.success as rp:
            var result = rp.value
            defer result.release()
            let host_result = result.public_address.host()
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
    Dir.mktmpdir("milk-tea-std-net-stun") do |dir|
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

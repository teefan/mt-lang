# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdZstdTest < Minitest::Test
  def test_host_runtime_compresses_and_decompresses_zstd
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.str as text
import std.zstd as zstd

function main() -> int:
    let input = "milk tea zstd roundtrip milk tea zstd roundtrip"
    let input_bytes = unsafe: ptr[ubyte]<-input.data
    let bound = zstd.compress_bound(input.len)
    if zstd.is_error(bound) != 0:
        return 1
    if bound > ptr_uint<-4096:
        return 2

    var compressed = zero[array[ubyte, 4096]]
    let compressed_size = zstd.compress(
        unsafe: ptr[void]<-ptr_of(compressed[0]),
        ptr_uint<-4096,
        unsafe: const_ptr[void]<-input_bytes,
        input.len,
        zstd.default_c_level(),
    )
    if zstd.is_error(compressed_size) != 0:
        return 3
    if compressed_size == 0 or compressed_size > ptr_uint<-4096:
        return 4

    var decoded = zero[array[ubyte, 4096]]
    let decoded_size = zstd.decompress(
        unsafe: ptr[void]<-ptr_of(decoded[0]),
        ptr_uint<-4096,
        unsafe: const_ptr[void]<-ptr_of(compressed[0]),
        compressed_size,
    )
    if zstd.is_error(decoded_size) != 0:
        return 5
    if decoded_size != input.len:
        return 6

    match text.utf8_byte_span_as_str(unsafe: span[ubyte](data = ptr_of(decoded[0]), len = decoded_size)):
        Option.none:
            return 7
        Option.some as payload:
            if not payload.value.equal(input):
                return 8

    let invalid_size = zstd.decompress(
        unsafe: ptr[void]<-ptr_of(decoded[0]),
        ptr_uint<-4096,
        unsafe: const_ptr[void]<-input_bytes,
        input.len,
    )
    if zstd.is_error(invalid_size) == 0:
        return 9

    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_includes result.link_flags, "-lzstd"
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-zstd") do |dir|
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

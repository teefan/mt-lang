# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdGzipTest < Minitest::Test
  def test_host_runtime_compresses_and_decompresses_gzip
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.gzip as gzip
import std.str as text

function main() -> int:
    let input = \"milk tea gzip roundtrip milk tea gzip roundtrip\"
    let input_bytes = unsafe: span[ubyte](data = ptr[ubyte]<-input.data, len = input.len)

    match gzip.compress_bytes(input_bytes):
        Result.failure as compress_error_payload:
            var error = compress_error_payload.error
            defer error.release()
            return 1
        Result.success as compress_payload:
            var compressed = compress_payload.value
            defer compressed.release()
            if compressed.len == 0:
                return 2

            match gzip.decompress_bytes(compressed.as_span()):
                Result.failure as decompress_error_payload:
                    var error = decompress_error_payload.error
                    defer error.release()
                    return 3
                Result.success as decompress_payload:
                    var decompressed = decompress_payload.value
                    defer decompressed.release()
                    match text.utf8_byte_span_as_str(decompressed.as_span()):
                        Option.none:
                            return 4
                        Option.some as decoded_payload:
                            if not decoded_payload.value.equal(input):
                                return 5

    let invalid = unsafe: span[ubyte](data = ptr[ubyte]<-input.data, len = input.len)
    match gzip.decompress_bytes(invalid):
        Result.success as invalid_success_payload:
            var broken = invalid_success_payload.value
            defer broken.release()
            return 6
        Result.failure as invalid_error_payload:
            var error = invalid_error_payload.error
            defer error.release()
            if error.message.as_str().len == 0:
                return 7

    match gzip.compress_bytes_with_level(input_bytes, 10):
        Result.success as invalid_level_success_payload:
            var unexpected = invalid_level_success_payload.value
            defer unexpected.release()
            return 8
        Result.failure as invalid_level_error_payload:
            var error = invalid_level_error_payload.error
            defer error.release()
            if error.message.as_str().len == 0:
                return 9

    let empty_input = unsafe: span[ubyte](data = ptr[ubyte]<-input.data, len = 0)
    match gzip.compress_bytes(empty_input):
        Result.failure as empty_error_payload:
            var error = empty_error_payload.error
            defer error.release()
            return 10
        Result.success as empty_success_payload:
            var empty = empty_success_payload.value
            defer empty.release()
            match gzip.decompress_bytes(empty.as_span()):
                Result.failure as empty_decode_error_payload:
                    var error = empty_decode_error_payload.error
                    defer error.release()
                    return 11
                Result.success as empty_decode_payload:
                    var decoded = empty_decode_payload.value
                    defer decoded.release()
                    if decoded.len != 0:
                        return 12

    return 0
    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_includes result.link_flags, "-lz"
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-gzip") do |dir|
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

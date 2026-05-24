# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdCurlRuntimeTest < Minitest::Test
  def test_host_runtime_imports_curl_runtime_convenience_module
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.curl.runtime as curl_runtime

function main() -> int:
    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_includes result.link_flags, "-lcurl"
  end

  def test_host_runtime_fetches_local_http_body_as_bytes
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-std-curl-runtime") do |root|
      File.write(File.join(root, "hello.txt"), "hello from curl runtime\n")

      with_static_http_server(root) do |base_url|
        source = <<~MT

import std.curl.runtime as runtime

function main() -> int:
    let response = runtime.get_bytes(\"#{base_url}/hello.txt\")
    match response:
        Result.failure as failure:
            let _ = runtime.code_message(failure.error)
            return 1
        Result.success as payload:
            var response_body = payload.value
            let body_text = response_body.as_str() else:
                return 2
            if body_text != \"hello from curl runtime\\n\":
                return 3
            response_body.release()

    return 0

        MT

        result = run_program(source, compiler:)

        assert_equal "", result.stdout
        assert_equal "", result.stderr
        assert_equal 0, result.exit_status
        assert_includes result.link_flags, "-lcurl"
      end
    end
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-curl-runtime-program") do |dir|
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

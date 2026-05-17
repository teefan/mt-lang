# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdHttpTest < Minitest::Test
  def test_http_get_fetches_response_status_headers_and_body
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-std-http-fixture") do |root|
      File.write(File.join(root, "message.txt"), "hello over http\n")

      with_static_http_server(root) do |base_url|
        source = [
          "import std.bytes as bytes",
          "import std.http as http",
          "import std.maybe as maybe",
          "import std.status as status",
          "import std.str as text",
          "",
          "async function main() -> int:",
          "    let response_result = await http.get(\"#{base_url}/message.txt?cache=1\")",
          "    match response_result:",
          "        status.Status.err as payload:",
          "            var error = payload.error",
          "            defer error.release()",
          "            return 1",
          "        status.Status.ok as payload:",
          "            var response = payload.value",
          "            defer response.release()",
          "            if response.status_code != 200:",
          "                return 2",
          "            match response.header(\"content-type\"):",
          "                maybe.Maybe.none:",
          "                    return 3",
          "                maybe.Maybe.some as header_payload:",
          "                    if not header_payload.value.starts_with(\"text/plain\"):",
          "                        return 4",
          "            match response.body.as_str():",
          "                maybe.Maybe.none:",
          "                    return 5",
          "                maybe.Maybe.some as body_payload:",
          "                    if not body_payload.value.equal(\"hello over http\\n\"):",
          "                        return 6",
          "            return 0",
          "",
        ].join("\n")

        result = run_program(source, compiler:)

        assert_equal "", result.stdout
        assert_equal "", result.stderr
        assert_equal 0, result.exit_status
        assert_includes result.link_flags, "-luv"
      end
    end
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-http") do |dir|
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

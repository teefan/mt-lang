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
          "",
          "",
          "import std.str as text",
          "",
          "async function main() -> int:",
          "    let response_result = await http.get(\"#{base_url}/message.txt?cache=1\")",
          "    match response_result:",
          "        Result.failure as payload:",
          "            var error = payload.error",
          "            defer error.release()",
          "            return 1",
          "        Result.success as payload:",
          "            var response = payload.value",
          "            defer response.release()",
          "            if response.status_code != 200:",
          "                return 2",
          "            match response.header(\"content-type\"):",
          "                Option.none:",
          "                    return 3",
          "                Option.some as header_payload:",
          "                    if not header_payload.value.starts_with(\"text/plain\"):",
          "                        return 4",
          "            match response.body.as_str():",
          "                Option.none:",
          "                    return 5",
          "                Option.some as body_payload:",
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

  def test_http_request_sends_method_headers_and_body
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    requests = Queue.new

    with_http_test_server(lambda do |client|
      requests << read_http_request(client)
      body = "accepted\n"
      client.write("HTTP/1.1 201 Created\r\n")
      client.write("Content-Type: text/plain; charset=utf-8\r\n")
      client.write("Content-Length: #{body.bytesize}\r\n")
      client.write("Connection: close\r\n")
      client.write("\r\n")
      client.write(body)
    end) do |base_url|
      source = [
        "import std.http as http",
        "",
        "",
        "import std.str as text",
        "",
        "async function main() -> int:",
        "    var headers = array[http.RequestHeader, 2](",
        "        http.RequestHeader(name = \"Content-Type\", value = \"application/x-www-form-urlencoded\"),",
        "        http.RequestHeader(name = \"X-Test\", value = \"milk-tea\"),",
        "    )",
        "    let response_result = await http.request(",
        "        \"#{base_url}/submit\",",
        "        \"POST\",",
        "        headers,",
        "        Option[span[ubyte]].some(value = text.as_byte_span(\"name=milk+tea\")),",
        "    )",
        "    match response_result:",
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 1",
        "        Result.success as payload:",
        "            var response = payload.value",
        "            defer response.release()",
        "            if response.status_code != 201:",
        "                return 2",
        "            match response.body.as_str():",
        "                Option.none:",
        "                    return 3",
        "                Option.some as body_payload:",
        "                    if not body_payload.value.equal(\"accepted\\n\"):",
        "                        return 4",
        "            return 0",
        "",
      ].join("\n")

      result = run_program(source, compiler:)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
      assert_includes result.link_flags, "-luv"
    end

    request = requests.pop

    assert_equal "POST", request[:method]
    assert_equal "/submit", request[:path]
    assert_equal "application/x-www-form-urlencoded", request[:headers].fetch("content-type")
    assert_equal "milk-tea", request[:headers].fetch("x-test")
    assert_equal "milk-tea/std.http", request[:headers].fetch("user-agent")
    assert_equal "close", request[:headers].fetch("connection")
    assert_equal "13", request[:headers].fetch("content-length")
    assert_equal "name=milk+tea", request[:body]
    assert_match(/127\.0\.0\.1:\d+/, request[:headers].fetch("host"))
  end

  def test_http_get_decodes_chunked_body
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    with_http_test_server(lambda do |client|
      read_http_request(client)
      client.write("HTTP/1.1 200 OK\r\n")
      client.write("Content-Type: text/plain; charset=utf-8\r\n")
      client.write("Transfer-Encoding: chunked\r\n")
      client.write("Connection: close\r\n")
      client.write("\r\n")
      client.write("6\r\nhello \r\n")
      client.write("8\r\nchunked\n\r\n")
      client.write("0\r\n\r\n")
    end) do |base_url|
      source = [
        "import std.http as http",
        "",
        "",
        "import std.str as text",
        "",
        "async function main() -> int:",
        "    let response_result = await http.get(\"#{base_url}/chunked\")",
        "    match response_result:",
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 1",
        "        Result.success as payload:",
        "            var response = payload.value",
        "            defer response.release()",
        "            if response.status_code != 200:",
        "                return 2",
        "            match response.body.as_str():",
        "                Option.none:",
        "                    return 3",
        "                Option.some as body_payload:",
        "                    if not body_payload.value.equal(\"hello chunked\\n\"):",
        "                        return 4",
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

  def test_http_https_urls_fail_at_transport_dispatch
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "import std.http as http",
      "",
      "import std.str as text",
      "",
      "async function main() -> int:",
      "    let response_result = await http.get(\"https://example.com/resource\")",
      "    match response_result:",
      "        Result.failure as payload:",
      "            var error = payload.error",
      "            defer error.release()",
      "            if not error.message.as_str().equal(\"https transport is not implemented yet\"):",
      "                return 1",
      "            return 0",
      "        Result.success as payload:",
      "            var response = payload.value",
      "            defer response.release()",
      "            return 2",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  private

  def with_http_test_server(handler)
    server = TCPServer.new("127.0.0.1", 0)
    errors = Queue.new

    thread = Thread.new do
      loop do
        client = server.accept
        handler.call(client)
      rescue IOError, Errno::EBADF
        break
      rescue StandardError => e
        errors << e
      ensure
        client&.close
      end
    end

    yield "http://127.0.0.1:#{server.local_address.ip_port}"
  ensure
    server&.close
    thread&.join(1)
    raise errors.pop unless errors.nil? || errors.empty?
  end

  def read_http_request(client)
    request_line = client.gets
    raise "missing request line" unless request_line

    method, path, version = request_line.strip.split(" ", 3)
    headers = {}

    while (line = client.gets)
      break if line == "\r\n"

      name, value = line.split(":", 2)
      raise "malformed request header: #{line.inspect}" if value.nil?

      headers[name.downcase] = value.strip
    end

    body_length = headers.fetch("content-length", "0").to_i
    body = body_length.zero? ? "" : client.read(body_length)

    {
      method:,
      path:,
      version:,
      headers:,
      body:
    }
  end

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

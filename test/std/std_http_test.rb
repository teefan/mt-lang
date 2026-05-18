# frozen_string_literal: true

require "openssl"
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

  def test_http_https_get_fetches_response_status_headers_and_body
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    requests = Queue.new

    with_https_test_server(lambda do |client|
      requests << read_http_request(client)
      body = "hello over https\n"
      client.write("HTTP/1.1 200 OK\r\n")
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
        "    let response_result = await http.get(\"#{base_url}/secure.txt?cache=1\")",
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
        "                    if not body_payload.value.equal(\"hello over https\\n\"):",
        "                        return 6",
        "            return 0",
        "",
      ].join("\n")

      result = run_program(source, compiler:)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
      assert_includes result.link_flags, "-lssl"
      assert_includes result.link_flags, "-lcrypto"
    end

    request = requests.pop

    assert_equal "GET", request[:method]
    assert_equal "/secure.txt?cache=1", request[:path]
    assert_equal "milk-tea/std.http", request[:headers].fetch("user-agent")
    assert_equal "close", request[:headers].fetch("connection")
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

  def with_https_test_server(handler)
    Dir.mktmpdir("milk-tea-std-https") do |dir|
      materials = build_https_server_materials(dir)
      server = TCPServer.new("127.0.0.1", 0)
      errors = Queue.new

      context = OpenSSL::SSL::SSLContext.new
      context.cert = materials.fetch(:cert)
      context.key = materials.fetch(:key)
      context.min_version = OpenSSL::SSL::TLS1_2_VERSION if context.respond_to?(:min_version=)

      ssl_server = OpenSSL::SSL::SSLServer.new(server, context)
      thread = Thread.new do
        loop do
          client = ssl_server.accept
          handler.call(client)
        rescue IOError, Errno::EBADF
          break
        rescue OpenSSL::SSL::SSLError => e
          break if server.closed?

          errors << e
        rescue StandardError => e
          errors << e
        ensure
          client&.close
        end
      end

      with_modified_env("SSL_CERT_FILE" => materials.fetch(:ca_path)) do
        yield "https://localhost:#{server.local_address.ip_port}"
      end
    ensure
      server&.close
      thread&.join(1)
      raise errors.pop unless errors.nil? || errors.empty?
    end
  end

  def build_https_server_materials(dir)
    ca_key = OpenSSL::PKey::RSA.new(2048)
    ca_cert = build_test_certificate(
      subject_name: "Milk Tea Test CA",
      key: ca_key,
      issuer_cert: nil,
      issuer_key: nil,
      serial: 1,
      extensions: [
        ["basicConstraints", "CA:TRUE", true],
        ["keyUsage", "keyCertSign,cRLSign", true],
        ["subjectKeyIdentifier", "hash"],
        ["authorityKeyIdentifier", "keyid:always,issuer:always"]
      ]
    )

    server_key = OpenSSL::PKey::RSA.new(2048)
    server_cert = build_test_certificate(
      subject_name: "localhost",
      key: server_key,
      issuer_cert: ca_cert,
      issuer_key: ca_key,
      serial: 2,
      extensions: [
        ["basicConstraints", "CA:FALSE", true],
        ["keyUsage", "digitalSignature,keyEncipherment", true],
        ["extendedKeyUsage", "serverAuth", true],
        ["subjectAltName", "DNS:localhost"],
        ["subjectKeyIdentifier", "hash"],
        ["authorityKeyIdentifier", "keyid:always,issuer:always"]
      ]
    )

    ca_path = File.join(dir, "ca.pem")
    File.write(ca_path, ca_cert.to_pem)

    {
      cert: server_cert,
      key: server_key,
      ca_path:
    }
  end

  def build_test_certificate(subject_name:, key:, issuer_cert:, issuer_key:, serial:, extensions:)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = serial
    cert.subject = OpenSSL::X509::Name.parse("/CN=#{subject_name}")
    cert.issuer = issuer_cert ? issuer_cert.subject : cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600

    extension_factory = OpenSSL::X509::ExtensionFactory.new
    extension_factory.subject_certificate = cert
    extension_factory.issuer_certificate = issuer_cert || cert
    extensions.each do |name, value, critical|
      cert.add_extension(extension_factory.create_extension(name, value, critical))
    end

    cert.sign(issuer_key || key, OpenSSL::Digest::SHA256.new)
    cert
  end

  def with_modified_env(values)
    missing = Object.new
    previous = {}

    values.each do |name, value|
      previous[name] = ENV.key?(name) ? ENV[name] : missing
      value.nil? ? ENV.delete(name) : ENV[name] = value
    end

    yield
  ensure
    previous.each do |name, value|
      value.equal?(missing) ? ENV.delete(name) : ENV[name] = value
    end
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

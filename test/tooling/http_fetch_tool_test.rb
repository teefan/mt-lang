# frozen_string_literal: true

require "openssl"
require "tmpdir"
require_relative "../test_helper"

class MilkTeaHttpFetchToolTest < Minitest::Test
  def test_fetch_to_file_follows_relative_https_redirects
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-http-fetch-tool") do |dir|
      body_path = File.join(dir, "response.body")
      requests = Queue.new

      with_https_test_server(lambda do |client|
        request = read_http_request(client)
        requests << request

        if request[:path] == "/redirect"
          client.write("HTTP/1.1 302 Found\r\n")
          client.write("Location: /final.txt\r\n")
          client.write("Content-Length: 0\r\n")
          client.write("Connection: close\r\n")
          client.write("\r\n")
          next
        end

        body = "redirected over https\n"
        client.write("HTTP/1.1 200 OK\r\n")
        client.write("Content-Type: text/plain; charset=utf-8\r\n")
        client.write("Content-Length: #{body.bytesize}\r\n")
        client.write("Connection: close\r\n")
        client.write("\r\n")
        client.write(body)
      end) do |base_url|
        response = nil
        with_modified_env("SSL_CERT_FILE" => @ca_path) do
          response = MilkTea::HttpFetchTool.fetch_to_file(url: "#{base_url}/redirect", body_path:, cc: compiler)
        end

        assert_equal 200, response.status_code
        assert_equal "OK", response.reason
        assert_equal "", response.location
        assert_equal "redirected over https\n", File.binread(body_path)
      end

      first_request = requests.pop
      second_request = requests.pop
      assert_equal "/redirect", first_request[:path]
      assert_equal "/final.txt", second_request[:path]
    end
  end

  private

  def with_https_test_server(handler)
    Dir.mktmpdir("milk-tea-http-fetch-https") do |dir|
      materials = build_https_server_materials(dir)
      @ca_path = materials.fetch(:ca_path)
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

      yield "https://localhost:#{server.local_address.ip_port}"
    ensure
      server&.close
      thread&.join(1)
      @ca_path = nil
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

    {
      method:,
      path:,
      version:,
      headers:
    }
  end

  def compiler_available?(compiler)
    return File.executable?(compiler) if compiler.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, compiler)
      File.file?(candidate) && File.executable?(candidate)
    end
  end
end

# frozen_string_literal: true

require "open3"
require "openssl"
require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdHttpsExampleTest < Minitest::Test
  def test_https_example_runs_and_kept_c_rebuilds_cleanly
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-std-https-example") do |dir|
      source_path = File.join(dir, "std_https_example.mt")
      output_path = File.join(dir, "std_https_example")
      keep_c_path = File.join(dir, "std_https_example.c")
      strict_output = File.join(dir, "std_https_example_strict")
      requests = Queue.new

      File.write(source_path, File.read(example_source_path))

      with_https_test_server(lambda do |client|
        requests << read_http_request(client)
        body = "hello over https example\n"
        client.write("HTTP/1.1 200 OK\r\n")
        client.write("Content-Type: text/plain; charset=utf-8\r\n")
        client.write("Content-Length: #{body.bytesize}\r\n")
        client.write("Connection: close\r\n")
        client.write("\r\n")
        client.write(body)
      end) do |base_url, ca_path|
        build_result = MilkTea::Build.build(source_path, output_path:, cc: compiler, keep_c_path: keep_c_path)

        assert_equal File.expand_path(output_path), build_result.output_path
        assert_equal File.expand_path(keep_c_path), build_result.c_path
        assert File.exist?(keep_c_path)
        assert_includes build_result.link_flags, "-lssl"
        assert_includes build_result.link_flags, "-lcrypto"

        run_stdout, run_stderr, run_status = Open3.capture3(
          { "SSL_CERT_FILE" => ca_path },
          build_result.output_path,
          "#{base_url}/message.txt?cache=1",
          "hello over https example\n",
          chdir: dir,
        )

        assert run_status.success?, [run_stdout, run_stderr].reject(&:empty?).join
        assert_equal "", run_stdout
        assert_equal "", run_stderr

        stdout, stderr, status = Open3.capture3(
          compiler,
          "-std=c11",
          "-Wall",
          "-Wextra",
          "-I#{File.join(MilkTea.root, 'std', 'c')}",
          keep_c_path,
          "-o",
          strict_output,
          *build_result.link_flags,
        )

        assert status.success?, [stdout, stderr].reject(&:empty?).join
        assert_equal "", stdout
        assert_equal "", stderr

        rerun_stdout, rerun_stderr, rerun_status = Open3.capture3(
          { "SSL_CERT_FILE" => ca_path },
          strict_output,
          "#{base_url}/message.txt?cache=1",
          "hello over https example\n",
          chdir: dir,
        )

        assert rerun_status.success?, [rerun_stdout, rerun_stderr].reject(&:empty?).join
        assert_equal "", rerun_stdout
        assert_equal "", rerun_stderr
      end

      request = requests.pop
      assert_equal "GET", request[:method]
      assert_equal "/message.txt?cache=1", request[:path]
      assert_equal "milk-tea/std.http", request[:headers].fetch("user-agent")
      assert_equal "close", request[:headers].fetch("connection")
    end
  end

  private

  def example_source_path
    File.expand_path("../../tmp/std_https_example.mt", __dir__)
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

      yield "https://localhost:#{server.local_address.ip_port}", materials.fetch(:ca_path)
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

  def compiler_available?(compiler)
    return File.executable?(compiler) if compiler.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, compiler)
      File.file?(candidate) && File.executable?(candidate)
    end
  end
end

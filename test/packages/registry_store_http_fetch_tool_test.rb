# frozen_string_literal: true

require "openssl"
require "tmpdir"
require_relative "../test_helper"

class MilkTeaPackageRegistryStoreHttpFetchToolTest < Minitest::Test
  def test_available_versions_and_sync_can_download_from_https_upstream
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-package-registry-store-https") do |dir|
      package_root = File.join(dir, "packages", "ui")
      registry_root = File.join(dir, "registry")
      upstream_root = File.join(dir, "upstream-registry")

      FileUtils.mkdir_p(File.join(package_root, "src", "teefan", "ui"))
      File.write(File.join(package_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.2.3"
        kind = "library"
        source_root = "src"
      TOML
      File.write(File.join(package_root, "src", "teefan", "ui", "layout.mt"), "")

      publisher = MilkTea::PackageRegistryStore.new(root: registry_root, upstream_root: upstream_root)
      publisher.publish(package_root, target: :upstream)

      with_static_https_server(upstream_root) do |base_url|
        store = MilkTea::PackageRegistryStore.new(root: registry_root, upstream_root: base_url)

        assert_equal ["1.2.3"], store.available_versions("teefan.ui")

        sync_result = store.sync("teefan.ui", "1.2.3")

        assert_equal File.expand_path(File.join(registry_root, "packages", "teefan.ui", "1.2.3")), sync_result.path
        assert store.published?("teefan.ui", "1.2.3")
        assert File.file?(File.join(sync_result.path, "src", "teefan", "ui", "layout.mt"))
        assert File.file?(File.join(registry_root, "packages", "teefan.ui", "1.2.3.tar.gz"))
      end
    end
  end

  private

  def with_static_https_server(root)
    Dir.mktmpdir("milk-tea-static-https") do |dir|
      materials = build_https_server_materials(dir)
      server = TCPServer.new("127.0.0.1", 0)
      root_path = File.expand_path(root)
      errors = Queue.new

      context = OpenSSL::SSL::SSLContext.new
      context.cert = materials.fetch(:cert)
      context.key = materials.fetch(:key)
      context.min_version = OpenSSL::SSL::TLS1_2_VERSION if context.respond_to?(:min_version=)

      ssl_server = OpenSSL::SSL::SSLServer.new(server, context)
      thread = Thread.new do
        loop do
          client = ssl_server.accept
          serve_static_http_request(client, root_path)
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

  def compiler_available?(compiler)
    return File.executable?(compiler) if compiler.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, compiler)
      File.file?(candidate) && File.executable?(candidate)
    end
  end
end

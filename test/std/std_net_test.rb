# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdNetTest < Minitest::Test
  def test_host_runtime_resolves_numeric_ipv4_and_formats_host
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "import std.async as aio",
      "import std.net as net",
      "import std.status as status",
      "",
      "async function main() -> int:",
      "    let resolved = await net.resolve_first(\"127.0.0.1\", \"8080\")",
      "    match resolved:",
      "        status.Status.err as payload:",
      "            var error = payload.error",
      "            defer error.release()",
      "            return 1",
      "        status.Status.ok as payload:",
      "            var address = payload.value",
      "            defer address.release()",
      "            match address.host():",
      "                status.Status.err as host_error_payload:",
      "                    var error = host_error_payload.error",
      "                    defer error.release()",
      "                    return 2",
      "                status.Status.ok as host_payload:",
      "                    var host = host_payload.value",
      "                    defer host.release()",
      "                    if host.as_str() != \"127.0.0.1\":",
      "                        return 3",
      "                    return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  def test_host_runtime_constructs_literal_ipv6_address
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "import std.net as net",
      "import std.status as status",
      "",
      "function main() -> int:",
      "    match net.ipv6(\"::1\", 443):",
      "        status.Status.err as payload:",
      "            var error = payload.error",
      "            defer error.release()",
      "            return 1",
      "        status.Status.ok as payload:",
      "            var address = payload.value",
      "            defer address.release()",
      "            match address.host():",
      "                status.Status.err as host_error_payload:",
      "                    var error = host_error_payload.error",
      "                    defer error.release()",
      "                    return 2",
      "                status.Status.ok as host_payload:",
      "                    var host = host_payload.value",
      "                    defer host.release()",
      "                    if host.as_str() != \"::1\":",
      "                        return 3",
      "                    return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  def test_tcp_runtime_connects_and_accepts_local_listener
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "import std.async as aio",
      "import std.net as net",
      "import std.status as status",
      "",
      "function expect_host(address_result: status.Status[net.SocketAddress, net.Error], expected: str, failure_code: int) -> int:",
      "    match address_result:",
      "        status.Status.err as payload:",
      "            var error = payload.error",
      "            defer error.release()",
      "            return failure_code",
      "        status.Status.ok as payload:",
      "            var address = payload.value",
      "            defer address.release()",
      "            match address.host():",
      "                status.Status.err as host_error_payload:",
      "                    var error = host_error_payload.error",
      "                    defer error.release()",
      "                    return failure_code + 1",
      "                status.Status.ok as host_payload:",
      "                    var host = host_payload.value",
      "                    defer host.release()",
      "                    if host.as_str() != expected:",
      "                        return failure_code + 2",
      "                    return 0",
      "",
      "async function main() -> int:",
      "    match net.ipv4(\"127.0.0.1\", 0):",
      "        status.Status.err as payload:",
      "            var error = payload.error",
      "            defer error.release()",
      "            return 1",
      "        status.Status.ok as payload:",
      "            var bind_address = payload.value",
      "            defer bind_address.release()",
      "            match net.listen(bind_address, 16):",
      "                status.Status.err as listen_error_payload:",
      "                    var error = listen_error_payload.error",
      "                    defer error.release()",
      "                    return 2",
      "                status.Status.ok as listen_payload:",
      "                    var listener = listen_payload.value",
      "                    defer listener.release()",
      "                    match listener.local_address():",
      "                        status.Status.err as local_error_payload:",
      "                            var error = local_error_payload.error",
      "                            defer error.release()",
      "                            return 3",
      "                        status.Status.ok as local_payload:",
      "                            var local_address = local_payload.value",
      "                            defer local_address.release()",
      "                            let connected = await net.connect(local_address)",
      "                            match connected:",
      "                                status.Status.err as connect_error_payload:",
      "                                    var error = connect_error_payload.error",
      "                                    defer error.release()",
      "                                    return 4",
      "                                status.Status.ok as connect_payload:",
      "                                    var client = connect_payload.value",
      "                                    defer client.release()",
      "                                    let accepted = await listener.accept()",
      "                                    match accepted:",
      "                                        status.Status.err as accept_error_payload:",
      "                                            var error = accept_error_payload.error",
      "                                            defer error.release()",
      "                                            return 5",
      "                                        status.Status.ok as accept_payload:",
      "                                            var server = accept_payload.value",
      "                                            defer server.release()",
      "                                            let client_peer_status = expect_host(client.peer_address(), \"127.0.0.1\", 6)",
      "                                            if client_peer_status != 0:",
      "                                                return client_peer_status",
      "                                            let server_peer_status = expect_host(server.peer_address(), \"127.0.0.1\", 9)",
      "                                            if server_peer_status != 0:",
      "                                                return server_peer_status",
      "                                            let server_local_status = expect_host(server.local_address(), \"127.0.0.1\", 12)",
      "                                            if server_local_status != 0:",
      "                                                return server_local_status",
      "                                            return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-net") do |dir|
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

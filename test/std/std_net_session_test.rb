# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdNetSessionTest < Minitest::Test
  def test_client_handshake_and_message_exchange
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.async as aio
import std.net as net
import std.net.session as sess
import std.str as text

async function main() -> int:
    let bind_result = net.ipv4("127.0.0.1", 0)
    match bind_result:
        Result.failure:
            return 1
        Result.success as bind_payload:
            var server_addr = bind_payload.value
            defer server_addr.release()
            let config = sess.Config.default(1024)
            let listen_result = sess.listen(server_addr, config)
            match listen_result:
                Result.failure:
                    return 2
                Result.success as listen_payload:
                    var server = listen_payload.value
                    defer server.release()
                    match server.local_address():
                        Result.failure:
                            return 3
                        Result.success as local_payload:
                            var resolved = local_payload.value
                            defer resolved.release()
                            match net.ipv4("127.0.0.1", 0):
                                Result.failure:
                                    return 4
                                Result.success as client_local:
                                    var cl = client_local.value
                                    defer cl.release()
                                    let conn_result = await sess.connect(cl, resolved, config)
                                    match conn_result:
                                        Result.failure:
                                            return 5
                                        Result.success as conn_payload:
                                            var client = conn_payload.value
                                            defer client.release()

                                            var frame: uint = 0
                                            while frame < 60:
                                                await client.tick(frame)
                                                await server.tick(frame)
                                                let server_recv = await server.recv()
                                                match server_recv:
                                                    Result.failure:
                                                        pass
                                                    Result.success as srv:
                                                        match srv.value:
                                                            Option.some as sm:
                                                                var ev = sm.value
                                                                if ev.kind == sess.PeerEventKind.user_data:
                                                                    ev.payload.release()
                                                                var drain_frame: uint = 0
                                                                while drain_frame < 10:
                                                                    await client.tick(frame + drain_frame)
                                                                    await server.tick(frame + drain_frame + 1)
                                                                    let client_recv = await client.recv()
                                                                    match client_recv:
                                                                        Result.success as crv:
                                                                            match crv.value:
                                                                                Option.some:
                                                                                    pass
                                                                                Option.none:
                                                                                    pass
                                                                        Result.failure:
                                                                            pass
                                                                    if client.state() == sess.ConnectionState.connected:
                                                                        return 0
                                                                    drain_frame += 1
                                                                break
                                                            Option.none:
                                                                pass
                                                frame += 1
                                            return int<-client.state()
    return 99

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-net-session") do |dir|
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

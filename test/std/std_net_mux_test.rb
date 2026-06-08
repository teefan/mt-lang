# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdNetMuxTest < Minitest::Test
  def test_muxed_exchanges_multiplexed_messages
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.async as aio
import std.net as net
import std.net.mux as mux
import std.str as text

async function main() -> int:
    match net.ipv4("127.0.0.1", 0):
        Result.failure:
            return 1
        Result.success as bind_payload:
            var server_addr = bind_payload.value
            defer server_addr.release()
            let config = mux.MuxedConfig.default()
            match mux.mux_listen(server_addr, config):
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
                                    match mux.mux_connect(cl, resolved, config):
                                        Result.failure:
                                            return 5
                                        Result.success as conn_payload:
                                            var client = conn_payload.value
                                            defer client.release()
                                            match await client.connect_to_peer():
                                                Result.failure:
                                                    return 6
                                                Result.success:
                                                    pass

                                            var msg_received: bool = false
                                            var frame: uint = 0
                                            while frame < 120 and not msg_received:
                                                await client.tick(frame)
                                                await server.tick(frame)

                                                let data = text.as_byte_span("hello")
                                                let send_result = await client.mux_send(0, 1, data, mux.flag_reliable)
                                                match send_result:
                                                    Result.success:
                                                        pass
                                                    Result.failure:
                                                        pass

                                                var drain_rounds: uint = 0
                                                while drain_rounds < 5:
                                                    let server_msg = server.try_recv()
                                                    match server_msg:
                                                        Option.some as sm:
                                                            var m = sm.value
                                                            defer m.release()
                                                            if m.channel_id == 0 and m.type_id == 1:
                                                                msg_received = true
                                                        Option.none:
                                                            pass
                                                    drain_rounds += 1

                                                frame += 1

                                            if msg_received:
                                                return 0
                                            return 30

    return 99

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-net-mux") do |dir|
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

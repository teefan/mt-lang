# frozen_string_literal: true

require "json"
require "stringio"
require_relative "../../test_helper"

class LSPProtocolTest < Minitest::Test
  def test_reads_and_writes_json_rpc_messages_with_content_length
    request = {
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => { "rootUri" => nil }
    }

    input = StringIO.new
    output = StringIO.new

    begin
      old_stdin = $stdin
      old_stdout = $stdout
      $stdin = input
      $stdout = output

      MilkTea::LSP::Protocol.write_message(request)
      wire = output.string

      input.write(wire)
      input.rewind
      output.truncate(0)
      output.rewind

      message = MilkTea::LSP::Protocol.read_message
      assert_equal request, message
    ensure
      $stdin = old_stdin
      $stdout = old_stdout
    end
  end

  def test_writes_response_and_error_payload_shapes
    output = StringIO.new

    begin
      old_stdout = $stdout
      $stdout = output

      MilkTea::LSP::Protocol.write_response(7, { "ok" => true })
      MilkTea::LSP::Protocol.write_error(9, -32_601, "Method not found")

      wire = output.string
      messages = parse_wire_messages(wire)

      assert_equal 2, messages.length
      assert_equal "2.0", messages[0]["jsonrpc"]
      assert_equal 7, messages[0]["id"]
      assert_equal({ "ok" => true }, messages[0]["result"])

      assert_equal "2.0", messages[1]["jsonrpc"]
      assert_equal 9, messages[1]["id"]
      assert_equal(-32_601, messages[1].dig("error", "code"))
    ensure
      $stdout = old_stdout
    end
  end

  private

  def parse_wire_messages(wire)
    io = StringIO.new(wire)
    messages = []
    until io.eof?
      header = io.gets("\r\n\r\n")
      break if header.nil?

      length = header[/Content-Length:\s*(\d+)/i, 1].to_i
      body = io.read(length)
      messages << JSON.parse(body)
    end
    messages
  end
end

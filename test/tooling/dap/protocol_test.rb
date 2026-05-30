# frozen_string_literal: true

require "stringio"
require_relative "../../test_helper"

class DAPProtocolTest < Minitest::Test
  def test_round_trips_dap_message_with_content_length
    input = StringIO.new
    output = StringIO.new
    protocol = MilkTea::DAP::Protocol.new(input:, output:)

    request = {
      "seq" => 1,
      "type" => "request",
      "command" => "initialize",
      "arguments" => {
        "adapterID" => "milk-tea"
      }
    }

    protocol.write_message(request)
    wire_payload = output.string

    input.write(wire_payload)
    input.rewind

    read_back = protocol.read_message
    assert_equal request, read_back
  end

  def test_read_message_handles_crlf_header_framing
    # DAP spec mandates \r\n header separators; protocol must handle them correctly.
    body = JSON.dump({ "seq" => 2, "type" => "request", "command" => "disconnect" })
    raw = "Content-Length: #{body.bytesize}\r\n\r\n#{body}"
    input = StringIO.new(raw)
    protocol = MilkTea::DAP::Protocol.new(input:, output: StringIO.new)

    msg = protocol.read_message
    assert_equal "disconnect", msg["command"]
  end

  def test_read_message_returns_nil_on_eof
    input = StringIO.new("")
    protocol = MilkTea::DAP::Protocol.new(input:, output: StringIO.new)

    assert_nil protocol.read_message
  end

  def test_read_message_returns_invalid_message_on_malformed_json
    raw = "Content-Length: 5\r\n\r\nnot{j"
    input = StringIO.new(raw)
    protocol = MilkTea::DAP::Protocol.new(input:, output: StringIO.new)

    assert_same MilkTea::DAP::Protocol::INVALID_MESSAGE, protocol.read_message
  end

  def test_write_message_emits_content_length_header
    output = StringIO.new
    protocol = MilkTea::DAP::Protocol.new(input: StringIO.new, output:)
    protocol.write_message({ "type" => "event", "event" => "initialized" })

    written = output.string
    assert_match(/\AContent-Length: \d+\r\n\r\n/, written)
    body = written.split("\r\n\r\n", 2).last
    parsed = JSON.parse(body)
    assert_equal "event", parsed["type"]
    assert_equal "initialized", parsed["event"]
  end

  def test_read_message_logs_errors_when_error_output_is_provided
    error_output = StringIO.new
    raw = "Content-Length: 7\r\n\r\n{broken"
    protocol = MilkTea::DAP::Protocol.new(input: StringIO.new(raw), output: StringIO.new, error_output:)

    assert_same MilkTea::DAP::Protocol::INVALID_MESSAGE, protocol.read_message
    assert_match(/DAP protocol read error:/, error_output.string)
  end

  def test_write_message_logs_errors_when_output_fails
    error_output = StringIO.new
    broken_output = Object.new
    broken_output.define_singleton_method(:write) { |_data| raise IOError, "write failed" }
    broken_output.define_singleton_method(:flush) { true }
    protocol = MilkTea::DAP::Protocol.new(input: StringIO.new, output: broken_output, error_output:)

    protocol.write_message({ "type" => "event" })
    assert_match(/DAP protocol write error: write failed/, error_output.string)
  end

  def test_log_error_is_noop_when_error_output_fails
    failing_error_output = Object.new
    failing_error_output.define_singleton_method(:puts) { |_line| raise IOError, "no stderr" }

    raw = "Content-Length: 8\r\n\r\n{broken}"
    protocol = MilkTea::DAP::Protocol.new(input: StringIO.new(raw), output: StringIO.new, error_output: failing_error_output)

    assert_same MilkTea::DAP::Protocol::INVALID_MESSAGE, protocol.read_message
  end

  def test_read_message_returns_invalid_message_when_content_length_is_missing
    raw = "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n{}"
    protocol = MilkTea::DAP::Protocol.new(input: StringIO.new(raw), output: StringIO.new)

    assert_same MilkTea::DAP::Protocol::INVALID_MESSAGE, protocol.read_message
  end
end

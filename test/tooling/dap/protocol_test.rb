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
end

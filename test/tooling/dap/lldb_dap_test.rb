# frozen_string_literal: true

require "stringio"
require "thread"
require_relative "../../test_helper"

class DAPLLDBDAPTest < Minitest::Test
  FakeProtocol = Struct.new(:messages, :written, keyword_init: true) do
    def read_message
      messages.shift
    end

    def write_message(message)
      written << message
    end
  end

  def test_running_reflects_wait_thread_state
    backend = MilkTea::DAP::Backends::LLDBDAP.new(adapter_command: ["lldb-dap"])

    refute backend.running?

    blocker = Queue.new
    wait_thread = Thread.new { blocker.pop }
    backend.instance_variable_set(:@wait_thread, wait_thread)

    assert backend.running?
  ensure
    blocker&.push(true)
    wait_thread&.join(0.2)
  end

  def test_request_times_out_and_cleans_pending_entry
    backend = MilkTea::DAP::Backends::LLDBDAP.new(adapter_command: ["lldb-dap"])
    backend.instance_variable_set(:@protocol, FakeProtocol.new(messages: [], written: []))

    blocker = Queue.new
    wait_thread = Thread.new { blocker.pop }
    backend.instance_variable_set(:@wait_thread, wait_thread)

    response = backend.request("threads", {}, timeout: 0.01)

    assert_equal "response", response["type"]
    assert_equal false, response["success"]
    assert_match(/timed out: threads/, response["message"])
    assert_empty backend.instance_variable_get(:@pending)
  ensure
    blocker&.push(true)
    wait_thread&.join(0.2)
  end

  def test_read_loop_routes_response_event_and_reverse_request
    events = []
    reverse_requests = []
    backend = MilkTea::DAP::Backends::LLDBDAP.new(
      adapter_command: ["lldb-dap"],
      on_event: ->(message) { events << message },
      on_request: lambda { |message|
        reverse_requests << message
        {
          "type" => "response",
          "request_seq" => message["seq"],
          "success" => true,
          "command" => message["command"]
        }
      }
    )

    protocol = FakeProtocol.new(
      messages: [
        { "type" => "response", "request_seq" => 1, "success" => true },
        { "type" => "event", "event" => "initialized" },
        { "type" => "request", "seq" => 7, "command" => "runInTerminal" },
        nil
      ],
      written: []
    )

    backend.instance_variable_set(:@protocol, protocol)
    queue = Queue.new
    backend.instance_variable_set(:@pending, { 1 => queue, 99 => Queue.new })

    backend.send(:read_loop)

    response = queue.pop
    assert_equal 1, response["request_seq"]
    assert_equal "initialized", events.first["event"]
    assert_equal "runInTerminal", reverse_requests.first["command"]
    assert_equal "runInTerminal", protocol.written.first["command"]

    drained = backend.instance_variable_get(:@pending)
    assert_empty drained
  end

  def test_handle_adapter_request_builds_default_error_response
    backend = MilkTea::DAP::Backends::LLDBDAP.new(adapter_command: ["lldb-dap"])
    protocol = FakeProtocol.new(messages: [], written: [])
    backend.instance_variable_set(:@protocol, protocol)

    backend.send(:handle_adapter_request, { "seq" => 12, "command" => "customReverse" })

    message = protocol.written.first
    assert_equal "response", message["type"]
    assert_equal 12, message["request_seq"]
    assert_equal false, message["success"]
    assert_match(/unsupported reverse request/, message["message"])
  end

  def test_drain_stderr_ignores_stream_errors
    backend = MilkTea::DAP::Backends::LLDBDAP.new(adapter_command: ["lldb-dap"])
    stderr = Object.new
    stderr.define_singleton_method(:each_line) { raise IOError, "stderr unavailable" }
    backend.instance_variable_set(:@stderr, stderr)

    backend.send(:drain_stderr)
  end
end

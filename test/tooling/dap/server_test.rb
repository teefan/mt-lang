# frozen_string_literal: true

require "json"
require "tmpdir"
require "timeout"
require_relative "../../test_helper"

class DAPServerTest < Minitest::Test
  class DAPClient
    def initialize(stdin_write, stdout_read)
      @stdin = stdin_write
      @stdout = stdout_read
      @next_seq = 1
      @buffered_responses = {}
    end

    def send_request(command, arguments = {})
      request_seq = start_request(command, arguments)
      wait_for_response(request_seq)
    end

    def start_request(command, arguments = {})
      request = {
        seq: @next_seq,
        type: "request",
        command: command,
        arguments: arguments
      }
      @next_seq += 1
      write_message(request)
      request[:seq]
    end

    def wait_for_response(expected_request_seq, timeout: 5)
      buffered_response = @buffered_responses.delete(expected_request_seq)
      return [buffered_response, []] if buffered_response

      read_response_and_events(expected_request_seq, timeout: timeout)
    end

    def wait_for_event(expected_event, timeout: 5)
      Timeout.timeout(timeout) do
        loop do
          message = read_message
          next if message.nil?

          if message["type"] == "response"
            @buffered_responses[message["request_seq"]] = message
            next
          end

          next unless message["type"] == "event"
          return message if message["event"] == expected_event
        end
      end
    end

    private

    def write_message(message)
      json = JSON.dump(message)
      @stdin.write("Content-Length: #{json.bytesize}\r\n\r\n#{json}")
      @stdin.flush
    end

    def read_response_and_events(expected_request_seq, timeout: 5)
      events = []
      response = nil

      Timeout.timeout(timeout) do
        loop do
          message = read_message
          next if message.nil?

          if message["type"] == "event"
            events << message
            next
          end

          if message["type"] == "response" && message["request_seq"] != expected_request_seq
            @buffered_responses[message["request_seq"]] = message
            next
          end

          next unless message["type"] == "response"
          next unless message["request_seq"] == expected_request_seq

          response = message
          break
        end
      end

      events.concat(drain_events)
      [response, events]
    end

    def send_response(request_seq, command, body = {}, success: true, message: nil)
      response = {
        seq: @next_seq,
        type: "response",
        request_seq: request_seq,
        command: command,
        success: success
      }
      response[:body] = body if success
      response[:message] = message if message
      @next_seq += 1
      write_message(response)
    end

    def read_message
      headers = {}
      loop do
        line = @stdout.gets
        return nil if line.nil?

        stripped = line.chomp.sub(/\r\z/, "")
        break if stripped.empty?

        key, value = stripped.split(":", 2)
        headers[key.strip] = value.strip
      end

      content_length = headers["Content-Length"]&.to_i
      return nil if content_length.nil? || content_length <= 0

      body = @stdout.read(content_length)
      JSON.parse(body)
    end

    def drain_events
      events = []
      while IO.select([@stdout], nil, nil, 0.15)
        message = read_message
        break if message.nil?

        if message["type"] == "response"
          @buffered_responses[message["request_seq"]] = message
          break
        end

        break unless message["type"] == "event"

        events << message
      end
      events
    end
  end

  class InMemoryProtocol
    attr_reader :written

    def initialize(incoming)
      @incoming = incoming.dup
      @written = []
    end

    def read_message
      @incoming.shift
    end

    def write_message(message)
      @written << message
    end
  end

  class FakeBridgeBackend
    attr_reader :requests

    def initialize(on_event, on_request = nil)
      @on_event = on_event
      @on_request = on_request
      @requests = []
    end

    def start!
      true
    end

    def stop!
      true
    end

    def request(command, arguments, timeout: 5)
      _timeout = timeout
      @requests << [command, arguments]

      case command
      when "initialize"
        {
          "success" => true,
          "body" => {
            "supportsConfigurationDoneRequest" => true,
            "supportsCompletionsRequest" => true,
            "supportsExceptionInfoRequest" => true,
            "supportsModulesRequest" => true,
            "supportsReadMemoryRequest" => true,
            "supportsDisassembleRequest" => true,
            "supportsDataBreakpoints" => true,
            "supportsInstructionBreakpoints" => true,
            "supportsSetExpression" => true,
            "supportsBreakpointLocationsRequest" => true,
            "supportsCancelRequest" => true
          }
        }
      when "launch", "attach"
        { "success" => true, "body" => {} }
      when "setBreakpoints"
        { "success" => true, "body" => { "breakpoints" => [{ "id" => 42, "verified" => true, "line" => 4 }] } }
      when "configurationDone"
        @on_event.call({ "type" => "event", "event" => "stopped", "body" => { "reason" => "entry", "threadId" => 77, "allThreadsStopped" => true } })
        { "success" => true, "body" => {} }
      when "threads"
        { "success" => true, "body" => { "threads" => [{ "id" => 77, "name" => "bridge-main" }] } }
      when "stackTrace"
        { "success" => true, "body" => { "stackFrames" => [{ "id" => 1, "name" => "bridge_main", "line" => 4, "column" => 0, "source" => { "path" => "/tmp/demo.mt" } }], "totalFrames" => 1 } }
      when "scopes"
        { "success" => true, "body" => { "scopes" => [{ "name" => "Locals", "variablesReference" => 99, "expensive" => false }] } }
      when "variables"
        { "success" => true, "body" => { "variables" => [{ "name" => "x", "value" => "42", "type" => "int", "variablesReference" => 0 }] } }
      when "setExceptionBreakpoints"
        { "success" => true, "body" => {} }
      when "evaluate"
        { "success" => true, "body" => { "result" => "42", "variablesReference" => 0 } }
      when "completions"
        { "success" => true, "body" => { "targets" => [{ "label" => "demo_symbol", "text" => "demo_symbol" }] } }
      when "exceptionInfo"
        {
          "success" => true,
          "body" => {
            "exceptionId" => "demo.exception",
            "description" => "bridge exception",
            "breakMode" => "always"
          }
        }
      when "modules"
        {
          "success" => true,
          "body" => {
            "modules" => [{ "id" => "main", "name" => "main.mt" }],
            "totalModules" => 1
          }
        }
      when "readMemory"
        {
          "success" => true,
          "body" => {
            "address" => arguments["memoryReference"],
            "data" => "AQIDBA==",
            "unreadableBytes" => 0
          }
        }
      when "disassemble"
        {
          "success" => true,
          "body" => {
            "instructions" => [
              { "address" => "0x1000", "instruction" => "mov x0, x0" }
            ]
          }
        }
      when "dataBreakpointInfo"
        {
          "success" => true,
          "body" => {
            "dataId" => "data:#{arguments["name"]}",
            "description" => { "label" => arguments["name"] },
            "accessTypes" => %w[read write readWrite],
            "canPersist" => true,
          }
        }
      when "setDataBreakpoints"
        {
          "success" => true,
          "body" => {
            "breakpoints" => Array(arguments["breakpoints"]).map.with_index do |breakpoint, index|
              {
                "id" => 300 + index,
                "verified" => true,
                "dataId" => breakpoint["dataId"]
              }
            end
          }
        }
      when "setExpression"
        {
          "success" => true,
          "body" => {
            "value" => arguments["value"],
            "type" => "int",
            "variablesReference" => 0
          }
        }
      when "setInstructionBreakpoints"
        {
          "success" => true,
          "body" => {
            "breakpoints" => Array(arguments["breakpoints"]).map.with_index do |_breakpoint, index|
              {
                "id" => 400 + index,
                "verified" => true
              }
            end
          }
        }
      when "breakpointLocations"
        {
          "success" => true,
          "body" => {
            "breakpoints" => [
              { "line" => arguments["line"], "column" => 1 }
            ]
          }
        }
      when "cancel"
        { "success" => true, "body" => {} }
      when "source"
        { "success" => true, "body" => { "content" => "# source not available" } }
      when "loadedSources"
        { "success" => true, "body" => { "sources" => [] } }
      when "terminate"
        { "success" => true, "body" => {} }
      when "disconnect"
        @on_event.call({ "type" => "event", "event" => "terminated" })
        @on_event.call({ "type" => "event", "event" => "exited", "body" => { "exitCode" => 0 } })
        { "success" => true, "body" => {} }
      else
        { "success" => false, "message" => "unsupported command" }
      end
    end
  end

  class DuplicateContinuedBridgeBackend < FakeBridgeBackend
    def request(command, arguments, timeout: 5)
      if command == "continue"
        _timeout = timeout
        @requests << [command, arguments]

        2.times do
          @on_event.call({
            "type" => "event",
            "event" => "continued",
            "body" => { "threadId" => 77, "allThreadsContinued" => true }
          })
        end

        return({ "success" => true, "body" => { "allThreadsContinued" => true } })
      end

      super
    end
  end

  class TerminateUnsupportedBridgeBackend < FakeBridgeBackend
    def request(command, arguments, timeout: 5)
      if command == "terminate"
        _timeout = timeout
        @requests << [command, arguments]
        return({ "success" => false, "message" => "unknown request" })
      end

      super
    end
  end

  class DebugMapBridgeBackend < FakeBridgeBackend
    def request(command, arguments, timeout: 5)
      case command
      when "stackTrace"
        {
          "success" => true,
          "body" => {
            "stackFrames" => [{
              "id" => 1,
              "name" => "demo_debug_map_add",
              "line" => 4,
              "column" => 0,
              "source" => { "path" => "/tmp/demo.mt" }
            }],
            "totalFrames" => 1
          }
        }
      when "variables"
        {
          "success" => true,
          "body" => {
            "variables" => [
              { "name" => "int_", "value" => "42", "type" => "int", "variablesReference" => 0 },
              { "name" => "left", "value" => "1", "type" => "int", "variablesReference" => 0 },
              { "name" => "__mt_for_index_1", "value" => "0", "type" => "ptr_uint", "variablesReference" => 0 }
            ]
          }
        }
      else
        super
      end
    end
  end

  class DebugMapExpressionBackend < DebugMapBridgeBackend
    def request(command, arguments, timeout: 5)
      _timeout = timeout
      @requests << [command, arguments]

      case command
      when "initialize"
        {
          "success" => true,
          "body" => {
            "supportsConfigurationDoneRequest" => true,
            "supportsEvaluateForHovers" => true,
            "supportsSetExpression" => true,
            "supportsSetVariable" => true,
          }
        }
      when "evaluate"
        {
          "success" => true,
          "body" => {
            "result" => arguments["expression"],
            "type" => "int",
            "variablesReference" => 0,
          }
        }
      when "setExpression"
        {
          "success" => true,
          "body" => {
            "value" => arguments["value"],
            "type" => "int",
            "variablesReference" => 0,
          }
        }
      when "setVariable"
        {
          "success" => true,
          "body" => {
            "value" => arguments["value"],
            "type" => "int",
            "variablesReference" => 0,
          }
        }
      else
        super
      end
    end
  end

  class AttachDebugMapBridgeBackend < DebugMapBridgeBackend
    def initialize(binary_path, on_event, on_request = nil)
      super(on_event, on_request)
      @binary_path = binary_path
    end

    def request(command, arguments, timeout: 5)
      case command
      when "modules"
        @requests << [command, arguments]
        {
          "success" => true,
          "body" => {
            "modules" => [{
              "id" => "main",
              "name" => File.basename(@binary_path),
              "path" => @binary_path
            }],
            "totalModules" => 1
          }
        }
      else
        super
      end
    end
  end

  class DeferredLaunchBridgeBackend < FakeBridgeBackend
    def initialize(on_event, on_request = nil)
      super
      @launch_gate = Queue.new
    end

    def request(command, arguments, timeout: 5)
      _timeout = timeout
      @requests << [command, arguments]

      case command
      when "initialize"
        {
          "success" => true,
          "body" => {
            "supportsConfigurationDoneRequest" => true,
            "supportsFunctionBreakpoints" => true,
            "supportsConditionalBreakpoints" => true,
          }
        }
      when "launch"
        @on_event.call({ "type" => "event", "event" => "initialized" })
        @launch_gate.pop
        { "success" => true, "body" => {} }
      when "setBreakpoints"
        {
          "success" => true,
          "body" => {
            "breakpoints" => [{ "id" => 1, "verified" => true, "line" => 4 }]
          }
        }
      when "configurationDone"
        @launch_gate << true
        @on_event.call({ "type" => "event", "event" => "stopped", "body" => { "reason" => "entry", "threadId" => 1 } })
        { "success" => true, "body" => {} }
      when "disconnect"
        @on_event.call({ "type" => "event", "event" => "terminated" })
        @on_event.call({ "type" => "event", "event" => "exited", "body" => { "exitCode" => 0 } })
        { "success" => true, "body" => {} }
      else
        { "success" => true, "body" => {} }
      end
    end
  end

  class EntryStopLaunchBridgeBackend < FakeBridgeBackend
    def initialize(on_event, on_request = nil)
      super
      @launch_ready = Queue.new
    end

    def request(command, arguments, timeout: 5)
      _timeout = timeout
      @requests << [command, arguments]

      case command
      when "initialize"
        {
          "success" => true,
          "body" => {
            "supportsConfigurationDoneRequest" => true
          }
        }
      when "launch"
        @on_event.call({ "type" => "event", "event" => "initialized" })
        @on_event.call({ "type" => "event", "event" => "stopped", "body" => { "reason" => "entry", "threadId" => 77, "allThreadsStopped" => true } })
        @launch_ready.pop
        { "success" => true, "body" => {} }
      when "setBreakpoints"
        {
          "success" => true,
          "body" => {
            "breakpoints" => [{ "id" => 1, "verified" => true, "line" => 4 }]
          }
        }
      when "configurationDone"
        @launch_ready << true
        { "success" => true, "body" => {} }
      when "threads"
        {
          "success" => true,
          "body" => {
            "threads" => [{ "id" => 77, "name" => "entry-thread" }]
          }
        }
      when "continue"
        {
          "success" => true,
          "body" => {
            "allThreadsContinued" => true
          }
        }
      when "disconnect"
        @on_event.call({ "type" => "event", "event" => "terminated" })
        @on_event.call({ "type" => "event", "event" => "exited", "body" => { "exitCode" => 0 } })
        { "success" => true, "body" => {} }
      else
        { "success" => true, "body" => {} }
      end
    end
  end

  class ReverseRequestBackend
    attr_reader :requests

    def initialize(on_event, on_request)
      @on_event = on_event
      @on_request = on_request
      @requests = []
    end

    def start!
      true
    end

    def stop!
      true
    end

    def request(command, arguments, timeout: 5)
      _timeout = timeout
      @requests << [command, arguments]

      case command
      when "initialize"
        { "success" => true, "body" => { "supportsConfigurationDoneRequest" => true } }
      when "launch"
        { "success" => true, "body" => {} }
      when "configurationDone"
        reverse_response = @on_request.call({
          "seq" => 700,
          "type" => "request",
          "command" => "runInTerminal",
          "arguments" => {
            "kind" => "integrated",
            "title" => "Milk Tea Debuggee",
            "cwd" => "/tmp",
            "args" => ["/usr/bin/true"]
          }
        })
        return { "success" => false, "message" => reverse_response["message"] } unless reverse_response["success"]

        @on_event.call({ "type" => "event", "event" => "stopped", "body" => { "reason" => "entry", "threadId" => 77, "allThreadsStopped" => true } })
        { "success" => true, "body" => { "terminalProcessId" => reverse_response.dig("body", "processId") } }
      when "disconnect"
        @on_event.call({ "type" => "event", "event" => "terminated" })
        @on_event.call({ "type" => "event", "event" => "exited", "body" => { "exitCode" => 0 } })
        { "success" => true, "body" => {} }
      else
        { "success" => true, "body" => {} }
      end
    end
  end

  class StartDebuggingBackend
    attr_reader :requests

    def initialize(on_event, on_request)
      @on_event = on_event
      @on_request = on_request
      @requests = []
    end

    def start! = true
    def stop! = true

    def request(command, arguments, timeout: 5)
      _timeout = timeout
      @requests << [command, arguments]

      case command
      when "initialize"
        { "success" => true, "body" => { "supportsConfigurationDoneRequest" => true } }
      when "launch"
        { "success" => true, "body" => {} }
      when "configurationDone"
        reverse_response = @on_request.call({
          "seq" => 800,
          "type" => "request",
          "command" => "startDebugging",
          "arguments" => {
            "configuration" => {
              "name" => "Child Session",
              "type" => "milk-tea",
              "request" => "launch",
              "program" => "/tmp/child.mt"
            },
            "request" => "launch"
          }
        })
        return { "success" => false, "message" => reverse_response["message"] } unless reverse_response["success"]

        @on_event.call({ "type" => "event", "event" => "stopped", "body" => { "reason" => "entry", "threadId" => 77, "allThreadsStopped" => true } })
        { "success" => true, "body" => {} }
      when "disconnect"
        @on_event.call({ "type" => "event", "event" => "terminated" })
        @on_event.call({ "type" => "event", "event" => "exited", "body" => { "exitCode" => 0 } })
        { "success" => true, "body" => {} }
      else
        { "success" => true, "body" => {} }
      end
    end
  end

  def test_initialize_then_launch_sequence_emits_initialized_and_entry_stopped
    with_server do |client|
      init_response, init_events = client.send_request("initialize", { "adapterID" => "milk-tea" })
      assert_equal true, init_response["success"]
      assert_equal "initialize", init_response["command"]
      assert_equal true, init_response.dig("body", "supportsConfigurationDoneRequest")
      assert_equal [], init_response.dig("body", "exceptionBreakpointFilters")
      assert_equal ["initialized"], init_events.map { |e| e["event"] }

      launch_response, launch_events = client.send_request("launch", { "program" => "/usr/bin/true", "stopOnEntry" => true })
      assert_equal true, launch_response["success"]
      assert_equal ["process"], launch_events.map { |e| e["event"] }
      process_body = launch_events.first["body"]
      assert_equal "true", process_body["name"]
      assert_equal "launch", process_body["startMethod"]
      assert_equal true, process_body["isLocalProcess"]

      conf_response, conf_events = client.send_request("configurationDone", {})
      assert_equal true, conf_response["success"]
      assert_equal ["stopped"], conf_events.map { |e| e["event"] }
      assert_equal "entry", conf_events.first.dig("body", "reason")
    end
  end

  def test_rejects_requests_before_initialize
    with_server do |client|
      response, _events = client.send_request("threads", {})
      assert_equal false, response["success"]
      assert_match(/initialize request must be sent first/, response["message"])
    end
  end

  def test_supports_basic_control_requests
    with_server do |client|
      _init_response, _init_events = client.send_request("initialize", { "adapterID" => "milk-tea" })
      _launch_response, _launch_events = client.send_request("launch", { "program" => "/usr/bin/true", "stopOnEntry" => true })
      _conf_response, _conf_events = client.send_request("configurationDone", {})

      threads_response, _threads_events = client.send_request("threads", {})
      assert_equal true, threads_response["success"]
      assert_equal 1, threads_response.dig("body", "threads")&.length

      stack_response, _stack_events = client.send_request("stackTrace", { "threadId" => 1 })
      assert_equal true, stack_response["success"]
      assert_equal "main", stack_response.dig("body", "stackFrames", 0, "name")

      next_response, _next_events = client.send_request("next", { "threadId" => 1 })
      assert_equal false, next_response["success"]
      assert_match(/not supported/, next_response["message"])

      cont_response, cont_events = client.send_request("continue", { "threadId" => 1 })
      assert_equal true, cont_response["success"]
      event_names = cont_events.map { |e| e["event"] }
      assert_includes event_names, "continued"
    end
  end

  def test_launch_requires_program_argument
    with_server do |client|
      _init_response, _init_events = client.send_request("initialize", { "adapterID" => "milk-tea" })

      response, _events = client.send_request("launch", {})
      assert_equal false, response["success"]
      assert_match(/requires a non-empty 'program'/, response["message"])
    end
  end

  def test_set_breakpoints_accepts_legacy_lines_shape
    with_server do |client|
      _init_response, _init_events = client.send_request("initialize", { "adapterID" => "milk-tea" })

      response, _events = client.send_request("setBreakpoints", {
        "source" => { "path" => "/tmp/demo.mt" },
        "lines" => [3, 7]
      })

      assert_equal true, response["success"]
      breakpoints = response.dig("body", "breakpoints")
      assert_equal [3, 7], breakpoints.map { |bp| bp["line"] }
      assert_equal [true, true], breakpoints.map { |bp| bp["verified"] }
    end
  end

  def test_launch_rejects_non_array_args
    with_server do |client|
      _init_response, _init_events = client.send_request("initialize", { "adapterID" => "milk-tea" })

      response, _events = client.send_request("launch", {
        "program" => "/usr/bin/true",
        "args" => "--not-an-array"
      })

      assert_equal false, response["success"]
      assert_match(/'args' must be an array/, response["message"])
    end
  end

  def test_entry_stopped_event_is_emitted_only_once
    with_server do |client|
      _init_response, _init_events = client.send_request("initialize", { "adapterID" => "milk-tea" })
      _launch_response, _launch_events = client.send_request("launch", { "program" => "/usr/bin/true", "stopOnEntry" => true })

      _first_conf_response, first_conf_events = client.send_request("configurationDone", {})
      assert_equal ["stopped"], first_conf_events.map { |e| e["event"] }

      _second_conf_response, second_conf_events = client.send_request("configurationDone", {})
      assert_equal [], second_conf_events

      disconnect_response, disconnect_events = client.send_request("disconnect", {})
      assert_equal true, disconnect_response["success"]
      assert_equal ["terminated", "exited"], disconnect_events.map { |e| e["event"] }
    end
  end

  def test_terminate_request_is_supported_in_process_backend
    with_server do |client|
      _init_response, _init_events = client.send_request("initialize", { "adapterID" => "milk-tea" })
      _launch_response, _launch_events = client.send_request("launch", { "program" => "/usr/bin/true", "stopOnEntry" => true })
      _conf_response, _conf_events = client.send_request("configurationDone", {})

      terminate_response, _terminate_events = client.send_request("terminate", {})
      assert_equal true, terminate_response["success"]
    end
  end

  def test_terminate_from_stop_on_entry_emits_terminated_and_exited
    with_server do |client|
      _init_response, _init_events = client.send_request("initialize", { "adapterID" => "milk-tea" })
      _launch_response, _launch_events = client.send_request("launch", { "program" => "/usr/bin/true", "stopOnEntry" => true })
      _conf_response, conf_events = client.send_request("configurationDone", {})
      assert_equal ["stopped"], conf_events.map { |e| e["event"] }

      terminate_response, terminate_events = client.send_request("terminate", {})
      assert_equal true, terminate_response["success"]
      assert_equal ["terminated", "exited"], terminate_events.map { |e| e["event"] }
      assert_equal 0, terminate_events.last.dig("body", "exitCode")
    end
  end

  def test_process_backend_emits_process_event_after_launch
    with_server do |client|
      _init_response, _init_events = client.send_request("initialize", { "adapterID" => "milk-tea" })
      launch_response, launch_events = client.send_request("launch", { "program" => "/usr/bin/true", "stopOnEntry" => true })
      assert_equal true, launch_response["success"]
      process_events = launch_events.select { |e| e["event"] == "process" }
      assert_equal 1, process_events.length
      process_body = process_events.first["body"]
      assert_equal "true", process_body["name"]
      assert_equal "launch", process_body["startMethod"]
      assert_equal true, process_body["isLocalProcess"]
    end
  end

  def test_process_backend_initialize_response_advertises_loaded_sources
    with_server do |client|
      init_response, _init_events = client.send_request("initialize", { "adapterID" => "milk-tea" })
      assert_equal true, init_response["success"]
      assert_equal true, init_response.dig("body", "supportsLoadedSourcesRequest")
    end
  end

  def test_launch_with_no_debug_forces_process_backend_and_skips_entry_stop
    incoming = [
      { "seq" => 1, "type" => "request", "command" => "initialize", "arguments" => { "adapterID" => "milk-tea" } },
      { "seq" => 2, "type" => "request", "command" => "launch", "arguments" => { "backend" => "lldb-dap", "program" => "/usr/bin/true", "stopOnEntry" => true, "noDebug" => true } },
      { "seq" => 3, "type" => "request", "command" => "configurationDone", "arguments" => {} }
    ]
    protocol = InMemoryProtocol.new(incoming)
    backend_started = false

    server = MilkTea::DAP::Server.new(
      protocol: protocol,
      backend_factory: lambda do |_adapter_command, on_event|
        backend_started = true
        FakeBridgeBackend.new(on_event)
      end
    )

    server.run

    launch_response = find_response(protocol.written, 2)
    assert_equal true, launch_response["success"] || launch_response[:success]

    conf_response = find_response(protocol.written, 3)
    assert_equal true, conf_response["success"] || conf_response[:success]

    process_events = find_events(protocol.written, "process")
    assert_equal 1, process_events.length
    assert_equal [], find_events(protocol.written, "stopped")
    assert_equal false, backend_started
  end

  def test_initialize_merges_backend_capabilities_when_server_prefers_lldb_backend
    incoming = [
      { "seq" => 1, "type" => "request", "command" => "initialize", "arguments" => { "adapterID" => "milk-tea" } }
    ]
    protocol = InMemoryProtocol.new(incoming)
    backend = nil

    server = MilkTea::DAP::Server.new(
      protocol: protocol,
      preferred_backend_kind: "lldb-dap",
      backend_factory: lambda do |_adapter_command, on_event|
        backend = FakeBridgeBackend.new(on_event)
        backend
      end
    )

    server.run

    init_response = find_response(protocol.written, 1)
    assert_equal true, init_response["success"] || init_response[:success]
    init_body = init_response["body"] || init_response[:body]
    assert_equal true, init_body["supportsReadMemoryRequest"] || init_body[:supportsReadMemoryRequest]
    assert_equal true, init_body["supportsDisassembleRequest"] || init_body[:supportsDisassembleRequest]

    initialized_events = find_events(protocol.written, "initialized")
    assert_equal 1, initialized_events.length

    backend_commands = backend.requests.map(&:first)
    assert_includes backend_commands, "initialize"
  end

  def test_lldb_backend_reverse_start_debugging_request_is_forwarded_to_client
    stdin_read, stdin_write = IO.pipe
    stdout_read, stdout_write = IO.pipe

    server = MilkTea::DAP::Server.new(
      protocol: MilkTea::DAP::Protocol.new(input: stdin_read, output: stdout_write),
      backend_factory: lambda do |_adapter_command, on_event, on_request|
        StartDebuggingBackend.new(on_event, on_request)
      end
    )

    thread = Thread.new { server.run }
    client = DAPClient.new(stdin_write, stdout_read)

    init_response, _init_events = client.send_request("initialize", { "adapterID" => "milk-tea", "supportsStartDebuggingRequest" => true })
    assert_equal true, init_response["success"]

    launch_response, _launch_events = client.send_request("launch", {
      "backend" => "lldb-dap",
      "program" => "/usr/bin/true",
      "stopOnEntry" => true
    })
    assert_equal true, launch_response["success"]

    conf_request = {
      seq: client.instance_variable_get(:@next_seq),
      type: "request",
      command: "configurationDone",
      arguments: {}
    }
    client.instance_variable_set(:@next_seq, conf_request[:seq] + 1)
    client.send(:write_message, conf_request)

    reverse_request = nil
    conf_response = nil
    events = []

    Timeout.timeout(5) do
      loop do
        message = client.send(:read_message)
        next if message.nil?

        if message["type"] == "request" && message["command"] == "startDebugging"
          reverse_request = message
          client.send(:send_response, message["seq"], "startDebugging", {})
          next
        end

        if message["type"] == "event"
          events << message
          next
        end

        next unless message["type"] == "response"
        next unless message["request_seq"] == conf_request[:seq]

        conf_response = message
        break
      end
    end

    assert_equal "startDebugging", reverse_request["command"]
    assert_equal "Child Session", reverse_request.dig("arguments", "configuration", "name")
    assert_equal "launch", reverse_request.dig("arguments", "request")
    assert_equal true, conf_response["success"]
    assert_includes events.map { |e| e["event"] }, "stopped"

    disconnect_response, disconnect_events = client.send_request("disconnect", {})
    assert_equal true, disconnect_response["success"]
    assert_includes disconnect_events.map { |e| e["event"] }, "terminated"
  ensure
    stdin_write&.close
    stdout_read&.close
    thread&.join(1)
  end

  def test_lldb_backend_bridge_is_deterministic_with_injected_backend
    incoming = [
      { "seq" => 1, "type" => "request", "command" => "initialize", "arguments" => { "adapterID" => "milk-tea" } },
      { "seq" => 2, "type" => "request", "command" => "launch", "arguments" => { "backend" => "lldb-dap", "program" => "/usr/bin/true", "stopOnEntry" => true } },
      { "seq" => 3, "type" => "request", "command" => "setBreakpoints", "arguments" => { "source" => { "path" => "/tmp/demo.mt" }, "breakpoints" => [{ "line" => 4 }] } },
      { "seq" => 4, "type" => "request", "command" => "configurationDone", "arguments" => {} },
      { "seq" => 5, "type" => "request", "command" => "threads", "arguments" => {} },
      { "seq" => 6, "type" => "request", "command" => "stackTrace", "arguments" => { "threadId" => 77 } },
      { "seq" => 7, "type" => "request", "command" => "scopes", "arguments" => { "frameId" => 1 } },
      { "seq" => 8, "type" => "request", "command" => "variables", "arguments" => { "variablesReference" => 99 } },
      { "seq" => 9, "type" => "request", "command" => "setExceptionBreakpoints", "arguments" => { "filters" => [] } },
      { "seq" => 10, "type" => "request", "command" => "evaluate", "arguments" => { "expression" => "x", "frameId" => 1, "context" => "watch" } },
      { "seq" => 11, "type" => "request", "command" => "completions", "arguments" => { "text" => "de", "column" => 2, "line" => 1, "frameId" => 1 } },
      { "seq" => 12, "type" => "request", "command" => "terminate", "arguments" => {} },
      { "seq" => 13, "type" => "request", "command" => "disconnect", "arguments" => {} }
    ]
    protocol = InMemoryProtocol.new(incoming)
    backend = nil

    server = MilkTea::DAP::Server.new(
      protocol: protocol,
      backend_factory: lambda do |_adapter_command, on_event|
        backend = FakeBridgeBackend.new(on_event)
        backend
      end
    )

    server.run

    launch_response = find_response(protocol.written, 2)
    assert_equal true, launch_response["success"] || launch_response[:success]

    breakpoints_response = find_response(protocol.written, 3)
    assert_equal true, breakpoints_response["success"] || breakpoints_response[:success]
    breakpoints_body = breakpoints_response["body"] || breakpoints_response[:body]
    first_breakpoint = breakpoints_body["breakpoints"]&.first || breakpoints_body[:breakpoints]&.first
    assert_equal 4, first_breakpoint["line"] || first_breakpoint[:line]
    assert_equal true, first_breakpoint["verified"] || first_breakpoint[:verified]

    set_breakpoints_request = backend.requests.find { |command, _arguments| command == "setBreakpoints" }
    refute_nil set_breakpoints_request

    configuration_done_events = find_events(protocol.written, "stopped")
    assert_equal true, configuration_done_events.any?

    threads_response = find_response(protocol.written, 5)
    threads_body = threads_response["body"] || threads_response[:body]
    first_thread = threads_body["threads"]&.first || threads_body[:threads]&.first
    assert_equal 77, first_thread["id"] || first_thread[:id]

    stack_response = find_response(protocol.written, 6)
    stack_body = stack_response["body"] || stack_response[:body]
    first_frame = stack_body["stackFrames"]&.first || stack_body[:stackFrames]&.first
    assert_equal "bridge_main", first_frame["name"] || first_frame[:name]
    assert_equal 4, first_frame["line"] || first_frame[:line]

    scopes_response = find_response(protocol.written, 7)
    scopes_body = scopes_response["body"] || scopes_response[:body]
    first_scope = scopes_body["scopes"]&.first || scopes_body[:scopes]&.first
    assert_equal "Locals", first_scope["name"] || first_scope[:name]
    assert_equal 99, first_scope["variablesReference"] || first_scope[:variablesReference]

    variables_response = find_response(protocol.written, 8)
    variables_body = variables_response["body"] || variables_response[:body]
    first_var = variables_body["variables"]&.first || variables_body[:variables]&.first
    assert_equal "x", first_var["name"] || first_var[:name]
    assert_equal "42", first_var["value"] || first_var[:value]

    exception_bp_response = find_response(protocol.written, 9)
    assert_equal true, exception_bp_response["success"] || exception_bp_response[:success]

    evaluate_response = find_response(protocol.written, 10)
    assert_equal true, evaluate_response["success"] || evaluate_response[:success]
    evaluate_body = evaluate_response["body"] || evaluate_response[:body]
    assert_equal "42", evaluate_body["result"] || evaluate_body[:result]

    completions_response = find_response(protocol.written, 11)
    assert_equal true, completions_response["success"] || completions_response[:success]
    completions_body = completions_response["body"] || completions_response[:body]
    first_target = completions_body["targets"]&.first || completions_body[:targets]&.first
    assert_equal "demo_symbol", first_target["label"] || first_target[:label]

    terminate_response = find_response(protocol.written, 12)
    assert_equal true, terminate_response["success"] || terminate_response[:success]

    disconnect_response = find_response(protocol.written, 13)
    assert_equal true, disconnect_response["success"] || disconnect_response[:success]

    caps_events = find_events(protocol.written, "capabilities")
    assert_equal true, caps_events.any?, "expected capabilities event after lldb-dap backend init"
    caps_body = caps_events.first[:body] || caps_events.first["body"]
    assert_equal [], caps_body[:exceptionBreakpointFilters] || caps_body["exceptionBreakpointFilters"],
                 "capabilities event body must include exceptionBreakpointFilters"
    assert_equal true, caps_body[:supportsCompletionsRequest] || caps_body["supportsCompletionsRequest"]

    backend_commands = backend.requests.map(&:first)
    assert_includes backend_commands, "initialize"
    assert_includes backend_commands, "launch"
    assert_includes backend_commands, "stackTrace"
    assert_includes backend_commands, "scopes"
    assert_includes backend_commands, "variables"
    assert_includes backend_commands, "setExceptionBreakpoints"
    assert_includes backend_commands, "evaluate"
    assert_includes backend_commands, "completions"
    assert_includes backend_commands, "terminate"
    assert_includes backend_commands, "disconnect"
  end

  def test_lldb_backend_falls_back_to_disconnect_when_terminate_is_unsupported
    incoming = [
      { "seq" => 1, "type" => "request", "command" => "initialize", "arguments" => { "adapterID" => "milk-tea" } },
      { "seq" => 2, "type" => "request", "command" => "launch", "arguments" => { "backend" => "lldb-dap", "program" => "/usr/bin/true", "stopOnEntry" => true } },
      { "seq" => 3, "type" => "request", "command" => "configurationDone", "arguments" => {} },
      { "seq" => 4, "type" => "request", "command" => "terminate", "arguments" => {} }
    ]
    protocol = InMemoryProtocol.new(incoming)
    backend = nil

    server = MilkTea::DAP::Server.new(
      protocol: protocol,
      backend_factory: lambda do |_adapter_command, on_event|
        backend = TerminateUnsupportedBridgeBackend.new(on_event)
        backend
      end
    )

    server.run

    terminate_response = find_response(protocol.written, 4)
    assert_equal true, terminate_response["success"] || terminate_response[:success]
    assert_includes find_events(protocol.written, "terminated").map { |event| event["event"] || event[:event] }, "terminated"

    backend_commands = backend.requests.map(&:first)
    assert_includes backend_commands, "terminate"
    assert_includes backend_commands, "disconnect"
  end

  def test_lldb_backend_suppresses_duplicate_continued_events
    incoming = [
      { "seq" => 1, "type" => "request", "command" => "initialize", "arguments" => { "adapterID" => "milk-tea" } },
      { "seq" => 2, "type" => "request", "command" => "launch", "arguments" => { "backend" => "lldb-dap", "program" => "/usr/bin/true", "stopOnEntry" => true } },
      { "seq" => 3, "type" => "request", "command" => "configurationDone", "arguments" => {} },
      { "seq" => 4, "type" => "request", "command" => "continue", "arguments" => { "threadId" => 77 } }
    ]
    protocol = InMemoryProtocol.new(incoming)

    server = MilkTea::DAP::Server.new(
      protocol: protocol,
      backend_factory: lambda do |_adapter_command, on_event|
        DuplicateContinuedBridgeBackend.new(on_event)
      end
    )

    server.run

    continue_response = find_response(protocol.written, 4)
    assert_equal true, continue_response["success"] || continue_response[:success]

    continued_events = find_events(protocol.written, "continued")
    assert_equal 1, continued_events.length
    continued_body = continued_events.first["body"] || continued_events.first[:body]
    assert_equal 77, continued_body["threadId"] || continued_body[:threadId]
    assert_equal true, continued_body["allThreadsContinued"] || continued_body[:allThreadsContinued]
  end

  def test_lldb_backend_rewrites_frames_and_locals_from_debug_map_sidecar
    Dir.mktmpdir("milk-tea-dap-debug-map") do |dir|
      source_path = File.join(dir, "demo.mt")
      binary_path = File.join(dir, "demo")
      File.write(source_path, "module demo.debug_map\n")
      File.write(binary_path, "")

      debug_map = MilkTea::DebugMap.new(
        binary_path: binary_path,
        program_source_path: source_path,
        functions: [
          MilkTea::DebugMap::Function.new(
            name: "add",
            c_name: "demo_debug_map_add",
            source_path: source_path,
            line: 3,
            params: [MilkTea::DebugMap::Entry.new(name: "left", c_name: "left", line: nil)],
            locals: [MilkTea::DebugMap::Entry.new(name: "int", c_name: "int_", line: 4)]
          )
        ]
      )
      debug_map.write(MilkTea::DebugMap.sidecar_path_for(binary_path))

      incoming = [
        { "seq" => 1, "type" => "request", "command" => "initialize", "arguments" => { "adapterID" => "milk-tea" } },
        { "seq" => 2, "type" => "request", "command" => "launch", "arguments" => { "backend" => "lldb-dap", "program" => binary_path, "stopOnEntry" => true } },
        { "seq" => 3, "type" => "request", "command" => "configurationDone", "arguments" => {} },
        { "seq" => 4, "type" => "request", "command" => "stackTrace", "arguments" => { "threadId" => 77 } },
        { "seq" => 5, "type" => "request", "command" => "scopes", "arguments" => { "frameId" => 1 } },
        { "seq" => 6, "type" => "request", "command" => "variables", "arguments" => { "variablesReference" => 99 } },
      ]
      protocol = InMemoryProtocol.new(incoming)

      server = MilkTea::DAP::Server.new(
        protocol: protocol,
        backend_factory: lambda do |_adapter_command, on_event|
          DebugMapBridgeBackend.new(on_event)
        end
      )

      server.run

      stack_response = find_response(protocol.written, 4)
      stack_body = stack_response["body"] || stack_response[:body]
      first_frame = stack_body["stackFrames"]&.first || stack_body[:stackFrames]&.first
      assert_equal "add", first_frame["name"] || first_frame[:name]

      variables_response = find_response(protocol.written, 6)
      variables_body = variables_response["body"] || variables_response[:body]
      variable_names = (variables_body["variables"] || variables_body[:variables]).map do |variable|
        variable["name"] || variable[:name]
      end
      assert_equal %w[int left], variable_names
    end
  end

  def test_lldb_backend_rewrites_evaluate_and_assignment_requests_from_debug_map_sidecar
    Dir.mktmpdir("milk-tea-dap-debug-map-expr") do |dir|
      source_path = File.join(dir, "demo.mt")
      binary_path = File.join(dir, "demo")
      File.write(source_path, "module demo.debug_map\n")
      File.write(binary_path, "")

      debug_map = MilkTea::DebugMap.new(
        binary_path: binary_path,
        program_source_path: source_path,
        functions: [
          MilkTea::DebugMap::Function.new(
            name: "add",
            c_name: "demo_debug_map_add",
            source_path: source_path,
            line: 3,
            params: [MilkTea::DebugMap::Entry.new(name: "left", c_name: "left", line: nil)],
            locals: [MilkTea::DebugMap::Entry.new(name: "int", c_name: "int_", line: 4)]
          )
        ]
      )
      debug_map.write(MilkTea::DebugMap.sidecar_path_for(binary_path))

      incoming = [
        { "seq" => 1, "type" => "request", "command" => "initialize", "arguments" => { "adapterID" => "milk-tea" } },
        { "seq" => 2, "type" => "request", "command" => "launch", "arguments" => { "backend" => "lldb-dap", "program" => binary_path, "stopOnEntry" => true } },
        { "seq" => 3, "type" => "request", "command" => "configurationDone", "arguments" => {} },
        { "seq" => 4, "type" => "request", "command" => "stackTrace", "arguments" => { "threadId" => 77 } },
        { "seq" => 5, "type" => "request", "command" => "scopes", "arguments" => { "frameId" => 1 } },
        { "seq" => 6, "type" => "request", "command" => "evaluate", "arguments" => { "expression" => "int + left", "frameId" => 1, "context" => "hover" } },
        { "seq" => 7, "type" => "request", "command" => "setExpression", "arguments" => { "expression" => "int", "value" => "left + 1", "frameId" => 1 } },
        { "seq" => 8, "type" => "request", "command" => "setVariable", "arguments" => { "variablesReference" => 99, "name" => "int", "value" => "left + 2" } },
      ]
      protocol = InMemoryProtocol.new(incoming)
      backend = nil

      server = MilkTea::DAP::Server.new(
        protocol: protocol,
        backend_factory: lambda do |_adapter_command, on_event|
          backend = DebugMapExpressionBackend.new(on_event)
          backend
        end
      )

      server.run

      caps_events = find_events(protocol.written, "capabilities")
      caps_body = caps_events.first[:body] || caps_events.first["body"]
      assert_equal true, caps_body[:supportsEvaluateForHovers] || caps_body["supportsEvaluateForHovers"]
      assert_equal true, caps_body[:supportsSetVariable] || caps_body["supportsSetVariable"]

      evaluate_response = find_response(protocol.written, 6)
      assert_equal true, evaluate_response["success"] || evaluate_response[:success]
      evaluate_body = evaluate_response["body"] || evaluate_response[:body]
      assert_equal "int_ + left", evaluate_body["result"] || evaluate_body[:result]

      set_expression_response = find_response(protocol.written, 7)
      assert_equal true, set_expression_response["success"] || set_expression_response[:success]
      set_expression_body = set_expression_response["body"] || set_expression_response[:body]
      assert_equal "left + 1", set_expression_body["value"] || set_expression_body[:value]

      set_variable_response = find_response(protocol.written, 8)
      assert_equal true, set_variable_response["success"] || set_variable_response[:success]
      set_variable_body = set_variable_response["body"] || set_variable_response[:body]
      assert_equal "left + 2", set_variable_body["value"] || set_variable_body[:value]

      evaluate_request = backend.requests.find { |command, _arguments| command == "evaluate" }
      refute_nil evaluate_request
      assert_equal "int_ + left", evaluate_request[1]["expression"]

      set_expression_request = backend.requests.find { |command, _arguments| command == "setExpression" }
      refute_nil set_expression_request
      assert_equal "int_", set_expression_request[1]["expression"]
      assert_equal "left + 1", set_expression_request[1]["value"]

      set_variable_request = backend.requests.find { |command, _arguments| command == "setVariable" }
      refute_nil set_variable_request
      assert_equal "int_", set_variable_request[1]["name"]
      assert_equal "left + 2", set_variable_request[1]["value"]
    end
  end

  def test_lldb_backend_synthesizes_set_variable_via_set_expression_when_backend_lacks_native_support
    Dir.mktmpdir("milk-tea-dap-debug-map-set-variable-fallback") do |dir|
      source_path = File.join(dir, "demo.mt")
      binary_path = File.join(dir, "demo")
      File.write(source_path, "module demo.debug_map\n")
      File.write(binary_path, "")

      debug_map = MilkTea::DebugMap.new(
        binary_path: binary_path,
        program_source_path: source_path,
        functions: [
          MilkTea::DebugMap::Function.new(
            name: "add",
            c_name: "demo_debug_map_add",
            source_path: source_path,
            line: 3,
            params: [MilkTea::DebugMap::Entry.new(name: "left", c_name: "left", line: nil)],
            locals: [MilkTea::DebugMap::Entry.new(name: "int", c_name: "int_", line: 4)]
          )
        ]
      )
      debug_map.write(MilkTea::DebugMap.sidecar_path_for(binary_path))

      incoming = [
        { "seq" => 1, "type" => "request", "command" => "initialize", "arguments" => { "adapterID" => "milk-tea" } },
        { "seq" => 2, "type" => "request", "command" => "launch", "arguments" => { "backend" => "lldb-dap", "program" => binary_path, "stopOnEntry" => true } },
        { "seq" => 3, "type" => "request", "command" => "configurationDone", "arguments" => {} },
        { "seq" => 4, "type" => "request", "command" => "stackTrace", "arguments" => { "threadId" => 77 } },
        { "seq" => 5, "type" => "request", "command" => "scopes", "arguments" => { "frameId" => 1 } },
        { "seq" => 6, "type" => "request", "command" => "setVariable", "arguments" => { "variablesReference" => 99, "name" => "int", "value" => "left + 3" } },
      ]
      protocol = InMemoryProtocol.new(incoming)
      backend = nil

      server = MilkTea::DAP::Server.new(
        protocol: protocol,
        backend_factory: lambda do |_adapter_command, on_event|
          backend = DebugMapBridgeBackend.new(on_event)
          backend
        end
      )

      server.run

      caps_events = find_events(protocol.written, "capabilities")
      caps_body = caps_events.first[:body] || caps_events.first["body"]
      assert_equal true, caps_body[:supportsSetVariable] || caps_body["supportsSetVariable"]

      set_variable_response = find_response(protocol.written, 6)
      assert_equal true, set_variable_response["success"] || set_variable_response[:success]
      set_variable_body = set_variable_response["body"] || set_variable_response[:body]
      assert_equal "left + 3", set_variable_body["value"] || set_variable_body[:value]

      set_expression_request = backend.requests.find { |command, _arguments| command == "setExpression" }
      refute_nil set_expression_request
      assert_equal "int_", set_expression_request[1]["expression"]
      assert_equal "left + 3", set_expression_request[1]["value"]
      assert_equal 1, set_expression_request[1]["frameId"]

      refute backend.requests.any? { |command, _arguments| command == "setVariable" }
    end
  end

  def test_lldb_backend_rewrites_data_breakpoint_info_from_debug_map_sidecar
    Dir.mktmpdir("milk-tea-dap-debug-map-data-breakpoint") do |dir|
      source_path = File.join(dir, "demo.mt")
      binary_path = File.join(dir, "demo")
      File.write(source_path, "module demo.debug_map\n")
      File.write(binary_path, "")

      debug_map = MilkTea::DebugMap.new(
        binary_path: binary_path,
        program_source_path: source_path,
        functions: [
          MilkTea::DebugMap::Function.new(
            name: "add",
            c_name: "demo_debug_map_add",
            source_path: source_path,
            line: 3,
            params: [MilkTea::DebugMap::Entry.new(name: "left", c_name: "left", line: nil)],
            locals: [MilkTea::DebugMap::Entry.new(name: "int", c_name: "int_", line: 4)]
          )
        ]
      )
      debug_map.write(MilkTea::DebugMap.sidecar_path_for(binary_path))

      incoming = [
        { "seq" => 1, "type" => "request", "command" => "initialize", "arguments" => { "adapterID" => "milk-tea" } },
        { "seq" => 2, "type" => "request", "command" => "launch", "arguments" => { "backend" => "lldb-dap", "program" => binary_path, "stopOnEntry" => true } },
        { "seq" => 3, "type" => "request", "command" => "configurationDone", "arguments" => {} },
        { "seq" => 4, "type" => "request", "command" => "stackTrace", "arguments" => { "threadId" => 77 } },
        { "seq" => 5, "type" => "request", "command" => "scopes", "arguments" => { "frameId" => 1 } },
        { "seq" => 6, "type" => "request", "command" => "dataBreakpointInfo", "arguments" => { "variablesReference" => 99, "name" => "int" } },
      ]
      protocol = InMemoryProtocol.new(incoming)
      backend = nil

      server = MilkTea::DAP::Server.new(
        protocol: protocol,
        backend_factory: lambda do |_adapter_command, on_event|
          backend = DebugMapBridgeBackend.new(on_event)
          backend
        end
      )

      server.run

      response = find_response(protocol.written, 6)
      assert_equal true, response["success"] || response[:success]
      body = response["body"] || response[:body]
      assert_equal "data:int_", body["dataId"] || body[:dataId]

      request = backend.requests.find { |command, _arguments| command == "dataBreakpointInfo" }
      refute_nil request
      assert_equal "int_", request[1]["name"]
    end
  end

  def test_lldb_backend_passthroughs_modern_dap_requests
    incoming = [
      { "seq" => 1, "type" => "request", "command" => "initialize", "arguments" => { "adapterID" => "milk-tea" } },
      { "seq" => 2, "type" => "request", "command" => "launch", "arguments" => { "backend" => "lldb-dap", "program" => "/usr/bin/true", "stopOnEntry" => true } },
      { "seq" => 3, "type" => "request", "command" => "configurationDone", "arguments" => {} },
      { "seq" => 4, "type" => "request", "command" => "exceptionInfo", "arguments" => { "threadId" => 77 } },
      { "seq" => 5, "type" => "request", "command" => "modules", "arguments" => { "startModule" => 0, "moduleCount" => 20 } },
      { "seq" => 6, "type" => "request", "command" => "readMemory", "arguments" => { "memoryReference" => "0x1000", "count" => 4 } },
      { "seq" => 7, "type" => "request", "command" => "disassemble", "arguments" => { "memoryReference" => "0x1000", "instructionCount" => 1 } },
      { "seq" => 8, "type" => "request", "command" => "dataBreakpointInfo", "arguments" => { "name" => "player.health", "frameId" => 1 } },
      { "seq" => 9, "type" => "request", "command" => "setDataBreakpoints", "arguments" => { "breakpoints" => [{ "dataId" => "data:player.health", "accessType" => "write" }] } },
      { "seq" => 10, "type" => "request", "command" => "setExpression", "arguments" => { "expression" => "x", "value" => "7", "frameId" => 1 } },
      { "seq" => 11, "type" => "request", "command" => "setInstructionBreakpoints", "arguments" => { "breakpoints" => [{ "instructionReference" => "0x1000", "offset" => 0 }] } },
      { "seq" => 12, "type" => "request", "command" => "breakpointLocations", "arguments" => { "source" => { "path" => "/tmp/demo.mt" }, "line" => 4, "endLine" => 4 } },
      { "seq" => 13, "type" => "request", "command" => "cancel", "arguments" => { "requestId" => 99 } },
      { "seq" => 14, "type" => "request", "command" => "disconnect", "arguments" => {} }
    ]

    protocol = InMemoryProtocol.new(incoming)
    backend = nil

    server = MilkTea::DAP::Server.new(
      protocol: protocol,
      backend_factory: lambda do |_adapter_command, on_event|
        backend = FakeBridgeBackend.new(on_event)
        backend
      end
    )

    server.run

    caps_events = find_events(protocol.written, "capabilities")
    caps_body = caps_events.first[:body] || caps_events.first["body"]
    assert_equal true, caps_body[:supportsExceptionInfoRequest] || caps_body["supportsExceptionInfoRequest"]
    assert_equal true, caps_body[:supportsModulesRequest] || caps_body["supportsModulesRequest"]
    assert_equal true, caps_body[:supportsReadMemoryRequest] || caps_body["supportsReadMemoryRequest"]
    assert_equal true, caps_body[:supportsDisassembleRequest] || caps_body["supportsDisassembleRequest"]
    assert_equal true, caps_body[:supportsDataBreakpoints] || caps_body["supportsDataBreakpoints"]
    assert_equal true, caps_body[:supportsInstructionBreakpoints] || caps_body["supportsInstructionBreakpoints"]
    assert_equal true, caps_body[:supportsSetExpression] || caps_body["supportsSetExpression"]
    assert_equal true, caps_body[:supportsBreakpointLocationsRequest] || caps_body["supportsBreakpointLocationsRequest"]
    assert_equal true, caps_body[:supportsCancelRequest] || caps_body["supportsCancelRequest"]

    exception_response = find_response(protocol.written, 4)
    assert_equal true, exception_response["success"] || exception_response[:success]
    exception_body = exception_response["body"] || exception_response[:body]
    assert_equal "demo.exception", exception_body["exceptionId"] || exception_body[:exceptionId]

    modules_response = find_response(protocol.written, 5)
    assert_equal true, modules_response["success"] || modules_response[:success]
    modules_body = modules_response["body"] || modules_response[:body]
    first_module = modules_body["modules"]&.first || modules_body[:modules]&.first
    assert_equal "main.mt", first_module["name"] || first_module[:name]

    memory_response = find_response(protocol.written, 6)
    assert_equal true, memory_response["success"] || memory_response[:success]
    memory_body = memory_response["body"] || memory_response[:body]
    assert_equal "AQIDBA==", memory_body["data"] || memory_body[:data]

    disassemble_response = find_response(protocol.written, 7)
    assert_equal true, disassemble_response["success"] || disassemble_response[:success]
    disassemble_body = disassemble_response["body"] || disassemble_response[:body]
    first_instruction = disassemble_body["instructions"]&.first || disassemble_body[:instructions]&.first
    assert_equal "mov x0, x0", first_instruction["instruction"] || first_instruction[:instruction]

    data_breakpoint_info_response = find_response(protocol.written, 8)
    assert_equal true, data_breakpoint_info_response["success"] || data_breakpoint_info_response[:success]
    data_breakpoint_info_body = data_breakpoint_info_response["body"] || data_breakpoint_info_response[:body]
    assert_equal "data:player.health", data_breakpoint_info_body["dataId"] || data_breakpoint_info_body[:dataId]

    set_data_breakpoints_response = find_response(protocol.written, 9)
    assert_equal true, set_data_breakpoints_response["success"] || set_data_breakpoints_response[:success]
    set_data_breakpoints_body = set_data_breakpoints_response["body"] || set_data_breakpoints_response[:body]
    first_data_breakpoint = set_data_breakpoints_body["breakpoints"]&.first || set_data_breakpoints_body[:breakpoints]&.first
    assert_equal true, first_data_breakpoint["verified"] || first_data_breakpoint[:verified]

    set_expression_response = find_response(protocol.written, 10)
    assert_equal true, set_expression_response["success"] || set_expression_response[:success]
    set_expression_body = set_expression_response["body"] || set_expression_response[:body]
    assert_equal "7", set_expression_body["value"] || set_expression_body[:value]

    set_instruction_breakpoints_response = find_response(protocol.written, 11)
    assert_equal true, set_instruction_breakpoints_response["success"] || set_instruction_breakpoints_response[:success]
    set_instruction_breakpoints_body = set_instruction_breakpoints_response["body"] || set_instruction_breakpoints_response[:body]
    first_instruction_breakpoint = set_instruction_breakpoints_body["breakpoints"]&.first || set_instruction_breakpoints_body[:breakpoints]&.first
    assert_equal true, first_instruction_breakpoint["verified"] || first_instruction_breakpoint[:verified]

    bp_locations_response = find_response(protocol.written, 12)
    assert_equal true, bp_locations_response["success"] || bp_locations_response[:success]
    bp_locations_body = bp_locations_response["body"] || bp_locations_response[:body]
    first_location = bp_locations_body["breakpoints"]&.first || bp_locations_body[:breakpoints]&.first
    assert_equal 4, first_location["line"] || first_location[:line]

    cancel_response = find_response(protocol.written, 13)
    assert_equal true, cancel_response["success"] || cancel_response[:success]

    backend_commands = backend.requests.map(&:first)
    assert_includes backend_commands, "exceptionInfo"
    assert_includes backend_commands, "modules"
    assert_includes backend_commands, "readMemory"
    assert_includes backend_commands, "disassemble"
    assert_includes backend_commands, "dataBreakpointInfo"
    assert_includes backend_commands, "setDataBreakpoints"
    assert_includes backend_commands, "setExpression"
    assert_includes backend_commands, "setInstructionBreakpoints"
    assert_includes backend_commands, "breakpointLocations"
    assert_includes backend_commands, "cancel"
  end

  def test_set_exception_breakpoints_returns_success_in_process_backend
    with_server do |client|
      _init, _init_events = client.send_request("initialize", { "adapterID" => "milk-tea" })
      response, _events = client.send_request("setExceptionBreakpoints", { "filters" => [] })
      assert_equal true, response["success"]
    end
  end

  def test_evaluate_returns_error_in_process_backend
    with_server do |client|
      _init, _init_events = client.send_request("initialize", { "adapterID" => "milk-tea" })
      _launch, _launch_events = client.send_request("launch", { "program" => "/usr/bin/true" })
      response, _events = client.send_request("evaluate", { "expression" => "x", "context" => "watch" })
      assert_equal false, response["success"]
      assert_match(/not supported/, response["message"])
    end
  end

  def test_source_returns_error_in_process_backend
    with_server do |client|
      _init, _init_events = client.send_request("initialize", { "adapterID" => "milk-tea" })
      response, _events = client.send_request("source", { "sourceReference" => 1 })
      assert_equal false, response["success"]
      assert_match(/not supported/, response["message"])
    end
  end

  def test_loaded_sources_returns_empty_in_process_backend
    with_server do |client|
      _init, _init_events = client.send_request("initialize", { "adapterID" => "milk-tea" })
      response, _events = client.send_request("loadedSources", {})
      assert_equal true, response["success"]
      assert_equal [], response.dig("body", "sources")
    end
  end

  def test_attach_requires_lldb_dap_backend
    with_server do |client|
      _init, _init_events = client.send_request("initialize", { "adapterID" => "milk-tea" })
      response, _events = client.send_request("attach", { "program" => "/usr/bin/true" })
      assert_equal false, response["success"]
      assert_match(/lldb-dap/, response["message"])
    end
  end

  def test_attach_without_program_forwards_pid_to_lldb_backend
    incoming = [
      { "seq" => 1, "type" => "request", "command" => "initialize", "arguments" => { "adapterID" => "milk-tea" } },
      { "seq" => 2, "type" => "request", "command" => "attach", "arguments" => { "backend" => "lldb-dap", "pid" => 4242 } },
      { "seq" => 3, "type" => "request", "command" => "disconnect", "arguments" => {} }
    ]

    protocol = InMemoryProtocol.new(incoming)
    backend = nil

    server = MilkTea::DAP::Server.new(
      protocol: protocol,
      backend_factory: lambda do |_adapter_command, on_event|
        backend = FakeBridgeBackend.new(on_event)
        backend
      end
    )

    server.run

    attach_response = find_response(protocol.written, 2)
    assert_equal true, attach_response["success"] || attach_response[:success]

    attach_request = backend.requests.find { |command, _arguments| command == "attach" }
    refute_nil attach_request
    attach_arguments = attach_request[1]
    assert_equal 4242, attach_arguments["pid"]
    refute attach_arguments.key?("program")
  end

  def test_attach_without_program_autoloads_debug_map_from_backend_modules
    Dir.mktmpdir("milk-tea-dap-attach-debug-map") do |dir|
      source_path = File.join(dir, "demo.mt")
      binary_path = File.join(dir, "demo")
      File.write(source_path, "module demo.debug_map\n")
      File.write(binary_path, "")

      MilkTea::DebugMap.new(
        binary_path: binary_path,
        program_source_path: source_path,
        functions: [
          MilkTea::DebugMap::Function.new(
            name: "add",
            c_name: "demo_debug_map_add",
            source_path: source_path,
            line: 3,
            params: [MilkTea::DebugMap::Entry.new(name: "left", c_name: "left", line: nil)],
            locals: [MilkTea::DebugMap::Entry.new(name: "int", c_name: "int_", line: 4)]
          )
        ]
      ).write(MilkTea::DebugMap.sidecar_path_for(binary_path))

      incoming = [
        { "seq" => 1, "type" => "request", "command" => "initialize", "arguments" => { "adapterID" => "milk-tea" } },
        { "seq" => 2, "type" => "request", "command" => "attach", "arguments" => { "backend" => "lldb-dap", "pid" => 4242 } },
        { "seq" => 3, "type" => "request", "command" => "configurationDone", "arguments" => {} },
        { "seq" => 4, "type" => "request", "command" => "stackTrace", "arguments" => { "threadId" => 77 } },
        { "seq" => 5, "type" => "request", "command" => "scopes", "arguments" => { "frameId" => 1 } },
        { "seq" => 6, "type" => "request", "command" => "variables", "arguments" => { "variablesReference" => 99 } },
        { "seq" => 7, "type" => "request", "command" => "disconnect", "arguments" => {} }
      ]
      protocol = InMemoryProtocol.new(incoming)
      backend = nil

      server = MilkTea::DAP::Server.new(
        protocol: protocol,
        backend_factory: lambda do |_adapter_command, on_event|
          backend = AttachDebugMapBridgeBackend.new(binary_path, on_event)
          backend
        end
      )

      server.run

      stack_response = find_response(protocol.written, 4)
      stack_body = stack_response["body"] || stack_response[:body]
      first_frame = stack_body["stackFrames"]&.first || stack_body[:stackFrames]&.first
      assert_equal "add", first_frame["name"] || first_frame[:name]

      variables_response = find_response(protocol.written, 6)
      variables_body = variables_response["body"] || variables_response[:body]
      variable_names = (variables_body["variables"] || variables_body[:variables]).map do |variable|
        variable["name"] || variable[:name]
      end
      assert_equal %w[int left], variable_names

      modules_request = backend.requests.find { |command, _arguments| command == "modules" }
      refute_nil modules_request
    end
  end

  def test_lldb_backend_surfaces_nested_attach_error_messages
    incoming = [
      { "seq" => 1, "type" => "request", "command" => "initialize", "arguments" => { "adapterID" => "milk-tea" } },
      { "seq" => 2, "type" => "request", "command" => "attach", "arguments" => { "backend" => "lldb-dap", "pid" => 4242 } },
    ]

    protocol = InMemoryProtocol.new(incoming)

    server = MilkTea::DAP::Server.new(
      protocol: protocol,
      backend_factory: lambda do |_adapter_command, on_event|
        Class.new do
          def initialize(on_event)
            @on_event = on_event
          end

          def start! = true
          def stop! = true

          def request(command, arguments, timeout: 5)
            _arguments = arguments
            _timeout = timeout

            case command
            when "initialize"
              { "success" => true, "body" => { "supportsConfigurationDoneRequest" => true } }
            when "attach"
              @on_event.call({ "type" => "event", "event" => "initialized" })
              {
                "success" => false,
                "body" => {
                  "error" => {
                    "id" => 3,
                    "format" => "ptrace attach is blocked by ptrace_scope"
                  }
                }
              }
            else
              { "success" => true, "body" => {} }
            end
          end
        end.new(on_event)
      end
    )

    server.run

    response = find_response(protocol.written, 2)
    assert_equal false, response["success"] || response[:success]
    assert_equal "ptrace attach is blocked by ptrace_scope", response["message"] || response[:message]
  end

  def test_restart_returns_error_in_process_backend
    with_server do |client|
      _init, _init_events = client.send_request("initialize", { "adapterID" => "milk-tea" })
      _launch, _launch_events = client.send_request("launch", { "program" => "/usr/bin/true" })
      response, _events = client.send_request("restart", {})
      assert_equal false, response["success"]
      assert_match(/not supported/, response["message"])
    end
  end

  def test_lldb_backend_sync_preserves_conditional_breakpoint_metadata
    incoming = [
      { "seq" => 1, "type" => "request", "command" => "initialize", "arguments" => { "adapterID" => "milk-tea" } },
      { "seq" => 2, "type" => "request", "command" => "setBreakpoints", "arguments" => {
        "source" => { "path" => "/tmp/demo.mt" },
        "breakpoints" => [{ "line" => 4, "condition" => "tick == 60", "hitCondition" => ">= 2", "logMessage" => "tick={tick}" }]
      } },
      { "seq" => 3, "type" => "request", "command" => "launch", "arguments" => { "backend" => "lldb-dap", "program" => "/usr/bin/true", "stopOnEntry" => true } },
      { "seq" => 4, "type" => "request", "command" => "configurationDone", "arguments" => {} },
      { "seq" => 5, "type" => "request", "command" => "disconnect", "arguments" => {} }
    ]

    protocol = InMemoryProtocol.new(incoming)
    backend = nil

    server = MilkTea::DAP::Server.new(
      protocol: protocol,
      backend_factory: lambda do |_adapter_command, on_event|
        backend = FakeBridgeBackend.new(on_event)
        backend
      end
    )

    server.run

    set_breakpoints_requests = backend.requests.select { |command, _arguments| command == "setBreakpoints" }
    assert_equal 1, set_breakpoints_requests.length

    breakpoint = set_breakpoints_requests.first[1].dig("breakpoints", 0)
    assert_equal 4, breakpoint["line"]
    assert_equal "tick == 60", breakpoint["condition"]
    assert_equal ">= 2", breakpoint["hitCondition"]
    assert_equal "tick={tick}", breakpoint["logMessage"]
  end

  def test_lldb_backend_syncs_function_breakpoints_after_configuration_done
    incoming = [
      { "seq" => 1, "type" => "request", "command" => "initialize", "arguments" => { "adapterID" => "milk-tea" } },
      { "seq" => 2, "type" => "request", "command" => "setFunctionBreakpoints", "arguments" => {
        "breakpoints" => [{ "name" => "demo.update", "condition" => "tick == 60" }]
      } },
      { "seq" => 3, "type" => "request", "command" => "launch", "arguments" => { "backend" => "lldb-dap", "program" => "/usr/bin/true", "stopOnEntry" => true } },
      { "seq" => 4, "type" => "request", "command" => "configurationDone", "arguments" => {} },
      { "seq" => 5, "type" => "request", "command" => "disconnect", "arguments" => {} }
    ]

    protocol = InMemoryProtocol.new(incoming)
    backend = Class.new do
      attr_reader :requests

      def initialize(on_event)
        @on_event = on_event
        @requests = []
      end

      def start! = true
      def stop! = true

      def request(command, arguments, timeout: 5)
        _timeout = timeout
        @requests << [command, arguments]

        case command
        when "initialize"
          { "success" => true, "body" => { "supportsConfigurationDoneRequest" => true } }
        when "launch"
          { "success" => true, "body" => {} }
        when "setFunctionBreakpoints"
          {
            "success" => true,
            "body" => {
              "breakpoints" => [{ "id" => 77, "verified" => true, "name" => "demo.update" }]
            }
          }
        when "configurationDone"
          @on_event.call({ "type" => "event", "event" => "stopped", "body" => { "reason" => "entry", "threadId" => 1 } })
          { "success" => true, "body" => {} }
        when "disconnect"
          @on_event.call({ "type" => "event", "event" => "terminated" })
          @on_event.call({ "type" => "event", "event" => "exited", "body" => { "exitCode" => 0 } })
          { "success" => true, "body" => {} }
        else
          { "success" => true, "body" => {} }
        end
      end
    end.new(nil)

    server = MilkTea::DAP::Server.new(
      protocol: protocol,
      backend_factory: lambda do |_adapter_command, on_event|
        backend.instance_variable_set(:@on_event, on_event)
        backend
      end
    )

    server.run

    function_request = backend.requests.find { |command, _arguments| command == "setFunctionBreakpoints" }
    refute_nil function_request
    breakpoint = function_request[1].dig("breakpoints", 0)
    assert_equal "demo.update", breakpoint["name"]
    assert_equal "tick == 60", breakpoint["condition"]

    response = find_response(protocol.written, 2)
    assert_equal true, response["success"] || response[:success]
  end

  def test_lldb_backend_emits_breakpoint_event_when_sync_adjusts_line
    # setBreakpoints BEFORE launch -> stored in session; on configurationDone, sync sends
    # them to backend which returns adjusted line 5 (from requested line 4); a breakpoint
    # "changed" event must be emitted.
    incoming = [
      { "seq" => 1, "type" => "request", "command" => "initialize", "arguments" => { "adapterID" => "milk-tea" } },
      { "seq" => 2, "type" => "request", "command" => "setBreakpoints", "arguments" => { "source" => { "path" => "/tmp/demo.mt" }, "breakpoints" => [{ "line" => 4 }] } },
      { "seq" => 3, "type" => "request", "command" => "launch", "arguments" => { "backend" => "lldb-dap", "program" => "/usr/bin/true", "stopOnEntry" => true } },
      { "seq" => 4, "type" => "request", "command" => "configurationDone", "arguments" => {} },
      { "seq" => 5, "type" => "request", "command" => "disconnect", "arguments" => {} }
    ]

    protocol = InMemoryProtocol.new(incoming)
    adjusted_line_backend = Class.new do
      attr_reader :requests

      def initialize(on_event)
        @on_event = on_event
        @requests = []
      end

      def start! = true
      def stop! = true

      def request(command, arguments, timeout: 5)
        @requests << [command, arguments]
        case command
        when "initialize"
          { "success" => true, "body" => {} }
        when "launch"
          { "success" => true, "body" => {} }
        when "setBreakpoints"
          # Return adjusted line 5 (was 4) to trigger a breakpoint changed event
          { "success" => true, "body" => { "breakpoints" => [{ "id" => 99, "verified" => true, "line" => 5 }] } }
        when "configurationDone"
          @on_event.call({ "type" => "event", "event" => "stopped", "body" => { "reason" => "entry", "threadId" => 1 } })
          { "success" => true, "body" => {} }
        when "disconnect"
          @on_event.call({ "type" => "event", "event" => "terminated" })
          @on_event.call({ "type" => "event", "event" => "exited", "body" => { "exitCode" => 0 } })
          { "success" => true, "body" => {} }
        else
          { "success" => false, "message" => "unsupported" }
        end
      end
    end.new(nil)

    server = MilkTea::DAP::Server.new(
      protocol: protocol,
      backend_factory: lambda do |_adapter_command, on_event|
        adjusted_line_backend.instance_variable_set(:@on_event, on_event)
        adjusted_line_backend
      end
    )

    server.run

    bp_events = find_events(protocol.written, "breakpoint")
    assert_equal true, bp_events.any?, "expected breakpoint changed event after sync adjusted line"

    bp_event = bp_events.first
    bp_body = bp_event[:body] || bp_event["body"]
    changed_bp = bp_body[:breakpoint] || bp_body["breakpoint"]
    assert_equal 5, changed_bp[:line] || changed_bp["line"]
    assert_equal true, changed_bp[:verified] || changed_bp["verified"]
  end

  def test_lldb_backend_processes_configuration_requests_while_launch_is_pending
    incoming = [
      { "seq" => 1, "type" => "request", "command" => "initialize", "arguments" => { "adapterID" => "milk-tea" } },
      { "seq" => 2, "type" => "request", "command" => "launch", "arguments" => { "backend" => "lldb-dap", "program" => "/usr/bin/true", "stopOnEntry" => true } },
      { "seq" => 3, "type" => "request", "command" => "setBreakpoints", "arguments" => {
        "source" => { "path" => "/tmp/demo.mt" },
        "breakpoints" => [{ "line" => 4 }]
      } },
      { "seq" => 4, "type" => "request", "command" => "configurationDone", "arguments" => {} },
      { "seq" => 5, "type" => "request", "command" => "disconnect", "arguments" => {} }
    ]

    protocol = InMemoryProtocol.new(incoming)
    backend = nil

    server = MilkTea::DAP::Server.new(
      protocol: protocol,
      backend_factory: lambda do |_adapter_command, on_event|
        backend = DeferredLaunchBridgeBackend.new(on_event)
        backend
      end
    )

    server.run

    launch_response = find_response(protocol.written, 2)
    assert_equal true, launch_response["success"] || launch_response[:success]

    config_response = find_response(protocol.written, 4)
    assert_equal true, config_response["success"] || config_response[:success]

    breakpoints_response = find_response(protocol.written, 3)
    assert_equal true, breakpoints_response["success"] || breakpoints_response[:success]

    assert backend.requests.any? { |command, _arguments| command == "setBreakpoints" }
    assert backend.requests.any? { |command, _arguments| command == "configurationDone" }

    stopped_events = find_events(protocol.written, "stopped")
    assert_equal true, stopped_events.any?
  end

  def test_lldb_backend_holds_launch_at_entry_and_auto_continues_after_configuration_when_stop_on_entry_is_false
    incoming = [
      { "seq" => 1, "type" => "request", "command" => "initialize", "arguments" => { "adapterID" => "milk-tea" } },
      { "seq" => 2, "type" => "request", "command" => "launch", "arguments" => { "backend" => "lldb-dap", "program" => "/usr/bin/true", "stopOnEntry" => false } },
      { "seq" => 3, "type" => "request", "command" => "setBreakpoints", "arguments" => {
        "source" => { "path" => "/tmp/demo.mt" },
        "breakpoints" => [{ "line" => 4 }]
      } },
      { "seq" => 4, "type" => "request", "command" => "configurationDone", "arguments" => {} },
      { "seq" => 5, "type" => "request", "command" => "disconnect", "arguments" => {} }
    ]

    protocol = InMemoryProtocol.new(incoming)
    backend = nil

    server = MilkTea::DAP::Server.new(
      protocol: protocol,
      backend_factory: lambda do |_adapter_command, on_event|
        backend = EntryStopLaunchBridgeBackend.new(on_event)
        backend
      end
    )

    server.run

    launch_request = backend.requests.find { |command, _arguments| command == "launch" }
    refute_nil launch_request
    assert_equal true, launch_request[1]["stopOnEntry"]
    refute launch_request[1].key?("backend")

    continue_request = backend.requests.find { |command, _arguments| command == "continue" }
    refute_nil continue_request
    assert_equal 77, continue_request[1]["threadId"]

    configuration_done_response = find_response(protocol.written, 4)
    assert_equal true, configuration_done_response["success"] || configuration_done_response[:success]

    initialized_events = find_events(protocol.written, "initialized")
    assert_equal 1, initialized_events.length
  end

  def test_lldb_backend_rewrites_sigstop_pause_stop_to_pause_reason
    incoming = [
      { "seq" => 1, "type" => "request", "command" => "initialize", "arguments" => { "adapterID" => "milk-tea" } },
      { "seq" => 2, "type" => "request", "command" => "launch", "arguments" => { "backend" => "lldb-dap", "program" => "/usr/bin/true", "stopOnEntry" => false } },
      { "seq" => 3, "type" => "request", "command" => "configurationDone", "arguments" => {} },
      { "seq" => 4, "type" => "request", "command" => "pause", "arguments" => { "threadId" => 77 } },
      { "seq" => 5, "type" => "request", "command" => "disconnect", "arguments" => {} }
    ]

    protocol = InMemoryProtocol.new(incoming)
    backend = nil

    server = MilkTea::DAP::Server.new(
      protocol: protocol,
      backend_factory: lambda do |_adapter_command, on_event|
        backend = Class.new do
          attr_reader :requests

          def initialize(on_event)
            @on_event = on_event
            @requests = []
          end

          def start! = true
          def stop! = true

          def request(command, arguments, timeout: 5)
            _timeout = timeout
            @requests << [command, arguments]

            case command
            when "initialize"
              { "success" => true, "body" => { "supportsConfigurationDoneRequest" => true } }
            when "launch"
              { "success" => true, "body" => {} }
            when "configurationDone"
              { "success" => true, "body" => {} }
            when "continue"
              { "success" => true, "body" => { "allThreadsContinued" => true } }
            when "pause"
              @on_event.call({
                "type" => "event",
                "event" => "stopped",
                "body" => {
                  "reason" => "exception",
                  "description" => "signal SIGSTOP",
                  "threadId" => 77,
                  "allThreadsStopped" => true
                }
              })
              { "success" => true, "body" => {} }
            when "stackTrace"
              {
                "success" => true,
                "body" => {
                  "stackFrames" => [
                    {
                      "id" => 0,
                      "name" => "___lldb_unnamed_symbol_9ef00",
                      "line" => 15,
                      "column" => 1,
                      "instructionPointerReference" => "0x7FFFF7A9EF32",
                      "source" => {
                        "name" => "___lldb_unnamed_symbol_9ef00",
                        "path" => "/usr/lib/libc.so.6`___lldb_unnamed_symbol_9ef00"
                      }
                    },
                    {
                      "id" => 1,
                      "name" => "SyncRendering",
                      "line" => 1244,
                      "column" => 12,
                      "instructionPointerReference" => "0x7FFFF034C2DA",
                      "source" => {
                        "name" => "wayland-surface.c",
                        "path" => "/usr/src/debug/egl-wayland2/egl-wayland2/src/wayland/wayland-surface.c"
                      }
                    },
                    {
                      "id" => 2,
                      "name" => "eplWlSwapBuffers",
                      "line" => 1366,
                      "column" => 10,
                      "instructionPointerReference" => "0x7FFFF034C2AD",
                      "source" => {
                        "name" => "wayland-surface.c",
                        "path" => "/usr/src/debug/egl-wayland2/egl-wayland2/src/wayland/wayland-surface.c"
                      }
                    },
                    {
                      "id" => 3,
                      "name" => "main",
                      "line" => 53,
                      "column" => 5,
                      "instructionPointerReference" => "0x555555559CED",
                      "source" => {
                        "name" => "milk-tea-demo.mt",
                        "path" => "/home/teefan/Projects/Ruby/mt-lang/examples/milk-tea-demo.mt"
                      }
                    }
                  ],
                  "totalFrames" => 4
                }
              }
            when "disconnect"
              @on_event.call({ "type" => "event", "event" => "terminated" })
              @on_event.call({ "type" => "event", "event" => "exited", "body" => { "exitCode" => 0 } })
              { "success" => true, "body" => {} }
            else
              { "success" => true, "body" => {} }
            end
          end
        end.new(on_event)
        backend
      end
    )

    server.run

    pause_response = find_response(protocol.written, 4)
    assert_equal true, pause_response["success"] || pause_response[:success]

    stopped_events = find_events(protocol.written, "stopped")
    pause_event = stopped_events.find do |event|
      body = event["body"] || event[:body]
      (body["threadId"] || body[:threadId]) == 77
    end
    refute_nil pause_event

    pause_body = pause_event["body"] || pause_event[:body]
    assert_equal "pause", pause_body["reason"] || pause_body[:reason]
    assert_equal "Paused", pause_body["description"] || pause_body[:description]

    pause_request = backend.requests.find { |command, _arguments| command == "pause" }
    refute_nil pause_request

    stack_trace_request = backend.requests.find { |command, arguments| command == "stackTrace" && arguments["threadId"] == 77 }
    refute_nil stack_trace_request

    output_events = find_events(protocol.written, "output")
    pause_output = output_events.find do |event|
      body = event["body"] || event[:body]
      output = (body["output"] || body[:output]).to_s
      output.include?("[milk-tea dap] pause focus thread=77: SyncRendering @ /usr/src/debug/egl-wayland2/egl-wayland2/src/wayland/wayland-surface.c:1244 <- eplWlSwapBuffers @ /usr/src/debug/egl-wayland2/egl-wayland2/src/wayland/wayland-surface.c:1366 <- main @ /home/teefan/Projects/Ruby/mt-lang/examples/milk-tea-demo.mt:53") &&
        output.include?("raw=___lldb_unnamed_symbol_9ef00 @ ___lldb_unnamed_symbol_9ef00:15 ip=0x7FFFF7A9EF32")
    end
    refute_nil pause_output
  end

  def test_lldb_backend_reverse_run_in_terminal_request_is_forwarded_to_client
    stdin_read, stdin_write = IO.pipe
    stdout_read, stdout_write = IO.pipe

    server = MilkTea::DAP::Server.new(
      protocol: MilkTea::DAP::Protocol.new(input: stdin_read, output: stdout_write),
      backend_factory: lambda do |_adapter_command, on_event, on_request|
        ReverseRequestBackend.new(on_event, on_request)
      end
    )

    thread = Thread.new { server.run }
    client = DAPClient.new(stdin_write, stdout_read)

    init_response, _init_events = client.send_request("initialize", { "adapterID" => "milk-tea", "supportsRunInTerminalRequest" => true })
    assert_equal true, init_response["success"]

    launch_response, _launch_events = client.send_request("launch", {
      "backend" => "lldb-dap",
      "program" => "/usr/bin/true",
      "stopOnEntry" => true
    })
    assert_equal true, launch_response["success"]

    conf_request = {
      seq: client.instance_variable_get(:@next_seq),
      type: "request",
      command: "configurationDone",
      arguments: {}
    }
    client.instance_variable_set(:@next_seq, conf_request[:seq] + 1)
    client.send(:write_message, conf_request)

    reverse_request = nil
    conf_response = nil
    events = []

    Timeout.timeout(5) do
      loop do
        message = client.send(:read_message)
        next if message.nil?

        if message["type"] == "request" && message["command"] == "runInTerminal"
          reverse_request = message
          client.send(:send_response, message["seq"], "runInTerminal", { "processId" => 1234, "shellProcessId" => 5678 })
          next
        end

        if message["type"] == "event"
          events << message
          next
        end

        next unless message["type"] == "response"
        next unless message["request_seq"] == conf_request[:seq]

        conf_response = message
        break
      end
    end

    assert_equal "runInTerminal", reverse_request["command"]
    assert_equal ["/usr/bin/true"], reverse_request.dig("arguments", "args")
    assert_equal true, conf_response["success"]
    assert_equal 1234, conf_response.dig("body", "terminalProcessId")
    assert_includes events.map { |e| e["event"] }, "stopped"

    disconnect_response, disconnect_events = client.send_request("disconnect", {})
    assert_equal true, disconnect_response["success"]
    assert_includes disconnect_events.map { |e| e["event"] }, "terminated"
  ensure
    stdin_write&.close
    stdout_read&.close
    thread&.join(1)
  end

  def test_lldb_backend_bridges_requests_and_events
    skip "set RUN_DAP_BRIDGE_TEST=1 to run lldb backend bridge integration test" unless ENV["RUN_DAP_BRIDGE_TEST"] == "1"

    with_fake_lldb_adapter do |adapter_path|
      with_server do |client|
        _init_response, _init_events = client.send_request("initialize", { "adapterID" => "milk-tea" })

        launch_response, launch_events = client.send_request("launch", {
          "backend" => "lldb-dap",
          "adapterPath" => adapter_path,
          "program" => "/usr/bin/true",
          "stopOnEntry" => true
        })
        assert_equal true, launch_response["success"]
        assert_equal [], launch_events

        breakpoints_response, _breakpoint_events = client.send_request("setBreakpoints", {
          "source" => { "path" => "/tmp/demo.mt" },
          "breakpoints" => [{ "line" => 4 }]
        })
        assert_equal true, breakpoints_response["success"]
        assert_equal 100, breakpoints_response.dig("body", "breakpoints", 0, "id")

        conf_response, conf_events = client.send_request("configurationDone", {})
        assert_equal true, conf_response["success"]
        assert_includes conf_events.map { |e| e["event"] }, "stopped"

        threads_response, _thread_events = client.send_request("threads", {})
        assert_equal true, threads_response["success"]
        assert_equal 99, threads_response.dig("body", "threads", 0, "id")

        next_response, next_events = client.send_request("next", { "threadId" => 99 })
        assert_equal true, next_response["success"]
        assert_includes next_events.map { |e| e["event"] }, "stopped"

        disconnect_response, disconnect_events = client.send_request("disconnect", {})
        assert_equal true, disconnect_response["success"]
        event_names = disconnect_events.map { |e| e["event"] }
        assert_includes event_names, "terminated"
        assert_includes event_names, "exited"
      end
    end
  end

  def test_real_lldb_dap_smoke_rewrites_frames_and_locals
    lldb_dap_path = command_path_for(ENV.fetch("LLDB_DAP", "lldb-dap"))
    skip "lldb-dap not available" unless lldb_dap_path
    skip "C compiler not available: #{ENV.fetch("CC", "cc")}" unless command_available?(ENV.fetch("CC", "cc"))

    Dir.mktmpdir("milk-tea-real-lldb-dap") do |dir|
      source_path = File.join(dir, "real_debug.mt")
      File.write(source_path, [
        "module demo.real_debug",
        "",
        "def add(left: int) -> int:",
        "    let next_value = left + 1",
        "    return next_value",
        "",
        "def main() -> int:",
        "    return add(41)",
        "",
      ].join("\n"))

      with_server(preferred_backend_kind: "lldb-dap", adapter_command: [lldb_dap_path]) do |client|
        init_response, _init_events = client.send_request("initialize", { "adapterID" => "milk-tea" })
        assert_equal true, init_response["success"]

        launch_request_seq = client.start_request("launch", {
          "backend" => "lldb-dap",
          "program" => source_path,
          "stopOnEntry" => true,
        })

        breakpoints_request_seq = client.start_request("setBreakpoints", {
          "source" => { "path" => source_path },
          "breakpoints" => [{ "line" => 5 }]
        })
        configuration_done_request_seq = client.start_request("configurationDone", {})

        breakpoints_response, breakpoints_events = client.wait_for_response(breakpoints_request_seq, timeout: 30)
        assert_equal true, breakpoints_response["success"]
        refute_nil breakpoints_response.dig("body", "breakpoints", 0)

        conf_response, conf_events = client.wait_for_response(configuration_done_request_seq, timeout: 30)
        assert_equal true, conf_response["success"]

        launch_response, launch_events = client.wait_for_response(launch_request_seq, timeout: 30)
        assert_equal true, launch_response["success"]

        entry_stop = (breakpoints_events + conf_events + launch_events).find { |event| event["event"] == "stopped" }
        entry_stop ||= client.wait_for_event("stopped", timeout: 30)
        refute_nil entry_stop

        thread_id = entry_stop.dig("body", "threadId")
        refute_nil thread_id

        continue_request_seq = client.start_request("continue", { "threadId" => thread_id })
        continue_response, continue_events = client.wait_for_response(continue_request_seq, timeout: 30)
        assert_equal true, continue_response["success"]

        breakpoint_stop = continue_events.find { |event| event["event"] == "stopped" }
        breakpoint_stop ||= client.wait_for_event("stopped", timeout: 30)
        refute_nil breakpoint_stop

        threads_request_seq = client.start_request("threads", {})
        threads_response, _thread_events = client.wait_for_response(threads_request_seq, timeout: 30)
        assert_equal true, threads_response["success"]
        thread_id = threads_response.dig("body", "threads", 0, "id")
        refute_nil thread_id

        stack_request_seq = client.start_request("stackTrace", { "threadId" => thread_id })
        stack_response, _stack_events = client.wait_for_response(stack_request_seq, timeout: 30)
        assert_equal true, stack_response["success"]
        first_frame = stack_response.dig("body", "stackFrames", 0)
        refute_nil first_frame
        assert_equal "add", first_frame["name"]
        assert_equal File.expand_path(source_path), first_frame.dig("source", "path")

        scopes_request_seq = client.start_request("scopes", { "frameId" => first_frame["id"] })
        scopes_response, _scope_events = client.wait_for_response(scopes_request_seq, timeout: 30)
        assert_equal true, scopes_response["success"]
        locals_scope = scopes_response.dig("body", "scopes")&.find { |scope| scope["name"] == "Locals" }
        refute_nil locals_scope

        variables_request_seq = client.start_request("variables", { "variablesReference" => locals_scope["variablesReference"] })
        variables_response, _variable_events = client.wait_for_response(variables_request_seq, timeout: 30)
        assert_equal true, variables_response["success"]
        variable_names = variables_response.fetch("body").fetch("variables").map { |variable| variable["name"] }
        assert_includes variable_names, "left"
        assert_includes variable_names, "next_value"

        disconnect_request_seq = client.start_request("disconnect", {})
        disconnect_response, disconnect_events = client.wait_for_response(disconnect_request_seq, timeout: 30)
        assert_equal true, disconnect_response["success"]
        event_names = disconnect_events.map { |event| event["event"] }
        assert_includes event_names, "terminated"
      end
    end
  end

  def test_real_lldb_dap_smoke_hits_data_breakpoint_on_rewritten_local
    lldb_dap_path = command_path_for(ENV.fetch("LLDB_DAP", "lldb-dap"))
    skip "lldb-dap not available" unless lldb_dap_path
    skip "C compiler not available: #{ENV.fetch("CC", "cc")}" unless command_available?(ENV.fetch("CC", "cc"))

    Dir.mktmpdir("milk-tea-real-lldb-dap-watch") do |dir|
      source_path = File.join(dir, "watch.mt")
      File.write(source_path, [
        "module demo.watch",
        "",
        "def add(left: int) -> int:",
        "    var watched = left",
        "    watched += 1",
        "    watched += 1",
        "    return watched",
        "",
        "def main() -> int:",
        "    return add(40)",
        "",
      ].join("\n"))

      with_server(preferred_backend_kind: "lldb-dap", adapter_command: [lldb_dap_path]) do |client|
        init_response, _init_events = client.send_request("initialize", { "adapterID" => "milk-tea" })
        assert_equal true, init_response["success"]

        launch_request_seq = client.start_request("launch", {
          "backend" => "lldb-dap",
          "program" => source_path,
          "stopOnEntry" => true,
        })

        breakpoints_request_seq = client.start_request("setBreakpoints", {
          "source" => { "path" => source_path },
          "breakpoints" => [{ "line" => 5 }]
        })
        configuration_done_request_seq = client.start_request("configurationDone", {})

        breakpoints_response, breakpoints_events = client.wait_for_response(breakpoints_request_seq, timeout: 30)
        assert_equal true, breakpoints_response["success"]
        assert_equal true, breakpoints_response.dig("body", "breakpoints", 0, "verified")

        conf_response, conf_events = client.wait_for_response(configuration_done_request_seq, timeout: 30)
        assert_equal true, conf_response["success"]

        launch_response, launch_events = client.wait_for_response(launch_request_seq, timeout: 30)
        assert_equal true, launch_response["success"]

        entry_stop = (breakpoints_events + conf_events + launch_events).find { |event| event["event"] == "stopped" }
        entry_stop ||= client.wait_for_event("stopped", timeout: 30)
        refute_nil entry_stop
        thread_id = entry_stop.dig("body", "threadId")
        refute_nil thread_id
        assert_equal "entry", entry_stop.dig("body", "reason")

        continue_request_seq = client.start_request("continue", { "threadId" => thread_id })
        continue_response, continue_events = client.wait_for_response(continue_request_seq, timeout: 30)
        assert_equal true, continue_response["success"]

        source_break_stop = continue_events.find { |event| event["event"] == "stopped" }
        source_break_stop ||= client.wait_for_event("stopped", timeout: 30)
        refute_nil source_break_stop
        assert_equal "breakpoint", source_break_stop.dig("body", "reason")

        stack_request_seq = client.start_request("stackTrace", { "threadId" => thread_id })
        stack_response, _stack_events = client.wait_for_response(stack_request_seq, timeout: 30)
        assert_equal true, stack_response["success"]
        first_frame = stack_response.dig("body", "stackFrames", 0)
        refute_nil first_frame
        assert_equal "add", first_frame["name"]

        scopes_request_seq = client.start_request("scopes", { "frameId" => first_frame["id"] })
        scopes_response, _scope_events = client.wait_for_response(scopes_request_seq, timeout: 30)
        assert_equal true, scopes_response["success"]
        locals_scope = scopes_response.dig("body", "scopes")&.find { |scope| scope["name"] == "Locals" }
        refute_nil locals_scope

        variables_request_seq = client.start_request("variables", { "variablesReference" => locals_scope["variablesReference"] })
        variables_response, _variable_events = client.wait_for_response(variables_request_seq, timeout: 30)
        assert_equal true, variables_response["success"]
        variable_names = variables_response.fetch("body").fetch("variables").map { |variable| variable["name"] }
        assert_includes variable_names, "left"
        assert_includes variable_names, "watched"

        data_breakpoint_info_request_seq = client.start_request("dataBreakpointInfo", {
          "variablesReference" => locals_scope["variablesReference"],
          "name" => "watched"
        })
        data_breakpoint_info_response, _data_breakpoint_info_events = client.wait_for_response(data_breakpoint_info_request_seq, timeout: 30)
        assert_equal true, data_breakpoint_info_response["success"]
        data_id = data_breakpoint_info_response.dig("body", "dataId")
        refute_nil data_id

        set_data_breakpoints_request_seq = client.start_request("setDataBreakpoints", {
          "breakpoints" => [{ "dataId" => data_id, "accessType" => "write" }]
        })
        set_data_breakpoints_response, _set_data_breakpoints_events = client.wait_for_response(set_data_breakpoints_request_seq, timeout: 30)
        assert_equal true, set_data_breakpoints_response["success"]
        assert_equal true, set_data_breakpoints_response.dig("body", "breakpoints", 0, "verified")

        next_request_seq = client.start_request("next", { "threadId" => thread_id })
        next_response, next_events = client.wait_for_response(next_request_seq, timeout: 30)
        assert_equal true, next_response["success"]

        data_breakpoint_stop = next_events.find { |event| event["event"] == "stopped" }
        data_breakpoint_stop ||= client.wait_for_event("stopped", timeout: 30)
        refute_nil data_breakpoint_stop
        assert_equal "data breakpoint", data_breakpoint_stop.dig("body", "reason")

        disconnect_request_seq = client.start_request("disconnect", {})
        disconnect_response, disconnect_events = client.wait_for_response(disconnect_request_seq, timeout: 30)
        assert_equal true, disconnect_response["success"]
        assert_includes disconnect_events.map { |event| event["event"] }, "terminated"
      end
    end
  end

  def test_real_lldb_dap_smoke_steps_next_step_in_and_step_out
    lldb_dap_path = command_path_for(ENV.fetch("LLDB_DAP", "lldb-dap"))
    skip "lldb-dap not available" unless lldb_dap_path
    skip "C compiler not available: #{ENV.fetch("CC", "cc")}" unless command_available?(ENV.fetch("CC", "cc"))

    Dir.mktmpdir("milk-tea-real-lldb-dap-steps") do |dir|
      source_path = File.join(dir, "steps.mt")
      File.write(source_path, [
        "module demo.steps",
        "",
        "def inner(value: int) -> int:",
        "    let lifted = value + 1",
        "    return lifted",
        "",
        "def outer(value: int) -> int:",
        "    let seed = value",
        "    let inside = inner(seed)",
        "    let marker = inside + 1",
        "    return marker",
        "",
        "def main() -> int:",
        "    return outer(40)",
        "",
      ].join("\n"))

      with_server(preferred_backend_kind: "lldb-dap", adapter_command: [lldb_dap_path]) do |client|
        init_response, _init_events = client.send_request("initialize", { "adapterID" => "milk-tea" })
        assert_equal true, init_response["success"]

        launch_request_seq = client.start_request("launch", {
          "backend" => "lldb-dap",
          "program" => source_path,
          "stopOnEntry" => true,
        })

        breakpoints_request_seq = client.start_request("setBreakpoints", {
          "source" => { "path" => source_path },
          "breakpoints" => [{ "line" => 8 }]
        })
        configuration_done_request_seq = client.start_request("configurationDone", {})

        breakpoints_response, breakpoints_events = client.wait_for_response(breakpoints_request_seq, timeout: 30)
        assert_equal true, breakpoints_response["success"]
        assert_equal true, breakpoints_response.dig("body", "breakpoints", 0, "verified")

        conf_response, conf_events = client.wait_for_response(configuration_done_request_seq, timeout: 30)
        assert_equal true, conf_response["success"]

        launch_response, launch_events = client.wait_for_response(launch_request_seq, timeout: 30)
        assert_equal true, launch_response["success"]

        entry_stop = (breakpoints_events + conf_events + launch_events).find { |event| event["event"] == "stopped" }
        entry_stop ||= client.wait_for_event("stopped", timeout: 30)
        refute_nil entry_stop

        thread_id = entry_stop.dig("body", "threadId")
        refute_nil thread_id

        continue_request_seq = client.start_request("continue", { "threadId" => thread_id })
        continue_response, continue_events = client.wait_for_response(continue_request_seq, timeout: 30)
        assert_equal true, continue_response["success"]

        breakpoint_stop = continue_events.find { |event| event["event"] == "stopped" }
        breakpoint_stop ||= client.wait_for_event("stopped", timeout: 30)
        refute_nil breakpoint_stop
        assert_equal "breakpoint", breakpoint_stop.dig("body", "reason")

        stack_request_seq = client.start_request("stackTrace", { "threadId" => thread_id })
        stack_response, _stack_events = client.wait_for_response(stack_request_seq, timeout: 30)
        assert_equal true, stack_response["success"]
        first_frame = stack_response.dig("body", "stackFrames", 0)
        refute_nil first_frame
        assert_equal "outer", first_frame["name"]
        assert_equal 9, first_frame["line"]

        step_in_request_seq = client.start_request("stepIn", { "threadId" => thread_id })
        step_in_response, step_in_events = client.wait_for_response(step_in_request_seq, timeout: 30)
        assert_equal true, step_in_response["success"]

        step_in_stop = step_in_events.find { |event| event["event"] == "stopped" }
        step_in_stop ||= client.wait_for_event("stopped", timeout: 30)
        refute_nil step_in_stop
        assert_equal "step", step_in_stop.dig("body", "reason")

        stack_request_seq = client.start_request("stackTrace", { "threadId" => thread_id })
        stack_response, _stack_events = client.wait_for_response(stack_request_seq, timeout: 30)
        assert_equal true, stack_response["success"]
        first_frame = stack_response.dig("body", "stackFrames", 0)
        refute_nil first_frame
        assert_equal "inner", first_frame["name"]
        assert_equal 4, first_frame["line"]

        step_out_request_seq = client.start_request("stepOut", { "threadId" => thread_id })
        step_out_response, step_out_events = client.wait_for_response(step_out_request_seq, timeout: 30)
        assert_equal true, step_out_response["success"]

        step_out_stop = step_out_events.find { |event| event["event"] == "stopped" }
        step_out_stop ||= client.wait_for_event("stopped", timeout: 30)
        refute_nil step_out_stop
        assert_equal "step", step_out_stop.dig("body", "reason")

        stack_request_seq = client.start_request("stackTrace", { "threadId" => thread_id })
        stack_response, _stack_events = client.wait_for_response(stack_request_seq, timeout: 30)
        assert_equal true, stack_response["success"]
        first_frame = stack_response.dig("body", "stackFrames", 0)
        refute_nil first_frame
        assert_equal "outer", first_frame["name"]
        assert_equal 9, first_frame["line"]

        next_request_seq = client.start_request("next", { "threadId" => thread_id })
        next_response, next_events = client.wait_for_response(next_request_seq, timeout: 30)
        assert_equal true, next_response["success"]

        next_stop = next_events.find { |event| event["event"] == "stopped" }
        next_stop ||= client.wait_for_event("stopped", timeout: 30)
        refute_nil next_stop
        assert_equal "step", next_stop.dig("body", "reason")

        stack_request_seq = client.start_request("stackTrace", { "threadId" => thread_id })
        stack_response, _stack_events = client.wait_for_response(stack_request_seq, timeout: 30)
        assert_equal true, stack_response["success"]
        first_frame = stack_response.dig("body", "stackFrames", 0)
        refute_nil first_frame
        assert_equal "outer", first_frame["name"]
        assert_equal 10, first_frame["line"]

        disconnect_request_seq = client.start_request("disconnect", {})
        disconnect_response, disconnect_events = client.wait_for_response(disconnect_request_seq, timeout: 30)
        assert_equal true, disconnect_response["success"]
        assert_includes disconnect_events.map { |event| event["event"] }, "terminated"
      end
    end
  end

  def test_real_lldb_dap_smoke_continue_pause_and_terminate
    lldb_dap_path = command_path_for(ENV.fetch("LLDB_DAP", "lldb-dap"))
    skip "lldb-dap not available" unless lldb_dap_path
    skip "C compiler not available: #{ENV.fetch("CC", "cc")}" unless command_available?(ENV.fetch("CC", "cc"))

    Dir.mktmpdir("milk-tea-real-lldb-dap-controls") do |dir|
      source_path = File.join(dir, "controls.mt")
      File.write(source_path, [
        "module demo.controls",
        "",
        "def main() -> int:",
        "    var total = 0",
        "    while total < 2000000000:",
        "        total += 1",
        "    return total",
        "",
      ].join("\n"))

      with_server(preferred_backend_kind: "lldb-dap", adapter_command: [lldb_dap_path]) do |client|
        init_response, _init_events = client.send_request("initialize", { "adapterID" => "milk-tea" })
        assert_equal true, init_response["success"]

        launch_request_seq = client.start_request("launch", {
          "backend" => "lldb-dap",
          "program" => source_path,
          "stopOnEntry" => false,
        })
        breakpoints_request_seq = client.start_request("setBreakpoints", {
          "source" => { "path" => source_path },
          "breakpoints" => [{ "line" => 6 }]
        })
        configuration_done_request_seq = client.start_request("configurationDone", {})

        breakpoints_response, breakpoints_events = client.wait_for_response(breakpoints_request_seq, timeout: 30)
        assert_equal true, breakpoints_response["success"]
        assert_equal true, breakpoints_response.dig("body", "breakpoints", 0, "verified")

        conf_response, conf_events = client.wait_for_response(configuration_done_request_seq, timeout: 30)
        assert_equal true, conf_response["success"]

        launch_response, launch_events = client.wait_for_response(launch_request_seq, timeout: 30)
        assert_equal true, launch_response["success"]

        breakpoint_stop = (breakpoints_events + conf_events + launch_events).find do |event|
          event["event"] == "stopped" && event.dig("body", "reason") == "breakpoint"
        end
        until breakpoint_stop
          stopped_event = client.wait_for_event("stopped", timeout: 30)
          breakpoint_stop = stopped_event if stopped_event.dig("body", "reason") == "breakpoint"
        end
        refute_nil breakpoint_stop
        assert_equal "breakpoint", breakpoint_stop.dig("body", "reason")

        thread_id = breakpoint_stop.dig("body", "threadId")
        refute_nil thread_id

        stack_request_seq = client.start_request("stackTrace", { "threadId" => thread_id })
        stack_response, _stack_events = client.wait_for_response(stack_request_seq, timeout: 30)
        assert_equal true, stack_response["success"]
        first_frame = stack_response.dig("body", "stackFrames", 0)
        refute_nil first_frame
        assert_equal "main", first_frame["name"]
        assert_equal 6, first_frame["line"]

        clear_breakpoints_request_seq = client.start_request("setBreakpoints", {
          "source" => { "path" => source_path },
          "breakpoints" => []
        })
        clear_breakpoints_response, _clear_breakpoints_events = client.wait_for_response(clear_breakpoints_request_seq, timeout: 30)
        assert_equal true, clear_breakpoints_response["success"]

        continue_request_seq = client.start_request("continue", { "threadId" => thread_id })
        continue_response, _continue_events = client.wait_for_response(continue_request_seq, timeout: 30)
        assert_equal true, continue_response["success"]

        pause_request_seq = client.start_request("pause", { "threadId" => thread_id })
        pause_response, pause_events = client.wait_for_response(pause_request_seq, timeout: 30)
        assert_equal true, pause_response["success"]

        pause_stop = pause_events.find { |event| event["event"] == "stopped" }
        pause_stop ||= client.wait_for_event("stopped", timeout: 30)
        refute_nil pause_stop
        assert_equal "pause", pause_stop.dig("body", "reason")

        stack_request_seq = client.start_request("stackTrace", { "threadId" => thread_id })
        stack_response, _stack_events = client.wait_for_response(stack_request_seq, timeout: 30)
        assert_equal true, stack_response["success"]
        first_frame = stack_response.dig("body", "stackFrames", 0)
        refute_nil first_frame
        assert_equal "main", first_frame["name"]

        terminate_request_seq = client.start_request("terminate", {})
        terminate_response, terminate_events = client.wait_for_response(terminate_request_seq, timeout: 30)
        assert_equal true, terminate_response["success"]
        terminate_event_names = terminate_events.map { |event| event["event"] }
        assert_includes terminate_event_names, "terminated"
      end
    end
  end

  private

  def command_available?(command)
    !!command_path_for(command)
  end

  def command_path_for(command)
    if command.include?(File::SEPARATOR)
      expanded = File.expand_path(command)
      return expanded if File.file?(expanded) && File.executable?(expanded)

      return nil
    end

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |entry|
      candidate = File.join(entry, command)
      return candidate if File.file?(candidate) && File.executable?(candidate)
    end

    nil
  end

  def with_server(preferred_backend_kind: "process", adapter_command: nil)
    stdin_read, stdin_write = IO.pipe
    stdout_read, stdout_write = IO.pipe

    server_script = <<~RUBY
      require 'milk_tea'
      MilkTea::DAP::Server.new(
        preferred_backend_kind: #{preferred_backend_kind.inspect},
        adapter_command: #{adapter_command.inspect}
      ).run
    RUBY

    pid = spawn(
      "bundle",
      "exec",
      "ruby",
      "-Ilib",
      "-e",
      server_script,
      in: stdin_read,
      out: stdout_write,
      err: File::NULL,
      chdir: File.expand_path("../../..", __dir__)
    )

    stdin_read.close
    stdout_write.close

    client = DAPClient.new(stdin_write, stdout_read)
    yield client
  ensure
    stdin_write&.close
    stdout_read&.close
    Process.kill("TERM", pid) rescue nil
    Process.wait(pid) rescue nil
  end

  def with_fake_lldb_adapter
    Dir.mktmpdir("fake-lldb-dap") do |dir|
      script_path = File.join(dir, "fake_lldb_dap.rb")
      File.write(script_path, <<~'RUBY')
        # frozen_string_literal: true
        require "json"

        seq = 1

        read_message = lambda do
          headers = {}
          loop do
            line = STDIN.gets
            break nil if line.nil?

            stripped = line.chomp.sub(/\\r\\z/, "")
            break :headers_done if stripped.empty?

            key, value = stripped.split(":", 2)
            headers[key.strip] = value.strip
          end

          next nil if headers.empty?

          length = headers["Content-Length"]&.to_i
          next nil if length.nil? || length <= 0

          JSON.parse(STDIN.read(length))
        end

        write_message = lambda do |message|
          json = JSON.dump(message)
          STDOUT.write("Content-Length: #{json.bytesize}\\r\\n\\r\\n#{json}")
          STDOUT.flush
        end

        write_response = lambda do |request, body = {}, success = true, error_message = nil|
          response = {
            seq: seq,
            type: "response",
            request_seq: request["seq"],
            command: request["command"],
            success: success
          }
          response[:body] = body if success
          response[:message] = error_message if !success && error_message
          write_message.call(response)
          seq += 1
        end

        write_event = lambda do |event, body = nil|
          payload = { seq: seq, type: "event", event: event }
          payload[:body] = body if body
          write_message.call(payload)
          seq += 1
        end

        loop do
          request = read_message.call
          break if request.nil?
          next unless request["type"] == "request"

          args = request["arguments"] || {}

          case request["command"]
          when "initialize"
            write_response.call(request, { supportsConfigurationDoneRequest: true })
          when "launch", "attach"
            write_response.call(request, {})
          when "setBreakpoints"
            requested = args["breakpoints"] || []
            breakpoints = requested.map.with_index do |bp, idx|
              { id: 100 + idx, verified: true, line: bp["line"].to_i }
            end
            write_response.call(request, { breakpoints: breakpoints })
          when "configurationDone"
            write_response.call(request, {})
            write_event.call("stopped", { reason: "entry", threadId: 99, allThreadsStopped: true })
          when "threads"
            write_response.call(request, { threads: [{ id: 99, name: "lldb-main" }] })
          when "stackTrace"
            write_response.call(request, {
              stackFrames: [{ id: 1, name: "lldb_main", line: 1, column: 1, source: { name: "demo", path: "/tmp/demo.mt" } }],
              totalFrames: 1
            })
          when "scopes"
            write_response.call(request, { scopes: [{ name: "Locals", variablesReference: 11, expensive: false }] })
          when "variables"
            write_response.call(request, { variables: [{ name: "a", value: "1", type: "int", variablesReference: 0 }] })
          when "setExceptionBreakpoints"
            write_response.call(request, {})
          when "evaluate"
            write_response.call(request, { result: "not_impl", variablesReference: 0 })
          when "source"
            write_response.call(request, { content: "# not available" })
          when "loadedSources"
            write_response.call(request, { sources: [] })
          when "continue"
            write_response.call(request, { allThreadsContinued: true })
            write_event.call("continued", { threadId: 99, allThreadsContinued: true })
          when "next", "stepIn", "stepOut"
            write_response.call(request, {})
            write_event.call("stopped", { reason: "step", threadId: 99, allThreadsStopped: true })
          when "pause"
            write_response.call(request, {})
            write_event.call("stopped", { reason: "pause", threadId: 99, allThreadsStopped: true })
          when "disconnect"
            write_response.call(request, {})
            write_event.call("terminated")
            write_event.call("exited", { exitCode: 0 })
            break
          else
            write_response.call(request, {}, false, "unsupported command")
          end
        end
      RUBY

      yield script_path
    end
  end

  def find_response(messages, request_seq)
    messages.find do |msg|
      type = msg["type"] || msg[:type]
      seq = msg["request_seq"] || msg[:request_seq]
      type == "response" && seq == request_seq
    end
  end

  def find_events(messages, event_name)
    messages.select do |msg|
      type = msg["type"] || msg[:type]
      event = msg["event"] || msg[:event]
      type == "event" && event == event_name
    end
  end

end

# frozen_string_literal: true

require "json"
require "tmpdir"
require "timeout"
require_relative "../../../test_helper"

module DAPServerTestHelpers
  LIB_DIR = File.expand_path("../../../../lib", __dir__).freeze

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

  class ScriptedDAPProtocol
    attr_reader :written

    def initialize(messages)
      @messages = messages.dup
      @written = []
    end

    def read_message
      @messages.shift
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
              "name" => "debug_map_add",
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
      RbConfig.ruby,
      "-I", LIB_DIR,
      "-e",
      server_script,
      in: stdin_read,
      out: stdout_write,
      err: File::NULL,
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

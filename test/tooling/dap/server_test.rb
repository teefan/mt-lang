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
    end

    def send_request(command, arguments = {})
      request = {
        seq: @next_seq,
        type: "request",
        command: command,
        arguments: arguments
      }
      @next_seq += 1
      write_message(request)
      read_response_and_events(request[:seq])
    end

    private

    def write_message(message)
      json = JSON.dump(message)
      @stdin.write("Content-Length: #{json.bytesize}\r\n\r\n#{json}")
      @stdin.flush
    end

    def read_response_and_events(expected_request_seq)
      events = []
      response = nil

      Timeout.timeout(5) do
        loop do
          message = read_message
          next if message.nil?

          if message["type"] == "event"
            events << message
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

    def initialize(on_event)
      @on_event = on_event
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
        { "success" => true, "body" => { "variables" => [{ "name" => "x", "value" => "42", "type" => "i32", "variablesReference" => 0 }] } }
      when "setExceptionBreakpoints"
        { "success" => true, "body" => {} }
      when "evaluate"
        { "success" => true, "body" => { "result" => "42", "variablesReference" => 0 } }
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
      assert_equal [], launch_events

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
      { "seq" => 11, "type" => "request", "command" => "terminate", "arguments" => {} },
      { "seq" => 12, "type" => "request", "command" => "disconnect", "arguments" => {} }
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
    breakpoints_body = breakpoints_response["body"] || breakpoints_response[:body]
    first_breakpoint = breakpoints_body["breakpoints"]&.first || breakpoints_body[:breakpoints]&.first
    assert_equal 42, first_breakpoint["id"] || first_breakpoint[:id]

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

    terminate_response = find_response(protocol.written, 11)
    assert_equal true, terminate_response["success"] || terminate_response[:success]

    disconnect_response = find_response(protocol.written, 12)
    assert_equal true, disconnect_response["success"] || disconnect_response[:success]

    caps_events = find_events(protocol.written, "capabilities")
    assert_equal true, caps_events.any?, "expected capabilities event after lldb-dap backend init"
    caps_body = caps_events.first[:body] || caps_events.first["body"]
    assert_equal [], caps_body[:exceptionBreakpointFilters] || caps_body["exceptionBreakpointFilters"],
                 "capabilities event body must include exceptionBreakpointFilters"

    backend_commands = backend.requests.map(&:first)
    assert_includes backend_commands, "initialize"
    assert_includes backend_commands, "launch"
    assert_includes backend_commands, "stackTrace"
    assert_includes backend_commands, "scopes"
    assert_includes backend_commands, "variables"
    assert_includes backend_commands, "setExceptionBreakpoints"
    assert_includes backend_commands, "evaluate"
    assert_includes backend_commands, "terminate"
    assert_includes backend_commands, "disconnect"
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

  private

  def with_server
    stdin_read, stdin_write = IO.pipe
    stdout_read, stdout_write = IO.pipe

    pid = spawn(
      'bundle exec ruby -Ilib -e "require \'milk_tea\'; MilkTea::DAP::Server.new.run"',
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
            write_response.call(request, { variables: [{ name: "a", value: "1", type: "i32", variablesReference: 0 }] })
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

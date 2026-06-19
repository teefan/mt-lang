# frozen_string_literal: true

require_relative "helpers"

class LldbBridgeTest < Minitest::Test
  include DAPServerTestHelpers

  def test_reverse_request_timeout_uses_configured_timeout_message
    original_timeout = ENV["MILK_TEA_DAP_REVERSE_REQUEST_TIMEOUT"]
    ENV["MILK_TEA_DAP_REVERSE_REQUEST_TIMEOUT"] = "0.05"

    incoming = [
      { "seq" => 1, "type" => "request", "command" => "initialize", "arguments" => { "adapterID" => "milk-tea" } },
      { "seq" => 2, "type" => "request", "command" => "launch", "arguments" => { "backend" => "lldb-dap", "program" => "/usr/bin/true", "stopOnEntry" => true } },
      { "seq" => 3, "type" => "request", "command" => "configurationDone", "arguments" => {} }
    ]
    protocol = InMemoryProtocol.new(incoming)

    server = MilkTea::DAP::Server.new(
      protocol: protocol,
      backend_factory: lambda do |_adapter_command, on_event, on_request|
        Class.new do
          def initialize(on_event, on_request)
            @on_event = on_event
            @on_request = on_request
          end

          def start! = true
          def stop! = true

          def request(command, arguments, timeout: 5)
            _arguments = arguments
            _timeout = timeout
            case command
            when "initialize"
              { "success" => true, "body" => { "supportsConfigurationDoneRequest" => true } }
            when "launch"
              { "success" => true, "body" => {} }
            when "configurationDone"
              @on_request.call({
                "seq" => 900,
                "type" => "request",
                "command" => "runInTerminal",
                "arguments" => { "kind" => "integrated", "title" => "Timed Out", "cwd" => "/tmp", "args" => ["/usr/bin/true"] }
              })
            else
              { "success" => true, "body" => {} }
            end
          end
        end.new(on_event, on_request)
      end
    )

    server.run

    conf_response = find_response(protocol.written, 3)
    assert_equal false, conf_response["success"] || conf_response[:success]
    message = conf_response["message"] || conf_response[:message]
    assert_match(/timed out after 0\.1s: runInTerminal/, message)
  ensure
    if original_timeout.nil?
      ENV.delete("MILK_TEA_DAP_REVERSE_REQUEST_TIMEOUT")
    else
      ENV["MILK_TEA_DAP_REVERSE_REQUEST_TIMEOUT"] = original_timeout
    end
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
    stop_thread(thread)
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
            linkage_name: "debug_map_add",
            source_path: source_path,
            line: 3,
            params: [MilkTea::DebugMap::Entry.new(name: "left", linkage_name: "left", line: nil)],
            locals: [MilkTea::DebugMap::Entry.new(name: "int", linkage_name: "int_", line: 4)]
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
            linkage_name: "debug_map_add",
            source_path: source_path,
            line: 3,
            params: [MilkTea::DebugMap::Entry.new(name: "left", linkage_name: "left", line: nil)],
            locals: [MilkTea::DebugMap::Entry.new(name: "int", linkage_name: "int_", line: 4)]
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
            linkage_name: "debug_map_add",
            source_path: source_path,
            line: 3,
            params: [MilkTea::DebugMap::Entry.new(name: "left", linkage_name: "left", line: nil)],
            locals: [MilkTea::DebugMap::Entry.new(name: "int", linkage_name: "int_", line: 4)]
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
            linkage_name: "debug_map_add",
            source_path: source_path,
            line: 3,
            params: [MilkTea::DebugMap::Entry.new(name: "left", linkage_name: "left", line: nil)],
            locals: [MilkTea::DebugMap::Entry.new(name: "int", linkage_name: "int_", line: 4)]
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
            linkage_name: "debug_map_add",
            source_path: source_path,
            line: 3,
            params: [MilkTea::DebugMap::Entry.new(name: "left", linkage_name: "left", line: nil)],
            locals: [MilkTea::DebugMap::Entry.new(name: "int", linkage_name: "int_", line: 4)]
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
                      "line" => 75,
                      "column" => 5,
                      "instructionPointerReference" => "0x555555559CED",
                      "source" => {
                        "name" => File.basename(example_path),
                        "path" => example_path
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
    stop_thread(thread)
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

  def test_lldb_backend_emits_pause_diagnostic_on_pause
    incoming = [
      { "seq" => 1, "type" => "request", "command" => "initialize", "arguments" => { "adapterID" => "milk-tea" } },
      { "seq" => 2, "type" => "request", "command" => "launch", "arguments" => { "backend" => "lldb-dap", "program" => "/usr/bin/true", "stopOnEntry" => true } },
      { "seq" => 3, "type" => "request", "command" => "configurationDone", "arguments" => {} },
      { "seq" => 4, "type" => "request", "command" => "pause", "arguments" => { "threadId" => 77 } },
      { "seq" => 5, "type" => "request", "command" => "disconnect", "arguments" => {} }
    ]
    protocol = InMemoryProtocol.new(incoming)

    server = MilkTea::DAP::Server.new(
      protocol: protocol,
      backend_factory: lambda do |_adapter_command, on_event, on_request|
        Class.new do
          def initialize(on_event, on_request)
            @on_event = on_event
            @on_request = on_request
          end

          def start! = true
          def stop! = true

          def request(command, _arguments, timeout: 5)
            case command
            when "initialize"
              { "success" => true, "body" => { "supportsConfigurationDoneRequest" => true } }
            when "launch", "configurationDone"
              { "success" => true, "body" => {} }
            when "pause"
              @on_event.call({
                "type" => "event",
                "event" => "stopped",
                "body" => { "reason" => "pause", "threadId" => 77, "allThreadsStopped" => true }
              })
              { "success" => true, "body" => {} }
            when "stackTrace"
              { "success" => true, "body" => { "stackFrames" => [{ "id" => 1, "name" => "my_function", "line" => 42, "column" => 0, "source" => { "name" => "demo.mt", "path" => "/tmp/demo.mt" } }], "totalFrames" => 1 } }
            when "disconnect"
              @on_event.call({ "type" => "event", "event" => "terminated" })
              @on_event.call({ "type" => "event", "event" => "exited", "body" => { "exitCode" => 0 } })
              { "success" => true, "body" => {} }
            else
              { "success" => true, "body" => {} }
            end
          end
        end.new(on_event, on_request)
      end
    )

    server.run

    output_events = protocol.written.select { |msg| (msg[:type] || msg["type"]) == "event" && (msg[:event] || msg["event"]) == "output" }
    refute_empty output_events, "expected output diagnostic events for pause"

    output_text = output_events.flat_map { |e|
      body = e[:body] || e["body"]
      body.is_a?(Hash) ? [body[:output] || body["output"]].compact : []
    }.join
    assert_match(/my_function/, output_text)
    assert_match(/pause focus/, output_text)
  end

end

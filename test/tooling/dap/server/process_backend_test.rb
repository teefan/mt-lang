# frozen_string_literal: true

require_relative "helpers"

class ProcessBackendTest < Minitest::Test
  include DAPServerTestHelpers

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

  def test_run_skips_invalid_protocol_messages_and_continues_processing
    protocol = ScriptedDAPProtocol.new([
      MilkTea::DAP::Protocol::INVALID_MESSAGE,
      { "seq" => 1, "type" => "request", "command" => "initialize", "arguments" => { "adapterID" => "milk-tea" } },
      nil,
    ])

    server = MilkTea::DAP::Server.new(protocol: protocol)
    server.run

    init_response = find_response(protocol.written, 1)
    assert_equal true, init_response["success"] || init_response[:success]
    initialized_events = find_events(protocol.written, "initialized")
    assert_equal 1, initialized_events.length
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

  def test_step_in_and_step_out_return_error_in_process_backend
    with_server do |client|
      _init_response, _init_events = client.send_request("initialize", { "adapterID" => "milk-tea" })
      _launch_response, _launch_events = client.send_request("launch", { "program" => "/usr/bin/true", "stopOnEntry" => true })
      _conf_response, _conf_events = client.send_request("configurationDone", {})

      step_in_response, _step_in_events = client.send_request("stepIn", { "threadId" => 1 })
      assert_equal false, step_in_response["success"]
      assert_match(/not supported/, step_in_response["message"])

      step_out_response, _step_out_events = client.send_request("stepOut", { "threadId" => 1 })
      assert_equal false, step_out_response["success"]
      assert_match(/not supported/, step_out_response["message"])
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
      assert_equal [false, false], breakpoints.map { |bp| bp["verified"] }
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

  def test_restart_returns_error_in_process_backend
    with_server do |client|
      _init, _init_events = client.send_request("initialize", { "adapterID" => "milk-tea" })
      _launch, _launch_events = client.send_request("launch", { "program" => "/usr/bin/true" })
      response, _events = client.send_request("restart", {})
      assert_equal false, response["success"]
      assert_match(/not supported/, response["message"])
    end
  end

end

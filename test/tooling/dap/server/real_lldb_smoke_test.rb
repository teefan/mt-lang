# frozen_string_literal: true

require_relative "helpers"

class RealLldbSmokeTest < Minitest::Test
  include DAPServerTestHelpers

  def test_real_lldb_dap_smoke_rewrites_frames_and_locals
    lldb_dap_path = command_path_for(ENV.fetch("LLDB_DAP", "lldb-dap"))
    skip "lldb-dap not available" unless lldb_dap_path
    skip "C compiler not available: #{ENV.fetch("CC", "cc")}" unless command_available?(ENV.fetch("CC", "cc"))

    Dir.mktmpdir("milk-tea-real-lldb-dap") do |dir|
      source_path = File.join(dir, "real_debug.mt")
      File.write(source_path, <<~MT

function add(left: int) -> int:
    let next_value = left + 1
    return next_value

function main() -> int:
    return add(41)

      MT

      )
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
          "breakpoints" => [{ "line" => 3 }]
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
      File.write(source_path, <<~MT

function add(left: int) -> int:
    var watched = left
    watched += 1
    watched += 1
    return watched

function main() -> int:
    return add(40)

      MT

      )
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
          "breakpoints" => [{ "line" => 3 }]
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
      File.write(source_path, <<~MT
function inner(value: int) -> int:
    let lifted = value + 1
    return lifted

function outer(value: int) -> int:
    let seed = value
    let inside = inner(seed)
    let marker = inside + 1
    return marker

function main() -> int:
    return outer(40)

      MT

      )
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
          "breakpoints" => [{ "line" => 7 }]
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
        assert_equal 7, first_frame["line"]

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
        assert_equal 2, first_frame["line"]

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
        assert_equal 7, first_frame["line"]

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
        assert_equal 8, first_frame["line"]

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
      File.write(source_path, <<~MT

function main() -> int:
    var total = 0
    while total < 2000000000:
        total += 1
    return total

      MT

      )
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
          "breakpoints" => [{ "line" => 4 }]
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
        assert_equal 4, first_frame["line"]

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

end

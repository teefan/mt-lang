# frozen_string_literal: true

module MilkTea
  module DAP
    class Server
      module ServerHandlers
        private

        def handle_initialize(message)
          if @session.initialized?
            write_error_response(message, "initialize can only be called once")
            return
          end

          @session.initialize!

          if default_backend_kind == "lldb-dap"
            start_lldb_backend({})
            backend_response = ensure_backend_initialized(message["arguments"] || {})
            return write_backend_response(message, backend_response) unless backend_response["success"]
          end

          write_response(message, effective_adapter_capabilities)

          write_event("initialized")
        end

        def handle_set_breakpoints(message)
          args = message["arguments"] || {}
          source = args["source"] || {}
          source_path = source["path"].to_s
          requested = args["breakpoints"] || Array(args["lines"]).map { |line| { "line" => line } }
          breakpoints = @session.set_breakpoints(source_path, requested)

          if using_lldb_backend?
            if backend_configuration_pending?
              @breakpoints_synced_to_backend = false
              write_response(message, { breakpoints: breakpoints })
              return
            end

            backend_response = backend_request("setBreakpoints", {
              "source" => source,
              "breakpoints" => requested
            })
            @breakpoints_synced_to_backend = false if backend_response["success"]
            return write_backend_response(message, backend_response)
          end

          # Process backend: mark breakpoints unverified
          if default_backend_kind == "process"
            breakpoints.each do |bp|
              bp["verified"] = false
              bp["message"] = "Process backend runs without a debugger; set breakpoints via lldb-dap backend instead."
            end
          end

          write_response(message, { breakpoints: breakpoints })
        end

        def handle_set_function_breakpoints(message)
          args = message["arguments"] || {}
          requested = args["breakpoints"] || []
          breakpoints = @session.set_function_breakpoints(requested)

          if using_lldb_backend?
            if backend_configuration_pending?
              @function_breakpoints_synced_to_backend = false
              write_response(message, { breakpoints: breakpoints })
              return
            end

            backend_response = backend_request("setFunctionBreakpoints", {
              "breakpoints" => requested
            })
            @function_breakpoints_synced_to_backend = false if backend_response["success"]
            return write_backend_response(message, backend_response)
          end

          write_response(message, { breakpoints: breakpoints })
        end

        def handle_configuration_done(message)
          @session.configuration_done!

          if using_lldb_backend?
            backend_response = ensure_backend_initialized({})
            return write_backend_response(message, backend_response) unless backend_response["success"]

            unless wait_for_backend_configuration_ready
              write_error_response(message, "lldb-dap did not become ready for configuration")
              return
            end

            sync_breakpoints_to_backend
            sync_function_breakpoints_to_backend
            sync_exception_breakpoints_to_backend
            backend_response = backend_request("configurationDone", {})
            return write_backend_response(message, backend_response) unless backend_response["success"]

            if @backend_auto_continue_after_configuration
              continue_response = backend_request("continue", backend_continue_arguments)
              @backend_auto_continue_after_configuration = false
              return write_error_response(message, backend_error_message(continue_response)) unless continue_response["success"]
            end

            write_response(message, backend_response["body"] || {})
            return
          end

          write_response(message, {})
          maybe_start_or_stop_on_entry
        end

        def handle_launch(message)
          request_start(message)
        end

        def handle_attach(message)
          args = message["arguments"] || {}
          unless args["backend"].to_s == "lldb-dap"
            write_error_response(message, "attach requires the lldb-dap backend")
            return
          end

          request_start(message)
        end

        def handle_threads(message)
          return write_backend_response(message, backend_request("threads", {})) if using_lldb_backend?

          write_response(message, {
            threads: [
              { id: @session.thread_id, name: "main" }
            ]
          })
        end

        def handle_stack_trace(message)
          if using_lldb_backend?
            maybe_load_debug_map_from_backend_modules
            backend_response = backend_request("stackTrace", message["arguments"] || {})
            rewrite_stack_trace_response(backend_response)
            return write_backend_response(message, backend_response)
          end

          source_path = @session.program_path || "(unknown)"
          write_response(message, {
            stackFrames: [
              {
                id: 1,
                name: "main",
                line: 1,
                column: 1,
                source: {
                  name: File.basename(source_path),
                  path: source_path
                }
              }
            ],
            totalFrames: 1
          })
        end

        def handle_scopes(message)
          if using_lldb_backend?
            arguments = message["arguments"] || {}
            backend_response = backend_request("scopes", arguments)
            rewrite_scopes_response(backend_response, arguments["frameId"])
            return write_backend_response(message, backend_response)
          end

          write_response(message, {
            scopes: [
              {
                name: "Locals",
                variablesReference: 1,
                expensive: false
              }
            ]
          })
        end

        def handle_variables(message)
          if using_lldb_backend?
            arguments = message["arguments"] || {}
            backend_response = backend_request("variables", arguments)
            rewrite_variables_response(backend_response, arguments["variablesReference"])
            return write_backend_response(message, backend_response)
          end

          _args = message["arguments"] || {}
          write_response(message, { variables: [] })
        end

        def handle_continue(message)
          return write_backend_response(message, backend_request("continue", message["arguments"] || {})) if using_lldb_backend?

          start_runtime_if_needed
          continue_runtime_if_paused
          write_response(message, { allThreadsContinued: true })
          write_event("continued", {
            threadId: @session.thread_id,
            allThreadsContinued: true
          })
        end

        def handle_next(message)
          return write_backend_response(message, backend_request("next", message["arguments"] || {})) if using_lldb_backend?

          write_error_response(message, "next is not supported by the process backend")
        end

        def handle_step_in(message)
          return write_backend_response(message, backend_request("stepIn", message["arguments"] || {})) if using_lldb_backend?

          write_error_response(message, "stepIn is not supported by the process backend")
        end

        def handle_step_out(message)
          return write_backend_response(message, backend_request("stepOut", message["arguments"] || {})) if using_lldb_backend?

          write_error_response(message, "stepOut is not supported by the process backend")
        end

        def handle_pause(message)
          if using_lldb_backend?
            @backend_pause_requested = true
            backend_response = backend_request("pause", message["arguments"] || {})
            @backend_pause_requested = false unless backend_response["success"]
            return write_backend_response(message, backend_response)
          end

          unless pause_runtime_if_running
            return write_error_response(message, "pause failed: process is not running")
          end

          write_response(message, {})
          write_event("stopped", {
            reason: "pause",
            threadId: @session.thread_id,
            allThreadsStopped: true
          })
        end

        def handle_terminate(message)
          if using_lldb_backend?
            backend_response = request_backend_terminate(message["arguments"] || {})
            write_backend_response(message, backend_response)
            return
          end

          terminate_runtime_if_running
          write_response(message, {})
          return if @session.runtime_started?

          @session.terminate!
          write_event("terminated")
          write_event("exited", { exitCode: 0 })
          cleanup_tmp_dirs
          @session.request_exit!
        end

        def handle_disconnect(message)
          if using_lldb_backend?
            join_background_threads
            backend_response = backend_request("disconnect", message["arguments"] || {})
            write_backend_response(message, backend_response)
            stop_lldb_backend
            cleanup_tmp_dirs
            @session.request_exit!
            return
          end

          write_response(message, {})
          terminate_runtime_if_running
          unless @session.runtime_started?
            @session.terminate!
            write_event("terminated")
            write_event("exited", { exitCode: 0 })
          end
          cleanup_tmp_dirs
          @session.request_exit!
        end

        def handle_set_exception_breakpoints(message)
          arguments = message["arguments"] || {}
          @session.set_exception_breakpoints(arguments)

          if using_lldb_backend?
            if backend_configuration_pending?
              @exception_breakpoints_synced_to_backend = false
              write_response(message, {})
              return
            end

            backend_response = backend_request("setExceptionBreakpoints", arguments)
            @exception_breakpoints_synced_to_backend = false if backend_response["success"]
            return write_backend_response(message, backend_response)
          end

          write_response(message, {})
        end

        def handle_evaluate(message)
          if using_lldb_backend?
            arguments = rewrite_evaluate_arguments(message["arguments"] || {})
            return write_backend_response(message, backend_request("evaluate", arguments))
          end

          write_error_response(message, "evaluate is not supported by the process backend")
        end

        def handle_set_expression(message)
          if using_lldb_backend?
            arguments = rewrite_set_expression_arguments(message["arguments"] || {})
            return write_backend_response(message, backend_request("setExpression", arguments))
          end

          write_error_response(message, "setExpression is not supported by the process backend")
        end

        def handle_set_variable(message)
          if using_lldb_backend?
            arguments = rewrite_set_variable_arguments(message["arguments"] || {})
            return write_backend_response(message, request_set_variable(arguments))
          end

          write_error_response(message, "setVariable is not supported by the process backend")
        end

        def handle_data_breakpoint_info(message)
          if using_lldb_backend?
            arguments = rewrite_data_breakpoint_info_arguments(message["arguments"] || {})
            return write_backend_response(message, backend_request("dataBreakpointInfo", arguments))
          end

          write_error_response(message, "dataBreakpointInfo is not supported by the process backend")
        end

        def handle_source(message)
          return write_backend_response(message, backend_request("source", message["arguments"] || {})) if using_lldb_backend?

          write_error_response(message, "source retrieval is not supported")
        end

        def handle_loaded_sources(message)
          return write_backend_response(message, backend_request("loadedSources", message["arguments"] || {})) if using_lldb_backend?

          write_response(message, { sources: [] })
        end

        def handle_restart(message)
          return write_backend_response(message, backend_request("restart", message["arguments"] || {})) if using_lldb_backend?

          write_error_response(message, "restart is not supported by the process backend")
        end

        def handle_cancel(message)
          args = message["arguments"] || {}
          request_id = args["requestId"] || args["progressId"]

          if using_lldb_backend?
            backend_response = backend_request("cancel", { "requestId" => request_id }.compact)
            write_backend_response(message, backend_response)
          else
            join_background_threads(timeout: 0.1)
            write_response(message, {})
          end
        end
      end
    end
  end
end

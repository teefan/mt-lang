# frozen_string_literal: true

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

require_relative "../tooling/debug_map"

module MilkTea
  module DAP
    # Minimal DAP server with strict request/response/event envelopes.
    class Server
      def initialize(protocol: Protocol.new, session: Session.new, backend_factory: nil, preferred_backend_kind: "process", adapter_command: nil)
        @protocol = protocol
        @session = session
        @backend_factory = backend_factory
        @preferred_backend_kind = preferred_backend_kind.to_s.empty? ? "process" : preferred_backend_kind.to_s
        @default_adapter_command = adapter_command&.dup
        @handlers = {}
        @write_mutex = Mutex.new
        @client_request_mutex = Mutex.new
        @pending_client_responses = {}
        @incoming_messages = Queue.new
        @reader_thread = nil
        @background_threads = []
        @background_threads_mutex = Mutex.new
        @runtime_mutex = Mutex.new
        @runtime_pid = nil
        @runtime_paused = false
        @tmp_dirs = []
        @lldb_backend = nil
        @backend_initialized = false
        @backend_capabilities = {}
        @breakpoints_synced_to_backend = false
        @function_breakpoints_synced_to_backend = false
        @exception_breakpoints_synced_to_backend = false
        @backend_start_thread = nil
        @backend_auto_continue_after_configuration = false
        @backend_stopped_thread_id = nil
        @backend_pause_requested = false
        @last_forwarded_continued_signature = nil
        @backend_configuration_mutex = Mutex.new
        @backend_configuration_condition = ConditionVariable.new
        @backend_configuration_ready = false
        @debug_map = nil
        @frame_debug_functions = {}
        @variables_reference_debug_functions = {}
        register_handlers
      end

      def run
        start_client_reader

        loop do
          message = @incoming_messages.pop
          break if message.nil?

          process_message(message)
          break if @session.should_exit?
        end
      ensure
        @backend_start_thread&.join(0.2)
        join_background_threads
        @reader_thread&.join(0.2)
      end

      private

      def start_client_reader
        return if @reader_thread&.alive?

        @reader_thread = Thread.new do
          loop do
            message = @protocol.read_message
            break if message.nil?

            if message["type"] == "response"
              queue = @client_request_mutex.synchronize do
                @pending_client_responses[message["request_seq"]]
              end
              if queue
                queue.push(message)
                next
              end
            end

            @incoming_messages.push(message)
          end
        ensure
          @incoming_messages.push(nil)
        end
      end

      def register_handlers
        @handlers["initialize"] = method(:handle_initialize)
        @handlers["setBreakpoints"] = method(:handle_set_breakpoints)
        @handlers["setFunctionBreakpoints"] = method(:handle_set_function_breakpoints)
        @handlers["configurationDone"] = method(:handle_configuration_done)
        @handlers["launch"] = method(:handle_launch)
        @handlers["attach"] = method(:handle_attach)
        @handlers["threads"] = method(:handle_threads)
        @handlers["stackTrace"] = method(:handle_stack_trace)
        @handlers["scopes"] = method(:handle_scopes)
        @handlers["variables"] = method(:handle_variables)
        @handlers["continue"] = method(:handle_continue)
        @handlers["next"] = method(:handle_next)
        @handlers["stepIn"] = method(:handle_step_in)
        @handlers["stepOut"] = method(:handle_step_out)
        @handlers["pause"] = method(:handle_pause)
        @handlers["terminate"] = method(:handle_terminate)
        @handlers["disconnect"] = method(:handle_disconnect)
        @handlers["setExceptionBreakpoints"] = method(:handle_set_exception_breakpoints)
        @handlers["evaluate"] = method(:handle_evaluate)
        @handlers["setExpression"] = method(:handle_set_expression)
        @handlers["setVariable"] = method(:handle_set_variable)
        @handlers["dataBreakpointInfo"] = method(:handle_data_breakpoint_info)
        @handlers["source"] = method(:handle_source)
        @handlers["loadedSources"] = method(:handle_loaded_sources)
        @handlers["restart"] = method(:handle_restart)
      end

      # Log threshold for --perf mode (milliseconds)
      PERF_LOG_THRESHOLD_MS = 20

      def process_message(message)
        if message["type"] == "response"
          handle_client_response(message)
          return
        end

        return unless message["type"] == "request"

        command = message["command"]
        handler = @handlers[command]

        unless command == "initialize" || @session.initialized?
          write_error_response(message, "initialize request must be sent first")
          return
        end

        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        if handler
          handler.call(message)
        elsif using_lldb_backend?
          backend_response = backend_request(command, message["arguments"] || {})
          write_backend_response(message, backend_response)
        else
          write_error_response(message, "Unsupported command: #{command}")
        end

        elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(1)
        if dap_perf_logging? && (dap_perf_verbose? || elapsed_ms > PERF_LOG_THRESHOLD_MS)
          detail = dap_perf_verbose? ? " #{summarize_dap_arguments(message['arguments'])}" : ""
          warn "[DAP perf] #{command} #{elapsed_ms}ms#{detail}"
        end
      rescue StandardError => e
        write_error_response(message, "Internal error: #{e.message}")
      end

      def dap_perf_logging?
        @dap_perf_logging ||= !ENV.fetch('MILK_TEA_DAP_PERF', nil).to_s.empty?
      end

      def dap_perf_verbose?
        @dap_perf_verbose ||= ENV.fetch('MILK_TEA_DAP_PERF', nil).to_s == 'verbose'
      end

      def summarize_dap_arguments(arguments)
        return "" unless arguments.is_a?(Hash)

        keys = arguments.keys.map(&:to_s).sort
        source_path = arguments.dig('source', 'path')
        frame_id = arguments['frameId']
        expression = arguments['expression']

        bits = []
        bits << "keys=#{keys.join(',')}" unless keys.empty?
        bits << "source=#{source_path}" if source_path
        bits << "frameId=#{frame_id}" if frame_id
        bits << "expr=#{expression.inspect}" if expression
        bits.join(' ')
      rescue StandardError
        ""
      end

      ADAPTER_CAPABILITIES = {
        supportsConfigurationDoneRequest: true,
        supportsFunctionBreakpoints: false,
        supportsConditionalBreakpoints: false,
        supportsPauseRequest: true,
        supportsEvaluateForHovers: false,
        supportsSetVariable: false,
        supportsTerminateRequest: true,
        supportsLoadedSourcesRequest: true,
        exceptionBreakpointFilters: []
      }.freeze

      def handle_initialize(message)
        if @session.initialized?
          write_error_response(message, "initialize can only be called once")
          return
        end

        @session.initialize!

        capabilities = ADAPTER_CAPABILITIES
        if default_backend_kind == "lldb-dap"
          start_lldb_backend({})
          backend_response = ensure_backend_initialized(message["arguments"] || {})
          return write_backend_response(message, backend_response) unless backend_response["success"]

          capabilities = effective_adapter_capabilities
        end

        write_response(message, capabilities)

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

      def request_start(message)
        if @session.launched?
          write_error_response(message, "Program already launched")
          return
        end

        args = message["arguments"] || {}
        if message["command"] == "launch" && args["program"].to_s.empty?
          write_error_response(message, "launch requires a non-empty 'program' argument")
          return
        end

        resolved = resolve_debug_program(message["command"], args["program"])
        unless resolved[:ok]
          write_error_response(message, resolved[:error])
          return
        end

        program_args = args["args"] || []
        unless program_args.is_a?(Array)
          write_error_response(message, "launch 'args' must be an array when provided")
          return
        end

        no_debug = message["command"] == "launch" && args["noDebug"] == true
        stop_on_entry = no_debug ? false : (args.key?("stopOnEntry") ? !!args["stopOnEntry"] : true)
        backend_kind = if no_debug
                         "process"
                       else
                         resolved_backend_kind(args["backend"])
                       end
        unless backend_kind
          write_error_response(message, "unsupported backend: #{args['backend']}")
          return
        end

        @session.request_start!(
          program_path: args["program"].to_s.empty? ? nil : args["program"],
          runnable_path: resolved[:runnable_path],
          program_args:,
          stop_on_entry:,
          backend_kind:
        )
        @session.launch!
        @backend_auto_continue_after_configuration = using_lldb_backend? && message["command"] == "launch" && !stop_on_entry
        @backend_stopped_thread_id = nil if using_lldb_backend?
        @last_forwarded_continued_signature = nil
        load_debug_map(resolved[:runnable_path])

        if using_lldb_backend?
          start_lldb_backend(args)
          reset_backend_configuration_ready
          init_response = ensure_backend_initialized({})
          return write_backend_response(message, init_response) unless init_response["success"]

          # Merge backend capabilities with adapter capabilities and notify the client.
          merged_caps = effective_adapter_capabilities
          write_event("capabilities", merged_caps)

          launch_arguments = backend_start_arguments(message["command"], args, resolved)
          @breakpoints_synced_to_backend = false
          @function_breakpoints_synced_to_backend = false
          @exception_breakpoints_synced_to_backend = false
          start_backend_start_request(message, launch_arguments)
          return
        end

        write_response(message, {})
        write_event("process", {
          name: File.basename(@session.program_path.to_s),
          startMethod: "launch",
          isLocalProcess: true
        })
        maybe_start_or_stop_on_entry
      end

      def maybe_start_or_stop_on_entry
        return if using_lldb_backend?

        return unless @session.launched?
        return unless @session.configuration_done?
        return if @session.runtime_started?

        if @session.stop_on_entry?
          return if @session.entry_stop_emitted?

          write_stopped("entry")
          @session.mark_entry_stop_emitted!
        else
          start_runtime_if_needed
        end
      end

      def write_stopped(reason)
        write_event("stopped", {
          reason: reason,
          threadId: @session.thread_id,
          allThreadsStopped: true
        })
      end

      def using_lldb_backend?
        @session.backend_kind == "lldb-dap"
      end

      def start_lldb_backend(args)
        return if @lldb_backend

        adapter_path = args["adapterPath"].to_s
        adapter_command = if adapter_path.empty?
                             @default_adapter_command || ["lldb-dap"]
                          else
                            expanded = File.expand_path(adapter_path)
                            expanded.end_with?(".rb") ? [RbConfig.ruby, expanded] : [expanded]
                          end

        @lldb_backend = if @backend_factory
                          build_backend_via_factory(adapter_command)
                        else
                          Backends::LLDBDAP.new(
                            adapter_command: adapter_command,
                            on_event: method(:handle_backend_event),
                            on_request: method(:handle_backend_request)
                          )
                        end
        @lldb_backend.start!
      end

      def stop_lldb_backend
        @backend_start_thread&.join(0.2)
        @backend_start_thread = nil
        @backend_auto_continue_after_configuration = false
        @backend_stopped_thread_id = nil
        @backend_pause_requested = false
        @lldb_backend&.stop!
      ensure
        @lldb_backend = nil
        @backend_initialized = false
        @backend_capabilities = {}
        reset_backend_configuration_ready
        clear_debug_context
      end

      def ensure_backend_initialized(client_arguments)
        return { "success" => true, "body" => @backend_capabilities } if @backend_initialized

        response = backend_request("initialize", backend_initialize_arguments(client_arguments))
        if response["success"]
          @backend_initialized = true
          @backend_capabilities = response["body"] || {}
        end
        response
      end

      def backend_request(command, arguments)
        unless @lldb_backend
          return {
            "success" => false,
            "message" => "lldb-dap backend is not running"
          }
        end

        @lldb_backend.request(command, arguments)
      end

      def request_backend_terminate(arguments)
        join_background_threads
        terminate_response = backend_request("terminate", arguments)
        return terminate_response if terminate_response["success"]
        return terminate_response unless backend_terminate_unsupported?(terminate_response)

        disconnect_response = backend_request("disconnect", arguments)
        return disconnect_response unless disconnect_response["success"]

        stop_lldb_backend
        cleanup_tmp_dirs
        unless @session.terminated?
          @session.terminate!
          write_event("terminated")
        end
        @session.request_exit!
        disconnect_response
      end

      def start_backend_start_request(request, arguments)
        @backend_start_thread = Thread.new do
          Thread.current.report_on_exception = false if Thread.current.respond_to?(:report_on_exception=)

          backend_response = backend_request(request["command"], arguments)
          write_backend_response(request, backend_response)
        rescue StandardError => e
          write_error_response(request, "Internal error: #{e.message}")
        ensure
          @backend_start_thread = nil
          @backend_configuration_mutex.synchronize do
            @backend_configuration_condition.broadcast
          end
        end
      end

      def write_backend_response(request, backend_response)
        if backend_response["success"]
          write_response(request, backend_response["body"] || {})
        else
          write_error_response(request, backend_error_message(backend_response))
        end
      end

      def backend_error_message(backend_response)
        message = backend_response["message"].to_s
        return message unless message.empty?

        error_body = backend_response.dig("body", "error")
        if error_body.is_a?(Hash)
          format = error_body["format"].to_s
          return format unless format.empty?

          error_message = error_body["message"].to_s
          return error_message unless error_message.empty?
        end

        "backend request failed"
      end

      def backend_terminate_unsupported?(backend_response)
        message = backend_error_message(backend_response).downcase
        message.include?("unknown request") || message.include?("unsupported command")
      end

      def build_backend_via_factory(adapter_command)
        arity = @backend_factory.arity
        if arity < 0 || arity >= 3
          @backend_factory.call(adapter_command, method(:handle_backend_event), method(:handle_backend_request))
        else
          @backend_factory.call(adapter_command, method(:handle_backend_event))
        end
      end

      def handle_backend_event(message)
        event = message["event"].to_s
        body = message["body"]

        # The outer Milk Tea adapter owns the initialize/initialized handshake.
        # Forwarding lldb-dap's own initialized event causes VS Code to repeat
        # the configuration phase and emit a second configurationDone.
        if event == "initialized"
          mark_backend_configuration_ready
          return
        end

        if event == "stopped"
          pause_requested = @backend_pause_requested
          body = rewrite_backend_stopped_event_body(body)
          emit_pause_diagnostic_async(body) if pause_requested
          @backend_stopped_thread_id = body && body["threadId"]
          @backend_pause_requested = false
          @last_forwarded_continued_signature = nil
        elsif event == "continued"
          signature = continued_event_signature(body)
          return if signature && signature == @last_forwarded_continued_signature

          @backend_stopped_thread_id = nil
          @backend_pause_requested = false
          @last_forwarded_continued_signature = signature
        elsif event == "terminated" || event == "exited"
          @backend_stopped_thread_id = nil
          @backend_pause_requested = false
          @last_forwarded_continued_signature = nil
        end

        write_event(event, body)

        return unless event == "terminated" || event == "exited"

        @session.terminate!
      end

      def handle_backend_request(message)
        client_seq = @session.next_seq
        queue = Queue.new
        @client_request_mutex.synchronize do
          @pending_client_responses[client_seq] = queue
        end

        write_message({
          seq: client_seq,
          type: "request",
          command: message["command"],
          arguments: message["arguments"] || {}
        })

        client_response = Timeout.timeout(5) { queue.pop }
        build_backend_request_response(message, client_response)
      rescue Timeout::Error
        {
          "seq" => @session.next_seq,
          "type" => "response",
          "request_seq" => message["seq"],
          "success" => false,
          "command" => message["command"],
          "message" => "client request timed out: #{message['command']}"
        }
      ensure
        @client_request_mutex.synchronize do
          @pending_client_responses.delete(client_seq) if defined?(client_seq)
        end
      end

      def handle_client_response(message)
        queue = @client_request_mutex.synchronize do
          @pending_client_responses[message["request_seq"]]
        end
        queue&.push(message)
      end

      def build_backend_request_response(request, client_response)
        response = {
          "seq" => @session.next_seq,
          "type" => "response",
          "request_seq" => request["seq"],
          "success" => !!client_response["success"],
          "command" => request["command"]
        }
        response["body"] = client_response["body"] if client_response.key?("body")
        response["message"] = client_response["message"] if client_response["message"]
        response
      end

      def emit_pause_diagnostic_async(body)
        return unless body.is_a?(Hash)

        thread_id = normalize_reference_key(dap_value(body, "threadId"))
        return if thread_id.nil?

        track_background_thread(Thread.new(thread_id) do |diagnostic_thread_id|
          stack_response = backend_request("stackTrace", {
            "threadId" => diagnostic_thread_id,
            "startFrame" => 0,
            "levels" => 8
          })

          write_event("output", {
            category: "console",
            output: "#{pause_diagnostic_output(diagnostic_thread_id, stack_response)}\n"
          })
        rescue StandardError => e
          write_event("output", {
            category: "console",
            output: "[milk-tea dap] pause top frame unavailable thread=#{diagnostic_thread_id}: #{e.message}\n"
          })
        end)
      end

      def pause_diagnostic_output(thread_id, stack_response)
        unless stack_response["success"]
          return "[milk-tea dap] pause focus unavailable thread=#{thread_id}: #{backend_error_message(stack_response)}"
        end

        frames = stack_response.dig("body", "stackFrames")
        frames = frames.select { |candidate| candidate.is_a?(Hash) } if frames.is_a?(Array)
        return "[milk-tea dap] pause focus unavailable thread=#{thread_id}: no stack frames" if !frames.is_a?(Array) || frames.empty?

        raw_frame = frames.first
        informative_index = frames.index { |frame| informative_pause_frame?(frame) }

        unless informative_index
          return "[milk-tea dap] pause top frame thread=#{thread_id}: #{pause_frame_summary(raw_frame, include_ip: true)}"
        end

        focus_frames = frames.drop(informative_index).first(3)
        focus = focus_frames.map { |frame| pause_frame_summary(frame) }.join(" <- ")
        raw_suffix = informative_index.zero? ? "" : " raw=#{pause_frame_summary(raw_frame, include_ip: true)}"

        "[milk-tea dap] pause focus thread=#{thread_id}: #{focus}#{raw_suffix}"
      end

      def informative_pause_frame?(frame)
        name = dap_value(frame, "name").to_s
        return false if name.empty?
        return false if name.match?(/\A___lldb_unnamed_symbol_/)
        return false if %w[clock_nanosleep __nanosleep nanosleep].include?(name)

        source = dap_value(frame, "source")
        source_path = source.is_a?(Hash) ? dap_value(source, "path").to_s : ""

        return true if source_path.start_with?("/usr/src/debug/")
        return true if !source_path.empty? && !source_path.start_with?("/usr/lib/") && !source_path.start_with?("/lib/")

        true
      end

      def pause_frame_summary(frame, include_ip: false)
        frame_name = dap_value(frame, "name").to_s
        frame_name = "(anonymous)" if frame_name.empty?

        instruction_pointer = dap_value(frame, "instructionPointerReference").to_s
        source = dap_value(frame, "source")
        source_path = source.is_a?(Hash) ? dap_value(source, "path").to_s : ""
        source_name = source.is_a?(Hash) ? dap_value(source, "name").to_s : ""
        line = dap_value(frame, "line")

        location_source = if !source_path.empty? && !source_path.include?("`")
                            source_path
                          elsif !source_name.empty?
                            source_name
                          elsif !source_path.empty?
                            source_path
                          else
                            instruction_pointer
                          end

        location = if location_source.to_s.empty?
                     "(unknown)"
                   elsif line.to_i.positive? && !location_source.include?(":#{line}")
                     "#{location_source}:#{line}"
                   else
                     location_source
                   end

        if include_ip && !instruction_pointer.empty? && location != instruction_pointer
          "#{frame_name} @ #{location} ip=#{instruction_pointer}"
        else
          "#{frame_name} @ #{location}"
        end
      end

      def track_background_thread(thread)
        @background_threads_mutex.synchronize do
          @background_threads << thread
        end
        thread
      end

      def join_background_threads(timeout: 0.5)
        threads = @background_threads_mutex.synchronize do
          threads = @background_threads
          @background_threads = []
          threads
        end

        threads.each do |thread|
          thread.join(timeout)
        rescue StandardError
          nil
        end
      end

      def sync_breakpoints_to_backend
        return if @breakpoints_synced_to_backend

        @session.each_breakpoint_source do |source_path, breakpoints|
          response = backend_request("setBreakpoints", {
            "source" => { "path" => source_path },
            "breakpoints" => breakpoints.map { |bp| filter_breakpoint_for_backend(bp) }
          })
          next unless response["success"]

          backend_bps = response.dig("body", "breakpoints") || []
          breakpoints.each_with_index do |local_bp, i|
            backend_bp = backend_bps[i]
            next unless backend_bp

            local_line = local_bp[:line] || local_bp["line"]
            local_verified = local_bp[:verified]
            backend_line = backend_bp["line"] || backend_bp[:line]
            backend_verified = backend_bp["verified"] || backend_bp[:verified]
            next if local_line == backend_line && local_verified == backend_verified

            write_event("breakpoint", {
              reason: "changed",
              breakpoint: {
                id: local_bp[:id] || local_bp["id"],
                verified: backend_verified,
                line: backend_line,
                source: { path: source_path }
              }
            })
          end
        end
        @breakpoints_synced_to_backend = true
      end

      def sync_function_breakpoints_to_backend
        return if @function_breakpoints_synced_to_backend
        return if @session.function_breakpoints.empty?

        backend_request("setFunctionBreakpoints", {
          "breakpoints" => @session.function_breakpoints.map { |bp| filter_breakpoint_for_backend(bp) }
        })
        @function_breakpoints_synced_to_backend = true
      end

      def sync_exception_breakpoints_to_backend
        return if @exception_breakpoints_synced_to_backend

        exception_breakpoints = @session.exception_breakpoints
        return if exception_breakpoints.nil?

        backend_request("setExceptionBreakpoints", exception_breakpoints)
        @exception_breakpoints_synced_to_backend = true
      end

      def write_response(request, body)
        write_message({
          seq: @session.next_seq,
          type: "response",
          request_seq: request["seq"],
          success: true,
          command: request["command"],
          body: body
        })
      end

      def write_error_response(request, message)
        write_message({
          seq: @session.next_seq,
          type: "response",
          request_seq: request && request["seq"],
          success: false,
          command: request && request["command"],
          message: message,
          body: {
            error: {
              id: 1,
              format: message
            }
          }
        })
      end

      def write_event(event, body = nil)
        message = {
          seq: @session.next_seq,
          type: "event",
          event: event
        }
        message[:body] = body if body
        write_message(message)
      end

      def write_message(message)
        @write_mutex.synchronize do
          @protocol.write_message(message)
        end
      end

      def backend_initialize_arguments(client_arguments)
        {
          "adapterID" => "milk-tea",
          "clientID" => "milk-tea",
          "linesStartAt1" => true,
          "columnsStartAt1" => true,
          "pathFormat" => "path"
        }.merge(client_arguments)
      end

      def filter_breakpoint_for_backend(breakpoint)
        breakpoint.each_with_object({}) do |(key, value), result|
          next if key.to_s == "id" || key.to_s == "verified"

          result[key.to_s] = value
        end
      end

      def load_debug_map(runnable_path)
        @debug_map = runnable_path ? DebugMap.load_for_binary(runnable_path) : nil
        @frame_debug_functions = {}
        @variables_reference_debug_functions = {}
      end

      def maybe_load_debug_map_from_backend_modules
        return if @debug_map
        return unless capability_enabled?("supportsModulesRequest")

        response = backend_request("modules", {})
        return unless response["success"]

        modules = response.dig("body", "modules")
        return unless modules.is_a?(Array)

        modules.each do |mod|
          candidate_path = dap_value(mod, "path") || dap_value(mod, "symbolFilePath")
          next if candidate_path.to_s.empty?

          candidate_path = File.expand_path(candidate_path)
          debug_map = DebugMap.load_for_binary(candidate_path)
          next unless debug_map

          @debug_map = debug_map
          @frame_debug_functions = {}
          @variables_reference_debug_functions = {}
          return
        end
      end

      def clear_debug_context
        @debug_map = nil
        @frame_debug_functions = {}
        @variables_reference_debug_functions = {}
        @backend_stopped_thread_id = nil
      end

      def rewrite_stack_trace_response(backend_response)
        return unless @debug_map
        return unless backend_response["success"]

        body = backend_response["body"]
        stack_frames = dap_value(body, "stackFrames")
        return unless stack_frames.is_a?(Array)

        @frame_debug_functions.clear
        stack_frames.each do |frame|
          function = @debug_map.function_for_c_name(dap_value(frame, "name"))
          next unless function

          dap_set(frame, "name", function.name)
          frame_id = normalize_reference_key(dap_value(frame, "id"))
          @frame_debug_functions[frame_id] = function if frame_id
        end
      end

      def rewrite_scopes_response(backend_response, frame_id)
        return unless backend_response["success"]

        normalized_frame_id = normalize_reference_key(frame_id)
        function = @frame_debug_functions[normalized_frame_id]

        body = backend_response["body"]
        scopes = dap_value(body, "scopes")
        return unless scopes.is_a?(Array)

        scopes.each do |scope|
          reference = normalize_reference_key(dap_value(scope, "variablesReference"))
          next unless reference

          scope_name = dap_value(scope, "name").to_s
          @variables_reference_debug_functions[reference] = {
            frame_id: normalized_frame_id,
            function: scope_name == "Locals" ? function : nil,
          }
        end
      end

      def rewrite_variables_response(backend_response, variables_reference)
        return unless @debug_map
        return unless backend_response["success"]

        function = debug_function_for_variables_reference(variables_reference)
        return unless function

        body = backend_response["body"]
        variables = dap_value(body, "variables")
        return unless variables.is_a?(Array)

        rewritten = variables.each_with_object([]) do |variable, kept|
          raw_name = dap_value(variable, "name").to_s
          entry = @debug_map.variable_for(function.c_name, raw_name)

          if entry
            dap_set(variable, "name", entry.name)
            kept << variable
            next
          end

          next if raw_name.start_with?("__mt_")

          kept << variable
        end

        dap_set(body, "variables", rewritten)
      end

      def rewrite_evaluate_arguments(arguments)
        rewritten = arguments.dup
        rewritten["expression"] = rewrite_expression_for_frame(arguments["expression"], arguments["frameId"])
        rewritten
      end

      def rewrite_set_expression_arguments(arguments)
        rewritten = arguments.dup
        rewritten["expression"] = rewrite_expression_for_frame(arguments["expression"], arguments["frameId"])
        rewritten["value"] = rewrite_expression_for_frame(arguments["value"], arguments["frameId"])
        rewritten
      end

      def rewrite_set_variable_arguments(arguments)
        rewritten = arguments.dup
        function = debug_function_for_variables_reference(arguments["variablesReference"])
        return rewritten unless function

        if (entry = @debug_map.source_variable_for(function.c_name, arguments["name"]))
          rewritten["name"] = entry.c_name
        end
        rewritten["value"] = rewrite_expression_for_function(arguments["value"], function)
        rewritten
      end

      def rewrite_data_breakpoint_info_arguments(arguments)
        rewritten = arguments.dup

        if arguments.key?("variablesReference")
          function = debug_function_for_variables_reference(arguments["variablesReference"])
          return rewritten unless function

          if (entry = @debug_map.source_variable_for(function.c_name, arguments["name"]))
            rewritten["name"] = entry.c_name
          end
          return rewritten
        end

        rewritten["name"] = rewrite_expression_for_frame(arguments["name"], arguments["frameId"])
        rewritten
      end

      def request_set_variable(arguments)
        return backend_request("setVariable", arguments) if backend_supports_set_variable?

        unless backend_supports_set_expression?
          return {
            "success" => false,
            "message" => "setVariable is not supported by the lldb-dap backend"
          }
        end

        context = variables_reference_context(arguments["variablesReference"])
        frame_id = context && context[:frame_id]
        unless frame_id
          return {
            "success" => false,
            "message" => "setVariable requires a scope frame context"
          }
        end

        set_expression_arguments = {
          "expression" => arguments["name"],
          "value" => arguments["value"],
          "frameId" => frame_id,
        }
        set_expression_arguments["format"] = arguments["format"] if arguments.key?("format")

        backend_request("setExpression", set_expression_arguments)
      end

      def rewrite_expression_for_frame(expression, frame_id)
        rewrite_expression_for_function(expression, debug_function_for_frame(frame_id))
      end

      def rewrite_expression_for_function(expression, function)
        return expression unless @debug_map
        return expression unless function
        return expression unless expression.is_a?(String)
        return expression if expression.empty?

        rewritten = +""
        index = 0
        while index < expression.length
          char = expression[index]
          if char == '"' || char == "'"
            index = copy_quoted_segment(expression, index, rewritten)
            next
          end

          if identifier_start_char?(char)
            start = index
            index += 1
            index += 1 while index < expression.length && identifier_continue_char?(expression[index])
            identifier = expression[start...index]
            if accessor_identifier?(expression, start)
              rewritten << identifier
              next
            end

            entry = @debug_map.source_variable_for(function.c_name, identifier)
            rewritten << (entry ? entry.c_name : identifier)
            next
          end

          rewritten << char
          index += 1
        end

        rewritten
      end

      def debug_function_for_frame(frame_id)
        @frame_debug_functions[normalize_reference_key(frame_id)]
      end

      def debug_function_for_variables_reference(variables_reference)
        context = variables_reference_context(variables_reference)
        context && context[:function]
      end

      def variables_reference_context(variables_reference)
        @variables_reference_debug_functions[normalize_reference_key(variables_reference)]
      end

      def effective_adapter_capabilities
        capabilities = ADAPTER_CAPABILITIES.merge(
          @backend_capabilities.transform_keys { |key| key.to_sym }
        )
        capabilities[:supportsSetVariable] = true if backend_supports_set_variable? || backend_supports_set_expression?
        capabilities
      end

      def backend_supports_set_variable?
        capability_enabled?("supportsSetVariable")
      end

      def backend_supports_set_expression?
        capability_enabled?("supportsSetExpression")
      end

      def capability_enabled?(name)
        value = @backend_capabilities[name] || @backend_capabilities[name.to_sym]
        !!value
      end

      def copy_quoted_segment(expression, index, output)
        quote = expression[index]
        output << quote
        index += 1

        while index < expression.length
          char = expression[index]
          output << char
          index += 1

          if char == "\\" && index < expression.length
            output << expression[index]
            index += 1
            next
          end

          break if char == quote
        end

        index
      end

      def accessor_identifier?(expression, index)
        previous_index = index - 1
        previous_index -= 1 while previous_index >= 0 && whitespace_char?(expression[previous_index])
        return false if previous_index < 0
        return true if expression[previous_index] == "."

        return false unless expression[previous_index] == ">"

        previous_index -= 1
        previous_index -= 1 while previous_index >= 0 && whitespace_char?(expression[previous_index])
        previous_index >= 0 && expression[previous_index] == "-"
      end

      def identifier_start_char?(char)
        char.match?(/[A-Za-z_]/)
      end

      def identifier_continue_char?(char)
        char.match?(/[A-Za-z0-9_]/)
      end

      def whitespace_char?(char)
        char.match?(/\s/)
      end

      def dap_value(payload, key)
        return nil unless payload.is_a?(Hash)

        payload[key] || payload[key.to_sym]
      end

      def dap_set(payload, key, value)
        return unless payload.is_a?(Hash)

        if payload.key?(key)
          payload[key] = value
        elsif payload.key?(key.to_sym)
          payload[key.to_sym] = value
        else
          payload[key] = value
        end
      end

      def normalize_reference_key(value)
        return nil if value.nil?
        return value if value.is_a?(Integer)

        text = value.to_s.strip
        return text.to_i if text.match?(/\A\d+\z/)

        text
      end

      def default_backend_kind
        @preferred_backend_kind
      end

      def resolved_backend_kind(requested_backend)
        backend = requested_backend.to_s.strip
        backend = default_backend_kind if backend.empty?
        return backend if backend == "process" || backend == "lldb-dap"

        nil
      end

      def resolve_launch_program(program)
        path = program.to_s
        return { ok: false, error: "launch requires a non-empty 'program' argument" } if path.empty?

        expanded = File.expand_path(path)
        if expanded.end_with?(".mt")
          return { ok: false, error: "Milk Tea program not found: #{expanded}" } unless File.file?(expanded)

          tmp_dir = Dir.mktmpdir("milk-tea-dap")
          @tmp_dirs << tmp_dir
          output_path = File.join(tmp_dir, File.basename(expanded, ".mt"))

          begin
            Build.build(expanded, output_path:, debug: true)
          rescue BuildError => e
            return { ok: false, error: e.message }
          end

          return { ok: true, runnable_path: output_path }
        end

        return { ok: false, error: "Program not found: #{expanded}" } unless File.file?(expanded)

        { ok: true, runnable_path: expanded }
      end

      def resolve_debug_program(command, program)
        return resolve_launch_program(program) if command == "launch"

        path = program.to_s
        return { ok: true, runnable_path: nil } if path.empty?

        resolve_launch_program(path)
      end

      def backend_start_arguments(command, arguments, resolved)
        rewritten = arguments.dup

        rewritten.delete("backend")
        rewritten.delete("adapterPath")

        if resolved[:runnable_path]
          rewritten["program"] = resolved[:runnable_path]
        elsif rewritten["program"].to_s.empty?
          rewritten.delete("program")
        end

        rewritten["stopOnEntry"] = true if command == "launch"

        rewritten["cwd"] = File.expand_path(rewritten["cwd"]) if rewritten["cwd"].is_a?(String) && !rewritten["cwd"].empty?
        rewritten["coreFile"] = File.expand_path(rewritten["coreFile"]) if rewritten["coreFile"].is_a?(String) && !rewritten["coreFile"].empty?
        rewritten
      end

      def backend_continue_arguments
        thread_id = @backend_stopped_thread_id || backend_thread_id_for_auto_continue
        return {} unless thread_id

        { "threadId" => thread_id }
      end

      def continued_event_signature(body)
        return nil unless body.is_a?(Hash)

        [
          normalize_reference_key(dap_value(body, "threadId")),
          dap_value(body, "allThreadsContinued") == true,
        ]
      end

      def rewrite_backend_stopped_event_body(body)
        return body unless @backend_pause_requested
        return body unless body.is_a?(Hash)

        reason = dap_value(body, "reason").to_s
        description = dap_value(body, "description").to_s
        text = dap_value(body, "text").to_s
        return body unless reason == "exception"
        return body unless description.match?(/\bSIGSTOP\b/) || text.match?(/\bSIGSTOP\b/)

        rewritten = body.dup
        dap_set(rewritten, "reason", "pause")
        dap_set(rewritten, "description", "Paused") if !description.empty? || rewritten.key?("description") || rewritten.key?(:description)
        dap_set(rewritten, "text", "Paused") if !text.empty? || rewritten.key?("text") || rewritten.key?(:text)
        rewritten
      end

      def backend_configuration_ready?
        @backend_configuration_mutex.synchronize { @backend_configuration_ready }
      end

      def backend_start_pending?
        thread = @backend_start_thread
        thread && thread.alive?
      end

      def backend_configuration_pending?
        backend_start_pending? && !backend_configuration_ready?
      end

      def wait_for_backend_configuration_ready(timeout: 30)
        return true unless backend_configuration_pending?

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

        @backend_configuration_mutex.synchronize do
          while @backend_start_thread&.alive? && !@backend_configuration_ready
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            return false if remaining <= 0

            @backend_configuration_condition.wait(@backend_configuration_mutex, remaining)
          end
        end

        true
      end

      def mark_backend_configuration_ready
        @backend_configuration_mutex.synchronize do
          @backend_configuration_ready = true
          @backend_configuration_condition.broadcast
        end
      end

      def reset_backend_configuration_ready
        @backend_configuration_mutex.synchronize do
          @backend_configuration_ready = false
        end
      end

      def backend_thread_id_for_auto_continue
        response = backend_request("threads", {})
        return nil unless response["success"]

        threads = response.dig("body", "threads")
        return nil unless threads.is_a?(Array)

        first_thread = threads.first
        return nil unless first_thread.is_a?(Hash)

        first_thread["id"]
      end

      def start_runtime_if_needed
        return if @session.runtime_started?
        return unless @session.runnable_path

        @session.mark_runtime_started!
        runnable_path = @session.runnable_path
        command = [runnable_path, *@session.program_args]
        chdir = File.dirname(File.expand_path(@session.program_path || runnable_path))

        Thread.new do
          Open3.popen3(*command, chdir:) do |stdin, stdout, stderr, wait_thr|
            stdin.close
            @runtime_mutex.synchronize { @runtime_pid = wait_thr.pid }

            out_thread = Thread.new do
              stdout.each_line do |line|
                write_event("output", { category: "stdout", output: line })
              end
            end

            err_thread = Thread.new do
              stderr.each_line do |line|
                write_event("output", { category: "stderr", output: line })
              end
            end

            out_thread.join
            err_thread.join

            status = wait_thr.value
            exit_code = status.exited? ? status.exitstatus : 1
            @session.terminate!

            write_event("terminated")
            write_event("exited", { exitCode: exit_code })
            @session.request_exit!
          end
        rescue StandardError => e
          @session.terminate!
          write_event("output", { category: "stderr", output: "DAP runtime error: #{e.message}\n" })
          write_event("terminated")
          write_event("exited", { exitCode: 1 })
          @session.request_exit!
        ensure
          @runtime_mutex.synchronize do
            @runtime_pid = nil
            @runtime_paused = false
          end
        end
      end

      def pause_runtime_if_running
        pid = @runtime_mutex.synchronize { @runtime_pid }
        return false if pid.nil?

        Process.kill("STOP", pid)
        @runtime_mutex.synchronize { @runtime_paused = true }
        true
      rescue StandardError
        false
      end

      def continue_runtime_if_paused
        pid, paused = @runtime_mutex.synchronize { [@runtime_pid, @runtime_paused] }
        return unless paused
        return if pid.nil?

        Process.kill("CONT", pid)
        @runtime_mutex.synchronize { @runtime_paused = false }
      rescue StandardError
        nil
      end

      def terminate_runtime_if_running
        pid = @runtime_mutex.synchronize { @runtime_pid }
        return if pid.nil?

        Process.kill("TERM", pid)
        @runtime_mutex.synchronize { @runtime_paused = false }
      rescue StandardError
        nil
      end

      def cleanup_tmp_dirs
        @tmp_dirs.each do |dir|
          FileUtils.remove_entry(dir) if File.exist?(dir)
        end
        @tmp_dirs.clear
      end
    end
  end
end

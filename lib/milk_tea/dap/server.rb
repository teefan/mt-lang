# frozen_string_literal: true

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

module MilkTea
  module DAP
    # Minimal DAP server with strict request/response/event envelopes.
    class Server
      def initialize(protocol: Protocol.new, session: Session.new, backend_factory: nil)
        @protocol = protocol
        @session = session
        @backend_factory = backend_factory
        @handlers = {}
        @write_mutex = Mutex.new
        @runtime_mutex = Mutex.new
        @runtime_pid = nil
        @runtime_thread = nil
        @tmp_dirs = []
        @lldb_backend = nil
        @breakpoints_synced_to_backend = false
        register_handlers
      end

      def run
        loop do
          message = @protocol.read_message
          break if message.nil?

          process_message(message)
          break if @session.should_exit?
        end
      end

      private

      def register_handlers
        @handlers["initialize"] = method(:handle_initialize)
        @handlers["setBreakpoints"] = method(:handle_set_breakpoints)
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
      end

      def process_message(message)
        return unless message["type"] == "request"

        command = message["command"]
        handler = @handlers[command]

        if handler.nil?
          write_error_response(message, "Unsupported command: #{command}")
          return
        end

        unless command == "initialize" || @session.initialized?
          write_error_response(message, "initialize request must be sent first")
          return
        end

        handler.call(message)
      rescue StandardError => e
        write_error_response(message, "Internal error: #{e.message}")
      end

      ADAPTER_CAPABILITIES = {
        supportsConfigurationDoneRequest: true,
        supportsFunctionBreakpoints: false,
        supportsConditionalBreakpoints: false,
        supportsEvaluateForHovers: false,
        supportsSetVariable: false,
        supportsTerminateRequest: true
      }.freeze

      def handle_initialize(message)
        if @session.initialized?
          write_error_response(message, "initialize can only be called once")
          return
        end

        @session.initialize!

        write_response(message, ADAPTER_CAPABILITIES)

        write_event("initialized")
      end

      def handle_set_breakpoints(message)
        args = message["arguments"] || {}
        source = args["source"] || {}
        source_path = source["path"].to_s
        requested = args["breakpoints"] || Array(args["lines"]).map { |line| { "line" => line } }
        breakpoints = @session.set_breakpoints(source_path, requested)

        if using_lldb_backend?
          backend_response = backend_request("setBreakpoints", {
            "source" => source,
            "breakpoints" => requested
          })
          return write_backend_response(message, backend_response)
        end

        write_response(message, { breakpoints: breakpoints })
      end

      def handle_configuration_done(message)
        @session.configuration_done!

        if using_lldb_backend?
          sync_breakpoints_to_backend
          backend_response = backend_request("configurationDone", {})
          return write_backend_response(message, backend_response)
        end

        write_response(message, {})
        maybe_start_or_stop_on_entry
      end

      def handle_launch(message)
        request_start(message)
      end

      def handle_attach(message)
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
        return write_backend_response(message, backend_request("stackTrace", message["arguments"] || {})) if using_lldb_backend?

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
        return write_backend_response(message, backend_request("scopes", message["arguments"] || {})) if using_lldb_backend?

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
        return write_backend_response(message, backend_request("variables", message["arguments"] || {})) if using_lldb_backend?

        _args = message["arguments"] || {}
        write_response(message, { variables: [] })
      end

      def handle_continue(message)
        return write_backend_response(message, backend_request("continue", message["arguments"] || {})) if using_lldb_backend?

        start_runtime_if_needed
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
        return write_backend_response(message, backend_request("pause", message["arguments"] || {})) if using_lldb_backend?

        write_error_response(message, "pause is not supported by the process backend")
      end

      def handle_terminate(message)
        if using_lldb_backend?
          backend_response = backend_request("terminate", message["arguments"] || {})
          write_backend_response(message, backend_response)
          return
        end

        terminate_runtime_if_running
        write_response(message, {})
      end

      def handle_disconnect(message)
        if using_lldb_backend?
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

        resolved = resolve_launch_program(args["program"])
        unless resolved[:ok]
          write_error_response(message, resolved[:error])
          return
        end

        program_args = args["args"] || []
        unless program_args.is_a?(Array)
          write_error_response(message, "launch 'args' must be an array when provided")
          return
        end

        stop_on_entry = args.key?("stopOnEntry") ? !!args["stopOnEntry"] : true
        backend_kind = args["backend"].to_s == "lldb-dap" ? "lldb-dap" : "process"

        @session.request_start!(
          program_path: args["program"],
          runnable_path: resolved[:runnable_path],
          program_args:,
          stop_on_entry:,
          backend_kind:
        )
        @session.launch!

        if using_lldb_backend?
          start_lldb_backend(args)
          init_response = backend_request("initialize", {
            "adapterID" => "milk-tea",
            "clientID" => "milk-tea",
            "linesStartAt1" => true,
            "columnsStartAt1" => true,
            "pathFormat" => "path"
          })
          return write_backend_response(message, init_response) unless init_response["success"]

          # Merge backend capabilities with adapter capabilities and notify the client.
          backend_caps = init_response["body"] || {}
          merged_caps = ADAPTER_CAPABILITIES.merge(
            backend_caps.transform_keys { |k| k.to_sym }
          )
          write_event("capabilities", merged_caps)

          launch_arguments = args.merge("program" => resolved[:runnable_path])
          backend_response = backend_request(message["command"], launch_arguments)
          @breakpoints_synced_to_backend = false
          return write_backend_response(message, backend_response)
        end

        write_response(message, {})
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
                            ["lldb-dap"]
                          else
                            expanded = File.expand_path(adapter_path)
                            expanded.end_with?(".rb") ? [RbConfig.ruby, expanded] : [expanded]
                          end

        @lldb_backend = if @backend_factory
                          @backend_factory.call(adapter_command, method(:handle_backend_event))
                        else
                          Backends::LLDBDAP.new(
                            adapter_command: adapter_command,
                            on_event: method(:handle_backend_event)
                          )
                        end
        @lldb_backend.start!
      end

      def stop_lldb_backend
        @lldb_backend&.stop!
      ensure
        @lldb_backend = nil
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

      def write_backend_response(request, backend_response)
        if backend_response["success"]
          write_response(request, backend_response["body"] || {})
        else
          write_error_response(request, backend_response["message"] || "backend request failed")
        end
      end

      def handle_backend_event(message)
        event = message["event"].to_s
        body = message["body"]

        write_event(event, body)

        return unless event == "terminated" || event == "exited"

        if event == "exited"
          @session.mark_runtime_exited!(body && body["exitCode"] || 0)
        end
        @session.terminate!
      end

      def sync_breakpoints_to_backend
        return if @breakpoints_synced_to_backend

        @session.each_breakpoint_source do |source_path, breakpoints|
          backend_request("setBreakpoints", {
            "source" => { "path" => source_path },
            "breakpoints" => breakpoints.map { |bp| { "line" => bp[:line] || bp["line"] } }
          })
        end
        @breakpoints_synced_to_backend = true
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

      def start_runtime_if_needed
        return if @session.runtime_started?
        return unless @session.runnable_path

        @session.mark_runtime_started!
        runnable_path = @session.runnable_path
        command = [runnable_path, *@session.program_args]
        chdir = File.dirname(File.expand_path(@session.program_path || runnable_path))

        @runtime_thread = Thread.new do
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
            @session.mark_runtime_exited!(exit_code)
            @session.terminate!

            write_event("terminated")
            write_event("exited", { exitCode: exit_code })
            @session.request_exit!
          end
        rescue StandardError => e
          @session.mark_runtime_exited!(1)
          @session.terminate!
          write_event("output", { category: "stderr", output: "DAP runtime error: #{e.message}\n" })
          write_event("terminated")
          write_event("exited", { exitCode: 1 })
          @session.request_exit!
        ensure
          @runtime_mutex.synchronize { @runtime_pid = nil }
        end
      end

      def terminate_runtime_if_running
        pid = @runtime_mutex.synchronize { @runtime_pid }
        return if pid.nil?

        Process.kill("TERM", pid)
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

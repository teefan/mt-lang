# frozen_string_literal: true

module MilkTea
  module DAP
    class Server
      module ServerLaunch
        private

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
      end
    end
  end
end

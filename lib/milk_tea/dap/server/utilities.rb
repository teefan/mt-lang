# frozen_string_literal: true

module MilkTea
  module DAP
    class Server
      module ServerUtilities
        PERF_LOG_THRESHOLD_MS = 20

        private

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

        def cleanup_tmp_dirs
          @tmp_dirs.each do |dir|
            FileUtils.remove_entry(dir) if File.exist?(dir)
          end
          @tmp_dirs.clear
        end
      end
    end
  end
end

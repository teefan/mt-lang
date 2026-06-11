# frozen_string_literal: true

module MilkTea
  module DAP
    class Server
      module ServerLLDBBackend
        private

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

          timeout_seconds = reverse_request_timeout
          client_response = Timeout.timeout(timeout_seconds) { queue.pop }
          build_backend_request_response(message, client_response)
        rescue Timeout::Error
          {
            "seq" => @session.next_seq,
            "type" => "response",
            "request_seq" => message["seq"],
            "success" => false,
            "command" => message["command"],
            "message" => format("client request timed out after %.1fs: %s", timeout_seconds, message["command"])
          }
        ensure
          @client_request_mutex.synchronize do
            @pending_client_responses.delete(client_seq) if defined?(client_seq)
          end
        end

        def reverse_request_timeout
          timeout = @reverse_request_timeout.to_f
          timeout.positive? ? timeout : 15.0
        rescue StandardError
          15.0
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

        def effective_adapter_capabilities
          capabilities = ADAPTER_CAPABILITIES.merge(
            @backend_capabilities.transform_keys { |key| key.to_sym }
          )
          capabilities[:supportsSetVariable] = true if backend_supports_set_variable? || backend_supports_set_expression?

          backend_filters = @backend_capabilities["exceptionBreakpointFilters"]
          if backend_filters.is_a?(Array) && !backend_filters.empty?
            capabilities[:exceptionBreakpointFilters] = backend_filters
          end

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
      end
    end
  end
end

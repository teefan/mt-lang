# frozen_string_literal: true

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

require_relative "../tooling/debug_map"

require_relative "server/handlers"
require_relative "server/launch"
require_relative "server/lldb_backend"
require_relative "server/debug_map"
require_relative "server/breakpoints"
require_relative "server/pause_diagnostics"
require_relative "server/wire"
require_relative "server/utilities"

module MilkTea
  module DAP
    # Minimal DAP server with strict request/response/event envelopes.
    class Server
      ADAPTER_CAPABILITIES = {
        supportsConfigurationDoneRequest: true,
        supportsFunctionBreakpoints: false,
        supportsConditionalBreakpoints: false,
        supportsPauseRequest: true,
        supportsEvaluateForHovers: false,
        supportsSetVariable: false,
        supportsTerminateRequest: true,
        supportsLoadedSourcesRequest: true,
        exceptionBreakpointFilters: [],
      }.freeze

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
        @reverse_request_timeout = Float(ENV.fetch("MILK_TEA_DAP_REVERSE_REQUEST_TIMEOUT", "15"))
        register_handlers
      end

      def run
        start_client_reader

        loop do
          message = @incoming_messages.pop
          break if message.nil?
          next if message.equal?(Protocol::INVALID_MESSAGE)

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
            next if message.equal?(Protocol::INVALID_MESSAGE)

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

      include ServerHandlers
      include ServerLaunch
      include ServerLLDBBackend
      include ServerDebugMap
      include ServerBreakpoints
      include ServerPauseDiagnostics
      include ServerWire
      include ServerUtilities
    end
  end
end

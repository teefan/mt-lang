# frozen_string_literal: true

module MilkTea
  module DAP
    # Holds mutable state for one DAP session.
    class Session
      attr_reader :program_path, :runnable_path, :program_args, :thread_id, :exit_code, :backend_kind,
          :function_breakpoints, :exception_breakpoints

      def initialize
        @next_outgoing_seq = 1
        @next_breakpoint_id = 1
        @thread_id = 1
        @initialized = false
        @configuration_done = false
        @launched = false
        @terminated = false
        @should_exit = false
        @start_requested = false
        @entry_stop_emitted = false
        @program_path = nil
        @runnable_path = nil
        @program_args = []
        @backend_kind = "process"
        @stop_on_entry = true
        @runtime_started = false
        @runtime_exited = false
        @exit_code = nil
        @breakpoints_by_source = {}
        @function_breakpoints = []
        @exception_breakpoints = nil
      end

      def next_seq
        seq = @next_outgoing_seq
        @next_outgoing_seq += 1
        seq
      end

      def initialize!
        @initialized = true
      end

      def initialized?
        @initialized
      end

      def configuration_done!
        @configuration_done = true
      end

      def configuration_done?
        @configuration_done
      end

      def request_start!(program_path:, runnable_path:, program_args: [], stop_on_entry: true, backend_kind: "process")
        @start_requested = true
        @program_path = program_path
        @runnable_path = runnable_path
        @program_args = Array(program_args).map(&:to_s)
        @backend_kind = backend_kind
        @stop_on_entry = stop_on_entry
      end

      def start_requested?
        @start_requested
      end

      def launch!
        @launched = true
      end

      def launched?
        @launched
      end

      def stop_on_entry?
        @stop_on_entry
      end

      def entry_stop_emitted?
        @entry_stop_emitted
      end

      def mark_entry_stop_emitted!
        @entry_stop_emitted = true
      end

      def mark_runtime_started!
        @runtime_started = true
      end

      def runtime_started?
        @runtime_started
      end

      def mark_runtime_exited!(exit_code)
        @runtime_exited = true
        @exit_code = exit_code
      end

      def runtime_exited?
        @runtime_exited
      end

      def terminate!
        @terminated = true
      end

      def terminated?
        @terminated
      end

      def request_exit!
        @should_exit = true
      end

      def should_exit?
        @should_exit
      end

      def set_breakpoints(source_path, breakpoints)
        normalized = breakpoints.map do |bp|
          raw = normalize_dap_hash(bp)
          raw["id"] = next_breakpoint_id
          raw["verified"] = true
          raw["line"] = raw["line"].to_i
          raw
        end
        @breakpoints_by_source[source_path] = normalized
        normalized
      end

      def set_function_breakpoints(breakpoints)
        @function_breakpoints = breakpoints.map do |bp|
          raw = normalize_dap_hash(bp)
          raw["id"] = next_breakpoint_id
          raw["verified"] = true
          raw["name"] = raw["name"].to_s
          raw
        end
      end

      def set_exception_breakpoints(arguments)
        @exception_breakpoints = normalize_dap_hash(arguments)
      end

      def each_breakpoint_source
        @breakpoints_by_source.each do |source_path, breakpoints|
          yield(source_path, breakpoints)
        end
      end

      private

      def normalize_dap_hash(value)
        value.each_with_object({}) do |(key, entry), result|
          result[key.to_s] = entry
        end
      end

      def next_breakpoint_id
        id = @next_breakpoint_id
        @next_breakpoint_id += 1
        id
      end
    end
  end
end

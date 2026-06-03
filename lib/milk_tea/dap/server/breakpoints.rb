# frozen_string_literal: true

module MilkTea
  module DAP
    class Server
      module ServerBreakpoints
        private

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
      end
    end
  end
end

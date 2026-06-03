# frozen_string_literal: true

module MilkTea
  module DAP
    class Server
      module ServerPauseDiagnostics
        private

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
      end
    end
  end
end

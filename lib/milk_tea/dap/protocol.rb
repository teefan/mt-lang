# frozen_string_literal: true

require "json"

module MilkTea
  module DAP
    # Handles DAP framing over stdin/stdout using Content-Length headers.
    class Protocol
      def initialize(input: $stdin, output: $stdout, error_output: nil)
        @input = input
        @output = output
        @error_output = error_output
      end

      def read_message
        headers = {}
        loop do
          line = @input.gets
          return nil if line.nil?

          stripped = line.chomp
          break if stripped.empty?

          key, value = stripped.split(":", 2)
          headers[key&.strip] = value&.strip
        end

        content_length = headers["Content-Length"]&.to_i
        return nil if content_length.nil? || content_length <= 0

        body = @input.read(content_length)
        JSON.parse(body)
      rescue StandardError => e
        log_error("DAP protocol read error: #{e.message}")
        nil
      end

      def write_message(message)
        json = JSON.dump(message)
        @output.write("Content-Length: #{json.bytesize}\r\n\r\n")
        @output.write(json)
        @output.flush
      rescue StandardError => e
        log_error("DAP protocol write error: #{e.message}")
      end

      private def log_error(message)
        return unless @error_output

        @error_output.puts(message)
      rescue StandardError
        nil
      end
    end
  end
end

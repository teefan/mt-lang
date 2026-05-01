# frozen_string_literal: true

require "json"

module MilkTea
  module DAP
    # Handles DAP framing over stdin/stdout using Content-Length headers.
    class Protocol
      def initialize(input: $stdin, output: $stdout)
        @input = input
        @output = output
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
        warn "DAP protocol read error: #{e.message}"
        nil
      end

      def write_message(message)
        json = JSON.dump(message)
        @output.write("Content-Length: #{json.bytesize}\r\n\r\n")
        @output.write(json)
        @output.flush
      rescue StandardError => e
        warn "DAP protocol write error: #{e.message}"
      end
    end
  end
end

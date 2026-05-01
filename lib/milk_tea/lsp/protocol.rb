# frozen_string_literal: true

require 'json'

module MilkTea
  module LSP
    # Handles JSON-RPC 2.0 protocol encoding/decoding over stdin/stdout
    class Protocol
      def self.read_message
        headers = {}
        loop do
          line = $stdin.gets
          return nil if line.nil?

          line = line.chomp
          break if line.empty?

          key, value = line.split(':', 2)
          headers[key&.strip] = value&.strip
        end

        content_length = headers['Content-Length']&.to_i
        return nil if content_length.nil? || content_length <= 0

        content = $stdin.read(content_length)
        JSON.parse(content)
      rescue StandardError => e
        warn "Protocol error reading message: #{e.message}"
        nil
      end

      def self.write_message(message)
        json = JSON.dump(message)
        length = json.bytesize
        header = "Content-Length: #{length}\r\n\r\n"
        $stdout.write(header)
        $stdout.write(json)
        $stdout.flush
      rescue StandardError => e
        warn "Protocol error writing message: #{e.message}"
      end

      def self.write_notification(method, params)
        write_message({
          jsonrpc: '2.0',
          method: method,
          params: params
        })
      end

      def self.write_response(id, result)
        write_message({
          jsonrpc: '2.0',
          id: id,
          result: result
        })
      end

      def self.write_error(id, code, message)
        write_message({
          jsonrpc: '2.0',
          id: id,
          error: {
            code: code,
            message: message
          }
        })
      end
    end
  end
end

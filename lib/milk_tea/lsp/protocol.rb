# frozen_string_literal: true

require 'json'
require 'thread'

module MilkTea
  module LSP
    # Handles JSON-RPC 2.0 protocol encoding/decoding over stdin/stdout
    class Protocol
      INVALID_MESSAGE = Object.new.freeze
      @write_mutex = Mutex.new
      @outgoing_mutex = Mutex.new
      @outgoing_id_counter = 1

      def self.outgoing_requests
        @outgoing_requests ||= {}
      end

      def self.send_request(method, params, &callback)
        id = @outgoing_mutex.synchronize { i = @outgoing_id_counter; @outgoing_id_counter += 1; i }
        @outgoing_mutex.synchronize { outgoing_requests[id] = callback }
        write_message({ jsonrpc: '2.0', id: id, method: method, params: params })
        id
      rescue StandardError => e
        @outgoing_mutex.synchronize { outgoing_requests.delete(id) }
        warn "Protocol error sending request #{method}: #{e.message}"
        nil
      end

      def self.handle_response(message)
        id = message['id']
        callback = @outgoing_mutex.synchronize { outgoing_requests.delete(id) }
        return unless callback

        callback.call(message['result'], message['error'])
      rescue StandardError => e
        warn "Protocol error handling response: #{e.message}"
      end

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
        return INVALID_MESSAGE if content_length.nil? || content_length <= 0

        content = $stdin.read(content_length)
        JSON.parse(content)
      rescue StandardError => e
        warn "Protocol error reading message: #{e.message}"
        INVALID_MESSAGE
      end

      def self.write_message(message)
        json = JSON.dump(message)
        length = json.bytesize
        header = "Content-Length: #{length}\r\n\r\n"
        @write_mutex.synchronize do
          $stdout.write(header)
          $stdout.write(json)
          $stdout.flush
        end
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

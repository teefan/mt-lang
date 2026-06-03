# frozen_string_literal: true

module MilkTea
  module DAP
    class Server
      module ServerWire
        private

        def write_response(request, body)
          write_message({
            seq: @session.next_seq,
            type: "response",
            request_seq: request["seq"],
            success: true,
            command: request["command"],
            body: body
          })
        end

        def write_error_response(request, message)
          write_message({
            seq: @session.next_seq,
            type: "response",
            request_seq: request && request["seq"],
            success: false,
            command: request && request["command"],
            message: message,
            body: {
              error: {
                id: 1,
                format: message
              }
            }
          })
        end

        def write_event(event, body = nil)
          message = {
            seq: @session.next_seq,
            type: "event",
            event: event
          }
          message[:body] = body if body
          write_message(message)
        end

        def write_message(message)
          @write_mutex.synchronize do
            @protocol.write_message(message)
          end
        end
      end
    end
  end
end

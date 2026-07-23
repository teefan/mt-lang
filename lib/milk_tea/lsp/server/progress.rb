# frozen_string_literal: true

module MilkTea
  module LSP
    class Server
      module ServerProgress
        private

        PROGRESS_TOKEN_PREFIX = "mt-lsp-progress"

        def create_progress(title:, message: nil, cancellable: false)
          token = "#{PROGRESS_TOKEN_PREFIX}-#{next_progress_token_id}"

          @protocol.send_request('window/workDoneProgress/create', { token: token }) do |_result, error|
            warn "[LSP] client rejected progress token #{token}: #{error}" if error
          end

          begin_value = { kind: 'begin', title: title, cancellable: cancellable }
          begin_value[:message] = message if message
          @protocol.write_notification('$/progress', { token: token, value: begin_value })
          create_progress_handle(@protocol, token)
        end

        def create_progress_handle(protocol, token)
          handle = Object.new
          handle.define_singleton_method(:report) do |percentage: nil, message: nil|
            value = { kind: 'report' }
            value[:percentage] = percentage if percentage
            value[:message] = message if message
            protocol.write_notification('$/progress', { token: token, value: value })
          end
          handle.define_singleton_method(:done) do |message: nil|
            value = { kind: 'end' }
            value[:message] = message if message
            protocol.write_notification('$/progress', { token: token, value: value })
          end
          handle
        end

        def next_progress_token_id
          @progress_token_counter ||= 0
          @progress_token_counter += 1
        end
      end
    end
  end
end

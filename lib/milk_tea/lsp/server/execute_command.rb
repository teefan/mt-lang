# frozen_string_literal: true

module MilkTea
  module LSP
    class Server
      module ServerExecuteCommand
        private

        def handle_execute_command(params)
          command = params["command"]
          case command
          when "mtc.restartServer"
            exit(0)
          else
            warn "Unknown executeCommand: #{command}"
            nil
          end
        rescue StandardError => e
          warn "Error in executeCommand handler: #{e.message}"
          nil
        end
      end
    end
  end
end

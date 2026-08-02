# frozen_string_literal: true

module MilkTea
  class CLI
    module CommandLsp
      def lsp_command
        log_level = nil

        until @argv.empty?
          arg = @argv.shift
          case arg
          when "--log-level"
            log_level = @argv.shift&.downcase
            unless log_level && %w[trace debug info warn error].include?(log_level)
              @err.puts("lsp: invalid --log-level #{log_level.inspect} (expected trace, debug, info, warn, or error)")
              return 1
            end
          when /\A--log-level=(.+)\z/
            log_level = ::Regexp.last_match(1).downcase
            unless %w[trace debug info warn error].include?(log_level)
              @err.puts("lsp: invalid --log-level #{log_level.inspect} (expected trace, debug, info, warn, or error)")
              return 1
            end
          when "--stdio"
            # stdio is the only transport; accept the flag as a no-op
          else
            if arg.start_with?("-")
              @err.puts("lsp: unknown option #{arg}")
              return 1
            end
            @err.puts("lsp: unexpected argument #{arg}")
            return 1
          end
        end

        require "milk_tea/lsp/server" unless defined?(MilkTea::LSP::Server)
        server = MilkTea::LSP::Server.new
        server.run
        0
      end
    end
  end
end

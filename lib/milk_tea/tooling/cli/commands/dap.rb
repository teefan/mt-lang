# frozen_string_literal: true

module MilkTea
  class CLI
    module CommandDap
      def dap_command
        preferred_backend_kind = "process"
        adapter_command = nil

        until @argv.empty?
          arg = @argv.shift
          case arg
          when "--log-level"
            @argv.shift
          when /\A--log-level=(.+)\z/
            # accept and ignore
          when "--backend"
            preferred_backend_kind = @argv.shift&.downcase
          when /\A--backend=(.+)\z/
            preferred_backend_kind = ::Regexp.last_match(1).downcase
          when "--adapter-path"
            adapter_path = @argv.shift
            adapter_command = resolve_adapter_path(adapter_path)
            return 1 unless adapter_command
          when /\A--adapter-path=(.+)\z/
            adapter_path = ::Regexp.last_match(1)
            adapter_command = resolve_adapter_path(adapter_path)
            return 1 unless adapter_command
          else
            if arg.start_with?("-")
              @err.puts("dap: unknown option #{arg}")
              return 1
            end
            @err.puts("dap: unexpected argument #{arg}")
            return 1
          end
        end

        require "milk_tea/dap/server" unless defined?(MilkTea::DAP::Server)
        server = MilkTea::DAP::Server.new(
          preferred_backend_kind:,
          adapter_command:,
        )
        server.run
        0
      end

      def resolve_adapter_path(adapter_path)
        unless adapter_path && File.file?(adapter_path)
          @err.puts("dap: adapter path not found: #{adapter_path}")
          return nil
        end
        expanded = File.expand_path(adapter_path)
        adapter_path.end_with?(".rb") ? [RbConfig.ruby, expanded] : [expanded]
      end
    end
  end
end

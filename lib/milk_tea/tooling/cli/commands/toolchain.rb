# frozen_string_literal: true

module MilkTea
  class CLI
    module CommandToolchain
      def toolchain_command
        ToolchainCLI.start(
          @argv,
          out: @out,
          err: @err,
          help_printer: method(:print_toolchain_help),
        )
      end
    end
  end
end

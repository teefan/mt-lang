# frozen_string_literal: true

module MilkTea
  class CLI
    module CommandToolchain
      def toolchain_command
        ToolchainCLI.start(
          @argv,
          out: @out,
          err: @err,
          help_printer: ->(io) { print_subcommand_help("toolchain", io) },
        )
      end
    end
  end
end

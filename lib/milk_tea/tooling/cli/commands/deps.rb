# frozen_string_literal: true

module MilkTea
  class CLI
    module CommandDeps
      def deps_command
        PackageManagerCLI.start(
          @argv,
          out: @out,
          err: @err,
          help_printer: ->(io) { print_subcommand_help("deps", io) },
          services: package_services,
        )
      end
    end
  end
end

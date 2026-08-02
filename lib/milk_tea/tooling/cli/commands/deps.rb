# frozen_string_literal: true

module MilkTea
  class CLI
    module CommandDeps
      def deps_command
        PackageManagerCLI.start(
          @argv,
          out: @out,
          err: @err,
          help_printer: method(:print_deps_help),
          services: package_services,
        )
      end
    end
  end
end

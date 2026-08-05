# frozen_string_literal: true

module MilkTea
  class CLI
    module CommandBindgen
      def bindgen_command
        BindgenCLI.start(@argv, out: @out, err: @err, help_printer: ->(io) { print_subcommand_help("bindgen", io) })
      end
    end
  end
end

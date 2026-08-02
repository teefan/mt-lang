# frozen_string_literal: true

module MilkTea
  class CLI
    module CommandBindgen
      def bindgen_command
        BindgenCLI.start(@argv, out: @out, err: @err, help_printer: method(:print_bindgen_help))
      end
    end
  end
end

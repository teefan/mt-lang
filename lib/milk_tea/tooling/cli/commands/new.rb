# frozen_string_literal: true

module MilkTea
  class CLI
    module CommandNew
      def new_command
        name = @argv.shift
        unless name
          @err.puts("missing project name")
          print_usage(@err)
          return 1
        end

        if @argv.any?
          @err.puts("unknown new option #{@argv.first}")
          print_usage(@err)
          return 1
        end

        result = ProjectScaffold.create(name)
        info("created #{result.root_path}")
        0
      end
    end
  end
end

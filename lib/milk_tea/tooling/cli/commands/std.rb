# frozen_string_literal: true

module MilkTea
  class CLI
    module CommandStd
      def std_command
        subcommand = @argv.shift

        case subcommand
        when "list"
          std_list_command
        when "show"
          std_show_command
        when nil
          @err.puts("missing std subcommand (expected list or show)")
          print_command_help("std", @err)
          1
        else
          @err.puts("unknown std subcommand #{subcommand}")
          print_command_help("std", @err)
          1
        end
      end

      def std_list_command
        as_json = false
        until @argv.empty?
          option = @argv.shift
          case option
          when "--json"
            as_json = true
          else
            @err.puts("unknown std list option #{option}")
            return 1
          end
        end

        entries = StdCatalog.entries
        if as_json
          @out.puts(JSON.generate(entries.map(&:to_h)))
          return 0
        end

        print_std_list(entries)
        0
      end

      def print_std_list(entries)
        name_width = entries.map { |entry| entry.name.length }.max
        description_width = entries.map { |entry| entry.description&.length.to_i }.max

        StdCatalog::CATEGORY_ORDER.each do |category|
          category_entries = entries.select { |entry| entry.category == category }
          next if category_entries.empty?

          @out.puts("#{category}:")
          category_entries.each do |entry|
            description = entry.description || "(no description)"
            @out.puts("  #{entry.name.ljust(name_width)}  #{description.ljust(description_width)}  #{entry.path}")
          end
          @out.puts
        end
      end

      def std_show_command
        name = @argv.shift
        unless name
          @err.puts("missing module name")
          print_command_help("std", @err)
          return 1
        end

        path = StdCatalog.resolve(name)
        unless path
          @err.puts("std module not found: #{name}")
          return 1
        end

        @out.write(File.read(path))
        0
      end
    end
  end
end

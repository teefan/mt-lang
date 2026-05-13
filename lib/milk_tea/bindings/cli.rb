# frozen_string_literal: true

module MilkTea
  class BindgenCLI
    def self.start(argv = ARGV, out:, err:, help_printer:)
      new(argv, out:, err:, help_printer:).start
    end

    def initialize(argv, out:, err:, help_printer:)
      @argv = argv.dup
      @out = out
      @err = err
      @help_printer = help_printer
    end

    def start
      module_name = @argv.shift
      header_path = @argv.shift
      unless module_name && header_path
        @err.puts("missing module name or header path")
        print_help
        return 1
      end

      require_relative "../bindings"

      options = parse_options
      return 1 unless options

      output_path = options.delete(:output_path)
      nullable_report_path = options.delete(:nullable_report_path)
      if nullable_report_path
        require "json"
        result = Bindgen.generate_with_report(module_name:, header_path:, **options)
        source = result.fetch(:source)
        report_path = File.expand_path(nullable_report_path)
        FileUtils.mkdir_p(File.dirname(report_path))
        File.write(report_path, JSON.pretty_generate(result.fetch(:nullable_policy_report)))
      else
        source = Bindgen.generate(module_name:, header_path:, **options)
      end

      if output_path
        FileUtils.mkdir_p(File.dirname(File.expand_path(output_path)))
        File.write(output_path, source)
        @out.puts("generated #{header_path} -> #{output_path}")
        @out.puts("nullable report #{header_path} -> #{report_path}") if nullable_report_path
      else
        @out.write(source)
        @err.puts("wrote nullable report #{report_path}") if nullable_report_path
      end
      0
    end

    private

    def print_help
      @help_printer.call(@err)
    end

    def parse_options
      options = {
        output_path: nil,
        nullable_report_path: nil,
        link_libraries: [],
        include_directives: [],
        clang: ENV.fetch("CLANG", "clang"),
        clang_args: [],
      }

      until @argv.empty?
        option = @argv.shift
        case option
        when "-o", "--output"
          value = @argv.shift
          return missing_option_value(option) unless value

          options[:output_path] = value
        when "--link"
          value = @argv.shift
          return missing_option_value(option) unless value

          options[:link_libraries] << value
        when "--include"
          value = @argv.shift
          return missing_option_value(option) unless value

          options[:include_directives] << value
        when "--clang"
          value = @argv.shift
          return missing_option_value(option) unless value

          options[:clang] = value
        when "--clang-arg"
          value = @argv.shift
          return missing_option_value(option) unless value

          options[:clang_args] << value
        when "--nullable-report"
          value = @argv.shift
          return missing_option_value(option) unless value

          options[:nullable_report_path] = value
        else
          @err.puts("unknown bindgen option #{option}")
          print_help
          return nil
        end
      end

      options[:include_directives] = nil if options[:include_directives].empty?
      options
    end

    def missing_option_value(option)
      @err.puts("missing value for #{option}")
      print_help
      nil
    end
  end
end

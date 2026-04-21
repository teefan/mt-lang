# frozen_string_literal: true

module MilkTea
  class CLI
    def self.start(argv = ARGV, out: $stdout, err: $stderr)
      new(argv, out:, err:).start
    end

    def initialize(argv, out:, err:)
      @argv = argv.dup
      @out = out
      @err = err
    end

    def start
      command = @argv.shift

      case command
      when "parse"
        parse_command
      else
        print_usage(@err)
        1
      end
    rescue MilkTea::LexError, MilkTea::ParseError, MilkTea::ModuleLoadError => e
      @err.puts(e.message)
      1
    end

    private

    def parse_command
      path = @argv.shift
      unless path
        @err.puts("missing source file path")
        print_usage(@err)
        return 1
      end

      ast = ModuleLoader.load_file(path)
      module_name = ast.module_name ? ast.module_name.to_s : "(anonymous)"
      @out.puts("parsed #{path} as #{module_name}")
      0
    end

    def print_usage(io)
      io.puts("Usage: mtc parse PATH")
    end
  end
end

# frozen_string_literal: true

module MilkTea
  class ToolchainCLI
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
      subcommand = @argv.shift
      unless subcommand
        @err.puts("missing toolchain subcommand")
        print_help
        return 1
      end

      case subcommand
      when "bootstrap"
        bootstrap_command
      when "doctor"
        doctor_command
      else
        @err.puts("unknown toolchain subcommand #{subcommand}")
        print_help
        1
      end
    end

    private

    def print_help
      @help_printer.call(@err)
    end

    def bootstrap_command
      if @argv.any?
        @err.puts("unknown toolchain option #{@argv.first}")
        print_help
        return 1
      end

      require_relative "../bindings"

      results = UpstreamSources.bootstrap_all!
      results.each do |result|
        verb = result.status == :present ? "kept" : "bootstrapped"
        @out.puts("#{verb} #{result.source.name} -> #{result.path}")
      end
      0
    end

    def doctor_command
      if @argv.any?
        @err.puts("unknown toolchain option #{@argv.first}")
        print_help
        return 1
      end

      require_relative "../bindings"

      cc = ENV.fetch("CC", "cc")
      ar = ENV.fetch("AR", "ar")
      checks = []

      checks << ["ruby", true, RUBY_DESCRIPTION]
      checks << ["cc", executable_available?(cc), cc]
      checks << ["ar", executable_available?(ar), ar]
      checks << ["bundle", executable_available?("bundle"), "bundle"]

      raylib_ok = false
      raylib_detail = "std.c.raylib binding missing"
      if checks.assoc("cc")[1]
        begin
          registry = RawBindings.default_registry(root: MilkTea.root)
          raylib_binding = registry.find_by_module_name("std.c.raylib")
          if raylib_binding
            raylib_binding.prepare!(cc: cc)
            raylib_ok = true
            raylib_detail = "std.c.raylib prepared"
          end
        rescue RawBindings::Error => e
          raylib_ok = false
          raylib_detail = e.message
        end
      else
        raylib_detail = "skipped (missing C compiler)"
      end
      checks << ["raylib", raylib_ok, raylib_detail]

      checks.each do |name, ok, detail|
        @out.puts("#{ok ? 'ok' : 'fail'} #{name}: #{detail}")
      end

      checks.all? { |_, ok, _| ok } ? 0 : 1
    end

    def executable_available?(program)
      return File.executable?(program) if program.include?(File::SEPARATOR)

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
        candidate = File.join(entry, program)
        File.file?(candidate) && File.executable?(candidate)
      end
    end
  end
end

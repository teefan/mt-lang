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
      when "tools"
        tools_command
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
      checks << ["git", executable_available?("git"), "git"]
      checks << ["clang", executable_available?(ENV.fetch("CLANG", "clang")), ENV.fetch("CLANG", "clang")]
      checks << ["cmake", executable_available?(ENV.fetch("CMAKE", "cmake")), ENV.fetch("CMAKE", "cmake")]
      checks << ["ninja", executable_available?("ninja"), "ninja"]

      UpstreamSources.default_sources(root: MilkTea.root).each do |source|
        missing = source.sentinel_paths.reject do |relative_path|
          File.exist?(source.checkout_root.join(relative_path))
        end
        if missing.empty?
          checks << ["source/#{source.name}", true, source.checkout_root.to_s]
        else
          checks << ["source/#{source.name}", false, "missing #{missing.first} under #{source.checkout_root}"]
        end
      end

      RawBindings.default_registry(root: MilkTea.root)
        .select { |binding| binding.module_name.start_with?("std.c.") }
        .sort_by(&:name)
        .each do |binding|
        begin
          header_path = binding.header_path(env: ENV)
          checks << ["binding/#{binding.name}", true, "#{binding.module_name} -> #{header_path}"]
        rescue RawBindings::Error => header_error
          unless checks.assoc("cc")[1]
            checks << ["binding/#{binding.name}", false, "skipped (missing C compiler)"]
            next
          end

          unless binding.respond_to?(:prepare!)
            checks << ["binding/#{binding.name}", false, header_error.message]
            next
          end

          begin
            binding.prepare!(env: ENV, cc:)
            header_path = binding.header_path(env: ENV)
            checks << ["binding/#{binding.name}", true, "#{binding.module_name} -> #{header_path}"]
          rescue RawBindings::Error => e
            checks << ["binding/#{binding.name}", false, e.message]
          end
        end
      end

      checks.each do |name, ok, detail|
        @out.puts("#{ok ? 'ok' : 'fail'} #{name}: #{detail}")
      end

      checks.all? { |_, ok, _| ok } ? 0 : 1
    end

    def tools_command
      if @argv.any?
        @err.puts("unknown toolchain option #{@argv.first}")
        print_help
        return 1
      end

      require_relative "../bindings"

      results = VendoredTools.build_all!(root: MilkTea.root)
      results.each do |result|
        @out.puts("built #{result[:tool].name} -> #{result[:binary]}")
      end
      0
    rescue VendoredTool::Error => e
      @err.puts(e.message)
      1
    end

    def executable_available?(program)
      return File.file?(program) && File.executable?(program) if program.include?(File::SEPARATOR)

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
        candidate = File.join(entry, program)
        File.file?(candidate) && File.executable?(candidate)
      end
    end
  end
end

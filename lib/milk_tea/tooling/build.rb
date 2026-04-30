# frozen_string_literal: true

require "fileutils"
require "open3"
require "tempfile"

module MilkTea
  class BuildError < StandardError; end

  class Build
    Result = Data.define(:output_path, :c_path, :compiler, :link_flags)

    def self.build(path, output_path: nil, cc: ENV.fetch("CC", "cc"), keep_c_path: nil, raw_bindings: nil)
      raw_bindings ||= default_raw_bindings
      new(path, output_path:, cc:, keep_c_path:, raw_bindings:).build
    end

    def self.default_raw_bindings(root: MilkTea.root)
      require_relative "../bindings"

      RawBindings.default_registry(root:)
    end
    private_class_method :default_raw_bindings

    def initialize(path, output_path:, cc:, keep_c_path:, raw_bindings:)
      @source_path = File.expand_path(path)
      @output_path = File.expand_path(output_path || default_output_path(@source_path))
      @cc = cc
      @keep_c_path = keep_c_path ? File.expand_path(keep_c_path) : nil
      @raw_bindings = raw_bindings
    end

    def build
      ensure_compiler_available!
      program = ModuleLoader.check_program(@source_path)
      prepare_bindings(program)
      generated_c = Codegen.generate_c(program)
      compiler_flags = collect_compiler_flags(program)
      link_flags = collect_link_flags(program)

      FileUtils.mkdir_p(File.dirname(@output_path))

      if @keep_c_path
        write_c_file(@keep_c_path, generated_c)
        compile(@keep_c_path, compiler_flags, link_flags)
        return Result.new(output_path: @output_path, c_path: @keep_c_path, compiler: @cc, link_flags:)
      end

      Tempfile.create(["milk-tea-build", ".c"]) do |file|
        file.write(generated_c)
        file.flush
        file.close

        compile(file.path, compiler_flags, link_flags)
      end

      Result.new(output_path: @output_path, c_path: nil, compiler: @cc, link_flags:)
    end

    private

    def default_output_path(source_path)
      source_path.sub(/\.mt\z/, "")
    end

    def prepare_bindings(program)
      program.analyses_by_module_name.keys.sort.each do |module_name|
        analysis = program.analyses_by_module_name.fetch(module_name)
        next unless analysis.module_kind == :extern_module

        binding = @raw_bindings.find_by_module_name(module_name)
        next unless binding

        binding.prepare!(cc: @cc)
      end
    rescue RawBindings::Error => e
      raise BuildError, e.message
    end

    def write_c_file(path, source)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, source)
    end

    def ensure_compiler_available!
      return if compiler_available?(@cc)

      raise BuildError, "C compiler not found: #{@cc}"
    end

    def collect_link_flags(program)
      program.analyses_by_module_name.keys.sort.each_with_object([]) do |module_name, flags|
        analysis = program.analyses_by_module_name.fetch(module_name)
        next unless analysis.module_kind == :extern_module

        binding = @raw_bindings.find_by_module_name(module_name)
        if binding
          binding.link_flags.grep(/\A-L/).each do |flag|
            flags << flag unless flags.include?(flag)
          end
        end

        analysis.directives.grep(AST::LinkDirective).each do |directive|
          flag = "-l#{directive.value}"
          flags << flag unless flags.include?(flag)
        end

        if binding
          binding.link_flags.reject { |flag| flag.start_with?("-L") }.each do |flag|
            flags << flag unless flags.include?(flag)
          end
        end
      end
    end

    def collect_compiler_flags(program)
      program.analyses_by_module_name.keys.sort.each_with_object([]) do |module_name, flags|
        analysis = program.analyses_by_module_name.fetch(module_name)
        next unless analysis.module_kind == :extern_module

        binding = @raw_bindings.find_by_module_name(module_name)
        next unless binding

        binding.build_flags.each do |flag|
          flags << flag unless flags.include?(flag)
        end
      end
    rescue RawBindings::Error => e
      raise BuildError, e.message
    end

    def compile(c_path, compiler_flags, link_flags)
      command = [@cc, "-std=c11", *compiler_flags, c_path, "-o", @output_path, *link_flags]
      stdout, stderr, status = Open3.capture3(*command)
      return if status.success?

      details = [stdout, stderr].reject(&:empty?).join
      raise BuildError, details.empty? ? "C compiler failed" : "C compiler failed:\n#{details}"
    rescue Errno::ENOENT
      raise BuildError, "C compiler not found: #{@cc}"
    end

    def compiler_available?(compiler)
      return File.file?(compiler) && File.executable?(compiler) if compiler.include?(File::SEPARATOR)

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
        candidate = File.join(entry, compiler)
        File.file?(candidate) && File.executable?(candidate)
      end
    end
  end
end

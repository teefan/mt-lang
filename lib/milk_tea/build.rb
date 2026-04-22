# frozen_string_literal: true

require "fileutils"
require "open3"
require "tempfile"

module MilkTea
  class BuildError < StandardError; end

  class Build
    Result = Data.define(:output_path, :c_path, :compiler, :link_flags)

    def self.build(path, output_path: nil, cc: ENV.fetch("CC", "cc"), keep_c_path: nil)
      new(path, output_path:, cc:, keep_c_path:).build
    end

    def initialize(path, output_path:, cc:, keep_c_path:)
      @source_path = File.expand_path(path)
      @output_path = File.expand_path(output_path || default_output_path(@source_path))
      @cc = cc
      @keep_c_path = keep_c_path ? File.expand_path(keep_c_path) : nil
    end

    def build
      program = ModuleLoader.check_program(@source_path)
      generated_c = Codegen.generate_c(program)
      link_flags = collect_link_flags(program)

      FileUtils.mkdir_p(File.dirname(@output_path))

      if @keep_c_path
        write_c_file(@keep_c_path, generated_c)
        compile(@keep_c_path, link_flags)
        return Result.new(output_path: @output_path, c_path: @keep_c_path, compiler: @cc, link_flags:)
      end

      Tempfile.create(["milk-tea-build", ".c"]) do |file|
        file.write(generated_c)
        file.flush
        file.close

        compile(file.path, link_flags)
      end

      Result.new(output_path: @output_path, c_path: nil, compiler: @cc, link_flags:)
    end

    private

    def default_output_path(source_path)
      source_path.sub(/\.mt\z/, "")
    end

    def write_c_file(path, source)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, source)
    end

    def collect_link_flags(program)
      program.analyses_by_module_name.keys.sort.each_with_object([]) do |module_name, flags|
        analysis = program.analyses_by_module_name.fetch(module_name)
        next unless analysis.module_kind == :extern_module

        analysis.directives.grep(AST::LinkDirective).each do |directive|
          flag = "-l#{directive.value}"
          flags << flag unless flags.include?(flag)
        end
      end
    end

    def compile(c_path, link_flags)
      command = [@cc, "-std=c11", c_path, "-o", @output_path, *link_flags]
      stdout, stderr, status = Open3.capture3(*command)
      return if status.success?

      details = [stdout, stderr].reject(&:empty?).join
      raise BuildError, details.empty? ? "C compiler failed" : "C compiler failed:\n#{details}"
    rescue Errno::ENOENT
      raise BuildError, "C compiler not found: #{@cc}"
    end
  end
end

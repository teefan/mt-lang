# frozen_string_literal: true
require_relative "../../test_helper"

module CodegenTestHelpers

  def generate_c_from_source(source)
    Dir.mktmpdir("milk-tea-codegen") do |dir|
      root_path = File.join(dir, source_relative_path(source))
      FileUtils.mkdir_p(File.dirname(root_path))
      File.write(root_path, source)

      program = MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root]).check_program(root_path)
      MilkTea::CBackend.generate_c(MilkTea::Lowering.lower(program))
    end
  end

  def generate_c_from_program_source(source, imported_sources = {})
    Dir.mktmpdir("milk-tea-codegen") do |dir|
      root_path = File.join(dir, source_relative_path(source, default: File.join("demo", "main.mt")))
      FileUtils.mkdir_p(File.dirname(root_path))
      File.write(root_path, source)

      imported_sources.each do |relative_path, imported_source|
        path = File.join(dir, relative_path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, imported_source)
      end

      program = MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root]).check_program(root_path)
      MilkTea::CBackend.generate_c(MilkTea::Lowering.lower(program))
    end
  end

  def run_program_from_source(source, compiler:, imported_sources: {})
    Dir.mktmpdir("milk-tea-codegen-run") do |dir|
      root_path = File.join(dir, source_relative_path(source, default: File.join("demo", "main.mt")))
      FileUtils.mkdir_p(File.dirname(root_path))
      File.write(root_path, source)

      imported_sources.each do |relative_path, imported_source|
        path = File.join(dir, relative_path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, imported_source)
      end

      MilkTea::Run.run(root_path, cc: compiler)
    end
  end

  def compiler_available?(compiler)
    return File.executable?(compiler) if compiler.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, compiler)
      File.file?(candidate) && File.executable?(candidate)
    end
  end
end

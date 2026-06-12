# frozen_string_literal: true
require_relative "../../test_helper"

module SemaTestHelpers

  def check_source(source)
    Dir.mktmpdir("milk-tea-sema") do |dir|
      root_path = File.join(dir, source_relative_path(source))
      FileUtils.mkdir_p(File.dirname(root_path))
      File.write(root_path, source)

      MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root]).check_file(root_path)
    end
  end

  def check_program_source(source, imported_sources = {})
    Dir.mktmpdir("milk-tea-sema") do |dir|
      root_path = File.join(dir, source_relative_path(source))
      FileUtils.mkdir_p(File.dirname(root_path))
      File.write(root_path, source)

      imported_sources.each do |relative_path, imported_source|
        path = File.join(dir, relative_path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, imported_source)
      end

      MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root]).check_program(root_path)
    end
  end
end

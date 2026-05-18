# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "../test_helper"

class MilkTeaLoweringTest < Minitest::Test
  def test_lowers_imported_struct_methods_and_associated_functions
    program = check_program_source(
      <<~MT,
        # module demo.main

        import demo.lib as lib

        function main() -> int:
            var value = lib.make()
            defer value.release()

            var created = lib.Buffer.create()
            defer created.release()
            return 0
      MT
      {
        "demo/lib.mt" => <<~MT,
          # module demo.lib

          public struct Buffer:
              value: int

          public function make() -> Buffer:
              return Buffer.create()

          extending Buffer:
              public static function create() -> Buffer:
                  return Buffer(value = 0)

              public mutable function release() -> void:
                  this.value = 0
        MT
      },
    )

    ir_program = MilkTea::Lowering.lower(program)

    assert_equal "demo.main", ir_program.module_name
    assert_includes ir_program.functions.map(&:name), "main"
  end

  private

  def source_relative_path(source, default: File.join("demo", "main.mt"))
    source.each_line do |line|
      next if line.strip.empty?

      match = line.match(/^\s*#\s*module\s+([A-Za-z0-9_.]+)\s*$/)
      return File.join(*match[1].split(".")) + ".mt" if match

      break
    end

    default
  end

  def check_program_source(source, imported_sources = {})
    Dir.mktmpdir("milk-tea-lowering") do |dir|
      root_path = File.join(dir, source_relative_path(source))
      FileUtils.mkdir_p(File.dirname(root_path))
      File.write(root_path, source)

      imported_sources.each do |relative_path, imported_source|
        path = File.join(dir, relative_path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, imported_source)
      end

      return MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root]).check_program(root_path)
    end
  end
end

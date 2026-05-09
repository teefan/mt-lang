# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "../test_helper"

class MilkTeaModuleLoaderTest < Minitest::Test
  def test_load_file_parses_language_standard_file
    ast = MilkTea::ModuleLoader.load_file(language_standard_path)

    assert_equal "examples.language_standard", ast.module_name.to_s
    assert_equal 10, ast.declarations.length
  end

  def test_load_file_reports_missing_files
    error = assert_raises(MilkTea::ModuleLoadError) do
      MilkTea::ModuleLoader.load_file(File.expand_path("missing.mt", __dir__))
    end

    assert_match(/source file not found/, error.message)
  end

  def test_check_file_runs_semantic_analysis
    result = MilkTea::ModuleLoader.check_file(language_standard_path)

    assert_equal "examples.language_standard", result.module_name
    assert_equal %w[main mode_label pair_label printf release_allocated_values], result.functions.keys.sort
  end

  def test_check_program_exposes_root_and_imported_modules
    program = MilkTea::ModuleLoader.check_program(language_standard_path)
    loaded_modules = program.analyses_by_module_name.keys

    assert_equal language_standard_path, program.root_path
    assert_equal "examples.language_standard", program.root_analysis.module_name
    assert_includes loaded_modules, "examples.language_standard"
    assert_includes loaded_modules, "examples.language_standard.foreign_bridge"
    assert_includes loaded_modules, "examples.language_standard.external_runtime"
    assert_includes loaded_modules, "std.fmt"
    assert_equal :module, program.analyses_by_module_name.fetch("std.fmt").module_kind
    assert_equal :extern_module, program.analyses_by_module_name.fetch("examples.language_standard.external_runtime").module_kind
  end

  def test_check_file_reports_missing_imported_modules
    source_path = File.expand_path("missing-import.mt", __dir__)
    File.write(source_path, <<~MT)
      module demo.bad

      import std.c.missing as missing

      function main() -> int:
          return 0
    MT

    error = assert_raises(MilkTea::ModuleLoadError) do
      MilkTea::ModuleLoader.check_file(source_path)
    end

    assert_match(/module not found/, error.message)
  ensure
    File.delete(source_path) if source_path && File.exist?(source_path)
  end

  def test_check_program_exports_only_public_declarations_from_imports
    Dir.mktmpdir("milk-tea-module-loader-visibility") do |dir|
      root_path = File.join(dir, "demo", "main.mt")
      lib_path = File.join(dir, "demo", "lib.mt")

      FileUtils.mkdir_p(File.dirname(root_path))
      File.write(root_path, <<~MT)
        module demo.main

        import demo.lib as lib

        function main() -> int:
            let counter = lib.Counter(value = lib.answer)
            return counter.read()
      MT

      File.write(lib_path, <<~MT)
        module demo.lib

        public const answer: int = 7
        const hidden: int = 9

        public struct Counter:
            value: int

        struct Hidden:
            value: int

        methods Counter:
            public function read() -> int:
                return this.value

            function bump() -> int:
                return this.value + 1

        public function make_counter() -> Counter:
            return Counter(value = answer)

        function hidden_fn() -> int:
            return hidden
      MT

      program = MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root]).check_program(root_path)
      imported = program.root_analysis.imports.fetch("lib")
      counter_type = imported.types.fetch("Counter")

      assert_equal %w[Counter], imported.types.keys.sort
      assert_equal %w[answer], imported.values.keys.sort
      assert_equal %w[make_counter], imported.functions.keys.sort
      assert_equal %w[read], imported.methods.fetch(counter_type).keys.sort
    end
  end

  def test_check_program_resolves_extern_module_imported_types
    Dir.mktmpdir("milk-tea-module-loader-extern-imports") do |dir|
      dep_path = File.join(dir, "std", "c", "dep.mt")
      helper_path = File.join(dir, "std", "c", "helper.mt")

      FileUtils.mkdir_p(File.dirname(dep_path))

      File.write(dep_path, <<~MT)
        external module std.c.dep:
            struct Vec:
                x: float
                y: float
      MT

      File.write(helper_path, <<~MT)
        external module std.c.helper:
            import std.c.dep as dep

            include "helper.h"

            struct Holder:
                value: dep.Vec

            external function wrap(value: dep.Vec) -> Holder
      MT

      program = MilkTea::ModuleLoader.new(module_roots: [dir]).check_program(helper_path)

      assert_equal %w[std.c.dep std.c.helper], program.analyses_by_module_name.keys.sort
      assert_equal :extern_module, program.root_analysis.module_kind
      assert_equal true, program.root_analysis.types.key?("Holder")
      assert_equal true, program.root_analysis.functions.key?("wrap")
      assert_equal true, program.root_analysis.imports.key?("dep")
    end
  end

  def test_check_program_exports_public_methods_on_imported_public_types
    Dir.mktmpdir("milk-tea-module-loader-imported-methods") do |dir|
      root_path = File.join(dir, "demo", "main.mt")
      ext_path = File.join(dir, "demo", "ext.mt")
      dep_path = File.join(dir, "demo", "dep.mt")

      FileUtils.mkdir_p(File.dirname(root_path))

      File.write(root_path, <<~MT)
        module demo.main

        import demo.ext as ext

        function main() -> int:
            let counter = ext.make_counter()
            return counter.read()
      MT

      File.write(dep_path, <<~MT)
        module demo.dep

        public struct Counter:
            value: int
      MT

      File.write(ext_path, <<~MT)
        module demo.ext

        import demo.dep as dep

        methods dep.Counter:
            public function read() -> int:
                return this.value

        public function make_counter() -> dep.Counter:
            return dep.Counter(value = 7)
      MT

      program = MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root]).check_program(root_path)
      imported = program.root_analysis.imports.fetch("ext")
      counter_type = program.analyses_by_module_name.fetch("demo.dep").types.fetch("Counter")

      assert_equal %w[make_counter], imported.functions.keys.sort
      assert_equal %w[read], imported.methods.fetch(counter_type).keys.sort
    end
  end

  def test_check_program_exports_public_methods_on_imported_generic_receivers
    Dir.mktmpdir("milk-tea-module-loader-imported-generic-methods") do |dir|
      root_path = File.join(dir, "demo", "main.mt")
      ext_path = File.join(dir, "demo", "ext.mt")
      dep_path = File.join(dir, "demo", "dep.mt")

      FileUtils.mkdir_p(File.dirname(root_path))

      File.write(root_path, <<~MT)
        module demo.main

        import demo.dep as dep
        import demo.ext as ext

        function main(handle: ptr[dep.Handle]) -> int:
            return handle.read_code()
      MT

      File.write(dep_path, <<~MT)
        module demo.dep

        public opaque Handle
      MT

      File.write(ext_path, <<~MT)
        module demo.ext

        import demo.dep as dep

        methods ptr[dep.Handle]:
            public function read_code() -> int:
                return 7
      MT

      program = MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root]).check_program(root_path)
      imported = program.root_analysis.imports.fetch("ext")
      handle_type = program.analyses_by_module_name.fetch("demo.dep").types.fetch("Handle")
      receiver_type = MilkTea::Types::GenericInstance.new("ptr", [handle_type])

      assert_equal %w[read_code], imported.methods.fetch(receiver_type).keys.sort
    end
  end

  def test_check_program_exports_public_methods_on_imported_generic_receiver_templates
    Dir.mktmpdir("milk-tea-module-loader-imported-generic-template-methods") do |dir|
      root_path = File.join(dir, "demo", "main.mt")
      ext_path = File.join(dir, "demo", "ext.mt")

      FileUtils.mkdir_p(File.dirname(root_path))

      File.write(root_path, <<~MT)
        module demo.main

        import demo.ext as ext

        function main(value: const_ptr[int]) -> int:
            return value.read_value()
      MT

      File.write(ext_path, <<~MT)
        module demo.ext

        methods const_ptr[T]:
            public function read_value() -> T:
                return unsafe: read(this)
      MT

      program = MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root]).check_program(root_path)
      imported = program.root_analysis.imports.fetch("ext")
      receiver_type = MilkTea::Types::GenericInstance.new("const_ptr", [MilkTea::Types::TypeVar.new("__receiver_arg0")])

      assert_equal %w[read_value], imported.methods.fetch(receiver_type).keys.sort
    end
  end

  def test_check_program_exports_public_methods_on_imported_nullable_generic_receiver_templates
    Dir.mktmpdir("milk-tea-module-loader-imported-nullable-generic-template-methods") do |dir|
      root_path = File.join(dir, "demo", "main.mt")
      ext_path = File.join(dir, "demo", "ext.mt")

      FileUtils.mkdir_p(File.dirname(root_path))

      File.write(root_path, <<~MT)
        module demo.main

        import demo.ext as ext

        function main(value: const_ptr[int]?) -> const_ptr[int]:
            return value.require_value("missing")
      MT

      File.write(ext_path, <<~MT)
        module demo.ext

        methods const_ptr[T]?:
            public function require_value(message: str) -> const_ptr[T]:
                if this == null:
                    fatal(message)

                return unsafe: const_ptr[T]<-this
      MT

      program = MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root]).check_program(root_path)
      imported = program.root_analysis.imports.fetch("ext")
      receiver_type = MilkTea::Types::Nullable.new(MilkTea::Types::GenericInstance.new("const_ptr", [MilkTea::Types::TypeVar.new("__receiver_arg0")]))

      assert_equal %w[require_value], imported.methods.fetch(receiver_type).keys.sort
    end
  end

  private

  def language_standard_path
    File.expand_path("../../examples/language_standard.mt", __dir__)
  end
end

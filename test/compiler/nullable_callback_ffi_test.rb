# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require_relative "../test_helper"

class MilkTeaNullableCallbackFFITest < Minitest::Test
  def test_type_checks_plain_null_for_nullable_external_callback_argument
    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.functions.key?("main")
  end

  def test_generate_c_for_foreign_defs_with_nullable_callback_alias
    generated = generate_c_from_program_source(root_source, imported_sources)

    assert_match(/Register\(NULL\);/, generated)
    assert_match(/Register\(demo_main_on_tick\);/, generated)
  end

  def test_generate_c_for_nullable_callback_locals_and_struct_fields
    source = <<~MT
      # module demo.callbacks

      type Callback = fn(value: int) -> void
      external function register(callback: Callback?) -> void

      struct Entry:
          callback: Callback?

      function on_tick(value: int) -> void:
          return

      function main() -> int:
          let local_callback: Callback? = null
          let null_entry = Entry(callback = null)
          let live_entry = Entry(callback = on_tick)
          register(local_callback)
          register(null_entry.callback)
          register(live_entry.callback)
          return 0
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/struct demo_callbacks_Entry \{\s+void \(\*callback\)\(int32_t value\);\s+\};/m, generated)
    assert_match(/void \(\*local_callback\)\(int32_t value\) = NULL;/, generated)
    assert_match(/\.callback = NULL/, generated)
    assert_match(/\.callback = demo_callbacks_on_tick/, generated)
    assert_match(/register\(local_callback\);/, generated)
    assert_match(/register\(null_entry\.callback\);/, generated)
    assert_match(/register\(live_entry\.callback\);/, generated)
  end

  def test_non_pointer_nullable_rejected_at_ffi_boundary
    source = <<~MT
      # module demo.ffireject

      external function take_opt(x: int?) -> void

      function main() -> int:
          return 0
    MT

    error = assert_raises(MilkTea::SemanticError) { check_program_source(source) }
    assert_match(/nullable at an FFI boundary/, error.message)
  end

  def test_pointer_nullable_allowed_at_ffi_boundary
    source = <<~MT
      # module demo.ffiok

      external function take_ptr(x: ptr[int]?) -> void

      function main() -> int:
          return 0
    MT

    program = check_program_source(source)
    assert_equal true, program.root_analysis.functions.key?("main")
  end

  private

  def root_source
    <<~MT
      import std.sample as sample

      function on_tick(value: int) -> void:
          return

      function main() -> int:
          sample.register(null)
          sample.register(on_tick)
          return 0
    MT
  end

  def imported_sources
    {
      "std/c/sample.mt" => <<~MT,
        external

        type Callback = fn(arg0: int) -> void

        external function Register(cb: Callback?) -> void
      MT
      "std/sample.mt" => <<~MT,
        import std.c.sample as c

        public type Callback = c.Callback

        public foreign function register(cb: Callback?) -> void = c.Register
      MT
    }
  end

  def check_program_source(source, imported_sources = {})
    Dir.mktmpdir("milk-tea-nullable-callback-sema") do |dir|
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

  def generate_c_from_program_source(source, imported_sources = {})
    Dir.mktmpdir("milk-tea-nullable-callback-codegen") do |dir|
      root_path = File.join(dir, source_relative_path(source))
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
end

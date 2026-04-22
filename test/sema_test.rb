# frozen_string_literal: true

require_relative "test_helper"

class MilkTeaSemaTest < Minitest::Test
  def test_demo_file_type_checks
    result = MilkTea::ModuleLoader.check_file(demo_path)

    assert_equal "demo.bouncing_ball", result.module_name
    assert_equal %w[main], result.functions.keys.sort
    assert_equal true, result.imports.key?("rl")
  end

  def test_rejects_non_bool_conditions
    source = <<~MT
      module demo.bad

      def main() -> i32:
          if 1:
              return 0
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/if condition must be bool/, error.message)
  end

  def test_rejects_wrong_return_type
    source = <<~MT
      module demo.bad

      def main() -> i32:
          return true
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/return type mismatch/, error.message)
  end

  def test_rejects_unknown_fields_in_struct_literals
    source = <<~MT
      module demo.bad

      struct Ball:
          radius: f32

      def main() -> i32:
          var ball = Ball(size = 20.0)
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/unknown field Ball.size/, error.message)
  end

  def test_rejects_duplicate_top_level_values
    source = <<~MT
      module demo.bad

      const width: i32 = 1
      const width: i32 = 2
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/duplicate value width/, error.message)
  end

  def test_type_checks_ffi_declaration_surface
    source = <<~MT
      module demo.ffi

      enum State: u8
          idle = 0
          moving = 1

      flags WindowFlags: u32
          visible = 1 << 0
          fullscreen = 1 << 1

      union Number:
          i: i32
          f: f32

      opaque SDL_Window
      type Seconds = f32
      extern def get_ticks() -> Seconds
      extern def open_window(title: cstr) -> SDL_Window?

      def main() -> i32:
          let state: State = State.idle
          let window_flags: WindowFlags = WindowFlags.visible
          let ticks: Seconds = get_ticks()
          let window: SDL_Window? = open_window(c"demo")
          return 0
    MT

    result = check_source(source)

    assert_equal :module, result.module_kind
    assert_equal "demo.ffi", result.module_name
    assert_equal true, result.types.key?("State")
    assert_equal true, result.types.key?("WindowFlags")
    assert_equal true, result.types.key?("Number")
    assert_equal true, result.types.key?("SDL_Window")
    assert_equal true, result.functions.key?("get_ticks")
    assert_equal true, result.functions.key?("open_window")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_function_type_aliases_and_callback_arguments
    source = <<~MT
      module demo.callbacks

      type LogCallback = fn(level: i32, message: cstr) -> void
      extern def set_callback(callback: LogCallback) -> void

      def on_log(level: i32, message: cstr) -> void:
          return

      def main() -> i32:
          set_callback(on_log)
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("LogCallback")
    assert_equal true, result.functions.key?("set_callback")
    assert_equal true, result.functions.key?("on_log")
  end

  def test_type_checks_span_construction_and_field_access
    source = <<~MT
      module demo.spans

      def read(items: span[i32]) -> i32:
          if items.len == 0:
              return 0
          unsafe:
              return *items.data

      def main() -> i32:
          var value = 7
          let items = span[i32](data = &value, len = 1)
          return read(items)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("read")
    assert_equal true, result.functions.key?("main")
    assert_equal "span[i32]", result.functions.fetch("read").type.params.first.type.to_s
  end

  def test_type_checks_generic_struct_instantiation_and_embedding
    source = <<~MT
      module demo.generics

      struct Slice[T]:
          data: ptr[T]
          len: usize

      struct Holder:
          items: Slice[i32]

      def read(items: Slice[i32]) -> i32:
          if items.len == 0:
              return 0
          unsafe:
              return *items.data

      def main() -> i32:
          var value = 7
          let holder = Holder(items = Slice[i32](data = &value, len = 1))
          return read(holder.items)
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Slice")
    assert_equal true, result.types.key?("Holder")
    assert_equal "demo.generics.Slice[i32]", result.functions.fetch("read").type.params.first.type.to_s
  end

  def test_type_checks_generic_functions_with_inferred_type_arguments
    source = <<~MT
      module demo.generic_functions

      struct Slice[T]:
          data: ptr[T]
          len: usize

      def head[T](items: Slice[T]) -> ptr[T]:
          return items.data

      def min[T](a: T, b: T) -> T:
          if a < b:
              return a
          return b

      def main() -> i32:
          var value = 7
          let items = Slice[i32](data = &value, len = 1)
          let smallest = min(9, 4)
          unsafe:
              return *head(items) + smallest
    MT

    result = check_source(source)

    assert_equal ["T"], result.functions.fetch("head").type_params
    assert_equal ["T"], result.functions.fetch("min").type_params
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_result_construction_from_expected_context
    source = <<~MT
      module demo.result

      enum LoadError: u8
          file_not_found = 1
          invalid_format = 2

      def load(available: bool) -> Result[i32, LoadError]:
          if available:
              return ok(7)
          return err(LoadError.invalid_format)

      def main() -> i32:
          let cached: Result[i32, LoadError] = ok(5)
          let missing = load(false)
          if cached.is_ok and missing.error == LoadError.invalid_format:
              return cached.value
          return 0
    MT

    result = check_source(source)

    assert_equal "Result[i32, demo.result.LoadError]", result.functions.fetch("load").type.return_type.to_s
    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_mismatched_callback_arguments
    source = <<~MT
      module demo.callbacks

      type LogCallback = fn(level: i32, message: cstr) -> void
      extern def set_callback(callback: LogCallback) -> void

      def wrong(level: i32) -> void:
          return

      def main() -> i32:
          set_callback(wrong)
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/argument callback to set_callback expects/, error.message)
  end

  def test_type_checks_keyword_field_names
    source = <<~MT
      module demo.keywords

      struct Event:
          type: i32

      def main(event: Event) -> i32:
          let copy = Event(type = event.type)
          return copy.type
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Event")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_unsafe_pointer_cast_and_arithmetic
    source = <<~MT
      module demo.unsafe_surface

      extern def allocate(size: usize) -> ptr[void]

      def main() -> i32:
          let memory = allocate(16)
          unsafe:
              let advanced = cast[ptr[byte]](memory) + 4
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_address_of_dereference_and_deref_assignment
    source = <<~MT
      module demo.pointer_surface

      struct Counter:
          value: i32

      def main() -> i32:
          var counter = Counter(value = 3)
          let counter_ptr = &counter
          (*counter_ptr).value = 7
          return counter.value
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Counter")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_array_construction_for_locals_consts_and_struct_fields
    source = <<~MT
      module demo.arrays

      struct Palette:
          colors: array[u32, 4]

      const DEFAULT: array[u32, 4] = array[u32, 4](11, 22, 33, 44)

      def main() -> i32:
          let palette = array[u32, 4](1, 2, 3, 4)
          let holder = Palette(colors = array[u32, 4](5, 6, 7, 8))
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Palette")
    assert_equal true, result.values.key?("DEFAULT")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_array_assignment_and_by_value_parameters
    source = <<~MT
      module demo.arrays

      def mutate(mut values: array[i32, 4]) -> i32:
          unsafe:
              values[1] = 9
              return values[1]

      def main() -> i32:
          var lhs = array[i32, 4](1, 2, 3, 4)
          let rhs = array[i32, 4](5, 6, 7, 8)
          lhs = rhs
          return mutate(lhs)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("mutate")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_local_array_return_values
    source = <<~MT
      module demo.array_returns

      def make() -> array[i32, 4]:
          return array[i32, 4](1, 2, 3, 4)

      def clone(values: array[i32, 4]) -> array[i32, 4]:
          return values

      def read(values: array[i32, 4]) -> i32:
          unsafe:
              return values[1]

      def main() -> i32:
          return read(clone(make()))
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("make")
    assert_equal true, result.functions.key?("clone")
    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_extern_array_params_and_returns
    param_source = <<~MT
      module demo.bad_params

      extern def take(values: array[i32, 4]) -> i32
    MT

    param_error = assert_raises(MilkTea::SemaError) do
      check_source(param_source)
    end

    assert_match(/extern function take cannot take array parameters/, param_error.message)

    return_source = <<~MT
      module demo.bad_return

      extern def make() -> array[i32, 4]
    MT

    return_error = assert_raises(MilkTea::SemaError) do
      check_source(return_source)
    end

    assert_match(/extern function make cannot return arrays/, return_error.message)
  end

  def test_type_checks_unsafe_array_indexing_and_element_assignment
    source = <<~MT
      module demo.arrays

      struct Palette:
          colors: array[u32, 4]

      def main() -> i32:
          var palette = array[u32, 4](1, 2, 3, 4)
          var holder = Palette(colors = array[u32, 4](5, 6, 7, 8))
          unsafe:
              palette[1] = 9
              holder.colors[2] = 10
              let first = palette[0]
              let third = holder.colors[2]
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_indexing_outside_unsafe
    source = <<~MT
      module demo.bad

      def main() -> i32:
          let palette = array[u32, 4](1, 2, 3, 4)
          let value = palette[0]
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/indexing requires unsafe/, error.message)
  end

  def test_rejects_dereference_of_non_pointer
    source = <<~MT
      module demo.bad

      def main() -> i32:
          let value = *1
          return value
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/operator \* requires a pointer operand/, error.message)
  end

  def test_rejects_pointer_cast_outside_unsafe
    source = <<~MT
      module demo.bad

      extern def allocate(size: usize) -> ptr[void]

      def main() -> i32:
          let memory = allocate(16)
          let bytes = cast[ptr[byte]](memory)
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/pointer cast requires unsafe/, error.message)
  end

  def test_rejects_pointer_arithmetic_outside_unsafe
    source = <<~MT
      module demo.bad

      extern def allocate(size: usize) -> ptr[void]

      def main() -> i32:
          let memory = allocate(16)
          let advanced = cast[ptr[byte]](memory) + 4
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/pointer cast requires unsafe/, error.message)
  end

  def test_rejects_non_integer_flags_backing_types
    source = <<~MT
      module demo.bad

      flags BadFlags: f32
          visible = 1
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/backing type must be an integer primitive/, error.message)
  end

  def test_rejects_unknown_enum_members
    source = <<~MT
      module demo.bad

      enum State: u8
          idle = 0

      def main() -> i32:
          let state: State = State.moving
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/unknown member .*State\.moving/, error.message)
  end

  private

  def demo_path
    File.expand_path("../examples/milk-tea-demo.mt", __dir__)
  end

  def check_source(source)
    MilkTea::Sema.check(MilkTea::Parser.parse(source))
  end
end

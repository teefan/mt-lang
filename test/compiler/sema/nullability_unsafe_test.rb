# frozen_string_literal: true

require_relative "helpers"

class NullabilityUnsafeTest < Minitest::Test
  include SemaTestHelpers

  def test_type_checks_nullable_pointer_guard_clause_flow_narrowing
    source = <<~MT
      # module demo.null_flow

      function read(handle: ptr[int]?) -> int:
          if handle == null:
              return 0
          unsafe:
              return read(handle)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("read")
  end

  def test_type_checks_short_circuit_nullable_flow_narrowing
    source = <<~MT
      # module demo.null_flow

      function read(handle: ptr[int]?) -> int:
          unsafe:
              if handle != null and read(handle) > 0:
                  return read(handle)
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("read")
  end

  def test_type_checks_assignment_to_nullable_local_in_null_branch
    source = <<~MT
      # module demo.null_flow

      function open_handle() -> ptr[int]?:
          return null[ptr[int]]

      function main() -> int:
          var handle: ptr[int]? = null[ptr[int]]
          if handle == null:
              handle = open_handle()
          return 0
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_assignment_to_nullable_local_in_non_null_branch
    source = <<~MT
      # module demo.null_flow

      function main(input: ptr[int]?) -> ptr[int]?:
          var handle = input
          if handle != null:
              handle = null[ptr[int]]
          return handle
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_let_else_nullable_flow_narrowing
    source = <<~MT
      # module demo.null_flow

      function read_handle(handle: ptr[int]?) -> int:
          let value = handle else:
              return 0
          unsafe:
              return read(value)
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("read_handle")
  end

  def test_type_checks_nullable_local_guard_clause_flow_narrowing
    source = <<~MT
      # module demo.null_flow

      function maybe_handle(handle: ptr[int]?) -> ptr[int]?:
          return handle

      function read_handle(handle: ptr[int]?) -> int:
          let value = maybe_handle(handle)
          if value == null:
              return 0
          unsafe:
              return read(value)
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("read_handle")
  end

  def test_type_checks_nullable_vec_get_guard_clause_flow_narrowing
    source = <<~MT
      # module demo.null_flow

      import std.vec as vec

      function read_values() -> int:
          var values = vec.Vec[int].create()
          defer values.release()
          values.push(7)

          let value_ptr = values.get(0)
          if value_ptr == null:
              return 0
          unsafe:
              return read(value_ptr)
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("read_values")
  end

  def test_type_checks_nullable_vec_get_fatal_guard_clause_flow_narrowing
    source = <<~MT
      # module demo.null_flow

      import std.vec as vec

      function read_values() -> int:
          var values = vec.Vec[int].create()
          defer values.release()
          values.push(7)

          let value_ptr = values.get(0)
          if value_ptr == null:
              fatal("missing value")
          unsafe:
              return read(value_ptr)
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("read_values")
  end

  def test_rejects_let_else_error_binding_for_nullable_initializer
    source = <<~MT
      # module demo.null_flow

      function read_handle(handle: ptr[int]?) -> int:
          let value = handle else as error:
              return 0
          unsafe:
              return read(value)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/let-else error binding for value requires Result\[T, E\]/, error.message)
  end

  def test_rejects_for_loop_iterator_next_without_nullable_pointer_item
    source = <<~MT
      # module demo.iterator_for

      struct Numbers:
          stop: int

      struct NumbersIter:
          index: int

      extending Numbers:
          public function iter() -> NumbersIter:
              return NumbersIter(index = this.stop)

      extending NumbersIter:
          public editable function next() -> ptr[int]:
              unsafe:
                  return ptr_of(this.index)

      function main() -> int:
          for value in Numbers(stop = 1):
              unsafe:
                  return read(value)
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/next must return bool or a nullable pointer-like item/, error.message)
  end

  def test_type_checks_foreign_defs_with_nullable_pointer_inout_slot
    root_source = <<~MT
      # module demo.main

      import std.sample as sample

      function main() -> void:
          var state: ptr[char]? = null
          sample.next_token(null[ptr[char]], c",", state)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function NextToken(text: ptr[char]?, delim: cstr, state: ptr[ptr[char]]) -> ptr[char]?
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function next_token(text: ptr[char]?, delim: cstr, inout state: ptr[char]?) -> ptr[char]? = c.NextToken(text, delim, state)
      MT
    }

    program = check_program_source(root_source, imported_sources)

    assert_equal true, program.root_analysis.imports.key?("sample")
    assert_equal true, program.root_analysis.functions.key?("main")
  end

  def test_type_checks_owned_foreign_release_calls_and_refines_binding_to_null
    root_source = <<~MT
      # module demo.main

      import std.window as win

      function main() -> int:
          let window = win.create()
          if window != null:
              win.destroy(window)
              if window == null:
                  return 1
          return 0
    MT

    imported_sources = {
      "std/c/window.mt" => <<~MT,
        # module std.c.window
        external
        include "window.h"

        external function CreateWindow() -> ptr[void]?
        external function DestroyWindow(window: ptr[void]?) -> void
      MT
      "std/window.mt" => <<~MT,
        # module std.window

        import std.c.window as c

        public opaque Window

        public foreign function create() -> Window? = c.CreateWindow
        public foreign function destroy(consuming window: Window) -> void = c.DestroyWindow
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("win")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_plain_null_for_nullable_external_pointer_argument
    source = <<~MT
      # module demo.ok

      external function load_font_ex(codepoints: ptr[int]?) -> void

      function main() -> void:
          load_font_ex(null)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_typed_null_for_non_nullable_external_aggregate_pointer_field
    program = check_program_source(
      <<~MT,
        # module demo.external_aggregate_typed_null

        import std.c.demo as demo

        function main() -> int:
            let buffer = demo.Buffer(content = null[ptr[char]], label = null[ptr[char]], length = 0)
            return buffer.length
      MT
      {
        "std/c/demo.mt" => <<~MT,
          # module std.c.demo
          external
          struct Buffer:
              content: ptr[char]
              label: cstr
              length: int
        MT
      },
    )

    assert_equal true, program.analyses_by_module_name.key?("demo.external_aggregate_typed_null")
  end

  def test_type_checks_external_ptr_to_void_argument_without_unsafe_cast
    source = <<~MT
      # module demo.ok

      external function update_texture(pixels: ptr[void]) -> void

      function main() -> void:
          var pixels = zero[array[int, 4]]
          let data = ptr_of(pixels[0])
          update_texture(data)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_owned_foreign_release_on_non_nullable_binding
    root_source = <<~MT
      # module demo.main

      import std.window as win

      function main() -> void:
          let window = win.require()
          win.destroy(window)
    MT

    imported_sources = {
      "std/c/window.mt" => <<~MT,
        # module std.c.window
        external
        include "window.h"

        external function RequireWindow() -> ptr[void]
        external function DestroyWindow(window: ptr[void]?) -> void
      MT
      "std/window.mt" => <<~MT,
        # module std.window

        import std.c.window as c

        public opaque Window

        public foreign function require() -> Window = c.RequireWindow
        public foreign function destroy(consuming window: Window) -> void = c.DestroyWindow
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(root_source, imported_sources)
    end

    assert_match(/consuming argument window to destroy must be a bare nullable local or parameter binding/, error.message)
  end

  def test_type_checks_owned_foreign_release_on_nullable_binding
    root_source = <<~MT
      # module demo.main

      import std.window as win

      function main() -> void:
          let window = win.create()
          if window != null:
              win.destroy(window)
    MT

    imported_sources = {
      "std/c/window.mt" => <<~MT,
        # module std.c.window
        external
        include "window.h"

        external function CreateWindow() -> ptr[void]?
        external function DestroyWindow(window: ptr[void]?) -> void
      MT
      "std/window.mt" => <<~MT,
        # module std.window

        import std.c.window as c

        public opaque Window

        public foreign function create() -> Window? = c.CreateWindow
        public foreign function destroy(consuming window: Window) -> void = c.DestroyWindow
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_direct_str_construction_outside_unsafe
    source = <<~MT
      # module demo.bad_str_constructor

      function main(data: ptr[char], len: ptr_uint) -> str:
          return str(data = data, len = len)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/str construction requires unsafe/, error.message)
  end

  def test_type_checks_unsafe_reinterpret_calls
    source = <<~MT
      # module demo.bits

      function main() -> uint:
          let value: float = 1.0
          unsafe:
              let bits = reinterpret[uint](value)
              return bits
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_unsafe_expression_reinterpret_initializer
    source = <<~MT
      # module demo.bits

      function main() -> uint:
          let value: float = 1.0
          let bits = unsafe: reinterpret[uint](value)
          return bits
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_reinterpret_outside_unsafe
    source = <<~MT
      # module demo.bits

      function main() -> uint:
          let value: float = 1.0
          return reinterpret[uint](value)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/reinterpret requires unsafe/, error.message)
  end

  def test_type_checks_methods_on_pointer_receivers_without_unsafe
    source = <<~MT
      # module demo.pointer_methods

      opaque Handle

      extending ptr[Handle]:
          public function ready() -> bool:
              return true

      function main(handle: ptr[Handle]) -> bool:
          return handle.ready()
    MT

    result = check_program_source(source).root_analysis

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_methods_on_nullable_generic_pointer_receivers
    source = <<~MT
      # module demo.nullable_generic_pointer_methods

      struct Point:
          x: int

      extending const_ptr[T]?:
          public function require_value(message: str) -> const_ptr[T]:
              if this == null:
                  fatal(message)

              return unsafe: const_ptr[T]<-this

      function main(point: const_ptr[Point]?) -> const_ptr[Point]:
          return point.require_value("missing")
    MT

    result = check_program_source(source).root_analysis

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_unsafe_pointer_cast_and_arithmetic
    source = <<~MT
      # module demo.unsafe_surface

      external function allocate(size: ptr_uint) -> ptr[void]

      function main() -> int:
          let memory = allocate(16)
          unsafe:
              let advanced = ptr[ubyte]<-memory + 4
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_unsafe_pointer_indexing_with_integer_offsets
    source = <<~MT
      # module demo.pointer_offsets

      external function allocate(size: ptr_uint) -> ptr[void]

      function main() -> int:
          let memory = allocate(16)
          unsafe:
              let bytes = ptr[ubyte]<-memory
              let offset = 4
              let advanced = bytes + offset
              let first = advanced[offset - 4]
              let same = first
          return 0
    MT

    result = check_source(source)

      def test_type_checks_unsafe_expressions_inside_boolean_control_flow
        source = <<~MT
          # module demo.unsafe_conditions

          function main(ptr: ptr[bool], count: int) -> int:
              let ready = true
              if ready and unsafe: read(ptr):
                  return 1
              while count > 0 and unsafe: read(ptr):
                  return count
              return 0
        MT

        result = check_source(source)

        assert_equal true, result.functions.key?("main")
      end

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_address_of_dereference_and_deref_assignment_in_unsafe
    source = <<~MT
      # module demo.pointer_surface

      struct Counter:
          value: int

      function main() -> int:
          var counter = Counter(value = 3)
          let counter_ptr = ptr_of(counter)
          unsafe:
              read(counter_ptr).value = 7
          return counter.value
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Counter")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_raw_pointer_member_access_in_unsafe
    source = <<~MT
      # module demo.pointer_surface

      struct Counter:
          value: int

      function main() -> int:
          var counter = Counter(value = 3)
          let counter_ptr = ptr_of(counter)
          unsafe:
              counter_ptr.value = 7
              return counter_ptr.value
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Counter")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_raw_pointer_method_calls_in_unsafe
    source = <<~MT
      # module demo.pointer_methods

      struct Counter:
          value: int

      extending Counter:
          editable function add(delta: int):
              this.value += delta

          function read() -> int:
              return this.value

      function main() -> int:
          var counter = Counter(value = 3)
          let counter_ptr = ptr_of(counter)
          unsafe:
              counter_ptr.add(4)
              return counter_ptr.read()
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Counter")
    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_pointer_indexing_outside_unsafe
    source = <<~MT
      # module demo.bad

      function read(data: ptr[uint]) -> uint:
          return data[0]

      function main() -> int:
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/pointer indexing requires unsafe/, error.message)
  end

  def test_rejects_pointer_dereference_outside_unsafe
    source = <<~MT
      # module demo.bad

      struct Counter:
          value: int

      function main() -> int:
          var counter = Counter(value = 3)
          let counter_ptr = ptr_of(counter)
          return read(counter_ptr).value
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/raw pointer dereference requires unsafe/, error.message)
  end

  def test_rejects_raw_pointer_member_access_outside_unsafe
    source = <<~MT
      # module demo.bad

      struct Counter:
          value: int

      function main() -> int:
          var counter = Counter(value = 3)
          let counter_ptr = ptr_of(counter)
          counter_ptr.value = 7
          return counter.value
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/raw pointer dereference requires unsafe/, error.message)
  end

  def test_rejects_raw_pointer_method_call_outside_unsafe
    source = <<~MT
      # module demo.bad

      struct Counter:
          value: int

      extending Counter:
          function read() -> int:
              return this.value

      function main() -> int:
          var counter = Counter(value = 3)
          let counter_ptr = ptr_of(counter)
          return counter_ptr.read()
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/raw pointer dereference requires unsafe/, error.message)
  end

  def test_rejects_read_on_raw_pointer_outside_unsafe
    source = <<~MT
      # module demo.bad

      struct Counter:
          value: int

      function main() -> int:
          var counter = Counter(value = 3)
          let counter_ptr = ptr_of(counter)
          return read(counter_ptr).value
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/raw pointer dereference requires unsafe/, error.message)
  end

  def test_rejects_pointer_cast_outside_unsafe
    source = <<~MT
      # module demo.bad

      external function allocate(size: ptr_uint) -> ptr[void]

      function main() -> int:
          let memory = allocate(16)
          let bytes = ptr[ubyte]<-memory
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/pointer cast requires unsafe/, error.message)
  end

  def test_rejects_pointer_arithmetic_outside_unsafe
    source = <<~MT
      # module demo.bad

      external function allocate(size: ptr_uint) -> ptr[void]

      function main() -> int:
          let memory = allocate(16)
          let advanced = ptr[ubyte]<-memory + 4
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/pointer cast requires unsafe/, error.message)
  end

  def test_type_checks_unsafe_pointer_to_cstr_abi_casts
    source = <<~MT
      # module demo.cstr_casts

      external function set_text(value: cstr) -> void
      external function get_text() -> cstr

      function main() -> void:
          var buffer = zero[array[char, 32]]
          unsafe:
              let raw_buffer = ptr_of(buffer[0])
              set_text(cstr<-raw_buffer)
              let clipboard = get_text()
              let writable = ptr[char]<-clipboard
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_unsafe_integer_to_char_buffer_writes
    source = <<~MT
      # module demo.char_buffer_writes

      function main() -> int:
          let first = 65
          var ptr: ptr[char] = zero[ptr[char]]
          unsafe:
              ptr[0] = first
              ptr[1] = char<-66
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_zero_pointer_initializer_for_nullable_pointer_local
    source = <<~MT
      # module demo.bad_zero_pointer_initializer

      function main() -> void:
          let maybe_buffer: ptr[char]? = zero[ptr[char]]
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/use null instead of zero\[ptr\[char\]\] in nullable pointer-like context ptr\[char\]\?/, error.message)
  end

  def test_rejects_zero_pointer_assignment_to_nullable_pointer_local
    source = <<~MT
      # module demo.bad_zero_pointer_assignment

      function main() -> void:
          var maybe_buffer: ptr[char]? = null
          maybe_buffer = zero[ptr[char]]
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/use null instead of zero\[ptr\[char\]\] in nullable pointer-like context ptr\[char\]\?/, error.message)
  end

  def test_rejects_zero_pointer_argument_for_nullable_pointer_parameter
    source = <<~MT
      # module demo.bad_zero_pointer_argument

      external function set_buffer(value: ptr[char]?) -> void

      function main() -> void:
          set_buffer(zero[ptr[char]])
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/use null instead of zero\[ptr\[char\]\] in nullable pointer-like context ptr\[char\]\?/, error.message)
  end

  def test_rejects_zero_pointer_return_for_nullable_pointer_return
    source = <<~MT
      # module demo.bad_zero_pointer_return

      function main() -> ptr[char]?:
          return zero[ptr[char]]
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/use null instead of zero\[ptr\[char\]\] in nullable pointer-like context ptr\[char\]\?/, error.message)
  end

  def test_type_checks_typed_null_pointer_literals_and_unsafe_cstr_casts
    source = <<~MT
      # module demo.typed_null_cstr

      external function set_text(value: cstr) -> void

      function main() -> void:
          let maybe_buffer: ptr[char]? = null[ptr[char]]
          unsafe:
              set_text(cstr<-null[ptr[char]])
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_non_pointer_typed_null_literals
    source = <<~MT
      # module demo.bad_typed_null

      function main() -> void:
          let maybe_buffer: ptr[char]? = null[int]
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/typed null requires pointer-like type, got int/, error.message)
  end

  def test_rejects_inference_from_typed_null_literals
    source = <<~MT
      # module demo.bad_typed_null_inference

      function main() -> void:
          let maybe_buffer = null[ptr[char]]
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/cannot infer type for maybe_buffer from null/, error.message)
  end

  def test_rejects_ref_to_pointer_cast_outside_unsafe
    source = <<~MT
      # module demo.bad

      function main() -> int:
          var value = 1
          let handle = ref_of(value)
          let raw = ptr[int]<-handle
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/ref to pointer cast requires unsafe/, error.message)
  end

  def test_get_returns_nullable_pointer_type
    source = <<~MT
      # module demo.get_nullable

      function main() -> int:
          var arr = array[int, 2](1, 2)
          let p = get(arr, 0) else:
              return 1
          unsafe:
              read(p) = 99
          return arr[0]
    MT

    result = check_source(source)
    assert_equal true, result.functions.key?("main")
  end

end

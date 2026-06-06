# frozen_string_literal: true

require_relative "helpers"

class GenericsTest < Minitest::Test
  include SemaTestHelpers

  def test_type_checks_generic_struct_constraints_through_nested_generic_fields
    source = <<~MT
      # module demo.generic_type_constraints

      interface Damageable:
          function hp() -> int

      struct NPC implements Damageable:
          value: int

      extending NPC:
          function hp() -> int:
              return this.value

      struct Holder[T implements Damageable]:
          value: T

      struct Wrapper[U implements Damageable]:
          holder: Holder[U]

      function main() -> int:
          let wrapper = Wrapper[NPC](holder = Holder[NPC](value = NPC(value = 7)))
          return wrapper.holder.value.hp()
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_nested_generic_struct_constraint_without_matching_outer_constraint
    source = <<~MT
      # module demo.generic_type_constraints_bad

      interface Damageable:
          function hp() -> int

      struct Holder[T implements Damageable]:
          value: T

      struct Wrapper[U]:
          holder: Holder[U]
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/type U does not implement interface Damageable/, error.message)
    assert_match(/type demo\.generic_type_constraints_bad\.Holder/, error.message)
  end

  def test_type_checks_generic_helper_with_let_else_error_binding
    source = <<~MT
      # module demo.generic_status_helper

      function encode(value: int) -> Result[int, int]:
          return Result[int, int].success(value= value + 1)

      function wrap[T](value: T, body: fn(arg0: T) -> Result[int, int]) -> Result[int, int]:
          let encoded = body(value) else as error:
              return Result[int, int].failure(error= error)
          return Result[int, int].success(value= encoded)

      function main() -> int:
          let value = wrap[int](4, encode) else:
              return 1
          return value
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_generic_function_calls_with_callable_value_arguments
    source = <<~MT
      # module demo.generic_callable_values

      function apply[T](callback: fn(value: int) -> T, value: int) -> T:
          return callback(value)

      function times_two(value: int) -> int:
          return value * 2

      function main() -> int:
          return apply(times_two, 21)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("apply")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_explicit_generic_method_specialization
    source = <<~MT
      # module demo.generic_method_specialization

      struct Box:
          value: int

      extending Box:
          function echo[T](item: T) -> T:
              return item

      function main() -> int:
          let box = Box(value = 1)
          return box.echo[int](41)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_current_type_param_in_nested_generic_method_specialization
    source = <<~MT
      # module demo.nested_generic_method_specialization

      struct Box:
          value: int

      struct Stack:
          box: Box

      extending Box:
          function echo[T](item: T) -> T:
              return item

      extending Stack:
          function forward[T](item: T) -> T:
              return this.box.echo[T](item)

      function main() -> int:
          let stack = Stack(box = Box(value = 1))
          return stack.forward[int](41)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_generic_struct_instantiation_and_embedding
    source = <<~MT

# module demo.generics

struct Slice[T]:
    data: ptr[T]
    len: ptr_uint

struct Holder:
    items: Slice[int]

function first(items: Slice[int]) -> int:
    if items.len == 0:
        return 0
    unsafe:
        return read(items.data)

function main() -> int:
    var value = 7
    let holder = Holder(items = Slice[int](data = ptr_of(value), len = 1))
    return first(holder.items)

    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Slice")
    assert_equal true, result.types.key?("Holder")
    assert_equal "demo.generics.Slice[int]", result.functions.fetch("first").type.params.first.type.to_s
  end

  def test_type_checks_generic_functions_with_inferred_type_arguments
    source = <<~MT
      # module demo.generic_functions

      struct Slice[T]:
          data: ptr[T]
          len: ptr_uint

      function head[T](items: Slice[T]) -> ptr[T]:
          return items.data

      function min[T](a: T, b: T) -> T:
          if a < b:
              return a
          return b

      function main() -> int:
          var value = 7
          let items = Slice[int](data = ptr_of(value), len = 1)
          let smallest = min(9, 4)
          unsafe:
              return read(head(items)) + smallest
    MT

    result = check_source(source)

    assert_equal ["T"], result.functions.fetch("head").type_params
    assert_equal ["T"], result.functions.fetch("min").type_params
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_generic_functions_with_explicit_type_arguments_and_layout_queries
    source = <<~MT
      # module demo.generic_layout

      function bytes_for[T](count: ptr_uint) -> ptr_uint:
          return count * size_of(T)

      function main() -> int:
          return int<-bytes_for[int](4)
    MT

    result = check_source(source)

    assert_equal ["T"], result.functions.fetch("bytes_for").type_params
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_generic_functions_with_literal_type_arguments
    source = <<~MT
      # module demo.generic_builder

      function capacity_of[N](buffer: str_buffer[N]) -> ptr_uint:
          return buffer.capacity()

      function main() -> int:
          var buffer: str_buffer[32]
          return int<-(capacity_of(buffer) + capacity_of(buffer))
    MT

    result = check_source(source)

    assert_equal ["N"], result.functions.fetch("capacity_of").type_params
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_generic_functions_with_explicit_literal_type_arguments
    source = <<~MT
      # module demo.generic_builder_explicit

      function capacity_of[N](buffer: str_buffer[N]) -> ptr_uint:
          return buffer.capacity()

      function main() -> int:
          var buffer: str_buffer[32]
          return int<-capacity_of[32](buffer)
    MT

    result = check_source(source)

    assert_equal ["N"], result.functions.fetch("capacity_of").type_params
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_generic_methods
    source = <<~MT
      # module demo.generic_methods

      struct Box:
          value: int

      extending Box:
          function echo[T](input: T) -> T:
              return input

          static function make[T](input: T) -> T:
              return input

      function main() -> int:
          let box = Box(value = 1)
          let a = box.echo(3)
          let b = Box.make(4)
          return a + b
    MT

    result = check_source(source)

    box_type = result.types.fetch("Box")
    echo_binding = result.methods.fetch(box_type).fetch("echo")
    make_binding = result.methods.fetch(box_type).fetch("static:make")

    assert_equal ["T"], echo_binding.type_params
    assert_equal ["T"], make_binding.type_params
    assert_equal true, result.functions.key?("main")
  end

    def test_type_checks_generic_receiver_methods
    source = <<~MT
      # module demo.generic_receiver_methods

      struct Box[T]:
          value: T

      extending Box[T]:
          function get() -> T:
              return this.value

          editable function set(value: T) -> void:
              this.value = value

          static function zero() -> Box[T]:
              return Box[T](value = zero[T])

          function echo[U](input: U) -> U:
              return input

      function main() -> int:
          var box = Box[int].zero()
          box.set(7)
          let echoed = box.echo(true)
          if echoed:
              return box.get()
          return 0
    MT

    result = check_source(source)

    box_type = result.types.fetch("Box")
    methods = result.methods.fetch(box_type)

    assert_equal "demo.generic_receiver_methods.Box[T]", methods.fetch("get").declared_receiver_type.to_s
    assert_equal ["T"], methods.fetch("static:zero").type_params
    assert_equal ["T", "U"], methods.fetch("echo").type_params
    assert_equal true, result.functions.key?("main")
    end

  def test_type_checks_generic_receiver_static_self_call
    source = <<~MT
      # module demo.generic_receiver_static_self_call

      struct Box[T]:
          value: T

      extending Box[T]:
          static function create() -> Box[T]:
              return Box[T](value = zero[T])

          static function with_default() -> Box[T]:
              return Box[T].create()

      function main() -> int:
          let box = Box[int].with_default()
          return box.value
    MT

    result = check_source(source)

    box_type = result.types.fetch("Box")
    methods = result.methods.fetch(box_type)

    assert_equal ["T"], methods.fetch("static:create").type_params
    assert_equal ["T"], methods.fetch("static:with_default").type_params
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_methods_on_generic_pointer_receivers
    source = <<~MT
      # module demo.generic_pointer_methods

      struct Point:
          x: int

      extending const_ptr[T]:
          public function read_value() -> T:
              return unsafe: read(this)

      function main(point: const_ptr[Point]) -> int:
          return point.read_value().x
    MT

    result = check_program_source(source).root_analysis

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_generic_foreign_mapping_public_alias_for_str_buffer_capacity_pairs
    root_source = <<~MT
      # module demo.main

      import std.ui as ui

      function main() -> void:
          var buffer: str_buffer[32]
          ui.text_box(buffer)
    MT

    imported_sources = {
      "std/c/ui.mt" => <<~MT,
        # module std.c.ui
        external
        include "ui.h"

        external function TextBox(text: ptr[char], text_size: int) -> void
      MT
      "std/ui.mt" => <<~MT,
        # module std.ui

        import std.c.ui as c

        public foreign function text_box[N](text: str_buffer[N] as ptr[char]) -> void = c.TextBox(text, int<-(text_public.capacity() + 1))
      MT
    }

    result = check_program_source(root_source, imported_sources)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_explicit_literal_specialization_for_imported_generic_foreign_defs
    root_source = <<~MT
      # module demo.main

      import std.ui as ui

      function main() -> void:
          var buffer: str_buffer[32]
          ui.text_box[32](buffer)
    MT

    imported_sources = {
      "std/c/ui.mt" => <<~MT,
        # module std.c.ui
        external
        include "ui.h"

        external function TextBox(text: ptr[char], text_size: int) -> void
      MT
      "std/ui.mt" => <<~MT,
        # module std.ui

        import std.c.ui as c

        public foreign function text_box[N](text: str_buffer[N] as ptr[char]) -> void = c.TextBox(text, int<-(text_public.capacity() + 1))
      MT
    }

    result = check_program_source(root_source, imported_sources)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_explicit_literal_specialization_for_local_generic_foreign_defs
    root_source = <<~MT
      # module demo.main

      import std.c.ui as c

      public foreign function text_box[N](text: str_buffer[N] as ptr[char]) -> void = c.TextBox(text, int<-(text_public.capacity() + 1))

      function main() -> void:
          var buffer: str_buffer[32]
          text_box[32](buffer)
    MT

    imported_sources = {
      "std/c/ui.mt" => <<~MT,
        # module std.c.ui
        external
        include "ui.h"

        external function TextBox(text: ptr[char], text_size: int) -> void
      MT
    }

    result = check_program_source(root_source, imported_sources)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_implicit_ref_arguments_for_generic_ref_parameters
    source = <<~MT
      # module demo.generic_refs

      function snapshot[T](value: ref[T]) -> T:
          return read(value)

      function main() -> int:
          var number = 7
          return snapshot(number)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_generic_variant_declaration_and_use
    source = <<~MT
      # module demo.variant_generic

      variant Box[T]:
          some(value: T)
          none

      function unwrap_or_zero(value: Box[int]) -> int:
          match value:
              Box.some as payload:
                  return payload.value
              Box.none:
                  return 0

      function main() -> int:
          let value: Box[int] = Box[int].some(value= 42)
          return unwrap_or_zero(value)
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Box")
    assert_equal true, result.functions.key?("unwrap_or_zero")
  end

  def test_type_checks_recursive_generic_method_helper_with_multiple_recursive_calls
  source = <<~MT
    # module demo.recursive_method_helper

    import std.mem.heap as heap

    struct Node[T]:
        value: T
        left: ptr[Node[T]]?

    public struct OrderedSet[T]:
        root: ptr[void]?

    extending OrderedSet[T]:
        public static function create() -> OrderedSet[T]:
            return OrderedSet[T](root = null)

        static function probe(node: ptr[Node[T]]?) -> void:
            if node == null:
                return
            let current = unsafe: ptr[Node[T]]<-node
            let left = unsafe: read(current).left
            OrderedSet[T].probe(left)
            OrderedSet[T].probe(left)
            heap.release(node)
            return

        public editable function release() -> void:
            OrderedSet[T].probe(unsafe: ptr[Node[T]]<-this.root)
            this.root = null
            return

    function main() -> int:
        var values = OrderedSet[int].create()
        defer values.release()
        return 0
  MT

  result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

end

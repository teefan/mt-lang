# frozen_string_literal: true

require_relative "helpers"

class DynTest < Minitest::Test
  include CodegenTestHelpers

  def test_generate_c_for_dyn_adapt_and_method_call
    source = <<~MT
      # module demo.dyn_codegen

      interface Shape:
          function area() -> float

      struct Circle implements Shape:
          radius: float

      extending Circle:
          function area() -> float:
              return 3.14 * this.radius * this.radius

      function main() -> int:
          var c = Circle(radius = 2.0)
          var s: dyn[Shape] = adapt[Shape](ref_of(c))
          let a = s.area()
          return 0
    MT

    generated = generate_c_from_source(source)

    assert_match(/typedef struct mt_vtable_Shape mt_vtable_Shape;/, generated)
    assert_match(/typedef struct mt_dyn_Shape mt_dyn_Shape;/, generated)
    assert_match(/struct mt_vtable_Shape \{/, generated)
    assert_match(/void \*data;/, generated)
    assert_match(/void \*vtable;/, generated)
    assert_match(/__dyn_demo_dyn_codegen_Circle_area/, generated)
    assert_match(/mt_vtable_demo_dyn_codegen_Circle_Shape/, generated)
    assert_match(/mt_vtable_Shape\*.*vtable/, generated)
  end

  def test_generate_c_for_dyn_with_multiple_interface_methods
    source = <<~MT
      # module demo.dyn_multi_codegen

      interface Damageable:
          function hp() -> int
          function name() -> str
          editable function take_damage(amount: int) -> void

      struct NPC implements Damageable:
          hp: int

      extending NPC:
          function hp() -> int:
              return this.hp
          function name() -> str:
              return "npc"
          editable function take_damage(amount: int):
              this.hp -= amount

      function main(amount: int) -> int:
          var n = NPC(hp = 10)
          var h: dyn[Damageable] = adapt[Damageable](ref_of(n))
          let current = h.hp()
          return current
    MT

    generated = generate_c_from_source(source)

    assert_match(/typedef struct mt_vtable_Damageable/, generated)
    assert_match(/__dyn_demo_dyn_multi_codegen_NPC_hp/, generated)
    assert_match(/__dyn_demo_dyn_multi_codegen_NPC_name/, generated)
    assert_match(/__dyn_demo_dyn_multi_codegen_NPC_take_damage/, generated)
    assert_match(/mt_vtable_demo_dyn_multi_codegen_NPC_Damageable/, generated)
  end

  def test_generate_c_for_dyn_with_editable_method_call
    source = <<~MT
      # module demo.dyn_editable_codegen

      interface Counter:
          editable function bump() -> void
          function value() -> int

      struct Tally implements Counter:
          count: int

      extending Tally:
          editable function bump():
              this.count += 1
          function value() -> int:
              return this.count

      function main() -> int:
          var t = Tally(count = 0)
          var c: dyn[Counter] = adapt[Counter](ref_of(t))
          return c.value()
    MT

    generated = generate_c_from_source(source)

    assert_match(/typedef struct mt_dyn_Counter/, generated)
    assert_match(/__dyn_demo_dyn_editable_codegen_Tally_bump/, generated)
    assert_match(/__dyn_demo_dyn_editable_codegen_Tally_value/, generated)
    assert_match(/mt_vtable_demo_dyn_editable_codegen_Tally_Counter/, generated)
  end

  def test_generate_c_for_dyn_generic_interface
    source = <<~MT
      # module demo.dyn_generic_codegen

      interface Mapper[T]:
          function map(x: T) -> T

      struct Doubler implements Mapper[int]:
          value: int

      extending Doubler:
          function map(x: int) -> int:
              return x * 2

      function main() -> int:
          var d = Doubler(value = 0)
          var m: dyn[Mapper[int]] = adapt[Mapper[int]](ref_of(d))
          let result = m.map(3)
          return result
    MT

    generated = generate_c_from_source(source)

    assert_match(/typedef struct mt_vtable_Mapper mt_vtable_Mapper;/, generated)
    assert_match(/typedef struct mt_dyn_Mapper mt_dyn_Mapper;/, generated)
    assert_match(/__dyn_demo_dyn_generic_codegen_Doubler_map/, generated)
    assert_match(/mt_vtable_demo_dyn_generic_codegen_Doubler_Mapper/, generated)
  end

  def test_generate_c_for_dyn_as_struct_field
    source = <<~MT
      # module demo.dyn_field_codegen

      interface Shape:
          function area() -> float

      struct Circle implements Shape:
          radius: float

      extending Circle:
          function area() -> float:
              return 3.14 * this.radius * this.radius

      struct Holder:
          shape: dyn[Shape]

      function main() -> int:
          var c = Circle(radius = 2.0)
          var holder = Holder(shape = adapt[Shape](ref_of(c)))
          return 0
    MT

    generated = generate_c_from_source(source)

    assert_match(/typedef struct mt_dyn_Shape/, generated)
    assert_match(/mt_dyn_Shape shape;/, generated)
  end

  def test_generate_c_for_dyn_with_opaque_type
    source = <<~MT
      # module demo.dyn_opaque_codegen

      interface Closable:
          function close() -> void

      opaque Handle implements Closable

      extending Handle:
          function close():
              return

      function use(handle: ref[Handle]) -> void:
          var h: dyn[Closable] = adapt[Closable](handle)
          h.close()
          return
    MT

    generated = generate_c_from_source(source)

    assert_match(/typedef struct mt_dyn_Closable/, generated)
    assert_match(/__dyn_demo_dyn_opaque_codegen_Handle_close/, generated)
    assert_match(/mt_vtable_demo_dyn_opaque_codegen_Handle_Closable/, generated)
  end

  def test_generate_c_for_dyn_return_value
    source = <<~MT
      # module demo.dyn_return_codegen

      interface Shape:
          function area() -> float

      struct Circle implements Shape:
          radius: float

      extending Circle:
          function area() -> float:
              return 3.14 * this.radius * this.radius

      function make(r: float) -> dyn[Shape]:
          var c = Circle(radius = r)
          return adapt[Shape](ref_of(c))

      function main() -> int:
          var s: dyn[Shape] = make(2.0)
          return int<-(s.area())
    MT

    generated = generate_c_from_source(source)

    assert_match(/mt_dyn_Shape/, generated)
    assert_match(/__dyn_demo_dyn_return_codegen_Circle_area/, generated)
  end

  def test_generate_c_for_dyn_function_parameter
    source = <<~MT
      # module demo.dyn_param_codegen

      interface Damageable:
          function hp() -> int

      struct NPC implements Damageable:
          hp: int

      extending NPC:
          function hp() -> int:
              return this.hp

      function inspect(handler: dyn[Damageable]) -> int:
          return handler.hp()

      function main() -> int:
          var n = NPC(hp = 10)
          let h: dyn[Damageable] = adapt[Damageable](ref_of(n))
          return inspect(h)
    MT

    generated = generate_c_from_source(source)

    assert_match(/mt_dyn_Damageable handler/, generated)
  end

  def test_generate_c_for_dyn_local_as_let_binding
    source = <<~MT
      # module demo.dyn_let_codegen

      interface Shape:
          function area() -> float

      struct Circle implements Shape:
          radius: float

      extending Circle:
          function area() -> float:
              return 3.14 * this.radius * this.radius

      function main(flag: bool) -> int:
          var c = Circle(radius = 1.0)
          let s = adapt[Shape](ref_of(c))
          return int<-flag
    MT

    generated = generate_c_from_source(source)

    assert_match(/__dyn_demo_dyn_let_codegen_Circle_area/, generated)
    assert_match(/mt_vtable_demo_dyn_let_codegen_Circle_Shape/, generated)
  end

  def test_run_program_with_dyn_adapt_and_method_call
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
      # module demo.dyn_runtime

      interface Damageable:
          function hp() -> int
          function name() -> str
          editable function take_damage(amount: int) -> void

      struct NPC implements Damageable:
          hp: int

      extending NPC:
          function hp() -> int:
              return this.hp
          function name() -> str:
              return "npc"
          editable function take_damage(amount: int):
              this.hp -= amount

      function main() -> int:
          var n = NPC(hp = 10)
          var h: dyn[Damageable] = adapt[Damageable](ref_of(n))
          return h.hp()
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 10, result.exit_status
  end

  def test_run_program_with_dyn_multiple_interfaces
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
      # module demo.dyn_multi_runtime

      interface Damageable:
          function hp() -> int

      struct Knight implements Damageable:
          hp: int

      extending Knight:
          function hp() -> int:
              return this.hp

      function get_hp(handler: dyn[Damageable]) -> int:
          return handler.hp()

      function main() -> int:
          var k = Knight(hp = 42)
          let h: dyn[Damageable] = adapt[Damageable](ref_of(k))
          return get_hp(h)
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 42, result.exit_status
  end

end

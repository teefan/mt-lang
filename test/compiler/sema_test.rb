# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "../test_helper"

class MilkTeaSemaTest < Minitest::Test
  def test_rejects_local_named_after_reserved_builtin_result_type
    error = assert_raises(MilkTea::SemaError) do
      check_source(<<~MT)
        function main() -> int:
            let Result = 1
            return Result
      MT
    end

    assert_equal "local Result uses reserved built-in type name Result", error.message
  end

  def test_allows_local_named_after_non_reserved_builtin_type_name
    analysis = check_source(<<~MT)
      function main() -> int:
          let span = 1
          return span
    MT

    assert_equal true, analysis.functions.key?("main")
  end

  def test_allows_import_alias_named_after_primitive_type
    program = check_program_source(<<~MT)
      # module demo.ok

      import std.async as str

      function main() -> int:
          return 0
    MT

    assert_equal true, program.root_analysis.functions.key?("main")
  end

  def test_rejects_import_alias_named_after_reserved_builtin_result_type
    error = assert_raises(MilkTea::SemaError) do
      check_program_source(<<~MT)
        # module demo.bad

        import std.async as Result

        function main() -> int:
            return 0
      MT
    end

    assert_match(/import alias Result uses reserved built-in type name Result/, error.message)
  end

  def test_rejects_non_bool_conditions
    source = <<~MT
      # module demo.bad

      function main() -> int:
          if 1:
              return 0
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/if condition must be bool/, error.message)
  end

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

  def test_type_checks_nominal_interface_constraint_calls
    source = <<~MT
      # module demo.interfaces

      interface Damageable:
          mutable function take_damage(amount: int) -> void
          function is_alive() -> bool

      struct NPC implements Damageable:
          hp: int

      extending NPC:
          mutable function take_damage(amount: int):
              this.hp -= amount

          function is_alive() -> bool:
              return this.hp > 0

      function damage_one[T implements Damageable](target: ref[T], amount: int) -> void:
          if target.is_alive():
              target.take_damage(amount)

      function main() -> int:
          var npc = NPC(hp = 10)
          damage_one(npc, 3)
          return npc.hp
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_nominal_interface_constraint_without_explicit_implements
    source = <<~MT
      # module demo.interfaces

      interface Damageable:
          mutable function take_damage(amount: int) -> void
          function is_alive() -> bool

      struct NPC:
          hp: int

      extending NPC:
          mutable function take_damage(amount: int):
              this.hp -= amount

          function is_alive() -> bool:
              return this.hp > 0

      function damage_one[T implements Damageable](target: ref[T], amount: int) -> void:
          if target.is_alive():
              target.take_damage(amount)

      function main() -> int:
          var npc = NPC(hp = 10)
          damage_one(npc, 3)
          return npc.hp
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/does not implement interface Damageable/, error.message)
  end

  def test_rejects_explicit_interface_conformance_with_missing_method
    source = <<~MT
      # module demo.interfaces

      interface Damageable:
          mutable function take_damage(amount: int) -> void
          function is_alive() -> bool

      struct NPC implements Damageable:
          hp: int

      extending NPC:
          mutable function take_damage(amount: int):
              this.hp -= amount

      function main() -> int:
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/missing method is_alive/, error.message)
  end

  def test_rejects_explicit_interface_conformance_with_generic_method
    source = <<~MT
      # module demo.interfaces

      interface Drawable:
          function draw() -> void

      struct Screen implements Drawable:
          ticks: int

      extending Screen:
          function draw[T]() -> void:
              return
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/cannot be implemented by generic methods/, error.message)
  end

  def test_type_checks_multiple_interfaces_on_single_type
    source = <<~MT
      # module demo.interfaces

      interface Damageable:
          mutable function take_damage(amount: int) -> void

      interface Named:
          function name() -> str

      struct NPC implements Damageable, Named:
          label: str
          hp: int

      extending NPC:
          mutable function take_damage(amount: int):
              this.hp -= amount

          function name() -> str:
              return this.label

      function tag_and_damage[T implements Damageable and Named](target: ref[T]) -> str:
          target.take_damage(1)
          return target.name()

      function main() -> int:
          var npc = NPC(label = "orc", hp = 10)
          let label = tag_and_damage(npc)
          if label == "orc" and npc.hp == 9:
              return 0
          return 1
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_default_specialization_with_interface_requirement_without_defaults_constraint
    source = <<~MT
      # module demo.default_interface_ok

      interface Named:
          function value() -> int

      struct Counter implements Named:
          count: int

      extending Counter:
          static function default() -> Counter:
              return Counter(count = 7)

          function value() -> int:
              return this.count

      function make_and_read[T implements Named]() -> int:
          let item = default[T]
          return item.value()

      function main() -> int:
          return make_and_read[Counter]()
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_static_interface_requirements_and_associated_calls_on_specialized_type_params
    source = <<~MT
      # module demo.static_interface_requirements

      interface Tagged:
          static function tag() -> int

      struct Counter implements Tagged:
          value: int

      extending Counter:
          static function tag() -> int:
              return 17

      function read_tag[T implements Tagged]() -> int:
          return T.tag()

      function main() -> int:
          return read_tag[Counter]()
    MT

    result = check_source(source)
    counter_type = result.types.fetch("Counter")
    methods = result.methods.fetch(counter_type)

    assert_nil methods.fetch("tag").type.receiver_type
    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_static_interface_requirement_implemented_by_instance_method
    source = <<~MT
      # module demo.static_interface_mismatch

      interface Tagged:
          static function tag() -> int

      struct Counter implements Tagged:
          value: int

      extending Counter:
          function tag() -> int:
              return this.value
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/method kind does not match/, error.message)
  end

  def test_type_checks_hash_and_equal_builtins_with_canonical_hooks
    source = <<~MT
      # module demo.hash_equal_ok

      struct Key:
          value: int

      extending Key:
          static function hash(value: const_ptr[Key]) -> uint:
              return uint<-0

          static function equal(left: const_ptr[Key], right: const_ptr[Key]) -> bool:
              return true

      function same_key[T](left: T, right: T) -> bool:
          return hash[T](left) == hash[T](right) and equal[T](left, right)

      function main() -> bool:
          let left = Key(value = 5)
          let right = Key(value = 5)
          return same_key[Key](left, right)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_hash_and_equal_builtins_in_imported_generic_functions
    source = <<~MT
      # module demo.hash_equal_imported_main

      import demo.hash_tools as tools

      struct Key:
          value: int

      extending Key:
          static function hash(value: const_ptr[Key]) -> uint:
              unsafe:
                  return uint<-read(ptr[Key]<-value).value

          static function equal(left: const_ptr[Key], right: const_ptr[Key]) -> bool:
              unsafe:
                  return read(ptr[Key]<-left).value == read(ptr[Key]<-right).value

      function main() -> bool:
          let left = Key(value = 5)
          let right = Key(value = 5)
          return tools.same_key(left, right)
    MT

    imported_sources = {
      "demo/hash_tools.mt" => <<~MT,
        # module demo.hash_tools

        public function same_key[T](left: T, right: T) -> bool:
            return hash[T](left) == hash[T](right) and equal[T](left, right)
      MT
    }

    result = check_program_source(source, imported_sources)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_rejects_hash_builtin_without_canonical_associated_hash_function
    source = <<~MT
      # module demo.hash_builtin_bad

      struct Key:
          value: int

      extending Key:
          static function hash(value: Key) -> uint:
              return uint<-value.value

      function read_hash[T](value: T) -> uint:
          return hash[T](value)

      function main() -> uint:
          let key = Key(value = 1)
          return read_hash[Key](key)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/requires demo\.hash_builtin_bad\.Key\.hash\(value: const_ptr\[demo\.hash_builtin_bad\.Key\]\) -> uint/, error.message)
  end

  def test_rejects_hash_builtin_for_ordinary_primitive_types
    source = <<~MT
      # module demo.hash_builtin_primitive_bad

      function read_hash[T](value: T) -> uint:
          return hash[T](value)

      function main() -> uint:
          return read_hash[int](1)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/hash\[int\] requires associated function int\.hash/, error.message)
  end

  def test_type_checks_hash_and_equal_builtins_for_str_with_explicit_static_hooks
    source = <<~MT
      # module demo.hash_equal_str_ok

      extending str:
          static function hash(value: const_ptr[str]) -> uint:
              return uint<-0

          static function equal(left: const_ptr[str], right: const_ptr[str]) -> bool:
              return true

      function same_text[T](left: T, right: T) -> bool:
          return hash[T](left) == hash[T](right) and equal[T](left, right)

      function main() -> bool:
          let left: str = "a"
          let right: str = "b"
          return same_text[str](left, right)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_order_builtin_with_canonical_hook
    source = <<~MT
      # module demo.order_ok

      struct Key:
          value: int

      extending Key:
          static function order(left: const_ptr[Key], right: const_ptr[Key]) -> int:
              unsafe:
                  let left_value = read(ptr[Key]<-left).value
                  let right_value = read(ptr[Key]<-right).value
                  if left_value < right_value:
                      return -1
                  if left_value > right_value:
                      return 1
                  return 0

      function compare[T](left: T, right: T) -> int:
          return order[T](left, right)

      function main() -> int:
          let left = Key(value = 1)
          let right = Key(value = 5)
          return compare[Key](left, right)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_order_builtin_in_imported_generic_functions
    source = <<~MT
      # module demo.order_imported_main

      import demo.order_tools as tools

      struct Key:
          value: int

      extending Key:
          static function order(left: const_ptr[Key], right: const_ptr[Key]) -> int:
              unsafe:
                  let left_value = read(ptr[Key]<-left).value
                  let right_value = read(ptr[Key]<-right).value
                  if left_value < right_value:
                      return -1
                  if left_value > right_value:
                      return 1
                  return 0

      function main() -> int:
          let left = Key(value = 2)
          let right = Key(value = 7)
          return tools.compare(left, right)
    MT

    imported_sources = {
      "demo/order_tools.mt" => <<~MT,
        # module demo.order_tools

        public function compare[T](left: T, right: T) -> int:
            return order[T](left, right)
      MT
    }

    result = check_program_source(source, imported_sources)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_rejects_order_builtin_without_canonical_associated_order_function
    source = <<~MT
      # module demo.order_builtin_bad

      struct Key:
          value: int

      extending Key:
          static function order(left: Key, right: Key) -> int:
              return left.value - right.value

      function compare[T](left: T, right: T) -> int:
          return order[T](left, right)

      function main() -> int:
          let left = Key(value = 1)
          let right = Key(value = 3)
          return compare[Key](left, right)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/requires demo\.order_builtin_bad\.Key\.order\(left: const_ptr\[demo\.order_builtin_bad\.Key\], right: const_ptr\[demo\.order_builtin_bad\.Key\]\) -> int/, error.message)
  end

  def test_rejects_hash_builtin_on_non_addressable_temporary_values
    source = <<~MT
      # module demo.hash_temporary_bad

      struct Key:
          value: int

      extending Key:
          static function hash(value: const_ptr[Key]) -> uint:
              return uint<-0

      function main() -> uint:
          return hash[Key](Key(value = 1))
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/hash\[demo\.hash_temporary_bad\.Key\] expects a safe/, error.message)
  end

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

  def test_rejects_removed_defaults_constraint_on_generic_variant
    source = <<~MT
      # module demo.generic_variant_defaults_removed

      struct Plain:
          value: int

      variant Slot[T defaults]:
          some(value: T)
          none

      function main() -> int:
          let slot = Slot[Plain].none
          match slot:
              case .none:
                  return 0
              case .some as some:
                  return some.value.value
    MT

    error = assert_raises(MilkTea::ParseError) do
      check_source(source)
    end

    assert_match(/defaults constraint has been removed/, error.message)
    assert_match(/default\[T\]/, error.message)
  end

  def test_rejects_removed_defaults_constraint_on_generic_function
    source = <<~MT
      # module demo.defaults_removed

      struct Plain:
          value: int

      function make_default[T defaults]() -> T:
          return default[T]

      function main() -> int:
          let plain = make_default[Plain]()
          return plain.value
    MT

    error = assert_raises(MilkTea::ParseError) do
      check_source(source)
    end

    assert_match(/defaults constraint has been removed/, error.message)
    assert_match(/default\[T\]/, error.message)
  end

  def test_type_checks_imported_public_interface_constraints
    root_source = <<~MT
      # module demo.main

      import std.sample as sample

      function damage_one[T implements sample.Damageable](target: ref[T], amount: int) -> void:
          if target.is_alive():
              target.take_damage(amount)

      function main() -> int:
          var npc = sample.NPC(hp = 5)
          damage_one(npc, 2)
          return npc.hp
    MT

    imported_sources = {
      "std/sample.mt" => <<~MT,
        # module std.sample

        public interface Damageable:
            mutable function take_damage(amount: int) -> void
            function is_alive() -> bool

        public struct NPC implements Damageable:
            hp: int

        extending NPC:
            public mutable function take_damage(amount: int):
                this.hp -= amount

            public function is_alive() -> bool:
                return this.hp > 0
      MT
    }

    result = check_program_source(root_source, imported_sources)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_downstream_imported_public_interface_conformance
    root_source = <<~MT
      # module demo.main

      import std.contracts as contracts
      import std.entities as entities

      function damage_one[T implements contracts.Damageable](target: ref[T], amount: int) -> void:
          if target.is_alive():
              target.take_damage(amount)

      function main() -> int:
          var npc = entities.NPC(hp = 5)
          damage_one(npc, 2)
          return npc.hp
    MT

    imported_sources = {
      "std/contracts.mt" => <<~MT,
        # module std.contracts

        public interface Damageable:
            mutable function take_damage(amount: int) -> void
            function is_alive() -> bool
      MT
      "std/entities.mt" => <<~MT,
        # module std.entities

        import std.contracts as contracts

        public struct NPC implements contracts.Damageable:
            hp: int

        extending NPC:
            public mutable function take_damage(amount: int):
                this.hp -= amount

            public function is_alive() -> bool:
                return this.hp > 0
      MT
    }

    result = check_program_source(root_source, imported_sources)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_rejects_downstream_imported_interface_conformance_with_private_methods
    root_source = <<~MT
      # module demo.main

      import std.contracts as contracts
      import std.entities as entities

      function damage_one[T implements contracts.Damageable](target: ref[T], amount: int) -> void:
          if target.is_alive():
              target.take_damage(amount)

      function main() -> int:
          var npc = entities.NPC(hp = 5)
          damage_one(npc, 2)
          return npc.hp
    MT

    imported_sources = {
      "std/contracts.mt" => <<~MT,
        # module std.contracts

        public interface Damageable:
            mutable function take_damage(amount: int) -> void
            function is_alive() -> bool
      MT
      "std/entities.mt" => <<~MT,
        # module std.entities

        import std.contracts as contracts

        public struct NPC implements contracts.Damageable:
            hp: int

        extending NPC:
            mutable function take_damage(amount: int):
                this.hp -= amount

            function is_alive() -> bool:
                return this.hp > 0
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(root_source, imported_sources)
    end

    assert_match(/type std\.entities\.NPC does not implement interface Damageable for function damage_one/, error.message)
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

  def test_type_checks_let_else_status_success_binding
    source = <<~MT
      # module demo.status_flow



      function parse(input: int) -> Result[int, int]:
          if input < 0:
              return Result[int, int].failure(error= 7)
          return Result[int, int].success(value= input + 1)

      function read_value(input: int) -> int:
          let value = parse(input) else:
              return 7
          return value + 10
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("read_value")
  end

  def test_type_checks_let_else_maybe_success_binding
    source = <<~MT
      # module demo.maybe_flow



      function parse(input: int) -> Option[int]:
          if input < 0:
              return Option[int].none
          return Option[int].some(value= input + 1)

      function read_value(input: int) -> int:
          let value = parse(input) else:
              return 7
          return value + 10
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("read_value")
  end

  def test_type_checks_let_else_status_error_binding
    source = <<~MT
      # module demo.status_flow



      function parse(input: int) -> Result[int, int]:
          if input < 0:
              return Result[int, int].failure(error= 7)
          return Result[int, int].success(value= input + 1)

      function read_value(input: int) -> int:
          let value = parse(input) else as error:
              return error
          return value + 10
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("read_value")
  end

  def test_type_checks_let_else_status_void_discard_binding
    source = <<~MT
      # module demo.status_void_flow



      function done() -> void:
          return

      function parse(input: int) -> Result[void, int]:
          if input < 0:
              return Result[void, int].failure(error= 7)
          return Result[void, int].success(value= done())

      function read_value(input: int) -> int:
          let _ = parse(input) else as error:
              return error
          return 10
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("read_value")
  end

  def test_type_checks_result_void_propagation_statement
    source = <<~MT
      # module demo.status_void_flow



      function done() -> void:
          return

      function parse(input: int) -> Result[void, int]:
          if input < 0:
              return Result[void, int].failure(error= 7)
          return Result[void, int].success(value= done())

      function verify(input: int) -> Result[void, int]:
          parse(input)?
          return Result[void, int].success(value= done())
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("verify")
  end

  def test_type_checks_result_propagation_inside_async_function
    source = <<~MT
      # module demo.status_void_flow



      function parse(input: int) -> Result[int, int]:
          return Result[int, int].success(value= input + 1)

      async function verify(input: int) -> Result[str, int]:
          let value = parse(input)?
          return Result[str, int].success(value= f"ok \#{value}")
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("verify")
  end

  def test_type_checks_result_propagation_over_await_inside_async_function
    source = <<~MT
      # module demo.status_void_flow

      import std.async as aio


      async function parse(input: int) -> Result[int, int]:
          await aio.sleep(1)
          return Result[int, int].success(value= input + 1)

      async function verify(input: int) -> Result[str, int]:
          let value = (await parse(input))?
          return Result[str, int].success(value= f"ok \#{value}")
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("verify")
  end

  def test_type_checks_result_void_propagation_statement_inside_async_function
    source = <<~MT
      # module demo.status_void_flow



      function done() -> void:
          return

      function parse(input: int) -> Result[void, int]:
          if input < 0:
              return Result[void, int].failure(error= 7)
          return Result[void, int].success(value= done())

      async function verify(input: int) -> Result[void, int]:
          parse(input)?
          return Result[void, int].success(value= done())
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("verify")
  end

  def test_rejects_result_propagation_inside_defer_block
    source = <<~MT
      # module demo.status_defer



      function done() -> void:
          return

      function parse() -> Result[void, int]:
          return Result[void, int].success(value= done())

      function verify() -> Result[void, int]:
          defer:
              parse()?
          return Result[void, int].success(value= done())
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/propagation is not allowed inside defer blocks/, error.message)
  end

  def test_rejects_result_propagation_when_enclosing_return_is_not_result
    source = <<~MT
      # module demo.status_non_result

      function parse(input: int) -> Result[int, int]:
          return Result[int, int].success(value= input)

      function verify(input: int) -> int:
          let value = parse(input)?
          return value
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/propagation requires enclosing function\/proc to return Result\[_/, error.message)
  end

  def test_rejects_result_propagation_with_error_type_mismatch
    source = <<~MT
      # module demo.status_error_type_mismatch

      function parse(input: int) -> Result[int, long]:
          return Result[int, long].success(value= input)

      function verify(input: int) -> Result[int, int]:
          let value = parse(input)?
          return Result[int, int].success(value= value)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/propagation error type/, error.message)
    assert_match(/must match enclosing Result error type/, error.message)
  end

  def test_rejects_result_propagation_expression_with_void_success_type
    source = <<~MT
      # module demo.status_void_success



      function done() -> void:
          return

      function parse() -> Result[void, int]:
          return Result[void, int].success(value= done())

      function verify() -> Result[int, int]:
          let value = parse()?
          return Result[int, int].success(value= value)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/propagation requires a non-void Result success type/, error.message)
  end

  def test_rejects_result_propagation_on_non_result_operand
    source = <<~MT
      # module demo.status_not_result

      function verify() -> Result[int, int]:
          let value = 1?
          return Result[int, int].success(value= value)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/propagation expects Result\[T, E\]/, error.message)
  end

  def test_rejects_result_propagation_outside_function_and_proc_bodies
    source = <<~MT
      # module demo.status_top_level

      const value: int = Result[int, int].success(value= 1)?
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/propagation is only allowed inside function and proc bodies/, error.message)
  end

  def test_rejects_let_else_discard_binding_with_type_annotation
    source = <<~MT
      # module demo.status_void_flow



      function done() -> void:
          return

      function parse() -> Result[void, int]:
          return Result[void, int].success(value= done())

      function main() -> int:
          let _: void = parse() else:
              return 1
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/let-else discard binding _ cannot have a type annotation/, error.message)
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

  def test_type_checks_for_loop_over_custom_iterator_protocol
    source = <<~MT
      # module demo.iterator_for

      struct Numbers:
          stop: int

      struct NumbersIter:
          index: int
          stop: int
          current: int

      extending Numbers:
          public function iter() -> NumbersIter:
              return NumbersIter(index = 0, stop = this.stop, current = 0)

      extending NumbersIter:
          public mutable function next() -> ptr[int]?:
              if this.index >= this.stop:
                  return null[ptr[int]]
              this.current = this.index
              this.index += 1
              unsafe:
                  return ptr_of(this.current)

      function main() -> int:
          var total = 0
          for value in Numbers(stop = 3):
              unsafe:
                  total += read(value)
          return total
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
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
          public mutable function next() -> ptr[int]:
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

  def test_type_checks_for_loop_over_bool_current_iterator_protocol
    source = <<~MT
      # module demo.iterator_current

      struct Numbers:
          stop: int

      struct NumbersIter:
          index: int
          stop: int

      extending Numbers:
          public function iter() -> NumbersIter:
              return NumbersIter(index = 0, stop = this.stop)

      extending NumbersIter:
          public mutable function next() -> bool:
              if this.index >= this.stop:
                  return false
              this.index += 1
              return true

          public function current() -> int:
              return this.index - 1

      function main() -> int:
          var total = 0
          for value in Numbers(stop = 3):
              total += value
          return total
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_struct_span_for_loop_as_mutable_alias
    source = <<~MT
      # module demo.for_ref

      struct Position:
          x: int
          y: int

      function apply(items: span[Position]) -> void:
          for item in items:
              item.x += 1
              item.y += 2
          return
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("apply")
  end

  def test_type_checks_parallel_collection_for_loop
    source = <<~MT
      # module demo.parallel_for

      struct Position:
          x: int
          y: int

      struct Velocity:
          x: int
          y: int

      function apply(entities: span[int], positions: span[Position], velocities: span[Velocity]) -> int:
          var total = 0
          for entity, position, velocity in entities, positions, velocities:
              position.x += velocity.x
              position.y += velocity.y
              total += entity
          return total
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("apply")
  end

  def test_type_checks_parallel_for_loop_in_async_function
    source = <<~MT
      # module demo.parallel_for

      import std.async as aio

      async function worker(values: span[int], other: span[int]) -> int:
          var total = 0
          for left, right in values, other:
              total += await aio.sleep(1)
              if left == right:
                  total += left
          return total
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("worker")
  end

  def test_type_checks_owned_foreign_release_after_let_else
    root_source = <<~MT
      # module demo.main

      import std.window as win

      function main() -> void:
          let window = win.create() else:
              return
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

  def test_rejects_let_else_without_terminating_else_body
    source = <<~MT
      # module demo.null_flow

      function read_handle(handle: ptr[int]?) -> int:
          let value = handle else:
              let fallback = 0
          unsafe:
              return read(value)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/else block for value must exit control flow/, error.message)
  end

  def test_type_checks_if_expression
    source = <<~MT
      # module demo.if_expr

      function main(ready: bool) -> int:
          return if ready: 1 else: 0
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_async_functions_and_await
    source = <<~MT
      # module demo.async_flow

      async function child() -> int:
          return 41

      async function parent() -> int:
          let value = await child()
          return value + 1
    MT

    result = check_program_source(source)

    assert_equal "Task[int]", result.root_analysis.functions.fetch("child").type.return_type.to_s
    assert_equal "Task[int]", result.root_analysis.functions.fetch("parent").type.return_type.to_s
  end

  def test_type_checks_async_main_with_std_async_import
    source = <<~MT
      # module demo.async_main

      import std.async as aio

      async function main() -> int:
          let waited = await aio.sleep(1)
          return waited + 42
    MT

    result = check_program_source(source)

    assert_equal "Task[int]", result.root_analysis.functions.fetch("main").type.return_type.to_s
  end

  def test_type_checks_async_main_without_explicit_async_runtime_import
    source = <<~MT
      # module demo.async_main

      async function child() -> int:
          return 41

      async function main() -> int:
          return await child()
    MT

    result = check_program_source(source)

    assert_equal "Task[int]", result.root_analysis.functions.fetch("main").type.return_type.to_s
  end

  def test_rejects_aio_without_explicit_async_runtime_import
    source = <<~MT
      # module demo.async_main

      async function main() -> int:
          let waited = await aio.sleep(1)
          return waited + 41
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/unknown name aio/, error.message)
  end

  def test_rejects_async_main_with_non_exit_return_type
    source = <<~MT
      # module demo.async_main

      import std.async as aio

      async function main() -> bool:
          return true
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/async main must return int or void/, error.message)
  end

  def test_rejects_await_outside_async_functions
    source = <<~MT
      # module demo.async_flow

      async function child() -> int:
          return 41

      function parent() -> int:
          return await child()
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/await is only allowed inside async functions/, error.message)
  end

  def test_type_checks_nested_await_expressions_in_async_functions
    source = <<~MT
      # module demo.async_flow

      import std.async as aio

      async function child() -> int:
          return 41

      async function main() -> int:
          return await child() + await aio.sleep(1) + 1
    MT

    result = check_program_source(source)

    assert_equal "Task[int]", result.root_analysis.functions.fetch("main").type.return_type.to_s
  end

  def test_type_checks_wait_with_direct_task_expression_root
    source = <<~MT
      # module demo.async_direct_task_root

      import std.async as aio

      async function child(bonus: int) -> int:
          return await aio.sleep(1) + bonus

      function main() -> int:
          return aio.wait(child(41))
    MT

    result = check_program_source(source)

    assert_equal "int", result.root_analysis.functions.fetch("main").type.return_type.to_s
  end

  def test_type_checks_async_methods
    source = <<~MT
      # module demo.async_methods

      import std.async as aio

      struct Counter:
          value: int

      extending Counter:
          async function read() -> int:
              return this.value

          async mutable function bump() -> void:
              this.value += 1

      async function main() -> int:
          var counter = Counter(value = 1)
          await counter.bump()
          return await counter.read()
    MT

    result = check_program_source(source)

    counter_type = result.root_analysis.types.fetch("Counter")
    read_method = result.root_analysis.methods.fetch(counter_type).fetch("read")
    bump_method = result.root_analysis.methods.fetch(counter_type).fetch("bump")

    assert_equal "Task[int]", read_method.type.return_type.to_s
    assert_equal "Task[void]", bump_method.type.return_type.to_s
    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_direct_function_identity_for_proc_parameter
    source = <<~MT
      # module demo.proc_coercion

      function apply(callback: proc(value: int) -> int, value: int) -> int:
          return callback(value)

      function times_two(value: int) -> int:
          return value * 2

      function main() -> int:
          return apply(times_two, 21)
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_await_in_if_expressions_inside_async_functions
    source = <<~MT
      # module demo.async_flow

      async function child() -> int:
          return 41

      async function parent(flag: bool) -> int:
          return if flag: await child() else: 0
    MT

    result = check_program_source(source)
    assert_equal true, result.root_analysis.functions.key?("parent")
  end

  def test_type_checks_control_flow_in_async_functions
    source = <<~MT
      # module demo.async_flow

      import std.async as aio

      async function parent(flag: bool) -> int:
          if flag:
              return 1
          return 0
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main") || result.root_analysis.functions.key?("parent")
  end

  def test_rejects_await_inside_if_statement_in_async_functions
    source = <<~MT
      # module demo.async_await_in_if

      import std.async as aio

      async function child() -> int:
          return 1

      async function parent() -> int:
          if true:
              return await child()
          return 0
    MT

    result = check_program_source(source)
    assert_equal true, result.root_analysis.functions.key?("parent")
  end

  def test_rejects_await_inside_if_condition_in_async_functions
    source = <<~MT
      # module demo.async_await_in_if_cond

      import std.async as aio

      async function child() -> bool:
          return true

      async function parent() -> int:
          if await child():
              return 1
          return 0
    MT

    result = check_program_source(source)
    assert_equal true, result.root_analysis.functions.key?("parent")
  end

  def test_type_checks_await_inside_while_condition_in_async_functions
    source = <<~MT
      # module demo.async_await_in_while_cond

      import std.async as aio

      async function ready() -> bool:
          return false

      async function parent() -> int:
          while await ready():
              return 1
          return 0
    MT

    result = check_program_source(source)
    assert_equal true, result.root_analysis.functions.key?("parent")
  end

  def test_type_checks_await_inside_match_discriminant_in_async_functions
    source = <<~MT
      # module demo.async_await_in_match

      import std.async as aio

      enum Mode: int
          a = 0
          b = 1

      async function mode() -> Mode:
          return Mode.a

      async function parent() -> int:
          match await mode():
              Mode.a:
                  return 1
              Mode.b:
                  return 2
    MT

    result = check_program_source(source)
    assert_equal true, result.root_analysis.functions.key?("parent")
  end

  def test_type_checks_await_inside_for_iterable_in_async_functions
    source = <<~MT
      # module demo.async_await_in_for_iterable

      import std.async as aio

      async function upper() -> int:
          return 3

      async function parent() -> int:
          var total = 0
          for i in 0..await upper():
              total += i
          return total
    MT

    result = check_program_source(source)
    assert_equal true, result.root_analysis.functions.key?("parent")
  end

  def test_type_checks_await_inside_short_circuit_and_or_in_async_functions
    source = <<~MT
      # module demo.async_short_circuit

      import std.async as aio

      async function t() -> bool:
          return true

      async function f() -> bool:
          return false

      async function parent() -> int:
          if await t() and await t():
              return 1
          if await f() or await t():
              return 2
          return 0
    MT

    result = check_program_source(source)
    assert_equal true, result.root_analysis.functions.key?("parent")
  end

  def test_type_checks_await_inside_assignment_target_in_async_functions
    source = <<~MT
      # module demo.async_assign_target

      import std.async as aio

      async function idx() -> int:
          return 0

      async function parent() -> int:
          var values = array[int, 1](0)
          values[await idx()] = 7
          return values[0]
    MT

    result = check_program_source(source)
    assert_equal true, result.root_analysis.functions.key?("parent")
  end

  def test_type_checks_await_in_while_body_in_async_functions
    source = <<~MT
      # module demo.async_await_in_while

      import std.async as aio

      async function child() -> int:
          return 1

      async function parent() -> int:
          var count = 0
          var i = 0
          while i < 3:
              count = count + await child()
              i = i + 1
          return count
    MT

    result = check_program_source(source)
    assert_equal true, result.root_analysis.functions.key?("parent")
  end

  def test_type_checks_defer_in_async_functions
    source = <<~MT
      # module demo.async_defer

      import std.async as aio

      async function main() -> int:
          var total = 0
          if true:
              defer:
                  total += 2
              await aio.sleep(1)
              total += 40
          return total
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_let_else_in_async_functions
    source = <<~MT
      # module demo.async_let_else

      import std.async as aio

      async function maybe_value(handle: ptr[int]?) -> ptr[int]?:
          return handle

      async function main(handle: ptr[int]?) -> int:
          let value = await maybe_value(handle) else:
              return 0
          unsafe:
              return read(value)
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_await_inside_async_defer_cleanup
    source = <<~MT
      # module demo.async_defer_await

      import std.async as aio

      async function main() -> int:
          var total = 0
          defer:
              total += await aio.sleep(1)
              total += 2
          return total
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_std_fmt_format_with_format_literal
    source = <<~MT
      # module demo.format

      import std.fmt as fmt
      import std.string as string

      function main(count: ubyte, delta: short, ticks: ulong) -> int:
          var text = fmt.format(f"count=\#{count} delta=\#{delta} ticks=\#{ticks} ok=\#{true}")
          defer text.release()
          return int<-text.len()
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_format_literal_as_general_str_expression
    source = <<~MT
      # module demo.format

      function length(text: str) -> ptr_uint:
          return text.len

      function main(count: int) -> int:
          let text = f"count=\#{count}"
          if length(f"ok=\#{true}") == 0:
              return 1
          return int<-text.len
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_format_heredoc_literal_as_general_str_expression
    source = <<~MT
      # module demo.format_heredoc

      function length(text: str) -> ptr_uint:
          return text.len

      function main(count: int, flag: bool) -> int:
          let text = f<<-FMT
            count=\#{count}
            precise=\#{if flag: 1.0 else: 2.0:.2}
          FMT
          if length(text) == 0:
              return 1
          return int<-text.len
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_rejects_general_format_literal_with_unsupported_interpolation_type
    source = <<~MT
      # module demo.format_bad

      struct Counter:
          value: int

      function main() -> ptr_uint:
          let text = f"counter=\#{Counter(value = 1)}"
          return text.len
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/formatted string interpolation supports .* got .*Counter/, error.message)
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

  def test_type_checks_format_precision_spec_on_float
    source = <<~MT
      # module demo.fmt_spec

      function main(pi: double, small: float) -> int:
          let formatted_pi = f"pi=\#{pi:.2}"
          let formatted_small = f"small=\#{small:.4}"
          if formatted_pi.len == 0 or formatted_small.len == 0:
              return 1
          return 0
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_rejects_precision_spec_on_non_float
    source = <<~MT
      # module demo.fmt_spec

      function main(count: int) -> int:
          let formatted = f"count=\#{count:.2}"
          if formatted.len == 0:
              return 1
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/precision.*float.*double|float.*double.*precision|format spec.*float.*double/i, error.message)
  end

  def test_type_checks_format_hex_spec_on_integer_and_integer_backed_enum
    source = <<~MT
      # module demo.fmt_hex

      enum State: uint
          idle = 0
          running = 1

      function main(count: int) -> int:
          let lower = f"lower=\#{count:x}"
          let upper = f"upper=\#{State.running:X}"
          if lower.len == 0 or upper.len == 0:
              return 1
          return 0
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_rejects_hex_spec_on_non_integer
    source = <<~MT
      # module demo.fmt_hex_bad

      function main(pi: double) -> int:
          let text = f"pi=\#{pi:x}"
          if text.len == 0:
              return 1
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/format spec ':x' and ':X'.*integer/i, error.message)
  end

  def test_type_checks_format_octal_and_binary_specs_on_integer_and_enum
    source = <<~MT
      # module demo.fmt_oct_bin

      flags Permission: uint
          read = 1 << 0
          write = 1 << 1

      function main(count: int) -> int:
          let octal = f"oct=\#{count:o}"
          let binary = f"bin=\#{Permission.read:B}"
          if octal.len == 0 or binary.len == 0:
              return 1
          return 0
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_rejects_octal_and_binary_specs_on_non_integer
    source = <<~MT
      # module demo.fmt_oct_bin_bad

      function main(pi: double) -> int:
          let octal = f"oct=\#{pi:o}"
          let binary = f"bin=\#{pi:b}"
          if octal.len == 0 or binary.len == 0:
              return 1
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/format spec ':o' and ':O'|format spec ':b' and ':B'/i, error.message)
  end

  def test_rejects_explicit_c_name_on_non_external_struct
    source = <<~MT
      # module demo.bad

      struct timespec = c"struct timespec":
          tv_sec: ptr_int
          tv_nsec: ptr_int
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/explicit C names are only allowed on external structs and unions/, error.message)
  end

  def test_rejects_wrong_return_type
    source = <<~MT
      # module demo.bad

      function main() -> int:
          return true
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/return type mismatch/, error.message)
  end

  def test_rejects_unknown_fields_in_struct_literals
    source = <<~MT
      # module demo.bad

      struct Ball:
          radius: float

      function main() -> int:
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
      # module demo.bad

      const width: int = 1
      const width: int = 2
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/duplicate value width/, error.message)
  end

  def test_rejects_function_named_after_reserved_primitive_type
    source = <<~MT
      # module demo.bad

      function double() -> int:
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/function double uses reserved built-in type name double/, error.message)
  end

  def test_rejects_parameter_named_after_reserved_primitive_type
    source = <<~MT
      # module demo.bad

      function main(byte: int) -> int:
          return byte
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/parameter byte uses reserved built-in type name byte/, error.message)
  end

  def test_rejects_local_named_after_reserved_primitive_type
    source = <<~MT
      # module demo.bad

      function main() -> int:
          let byte = 1
          return byte
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/local byte uses reserved built-in type name byte/, error.message)
  end

  def test_rejects_let_else_error_binding_named_after_reserved_primitive_type
    source = <<~MT
      # module demo.status_bad



      function parse(input: int) -> Result[int, int]:
          if input < 0:
              return Result[int, int].failure(error= 7)
          return Result[int, int].success(value= input + 1)

      function main(input: int) -> int:
          let value = parse(input) else as byte:
              return byte
          return value
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/let-else error binding byte uses reserved built-in type name byte/, error.message)
  end

  def test_rejects_for_binding_named_after_reserved_primitive_type
    source = <<~MT
      # module demo.bad

      function main() -> int:
          for byte in 0..2:
              return byte
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/for binding byte uses reserved built-in type name byte/, error.message)
  end

  def test_rejects_proc_parameter_named_after_reserved_primitive_type
    source = <<~MT
      # module demo.bad

      function main() -> int:
          let callback = proc(byte: int) -> int:
              return byte
          return callback(1)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/parameter byte uses reserved built-in type name byte/, error.message)
  end

  def test_allows_import_alias_named_after_reserved_primitive_type
    source = <<~MT
      # module demo.bad

      import std.async as str

      function main() -> int:
          return 0
    MT

    program = check_program_source(source)
    assert_equal true, program.root_analysis.functions.key?("main")
  end

  def test_rejects_type_parameter_named_after_reserved_primitive_type
    source = <<~MT
      # module demo.bad

      function identity[byte](value: byte) -> byte:
          return value
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/type parameter byte uses reserved built-in type name byte/, error.message)
  end

  def test_rejects_type_parameter_named_after_non_primitive_builtin_type
    source = <<~MT
      # module demo.bad

      function identity[span](value: span) -> span:
          return value
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/type parameter span uses reserved built-in type name span/, error.message)
  end

  def test_rejects_type_declaration_named_after_reserved_builtin_type
    source = <<~MT
      # module demo.bad

      struct span:
          value: int
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/type span uses reserved built-in type name span/, error.message)
  end

  def test_rejects_enum_member_named_after_reserved_builtin_type
    source = <<~MT
      # module demo.bad

      enum Scalar: int
          float = 0
          ok = 1
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/member Scalar float uses reserved built-in type name float/, error.message)
  end

  def test_rejects_struct_field_named_after_reserved_builtin_type
    source = <<~MT
      # module demo.bad

      struct Frame:
          ptr_uint: int
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/field Frame ptr_uint uses reserved built-in type name ptr_uint/, error.message)
  end

  def test_rejects_variant_arm_named_after_reserved_builtin_type
    source = <<~MT
      # module demo.bad

      variant Event:
          span
          payload(value: int)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/arm Event span uses reserved built-in type name span/, error.message)
  end

  def test_rejects_variant_field_named_after_reserved_builtin_type
    source = <<~MT
      # module demo.bad

      variant Event:
          payload(Result: int)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/field Event.payload Result uses reserved built-in type name Result/, error.message)
  end

  def test_type_checks_ffi_declaration_surface
    source = <<~MT
      # module demo.ffi

      enum State: ubyte
          idle = 0
          moving = 1

      flags WindowFlags: uint
          visible = 1 << 0
          fullscreen = 1 << 1

      union Number:
          i: int
          f: float

      opaque SDL_Window
      type Seconds = float
      external function get_ticks() -> Seconds
      external function open_window(title: cstr) -> SDL_Window?

      function main() -> int:
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
      # module demo.callbacks

      type LogCallback = fn(level: int, message: cstr) -> void
      external function set_callback(callback: LogCallback) -> void

      function on_log(level: int, message: cstr) -> void:
          return

      function main() -> int:
          set_callback(on_log)
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("LogCallback")
    assert_equal true, result.functions.key?("set_callback")
    assert_equal true, result.functions.key?("on_log")
  end

  def test_type_checks_callable_value_storage_and_indirect_calls
    source = <<~MT
      # module demo.callable_values

      struct Entry:
          callback: fn(value: float) -> float

      function identity(value: int) -> int:
          return value

      function ease(value: float) -> float:
          return value + 2.0

      function main() -> int:
          let callbacks = array[fn(value: int) -> int, 1](identity)
          let entry = Entry(callback = ease)
          let callback: fn(value: float) -> float = entry.callback
          let left = callbacks[0](1)
          let right = callback(1.0)
          return left + int<-right
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Entry")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_imported_function_callable_values
    root_source = <<~MT
      # module demo.main

      import std.ease as ease

      struct Entry:
          callback: fn(value: int) -> int

      function main() -> int:
          let callbacks = array[fn(value: int) -> int, 1](ease.times_two)
          let entry = Entry(callback = ease.times_two)
          return callbacks[0](3) + entry.callback(4)
    MT

    imported_sources = {
      "std/ease.mt" => <<~MT,
        # module std.ease

        public function times_two(value: int) -> int:
            return value * 2
      MT
    }

    result = check_program_source(root_source, imported_sources).root_analysis

    assert_equal true, result.types.key?("Entry")
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

  def test_type_checks_proc_closure_capture_and_param_calls
    source = <<~MT
      # module demo.proc_values

      function apply(callback: proc(value: int) -> int, value: int) -> int:
          return callback(value)

      function main() -> int:
          let offset = 4
          let callback = proc(value: int) -> int:
              return value * 2 + offset
          return apply(callback, 3)
    MT

    result = check_source(source)

    assert_equal "proc(int) -> int", result.functions.fetch("apply").type.params.fetch(0).type.to_s
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_proc_storage_in_struct_fields
    source = <<~MT
      # module demo.proc_field

      struct Holder:
          callback: proc(value: int) -> int

      function call(holder: Holder, value: int) -> int:
          return holder.callback(value)

      function main() -> int:
          let offset = 3
          let callback = proc(value: int) -> int:
              return value + offset
          let holder = Holder(callback = callback)
          return call(holder, 4)
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Holder")
    assert_equal true, result.functions.key?("call")
  end

  def test_type_checks_proc_return_types
    source = <<~MT
      # module demo.proc_return

      function factory(offset: int) -> proc(value: int) -> int:
          return proc(value: int) -> int:
              return value + offset

      function main() -> int:
          let callback = factory(2)
          return callback(40)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("factory")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_proc_assignment
    source = <<~MT
      # module demo.proc_assign

      struct Holder:
          callback: proc(value: int) -> int

      function main() -> int:
          let ca = proc(value: int) -> int:
              return value + 1
          let cb = proc(value: int) -> int:
              return value + 2
          let a = Holder(callback = ca)
          var b = Holder(callback = cb)
          b = a
          return b.callback(1)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_proc_field_assignment
    source = <<~MT
      # module demo.proc_field_assign

      struct Holder:
          callback: proc(value: int) -> int

      function main() -> int:
          let ca = proc(value: int) -> int:
              return value + 1
          var h = Holder(callback = ca)
          let cb = proc(value: int) -> int:
              return value + 2
          h.callback = cb
          return h.callback(1)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_proc_var_reassign
    source = <<~MT
      # module demo.proc_var_reassign

      function main() -> int:
          var callback = proc(value: int) -> int:
              return value + 1
          callback = proc(value: int) -> int:
              return value + 2
          return callback(0)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_async_function_with_proc_parameter
    source = <<~MT
      # module demo.async_proc_param

      async function run(callback: proc(value: int) -> int) -> int:
          return callback(1)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("run")
  end

  def test_type_checks_proc_expression_inside_async_function
    source = <<~MT
      # module demo.async_proc_expr

      async function run() -> int:
          let callback = proc(value: int) -> int:
              return value + 1
          return callback(1)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("run")
  end

  def test_type_checks_foreign_defs_with_boundary_mappings
    root_source = <<~MT
      # module demo.main

      import std.raylib as rl

      function main(path: str, data: span[ubyte]) -> int:
          var data_size = 0
          rl.init_window(800, 450, "Demo")
          let loaded = rl.load_file_data(path, data_size)
          let saved = rl.save_file_data(path, data)
          if loaded != null and saved:
              return data_size
          return 0
    MT

    imported_sources = {
      "std/c/raylib.mt" => <<~MT,
        # module std.c.raylib
        external
        include "raylib.h"

        external function InitWindow(width: int, height: int, title: cstr) -> void
        external function LoadFileData(file_name: cstr, data_size: ptr[int]) -> ptr[ubyte]?
        external function SaveFileData(file_name: cstr, data: ptr[ubyte], bytes: int) -> bool
      MT
      "std/raylib.mt" => <<~MT,
        # module std.raylib

        import std.c.raylib as c

        public foreign function init_window(width: int, height: int, title: str as cstr) -> void = c.InitWindow
        public foreign function load_file_data(file_name: str as cstr, out data_size: int) -> ptr[ubyte]? = c.LoadFileData
        public foreign function save_file_data(file_name: str as cstr, data: span[ubyte]) -> bool = c.SaveFileData(file_name, data.data, int<-data.len)
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("rl")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_defs_with_span_str_to_span_cstr_boundary
    root_source = <<~MT
      # module demo.main

      import std.sample as sample

      function main() -> void:
          var labels = array[str, 3]("Play", "Options", "Quit")
          var active = 0
          sample.use_names(labels, active)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function UseNames(names: ptr[cstr], count: int, active: ptr[int]) -> int
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function use_names(names: span[str] as span[cstr], inout active: int) -> int = c.UseNames(names.data, int<-names.len, active)
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("sample")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_defs_with_span_str_to_span_ptr_char_boundary
    root_source = <<~MT
      # module demo.main

      import std.sample as sample

      function main() -> void:
          var labels = array[str, 3]("Play", "Options", "Quit")
          var active = 0
          sample.use_names(labels, active)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function UseNames(names: ptr[ptr[char]], count: int, active: ptr[int]) -> int
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function use_names(names: span[str] as span[ptr[char]], inout active: int) -> int = c.UseNames(names.data, int<-names.len, active)
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("sample")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_defs_with_span_str_temp_marshalling_in_return_expression
    root_source = <<~MT
      # module demo.main

      import std.sample as sample

      function main() -> int:
          var labels = array[str, 3]("12", "34", "56")
          return sample.count_names(labels)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function CountNames(names: ptr[ptr[char]], count: int) -> int
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function count_names(names: span[str] as span[ptr[char]]) -> int = c.CountNames(names.data, int<-names.len)
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("sample")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_nested_foreign_defs_with_span_str_temp_marshalling_in_inline_context
    root_source = <<~MT
      # module demo.main

      import std.sample as sample

      function keep(value: int) -> int:
          return value

      function main() -> int:
          var labels = array[str, 3]("12", "34", "56")
          return keep(sample.count_names(labels))
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function CountNames(names: ptr[ptr[char]], count: int) -> int
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function count_names(names: span[str] as span[ptr[char]]) -> int = c.CountNames(names.data, int<-names.len)
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("sample")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_nested_foreign_defs_with_multi_use_mapping_in_inline_context
    root_source = <<~MT
      # module demo.main

      import std.sample as sample

      function keep(value: int) -> int:
          return value

      function main() -> int:
          return keep(sample.pair_sum(1 + 2))
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function PairSum(left: int, right: int) -> int
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function pair_sum(value: int) -> int = c.PairSum(value, value)
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("sample")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_nested_foreign_defs_in_if_expression_and_short_circuit_contexts
    root_source = <<~MT
      # module demo.main

      import std.sample as sample

      function main() -> int:
          var labels = array[str, 3]("12", "34", "56")
          let total = if true: sample.count_names(labels) else: 0
          if false and sample.pair_sum(1 + 2) > 0:
              return 1
          return total
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function CountNames(names: ptr[ptr[char]], count: int) -> int
        external function PairSum(left: int, right: int) -> int
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function count_names(names: span[str] as span[ptr[char]]) -> int = c.CountNames(names.data, int<-names.len)
        public foreign function pair_sum(value: int) -> int = c.PairSum(value, value)
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("sample")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_mapping_expression_that_already_references_params
    root_source = <<~MT
      # module demo.main

      import std.sample as sample

      function main() -> int:
          return sample.pair_sum_plus_one(3)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function PairSum(left: int, right: int) -> int
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function pair_sum_plus_one(value: int) -> int = c.PairSum(value, value) + 1
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("sample")
    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_foreign_defs_with_str_to_ptr_char_boundary
    root_source = <<~MT
      # module demo.main

      import std.sample as sample

      function main() -> void:
          sample.show("demo")
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function Show(text: ptr[char]) -> void
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function show(text: str as ptr[char]) -> void = c.Show
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(root_source, imported_sources)
    end

    assert_match(/cannot map str as ptr\[char\]/, error.message)
  end

  def test_type_checks_foreign_defs_with_span_cstr_to_span_ptr_char_boundary_without_scratch
    root_source = <<~MT
      # module demo.main

      import std.sample as sample

      function main() -> void:
          var labels = array[cstr, 3]("Play", "Options", "Quit")
          var active = 0
          sample.use_names(labels, active)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function UseNames(names: ptr[ptr[char]], count: int, active: ptr[int]) -> int
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function use_names(names: span[cstr] as span[ptr[char]], inout active: int) -> int = c.UseNames(names.data, int<-names.len, active)
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("sample")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_defs_with_string_literal_without_using_scratch
    root_source = <<~MT
      # module demo.main

      import std.raylib as rl

      function main() -> void:
          rl.init_window(800, 450, "Demo")
    MT

    imported_sources = {
      "std/c/raylib.mt" => <<~MT,
        # module std.c.raylib
        external
        include "raylib.h"

        external function InitWindow(width: int, height: int, title: cstr) -> void
      MT
      "std/raylib.mt" => <<~MT,
        # module std.raylib

        import std.c.raylib as c

        public foreign function init_window(width: int, height: int, title: str as cstr) -> void = c.InitWindow
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("rl")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_defs_with_existing_cstr_without_using_scratch
    root_source = <<~MT
      # module demo.main

      import std.raylib as rl

      function main() -> void:
          let title = c"Demo"
          rl.init_window(800, 450, title)
    MT

    imported_sources = {
      "std/c/raylib.mt" => <<~MT,
        # module std.c.raylib
        external
        include "raylib.h"

        external function InitWindow(width: int, height: int, title: cstr) -> void
      MT
      "std/raylib.mt" => <<~MT,
        # module std.raylib

        import std.c.raylib as c

        public foreign function init_window(width: int, height: int, title: str as cstr) -> void = c.InitWindow
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("rl")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_defs_with_identity_pointer_projections
    root_source = <<~MT
      # module demo.main

      import std.mem as mem

      function main(buffer: ptr[char]) -> cstr:
          let bytes = mem.allocate_bytes(16)
          mem.release_bytes(bytes)
          mem.set_label(buffer)
          return mem.get_label()
    MT

    imported_sources = {
      "std/c/mem.mt" => <<~MT,
        # module std.c.mem
        external
        include "mem.h"

        external function AllocateBytes(size: ptr_uint) -> ptr[void]
        external function ReleaseBytes(memory: ptr[void]) -> void
        external function SetLabel(label: cstr) -> void
        external function GetLabel() -> ptr[char]
      MT
      "std/mem.mt" => <<~MT,
        # module std.mem

        import std.c.mem as c

        public foreign function allocate_bytes(size: ptr_uint) -> ptr[ubyte] = c.AllocateBytes
        public foreign function release_bytes(memory: ptr[ubyte]) -> void = c.ReleaseBytes
        public foreign function set_label(label: ptr[char]) -> void = c.SetLabel
        public foreign function get_label() -> cstr = c.GetLabel
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("mem")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_defs_with_opaque_handle_projections
    root_source = <<~MT
      # module demo.main

      import std.window as win

      function main() -> int:
          let window = win.create()
          if window != null:
              win.destroy(window)
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
        public foreign function destroy(window: Window?) -> void = c.DestroyWindow
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("win")
    assert_equal true, result.functions.key?("main")
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

  def test_type_checks_external_opaque_handle_projection_against_typed_pointer_signatures
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

        opaque RawWindow = c"RawWindow"

        external function CreateWindow() -> ptr[RawWindow]?
        external function DestroyWindow(window: ptr[RawWindow]) -> void
      MT
      "std/window.mt" => <<~MT,
        # module std.window

        import std.c.window as c

        public opaque Window = c"RawWindow"

        public foreign function create() -> Window? = c.CreateWindow
        public foreign function destroy(consuming window: Window) -> void = c.DestroyWindow
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("win")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_out_opaque_handle_projection_against_typed_pointer_signatures
    root_source = <<~MT
      # module demo.main

      import std.window as win

      function main() -> int:
          var window: win.Window
          if not win.create(window):
              return 1
          defer:
              win.destroy(window)
          return 0
    MT

    imported_sources = {
      "std/c/window.mt" => <<~MT,
        # module std.c.window
        external
        include "window.h"

        opaque RawWindow = c"RawWindow"

        external function CreateWindow(window: ptr[ptr[RawWindow]]?) -> bool
        external function DestroyWindow(window: ptr[RawWindow]) -> void
      MT
      "std/window.mt" => <<~MT,
        # module std.window

        import std.c.window as c

        public opaque Window = c"RawWindow"

        public foreign function create(out window: Window) -> bool = c.CreateWindow
        public foreign function destroy(window: Window) -> void = c.DestroyWindow
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

  def test_type_checks_owned_foreign_release_inside_defer_expression
    root_source = <<~MT
      # module demo.main

      import std.window as win

      function main() -> void:
          let window = win.create()
          if window != null:
              defer win.destroy(window)
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

  def test_type_checks_owned_foreign_release_inside_defer_block
    root_source = <<~MT
      # module demo.main

      import std.window as win

      function main() -> void:
          let window = win.create()
          if window != null:
              defer:
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

  def test_rejects_owned_foreign_release_in_local_initializer
    root_source = <<~MT
      # module demo.main

      import std.window as win

      function main() -> void:
          let window = win.create()
          if window != null:
              let released = win.destroy(window)
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

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(root_source, imported_sources)
    end

    assert_match(/consuming foreign calls must be top-level expression statements/, error.message)
  end

  def test_rejects_foreign_defs_that_drop_cstr_mutability
    root_source = <<~MT
      # module demo.main

      import std.mem as mem

      function main(label: cstr) -> void:
          mem.write_label(label)
    MT

    imported_sources = {
      "std/c/mem.mt" => <<~MT,
        # module std.c.mem
        external
        include "mem.h"

        external function WriteLabel(label: ptr[char]) -> void
      MT
      "std/mem.mt" => <<~MT,
        # module std.mem

        import std.c.mem as c

        public foreign function write_label(label: cstr) -> void = c.WriteLabel
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(root_source, imported_sources)
    end

    assert_match(/argument label to WriteLabel expects ptr\[char\], got cstr/, error.message)
  end

  def test_rejects_out_argument_outside_foreign_call
    source = <<~MT
      # module demo.bad

      function write(value: int) -> int:
          return value

      function main() -> int:
          var number = 1
          return write(out number)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/out is only allowed for foreign call arguments/, error.message)
  end

  def test_type_checks_mixed_numeric_binary_operators_with_arithmetic_conversion
    source = <<~MT
      # module demo.numeric_conversions

      function sum() -> double:
          return 1 + 2.5

      function before_limit() -> bool:
          return 3 < 3.5

      function main() -> int:
          if before_limit():
              return int<-sum()
          return 0
    MT

    result = check_source(source)

    assert_equal "double", result.functions.fetch("sum").type.return_type.to_s
    assert_equal "bool", result.functions.fetch("before_limit").type.return_type.to_s
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_left_biased_float_literals_against_float_operands
    source = <<~MT
      # module demo.float_literal_alignment

      struct Pair:
          x: float
          y: float

      function inverse(value: float) -> float:
          let scaled = 1.0 / value
          return scaled

      function main() -> int:
          let denom: float = 4.0
          let pair = Pair(x = 1.0 / denom, y = -2.0 / denom)
          if inverse(denom) < pair.x:
              return 1
          return 0
    MT

    result = check_source(source)

    assert_equal "float", result.functions.fetch("inverse").type.return_type.to_s
    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_mixed_signed_and_unsigned_integer_arithmetic_without_explicit_cast
    source = <<~MT
      # module demo.bad

      function main() -> int:
          let left: int = 1
          let right: uint = 2
          let sum = left + right
          return sum
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/operator \+ requires compatible numeric types/, error.message)
  end

  def test_type_checks_span_construction_and_field_access
    source = <<~MT
      # module demo.spans

      function first(items: span[int]) -> int:
          if items.len == 0:
              return 0
          unsafe:
              return read(items.data)

      function main() -> int:
          var value = 7
          let items = span[int](data = ptr_of(value), len = 1)
          return first(items)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("first")
    assert_equal true, result.functions.key?("main")
    assert_equal "span[int]", result.functions.fetch("first").type.params.first.type.to_s
  end

  def test_type_checks_safe_span_indexing_and_element_assignment
    source = <<~MT
      # module demo.spans

      function bump(items: span[int]) -> int:
          let first = items[0]
          items[0] = first + 2
          return items[0]

      function main() -> int:
          var value = 7
          let items = span[int](data = ptr_of(value), len = 1)
          return bump(items)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("bump")
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
    make_binding = result.methods.fetch(box_type).fetch("make")

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

          mutable function set(value: T) -> void:
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
    assert_equal ["T"], methods.fetch("zero").type_params
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

    assert_equal ["T"], methods.fetch("create").type_params
    assert_equal ["T"], methods.fetch("with_default").type_params
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_named_constants_in_integer_type_argument_slots
    source = <<~MT
      # module demo.named_const_type_args

      const BASE: int = 28
      const CAPACITY: int = BASE + 4

      function capacity_of[N](buffer: str_buffer[N]) -> ptr_uint:
          return buffer.capacity()

      function main() -> int:
          var buffer: str_buffer[CAPACITY]
          var values = zero[array[int, CAPACITY]]
          values[0] = int<-capacity_of[CAPACITY](buffer)
          return values[0]
    MT

    result = check_source(source)

    assert_equal 32, result.values.fetch("CAPACITY").const_value
    assert_equal ["N"], result.functions.fetch("capacity_of").type_params
    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_removed_builtin_ok_and_err_helpers
    ok_source = <<~MT
      # module demo.ok

      function main() -> int:
          let value = ok(7)
          return 0
    MT

    ok_error = assert_raises(MilkTea::SemaError) do
      check_source(ok_source)
    end

    assert_match(/unknown callable ok/, ok_error.message)

    err_source = <<~MT
      # module demo.err

      function main() -> int:
          let value = err(7)
          return 0
    MT

    err_error = assert_raises(MilkTea::SemaError) do
      check_source(err_source)
    end

    assert_match(/unknown callable err/, err_error.message)
  end

  def test_type_checks_fatal_statement_with_string_message
    source = <<~MT
      # module demo.fatal

      function main() -> int:
          fatal("bad state")
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_passing_stored_str_to_cstr_parameter_without_explicit_boundary
    source = <<~MT
      # module demo.string_boundary

      external function set_text(value: cstr) -> void

      function main() -> void:
          let text: str = "hello"
          set_text(text)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/argument value to set_text expects cstr, got str/, error.message)
  end

  def test_type_checks_contextual_string_literals_for_cstr_surfaces
    source = <<~MT
      # module demo.literal_cstr

      external function set_text(value: cstr) -> void

      function main() -> cstr:
          let title: cstr = "hello"
          let labels = array[cstr, 2]("Layout", "Palette")
          set_text("world")
          set_text(labels[0])
          return title
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_real_str_len_slice_and_cstr_conversion
    source = <<~MT
      # module demo.str_methods

      import std.str as text_ops
      import std.mem.arena as arena

      function main() -> int:
          var scratch = arena.create(64)
          defer scratch.release()

          let text: str = "hello world"
          let part = text.slice(6, 5)
          let copied = part.to_cstr(ref_of(scratch))

          if text.len == ptr_uint<-11 and part.len == ptr_uint<-5:
              return int<-part.len
          fatal(copied)
          return 0
    MT

            program = check_program_source(source)

            assert_equal true, program.analyses_by_module_name.key?("demo.str_methods")
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

  def test_type_checks_exhaustive_match_statement_over_enum
    source = <<~MT
      # module demo.match

      enum EventKind: ubyte
          quit = 1
          resize = 2

      function dispatch(kind: EventKind) -> int:
          match kind:
              EventKind.quit:
                  return 0
              EventKind.resize:
                  return 1

      function main() -> int:
          return dispatch(EventKind.resize)
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("EventKind")
    assert_equal true, result.functions.key?("dispatch")
  end

  def test_type_checks_for_loops_over_range_and_span
    source = <<~MT
      # module demo.for_loops

      function scan(items: span[int]) -> int:
          for i in 0..items.len:
              let index: ptr_uint = i

          for item in items:
              let value: int = item

          return 0
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("scan")
  end

  def test_type_checks_break_and_continue_inside_loop_bodies
    source = <<~MT
      # module demo.loop_control

      enum Step: ubyte
          skip = 1
          keep = 2
          stop = 3

      function add(target: ptr[int], amount: int) -> void:
          unsafe:
              read(target) += amount

      function main() -> int:
          var total = 0
          for step in array[Step, 4](Step.keep, Step.skip, Step.keep, Step.stop):
              defer add(ptr_of(total), 1)
              match step:
                  Step.skip:
                      continue
                  Step.keep:
                      total += 10
                  Step.stop:
                      break
          return total
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_break_inside_nested_loop_in_defer_block
    source = <<~MT
      # module demo.defer_loop

      function main() -> int:
          for outer in 0..1:
              defer:
                  while true:
                      break
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_return_inside_defer_block
    source = <<~MT
      # module demo.defer_return

      function main() -> int:
          defer:
              return 1
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/return is not allowed inside defer blocks/, error.message)
  end

  def test_rejects_outer_loop_continue_inside_defer_block
    source = <<~MT
      # module demo.defer_continue

      function main() -> int:
          for outer in 0..1:
              defer:
                  continue
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/continue must be inside a loop/, error.message)
  end

  def test_type_checks_layout_queries_and_static_assert
    source = <<~MT
      # module demo.layout

      struct Header:
          magic: array[ubyte, 4]
          version: ushort

      static_assert(size_of(Header) == 6, "Header size should stay stable")

      function main() -> ptr_uint:
          return offset_of(Header, version) + align_of(Header)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_offsetof_unknown_field
    source = <<~MT
      # module demo.layout

      struct Header:
          version: ushort

      function main() -> ptr_uint:
          return offset_of(Header, missing)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/unknown field demo\.layout\.Header\.missing/, error.message)
  end

  def test_rejects_static_assert_with_non_literal_message
    source = <<~MT
      # module demo.layout

      const MESSAGE: cstr = c"layout must hold"

      function main() -> int:
          static_assert(true, MESSAGE)
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/static_assert message must be a string literal/, error.message)
  end

  def test_rejects_static_assert_with_non_constant_condition
    source = <<~MT
      # module demo.layout

      function main(count: int) -> int:
          static_assert(count > 0, "count must stay positive")
          return count
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/static_assert condition must be a compile-time bool constant/, error.message)
  end

  def test_type_checks_layout_query_const_reuse_in_static_assert_and_type_argument_slots
    source = <<~MT
      # module demo.layout_const

      struct Header:
          magic: array[ubyte, 4]
          version: ushort

      const HEADER_SIZE: ptr_uint = size_of(Header)
      static_assert(HEADER_SIZE == 6, "Header size should stay stable")

      function main() -> int:
          var values: array[int, HEADER_SIZE]
          return 0
    MT

    result = check_source(source)

    assert_equal 6, result.values.fetch("HEADER_SIZE").const_value
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_relational_const_reuse_in_static_assert
    source = <<~MT
      # module demo.static_assert_const_compare

      const OK: bool = 1 < 2
      static_assert(OK, "ok")

      function main() -> int:
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.values.fetch("OK").const_value
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_packed_and_aligned_struct_layout
    source = <<~MT
      # module demo.layout

      packed struct Header:
          tag: ubyte
          value: uint

      align(16) struct Mat4:
          data: array[float, 16]

      static_assert(size_of(Header) == 5, "Header should stay packed")
      static_assert(offset_of(Header, value) == 1, "Header.value offset drifted")
      static_assert(align_of(Mat4) == 16, "Mat4 alignment drifted")

      function main() -> int:
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
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

  def test_rejects_reinterpret_of_array_types
    source = <<~MT
      # module demo.bits

      function main() -> int:
          let values = array[ubyte, 4](1, 2, 3, 4)
          unsafe:
              let bits = reinterpret[uint](values)
              return int<-bits
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/reinterpret requires non-array concrete sized types/, error.message)
  end

  def test_type_checks_explicit_casts_from_enum_and_flags_backing_values
    source = <<~MT
      # module demo.cast_values

      enum State: ubyte
          idle = 0

      flags Gesture: int
          tap = 1

      function main() -> int:
          let state = int<-State.idle
          let gesture = uint<-Gesture.tap
          return state + int<-gesture
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_same_width_enum_and_flags_arguments_without_explicit_cast_for_extern_calls
    source = <<~MT
      # module demo.call_values

      enum State: ubyte
          idle = 0

      flags Gesture: int
          tap = 1

      external function takes_uint(value: uint) -> int
      external function takes_ubyte(value: ubyte) -> int

      function main() -> int:
          takes_uint(Gesture.tap)
          takes_ubyte(State.idle)
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_integer_literals_against_expected_float_boundaries
    source = <<~MT
      # module demo.literal_float_context

      struct Point:
          x: float
          y: float

      function takes_float(value: float) -> void:
          return

      function main() -> int:
          let baseline: float = 0
          let point = Point(x = 0, y = 1)
          takes_float(0)
          return int<-(baseline + point.x)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_contextual_integer_to_float_for_non_external_call_and_field_boundaries
    source = <<~MT
      # module demo.non_external_numeric_strict

      struct Point:
          x: float

      function takes_float(value: float) -> void:
          return

      function main() -> int:
          let value = 7
          takes_float(value)
          let point = Point(x = value)
          let radians: float = value * 0.5
          takes_float(value * 0.5)
          return int<-(point.x + radians)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_contextual_integer_to_float_for_local_assignment_and_return
    source = <<~MT
      # module demo.contextual_int_to_float

      struct Point:
          x: float

      function project(value: int) -> float:
          var total: float = value
          total = value + 1
          total += value + 2
          total -= value + 3
          var point = Point(x = 0.0)
          point.x = value + 4
          return value + 5

      function main() -> int:
          let value = 4
          let baseline: float = value
          return int<-(project(value) + baseline)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("project")
  end

  def test_rejects_contextual_float_narrowing_without_float_expected_context
    source = <<~MT
      # module demo.contextual_float_expected_only

      function main() -> int:
          var angle = 1
          let radians = angle * 0.5
          let target: float = radians
          return int<-target
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/cannot assign double to target: expected float/, error.message)
  end

  def test_rejects_contextual_float_narrowing_for_integer_compound_assignment_targets
    source = <<~MT
      # module demo.contextual_float_compound_reject

      function main() -> int:
          var total = 1
          total += 0.5
          return total
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/operator \+= requires matching numeric types, got int and double/, error.message)
  end

  def test_type_checks_lossless_numeric_coercion_for_external_boundaries
    program = check_program_source(
      <<~MT,
        # module demo.external_numeric

        import std.c.demo as demo

        function main() -> int:
            let shade: ubyte = 200
            let count: short = 120
            let alpha: float = 0.5
            var color = demo.Color(r = shade, g = 0, b = 0, a = 255)
            color.g = shade
            demo.set_count(count)
            demo.set_opacity(alpha)
            return 0
      MT
      {
        "std/c/demo.mt" => <<~MT,
          # module std.c.demo
          external
          struct Color:
              r: short
              g: short
              b: ubyte
              a: ubyte

          external function set_count(value: int) -> void
          external function set_opacity(value: double) -> void
        MT
      },
    )

    assert_equal true, program.analyses_by_module_name.key?("demo.external_numeric")
  end

  def test_type_checks_exact_compile_time_numeric_coercion_at_typed_and_external_boundaries
    program = check_program_source(
      <<~MT,
        # module demo.exact_numeric_constants

        import std.c.demo as demo

        const channel_value: int = 255

        function main() -> int:
            let whole: int = 2.0
            let local_opaque = channel_value
            demo.set_channel(local_opaque)
            demo.set_channel(demo.OPAQUE)
            demo.set_scale(200)
            return whole
      MT
      {
        "std/c/demo.mt" => <<~MT,
          # module std.c.demo
          external
          const OPAQUE: int = 255

          external function set_channel(value: ubyte) -> void
          external function set_scale(value: float) -> void
        MT
      },
    )

    assert_equal true, program.analyses_by_module_name.key?("demo.exact_numeric_constants")
  end

  def test_rejects_lossy_numeric_coercion_for_external_function_boundaries
    error = assert_raises(MilkTea::SemaError) do
      check_program_source(
        <<~MT,
          # module demo.external_numeric_lossy_call

          import std.c.demo as demo

          function main() -> int:
              var channel = 200
              demo.set_scale(channel)
              return 0
        MT
        {
          "std/c/demo.mt" => <<~MT,
            # module std.c.demo
            external
            external function set_scale(value: float) -> void
          MT
        },
      )
    end

    assert_match(/argument value to set_scale expects float, got int/, error.message)
  end

  def test_rejects_lossy_numeric_coercion_for_external_field_boundaries
    error = assert_raises(MilkTea::SemaError) do
      check_program_source(
        <<~MT,
          # module demo.external_numeric_lossy_field

          import std.c.demo as demo

          function main() -> int:
              var channel = 200
              var color = demo.Color(r = 0, g = 0, b = 0, a = 255)
              color.g = channel
              return 0
        MT
        {
          "std/c/demo.mt" => <<~MT,
            # module std.c.demo
            external
            struct Color:
                r: ubyte
                g: ubyte
                b: ubyte
                a: ubyte
          MT
        },
      )
    end

    assert_match(/cannot assign int to ubyte/, error.message)
  end

  def test_rejects_inexact_compile_time_numeric_coercion_for_typed_boundaries
    error = assert_raises(MilkTea::SemaError) do
      check_source(
        <<~MT,
          # module demo.inexact_numeric_constants

          function main() -> int:
              let whole: int = 2.5
              return whole
        MT
      )
    end

    assert_match(/cannot assign double to whole: expected int/, error.message)
  end

  def test_type_checks_import_of_public_declarations_and_methods
    source = <<~MT
      # module demo.main

      import demo.lib as lib

      function main() -> int:
          let counter = lib.Counter(value = lib.answer)
          return counter.read()
    MT

    imported = {
      "demo/lib.mt" => <<~MT,

# module demo.lib

public const answer: int = 7

public struct Counter:
    value: int

extending Counter:
    public function read() -> int:
        return this.value

    function times_two() -> int:
        return this.value * 2
      MT
    }

    result = check_program_source(source, imported).root_analysis

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_import_of_public_methods_on_imported_receiver_types
    source = <<~MT
      # module demo.main

      import demo.ext as ext

      function main() -> int:
          let counter = ext.make_counter()
          return counter.read()
    MT

    imported = {
      "demo/dep.mt" => <<~MT,
        # module demo.dep

        public struct Counter:
            value: int
      MT
      "demo/ext.mt" => <<~MT,
        # module demo.ext

        import demo.dep as dep

        extending dep.Counter:
            public function read() -> int:
                return this.value

        public function make_counter() -> dep.Counter:
            return dep.Counter(value = 7)
      MT
    }

    result = check_program_source(source, imported).root_analysis

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_methods_on_opaque_receivers
    source = <<~MT
      # module demo.opaque_methods

      opaque Handle

      extending Handle:
          public function ready() -> bool:
              return true

      function main(handle: Handle) -> bool:
          return handle.ready()
    MT

    result = check_program_source(source).root_analysis

    assert_equal true, result.functions.key?("main")
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

  def test_rejects_import_of_private_module_member
    source = <<~MT
      # module demo.main

      import demo.lib as lib

      function main() -> int:
          return lib.hidden
    MT

    imported = {
      "demo/lib.mt" => <<~MT,
        # module demo.lib

        const hidden: int = 7
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source, imported)
    end

    assert_match(/lib\.hidden is private to module demo\.lib/, error.message)
  end

  def test_rejects_import_of_private_method
    source = <<~MT
      # module demo.main

      import demo.lib as lib

      function main() -> int:
          let counter = lib.Counter(value = 1)
          counter.times_two()
          return 0
    MT

    imported = {
      "demo/lib.mt" => <<~MT,
        # module demo.lib

        public struct Counter:
            value: int

        extending Counter:
            function times_two() -> int:
                return this.value * 2
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source, imported)
    end

    assert_match(/demo\.lib\.Counter\.times_two is private to module demo\.lib/, error.message)
  end

  def test_rejects_ambiguous_imported_extension_method_calls
    source = <<~MT
      # module demo.main

      import demo.dep as dep
      import demo.a as a
      import demo.b as b

      function main(value: dep.Counter) -> int:
          value.tag()
          return 0
    MT

    imported = {
      "demo/dep.mt" => <<~MT,
        # module demo.dep

        public struct Counter:
            value: int
      MT
      "demo/a.mt" => <<~MT,
        # module demo.a

        import demo.dep as dep

        extending dep.Counter:
            public function tag() -> int:
                return 1
      MT
      "demo/b.mt" => <<~MT,
        # module demo.b

        import demo.dep as dep

        extending dep.Counter:
            public function tag() -> int:
                return 2
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source, imported)
    end

    assert_match(/ambiguous imported method demo\.dep\.Counter\.tag; found in modules demo\.a, demo\.b/, error.message)
    assert_equal 8, error.line
    assert_equal 11, error.column
  end

  def test_rejects_ambiguous_imported_extension_associated_function_calls
    source = <<~MT
      # module demo.main

      import demo.dep as dep
      import demo.a as a
      import demo.b as b

      function main() -> int:
          dep.Counter.zero()
          return 0
    MT

    imported = {
      "demo/dep.mt" => <<~MT,
        # module demo.dep

        public struct Counter:
            value: int
      MT
      "demo/a.mt" => <<~MT,
        # module demo.a

        import demo.dep as dep

        extending dep.Counter:
            public static function zero() -> dep.Counter:
                return dep.Counter(value = 1)
      MT
      "demo/b.mt" => <<~MT,
        # module demo.b

        import demo.dep as dep

        extending dep.Counter:
            public static function zero() -> dep.Counter:
                return dep.Counter(value = 2)
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source, imported)
    end

    assert_match(/ambiguous imported method demo\.dep\.Counter\.zero; found in modules demo\.a, demo\.b/, error.message)
    assert_equal 8, error.line
    assert_equal 17, error.column
  end

  def test_rejects_import_of_private_type_constructor
    source = <<~MT
      # module demo.main

      import demo.lib as lib

      function main() -> int:
          let hidden = lib.Hidden(value = 7)
          return hidden.value
    MT

    imported = {
      "demo/lib.mt" => <<~MT,
        # module demo.lib

        struct Hidden:
            value: int
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source, imported)
    end

    assert_match(/lib\.Hidden is private to module demo\.lib/, error.message)
  end

  def test_rejects_same_width_enum_and_flags_arguments_without_explicit_cast_for_non_extern_calls
    source = <<~MT
      # module demo.call_values

      flags Gesture: int
          tap = 1

      function takes_uint(value: uint) -> int:
          return 0

      function main() -> int:
          takes_uint(Gesture.tap)
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/argument value to takes_uint expects uint, got .*Gesture/, error.message)
  end

  def test_type_checks_variadic_extern_calls
    source = <<~MT
      # module demo.printf

      external function printf(format: cstr, ...) -> int

      function main() -> int:
          let count = printf(c"value=%d ratio=%.1f\\n", 7, 2.5)
          return count
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_variadic_extern_calls_missing_required_arguments
    source = <<~MT
      # module demo.printf

      external function printf(format: cstr, ...) -> int

      function main() -> int:
          return printf()
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/function printf expects at least 1 arguments, got 0/, error.message)
  end

  def test_rejects_same_width_enum_and_flags_assignment_without_explicit_cast
    source = <<~MT
      # module demo.bad

      flags Gesture: int
          tap = 1

      function main() -> int:
          let gesture: uint = Gesture.tap
          return int<-gesture
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/cannot assign .*Gesture to gesture: expected uint/, error.message)
  end

  def test_rejects_non_power_of_two_alignment
    source = <<~MT
      # module demo.layout

      align(3) struct Mat4:
          data: array[float, 16]
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/align\(\.\.\.\) requires a power-of-two alignment, got 3/, error.message)
  end

  def test_rejects_break_and_continue_outside_loops
    break_source = <<~MT
      # module demo.bad

      function main() -> int:
          break
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(break_source)
    end
    assert_match(/break must be inside a loop/, error.message)

    continue_source = <<~MT
      # module demo.bad

      function main() -> int:
          continue
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(continue_source)
    end
    assert_match(/continue must be inside a loop/, error.message)
  end

  def test_rejects_for_loop_over_non_iterable_value
    source = <<~MT
      # module demo.for_loops

      function main() -> int:
          for value in 3:
              let copy = value
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/for loop expects start\.\.stop, array\[T, N\], span\[T\], or an iterable with iter\(\)\/next\(\)/, error.message)
  end

  def test_type_checks_dot_dot_range_in_for_loop
    source = <<~MT
      # module demo.for_loops

      function sum(count: int) -> int:
          var total = 0
          for i in 0..count:
              total += i
          return total
    MT

    result = check_source(source)
    assert_equal true, result.functions.key?("sum")
  end

  def test_type_checks_dot_dot_range_with_ptr_uint_bounds
    source = <<~MT
      # module demo.for_loops

      function sum_n(n: ptr_uint) -> ptr_uint:
          var total: ptr_uint = 0
          for i in 0..n:
              total += i
          return total
    MT

    result = check_source(source)
    assert_equal true, result.functions.key?("sum_n")
  end

  def test_rejects_dot_dot_range_with_non_integer_bounds
    source = <<~MT
      # module demo.for_loops

      function main() -> void:
          for i in 0.0..1.0:
              let x = i
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/range bounds must be integer types/, error.message)
  end

  def test_rejects_dot_dot_range_with_mismatched_bound_types
    source = <<~MT
      # module demo.for_loops

      function main(n: ptr_uint) -> void:
          for i in 0..n:
              let x: ptr_uint = i
    MT

    # This should succeed: literal 0 adapts to ptr_uint
    result = check_source(source)
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_range_index_assignment
    source = <<~MT
      # module demo.range_assign

      function fill(buf: ptr[float]) -> void:
          unsafe:
              buf[0..3] = (1.0, 2.0, 3.0)
    MT

    result = check_source(source)
    assert_equal true, result.functions.key?("fill")
  end

  def test_rejects_range_index_assignment_with_non_literal_bounds
    source = <<~MT
      # module demo.range_assign

      function fill(buf: ptr[float], n: ptr_uint) -> void:
          unsafe:
              buf[0..n] = (1.0, 2.0, 3.0)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/requires integer literal bounds/, error.message)
  end

  def test_rejects_range_index_assignment_with_mismatched_count
    source = <<~MT
      # module demo.range_assign

      function fill(buf: ptr[float]) -> void:
          unsafe:
              buf[0..3] = (1.0, 2.0)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/spans 3 elements but tuple has 2/, error.message)
  end

  def test_rejects_non_exhaustive_match_statement_over_enum
    source = <<~MT
      # module demo.match

      enum EventKind: ubyte
          quit = 1
          resize = 2

      function dispatch(kind: EventKind) -> int:
          match kind:
              EventKind.quit:
                  return 0
          return 1
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/match on demo.match.EventKind is missing cases: resize/, error.message)
  end

  def test_rejects_fatal_with_non_string_message
    source = <<~MT
      # module demo.fatal

      function main() -> int:
          fatal(123)
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/fatal expects str or cstr, got int/, error.message)
  end

  def test_rejects_mismatched_callback_arguments
    source = <<~MT
      # module demo.callbacks

      type LogCallback = fn(level: int, message: cstr) -> void
      external function set_callback(callback: LogCallback) -> void

      function wrong(level: int) -> void:
          return

      function main() -> int:
          set_callback(wrong)
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/argument callback to set_callback expects/, error.message)
  end

  def test_type_checks_non_keyword_field_names
    source = <<~MT
      # module demo.keywords

      struct Event:
          kind: int

      function main(event: Event) -> int:
          let copy = Event(kind = event.kind)
          return copy.kind
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Event")
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

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_extended_compound_assignment_operators
    source = <<~MT
      # module demo.compound_assignments

      flags Bits: uint
          a = 1 << 0
          b = 1 << 1

      function main() -> int:
          var value = 12
          value %= 5
          value <<= 1
          value >>= 1
          var bits = Bits.a
          bits |= Bits.b
          bits &= Bits.b
          bits ^= Bits.a
          return value
    MT

    result = check_source(source)

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
          mutable function add(delta: int):
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

  def test_type_checks_associated_functions_on_local_structs
    source = <<~MT
      # module demo.associated

      struct Vec:
          x: int

      extending Vec:
          static function zero() -> Vec:
              return Vec(x = 0)

          function add(other: Vec) -> Vec:
              return Vec(x = this.x + other.x)

      function main() -> int:
          let left = Vec.zero()
          let total = left.add(Vec.zero())
          return total.x
    MT

    result = check_source(source)
    vec_type = result.types.fetch("Vec")
    methods = result.methods.fetch(vec_type)

    assert_nil methods.fetch("zero").type.receiver_type
    assert_equal vec_type, methods.fetch("add").type.receiver_type
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_array_construction_for_locals_consts_and_struct_fields
    source = <<~MT
      # module demo.arrays

      struct Palette:
          colors: array[uint, 4]

      const DEFAULT: array[uint, 4] = array[uint, 4](11, 22, 33, 44)

      function main() -> int:
          let palette = array[uint, 4](1, 2, 3, 4)
          let holder = Palette(colors = array[uint, 4](5, 6, 7, 8))
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Palette")
    assert_equal true, result.values.key?("DEFAULT")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_array_assignment_and_by_value_parameters
    source = <<~MT
      # module demo.arrays

      function mutate(values: array[int, 4]) -> int:
          var local = values
          unsafe:
              local[1] = 9
              return local[1]

      function main() -> int:
          var lhs = array[int, 4](1, 2, 3, 4)
          let rhs = array[int, 4](5, 6, 7, 8)
          lhs = rhs
          return mutate(lhs)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("mutate")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_local_array_return_values
    source = <<~MT
      # module demo.array_returns

      function make() -> array[int, 4]:
          return array[int, 4](1, 2, 3, 4)

      function clone(values: array[int, 4]) -> array[int, 4]:
          return values

      function read(values: array[int, 4]) -> int:
          unsafe:
              return values[1]

      function main() -> int:
          return read(clone(make()))
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("make")
    assert_equal true, result.functions.key?("clone")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_zero_initialization_for_arrays_and_structs
    source = <<~MT
      # module demo.zero

      struct Palette:
          colors: array[uint, 4]

      function main() -> int:
          let palette = zero[array[uint, 4]]
          let holder = zero[Palette]
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Palette")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_partial_aggregate_and_array_construction
    source = <<~MT
      # module demo.partial_init

      struct Point:
          x: int
          y: int

      struct Holder:
          point: Point
          colors: array[uint, 4]

      function main() -> int:
          let origin = Point()
          let point = Point(x = 5)
          let colors = array[uint, 4](1, 2)
          let holder = Holder(point = point)
          return origin.x + point.x + int<-colors[1] + holder.point.x
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Point")
    assert_equal true, result.types.key?("Holder")
    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_partial_array_construction_with_too_many_elements
    source = <<~MT
      # module demo.too_many_array_elements

      function main() -> int:
          let values = array[int, 2](1, 2, 3)
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/array expects at most 2 elements, got 3/, error.message)
  end

  def test_rejects_zero_for_void
    source = <<~MT
      # module demo.zero_bad

      function main() -> int:
          let value = zero[void]
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/zero does not support type void/, error.message)
  end

  def test_type_checks_default_specialization_with_explicit_associated_overrides
    source = <<~MT
      # module demo.default_builtin

      struct Player:
          hp: int

      extending Player:
          static function default() -> Player:
              return Player(hp = 100)

      struct Plain:
          hp: int

      extending Plain:
          static function default() -> Plain:
              return Plain(hp = 7)

      function make_default[T]() -> T:
          return default[T]

      function main() -> int:
          let player = make_default[Player]()
          let plain = make_default[Plain]()
          return player.hp + plain.hp
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Player")
    assert_equal true, result.types.key?("Plain")
    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_default_specialization_without_explicit_associated_default
    source = <<~MT
      # module demo.default_builtin_bad

      struct Plain:
          hp: int

      function make_default[T]() -> T:
          return default[T]

      function main() -> int:
          let plain = make_default[Plain]()
          return plain.hp
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/default\[demo\.default_builtin_bad\.Plain\] requires associated function demo\.default_builtin_bad\.Plain\.default\(\)/, error.message)
  end

  def test_rejects_default_call_form
    source = <<~MT
      # module demo.default_call_form

      function main() -> int:
          let value = default[int]()
          return value
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/default\[T\]\(\) is no longer supported; use default\[T\]/, error.message)
  end

  def test_rejects_default_override_with_parameters
    source = <<~MT
      # module demo.bad_default_override

      struct Player:
          hp: int

      extending Player:
          static function default(seed: int) -> Player:
              return Player(hp = seed)

      function main() -> int:
          let player = default[Player]
          return player.hp
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/default\[demo\.bad_default_override\.Player\] requires demo\.bad_default_override\.Player\.default\(\) to take 0 arguments/, error.message)
  end

  def test_rejects_extern_array_params_and_returns
    param_source = <<~MT
      # module demo.bad_params

      external function take(values: array[int, 4]) -> int
    MT

    param_error = assert_raises(MilkTea::SemaError) do
      check_source(param_source)
    end

    assert_match(/external function take cannot take array parameters/, param_error.message)

    return_source = <<~MT
      # module demo.bad_return

      external function make() -> array[int, 4]
    MT

    return_error = assert_raises(MilkTea::SemaError) do
      check_source(return_source)
    end

    assert_match(/external function make cannot return arrays/, return_error.message)
  end

  def test_rejects_external_function_with_proc_parameter
    source = <<~MT
      # module demo.external_proc_param

      external function install(callback: proc() -> void) -> void
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/external function install cannot take proc parameters/, error.message)
  end

  def test_type_checks_safe_array_indexing_and_element_assignment
    source = <<~MT
      # module demo.arrays

      struct Palette:
          colors: array[uint, 4]

      function main() -> int:
          var palette = array[uint, 4](1, 2, 3, 4)
          var holder = Palette(colors = array[uint, 4](5, 6, 7, 8))
          palette[1] = 9
          holder.colors[2] = 10
          let first = palette[0]
          let third = holder.colors[2]
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_addr_of_fixed_array_element_through_pointer_deref
    source = <<~MT
      # module demo.ptr_arrays

      struct Palette:
          colors: array[uint, 4]

      function main() -> uint:
          var holder = Palette(colors = array[uint, 4](5, 6, 7, 8))
          unsafe:
              let base = ptr_of(holder)
              let first = ptr_of(read(base).colors[0])
              read(first) = 9
          return holder.colors[0]
    MT

    result = check_source(source)

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

  def test_rejects_mut_method_call_on_read_only_raw_pointer
    source = <<~MT
      # module demo.bad

      struct Counter:
          value: int

      extending Counter:
          mutable function add(delta: int):
              this.value += delta

      function main() -> int:
          var counter = Counter(value = 3)
          let counter_ptr = const_ptr_of(counter)
          unsafe:
              counter_ptr.add(1)
          return counter.value
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/cannot call mutable method add on an immutable receiver/, error.message)
  end

  def test_rejects_safe_indexing_of_temporary_array_values
    source = <<~MT
      # module demo.bad

      function main() -> int:
          let value = array[int, 4](1, 2, 3, 4)[0]
          return value
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/safe array indexing requires an addressable array value/, error.message)
  end

  def test_type_checks_safe_indexing_of_value_ref_array_projection
    source = <<~MT
      # module demo.good

      struct Item:
          value: int

      function project(items: ref[array[Item, 4]]) -> int:
          return read(items)[0].value

      function write(items: ref[array[Item, 4]]) -> void:
          read(items)[0].value = 7
          return
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("project")
    assert_equal true, result.functions.key?("write")
  end

  def test_rejects_dereference_of_non_pointer
    source = <<~MT
      # module demo.bad

      function main() -> int:
          let value = read(1)
          return value
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/read expects ref\[\.\.\.\] or ptr\[\.\.\.\], got int/, error.message)
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

  def test_reports_invalid_prefix_cast_at_cast_expression_column
    source = <<~MT
      function main() -> int:
          return unsafe: read(ptr[int]<-0)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/cast currently only supports numeric primitive types/, error.message)
    assert_equal 2, error.line
    assert_equal 25, error.column
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

  def test_type_checks_const_pointer_calls_from_immutable_storage
    source = <<~MT
      # module demo.const_pointer_call

      external function inspect(values: const_ptr[int]) -> void

      function main() -> void:
          let value = 7
          inspect(const_ptr_of(value))
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_const_void_pointer_calls_from_immutable_storage
    source = <<~MT
      # module demo.const_void_pointer_call

      external function inspect(value: const_ptr[void]) -> void

      function main() -> void:
          let value = 7
          inspect(const_ptr_of(value))
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_in_parameter
    root_source = <<~MT
      # module demo.main

      import std.sample as sample

      function main() -> void:
          let value = 7
          sample.inspect(value)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function Inspect(value: const_ptr[void]) -> void
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function inspect[T](in value: T as const_ptr[void]) -> void = c.Inspect
      MT
    }

    result = check_program_source(root_source, imported_sources).root_analysis

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_foreign_in_argument_with_legacy_marker
    root_source = <<~MT
      # module demo.main

      import std.sample as sample

      function main() -> void:
          let value = 7
          sample.inspect(in value)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function Inspect(value: const_ptr[void]) -> void
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function inspect[T](in value: T as const_ptr[void]) -> void = c.Inspect
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(root_source, imported_sources)
    end

    assert_match(/argument value to inspect must not use in/, error.message)
  end

  def test_rejects_foreign_in_parameter_without_const_ptr_boundary
    root_source = <<~MT
      # module demo.main

      import std.sample as sample

      function main() -> void:
          let value = 7
          sample.inspect(value)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function Inspect(value: ptr[void]) -> void
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function inspect[T](in value: T as ptr[void]) -> void = c.Inspect
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(root_source, imported_sources)
    end

    assert_match(/in parameter value of inspect must lower to const_ptr\[\.\.\.\]/, error.message)
  end

  def test_rejects_incompatible_foreign_in_parameter_mapping
    root_source = <<~MT
      # module demo.main

      import std.sample as sample

      function main() -> void:
          let value = 7
          sample.inspect(value)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function Inspect(value: const_ptr[float]) -> void
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function inspect(in value: int as const_ptr[float]) -> void = c.Inspect
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(root_source, imported_sources)
    end

    assert_match(/in parameter value of inspect cannot map int as const_ptr\[float\]/, error.message)
  end

  def test_rejects_consuming_foreign_parameter_with_non_pointer_public_type
    root_source = <<~MT
      # module demo.main

      import std.sample as sample

      function main() -> void:
          sample.release(1)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function Release(value: int) -> void
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function release(consuming value: int) -> void = c.Release
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(root_source, imported_sources)
    end

    assert_match(/consuming parameter value of release must use a non-null opaque or ptr\[\.\.\.\] type/, error.message)
  end

  def test_rejects_const_pointer_for_writable_pointer_parameters
    source = <<~MT
      # module demo.bad_const_pointer

      external function write(values: ptr[int]) -> void

      function main() -> void:
          let value = 7
          write(const_ptr_of(value))
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/expects ptr\[int\], got const_ptr\[int\]/, error.message)
  end

  def test_type_checks_array_char_as_span_char_and_safe_index_source
    source = <<~MT
      # module demo.char_array_surface

      function view(items: span[char]) -> ptr_uint:
          return items.len

      function main() -> int:
          var buffer = zero[array[char, 32]]
          buffer[0] = 65
          let used = view(buffer)
          return int<-used
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_zero_initialized_typed_array_char_locals
    source = <<~MT
      # module demo.char_array_zero_locals

      function main() -> int:
          var buffer: array[char, 32]
          buffer[0] = 65
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_typed_local_without_initializer_for_non_zero_initializable_type
    source = <<~MT
      # module demo.bad_local

      function main() -> void:
          let callback: fn(value: int) -> void
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/without initializer requires a zero-initializable type/, error.message)
  end

  def test_rejects_array_char_text_methods
    source = <<~MT
      # module demo.char_array_methods

      function main() -> int:
          var buffer = zero[array[char, 16]]
          let view = buffer.as_str()
          let label = buffer.as_cstr()
          return int<-view.len
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/array\[char, 16\]\.as_str is not available; array\[char, N\] is raw storage/, error.message)
  end

  def test_rejects_removed_predecessor_of_str_buffer_type
    removed_type_name = %w[str builder].join("_")

    source = <<~MT
      # module demo.main

      function main() -> void:
          var buffer: #{removed_type_name}[8]
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/unknown generic type #{Regexp.escape(removed_type_name)}/, error.message)
  end

  def test_rejects_removed_cstr_list_buffer_type
    source = <<~MT
      # module demo.main

      function main() -> void:
          var labels: cstr_list_buffer[3, 64]
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/unknown generic type cstr_list_buffer/, error.message)
  end

  def test_rejects_array_char_as_str_on_temporary_receiver
    source = <<~MT
      # module demo.char_array_bad_view

      function main() -> str:
          return zero[array[char, 8]].as_str()
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/array\[char, 8\]\.as_str is not available; array\[char, N\] is raw storage/, error.message)
  end

  def test_rejects_array_char_as_cstr_on_temporary_receiver
    source = <<~MT
      # module demo.char_array_bad_cstr

      function main() -> cstr:
          return zero[array[char, 8]].as_cstr()
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/array\[char, 8\]\.as_cstr is not available; array\[char, N\] is raw storage/, error.message)
  end

  def test_rejects_foreign_str_as_cstr_calls_with_array_char_as_cstr
    root_source = <<~MT
      # module demo.main

      import std.ui as ui

      function main() -> void:
          var buffer: array[char, 32]
          ui.label(buffer.as_cstr())
    MT

    imported_sources = {
      "std/c/ui.mt" => <<~MT,
        # module std.c.ui
        external

        external function Label(text: cstr) -> void
      MT
      "std/ui.mt" => <<~MT,
        # module std.ui

        import std.c.ui as c

        public foreign function label(text: str as cstr) -> void = c.Label
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(root_source, imported_sources)
    end

    assert_match(/array\[char, 32\]\.as_cstr is not available; array\[char, N\] is raw storage/, error.message)
  end

  def test_type_checks_foreign_defs_with_array_char_and_span_char_ptr_char_boundary
    root_source = <<~MT
      # module demo.main

      import std.mem as mem

      function main() -> void:
          var fixed = zero[array[char, 32]]
          var dynamic = zero[array[char, 64]]
          mem.write_fixed(fixed)
          mem.write_dynamic(dynamic)
    MT

    imported_sources = {
      "std/c/mem.mt" => <<~MT,
        # module std.c.mem
        external
        include "mem.h"

        external function WriteFixed(label: ptr[char]) -> void
        external function WriteDynamic(label: ptr[char]) -> void
      MT
      "std/mem.mt" => <<~MT,
        # module std.mem

        import std.c.mem as c

        public foreign function write_fixed(label: array[char, 32] as ptr[char]) -> void = c.WriteFixed(label)
        public foreign function write_dynamic(label: span[char] as ptr[char]) -> void = c.WriteDynamic(label)
      MT
    }

    result = check_program_source(root_source, imported_sources)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_ro_addr_on_immutable_array_elements_for_const_pointers
    source = <<~MT
      # module demo.const_pointer_arrays

      struct Vec2:
          x: float
          y: float

      external function draw(points: const_ptr[Vec2], count: int) -> void

      function main() -> void:
          let points = array[Vec2, 2](
              Vec2(x = 1.0, y = 2.0),
              Vec2(x = 3.0, y = 4.0),
          )
          draw(const_ptr_of(points[0]), 2)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_mapping_public_alias_for_boundary_length_pairs
    root_source = <<~MT
      # module demo.main

      import std.ui as ui

      function main() -> void:
          var buffer = zero[array[char, 32]]
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

        public foreign function text_box(text: span[char] as ptr[char]) -> void = c.TextBox(text, int<-text_public.len)
      MT
    }

    result = check_program_source(root_source, imported_sources)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_str_buffer_methods_and_span_char_calls
    source = <<~MT
      # module demo.str_buffer_surface

      function view(items: span[char]) -> ptr_uint:
          return items.len

      function main() -> int:
          var buffer: str_buffer[32]
          buffer.assign("hi")
          buffer.append("!")
          let text = buffer.as_str()
          let label = buffer.as_cstr()
          let raw = view(buffer)
          if text.len == 0:
              return 1
          buffer.clear()
          return int<-(raw + buffer.capacity())
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_mapping_public_alias_for_str_buffer_boundary_length_pairs
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

        public foreign function text_box(text: span[char] as ptr[char]) -> void = c.TextBox(text, int<-text_public.len)
      MT
    }

    result = check_program_source(root_source, imported_sources)

    assert_equal true, result.root_analysis.functions.key?("main")
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

  def test_rejects_char_as_general_numeric_type
    source = <<~MT
      # module demo.bad_char_numeric

      function main() -> int:
          let value = char<-65
          return value + 1
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/operator \+ requires compatible numeric types, got char and int/, error.message)
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

  def test_type_checks_safe_ref_locals_params_and_methods
    source = <<~MT
      # module demo.refs

      struct Counter:
          value: int

      extending Counter:
          mutable function add(delta: int):
              this.value += delta

          function read() -> int:
              return this.value

      function increment(counter: ref[Counter], amount: int) -> void:
          counter.add(amount)
          counter.value += 1

      function main() -> int:
          var counter = Counter(value = 3)
          increment(counter, 4)
          let handle = ref_of(counter)
          let value_ref = ref_of(handle.value)
          read(value_ref) += 2
          unsafe:
              let raw_counter = ptr_of(handle)
              read(raw_counter).value += 1
          return handle.read()
    MT

    result = check_source(source)

    assert_equal "ref[demo.refs.Counter]", result.functions.fetch("increment").type.params.first.type.to_s
    assert_equal true, result.functions.key?("main")
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

  def test_rejects_ref_of_immutable_values
    source = <<~MT
      # module demo.bad

      function main() -> int:
          let value = 1
          let handle = ref_of(value)
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/cannot assign to immutable value/, error.message)
  end

  def test_rejects_ref_storage_and_escape_types
    field_source = <<~MT
      # module demo.bad_field

      struct Holder:
          value: ref[int]
    MT

    field_error = assert_raises(MilkTea::SemaError) do
      check_source(field_source)
    end

    assert_match(/field Holder\.value cannot store ref types/, field_error.message)

    extern_source = <<~MT
      # module demo.bad_param

      external function take(value: ref[int]) -> void
    MT

    extern_error = assert_raises(MilkTea::SemaError) do
      check_source(extern_source)
    end

    assert_match(/external function take cannot take ref parameters/, extern_error.message)

    return_source = <<~MT
      # module demo.bad_return

      function leak(value: ref[int]) -> ref[int]:
          return value
    MT

    return_error = assert_raises(MilkTea::SemaError) do
      check_source(return_source)
    end

    assert_match(/function leak cannot return ref types/, return_error.message)
  end

  def test_type_checks_ref_arguments_for_by_value_parameters
    source = <<~MT
      # module demo.ref_value_args

      struct Counter:
          value: int

      external function consume(counter: Counter) -> void

      function project(counter: Counter) -> int:
          return counter.value

      function main() -> int:
          var counter = Counter(value = 7)
          let handle = ref_of(counter)
          consume(read(handle))
          return project(read(handle))
    MT

    result = check_source(source)

    assert_equal "demo.ref_value_args.Counter", result.functions.fetch("project").type.params.first.type.to_s
    assert_equal true, result.functions.key?("main")
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

  def test_type_checks_ref_projection_without_value
    source = <<~MT
      # module demo.good

      struct Counter:
          value: int

      function main() -> int:
          var counter = Counter(value = 3)
          let handle = ref_of(counter)
          let value_ref = ref_of(handle.value)
          read(value_ref) += 2
          return handle.value
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_non_integer_flags_backing_types
    source = <<~MT
      # module demo.bad

      flags BadFlags: float
          visible = 1
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/backing type must be an integer primitive/, error.message)
  end

  def test_rejects_unknown_enum_members
    source = <<~MT
      # module demo.bad

      enum State: ubyte
          idle = 0

      function main() -> int:
          let state: State = State.moving
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/unknown member .*State\.moving/, error.message)
  end

  def test_rejects_foreign_external_struct_boundary_with_different_layout
    source = <<~MT
      # module demo.main

      import std.shared as shared
      import std.sample as sample

      function main() -> void:
          sample.set_matrix(shared.IDENTITY)
    MT

    imported_sources = {
      "std/c/shared.mt" => <<~MT,
        # module std.c.shared
        external
        struct Matrix:
            m0: float
      MT
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        struct Matrix:
            m0: float
            m1: float

        external function SetMatrix(matrix: Matrix) -> void
      MT
      "std/shared.mt" => <<~MT,
        # module std.shared

        import std.c.shared as c

        public type Matrix = c.Matrix
        public const IDENTITY: Matrix = Matrix(m0 = 1.0)
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c
        import std.shared as shared

        public foreign function set_matrix(matrix: shared.Matrix as c.Matrix) -> void = c.SetMatrix
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source, imported_sources)
    end

      def test_allows_callback_parameters_with_ref_arguments
        source = <<~MT
          # module demo.ref_callback_param

          struct Counter:
              value: int

          function each(counter: ref[Counter], body: fn(arg0: ref[Counter]) -> bool) -> bool:
              return body(counter)

          function increment(counter: ref[Counter]) -> bool:
              counter.value += 1
              return true

          function main() -> int:
              var counter = Counter(value = 0)
              if not each(ref_of(counter), increment):
                  return 1
              return counter.value
        MT

        result = check_source(source)

        assert_equal "fn(arg0: ref[demo.ref_callback_param.Counter]) -> bool", result.functions.fetch("each").type.params[1].type.to_s
      end

    assert_match(/foreign parameter matrix of set_matrix cannot map std\.c\.shared\.Matrix as std\.c\.sample\.Matrix/, error.message)
  end

  def test_type_checks_foreign_external_opaque_boundary_with_matching_c_name
    source = <<~MT
      # module demo.main

      import std.sample as sample

      function main(logger: sample.Logger) -> void:
          sample.write_log(logger)
    MT

    imported_sources = {
      "std/c/shared.mt" => <<~MT,
        # module std.c.shared
        external
        opaque va_list = c"va_list"
      MT
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        opaque va_list = c"va_list"

        external function WriteLog(args: va_list) -> void
      MT
      "std/shared.mt" => <<~MT,
        # module std.shared

        import std.c.shared as c

        public type Logger = c.va_list
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c
        import std.shared as shared

        public type Logger = shared.Logger
        public foreign function write_log(args: shared.Logger as c.va_list) -> void = c.WriteLog
      MT
    }

    program = check_program_source(source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("sample")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_module_scope_mutable_vars_and_zero_initialized_storage
    source = <<~MT
      # module demo.module_vars

      function identity(value: int) -> int:
          return value

      var counter: int = 1
      var scratch: array[ubyte, 4]
      var callbacks: array[fn(value: int) -> int, 1] = array[fn(value: int) -> int, 1](identity)

      function main() -> int:
          counter = callbacks[0](counter + 1)
          scratch[0] = 7
          return counter + int<-scratch[0]
    MT

    result = check_source(source)
    counter = result.values.fetch("counter")
    scratch = result.values.fetch("scratch")
    callbacks = result.values.fetch("callbacks")

    assert_equal true, counter.mutable
    assert_equal :var, counter.kind
    assert_equal "int", counter.type.to_s
    assert_equal true, scratch.mutable
    assert_equal "array[ubyte, 4]", scratch.type.to_s
    assert_equal true, callbacks.mutable
    assert_equal "array", callbacks.type.name
    assert_instance_of MilkTea::Types::Function, callbacks.type.arguments[0]
    assert_equal "int", callbacks.type.arguments[0].return_type.to_s
    assert_equal "int", callbacks.type.arguments[0].params.first.type.to_s
    assert_equal 1, callbacks.type.arguments[1].value
    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_module_scope_var_with_non_static_initializer
    source = <<~MT
      # module demo.bad_module_var

      function seed() -> int:
          return 41

      var counter: int = seed()
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/module variable initializer must be static-storage-safe/, error.message)
  end

  def test_type_checks_integer_match_with_wildcard
    source = <<~MT
      # module demo.int_match

      function dispatch(key: int) -> int:
          match key:
              65:
                  return 1
              27:
                  return 2
              _:
                  return 0

      function main() -> int:
          return dispatch(65)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("dispatch")
  end

  def test_rejects_integer_match_missing_wildcard
    source = <<~MT
      # module demo.int_match_bad

      function dispatch(key: int) -> int:
          match key:
              65:
                  return 1
              27:
                  return 2

      function main() -> int:
          return dispatch(65)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/requires a wildcard arm/, error.message)
  end

  def test_rejects_non_literal_pattern_in_integer_match
    source = <<~MT
      # module demo.int_match_bad_pattern

      var x: int = 65

      function dispatch(key: int) -> int:
          match key:
              x:
                  return 1
              _:
                  return 0

      function main() -> int:
          return dispatch(65)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/must be an integer literal or _/, error.message)
  end

  def test_rejects_duplicate_wildcard_in_match
    source = <<~MT
      # module demo.dup_wild

      function dispatch(key: int) -> int:
          match key:
              65:
                  return 1
              _:
                  return 0
              _:
                  return 99

      function main() -> int:
          return dispatch(65)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/duplicate wildcard arm/, error.message)
  end

  def test_type_checks_enum_match_with_wildcard_subset
    source = <<~MT
      # module demo.enum_wild

      enum EventKind: ubyte
          quit = 1
          resize = 2
          key = 3

      function dispatch(kind: EventKind) -> int:
          match kind:
              EventKind.quit:
                  return 0
              _:
                  return 1

      function main() -> int:
          return dispatch(EventKind.quit)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("dispatch")
  end

  def test_rejects_duplicate_integer_match_arm_value
    source = <<~MT
      # module demo.dup_int

      function dispatch(key: int) -> int:
          match key:
              65:
                  return 1
              65:
                  return 2
              _:
                  return 0

      function main() -> int:
          return dispatch(65)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/duplicate match arm value/, error.message)
  end

  def test_type_checks_integer_match_ubyte_scrutinee
    source = <<~MT
      # module demo.u8_match

      function dispatch(code: ubyte) -> int:
          match code:
              0:
                  return 0
              1:
                  return 1
              _:
                  return 99

      function main() -> int:
          return dispatch(1)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("dispatch")
  end

  def test_type_checks_exhaustive_variant_match
    source = <<~MT
      # module demo.variant_match

      variant Shape:
          circle(radius: double)
          rect(w: double, h: double)
          point

      function area(s: Shape) -> double:
          var result = 0.0
          match s:
              Shape.circle as c:
                  result = c.radius * c.radius
              Shape.rect as r:
                  result = r.w * r.h
              Shape.point:
                  result = 0.0
          return result

      function main() -> int:
          let c: Shape = Shape.circle(radius= 1.0)
          let p: Shape = Shape.point
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Shape")
    assert_equal true, result.functions.key?("area")
  end

  def test_type_checks_variant_match_with_wildcard
    source = <<~MT
      # module demo.variant_wildcard

      variant Token:
          ident(text: str)
          number(value: int)
          eof

      function is_done(t: Token) -> bool:
          match t:
              Token.eof:
                  return true
              _:
                  return false

      function main() -> int:
          let tok: Token = Token.ident(text= "hello")
          if is_done(tok):
              return 1
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Token")
    assert_equal true, result.functions.key?("is_done")
  end

  def test_rejects_non_exhaustive_variant_match
    source = <<~MT
      # module demo.variant_non_exhaustive

      variant Shape:
          circle(radius: double)
          rect(w: double, h: double)
          point

      function area(s: Shape) -> double:
          match s:
              Shape.circle as c:
                  return c.radius
              Shape.rect as r:
                  return r.w
    MT

    assert_raises(MilkTea::SemaError) { check_source(source) }
  end

  def test_rejects_variant_construction_with_missing_fields
    source = <<~MT
      # module demo.variant_fields

      variant Shape:
          circle(radius: double)

      function main() -> int:
          let c: Shape = Shape.circle()
          return 0
    MT

    assert_raises(MilkTea::SemaError) { check_source(source) }
  end

  def test_rejects_as_binding_on_no_payload_arm
    source = <<~MT
      # module demo.variant_no_payload

      variant Shape:
          point

      function main() -> int:
          let s: Shape = Shape.point
          match s:
              Shape.point as p:
                  return 0
    MT

    assert_raises(MilkTea::SemaError) { check_source(source) }
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

  def test_type_checks_proc_fields_in_union
    source = <<~MT
      # module demo.union_proc

      union CallbackOrValue:
          callback: proc() -> int
          value: int

      function main() -> int:
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("CallbackOrValue")
  end

  def test_type_checks_while_loop_with_bool_condition
    source = <<~MT
      # module demo.while_loop

      function countdown(start: int) -> int:
          var i = start
          var total = 0
          while i > 0:
              total += i
              i -= 1
          return total
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("countdown")
  end

  def test_rejects_while_loop_with_non_bool_condition
    source = <<~MT
      # module demo.bad_while

      function main() -> int:
          while 1:
              return 0
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/while condition must be bool/, error.message)
  end

  def test_type_checks_boolean_and_or_not_operators
    source = <<~MT
      # module demo.bool_ops

      function test_and(a: bool, b: bool) -> bool:
          return a and b

      function test_or(a: bool, b: bool) -> bool:
          return a or b

      function test_not(a: bool) -> bool:
          return not a

      function test_combined(a: bool, b: bool, c: bool) -> bool:
          return a and b or not c

      function main() -> int:
          if test_and(true, false):
              return 1
          if test_or(false, true):
              return 2
          if not test_not(true):
              return 3
          return 0
    MT

    result = check_source(source)

    assert_equal "bool", result.functions.fetch("test_and").type.return_type.to_s
    assert_equal "bool", result.functions.fetch("test_or").type.return_type.to_s
    assert_equal "bool", result.functions.fetch("test_not").type.return_type.to_s
    assert_equal "bool", result.functions.fetch("test_combined").type.return_type.to_s
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_bitwise_operators_on_integers
    source = <<~MT
      # module demo.bitwise_ops

      function test_or(a: int, b: int) -> int:
          return a | b

      function test_and(a: int, b: int) -> int:
          return a & b

      function test_xor(a: int, b: int) -> int:
          return a ^ b

      function test_lshift(a: int, b: int) -> int:
          return a << b

      function test_rshift(a: int, b: int) -> int:
          return a >> b

      function test_complement(a: int) -> int:
          return ~a

      function main() -> int:
          return test_or(1, 2) + test_and(3, 1) + test_xor(3, 1)
    MT

    result = check_source(source)

    assert_equal "int", result.functions.fetch("test_or").type.return_type.to_s
    assert_equal "int", result.functions.fetch("test_and").type.return_type.to_s
    assert_equal "int", result.functions.fetch("test_xor").type.return_type.to_s
    assert_equal "int", result.functions.fetch("test_lshift").type.return_type.to_s
    assert_equal "int", result.functions.fetch("test_rshift").type.return_type.to_s
    assert_equal "int", result.functions.fetch("test_complement").type.return_type.to_s
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_modulo_operator
    source = <<~MT
      # module demo.modulo_op

      function remainder(a: int, b: int) -> int:
          return a % b

      function main() -> int:
          return remainder(10, 3)
    MT

    result = check_source(source)

    assert_equal "int", result.functions.fetch("remainder").type.return_type.to_s
    assert_equal true, result.functions.key?("main")
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

        public mutable function release() -> void:
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

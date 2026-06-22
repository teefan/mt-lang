# frozen_string_literal: true

require_relative "helpers"

class BuiltinTest < Minitest::Test
  include SemaTestHelpers

  def test_rejects_local_named_after_reserved_builtin_result_type
    error = assert_raises(MilkTea::SemanticError) do
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

    error = assert_raises(MilkTea::SemanticError) do
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

    error = assert_raises(MilkTea::SemanticError) do
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

    error = assert_raises(MilkTea::SemanticError) do
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

    error = assert_raises(MilkTea::SemanticError) do
      check_source(source)
    end

    assert_match(/hash\[demo\.hash_temporary_bad\.Key\] expects a safe/, error.message)
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

    assert_match(/expected '\]' after type parameters/, error.message)
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

    assert_match(/expected '\]' after type parameters/, error.message)
  end

  def test_rejects_type_parameter_named_after_non_primitive_builtin_type
    source = <<~MT
      # module demo.bad

      function identity[span](value: span) -> span:
          return value
    MT

    error = assert_raises(MilkTea::SemanticError) do
      check_source(source)
    end

    assert_match(/type parameter span uses reserved built-in type name span/, error.message)
    assert_equal 3, error.line
    assert_equal source.lines[2].index("span") + 1, error.column
    assert_equal "span".length, error.length
  end

  def test_rejects_type_declaration_named_after_reserved_builtin_type
    source = <<~MT
      # module demo.bad

      struct span:
          value: int
    MT

    error = assert_raises(MilkTea::SemanticError) do
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

    error = assert_raises(MilkTea::SemanticError) do
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

    error = assert_raises(MilkTea::SemanticError) do
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

    error = assert_raises(MilkTea::SemanticError) do
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

    error = assert_raises(MilkTea::SemanticError) do
      check_source(source)
    end

    assert_match(/field Event.payload Result uses reserved built-in type name Result/, error.message)
  end

  def test_rejects_removed_builtin_ok_and_err_helpers
    ok_source = <<~MT
      # module demo.ok

      function main() -> int:
          let value = ok(7)
          return 0
    MT

    ok_error = assert_raises(MilkTea::SemanticError) do
      check_source(ok_source)
    end

    assert_match(/unknown callable ok/, ok_error.message)

    err_source = <<~MT
      # module demo.err

      function main() -> int:
          let value = err(7)
          return 0
    MT

    err_error = assert_raises(MilkTea::SemanticError) do
      check_source(err_source)
    end

    assert_match(/unknown callable err/, err_error.message)
  end

  def test_order_builtin_accepts_primitive_integer_types
    source = <<~MT
      # module demo.order_accept

      import std.hash

      function main() -> int:
          let left: int = 1
          let right: int = 3
          let cmp = order[int](left, right)
          if cmp < 0:
              return -1
          else if cmp > 0:
              return 1
          else:
              return 0
    MT

    result = check_source(source)
    assert_equal true, result.functions.key?("main")
  end

  def test_order_builtin_accepts_uint
    source = <<~MT
      # module demo.order_uint

      import std.hash

      function main() -> int:
          let a: uint = 10
          let b: uint = 5
          return order[uint](a, b)
    MT

    result = check_source(source)
    assert_equal true, result.functions.key?("main")
  end

  def test_order_builtin_rejects_without_import
    source = <<~MT
      # module demo.order_noimport

      function main() -> int:
          let a: int = 1
          let b: int = 2
          return order[int](a, b)
    MT

    error = assert_raises(MilkTea::SemanticError) { check_source(source) }
    assert_match(/requires associated function/, error.message)
  end

end

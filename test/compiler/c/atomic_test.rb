# frozen_string_literal: true

require_relative "../sema/helpers"
require_relative "helpers"

class AtomicTest < Minitest::Test
  include SemaTestHelpers
  include CodegenTestHelpers

  def test_atomic_type_checks
    source = <<~MT
      # module demo.atomic_basic

      function main() -> int:
          var counter: atomic[int]
          counter.store(0)
          let prev = counter.add(5)
          let value = counter.load()
          return value
    MT

    result = check_program_source(source)
    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_atomic_rejects_non_integer_type
    source = <<~MT
      # module demo.atomic_bad

      function main() -> int:
          var counter: atomic[float]
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) { check_program_source(source) }
    assert_match(/primitive integer or bool/, error.message)
  end

  def test_atomic_generates_c_with_builtins
    source = <<~MT
      # module demo.atomic_gen

      function main() -> int:
          var counter: atomic[int]
          counter.store(10)
          let prev = counter.add(1)
          let val = counter.load()
          counter.sub(1)
          let old = counter.exchange(42)
          return val
    MT

    c_code = generate_c_from_program_source(source)
    assert_includes c_code, "_Atomic int32_t"
    assert_includes c_code, "__atomic_store_n"
    assert_includes c_code, "__atomic_load_n"
    assert_includes c_code, "__atomic_fetch_add"
    assert_includes c_code, "__atomic_fetch_sub"
    assert_includes c_code, "__atomic_exchange_n"
  end

  def test_atomic_store_rejects_immutable_receiver
    source = <<~MT
      # module demo.atomic_immut

      function main() -> int:
          let counter: atomic[int]
          counter.store(1)
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) { check_program_source(source) }
    assert_match(/immutable/, error.message)
  end

  def test_atomic_is_sendable
    source = <<~MT
      # module demo.atomic_send

      var shared_counter: atomic[int]

      function increment() -> void:
          shared_counter.add(1)

      function main() -> int:
          shared_counter.store(0)
          parallel:
              spawn:
                  increment()
              spawn:
                  increment()
          return shared_counter.load()
    MT

    c_code = generate_c_from_program_source(source)
    assert_includes c_code, "__atomic_fetch_add"
  end
end

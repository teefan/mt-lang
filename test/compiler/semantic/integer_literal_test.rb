# frozen_string_literal: true

require_relative "helpers"

class IntegerLiteralTest < Minitest::Test
  include SemaTestHelpers

  def test_bare_int32_literal_stays_int
    source = <<~MT
      function main() -> int:
          let x = 42
          return x
    MT

    check_source(source)
  end

  def test_bare_literal_past_int32_promotes_to_long
    source = <<~MT
      function main() -> int:
          let x = 2147483648
          if x == 2147483648l:
              return 0
          return 1
    MT

    check_source(source)
  end

  def test_bare_literal_past_int64_promotes_to_ulong
    source = <<~MT
      function main() -> int:
          let x = 9223372036854775808
          if x == 9223372036854775808ul:
              return 0
          return 1
    MT

    check_source(source)
  end

  def test_bare_literal_exceeding_ulong_is_rejected
    source = <<~MT
      function main() -> int:
          let x = 18446744073709551616
          return 0
    MT

    error = assert_raises(MilkTea::SemanticError) do
      check_source(source)
    end

    assert_match(/does not fit in any integer type/, error.message)
  end

  def test_suffixed_literal_uses_suffix_type
    source = <<~MT
      function main() -> int:
          let x = 5000000000l
          let y = 18446744073709551615ul
          return 0
    MT

    check_source(source)
  end
end

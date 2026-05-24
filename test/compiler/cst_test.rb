# frozen_string_literal: true

require_relative "../test_helper"

class MilkTeaCSTTest < Minitest::Test
  def test_reconstruct_round_trips_original_source
    source = <<~MT
      function main() -> int:
          let value = 42
          return value
    MT

    cst = MilkTea::CSTBuilder.build(source)

    assert_equal source, cst.reconstruct
  end

  def test_reconstruct_normalized_collapses_inter_token_spaces
    source = <<~MT

function  main() -> int:
    let   value: int =  42
    return  value

    MT

    cst = MilkTea::CSTBuilder.build(source)

    expected = <<~MT

function main() -> int:
    let value: int = 42
    return value

    MT

    assert_equal expected, cst.reconstruct_normalized
  end
end

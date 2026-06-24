# frozen_string_literal: true

require_relative "../test_helper"

class IRJsonTest < Minitest::Test
  def compile_and_roundtrip(source)
    Dir.mktmpdir("mt-irjson-test") do |dir|
      path = File.join(dir, "test.mt")
      File.write(path, source)

      loader = MilkTea::ModuleLoader.new
      program = loader.check_program(path)
      ir = MilkTea::Lowering.lower(program)

      rt_ir = MilkTea::IRJson.round_trip(ir)

      orig_c = MilkTea::CBackend.generate_c(ir)
      rt_c = MilkTea::CBackend.generate_c(rt_ir)

      [ir, rt_ir, orig_c, rt_c]
    end
  end

  def test_simple_functions_roundtrip
    source = <<~MT
      function add(a: int, b: int) -> int:
          return a + b

      function main() -> int:
          return add(1, 2)
    MT

    _, _, orig, rt = compile_and_roundtrip(source)
    assert_equal orig, rt
  end

  def test_struct_with_fields_roundtrip
    source = <<~MT
      struct Point:
          x: float
          y: float

      function main() -> int:
          let p: Point
          return 0
    MT

    _, _, orig, rt = compile_and_roundtrip(source)
    assert_equal orig, rt
  end

  def test_enum_roundtrip
    source = <<~MT
      enum Color: ubyte
          red = 0
          green = 1
          blue = 2

      function main() -> int:
          let c = Color.red
          return 0
    MT

    _, _, orig, rt = compile_and_roundtrip(source)
    assert_equal orig, rt
  end

  def test_json_serialization_shape
    source = <<~MT
      function main() -> int:
          return 0
    MT

    ir, _, _, _ = compile_and_roundtrip(source)
    json = MilkTea::IRJson.serialize_to_json(ir)
    parsed = JSON.parse(json)

    assert_equal "Program", parsed["$type"]
    assert parsed["functions"].is_a?(Array)
    refute_empty parsed["functions"]
  end
end

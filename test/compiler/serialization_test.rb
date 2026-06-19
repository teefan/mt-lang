# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/milk_tea/core/serialization"

class SerializationTest < Minitest::Test
  def test_roundtrip_tokens
    source = <<~MT
      # module demo.main

      const X: int = 42

      function main() -> int:
          return X
    MT

    tokens = MilkTea::Lexer.lex(source)
    json = MilkTea::Serialization.serialize_tokens(tokens)
    restored = MilkTea::Serialization.deserialize_tokens(json)

    assert_equal tokens.length, restored.length
    tokens.zip(restored).each do |orig, rest|
      assert_equal orig.type, rest.type
      assert_equal orig.lexeme, rest.lexeme
      assert_equal orig.line, rest.line
      assert_equal orig.column, rest.column
    end
  end

  def test_roundtrip_tokens_with_trivia
    source = <<~MT
      # module demo.main

      const X: int = 42

      // a comment
      function main() -> int:
          return X
    MT

    tokens = MilkTea::Lexer.lex(source, mode: :with_trivia)
    json = MilkTea::Serialization.serialize_tokens(tokens)
    restored = MilkTea::Serialization.deserialize_tokens(json)

    assert_equal tokens.length, restored.length
  end

  def test_roundtrip_ast
    source = <<~MT
      # module demo.main

      struct Vec2:
          x: double
          y: double

      function main() -> int:
          return 0
    MT

    ast = MilkTea::Parser.parse(source)
    json = MilkTea::Serialization.serialize_ast(ast)
    restored = MilkTea::Serialization.deserialize_ast(json)

    assert_equal ast.module_name.to_s, restored.module_name.to_s
    assert_equal ast.module_kind.to_s, restored.module_kind.to_s
    assert_equal ast.declarations.length, restored.declarations.length
    assert_equal ast.declarations.first.name, restored.declarations.first.name
  end

  def test_roundtrip_ast_with_node_ids
    source = <<~MT
      # module demo.main

      const X: int = 42

      function main() -> int:
          return X
    MT

    ast = MilkTea::Parser.parse(source)
    json = MilkTea::Serialization.serialize_ast(ast)
    restored = MilkTea::Serialization.deserialize_ast(json)

    refute_empty ast.node_ids
    assert_equal ast.node_ids.length, restored.node_ids.length
  end

  def test_roundtrip_ir_program
    source = <<~MT
      # module demo.main

      const X: int = 42

      function main() -> int:
          return X
    MT

    program = check_program(source)
    ir_program = MilkTea::Lowering.lower(program)

    json = MilkTea::Serialization.serialize_program(ir_program)
    restored = MilkTea::Serialization.deserialize_program(json)

    assert_equal ir_program.module_name, restored.module_name
    assert_equal ir_program.constants.length, restored.constants.length
    assert_equal ir_program.functions.length, restored.functions.length
  end

  def test_roundtrip_produces_valid_c
    source = <<~MT
      # module demo.main

      function main() -> int:
          return 42
    MT

    program = check_program(source)
    ir_program = MilkTea::Lowering.lower(program)

    json = MilkTea::Serialization.serialize_program(ir_program)
    restored = MilkTea::Serialization.deserialize_program(json)

    original_c = MilkTea::Codegen.generate_c(ir_program)
    restored_c = MilkTea::Codegen.generate_c(restored)

    assert_equal original_c, restored_c
  end

  private

  def check_program(source)
    Dir.mktmpdir("serialization-test") do |dir|
      path = File.join(dir, "demo", "main.mt")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, source)

      MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root]).check_program(path)
    end
  end
end

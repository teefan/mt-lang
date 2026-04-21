# frozen_string_literal: true

require_relative "test_helper"

class MilkTeaParserTest < Minitest::Test
  def test_parses_demo_file_into_expected_ast_shape
    ast = MilkTea::Parser.parse(File.read(demo_path), path: demo_path)

    assert_equal "demo.bouncing_ball", ast.module_name.to_s
    assert_equal 1, ast.imports.length
    assert_equal "std.c.raylib", ast.imports.first.path.to_s
    assert_equal "rl", ast.imports.first.alias_name
    assert_equal(
      %w[ConstDecl ConstDecl ConstDecl StructDecl ImplBlock FunctionDef],
      ast.declarations.map { |node| node.class.name.split("::").last },
    )

    struct_decl = ast.declarations[3]
    assert_equal "Ball", struct_decl.name
    assert_equal %w[position velocity radius color], struct_decl.fields.map(&:name)

    impl_block = ast.declarations[4]
    assert_equal "Ball", impl_block.type_name.to_s
    assert_equal %w[update draw], impl_block.methods.map(&:name)

    update_method = impl_block.methods.first
    assert_equal 4, update_method.body.length
    assert_instance_of MilkTea::AST::Assignment, update_method.body[0]
    assert_instance_of MilkTea::AST::Assignment, update_method.body[1]
    assert_instance_of MilkTea::AST::IfStmt, update_method.body[2]
    assert_instance_of MilkTea::AST::IfStmt, update_method.body[3]

    main_fn = ast.declarations[5]
    assert_equal "main", main_fn.name
    assert_equal 6, main_fn.body.length

    ball_decl = main_fn.body[3]
    assert_instance_of MilkTea::AST::LocalDecl, ball_decl
    assert_equal :var, ball_decl.kind
    assert_instance_of MilkTea::AST::Call, ball_decl.value
    assert_equal %w[position velocity radius color], ball_decl.value.arguments.map(&:name)

    while_stmt = main_fn.body[4]
    assert_instance_of MilkTea::AST::WhileStmt, while_stmt
    assert_instance_of MilkTea::AST::UnaryOp, while_stmt.condition
    assert_equal "not", while_stmt.condition.operator
  end

  def test_parses_if_elif_else_chains
    source = <<~MT
      module demo.flow

      def main() -> i32:
          if ready:
              return 1
          elif fallback:
              return 2
          else:
              return 3
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    if_stmt = main_fn.body.first

    assert_instance_of MilkTea::AST::IfStmt, if_stmt
    assert_equal 2, if_stmt.branches.length
    assert_equal 1, if_stmt.else_body.length
  end

  def test_parses_generic_nullable_types_and_bare_returns
    source = <<~MT
      module demo.types

      const missing: ptr[Window]? = null
      const ready: bool = true
      const title: cstr = c"Hello"

      def load(buffer: span[u8]) -> ptr[Window]?:
          return
    MT

    ast = MilkTea::Parser.parse(source)

    missing = ast.declarations[0]
    assert_equal "ptr", missing.type.name.to_s
    assert_equal true, missing.type.nullable
    assert_equal "Window", missing.type.arguments.first.value.name.to_s
    assert_instance_of MilkTea::AST::NullLiteral, missing.value

    ready = ast.declarations[1]
    assert_instance_of MilkTea::AST::BooleanLiteral, ready.value
    assert_equal true, ready.value.value

    title = ast.declarations[2]
    assert_instance_of MilkTea::AST::StringLiteral, title.value
    assert_equal true, title.value.cstring

    load = ast.declarations[3]
    assert_equal "span", load.params.first.type.name.to_s
    assert_equal "u8", load.params.first.type.arguments.first.value.name.to_s
    assert_equal true, load.return_type.nullable
    assert_nil load.body.first.value
  end

  def test_rejects_untyped_non_self_parameters
    source = <<~MT
      module demo.bad

      def bad(value):
          return 0
    MT

    error = assert_raises(MilkTea::ParseError) do
      MilkTea::Parser.parse(source)
    end

    assert_match(/expected ':' and parameter type/, error.message)
  end

  private

  def demo_path
    File.expand_path("../examples/milk-tea-demo.mt", __dir__)
  end
end

# frozen_string_literal: true

require_relative "test_helper"

class MilkTeaParserTest < Minitest::Test
  def test_parses_demo_file_into_expected_ast_shape
    ast = MilkTea::Parser.parse(File.read(demo_path), path: demo_path)

    assert_equal "demo.bouncing_ball", ast.module_name.to_s
    assert_equal :module, ast.module_kind
    assert_equal [], ast.directives
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

  def test_parses_function_type_aliases
    source = <<~MT
      module demo.callbacks

      type LogCallback = fn(level: i32, message: cstr, user_data: ptr[void]) -> void
    MT

    ast = MilkTea::Parser.parse(source)
    callback = ast.declarations.first

    assert_equal "LogCallback", callback.name
    assert_instance_of MilkTea::AST::FunctionType, callback.target
    assert_equal %w[level message user_data], callback.target.params.map(&:name)
    assert_equal "i32", callback.target.params[0].type.name.to_s
    assert_equal "ptr", callback.target.params[2].type.name.to_s
    assert_equal "void", callback.target.return_type.name.to_s
  end

  def test_parses_keyword_names_in_struct_fields_and_member_access
    source = <<~MT
      module demo.keywords

      struct Event:
          type: i32

      def main(event: Event) -> i32:
          let copy = Event(type = event.type)
          return copy.type
    MT

    ast = MilkTea::Parser.parse(source)
    event_decl = ast.declarations[0]
    main_fn = ast.declarations[1]
    local_decl = main_fn.body[0]

    assert_equal "type", event_decl.fields.first.name
    assert_equal "type", local_decl.value.arguments.first.name
    assert_equal "type", local_decl.value.arguments.first.value.member
    assert_equal "type", main_fn.body[1].value.member
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

  def test_parses_extern_module_declarations
    source = <<~MT
      extern module std.c.raylib:
          link "raylib"
          include "raylib.h"

          struct Color:
              r: u8
              g: u8
              b: u8
              a: u8

          const BLACK: Color = Color(r = 0, g = 0, b = 0, a = 255)

          enum LogLevel: i32
              info = 1
              warning = 2

          flags WindowFlags: u32
              visible = 1 << 0

          union Number:
              i: i32
              f: f32

          opaque SDL_Window
          extern def InitWindow(width: i32, height: i32, title: cstr) -> void
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal :extern_module, ast.module_kind
    assert_equal "std.c.raylib", ast.module_name.to_s
    assert_equal %w[LinkDirective IncludeDirective], ast.directives.map { |node| node.class.name.split("::").last }
    assert_equal(
      %w[StructDecl ConstDecl EnumDecl FlagsDecl UnionDecl OpaqueDecl ExternFunctionDecl],
      ast.declarations.map { |node| node.class.name.split("::").last },
    )

    const_decl = ast.declarations[1]
    assert_equal "BLACK", const_decl.name
    assert_equal "Color", const_decl.type.name.to_s
    assert_instance_of MilkTea::AST::Call, const_decl.value

    flags_decl = ast.declarations[3]
    assert_equal "WindowFlags", flags_decl.name
    assert_equal "u32", flags_decl.backing_type.name.to_s
    assert_instance_of MilkTea::AST::BinaryOp, flags_decl.members.first.value
    assert_equal "<<", flags_decl.members.first.value.operator

    extern_def = ast.declarations.last
    assert_equal "InitWindow", extern_def.name
    assert_equal "void", extern_def.return_type.name.to_s
  end

  private

  def demo_path
    File.expand_path("../examples/milk-tea-demo.mt", __dir__)
  end
end

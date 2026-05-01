# frozen_string_literal: true

require_relative "../test_helper"

class MilkTeaParserTest < Minitest::Test
  def test_parses_demo_file_into_expected_ast_shape
    ast = MilkTea::Parser.parse(File.read(demo_path), path: demo_path)

    assert_equal "demo.bouncing_ball", ast.module_name.to_s
    assert_equal :module, ast.module_kind
    assert_equal [], ast.directives
    assert_equal 1, ast.imports.length
    assert_equal "std.raylib", ast.imports.first.path.to_s
    assert_equal "rl", ast.imports.first.alias_name
    assert_equal(
      %w[ConstDecl ConstDecl ConstDecl StructDecl MethodsBlock FunctionDef],
      ast.declarations.map { |node| node.class.name.split("::").last },
    )

    struct_decl = ast.declarations[3]
    assert_equal "Ball", struct_decl.name
    assert_equal %w[position velocity radius color], struct_decl.fields.map(&:name)

    methods_block = ast.declarations[4]
    assert_equal "Ball", methods_block.type_name.to_s
    assert_equal %w[update draw], methods_block.methods.map(&:name)

    update_method = methods_block.methods.first
    assert_equal :edit, update_method.kind
    assert_equal 4, update_method.body.length
    assert_instance_of MilkTea::AST::Assignment, update_method.body[0]
    assert_instance_of MilkTea::AST::Assignment, update_method.body[1]
    assert_instance_of MilkTea::AST::IfStmt, update_method.body[2]
    assert_instance_of MilkTea::AST::IfStmt, update_method.body[3]

    draw_method = methods_block.methods[1]
    assert_equal :plain, draw_method.kind

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

  def test_parses_public_declarations_and_methods
    source = <<~MT
      module demo.visibility

      pub const answer: i32 = 42
      pub var counter: i32 = 0
      pub type Score = i32

      pub struct Counter:
          value: i32

      methods Counter:
          pub def read() -> i32:
              return this.value

          def bump() -> void:
              this.value += 1

      pub def make_counter() -> Counter:
          return Counter(value = 0)
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal :public, ast.declarations[0].visibility
    assert_equal :public, ast.declarations[1].visibility
    assert_equal :public, ast.declarations[2].visibility
    assert_equal :public, ast.declarations[3].visibility
    assert_equal :public, ast.declarations[5].visibility

    assert_instance_of MilkTea::AST::VarDecl, ast.declarations[1]

    methods_block = ast.declarations[4]
    assert_equal :public, methods_block.methods[0].visibility
    assert_equal :private, methods_block.methods[1].visibility
  end

  def test_parses_module_scope_vars_with_and_without_initializer
    source = <<~MT
      module demo.globals

      var counter: i32 = 0
      pub var scratch: array[u8, 16]

      def main() -> i32:
          counter += 1
          return counter
    MT

    ast = MilkTea::Parser.parse(source)

    assert_instance_of MilkTea::AST::VarDecl, ast.declarations[0]
    assert_equal "counter", ast.declarations[0].name
    assert_instance_of MilkTea::AST::IntegerLiteral, ast.declarations[0].value

    assert_instance_of MilkTea::AST::VarDecl, ast.declarations[1]
    assert_equal :public, ast.declarations[1].visibility
    assert_nil ast.declarations[1].value
  end

  def test_parses_extern_opaque_with_explicit_c_name
    source = <<~MT
      extern module std.c.time:
          opaque tm = c"struct tm"
    MT

    ast = MilkTea::Parser.parse(source)
    opaque_decl = ast.declarations.first

    assert_instance_of MilkTea::AST::OpaqueDecl, opaque_decl
    assert_equal "tm", opaque_decl.name
    assert_equal "struct tm", opaque_decl.c_name
  end

  def test_parses_leading_imports_inside_extern_modules
    source = <<~MT
      extern module std.c.helper:
          import std.c.dep as dep

          include "helper.h"

          struct Holder:
              value: dep.Vec
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal :extern_module, ast.module_kind
    assert_equal 1, ast.imports.length
    assert_equal "std.c.dep", ast.imports.first.path.to_s
    assert_equal "dep", ast.imports.first.alias_name
    assert_equal 1, ast.directives.length
    assert_equal 1, ast.declarations.length
  end

  def test_rejects_pub_on_methods_block
    source = <<~MT
      module demo.visibility

      pub methods Counter:
          def read() -> i32:
              return 0
    MT

    error = assert_raises(MilkTea::ParseError) { MilkTea::Parser.parse(source) }

    assert_match(/pub is not allowed on methods blocks/, error.message)
  end

  def test_parses_if_expression
    source = <<~MT
      module demo.expr

      def main(ready: bool) -> i32:
          return if ready then 1 else 0
    MT

    ast = MilkTea::Parser.parse(source)
    return_stmt = ast.declarations.first.body.first

    assert_instance_of MilkTea::AST::ReturnStmt, return_stmt
    assert_instance_of MilkTea::AST::IfExpr, return_stmt.value
    assert_instance_of MilkTea::AST::Identifier, return_stmt.value.condition
    assert_instance_of MilkTea::AST::IntegerLiteral, return_stmt.value.then_expression
    assert_instance_of MilkTea::AST::IntegerLiteral, return_stmt.value.else_expression
  end

  def test_parses_async_functions_and_await_expressions
    source = <<~MT
      module demo.async_expr

      async def compute() -> i32:
          let value = await child()
          return value

      async def child() -> i32:
          return 41
    MT

    ast = MilkTea::Parser.parse(source)
    compute = ast.declarations.first
    local_decl = compute.body.first

    assert_equal true, compute.async
    assert_instance_of MilkTea::AST::LocalDecl, local_decl
    assert_instance_of MilkTea::AST::AwaitExpr, local_decl.value
    assert_instance_of MilkTea::AST::Call, local_decl.value.expression
  end

  def test_parses_scientific_float_literals
    source = <<~MT
      module demo.float_literals

      const epsilon: f32 = 1.1920929E-7

      def main() -> f32:
          return epsilon
    MT

    ast = MilkTea::Parser.parse(source)
    const_decl = ast.declarations.first

    assert_instance_of MilkTea::AST::FloatLiteral, const_decl.value
    assert_equal "1.1920929E-7", const_decl.value.lexeme
    assert_in_delta 1.1920929e-7, const_decl.value.value, 1e-15
  end

  def test_parses_return_boolean_chain_without_forced_parentheses
    source = <<~MT
      module demo.expr

      def main(a: bool, b: bool, c: bool) -> bool:
          return a and b or c
    MT

    ast = MilkTea::Parser.parse(source)
    return_stmt = ast.declarations.first.body.first

    assert_instance_of MilkTea::AST::ReturnStmt, return_stmt
    assert_instance_of MilkTea::AST::BinaryOp, return_stmt.value
    assert_equal "or", return_stmt.value.operator
    assert_instance_of MilkTea::AST::BinaryOp, return_stmt.value.left
    assert_equal "and", return_stmt.value.left.operator
  end

  def test_parses_format_string_literal
    source = <<~MT
      module demo.format

      import std.fmt as fmt
      import std.string as string

      def main(count: i32) -> i32:
          let text = fmt.string(f"count=\#{count} ok=\#{true}")
          return i32<-text.count()
    MT

    ast = MilkTea::Parser.parse(source)
    local_decl = ast.declarations.first.body.first
    format_string = local_decl.value.arguments.first.value

    assert_instance_of MilkTea::AST::FormatString, format_string
    assert_equal 4, format_string.parts.length
    assert_instance_of MilkTea::AST::FormatTextPart, format_string.parts[0]
    assert_instance_of MilkTea::AST::FormatExprPart, format_string.parts[1]
    assert_equal "count=", format_string.parts[0].value
    assert_instance_of MilkTea::AST::Identifier, format_string.parts[1].expression
  end

  def test_parses_prefix_cast_with_identifier_rhs
    source = <<~MT
      module demo.prefix_cast

      def main(value: f32) -> i32:
          return i32<-value
    MT

    ast = MilkTea::Parser.parse(source)
    return_stmt = ast.declarations.first.body.first

    assert_instance_of MilkTea::AST::ReturnStmt, return_stmt
    assert_instance_of MilkTea::AST::Call, return_stmt.value
    assert_equal "cast", return_stmt.value.callee.callee.name
    assert_equal "i32", return_stmt.value.callee.arguments.first.value.name.to_s
    assert_instance_of MilkTea::AST::Identifier, return_stmt.value.arguments.first.value
    assert_equal "value", return_stmt.value.arguments.first.value.name
  end

  def test_parses_prefix_cast_with_parenthesized_rhs
    source = <<~MT
      module demo.prefix_cast

      def main(a: i32, b: i32) -> u8:
          return u8<-(a - b)
    MT

    ast = MilkTea::Parser.parse(source)
    return_stmt = ast.declarations.first.body.first

    assert_instance_of MilkTea::AST::ReturnStmt, return_stmt
    assert_instance_of MilkTea::AST::Call, return_stmt.value
    assert_equal "cast", return_stmt.value.callee.callee.name
    assert_equal "u8", return_stmt.value.callee.arguments.first.value.name.to_s
    assert_instance_of MilkTea::AST::BinaryOp, return_stmt.value.arguments.first.value
    assert_equal "-", return_stmt.value.arguments.first.value.operator
  end

  def test_parses_nested_prefix_casts
    source = <<~MT
      module demo.prefix_cast

      def main(value: i32) -> f64:
          return f64<-f32<-value
    MT

    ast = MilkTea::Parser.parse(source)
    return_stmt = ast.declarations.first.body.first

    assert_instance_of MilkTea::AST::Call, return_stmt.value
    assert_equal "f64", return_stmt.value.callee.arguments.first.value.name.to_s
    inner = return_stmt.value.arguments.first.value
    assert_instance_of MilkTea::AST::Call, inner
    assert_equal "f32", inner.callee.arguments.first.value.name.to_s
  end

  def test_parses_for_range_statement
    source = <<~MT
      module demo.flow

      def main(count: i32) -> i32:
          for i in range(0, count):
              tick(i)
          return 0
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    for_stmt = main_fn.body.first

    assert_instance_of MilkTea::AST::ForStmt, for_stmt
    assert_equal "i", for_stmt.name
    assert_instance_of MilkTea::AST::Call, for_stmt.iterable
    assert_instance_of MilkTea::AST::Identifier, for_stmt.iterable.callee
    assert_equal "range", for_stmt.iterable.callee.name
    assert_equal 2, for_stmt.iterable.arguments.length
    assert_instance_of MilkTea::AST::ExpressionStmt, for_stmt.body.first
  end

  def test_parses_for_collection_statement
    source = <<~MT
      module demo.flow

      def main(items: span[i32]) -> i32:
          for item in items:
              tick(item)
          return 0
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    for_stmt = main_fn.body.first

    assert_instance_of MilkTea::AST::ForStmt, for_stmt
    assert_equal "item", for_stmt.name
    assert_instance_of MilkTea::AST::Identifier, for_stmt.iterable
    assert_equal "items", for_stmt.iterable.name
    assert_instance_of MilkTea::AST::ExpressionStmt, for_stmt.body.first
  end

  def test_parses_defer_block_statement
    source = <<~MT
      module demo.cleanup

      def main() -> void:
          defer:
              first_cleanup()
              second_cleanup()
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    defer_stmt = main_fn.body.first

    assert_instance_of MilkTea::AST::DeferStmt, defer_stmt
    assert_nil defer_stmt.expression
    assert_equal 2, defer_stmt.body.length
    assert_instance_of MilkTea::AST::ExpressionStmt, defer_stmt.body[0]
    assert_instance_of MilkTea::AST::ExpressionStmt, defer_stmt.body[1]
  end

  def test_parses_variant_declarations_and_as_binding_in_match
    source = <<~MT
      module demo.variant_parse

      variant Shape:
          circle(radius: f64)
          rect(w: f64, h: f64)
          point

      def area(s: Shape) -> f64:
          match s:
              Shape.circle as c:
                  return 3.14 * c.radius * c.radius
              Shape.rect as r:
                  return r.w * r.h
              Shape.point:
                  return 0.0
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal 2, ast.declarations.length
    variant_decl = ast.declarations[0]
    assert_instance_of MilkTea::AST::VariantDecl, variant_decl
    assert_equal "Shape", variant_decl.name
    assert_equal %w[circle rect point], variant_decl.arms.map(&:name)
    assert_equal %w[radius], variant_decl.arms[0].fields.map(&:name)
    assert_equal %w[w h], variant_decl.arms[1].fields.map(&:name)
    assert_equal [], variant_decl.arms[2].fields

    fn = ast.declarations[1]
    match_stmt = fn.body.first
    assert_instance_of MilkTea::AST::MatchStmt, match_stmt
    assert_equal "c", match_stmt.arms[0].binding_name
    assert_equal "r", match_stmt.arms[1].binding_name
    assert_nil match_stmt.arms[2].binding_name
  end

  def test_parses_break_and_continue_inside_match_arms
    source = <<~MT
      module demo.flow

      enum Step: u8
          skip = 1
          keep = 2
          stop = 3

      def main(items: array[Step, 3]) -> i32:
          for step in items:
              match step:
                  Step.skip:
                      continue
                  Step.keep:
                      break
                  Step.stop:
                      return 0
          return 1
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations[1]
    for_stmt = main_fn.body.first
    match_stmt = for_stmt.body.first

    assert_instance_of MilkTea::AST::ForStmt, for_stmt
    assert_instance_of MilkTea::AST::MatchStmt, match_stmt
    assert_instance_of MilkTea::AST::ContinueStmt, match_stmt.arms[0].body.first
    assert_instance_of MilkTea::AST::BreakStmt, match_stmt.arms[1].body.first
  end

  def test_parses_layout_queries_and_static_assert
    source = <<~MT
      module demo.layout

      struct Header:
          magic: array[u8, 4]
          version: u16

      static_assert(sizeof(Header) >= 6, "Header must include version")

      def main() -> usize:
          return offsetof(Header, version) + alignof(Header)
    MT

    ast = MilkTea::Parser.parse(source)
    static_assert = ast.declarations[1]
    main_fn = ast.declarations[2]
    return_stmt = main_fn.body.first

    assert_instance_of MilkTea::AST::StaticAssert, static_assert
    assert_instance_of MilkTea::AST::BinaryOp, static_assert.condition
    assert_instance_of MilkTea::AST::SizeofExpr, static_assert.condition.left
    assert_instance_of MilkTea::AST::StringLiteral, static_assert.message
    assert_instance_of MilkTea::AST::BinaryOp, return_stmt.value
    assert_instance_of MilkTea::AST::OffsetofExpr, return_stmt.value.left
    assert_instance_of MilkTea::AST::AlignofExpr, return_stmt.value.right
  end

  def test_parses_packed_and_aligned_struct_declarations
    source = <<~MT
      module demo.layout

      packed struct Header:
          tag: u8
          value: u32

      align(16) struct Mat4:
          data: array[f32, 16]
    MT

    ast = MilkTea::Parser.parse(source)
    header = ast.declarations[0]
    mat4 = ast.declarations[1]

    assert_equal true, header.packed
    assert_nil header.alignment
    assert_equal false, mat4.packed
    assert_equal 16, mat4.alignment
  end

  def test_parses_unsafe_reinterpret_specialization_call
    source = <<~MT
      module demo.bits

      def main() -> u32:
          let value: f32 = 1.0
          unsafe:
              let bits = reinterpret[u32](value)
              return bits
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations[0]
    unsafe_stmt = main_fn.body[1]
    bits_decl = unsafe_stmt.body[0]

    assert_instance_of MilkTea::AST::UnsafeStmt, unsafe_stmt
    assert_instance_of MilkTea::AST::Call, bits_decl.value
    assert_instance_of MilkTea::AST::Specialization, bits_decl.value.callee
    assert_equal "reinterpret", bits_decl.value.callee.callee.name
    assert_equal "u32", bits_decl.value.callee.arguments.first.value.name.to_s
  end

  def test_parses_match_statement_with_enum_member_arms
    source = <<~MT
      module demo.flow

      enum EventKind: u8
          quit = 1
          resize = 2

      def main(kind: EventKind) -> i32:
          match kind:
              EventKind.quit:
                  return 0
              EventKind.resize:
                  return 1
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations[1]
    match_stmt = main_fn.body.first

    assert_instance_of MilkTea::AST::MatchStmt, match_stmt
    assert_instance_of MilkTea::AST::Identifier, match_stmt.expression
    assert_equal "kind", match_stmt.expression.name
    assert_equal 2, match_stmt.arms.length
    assert_instance_of MilkTea::AST::MemberAccess, match_stmt.arms[0].pattern
    assert_equal "quit", match_stmt.arms[0].pattern.member
    assert_instance_of MilkTea::AST::ReturnStmt, match_stmt.arms[0].body.first
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

  def test_parses_typed_null_pointer_literals
    source = <<~MT
      module demo.typed_null

      const missing: ptr[char]? = null[ptr[char]]
    MT

    ast = MilkTea::Parser.parse(source)

    missing = ast.declarations[0]
    assert_instance_of MilkTea::AST::NullLiteral, missing.value
    assert_equal "ptr", missing.value.type.name.to_s
    assert_equal "char", missing.value.type.arguments.first.value.name.to_s
  end

  def test_parses_const_pointer_types_and_ro_addr_calls
    source = <<~MT
      module demo.const_pointers

      extern def inspect(values: const_ptr[i32]) -> void

      def main() -> void:
          let value = 7
          inspect(const_ptr_of(value))
    MT

    ast = MilkTea::Parser.parse(source)

    inspect_fn = ast.declarations[0]
    assert_equal "const_ptr", inspect_fn.params.first.type.name.to_s
    assert_equal "i32", inspect_fn.params.first.type.arguments.first.value.name.to_s

    main_fn = ast.declarations[1]
    inspect_call = main_fn.body[1].expression
    assert_instance_of MilkTea::AST::Call, inspect_call
    assert_equal "inspect", inspect_call.callee.name

    ro_addr_call = inspect_call.arguments.first.value
    assert_instance_of MilkTea::AST::Call, ro_addr_call
    assert_equal "const_ptr_of", ro_addr_call.callee.name
  end

  def test_parses_generic_struct_declaration_and_constructor_call
    source = <<~MT
      module demo.generics

      struct Slice[T]:
          data: ptr[T]
          len: usize

      def main() -> i32:
          let value = 7
          let items = Slice[i32](data = ptr_of(ref_of(value)), len = 1)
          return items.len
    MT

    ast = MilkTea::Parser.parse(source)
    slice = ast.declarations.first

    assert_equal "Slice", slice.name
    assert_equal ["T"], slice.type_params.map(&:name)
    assert_equal "ptr", slice.fields.first.type.name.to_s
    assert_equal "T", slice.fields.first.type.arguments.first.value.name.to_s

    main_fn = ast.declarations[1]
    constructor = main_fn.body[1].value

    assert_instance_of MilkTea::AST::Call, constructor
    assert_instance_of MilkTea::AST::Specialization, constructor.callee
    assert_equal "Slice", constructor.callee.callee.name
    assert_equal "i32", constructor.callee.arguments.first.value.name.to_s
    assert_equal %w[data len], constructor.arguments.map(&:name)
  end

  def test_parses_generic_function_definition
    source = <<~MT
      module demo.generic_functions

      struct Slice[T]:
          data: ptr[T]
          len: usize

      def first[T](items: Slice[T]) -> ptr[T]?:
          return items.data
    MT

    ast = MilkTea::Parser.parse(source)
    function = ast.declarations[1]

    assert_equal "first", function.name
    assert_equal ["T"], function.type_params.map(&:name)
    assert_equal "Slice", function.params.first.type.name.to_s
    assert_equal "T", function.params.first.type.arguments.first.value.name.to_s
    assert_equal "ptr", function.return_type.name.to_s
    assert_equal true, function.return_type.nullable
  end

  def test_parses_indexed_call_instead_of_generic_specialization
    source = <<~MT
      module demo.index_call

      def main() -> i32:
          return callbacks[0](1)
    MT

    ast = MilkTea::Parser.parse(source)
    call = ast.declarations.first.body.first.value

    assert_instance_of MilkTea::AST::Call, call
    assert_instance_of MilkTea::AST::IndexAccess, call.callee
  end

  def test_parses_callable_value_storage_and_indirect_calls
    source = <<~MT
      module demo.callable_values

      struct Entry:
          callback: fn(value: f32) -> f32

      def ease(value: f32) -> f32:
          return value

      def main() -> i32:
          let callbacks = array[fn(value: i32) -> i32, 1](cast[fn(value: i32) -> i32](identity))
          let entry = Entry(callback = ease)
          let callback: fn(value: f32) -> f32 = entry.callback
          let left = callbacks[0](1)
          let right = callback(1.0)
          return i32<-right + left

      def identity(value: i32) -> i32:
          return value
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations[2]

    callbacks_decl = main_fn.body[0]
    assert_equal "array", callbacks_decl.value.callee.callee.name
    assert_instance_of MilkTea::AST::FunctionType, callbacks_decl.value.callee.arguments[0].value

    entry_decl = main_fn.body[1]
    assert_instance_of MilkTea::AST::Call, entry_decl.value
    assert_equal "Entry", entry_decl.value.callee.name

    left_decl = main_fn.body[3]
    assert_instance_of MilkTea::AST::Call, left_decl.value
    assert_instance_of MilkTea::AST::IndexAccess, left_decl.value.callee

    right_decl = main_fn.body[4]
    assert_instance_of MilkTea::AST::Call, right_decl.value
    assert_instance_of MilkTea::AST::Identifier, right_decl.value.callee
    assert_equal "callback", right_decl.value.callee.name
  end

  def test_parses_proc_type_refs_in_function_parameters
    source = <<~MT
      module demo.proc_params

      def apply(callback: proc(value: i32) -> i32, value: i32) -> i32:
          return callback(value)
    MT

    ast = MilkTea::Parser.parse(source)
    apply_fn = ast.declarations.first
    callback_param = apply_fn.params.first

    assert_instance_of MilkTea::AST::ProcType, callback_param.type
    assert_equal "value", callback_param.type.params.first.name
    assert_equal "i32", callback_param.type.return_type.name.to_s
  end

  def test_parses_proc_expressions
    source = <<~MT
      module demo.proc_values

      def main() -> i32:
          let offset = 4
          let callback = proc(value: i32) -> i32:
              return value + offset
          return callback(3)
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    callback_decl = main_fn.body[1]

    assert_instance_of MilkTea::AST::LocalDecl, callback_decl
    assert_instance_of MilkTea::AST::ProcExpr, callback_decl.value
    assert_equal "i32", callback_decl.value.return_type.name.to_s
    assert_equal "value", callback_decl.value.params.first.name
    assert_equal "i32", callback_decl.value.params.first.type.name.to_s
  end

  def test_parses_explicit_generic_function_specialization_call
    source = <<~MT
      module demo.generic_call

      def bytes_for[T](count: usize) -> usize:
          return count

      def main() -> i32:
          return i32<-bytes_for[i32](4)
    MT

    ast = MilkTea::Parser.parse(source)
    call = ast.declarations[1].body.first.value.arguments.first.value

    assert_instance_of MilkTea::AST::Call, call
    assert_instance_of MilkTea::AST::Specialization, call.callee
    assert_equal "bytes_for", call.callee.callee.name
    assert_equal "i32", call.callee.arguments.first.value.name.to_s
  end

  def test_parses_explicit_generic_function_literal_specialization_call
    source = <<~MT
      module demo.generic_literal_call

      def capacity_of[N](buffer: str_builder[N]) -> usize:
          return buffer.capacity()

      def main() -> i32:
          var buffer: str_builder[32]
          return i32<-capacity_of[32](buffer)
    MT

    ast = MilkTea::Parser.parse(source)
    call = ast.declarations[1].body[1].value.arguments.first.value

    assert_instance_of MilkTea::AST::Call, call
    assert_instance_of MilkTea::AST::Specialization, call.callee
    assert_equal "capacity_of", call.callee.callee.name
    assert_equal 32, call.callee.arguments.first.value.value
  end

  def test_parses_explicit_generic_function_named_const_specialization_call
    source = <<~MT
      module demo.generic_named_const_call

      const CAPACITY: i32 = 32

      def capacity_of[N](buffer: str_builder[N]) -> usize:
          return buffer.capacity()

      def main() -> i32:
          var buffer: str_builder[CAPACITY]
          return i32<-capacity_of[CAPACITY](buffer)
    MT

    ast = MilkTea::Parser.parse(source)
    call = ast.declarations[2].body[1].value.arguments.first.value

    assert_instance_of MilkTea::AST::Call, call
    assert_instance_of MilkTea::AST::Specialization, call.callee
    assert_equal "capacity_of", call.callee.callee.name
    assert_equal "CAPACITY", call.callee.arguments.first.value.name.to_s
  end

  def test_parses_explicit_imported_member_literal_specialization_call
    source = <<~MT
      module demo.imported_generic_literal_call

      import std.ui as ui

      def main() -> i32:
          var buffer: str_builder[32]
          ui.text_box[32](buffer)
          return 0
    MT

    ast = MilkTea::Parser.parse(source)
    call = ast.declarations.first.body[1].expression

    assert_instance_of MilkTea::AST::Call, call
    assert_instance_of MilkTea::AST::Specialization, call.callee
    assert_instance_of MilkTea::AST::MemberAccess, call.callee.callee
    assert_equal "ui", call.callee.callee.receiver.name
    assert_equal "text_box", call.callee.callee.member
    assert_equal 32, call.callee.arguments.first.value.value
  end

  def test_parses_explicit_local_foreign_literal_specialization_call
    source = <<~MT
      module demo.local_generic_foreign_literal_call

      foreign def text_box[N](text: str_builder[N] as ptr[char]) -> void = c.TextBox(text)

      def main() -> i32:
          var buffer: str_builder[32]
          text_box[32](buffer)
          return 0
    MT

    ast = MilkTea::Parser.parse(source)
    call = ast.declarations[1].body[1].expression

    assert_instance_of MilkTea::AST::Call, call
    assert_instance_of MilkTea::AST::Specialization, call.callee
    assert_equal "text_box", call.callee.callee.name
    assert_equal 32, call.callee.arguments.first.value.value
  end

  def test_parses_span_constructor_calls
    source = <<~MT
      module demo.spans

      def main() -> i32:
          let view = span[i32](data = buffer, len = 3)
          return view.len
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    local_decl = main_fn.body.first

    assert_instance_of MilkTea::AST::LocalDecl, local_decl
    assert_instance_of MilkTea::AST::Call, local_decl.value
    assert_instance_of MilkTea::AST::Specialization, local_decl.value.callee
    assert_equal "span", local_decl.value.callee.callee.name
    assert_equal "i32", local_decl.value.callee.arguments.first.value.name.to_s
    assert_equal %w[data len], local_decl.value.arguments.map(&:name)
  end

  def test_parses_array_constructor_calls
    source = <<~MT
      module demo.arrays

      def main() -> i32:
          let palette = array[u32, 4](1, 2, 3, 4)
          return 0
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    local_decl = main_fn.body.first

    assert_instance_of MilkTea::AST::Call, local_decl.value
    assert_instance_of MilkTea::AST::Specialization, local_decl.value.callee
    assert_equal "array", local_decl.value.callee.callee.name
    assert_equal 2, local_decl.value.callee.arguments.length
    assert_equal "u32", local_decl.value.callee.arguments.first.value.name.to_s
    assert_equal 4, local_decl.value.callee.arguments[1].value.value
    assert_equal 4, local_decl.value.arguments.length
  end

  def test_parses_typed_local_without_initializer
    source = <<~MT
      module demo.locals

      def main() -> void:
          var buffer: array[char, 32]
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    local_decl = main_fn.body.first

    assert_instance_of MilkTea::AST::LocalDecl, local_decl
    assert_equal :var, local_decl.kind
    assert_equal "buffer", local_decl.name
    assert_equal "array", local_decl.type.name.to_s
    assert_equal "char", local_decl.type.arguments.first.value.name.to_s
    assert_equal 32, local_decl.type.arguments[1].value.value
    assert_nil local_decl.value
  end

  def test_parses_zero_constructor_calls
    source = <<~MT
      module demo.zero

      def main() -> i32:
          let palette = zero[array[u32, 4]]()
          return 0
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    local_decl = main_fn.body.first

    assert_instance_of MilkTea::AST::Call, local_decl.value
    assert_instance_of MilkTea::AST::Specialization, local_decl.value.callee
    assert_equal "zero", local_decl.value.callee.callee.name
    assert_equal 1, local_decl.value.callee.arguments.length
    array_type = local_decl.value.callee.arguments.first.value
    assert_instance_of MilkTea::AST::TypeRef, array_type
    assert_equal "array", array_type.name.to_s
    assert_equal 2, array_type.arguments.length
    assert_equal "u32", array_type.arguments.first.value.name.to_s
    assert_equal 4, array_type.arguments[1].value.value
    assert_equal 0, local_decl.value.arguments.length
  end

  def test_parses_array_char_zero_constructor_calls
    source = <<~MT
      module demo.char_array

      def main() -> i32:
          let buffer = zero[array[char, 64]]()
          return 0
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    local_decl = main_fn.body.first

    assert_instance_of MilkTea::AST::Call, local_decl.value
    assert_instance_of MilkTea::AST::Specialization, local_decl.value.callee
    assert_equal "zero", local_decl.value.callee.callee.name
    assert_equal 1, local_decl.value.callee.arguments.length
    array_type = local_decl.value.callee.arguments.first.value
    assert_instance_of MilkTea::AST::TypeRef, array_type
    assert_equal "array", array_type.name.to_s
    assert_equal "char", array_type.arguments.first.value.name.to_s
    assert_equal 64, array_type.arguments[1].value.value
    assert_equal 0, local_decl.value.arguments.length
  end

  def test_parses_partial_aggregate_and_array_constructor_calls
    source = <<~MT
      module demo.partial_literals

      struct Point:
          x: i32
          y: i32

      def main() -> i32:
          let origin = Point()
          let point = Point(x = 1)
          let palette = array[u32, 4](1, 2)
          return 0
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations[1]
    origin_decl = main_fn.body[0]
    point_decl = main_fn.body[1]
    palette_decl = main_fn.body[2]

    assert_instance_of MilkTea::AST::Call, origin_decl.value
    assert_equal "Point", origin_decl.value.callee.name
    assert_equal 0, origin_decl.value.arguments.length

    assert_instance_of MilkTea::AST::Call, point_decl.value
    assert_equal "Point", point_decl.value.callee.name
    assert_equal 1, point_decl.value.arguments.length
    assert_equal "x", point_decl.value.arguments.first.name

    assert_instance_of MilkTea::AST::Call, palette_decl.value
    assert_instance_of MilkTea::AST::Specialization, palette_decl.value.callee
    assert_equal "array", palette_decl.value.callee.callee.name
    assert_equal 2, palette_decl.value.arguments.length
  end

  def test_parses_index_access_instead_of_specialization
    source = <<~MT
      module demo.arrays

      def main() -> i32:
          unsafe:
              let value = palette[1]
          return 0
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    unsafe_stmt = main_fn.body.first
    local_decl = unsafe_stmt.body.first

    assert_instance_of MilkTea::AST::IndexAccess, local_decl.value
    assert_instance_of MilkTea::AST::Identifier, local_decl.value.receiver
    assert_instance_of MilkTea::AST::IntegerLiteral, local_decl.value.index
    assert_equal "palette", local_decl.value.receiver.name
    assert_equal 1, local_decl.value.index.value
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

  def test_parses_async_methods
    source = <<~MT
      module demo.async_methods

      struct Counter:
          value: i32

      methods Counter:
          async def read() -> i32:
              return this.value

          async edit def bump() -> void:
              this.value += 1
    MT

    ast = MilkTea::Parser.parse(source)
    methods = ast.declarations[1]

    assert_instance_of MilkTea::AST::MethodsBlock, methods
    assert_equal true, methods.methods[0].async
    assert_equal :plain, methods.methods[0].kind
    assert_equal true, methods.methods[1].async
    assert_equal :edit, methods.methods[1].kind
  end

  def test_parses_unsafe_blocks_with_pointer_cast_and_arithmetic
    source = <<~MT
      module demo.unsafe_surface

      def main(memory: ptr[void]) -> i32:
          unsafe:
              let advanced = ptr[byte]<-memory + 4
          return 0
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    unsafe_stmt = main_fn.body.first

    assert_instance_of MilkTea::AST::UnsafeStmt, unsafe_stmt
    local_decl = unsafe_stmt.body.first
    assert_instance_of MilkTea::AST::LocalDecl, local_decl
    assert_instance_of MilkTea::AST::BinaryOp, local_decl.value
    assert_equal "+", local_decl.value.operator
    assert_instance_of MilkTea::AST::Call, local_decl.value.left
  end

  def test_parses_addr_value_and_raw_calls
    source = <<~MT
      module demo.handles

      struct Counter:
          value: i32

      def main() -> i32:
          var counter = Counter(value = 3)
          let handle = ref_of(counter)
          unsafe:
              let counter_ptr = ptr_of(handle)
              counter_ptr.value = 7
          let value_ref = ref_of(handle.value)
          read(value_ref) += 2
          return handle.value
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations[1]

    handle_decl = main_fn.body[1]
    assert_instance_of MilkTea::AST::Call, handle_decl.value
    assert_equal "ref_of", handle_decl.value.callee.name

    unsafe_stmt = main_fn.body[2]
    pointer_decl = unsafe_stmt.body[0]
    assert_instance_of MilkTea::AST::Call, pointer_decl.value
    assert_equal "ptr_of", pointer_decl.value.callee.name

    assignment = unsafe_stmt.body[1]
    assert_instance_of MilkTea::AST::MemberAccess, assignment.target
    assert_instance_of MilkTea::AST::Identifier, assignment.target.receiver
    assert_equal "counter_ptr", assignment.target.receiver.name
  end

  def test_parses_extended_compound_assignment_operators
    source = <<~MT
      module demo.compound_assignments

      flags Bits: u32
          a = 1 << 0
          b = 1 << 1

      def main() -> void:
          var value = 12
          value %= 5
          value <<= 1
          value >>= 1
          var bits = Bits.a
          bits |= Bits.b
          bits &= Bits.b
          bits ^= Bits.a
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations[1]

    assignments = main_fn.body.select { |statement| statement.is_a?(MilkTea::AST::Assignment) }
    assert_equal ["%=", "<<=", ">>=", "|=", "&=", "^="], assignments.map(&:operator)
  end

  def test_rejects_legacy_pointer_sigils
    source = <<~MT
      module demo.bad

      struct Counter:
          value: i32

      def main() -> i32:
          var counter = Counter(value = 3)
          let counter_ptr = &counter
          return counter_ptr->value
    MT

    assert_raises(MilkTea::ParseError) do
      MilkTea::Parser.parse(source)
    end
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
    assert_equal false, extern_def.variadic
  end

  def test_parses_variadic_extern_function_declarations
    source = <<~MT
      extern module std.c.stdio:
          include "stdio.h"

          extern def printf(format: cstr, ...) -> i32
    MT

    ast = MilkTea::Parser.parse(source)
    extern_def = ast.declarations.last

    assert_equal "printf", extern_def.name
    assert_equal ["format"], extern_def.params.map(&:name)
    assert_equal true, extern_def.variadic
  end

  def test_parses_foreign_function_declarations_and_calls
    source = <<~MT
      module std.raylib

      import std.c.raylib as c

      pub foreign def init_window(width: i32, height: i32, title: str as cstr) -> void = c.InitWindow
      pub foreign def load_file_data(file_name: str as cstr, out data_size: i32) -> ptr[u8]? = c.LoadFileData
      pub foreign def set_shader_value[T](shader: Shader, loc_index: i32, in value: T as const_ptr[void], uniform_type: i32) -> void = c.SetShaderValue
      pub foreign def save_file_data(file_name: str as cstr, data: span[u8]) -> bool = c.SaveFileData(file_name, data.data, i32<-data.len)
      pub foreign def close_window(consuming window: Window) -> void = c.CloseWindow

      def main(path: str) -> ptr[u8]?:
          var data_size = 0
          let contrast = 1.0
          set_shader_value(Shader(), 0, in contrast, 0)
          return load_file_data(path, out data_size)
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal(
      %w[ForeignFunctionDecl ForeignFunctionDecl ForeignFunctionDecl ForeignFunctionDecl ForeignFunctionDecl FunctionDef],
      ast.declarations.map { |node| node.class.name.split("::").last },
    )

    init_window = ast.declarations[0]
    assert_equal :public, init_window.visibility
    assert_equal "init_window", init_window.name
    assert_instance_of MilkTea::AST::MemberAccess, init_window.mapping
    assert_equal :plain, init_window.params[2].mode
    assert_equal "str", init_window.params[2].type.name.to_s
    assert_equal "cstr", init_window.params[2].boundary_type.name.to_s

    load_file_data = ast.declarations[1]
    assert_equal :out, load_file_data.params[1].mode
    assert_instance_of MilkTea::AST::MemberAccess, load_file_data.mapping

    set_shader_value = ast.declarations[2]
    assert_equal :in, set_shader_value.params[2].mode
    assert_equal "const_ptr", set_shader_value.params[2].boundary_type.name.to_s

    save_file_data = ast.declarations[3]
    assert_instance_of MilkTea::AST::Call, save_file_data.mapping
    assert_equal "SaveFileData", save_file_data.mapping.callee.member

    close_window = ast.declarations[4]
    assert_equal :consuming, close_window.params[0].mode
    assert_instance_of MilkTea::AST::MemberAccess, close_window.mapping

    main_fn = ast.declarations[5]
    shader_stmt = main_fn.body[2]
    assert_instance_of MilkTea::AST::Call, shader_stmt.expression
    assert_instance_of MilkTea::AST::UnaryOp, shader_stmt.expression.arguments[2].value
    assert_equal "in", shader_stmt.expression.arguments[2].value.operator
    return_stmt = main_fn.body[3]
    assert_instance_of MilkTea::AST::Call, return_stmt.value
    assert_instance_of MilkTea::AST::UnaryOp, return_stmt.value.arguments[1].value
    assert_equal "out", return_stmt.value.arguments[1].value.operator
  end

  private

  def demo_path
    File.expand_path("../../examples/milk-tea-demo.mt", __dir__)
  end
end

# frozen_string_literal: true

require_relative "../test_helper"

class MilkTeaParserTest < Minitest::Test
  def test_parses_language_fixture_file_into_expected_ast_shape
    ast = MilkTea::Parser.parse(File.read(language_fixture_path), path: language_fixture_path)

    assert_nil ast.module_name
    assert_equal :module, ast.module_kind
    assert_equal [], ast.directives
    assert_equal 4, ast.imports.length
    assert_equal(
      [
        ["std.maybe", "maybe"],
        ["std.status", "status"],
        ["test.fixtures.language_fixture.external_runtime", "runtime"],
        ["test.fixtures.language_fixture.types", "types"],
      ],
      ast.imports.map { |import| [import.path.to_s, import.alias_name] },
    )
    assert_equal(
      %w[ConstDecl TypeAliasDecl StructDecl MethodsBlock FunctionDef FunctionDef],
      ast.declarations.map { |node| node.class.name.split("::").last },
    )

    type_alias = ast.declarations[1]
    assert_equal "ExitCode", type_alias.name

    struct_decl = ast.declarations[2]
    assert_equal "AppState", struct_decl.name
    assert_equal %w[counter touched], struct_decl.fields.map(&:name)

    methods_block = ast.declarations[3]
    assert_equal "AppState", methods_block.type_name.to_s
    assert_equal %w[create touch read], methods_block.methods.map(&:name)

    create_method, touch_method, read_method = methods_block.methods
    assert_equal :static, create_method.kind
    assert_equal :editable, touch_method.kind
    assert_equal :plain, read_method.kind

    main_fn = ast.declarations[5]
    assert_equal "main", main_fn.name
    assert_equal(
      %w[LocalDecl DeferStmt ExpressionStmt MatchStmt ReturnStmt],
      main_fn.body.map { |node| node.class.name.split("::").last }.uniq,
    )
    assert main_fn.body.any? { |node| node.is_a?(MilkTea::AST::MatchStmt) }
    assert main_fn.body.any? { |node| node.is_a?(MilkTea::AST::DeferStmt) }
    assert_instance_of MilkTea::AST::ReturnStmt, main_fn.body.last
  end

  def test_parses_if_elif_else_chains
    source = <<~MT
      function main() -> int:
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
    assert_equal 2, if_stmt.branches[0].line
    assert_equal 5, if_stmt.branches[0].column
    assert_equal 2, if_stmt.branches[0].length
    assert_equal 4, if_stmt.branches[1].line
    assert_equal 5, if_stmt.branches[1].column
    assert_equal 4, if_stmt.branches[1].length
  end

  def test_parses_let_else_local_declaration
    source = <<~MT
      function main(handle: ptr[int]?) -> int:
          let value = handle else:
              return 1
          unsafe:
              return read(value)
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    local_decl = main_fn.body.first

    assert_instance_of MilkTea::AST::LocalDecl, local_decl
    assert_equal :let, local_decl.kind
    assert_instance_of MilkTea::AST::Identifier, local_decl.value
    assert_nil local_decl.else_binding
    assert_equal 1, local_decl.else_body.length
    assert_instance_of MilkTea::AST::ReturnStmt, local_decl.else_body.first
  end

  def test_parses_let_else_status_error_binding
    source = <<~MT
      function main(result: int) -> int:
          let value = result else as error:
              return error
          return value
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    local_decl = main_fn.body.first

    assert_instance_of MilkTea::AST::LocalDecl, local_decl
    assert_instance_of MilkTea::AST::Identifier, local_decl.else_binding
    assert_equal "error", local_decl.else_binding.name
  end

  def test_rejects_var_else_local_declaration
    source = <<~MT
      function main(handle: ptr[int]?) -> int:
          var value = handle else:
              return 1
          return 0
    MT

    error = assert_raises(MilkTea::ParseError) do
      MilkTea::Parser.parse(source)
    end

    assert_match(/let-else is only allowed on let declarations/, error.message)
  end

  def test_parses_public_declarations_and_methods
    source = <<~MT
      public const answer: int = 42
      public var counter: int = 0
      public type Score = int

      public struct Counter:
          value: int

      methods Counter:
          public function read() -> int:
              return this.value

          function bump() -> void:
              this.value += 1

      public function make_counter() -> Counter:
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

  def test_parses_interfaces_implements_and_constrained_type_params
    source = <<~MT
      public interface Damageable:
          editable function take_damage(amount: int) -> void
          function is_alive() -> bool

      struct NPC implements Damageable:
          hp: int

      function damage_one[T implements Damageable](target: ref[T]) -> void:
          target.take_damage(1)
    MT

    ast = MilkTea::Parser.parse(source)

    interface_decl = ast.declarations[0]
    struct_decl = ast.declarations[1]
    function_decl = ast.declarations[2]

    assert_instance_of MilkTea::AST::InterfaceDecl, interface_decl
    assert_equal :public, interface_decl.visibility
    assert_equal %w[take_damage is_alive], interface_decl.methods.map(&:name)
    assert_equal :editable, interface_decl.methods.first.kind

    assert_instance_of MilkTea::AST::StructDecl, struct_decl
    assert_equal ["Damageable"], struct_decl.implements.map(&:to_s)

    assert_instance_of MilkTea::AST::FunctionDef, function_decl
    assert_equal [[:interface, "Damageable"]], function_decl.type_params.first.constraints.map { |constraint| [constraint.kind, constraint.interface_ref&.to_s] }
  end

  def test_parses_default_and_interface_type_param_constraints
    source = <<~MT
      interface ScreenState:
          function draw() -> void

      function make_default[T defaults and implements ScreenState]() -> T:
          return default[T]
    MT

    ast = MilkTea::Parser.parse(source)
    function_decl = ast.declarations[1]

    assert_instance_of MilkTea::AST::FunctionDef, function_decl
    assert_equal(
      [[:defaults, nil], [:interface, "ScreenState"]],
      function_decl.type_params.first.constraints.map { |constraint| [constraint.kind, constraint.interface_ref&.to_s] },
    )
  end

  def test_parses_mixed_type_param_constraints_with_hashes_equates_and_multiple_interfaces
    source = <<~MT
      function same_key[T defaults and implements Named and Tagged and hashes and equates](left: T, right: T) -> bool:
          return equal[T](left, right)
    MT

    ast = MilkTea::Parser.parse(source)
    function_decl = ast.declarations.first

    assert_instance_of MilkTea::AST::FunctionDef, function_decl
    assert_equal(
      [
        [:defaults, nil],
        [:interface, "Named"],
        [:interface, "Tagged"],
        [:hashes, nil],
        [:equates, nil],
      ],
      function_decl.type_params.first.constraints.map { |constraint| [constraint.kind, constraint.interface_ref&.to_s] },
    )
  end

  def test_parses_module_scope_vars_with_and_without_initializer
    source = <<~MT
      var counter: int = 0
      public var scratch: array[ubyte, 16]

      function main() -> int:
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
      external

      opaque tm = c"struct tm"
    MT

    ast = MilkTea::Parser.parse(source)
    opaque_decl = ast.declarations.first

    assert_instance_of MilkTea::AST::OpaqueDecl, opaque_decl
    assert_equal "tm", opaque_decl.name
    assert_equal "struct tm", opaque_decl.c_name
  end

  def test_parses_extern_struct_with_explicit_c_name
    source = <<~MT
      external

      struct timespec = c"struct timespec":
          tv_sec: ptr_int
          tv_nsec: ptr_int
    MT

    ast = MilkTea::Parser.parse(source)
    struct_decl = ast.declarations.first

    assert_instance_of MilkTea::AST::StructDecl, struct_decl
    assert_equal "timespec", struct_decl.name
    assert_equal "struct timespec", struct_decl.c_name
  end

  def test_parses_leading_imports_inside_raw_modules
    source = <<~MT
      external

      import std.c.dep as dep

      include "helper.h"

      struct Holder:
          value: dep.Vec
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal :raw_module, ast.module_kind
    assert_equal 1, ast.imports.length
    assert_equal "std.c.dep", ast.imports.first.path.to_s
    assert_equal "dep", ast.imports.first.alias_name
    assert_equal 1, ast.directives.length
    assert_equal 1, ast.declarations.length
  end

  def test_rejects_pub_on_methods_block
    source = <<~MT
      public methods Counter:
          function read() -> int:
              return 0
    MT

    error = assert_raises(MilkTea::ParseError) { MilkTea::Parser.parse(source) }

    assert_match(/public is not allowed on methods blocks/, error.message)
  end

  def test_parses_if_expression
    source = <<~MT
      function main(ready: bool) -> int:
          return if ready: 1 else: 0
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
      async function compute() -> int:
          let value = await child()
          return value

      async function child() -> int:
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
      const epsilon: float = 1.1920929E-7

      function main() -> float:
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
      function main(a: bool, b: bool, c: bool) -> bool:
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
      import std.fmt as fmt
      import std.string as string

      function main(count: int) -> int:
          let text = fmt.format(f"count=\#{count} ok=\#{true}")
          return int<-text.len()
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

  def test_parses_format_string_literal_with_expression_colons_and_trailing_precision
    source = <<~MT
      function main(flag: bool, handle: ptr[int]) -> int:
          let text = f"value=\#{unsafe: read(handle)} precise=\#{if flag: 1.0 else: 2.0:.2}"
          return int<-text.len
    MT

    ast = MilkTea::Parser.parse(source)
    local_decl = ast.declarations.first.body.first
    format_string = local_decl.value

    assert_instance_of MilkTea::AST::FormatString, format_string

    first_expr = format_string.parts[1]
    assert_instance_of MilkTea::AST::FormatExprPart, first_expr
    assert_instance_of MilkTea::AST::UnsafeExpr, first_expr.expression
    assert_nil first_expr.format_spec

    second_expr = format_string.parts[3]
    assert_instance_of MilkTea::AST::FormatExprPart, second_expr
    assert_instance_of MilkTea::AST::IfExpr, second_expr.expression
    assert_equal({ kind: :precision, value: 2 }, second_expr.format_spec)
  end

  def test_parses_prefix_cast_with_identifier_rhs
    source = <<~MT
      function main(value: float) -> int:
          return int<-value
    MT

    ast = MilkTea::Parser.parse(source)
    return_stmt = ast.declarations.first.body.first

    assert_instance_of MilkTea::AST::ReturnStmt, return_stmt
    assert_instance_of MilkTea::AST::Call, return_stmt.value
    assert_equal "cast", return_stmt.value.callee.callee.name
    assert_equal "int", return_stmt.value.callee.arguments.first.value.name.to_s
    assert_instance_of MilkTea::AST::Identifier, return_stmt.value.arguments.first.value
    assert_equal "value", return_stmt.value.arguments.first.value.name
  end

  def test_parses_prefix_cast_with_parenthesized_rhs
    source = <<~MT
      function main(a: int, b: int) -> ubyte:
          return ubyte<-(a - b)
    MT

    ast = MilkTea::Parser.parse(source)
    return_stmt = ast.declarations.first.body.first

    assert_instance_of MilkTea::AST::ReturnStmt, return_stmt
    assert_instance_of MilkTea::AST::Call, return_stmt.value
    assert_equal "cast", return_stmt.value.callee.callee.name
    assert_equal "ubyte", return_stmt.value.callee.arguments.first.value.name.to_s
    assert_instance_of MilkTea::AST::BinaryOp, return_stmt.value.arguments.first.value
    assert_equal "-", return_stmt.value.arguments.first.value.operator
  end

  def test_parses_nested_prefix_casts
    source = <<~MT
      function main(value: int) -> double:
          return double<-float<-value
    MT

    ast = MilkTea::Parser.parse(source)
    return_stmt = ast.declarations.first.body.first

    assert_instance_of MilkTea::AST::Call, return_stmt.value
    assert_equal "double", return_stmt.value.callee.arguments.first.value.name.to_s
    inner = return_stmt.value.arguments.first.value
    assert_instance_of MilkTea::AST::Call, inner
    assert_equal "float", inner.callee.arguments.first.value.name.to_s
  end

  def test_parses_for_range_statement
    source = <<~MT
      function main(count: int) -> int:
          for i in 0..count:
              tick(i)
          return 0
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    for_stmt = main_fn.body.first

    assert_instance_of MilkTea::AST::ForStmt, for_stmt
    assert_equal "i", for_stmt.name
    assert_instance_of MilkTea::AST::RangeExpr, for_stmt.iterable
    assert_instance_of MilkTea::AST::IntegerLiteral, for_stmt.iterable.start_expr
    assert_instance_of MilkTea::AST::Identifier, for_stmt.iterable.end_expr
    assert_equal "count", for_stmt.iterable.end_expr.name
    assert_instance_of MilkTea::AST::ExpressionStmt, for_stmt.body.first
  end

  def test_parses_for_collection_statement
    source = <<~MT
      function main(items: span[int]) -> int:
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
      function main() -> void:
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
      variant Shape:
          circle(radius: double)
          rect(w: double, h: double)
          point

      function area(s: Shape) -> double:
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
      enum Step: ubyte
          skip = 1
          keep = 2
          stop = 3

      function main(items: array[Step, 3]) -> int:
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
      struct Header:
          magic: array[ubyte, 4]
          version: ushort

      static_assert(size_of(Header) >= 6, "Header must include version")

      function main() -> ptr_uint:
          return offset_of(Header, version) + align_of(Header)
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
      packed struct Header:
          tag: ubyte
          value: uint

      align(16) struct Mat4:
          data: array[float, 16]
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
      function main() -> uint:
          let value: float = 1.0
          unsafe:
              let bits = reinterpret[uint](value)
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
    assert_equal "uint", bits_decl.value.callee.arguments.first.value.name.to_s
  end

  def test_parses_single_statement_unsafe_local_declaration
    source = <<~MT
      function main(value: float) -> uint:
          let bits = unsafe: reinterpret[uint](value)
          return bits
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations[0]
    bits_decl = main_fn.body[0]

    assert_instance_of MilkTea::AST::LocalDecl, bits_decl
    assert_instance_of MilkTea::AST::UnsafeExpr, bits_decl.value
    assert_instance_of MilkTea::AST::Call, bits_decl.value.expression
    assert_instance_of MilkTea::AST::Specialization, bits_decl.value.expression.callee
    assert_equal "reinterpret", bits_decl.value.expression.callee.callee.name
    assert_equal "uint", bits_decl.value.expression.callee.arguments.first.value.name.to_s
  end

  def test_parses_single_statement_unsafe_assignment_with_colon
    source = <<~MT
      function main(ptr: ptr[uint]) -> void:
          unsafe: read(ptr) = 1
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations[0]
    unsafe_stmt = main_fn.body[0]

    assert_instance_of MilkTea::AST::UnsafeStmt, unsafe_stmt
    assert_equal 1, unsafe_stmt.body.length
    assert_instance_of MilkTea::AST::Assignment, unsafe_stmt.body[0]
  end

  def test_rejects_inline_unsafe_local_declaration_with_colon
    source = <<~MT
      function main(value: float) -> uint:
          unsafe: let bits = reinterpret[uint](value)
          return bits
    MT

    assert_raises(MilkTea::ParseError) { MilkTea::Parser.parse(source) }
  end

  def test_rejects_bare_single_statement_unsafe_without_colon
    source = <<~MT
      function main(value: float) -> uint:
          unsafe let bits = reinterpret[uint](value)
          return bits
    MT

    assert_raises(MilkTea::ParseError) { MilkTea::Parser.parse(source) }
  end

  def test_parses_match_statement_with_enum_member_arms
    source = <<~MT
      enum EventKind: ubyte
          quit = 1
          resize = 2

      function main(kind: EventKind) -> int:
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
      const missing: ptr[Window]? = null
      const ready: bool = true
      const title: cstr = c"Hello"

      function load(buffer: span[ubyte]) -> ptr[Window]?:
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
    assert_equal "ubyte", load.params.first.type.arguments.first.value.name.to_s
    assert_equal true, load.return_type.nullable
    assert_nil load.body.first.value
  end

  def test_parses_typed_null_pointer_literals
    source = <<~MT
      const missing: ptr[char]? = null[ptr[char]]
    MT

    ast = MilkTea::Parser.parse(source)

    missing = ast.declarations[0]
    assert_instance_of MilkTea::AST::NullLiteral, missing.value
    assert_equal "ptr", missing.value.type.name.to_s
    assert_equal "char", missing.value.type.arguments.first.value.name.to_s
  end

  def test_parses_heredoc_cstring_literals
    source = <<~MT
      const shader: cstr = c<<-GLSL
          #version 330
          void main()
          {
          }
      GLSL
    MT

    ast = MilkTea::Parser.parse(source)

    shader = ast.declarations[0]
    assert_instance_of MilkTea::AST::StringLiteral, shader.value
    assert_equal true, shader.value.cstring
    assert_equal "#version 330\nvoid main()\n{\n}\n", shader.value.value
  end

  def test_parses_multiline_adjacent_cstring_literals
    source = <<~MT
      const title: cstr = c"Milk Tea keeps this text readable"
          c" while storing a single logical line."
    MT

    ast = MilkTea::Parser.parse(source)
    declaration = ast.declarations[0]

    assert_instance_of MilkTea::AST::StringLiteral, declaration.value
    assert_equal true, declaration.value.cstring
    assert_equal "Milk Tea keeps this text readable while storing a single logical line.", declaration.value.value
  end

  def test_parses_const_pointer_types_and_ro_addr_calls
    source = <<~MT
      external function inspect(values: const_ptr[int]) -> void

      function main() -> void:
          let value = 7
          inspect(const_ptr_of(value))
    MT

    ast = MilkTea::Parser.parse(source)

    inspect_fn = ast.declarations[0]
    assert_equal "const_ptr", inspect_fn.params.first.type.name.to_s
    assert_equal "int", inspect_fn.params.first.type.arguments.first.value.name.to_s

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
      struct Slice[T]:
          data: ptr[T]
          len: ptr_uint

      function main() -> int:
          let value = 7
          let items = Slice[int](data = ptr_of(value), len = 1)
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
    assert_equal "int", constructor.callee.arguments.first.value.name.to_s
    assert_equal %w[data len], constructor.arguments.map(&:name)
  end

  def test_parses_generic_function_definition
    source = <<~MT
      struct Slice[T]:
          data: ptr[T]
          len: ptr_uint

      function first[T](items: Slice[T]) -> ptr[T]?:
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
      function main() -> int:
          return callbacks[0](1)
    MT

    ast = MilkTea::Parser.parse(source)
    call = ast.declarations.first.body.first.value

    assert_instance_of MilkTea::AST::Call, call
    assert_instance_of MilkTea::AST::IndexAccess, call.callee
  end

  def test_parses_callable_value_storage_and_indirect_calls
    source = <<~MT
      struct Entry:
          callback: fn(value: float) -> float

      function ease(value: float) -> float:
          return value

      function main() -> int:
          let callbacks = array[fn(value: int) -> int, 1](identity)
          let entry = Entry(callback = ease)
          let callback: fn(value: float) -> float = entry.callback
          let left = callbacks[0](1)
          let right = callback(1.0)
          return int<-right + left

      function identity(value: int) -> int:
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

  def test_rejects_explicit_cast_call_form
    source = <<~MT
      function main(value: int) -> long:
          return cast[long](value)
    MT

    error = assert_raises(MilkTea::ParseError) do
      MilkTea::Parser.parse(source)
    end

    assert_match(/cast\[T\]\(value\) is no longer supported; use T<-value/, error.message)
  end

  def test_reports_hint_for_spaced_prefix_cast_tokens
    source = <<~MT
      function main(value: int) -> long:
          return long < -value
    MT

    error = assert_raises(MilkTea::ParseError) do
      MilkTea::Parser.parse(source)
    end

    assert_match(/did you mean T<-expr\?/, error.message)
  end

  def test_parses_proc_type_refs_in_function_parameters
    source = <<~MT
      function apply(callback: proc(value: int) -> int, value: int) -> int:
          return callback(value)
    MT

    ast = MilkTea::Parser.parse(source)
    apply_fn = ast.declarations.first
    callback_param = apply_fn.params.first

    assert_instance_of MilkTea::AST::ProcType, callback_param.type
    assert_equal "value", callback_param.type.params.first.name
    assert_equal "int", callback_param.type.return_type.name.to_s
  end

  def test_parses_proc_expressions
    source = <<~MT
      function main() -> int:
          let offset = 4
          let callback = proc(value: int) -> int:
              return value + offset
          return callback(3)
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    callback_decl = main_fn.body[1]

    assert_instance_of MilkTea::AST::LocalDecl, callback_decl
    assert_instance_of MilkTea::AST::ProcExpr, callback_decl.value
    assert_equal "int", callback_decl.value.return_type.name.to_s
    assert_equal "value", callback_decl.value.params.first.name
    assert_equal "int", callback_decl.value.params.first.type.name.to_s
  end

  def test_parses_explicit_generic_function_specialization_call
    source = <<~MT
      function bytes_for[T](count: ptr_uint) -> ptr_uint:
          return count

      function main() -> int:
          return int<-bytes_for[int](4)
    MT

    ast = MilkTea::Parser.parse(source)
    call = ast.declarations[1].body.first.value.arguments.first.value

    assert_instance_of MilkTea::AST::Call, call
    assert_instance_of MilkTea::AST::Specialization, call.callee
    assert_equal "bytes_for", call.callee.callee.name
    assert_equal "int", call.callee.arguments.first.value.name.to_s
  end

  def test_parses_explicit_generic_function_literal_specialization_call
    source = <<~MT
      function capacity_of[N](buffer: str_builder[N]) -> ptr_uint:
          return buffer.capacity()

      function main() -> int:
          var buffer: str_builder[32]
          return int<-capacity_of[32](buffer)
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
      const CAPACITY: int = 32

      function capacity_of[N](buffer: str_builder[N]) -> ptr_uint:
          return buffer.capacity()

      function main() -> int:
          var buffer: str_builder[CAPACITY]
          return int<-capacity_of[CAPACITY](buffer)
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
      import std.ui as ui

      function main() -> int:
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
      foreign function text_box[N](text: str_builder[N] as ptr[char]) -> void = c.TextBox(text)

      function main() -> int:
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
      function main() -> int:
          let view = span[int](data = buffer, len = 3)
          return view.len
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    local_decl = main_fn.body.first

    assert_instance_of MilkTea::AST::LocalDecl, local_decl
    assert_instance_of MilkTea::AST::Call, local_decl.value
    assert_instance_of MilkTea::AST::Specialization, local_decl.value.callee
    assert_equal "span", local_decl.value.callee.callee.name
    assert_equal "int", local_decl.value.callee.arguments.first.value.name.to_s
    assert_equal %w[data len], local_decl.value.arguments.map(&:name)
  end

  def test_parses_array_constructor_calls
    source = <<~MT
      function main() -> int:
          let palette = array[uint, 4](1, 2, 3, 4)
          return 0
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    local_decl = main_fn.body.first

    assert_instance_of MilkTea::AST::Call, local_decl.value
    assert_instance_of MilkTea::AST::Specialization, local_decl.value.callee
    assert_equal "array", local_decl.value.callee.callee.name
    assert_equal 2, local_decl.value.callee.arguments.length
    assert_equal "uint", local_decl.value.callee.arguments.first.value.name.to_s
    assert_equal 4, local_decl.value.callee.arguments[1].value.value
    assert_equal 4, local_decl.value.arguments.length
  end

  def test_parses_typed_local_without_initializer
    source = <<~MT
      function main() -> void:
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
      function main() -> int:
          let palette = zero[array[uint, 4]]
          return 0
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    local_decl = main_fn.body.first

    assert_instance_of MilkTea::AST::Specialization, local_decl.value
    assert_equal "zero", local_decl.value.callee.name
    assert_equal 1, local_decl.value.arguments.length
    array_type = local_decl.value.arguments.first.value
    assert_instance_of MilkTea::AST::TypeRef, array_type
    assert_equal "array", array_type.name.to_s
    assert_equal 2, array_type.arguments.length
    assert_equal "uint", array_type.arguments.first.value.name.to_s
    assert_equal 4, array_type.arguments[1].value.value
  end

  def test_parses_array_char_zero_constructor_calls
    source = <<~MT
      function main() -> int:
          let buffer = zero[array[char, 64]]
          return 0
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    local_decl = main_fn.body.first

    assert_instance_of MilkTea::AST::Specialization, local_decl.value
    assert_equal "zero", local_decl.value.callee.name
    assert_equal 1, local_decl.value.arguments.length
    array_type = local_decl.value.arguments.first.value
    assert_instance_of MilkTea::AST::TypeRef, array_type
    assert_equal "array", array_type.name.to_s
    assert_equal "char", array_type.arguments.first.value.name.to_s
    assert_equal 64, array_type.arguments[1].value.value
  end

  def test_parses_partial_aggregate_and_array_constructor_calls
    source = <<~MT
      struct Point:
          x: int
          y: int

      function main() -> int:
          let origin = Point()
          let point = Point(x = 1)
          let palette = array[uint, 4](1, 2)
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
      function main() -> int:
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
      type LogCallback = fn(level: int, message: cstr, user_data: ptr[void]) -> void
    MT

    ast = MilkTea::Parser.parse(source)
    callback = ast.declarations.first

    assert_equal "LogCallback", callback.name
    assert_instance_of MilkTea::AST::FunctionType, callback.target
    assert_equal %w[level message user_data], callback.target.params.map(&:name)
    assert_equal "int", callback.target.params[0].type.name.to_s
    assert_equal "ptr", callback.target.params[2].type.name.to_s
    assert_equal "void", callback.target.return_type.name.to_s
  end

  def test_parses_async_methods
    source = <<~MT
      struct Counter:
          value: int

      methods Counter:
          async function read() -> int:
              return this.value

          async editable function bump() -> void:
              this.value += 1
    MT

    ast = MilkTea::Parser.parse(source)
    methods = ast.declarations[1]

    assert_instance_of MilkTea::AST::MethodsBlock, methods
    assert_equal true, methods.methods[0].async
    assert_equal :plain, methods.methods[0].kind
    assert_equal true, methods.methods[1].async
    assert_equal :editable, methods.methods[1].kind
  end

  def test_parses_generic_methods_block_targets
    source = <<~MT
      struct Box[T]:
          value: T

      methods Box[T]:
          function get() -> T:
              return this.value
    MT

    ast = MilkTea::Parser.parse(source)
    methods = ast.declarations[1]

    assert_instance_of MilkTea::AST::MethodsBlock, methods
    assert_equal "Box[T]", methods.type_name.to_s
  end

  def test_parses_unsafe_blocks_with_pointer_cast_and_arithmetic
    source = <<~MT
      function main(memory: ptr[void]) -> int:
          unsafe:
              let advanced = ptr[ubyte]<-memory + 4
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
      struct Counter:
          value: int

      function main() -> int:
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
      flags Bits: uint
          a = 1 << 0
          b = 1 << 1

      function main() -> void:
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
      struct Counter:
          value: int

      function main() -> int:
          var counter = Counter(value = 3)
          let counter_ptr = &counter
          return counter_ptr->value
    MT

    assert_raises(MilkTea::ParseError) do
      MilkTea::Parser.parse(source)
    end
  end

  def test_rejects_keyword_names_in_struct_fields
    source = <<~MT
      struct Event:
          kind: int
    MT

    ast = MilkTea::Parser.parse(source)
    event_decl = ast.declarations[0]

    assert_equal "kind", event_decl.fields.first.name
  end

  def test_rejects_reserved_keyword_as_struct_field_name
    source = <<~MT
      struct Event:
          type: int
    MT

    error = assert_raises(MilkTea::ParseError) do
      MilkTea::Parser.parse(source)
    end

    assert_match(/expected field name/, error.message)
  end

  def test_rejects_untyped_non_self_parameters
    source = <<~MT
      function bad(value):
          return 0
    MT

    error = assert_raises(MilkTea::ParseError) do
      MilkTea::Parser.parse(source)
    end

    assert_match(/expected ':' and parameter type/, error.message)
  end

  def test_parses_raw_module_declarations
    source = <<~MT
      external

      link "raylib"
      include "raylib.h"

      struct Color:
          r: ubyte
          g: ubyte
          b: ubyte
          a: ubyte

      const BLACK: Color = Color(r = 0, g = 0, b = 0, a = 255)

      enum LogLevel: int
          info = 1
          warning = 2

      flags WindowFlags: uint
          visible = 1 << 0

      union Number:
          i: int
          f: float

      opaque SDL_Window
      external function InitWindow(width: int, height: int, title: cstr) -> void
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal :raw_module, ast.module_kind
    assert_nil ast.module_name
    assert_equal %w[LinkDirective IncludeDirective], ast.directives.map { |node| node.class.name.split("::").last }
    assert_equal(
      %w[StructDecl ConstDecl EnumDecl FlagsDecl UnionDecl OpaqueDecl ExternFunctionDecl],
      ast.declarations.map { |node| node.class.name.split("::").last },
    )
    assert_equal [nil, nil, nil, nil, nil, nil], ast.declarations.first(6).map(&:visibility)

    const_decl = ast.declarations[1]
    assert_equal "BLACK", const_decl.name
    assert_equal "Color", const_decl.type.name.to_s
    assert_instance_of MilkTea::AST::Call, const_decl.value

    flags_decl = ast.declarations[3]
    assert_equal "WindowFlags", flags_decl.name
    assert_equal "uint", flags_decl.backing_type.name.to_s
    assert_instance_of MilkTea::AST::BinaryOp, flags_decl.members.first.value
    assert_equal "<<", flags_decl.members.first.value.operator

    extern_def = ast.declarations.last
    assert_equal "InitWindow", extern_def.name
    assert_equal "void", extern_def.return_type.name.to_s
    assert_equal false, extern_def.variadic
  end

  def test_parses_variadic_extern_function_declarations
    source = <<~MT
      external

      include "stdio.h"

      external function printf(format: cstr, ...) -> int
    MT

    ast = MilkTea::Parser.parse(source)
    extern_def = ast.declarations.last

    assert_equal "printf", extern_def.name
    assert_equal ["format"], extern_def.params.map(&:name)
    assert_equal true, extern_def.variadic
  end

  def test_rejects_raw_module_directives_after_declarations
    source = <<~MT
      external

      struct Foo:
          value: int

      include "foo.h"
    MT

    error = assert_raises(MilkTea::ParseError) do
      MilkTea::Parser.parse(source)
    end

    assert_match(/include directives must appear before external declarations/, error.message)
  end

  def test_rejects_methods_blocks_in_raw_modules
    source = <<~MT
      external

      methods Counter:
          function read() -> int:
              return 0
    MT

    error = assert_raises(MilkTea::ParseError) do
      MilkTea::Parser.parse(source)
    end

    assert_match(/methods is not allowed in external files/, error.message)
  end

  def test_rejects_late_imports_in_raw_modules
    source = <<~MT
      external

      include "foo.h"

      import std.c.dep
    MT

    error = assert_raises(MilkTea::ParseError) do
      MilkTea::Parser.parse(source)
    end

    assert_match(/imports must appear before external directives and declarations/, error.message)
  end

  def test_rejects_ordinary_only_declarations_in_raw_modules
    cases = {
      "var counter: int = 0\n" => /var is not allowed in external files/,
      "variant Token:\n    eof\n" => /variant is not allowed in external files/,
      "interface Damageable:\n    function hit() -> void\n" => /interface is not allowed in external files/,
      "foreign function init() -> void = c.Init\n" => /foreign is not allowed in external files/,
      "function init() -> void:\n    return\n" => /function is not allowed in external files/,
      "async function init() -> void:\n    return\n" => /async function is not allowed in external files/,
      "static_assert(true, \"ok\")\n" => /static_assert is not allowed in external files/,
      "public const MAGIC: int = 1\n" => /public is not allowed in external files/,
    }

    cases.each do |declaration_source, expected_message|
      source = "external\n\n#{declaration_source}"

      error = assert_raises(MilkTea::ParseError) do
        MilkTea::Parser.parse(source)
      end

      assert_match(expected_message, error.message, declaration_source)
    end
  end

  def test_parses_foreign_function_declarations_and_calls
    source = <<~MT
      import std.c.raylib as c

      public foreign function init_window(width: int, height: int, title: str as cstr) -> void = c.InitWindow
      public foreign function load_file_data(file_name: str as cstr, out data_size: int) -> ptr[ubyte]? = c.LoadFileData
      public foreign function set_shader_value[T](shader: Shader, loc_index: int, in value: T as const_ptr[void], uniform_type: int) -> void = c.SetShaderValue
      public foreign function save_file_data(file_name: str as cstr, data: span[ubyte]) -> bool = c.SaveFileData(file_name, data.data, int<-data.len)
      public foreign function close_window(consuming window: Window) -> void = c.CloseWindow

      function main(path: str) -> ptr[ubyte]?:
          var data_size = 0
          let contrast = 1.0
          set_shader_value(Shader(), 0, contrast, 0)
          return load_file_data(path, data_size)
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
    assert_instance_of MilkTea::AST::Identifier, shader_stmt.expression.arguments[2].value
    assert_equal "contrast", shader_stmt.expression.arguments[2].value.name
    return_stmt = main_fn.body[3]
    assert_instance_of MilkTea::AST::Call, return_stmt.value
    assert_instance_of MilkTea::AST::Identifier, return_stmt.value.arguments[1].value
    assert_equal "data_size", return_stmt.value.arguments[1].value.name
  end

  def test_parses_variadic_foreign_function_declarations
    source = <<~MT
      import std.c.stdio as c

      public foreign function print(format: str as cstr, ...) -> int = c.printf
    MT

    ast = MilkTea::Parser.parse(source)
    foreign_def = ast.declarations.last

    assert_equal "print", foreign_def.name
    assert_equal ["format"], foreign_def.params.map(&:name)
    assert_equal true, foreign_def.variadic
    assert_instance_of MilkTea::AST::MemberAccess, foreign_def.mapping
  end

  def test_parses_format_string_precision_spec
    source = <<~MT
      function main() -> int:
          let pi: double = 3.14159
          let first = f"pi=\#{pi:.2}"
          let second = f"\#{pi:.0}"
          return 0
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.last
    format1_decl = main_fn.body[1]
    format2_decl = main_fn.body[2]

    # f"pi=#{pi:.2}" -> text part "pi=" + expr part with precision 2
    format1 = format1_decl.value
    assert_instance_of MilkTea::AST::FormatString, format1
    assert_equal 2, format1.parts.length

    text_part = format1.parts[0]
    assert_instance_of MilkTea::AST::FormatTextPart, text_part
    assert_equal "pi=", text_part.value

    expr_part1 = format1.parts[1]
    assert_instance_of MilkTea::AST::FormatExprPart, expr_part1
    assert_equal({ kind: :precision, value: 2 }, expr_part1.format_spec)

    # f"#{pi:.0}" -> single expr part with precision 0
    format2 = format2_decl.value
    assert_instance_of MilkTea::AST::FormatString, format2
    assert_equal 1, format2.parts.length

    expr_part2 = format2.parts[0]
    assert_instance_of MilkTea::AST::FormatExprPart, expr_part2
    assert_equal({ kind: :precision, value: 0 }, expr_part2.format_spec)
  end

  def test_parse_collecting_errors_recovers_after_invalid_top_level_declaration
    source = <<~MT
      const board_width: int = 10
      const board_height: int = 20a
      const board_cells: int = 200

      function main() -> int:
          return board_cells
    MT

    result = MilkTea::Parser.parse_collecting_errors(source)

    assert_equal 1, result.errors.length
    assert_match(/expected end of statement/, result.errors.first.message)
    refute_nil result.ast
    assert_equal ["board_width", "board_height", "board_cells", "main"], result.ast.declarations.map(&:name)
    assert_instance_of MilkTea::AST::ErrorExpr, result.ast.declarations[1].value
  end

  def test_parse_collecting_errors_recovers_after_invalid_raw_module_declaration
    source = <<~MT
      external

      include "foo.h"

      struct Foo:
          value: int

      function nope() -> void:
          return

      opaque Handle
    MT

    result = MilkTea::Parser.parse_collecting_errors(source)

    assert_equal 1, result.errors.length
    assert_match(/function is not allowed in external files/, result.errors.first.message)
    refute_nil result.ast
    assert_equal :raw_module, result.ast.module_kind
    assert_equal ["Foo", "Handle"], result.ast.declarations.map(&:name)
  end

  def test_parse_collecting_errors_recovers_after_multiple_invalid_raw_module_entries
    source = <<~MT
      external

      include "foo.h"

      struct Foo:
          value: int

      function nope() -> void:
          return

      import std.c.dep

      opaque Handle
    MT

    result = MilkTea::Parser.parse_collecting_errors(source)

    assert_equal 2, result.errors.length
    assert_match(/function is not allowed in external files/, result.errors[0].message)
    assert_match(/imports must appear before external directives and declarations/, result.errors[1].message)
    refute_nil result.ast
    assert_equal :raw_module, result.ast.module_kind
    assert_equal ["Foo", "Handle"], result.ast.declarations.map(&:name)
  end

  def test_parse_collecting_errors_recovers_after_invalid_statement_in_block
    source = <<~MT
      function main() -> int:
          let width = 10
          let height = 20a
          return width
    MT

    result = MilkTea::Parser.parse_collecting_errors(source)

    assert_equal 1, result.errors.length
    assert_match(/expected end of statement/, result.errors.first.message)

    function_def = result.ast.declarations.last
    assert_equal 3, function_def.body.length
    assert_instance_of MilkTea::AST::LocalDecl, function_def.body[0]
    assert_instance_of MilkTea::AST::LocalDecl, function_def.body[1]
    assert_instance_of MilkTea::AST::ErrorExpr, function_def.body[1].value
    assert_instance_of MilkTea::AST::ReturnStmt, function_def.body[2]
  end

  def test_parse_collecting_errors_preserves_typed_local_declaration_with_invalid_initializer
    source = <<~MT
      function main() -> int:
          let height: int = 20a
          return height
    MT

    result = MilkTea::Parser.parse_collecting_errors(source)

    assert_equal 1, result.errors.length
    assert_match(/expected end of statement/, result.errors.first.message)

    function_def = result.ast.declarations.last
    assert_equal 2, function_def.body.length
    assert_instance_of MilkTea::AST::LocalDecl, function_def.body[0]
    assert_instance_of MilkTea::AST::ErrorExpr, function_def.body[0].value
    assert_instance_of MilkTea::AST::ReturnStmt, function_def.body[1]
  end

  def test_parse_collecting_errors_preserves_untyped_local_declaration_with_invalid_initializer
    source = <<~MT
      function main() -> int:
          let value = 20a
          return value
    MT

    result = MilkTea::Parser.parse_collecting_errors(source)

    assert_equal 1, result.errors.length
    assert_match(/expected end of statement/, result.errors.first.message)

    function_def = result.ast.declarations.last
    assert_equal 2, function_def.body.length
    assert_instance_of MilkTea::AST::LocalDecl, function_def.body[0]
    assert_nil function_def.body[0].type
    assert_instance_of MilkTea::AST::ErrorExpr, function_def.body[0].value
    assert_instance_of MilkTea::AST::ReturnStmt, function_def.body[1]
  end

  def test_parse_collecting_errors_preserves_let_else_after_invalid_else_block
    source = <<~MT
      function main(handle: ptr[int]?) -> int:
          let value = handle else as error
              return 1
          unsafe:
              return read(value)
    MT

    result = MilkTea::Parser.parse_collecting_errors(source)

    assert_equal 1, result.errors.length
    assert_match(/expected ':' before block/, result.errors.first.message)

    function_def = result.ast.declarations.last
    local_decl = function_def.body.first
    assert_instance_of MilkTea::AST::LocalDecl, local_decl
    assert_instance_of MilkTea::AST::Identifier, local_decl.value
    assert_equal "error", local_decl.else_binding.name
    assert_nil local_decl.else_body
    assert_equal true, local_decl.recovered_else
  end

  def test_parse_collecting_errors_preserves_invalid_non_declaration_statement
    source = <<~MT
      function main() -> int:
          let value = 1
          unsafe
              value += 1
          return value
    MT

    result = MilkTea::Parser.parse_collecting_errors(source)

    assert_equal 1, result.errors.length
    assert_match(/expected ':' after unsafe/, result.errors.first.message)

    function_def = result.ast.declarations.last
    assert_equal 3, function_def.body.length
    assert_instance_of MilkTea::AST::LocalDecl, function_def.body[0]
    assert_instance_of MilkTea::AST::ErrorBlockStmt, function_def.body[1]
    assert_equal 1, function_def.body[1].body.length
    assert_instance_of MilkTea::AST::Assignment, function_def.body[1].body[0]
    assert_instance_of MilkTea::AST::ReturnStmt, function_def.body[2]
  end

  def test_parse_collecting_errors_preserves_invalid_block_header_body
    source = <<~MT
      function main() -> int:
          let value = 1
          unsafe
              let inner = value
              return inner
    MT

    result = MilkTea::Parser.parse_collecting_errors(source)

    assert_equal 1, result.errors.length
    assert_match(/expected ':' after unsafe/, result.errors.first.message)

    function_def = result.ast.declarations.last
    assert_equal 2, function_def.body.length
    assert_instance_of MilkTea::AST::LocalDecl, function_def.body[0]
    assert_instance_of MilkTea::AST::ErrorBlockStmt, function_def.body[1]
    assert_equal :unsafe, function_def.body[1].header_type
    assert_equal 2, function_def.body[1].body.length
    assert_instance_of MilkTea::AST::LocalDecl, function_def.body[1].body[0]
    assert_instance_of MilkTea::AST::ReturnStmt, function_def.body[1].body[1]
  end

  def test_parse_collecting_errors_marks_invalid_unsafe_block_header_type
    source = <<~MT
      function main() -> int:
          unsafe
              return 1
    MT

    result = MilkTea::Parser.parse_collecting_errors(source)

    assert_equal 1, result.errors.length
    assert_match(/expected ':' after unsafe/, result.errors.first.message)

    function_def = result.ast.declarations.last
    assert_instance_of MilkTea::AST::ErrorBlockStmt, function_def.body[0]
    assert_equal :unsafe, function_def.body[0].header_type
  end

  def test_parse_collecting_errors_preserves_invalid_if_block_header_condition
    source = <<~MT
      struct Point:
          x: int

      function main() -> int:
          var p: Point? = null
          if p != null
              return p.x
          return 0
    MT

    result = MilkTea::Parser.parse_collecting_errors(source)

    assert_equal 1, result.errors.length
    assert_match(/expected ':' before block/, result.errors.first.message)

    function_def = result.ast.declarations.last
    recovered_if = function_def.body[1]
    assert_instance_of MilkTea::AST::IfStmt, recovered_if
    assert_equal 1, recovered_if.branches.length
    assert_instance_of MilkTea::AST::BinaryOp, recovered_if.branches[0].condition
    assert_equal "!=", recovered_if.branches[0].condition.operator
    assert_equal 1, recovered_if.branches[0].body.length
    assert_instance_of MilkTea::AST::ReturnStmt, recovered_if.branches[0].body[0]
  end

  def test_parse_collecting_errors_preserves_invalid_while_block_header_condition
    source = <<~MT
      struct Point:
          x: int

      function main() -> int:
          var p: Point? = Point(x = 1)
          while p != null
              return p.x
          return 0
    MT

    result = MilkTea::Parser.parse_collecting_errors(source)

    assert_equal 1, result.errors.length
    assert_match(/expected ':' before block/, result.errors.first.message)

    function_def = result.ast.declarations.last
    recovered_while = function_def.body[1]
    assert_instance_of MilkTea::AST::WhileStmt, recovered_while
    assert_instance_of MilkTea::AST::BinaryOp, recovered_while.condition
    assert_equal "!=", recovered_while.condition.operator
    assert_equal 1, recovered_while.body.length
    assert_instance_of MilkTea::AST::ReturnStmt, recovered_while.body[0]
  end

  def test_parse_collecting_errors_preserves_invalid_for_block_header_bindings_and_iterables
    source = <<~MT
      function main(items: array[int, 2]) -> int:
          for item in items
              return item
          return 0
    MT

    result = MilkTea::Parser.parse_collecting_errors(source)

    assert_equal 1, result.errors.length
    assert_match(/expected ':' before block/, result.errors.first.message)

    function_def = result.ast.declarations.last
    recovered_for = function_def.body[0]
    assert_instance_of MilkTea::AST::ErrorBlockStmt, recovered_for
    assert_equal :for, recovered_for.header_type
    assert_equal ["item"], recovered_for.header_bindings.map(&:name)
    assert_equal 1, recovered_for.header_iterables.length
    assert_instance_of MilkTea::AST::Identifier, recovered_for.header_iterables[0]
    assert_equal 1, recovered_for.body.length
    assert_instance_of MilkTea::AST::ReturnStmt, recovered_for.body[0]
  end

  def test_parse_collecting_errors_preserves_invalid_if_block_body_without_condition
    source = <<~MT
      function main() -> int:
          if:
              return 1
          return 0
    MT

    result = MilkTea::Parser.parse_collecting_errors(source)

    assert_equal 1, result.errors.length

    function_def = result.ast.declarations.last
    recovered_if = function_def.body[0]
    assert_instance_of MilkTea::AST::IfStmt, recovered_if
    assert_equal 1, recovered_if.branches.length
    assert_instance_of MilkTea::AST::ErrorExpr, recovered_if.branches[0].condition
    assert_equal 1, recovered_if.branches[0].body.length
    assert_instance_of MilkTea::AST::ReturnStmt, recovered_if.branches[0].body[0]
  end

  def test_parse_collecting_errors_preserves_invalid_while_block_body_without_condition
    source = <<~MT
      function main() -> int:
          while:
              continue
          return 0
    MT

    result = MilkTea::Parser.parse_collecting_errors(source)

    assert_equal 1, result.errors.length

    function_def = result.ast.declarations.last
    recovered_while = function_def.body[0]
    assert_instance_of MilkTea::AST::WhileStmt, recovered_while
    assert_instance_of MilkTea::AST::ErrorExpr, recovered_while.condition
    assert_equal 1, recovered_while.body.length
    assert_instance_of MilkTea::AST::ContinueStmt, recovered_while.body[0]
  end

  def test_parse_collecting_errors_preserves_invalid_for_block_body_without_header
    source = <<~MT
      function main() -> int:
          for:
              continue
          return 0
    MT

    result = MilkTea::Parser.parse_collecting_errors(source)

    assert_equal 1, result.errors.length

    function_def = result.ast.declarations.last
    recovered_for = function_def.body[0]
    assert_instance_of MilkTea::AST::ErrorBlockStmt, recovered_for
    assert_equal :for, recovered_for.header_type
    assert_nil recovered_for.header_bindings
    assert_nil recovered_for.header_iterables
    assert_equal 1, recovered_for.body.length
    assert_instance_of MilkTea::AST::ContinueStmt, recovered_for.body[0]
  end

  def test_parse_collecting_errors_preserves_match_arms_after_invalid_match_header
    source = <<~MT
      variant MaybePoint:
          some(value: int)
          none

      function main(value: MaybePoint) -> int:
          match value
              MaybePoint.some as payload:
                  return payload.value
              MaybePoint.none:
                  return 0
    MT

    result = MilkTea::Parser.parse_collecting_errors(source)

    assert_equal 1, result.errors.length
    assert_match(/expected ':' before block/, result.errors.first.message)

    function_def = result.ast.declarations.last
    recovered_match = function_def.body[0]
    assert_instance_of MilkTea::AST::MatchStmt, recovered_match
    assert_instance_of MilkTea::AST::Identifier, recovered_match.expression
    assert_equal "value", recovered_match.expression.name
    assert_equal 2, recovered_match.arms.length
    assert_equal "payload", recovered_match.arms[0].binding_name
    assert_instance_of MilkTea::AST::ReturnStmt, recovered_match.arms[0].body[0]
    assert_nil recovered_match.arms[1].binding_name
  end

  def test_parse_collecting_errors_preserves_match_arms_after_missing_match_expression
    source = <<~MT
      variant MaybePoint:
          some(value: int)
          none

      function main() -> int:
          match:
              MaybePoint.some as payload:
                  return payload.value
              MaybePoint.none:
                  return 0
    MT

    result = MilkTea::Parser.parse_collecting_errors(source)

    assert_equal 1, result.errors.length

    function_def = result.ast.declarations.last
    recovered_match = function_def.body[0]
    assert_instance_of MilkTea::AST::MatchStmt, recovered_match
    assert_instance_of MilkTea::AST::ErrorExpr, recovered_match.expression
    assert_equal 2, recovered_match.arms.length
    assert_equal "payload", recovered_match.arms[0].binding_name
    assert_instance_of MilkTea::AST::ReturnStmt, recovered_match.arms[0].body[0]
  end

  def test_parse_collecting_errors_preserves_invalid_match_arm_header_body
    source = <<~MT
      variant MaybePoint:
          some(value: int)
          none

      function main(value: MaybePoint) -> int:
          match value:
              MaybePoint.some as payload
                  return payload.value
              MaybePoint.none:
                  return 0
    MT

    result = MilkTea::Parser.parse_collecting_errors(source)

    assert_equal 1, result.errors.length
    assert_match(/expected ':' before block/, result.errors.first.message)

    function_def = result.ast.declarations.last
    recovered_match = function_def.body[0]
    assert_instance_of MilkTea::AST::MatchStmt, recovered_match
    assert_equal 2, recovered_match.arms.length
    assert_equal "payload", recovered_match.arms[0].binding_name
    assert_equal 1, recovered_match.arms[0].body.length
    assert_instance_of MilkTea::AST::ReturnStmt, recovered_match.arms[0].body[0]
  end

  def test_parse_collecting_errors_preserves_invalid_match_arm_body_without_pattern
    source = <<~MT
      function main(value: int) -> int:
          match value:
              :
                  return 1
              _:
                  return 0
    MT

    result = MilkTea::Parser.parse_collecting_errors(source)

    assert_equal 1, result.errors.length

    function_def = result.ast.declarations.last
    recovered_match = function_def.body[0]
    assert_instance_of MilkTea::AST::MatchStmt, recovered_match
    assert_equal 2, recovered_match.arms.length
    assert_instance_of MilkTea::AST::ErrorExpr, recovered_match.arms[0].pattern
    assert_equal 1, recovered_match.arms[0].body.length
    assert_instance_of MilkTea::AST::ReturnStmt, recovered_match.arms[0].body[0]
  end

  private

  def language_fixture_path
    File.expand_path("../fixtures/language_fixture.mt", __dir__)
  end
end

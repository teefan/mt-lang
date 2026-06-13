# frozen_string_literal: true

require_relative "../test_helper"

class MilkTeaParserTest < Minitest::Test
  def test_parses_if_else_if_else_chains
    source = <<~MT
      function main() -> int:
          if ready:
              return 1
          else if fallback:
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
    assert_equal 10, if_stmt.branches[1].column
    assert_equal 2, if_stmt.branches[1].length
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

  def test_parses_let_else_discard_binding
    source = <<~MT
      function main(input: int) -> int:
          let _ = parse(input) else:
              return 1
          return 0
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    local_decl = main_fn.body.first

    assert_instance_of MilkTea::AST::LocalDecl, local_decl
    assert_equal "_", local_decl.name
    assert_instance_of MilkTea::AST::Call, local_decl.value
    assert_equal 1, local_decl.else_body.length
    assert_nil local_decl.else_binding
  end

  def test_parses_result_propagation_expression
    source = <<~MT
      function main() -> Result[int, int]:
          let value = parse()?
          return Result[int, int].success(value= value)
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    local_decl = main_fn.body.first

    assert_instance_of MilkTea::AST::LocalDecl, local_decl
    assert_instance_of MilkTea::AST::UnaryOp, local_decl.value
    assert_equal "?", local_decl.value.operator
    assert_instance_of MilkTea::AST::Call, local_decl.value.operand
  end

  def test_parses_result_propagation_expression_statement
    source = <<~MT
      function verify(input: int) -> Result[void, int]:
          parse(input)?
          return Result[void, int].success(value= done())
    MT

    ast = MilkTea::Parser.parse(source)
    verify_fn = ast.declarations.first
    propagation_stmt = verify_fn.body.first

    assert_instance_of MilkTea::AST::ExpressionStmt, propagation_stmt
    assert_instance_of MilkTea::AST::UnaryOp, propagation_stmt.expression
    assert_equal "?", propagation_stmt.expression.operator
    assert_instance_of MilkTea::AST::Call, propagation_stmt.expression.operand
  end

  def test_parses_var_else_local_declaration
    source = <<~MT
      function main(handle: ptr[int]?) -> int:
          var value = handle else:
              return 1
          unsafe:
              return read(value)
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    local_decl = main_fn.body.first

    assert_instance_of MilkTea::AST::LocalDecl, local_decl
    assert_equal :var, local_decl.kind
    assert_instance_of MilkTea::AST::Identifier, local_decl.value
    assert_nil local_decl.else_binding
    assert_equal 1, local_decl.else_body.length
    assert_instance_of MilkTea::AST::ReturnStmt, local_decl.else_body.first
  end

  def test_rejects_keyword_as_local_variable_name_with_clear_message
    source = <<~MT
      function main() -> int:
          let if = 1
          return 0
    MT

    error = assert_raises(MilkTea::ParseError) do
      MilkTea::Parser.parse(source)
    end

    assert_match(/keyword 'if' cannot be used as local variable name/, error.message)
  end

  def test_parses_public_declarations_and_methods
    source = <<~MT
      public const answer: int = 42
      public var counter: int = 0
      public type Score = int

      public struct Counter:
          value: int

      extending Counter:
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

    extending_block = ast.declarations[4]
    assert_equal :public, extending_block.methods[0].visibility
    assert_equal :private, extending_block.methods[1].visibility
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

  def test_parses_type_param_source_coordinates
    source = <<~MT
      function identity[span](value: span) -> span:
          return value
    MT

    ast = MilkTea::Parser.parse(source)
    function_decl = ast.declarations.first
    type_param = function_decl.type_params.first

    assert_equal "span", type_param.name
    assert_equal 1, type_param.line
    assert_equal source.lines.first.index("span") + 1, type_param.column
    assert_equal "span".length, type_param.length
  end

  def test_parses_former_constraint_words_as_ordinary_names
    source = <<~MT
      interface hashes:
          function hash() -> uint

      interface equates:
          function equal() -> bool

      function defaults() -> int:
          return 0

      function combine[T implements hashes and equates]() -> int:
          return defaults()
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal %w[hashes equates defaults combine], ast.declarations.map(&:name)
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

  def test_parses_top_level_and_struct_event_declarations
    source = <<~MT
      public event reload_requested[4]

      struct Window:
          title: str
          event closed[4]
          public event resized[8](ResizeEvent)
    MT

    ast = MilkTea::Parser.parse(source)
    top_level_event = ast.declarations[0]
    struct_decl = ast.declarations[1]

    assert_instance_of MilkTea::AST::EventDecl, top_level_event
    assert_equal "reload_requested", top_level_event.name
    assert_equal 4, top_level_event.capacity
    assert_nil top_level_event.payload_type
    assert_equal :public, top_level_event.visibility

    assert_instance_of MilkTea::AST::StructDecl, struct_decl
    assert_equal ["title"], struct_decl.fields.map(&:name)
    assert_equal %w[closed resized], struct_decl.events.map(&:name)
    assert_equal [4, 8], struct_decl.events.map(&:capacity)
    assert_nil struct_decl.events[0].payload_type
    assert_equal "ResizeEvent", struct_decl.events[1].payload_type.name.to_s
    assert_equal [:private, :public], struct_decl.events.map(&:visibility)
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

  def test_rejects_pub_on_extending_block
    source = <<~MT
      public extending Counter:
          function read() -> int:
              return 0
    MT

    error = assert_raises(MilkTea::ParseError) { MilkTea::Parser.parse(source) }

    assert_match(/public is not allowed on extending blocks/, error.message)
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

  def test_parses_match_expression
    source = <<~MT
      variant Step:
          keep(value: int)
          stop

      function main(step: Step) -> int:
          return match step:
              Step.keep as payload: payload.value
              Step.stop: 0
    MT

    ast = MilkTea::Parser.parse(source)
    return_stmt = ast.declarations[1].body.first

    assert_instance_of MilkTea::AST::ReturnStmt, return_stmt
    assert_instance_of MilkTea::AST::MatchExpr, return_stmt.value
    assert_equal "payload", return_stmt.value.arms.first.binding_name
    assert_instance_of MilkTea::AST::Identifier, return_stmt.value.arms.first.value.receiver
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

  def test_parses_pass_statements_in_nested_blocks
    source = <<~MT
      function main(flag: bool) -> int:
          if flag:
              pass
          defer:
              pass
          return 0
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    if_stmt = main_fn.body[0]
    defer_stmt = main_fn.body[1]

    assert_instance_of MilkTea::AST::IfStmt, if_stmt
    assert_instance_of MilkTea::AST::PassStmt, if_stmt.branches[0].body.first
    assert_instance_of MilkTea::AST::DeferStmt, defer_stmt
    assert_instance_of MilkTea::AST::PassStmt, defer_stmt.body.first
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

  def test_parses_attribute_declarations_and_supported_attribute_targets
    source = <<~MT
      public attribute[field] rename(name: str)
      public attribute[callable] inline

      @[packed]
      @[align(16)]
      public struct Header:
          @[rename("payload_len")]
          value: uint

      @[inline]
      public function parse() -> int:
          return 0
    MT

    ast = MilkTea::Parser.parse(source)
    rename_attr = ast.declarations[0]
    inline_attr = ast.declarations[1]
    header = ast.declarations[2]
    parse_fn = ast.declarations[3]

    assert_instance_of MilkTea::AST::AttributeDecl, rename_attr
    assert_equal "rename", rename_attr.name
    assert_equal [:field], rename_attr.targets
    assert_instance_of MilkTea::AST::AttributeDecl, inline_attr
    assert_equal [:callable], inline_attr.targets
    assert_equal true, header.packed
    assert_equal 16, header.alignment
    assert_equal %w[packed align], header.attributes.map { |attribute| attribute.name.to_s }
    assert_equal ["rename"], header.fields.first.attributes.map { |attribute| attribute.name.to_s }
    assert_equal ["inline"], parse_fn.attributes.map { |attribute| attribute.name.to_s }
  end

  def test_rejects_legacy_layout_syntax
    error = assert_raises(MilkTea::ParseError) do
      MilkTea::Parser.parse(
        <<~MT,
          packed struct Header:
              tag: ubyte
        MT
      )
    end

    assert_match(/layout modifiers must use attributes/, error.message)
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

  def test_parses_unsafe_expression_after_boolean_operator_in_if_condition
    source = <<~MT
      function main(ready: bool, ptr: ptr[bool]) -> int:
          if ready and unsafe: read(ptr):
              return 1
          return 0
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations[0]
    if_stmt = main_fn.body[0]

    assert_instance_of MilkTea::AST::IfStmt, if_stmt
    assert_instance_of MilkTea::AST::BinaryOp, if_stmt.branches[0].condition
    assert_equal "and", if_stmt.branches[0].condition.operator
    assert_instance_of MilkTea::AST::UnsafeExpr, if_stmt.branches[0].condition.right
  end

  def test_parses_not_unsafe_expression_in_if_condition
    source = <<~MT
      function main(ptr: ptr[bool]) -> int:
          if not unsafe: read(ptr):
              return 1
          return 0
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations[0]
    if_stmt = main_fn.body[0]

    assert_instance_of MilkTea::AST::IfStmt, if_stmt
    assert_instance_of MilkTea::AST::UnaryOp, if_stmt.branches[0].condition
    assert_equal "not", if_stmt.branches[0].condition.operator
    assert_instance_of MilkTea::AST::UnsafeExpr, if_stmt.branches[0].condition.operand
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

  def test_parses_whitespace_adjacent_string_literals_on_same_line
    source = <<~MT
      const title: str = "Milk" " Tea" " language"
    MT

    ast = MilkTea::Parser.parse(source)
    declaration = ast.declarations[0]

    assert_instance_of MilkTea::AST::StringLiteral, declaration.value
    assert_equal false, declaration.value.cstring
    assert_equal "Milk Tea language", declaration.value.value
  end

  def test_parses_mixed_adjacent_cstring_and_string_literals_in_call_arguments
    source = <<~MT
      function main() -> void:
          fatal(
              c"async runtime requires an active runtime; use async.wait or async.run, "
              "or call the explicit *_on helpers")
    MT

    ast = MilkTea::Parser.parse(source)
    call = ast.declarations[0].body[0].expression

    assert_instance_of MilkTea::AST::Call, call
    assert_equal 1, call.arguments.length
    literal = call.arguments[0].value
    assert_instance_of MilkTea::AST::StringLiteral, literal
    assert_equal false, literal.cstring
    assert_equal "async runtime requires an active runtime; use async.wait or async.run, or call the explicit *_on helpers", literal.value
  end

  def test_parses_parenthesized_multiline_binary_expression
    source = <<~MT
      function main() -> int:
          let total = (
              1
              + 2
          )
          return total
    MT

    ast = MilkTea::Parser.parse(source)
    declaration = ast.declarations[0].body[0]

    assert_instance_of MilkTea::AST::BinaryOp, declaration.value
    assert_equal "+", declaration.value.operator
  end

  def test_parses_binary_expression_continued_after_operator
    source = <<~MT
      function main() -> int:
          let total = 1 +
              2
          return total
    MT

    ast = MilkTea::Parser.parse(source)
    declaration = ast.declarations[0].body[0]

    assert_instance_of MilkTea::AST::BinaryOp, declaration.value
    assert_equal "+", declaration.value.operator
  end

  def test_parses_range_expression_continued_after_operator
    source = <<~MT
      function main() -> void:
          let values = 1 ..
              4
          pass
    MT

    ast = MilkTea::Parser.parse(source)
    declaration = ast.declarations[0].body[0]

    assert_instance_of MilkTea::AST::RangeExpr, declaration.value
    assert_equal 1, declaration.value.start_expr.value
    assert_equal 4, declaration.value.end_expr.value
  end

  def test_parses_multiline_type_and_parameter_lists_with_trailing_commas
    source = <<~MT
      struct Slice[T,]:
          data: ptr[T]
          len: ptr_uint

      function first[T,](
          items: Slice[
              T,
          ],
      ) -> ptr[T]?:
          return items.data

      function main() -> ptr[int]?:
          let value = 7
          let items = Slice[
              int,
          ](
              data = ptr_of(value),
              len = 1,
          )
          let callback = proc(
              current: ptr[int],
          ) -> ptr[int]?:
              return current
          return callback(items.data)
    MT

    ast = MilkTea::Parser.parse(source)

    slice = ast.declarations[0]
    assert_equal ["T"], slice.type_params.map(&:name)

    first = ast.declarations[1]
    assert_equal ["T"], first.type_params.map(&:name)
    assert_equal "Slice", first.params.first.type.name.to_s
    assert_equal "T", first.params.first.type.arguments.first.value.name.to_s

    main_fn = ast.declarations[2]
    constructor = main_fn.body[1].value
    assert_instance_of MilkTea::AST::Call, constructor
    assert_instance_of MilkTea::AST::Specialization, constructor.callee
    assert_equal "int", constructor.callee.arguments.first.value.name.to_s

    callback = main_fn.body[2].value
    assert_instance_of MilkTea::AST::ProcExpr, callback
    assert_equal "current", callback.params.first.name
  end

  def test_parses_multiline_variant_fields_and_function_type_params_with_trailing_commas
    source = <<~MT
      variant Token[T,]:
          callback(
              handler: fn(
                  value: int,
              ) -> int,
              payload: T,
          )
    MT

    ast = MilkTea::Parser.parse(source)
    token = ast.declarations[0]

    assert_equal ["T"], token.type_params.map(&:name)

    arm = token.arms[0]
    assert_equal "callback", arm.name
    assert_equal %w[handler payload], arm.fields.map(&:name)

    handler_type = arm.fields[0].type
    assert_instance_of MilkTea::AST::FunctionType, handler_type
    assert_equal "value", handler_type.params[0].name
    assert_equal "int", handler_type.return_type.name.to_s
  end

  def test_rejects_binary_expression_split_before_operator_without_grouping
    source = <<~MT
      function main() -> int:
          let total = 1
              + 2
          return total
    MT

    error = assert_raises(MilkTea::ParseError) do
      MilkTea::Parser.parse(source)
    end

    assert_match(/unexpected indentation in statement block/, error.message)
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

  def test_parses_member_indexed_call_instead_of_generic_specialization
    source = <<~MT
      struct Entry:
          callbacks: array[fn(value: int) -> int, 1]

      function identity(value: int) -> int:
          return value

      function main() -> int:
          let entry = Entry(callbacks = array[fn(value: int) -> int, 1](identity))
          return entry.callbacks[0](1)
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations[2]
    call = main_fn.body[1].value

    assert_instance_of MilkTea::AST::Call, call
    assert_instance_of MilkTea::AST::IndexAccess, call.callee
    assert_instance_of MilkTea::AST::MemberAccess, call.callee.receiver
    assert_equal "callbacks", call.callee.receiver.member
    assert_instance_of MilkTea::AST::IntegerLiteral, call.callee.index
    assert_equal 0, call.callee.index.value
  end

  def test_parses_explicit_cast_call_form_as_ordinary_indexed_call
    source = <<~MT
      function main(value: int) -> long:
          return cast[long](value)
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    call = main_fn.body.first.value

    assert_instance_of MilkTea::AST::Call, call
    assert_instance_of MilkTea::AST::IndexAccess, call.callee
    assert_instance_of MilkTea::AST::Identifier, call.callee.receiver
    assert_equal "cast", call.callee.receiver.name
    assert_instance_of MilkTea::AST::Identifier, call.callee.index
    assert_equal "long", call.callee.index.name
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

  def test_parses_proc_type_refs_in_function_returns
    source = <<~MT
      function factory(offset: int) -> proc(value: int) -> int:
          return proc(value: int) -> int:
              return value + offset
    MT

    ast = MilkTea::Parser.parse(source)
    factory_fn = ast.declarations.first

    assert_instance_of MilkTea::AST::ProcType, factory_fn.return_type
    assert_equal "value", factory_fn.return_type.params.first.name
    assert_equal "int", factory_fn.return_type.return_type.name.to_s
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

  def test_parses_expression_bodied_proc_expressions_in_call_arguments
    source = <<~MT
      function apply(callback: proc(value: int) -> bool, value: int) -> bool:
          return callback(value)

      function main() -> bool:
          return apply(proc(value: int) -> bool: value > 3, 4)
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations[1]
    return_stmt = main_fn.body.first
    call = return_stmt.value
    proc_argument = call.arguments.first.value

    assert_instance_of MilkTea::AST::ProcExpr, proc_argument
    assert_equal 1, proc_argument.body.length
    assert_instance_of MilkTea::AST::ReturnStmt, proc_argument.body.first
    assert_instance_of MilkTea::AST::BinaryOp, proc_argument.body.first.value
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
      function capacity_of[N](buffer: str_buffer[N]) -> ptr_uint:
          return buffer.capacity()

      function main() -> int:
          var buffer: str_buffer[32]
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

      function capacity_of[N](buffer: str_buffer[N]) -> ptr_uint:
          return buffer.capacity()

      function main() -> int:
          var buffer: str_buffer[CAPACITY]
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
          var buffer: str_buffer[32]
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
      foreign function text_box[N](text: str_buffer[N] as ptr[char]) -> void = c.TextBox(text)

      function main() -> int:
          var buffer: str_buffer[32]
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

  def test_parses_zero_value_specializations
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

  def test_parses_array_char_zero_value_specializations
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

      extending Counter:
          async function read() -> int:
              return this.value

          async editable function bump() -> void:
              this.value += 1
    MT

    ast = MilkTea::Parser.parse(source)
    methods = ast.declarations[1]

    assert_instance_of MilkTea::AST::ExtendingBlock, methods
    assert_equal true, methods.methods[0].async
    assert_equal :plain, methods.methods[0].kind
    assert_equal true, methods.methods[1].async
    assert_equal :editable, methods.methods[1].kind
  end

  def test_rejects_public_interface_methods
    source = <<~MT
      interface Damageable:
          public function take_damage(amount: int) -> void
    MT

    error = assert_raises(MilkTea::ParseError) do
      MilkTea::Parser.parse(source)
    end

    assert_match(/public is not allowed on interface methods/, error.message)
  end

  def test_rejects_generic_interface_methods
    source = <<~MT
      interface Factory:
          function create[T]() -> T
    MT

    error = assert_raises(MilkTea::ParseError) do
      MilkTea::Parser.parse(source)
    end

    assert_match(/interface method create cannot be generic/, error.message)
  end

  def test_parses_generic_extending_block_targets
    source = <<~MT
      struct Box[T]:
          value: T

      extending Box[T]:
          function get() -> T:
              return this.value
    MT

    ast = MilkTea::Parser.parse(source)
    methods = ast.declarations[1]

    assert_instance_of MilkTea::AST::ExtendingBlock, methods
    assert_equal "Box[T]", methods.type_name.to_s
  end

  def test_parses_generic_receiver_self_specialization_call
    source = <<~MT
      struct Box[T]:
          value: T

      extending Box[T]:
          static function create() -> Box[T]:
              return Box[T](value = zero[T])

          static function with_default() -> Box[T]:
              return Box[T].create()
    MT

    ast = MilkTea::Parser.parse(source)
    methods = ast.declarations[1]
    return_stmt = methods.methods[1].body.first
    call = return_stmt.value

    assert_instance_of MilkTea::AST::Call, call
    assert_instance_of MilkTea::AST::MemberAccess, call.callee
    assert_instance_of MilkTea::AST::Specialization, call.callee.receiver
    assert_equal "Box", call.callee.receiver.callee.name
    assert_equal "T", call.callee.receiver.arguments.first.value.name.to_s
    assert_equal "create", call.callee.member
  end

  def test_parses_multiline_generic_receiver_self_specialization_call
    source = <<~MT
      struct Box[T]:
          value: T

      extending Box[T]:
          static function create() -> Box[T]:
              return Box[T](value = zero[T])

          static function with_default() -> Box[T]:
              return Box[
                  T,
              ].create()
    MT

    ast = MilkTea::Parser.parse(source)
    methods = ast.declarations[1]
    return_stmt = methods.methods[1].body.first
    call = return_stmt.value

    assert_instance_of MilkTea::AST::Call, call
    assert_instance_of MilkTea::AST::MemberAccess, call.callee
    assert_instance_of MilkTea::AST::Specialization, call.callee.receiver
    assert_equal "Box", call.callee.receiver.callee.name
    assert_equal "T", call.callee.receiver.arguments.first.value.name.to_s
    assert_equal "create", call.callee.member
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

    assert_match(/keyword 'type' cannot be used as field name/, error.message)
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

  def test_rejects_extending_blocks_in_raw_modules
    source = <<~MT
      external

      extending Counter:
          function read() -> int:
              return 0
    MT

    error = assert_raises(MilkTea::ParseError) do
      MilkTea::Parser.parse(source)
    end

    assert_match(/extending is not allowed in external files/, error.message)
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
      "event ready[1]\n" => /event is not allowed in external files/,
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

  def test_parses_external_function_directional_params
    source = <<~MT
      external function fill(out value: int, inout total: int, label: cstr) -> void
    MT

    ast = MilkTea::Parser.parse(source)
    decl = ast.declarations.first

    assert_instance_of MilkTea::AST::ExternFunctionDecl, decl
    assert_equal %i[out inout plain], decl.params.map(&:mode)
    assert_equal %w[int int cstr], decl.params.map { |param| param.type.name.to_s }
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

  def test_parses_format_heredoc_literal
    source = <<~MT
      function main(flag: bool, count: int) -> ptr_uint:
          let text = f<<-FMT
          count=\#{count}
          precise=\#{if flag: 1.0 else: 2.0:.2}
          FMT
          return text.len
    MT

    ast = MilkTea::Parser.parse(source)
    local_decl = ast.declarations.first.body.first
    format_string = local_decl.value

    assert_instance_of MilkTea::AST::FormatString, format_string
    assert_equal 5, format_string.parts.length
    assert_instance_of MilkTea::AST::FormatTextPart, format_string.parts[0]
    assert_instance_of MilkTea::AST::FormatExprPart, format_string.parts[1]
    assert_equal "count=", format_string.parts[0].value
    assert_instance_of MilkTea::AST::Identifier, format_string.parts[1].expression
    assert_equal "count", format_string.parts[1].expression.name
    assert_equal :precision, format_string.parts[3].format_spec[:kind]
    assert_equal 2, format_string.parts[3].format_spec[:value]
  end

  def test_parses_format_string_hex_specs
    source = <<~MT
      function main(value: int) -> ptr_uint:
          let text = f"lower=\#{value:x} upper=\#{value:X}"
          return text.len
    MT

    ast = MilkTea::Parser.parse(source)
    local_decl = ast.declarations.first.body.first
    format_string = local_decl.value

    assert_instance_of MilkTea::AST::FormatString, format_string
    lower_expr = format_string.parts[1]
    upper_expr = format_string.parts[3]
    assert_equal({ kind: :hex, uppercase: false }, lower_expr.format_spec)
    assert_equal({ kind: :hex, uppercase: true }, upper_expr.format_spec)
  end

  def test_parses_format_string_octal_and_binary_specs
    source = <<~MT
      function main(value: int) -> ptr_uint:
          let text = f"oct=\#{value:o} OCT=\#{value:O} bin=\#{value:b} BIN=\#{value:B}"
          return text.len
    MT

    ast = MilkTea::Parser.parse(source)
    local_decl = ast.declarations.first.body.first
    format_string = local_decl.value

    assert_instance_of MilkTea::AST::FormatString, format_string
    assert_equal({ kind: :oct, uppercase: false }, format_string.parts[1].format_spec)
    assert_equal({ kind: :oct, uppercase: true }, format_string.parts[3].format_spec)
    assert_equal({ kind: :bin, uppercase: false }, format_string.parts[5].format_spec)
    assert_equal({ kind: :bin, uppercase: true }, format_string.parts[7].format_spec)
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

  def test_parse_collecting_errors_reports_unexpected_indentation_in_statement_block_and_recovers_following_declarations
    source = <<~MT
      function release_app() -> void:
          shutdown_network()
              app.registry.release()

      function default_state() -> int:
          return 0
    MT

    result = MilkTea::Parser.parse_collecting_errors(source, path: "demo.mt")

    assert_equal 1, result.errors.length
    assert_match(/unexpected indentation in statement block/, result.errors.first.message)
    assert_match(/demo\.mt:3:9/, result.errors.first.message)

    refute_nil result.ast
    assert_equal "default_state", result.ast.declarations.last&.name
  end

  def test_parse_collecting_errors_reports_lex_indentation_error_and_preserves_following_declarations
    source = <<~MT
      function release_app() -> void:
          shutdown_network()
           app.registry.release()

      function default_state() -> int:
          return 0
    MT

    result = MilkTea::Parser.parse_collecting_errors(source, path: "demo.mt")

    assert_equal 1, result.errors.length
    assert_match(/indentation must use multiples of 4 spaces/, result.errors.first.message)
    assert_match(/demo\.mt:3:6/, result.errors.first.message)

    refute_nil result.ast
    assert_equal %w[release_app default_state], result.ast.declarations.map(&:name)
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

  # ── Inline compile-time statements ────────────────────────────────────────

  def test_parses_when_stmt_with_enum
    source = <<~MT
      function handle() -> int:
          when FAVORITE:
              Color.red:
                  return 1
              Color.blue:
                  return 2
          return 0
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    when_stmt = main_fn.body.first

    assert_instance_of MilkTea::AST::WhenStmt, when_stmt
    assert_instance_of MilkTea::AST::Identifier, when_stmt.discriminant
    assert_equal "FAVORITE", when_stmt.discriminant.name
    assert_equal 2, when_stmt.branches.length
    assert_nil when_stmt.else_body
  end

  def test_parses_when_stmt_with_else_as_fallback_arm
    source = <<~MT
      function handle() -> int:
          when FLAG:
              A:
                  return 1
              else:
                  return 2
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    when_stmt = main_fn.body.first

    assert_instance_of MilkTea::AST::WhenStmt, when_stmt
    assert_equal 2, when_stmt.branches.length
  end

  def test_parses_when_stmt_with_exhaustive_enum
    source = <<~MT
      function label() -> str:
          when TARGET:
              Backend.gl:
                  return "gl"
              Backend.metal:
                  return "metal"
              Backend.vulkan:
                  return "vulkan"
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    when_stmt = main_fn.body.first

    assert_instance_of MilkTea::AST::WhenStmt, when_stmt
    assert_instance_of MilkTea::AST::Identifier, when_stmt.discriminant
    assert_equal "TARGET", when_stmt.discriminant.name
    assert_equal 3, when_stmt.branches.length
  end

  def test_parses_when_stmt_at_module_level_returns_stmt
    source = <<~MT
      function pick() -> int:
          when FLAG:
              Kind.a:
                  return 1
              Kind.b:
                  return 2
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    when_stmt = main_fn.body.first
    assert_instance_of MilkTea::AST::WhenStmt, when_stmt
    assert_equal 2, when_stmt.branches.length
  end

  def test_parses_inline_if
    source = <<~MT
      function debug() -> void:
          inline if DEBUG_MODE:
              log("debug on")
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    if_stmt = main_fn.body.first

    assert_instance_of MilkTea::AST::IfStmt, if_stmt
    assert if_stmt.inline
    assert_nil if_stmt.else_body
  end

  def test_parses_inline_if_else
    source = <<~MT
      function draw() -> void:
          inline if RENDER:
              fancy()
          else:
              simple()
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    if_stmt = main_fn.body.first

    assert_instance_of MilkTea::AST::IfStmt, if_stmt
    assert if_stmt.inline
    refute_nil if_stmt.else_body
  end

  def test_parses_inline_if_else_if
    source = <<~MT
      function draw() -> void:
          inline if A:
              path_a()
          else if B:
              path_b()
          else:
              fallback()
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    if_stmt = main_fn.body.first

    assert_instance_of MilkTea::AST::IfStmt, if_stmt
    assert if_stmt.inline
    assert_equal 2, if_stmt.branches.length
    refute_nil if_stmt.else_body
  end

  def test_parses_inline_for
    source = <<~MT
      function validate() -> void:
          inline for field in fields_of(Particle):
              static_assert(field.type == float, "bad")
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    for_stmt = main_fn.body.first

    assert_instance_of MilkTea::AST::ForStmt, for_stmt
    assert for_stmt.inline
    assert_equal "field", for_stmt.binding.name
  end

  def test_parses_inline_while
    source = <<~MT
      function pow() -> int:
          var n: int = 1
          inline while n < 1024:
              n = n * 2
          return n
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    while_stmt = main_fn.body[1]

    assert_instance_of MilkTea::AST::WhileStmt, while_stmt
    assert while_stmt.inline
  end

  def test_parses_inline_match
    source = <<~MT
      function draw(backend: Backend) -> void:
          inline match BACKEND:
              Backend.gl:
                  gl_draw()
              Backend.metal:
                  metal_draw()
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    match_stmt = main_fn.body.first

    assert_instance_of MilkTea::AST::MatchStmt, match_stmt
    assert match_stmt.inline
    assert_equal 2, match_stmt.arms.length
  end

  def test_parses_const_function
    source = <<~MT
      const function square(x: int) -> int:
          return x * x

      const RESULT: int = square(5)
    MT

    ast = MilkTea::Parser.parse(source)
    const_fn = ast.declarations.first

    assert_instance_of MilkTea::AST::FunctionDef, const_fn
    assert const_fn.const
  end

  def test_parses_const_function_block_body
    source = <<~MT
      const NEXT -> int:
          var n: int = 1
          while n < 1024:
              n = n * 2
          return n

      function main() -> int:
          return NEXT
    MT

    ast = MilkTea::Parser.parse(source)
    const_decl = ast.declarations.first

    assert_instance_of MilkTea::AST::ConstDecl, const_decl
    refute_nil const_decl.block_body
  end

  # ── Native math types ─────────────────────────────────────────────────────

  def test_parses_vec3_type_and_constructor
    source = <<~MT
      function direction() -> vec3:
          return vec3(x = 1.0, y = 0.0, z = 0.0)
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.first
    assert_instance_of MilkTea::AST::FunctionDef, main_fn
  end

  def test_parses_ivec4_type
    source = <<~MT
      function make_ivec() -> ivec4:
          return ivec4(x = 1, y = 0, z = 0, w = 1)
    MT

    ast = MilkTea::Parser.parse(source)
    assert_instance_of MilkTea::AST::FunctionDef, ast.declarations.first
  end

  def test_parses_mat4_type_and_constructor
    source = <<~MT
      function identity() -> mat4:
          return mat4(
              col0 = vec4(x = 1.0, y = 0.0, z = 0.0, w = 0.0),
              col1 = vec4(x = 0.0, y = 1.0, z = 0.0, w = 0.0),
              col2 = vec4(x = 0.0, y = 0.0, z = 1.0, w = 0.0),
              col3 = vec4(x = 0.0, y = 0.0, z = 0.0, w = 1.0),
          )
    MT

    ast = MilkTea::Parser.parse(source)
    assert_instance_of MilkTea::AST::FunctionDef, ast.declarations.first
  end

  def test_parses_quat_type_and_constructor
    source = <<~MT
      function identity() -> quat:
          return quat(x = 0.0, y = 0.0, z = 0.0, w = 1.0)
    MT

    ast = MilkTea::Parser.parse(source)
    assert_instance_of MilkTea::AST::FunctionDef, ast.declarations.first
  end

  # ── SoA ───────────────────────────────────────────────────────────────────

  def test_parses_soa_type_and_index
    source = <<~MT
      struct Particle:
          x: float
          y: float

      function sum_x(data: SoA[Particle, 16]) -> float:
          var total: float = 0.0
          for i in 0..16:
              total += data[i].x
          return total
    MT

    ast = MilkTea::Parser.parse(source)
    main_fn = ast.declarations.last
    assert_instance_of MilkTea::AST::FunctionDef, main_fn
  end

  # ── order[T] ──────────────────────────────────────────────────────────────

  def test_parses_order_builtin
    source = <<~MT
      function compare(a: int, b: int) -> int:
          return order[int](a, b)
    MT

    ast = MilkTea::Parser.parse(source)
    assert_instance_of MilkTea::AST::FunctionDef, ast.declarations.first
  end

  # ── size_of / align_of with generic type ──────────────────────────────────

  def test_parses_size_of_with_generic_type
    source = <<~MT
      function size[T]() -> ptr_uint:
          return size_of(T)
    MT

    ast = MilkTea::Parser.parse(source)
    assert_instance_of MilkTea::AST::FunctionDef, ast.declarations.first
  end

  def test_parses_align_of_with_generic_type
    source = <<~MT
      function alignment[T]() -> ptr_uint:
          return align_of(T)
    MT

    ast = MilkTea::Parser.parse(source)
    assert_instance_of MilkTea::AST::FunctionDef, ast.declarations.first
  end

  def test_parses_emit_function_inside_const_function
    source = <<~MT
      const function generate() -> void:
          emit function helper() -> int:
              return 42
      function main() -> int:
          return helper()
    MT

    ast = MilkTea::Parser.parse(source)
    const_fn = ast.declarations.first
    assert_instance_of MilkTea::AST::FunctionDef, const_fn
    assert const_fn.const

    body = const_fn.body
    emit_stmt = body.first
    assert_instance_of MilkTea::AST::EmitStmt, emit_stmt
    assert_instance_of MilkTea::AST::FunctionDef, emit_stmt.declaration
  end

  def test_parses_struct_with_lifetime_param
    source = <<~MT
      struct Cursor[@a]:
          data: ref[@a, span[ubyte]]
          position: ptr_uint
    MT

    ast = MilkTea::Parser.parse(source)
    struct_decl = ast.declarations.first
    assert_instance_of MilkTea::AST::StructDecl, struct_decl
    assert_equal ["@a"], struct_decl.lifetime_params
    assert_equal ["data", "position"], struct_decl.fields.map(&:name)

    data_field = struct_decl.fields.first
    assert_equal "ref", data_field.type.name.to_s
    assert_equal "@a", data_field.type.lifetime
  end

  def test_parses_struct_with_lifetime_and_type_params
    source = <<~MT
      struct Container[@a, T]:
          data: ref[@a, span[T]]
    MT

    ast = MilkTea::Parser.parse(source)
    struct_decl = ast.declarations.first
    assert_equal ["@a"], struct_decl.lifetime_params
    assert_equal ["T"], struct_decl.type_params.map(&:name)
  end

  def test_parses_ref_type_without_lifetime_is_unchanged
    source = <<~MT
      function foo(x: ref[int]) -> void:
          pass
    MT

    ast = MilkTea::Parser.parse(source)
    fn = ast.declarations.first
    param_type = fn.params.first.type
    assert_equal "ref", param_type.name.to_s
    assert_nil param_type.lifetime
  end

  def test_parses_generic_interface
    source = <<~MT
      interface Mapper[T, U]:
          function map(x: T) -> U
          static function identity() -> T
    MT

    ast = MilkTea::Parser.parse(source)
    iface = ast.declarations.first
    assert_instance_of MilkTea::AST::InterfaceDecl, iface
    assert_equal ["T", "U"], iface.type_params.map(&:name)
    assert_equal ["map", "identity"], iface.methods.map(&:name)
  end

  def test_parses_interface_without_type_params
    source = <<~MT
      interface Empty:
          function nothing() -> void
    MT

    ast = MilkTea::Parser.parse(source)
    iface = ast.declarations.first
    assert_instance_of MilkTea::AST::InterfaceDecl, iface
    assert_equal [], iface.type_params
  end

end

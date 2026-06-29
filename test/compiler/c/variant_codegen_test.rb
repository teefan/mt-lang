# frozen_string_literal: true

require_relative "helpers"

class VariantCodegenTest < Minitest::Test
  include CodegenTestHelpers

  def test_self_referencing_variant_no_cycle
    source = <<~MT
      # module demo.nocycle

      variant Expr:
          identifier(name: str)
          binary_op(operator: str, left: Expr, right: Expr)
          unary_op(operator: str, operand: Expr)

      function make_expr() -> Expr:
          return Expr.binary_op(operator = "+", left = Expr.identifier(name = "a"), right = Expr.identifier(name = "b"))

      function main() -> int:
          let e = make_expr()
          return 0
    MT

    generated = generate_c_from_program_source(source)
    assert_match(/typedef/, generated, "should produce valid C with typedefs")
  end

  def test_self_referencing_arm_fields_emit_as_pointers
    source = <<~MT
      # module demo.selfref

      variant Node:
          leaf(value: int)
          branch(left: Node, right: Node)

      function make_tree() -> Node:
          let left = Node.leaf(value = 1)
          let right = Node.leaf(value = 2)
          return Node.branch(left = left, right = right)

      function main() -> int:
          let root = make_tree()
          return 0
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/demo_selfref_Node \*left;/, generated, "left field must be a pointer to Node")
    assert_match(/demo_selfref_Node \*right;/, generated, "right field must be a pointer to Node")
  end

  def test_variant_constructor_heap_copies_self_ref_fields
    source = <<~MT
      # module demo.varlit

      variant Node:
          leaf(value: int)
          branch(left: Node, right: Node)

      function make_node() -> Node:
          let left = Node.leaf(value = 1)
          let right = Node.leaf(value = 2)
          return Node.branch(left = left, right = right)

      function main() -> int:
          let root = make_node()
          return 0
    MT

    generated = generate_c_from_program_source(source)

    assert_match(
      /\.left = \(\(demo_varlit_Node\*\)memcpy\(malloc\(sizeof\(demo_varlit_Node\)\), &\(left\), sizeof\(demo_varlit_Node\)\)\)/,
      generated,
      "branch constructor must heap-copy the left field to avoid a dangling stack pointer"
    )
    assert_match(
      /\.right = \(\(demo_varlit_Node\*\)memcpy\(malloc\(sizeof\(demo_varlit_Node\)\), &\(right\), sizeof\(demo_varlit_Node\)\)\)/,
      generated,
      "branch constructor must heap-copy the right field to avoid a dangling stack pointer"
    )
    refute_match(/\.left = &left\b/, generated,
                "branch constructor must not return the address of a stack local")
  end

  def test_value_receiver_method_call_from_editable_context
    source = <<~MT
      # module demo.vrecv

      struct Counter:
          count: int

      extending Counter:
          public static function create() -> Counter:
              return Counter(count = 0)

          public function read() -> int:
              return this.count

          public editable function increment() -> void:
              this.count += 1

          public editable function increment_and_read() -> int:
              this.increment()
              return this.read()

      function main() -> int:
          var c = Counter.create()
          let val = c.increment_and_read()
          return val
    MT

    generated = generate_c_from_program_source(source)
    assert_match(/Counter_read\(\*this\)/, generated,
                "editable method must dereference this when calling value-receiver method")
  end

  # --- match else: as wildcard (Bug 7: parser fix) ---

  def test_match_with_else_as_wildcard
    source = <<~MT
      # module demo.elsewild

      variant Color:
          red(value: int)
          green(value: int)
          blue(value: int)

      function describe(c: Color) -> int:
          match c:
              Color.red as r:
                  return r.value
              else:
                  return 0

      function main() -> int:
          var c = Color.red(value = 42)
          return describe(c)
    MT

    generated = generate_c_from_program_source(source)
    assert_match(/demo_elsewild_Color_kind_red/, generated,
                "match with else: must produce valid C with variant arm dispatching")
  end

  def test_match_expression_with_else_as_wildcard
    source = <<~MT
      # module demo.elsewild2

      variant Color:
          red(value: int)
          green(value: int)

      function get_color_name(c: Color) -> int:
          return match c:
              Color.red as r: r.value
              else: 0

      function main() -> int:
          var c = Color.green(value = 7)
          return get_color_name(c)
    MT

    generated = generate_c_from_program_source(source)
    assert_match(/demo_elsewild2_Color_kind_red/, generated,
                "match expression with else: must produce valid C")
  end

  # --- C keyword arm name sanitization (Bug 11) ---

  def test_c_keyword_arm_name_sizeof
    source = <<~MT
      # module demo.ckw1

      variant Token:
          sizeof(val: int)
          switch(val: str)

      function make_token() -> Token:
          return Token.sizeof(val = 42)

      function main() -> int:
          var t = make_token()
          match t:
              Token.sizeof as s:
                  return s.val
              else:
                  return 0
    MT

    generated = generate_c_from_program_source(source)
    assert_match(/struct demo_ckw1_Token_sizeof/, generated,
                "C keyword arm sizeof must produce valid struct type name")
    assert_match(/struct demo_ckw1_Token_switch/, generated,
                "C keyword arm switch must produce valid struct type name")
    refute_match(/(?<![a-zA-Z_])sizeof(?![a-zA-Z_])/, generated,
                "arm name sizeof must NOT appear as standalone C identifier")
  end

  def test_c_keyword_arm_name_case_default
    source = <<~MT
      # module demo.ckw2

      variant Action:
          default(val: int)
          case(val: int)

      function make_action() -> Action:
          return Action.case(val = 1)

      function main() -> int:
          var a = make_action()
          match a:
              Action.case as c:
                  return c.val
              else:
                  return 0
    MT

    generated = generate_c_from_program_source(source)
    refute_match(/\.data\.case\b/, generated,
                   "C keyword arm case as union member must be sanitized")
    refute_match(/\.data\.default\b/, generated,
                   "C keyword arm default as union member must be sanitized")
    assert_match(/\.data\.case_/, generated,
                "C keyword arm case must be sanitized as case_")
  end
end

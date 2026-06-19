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

  def test_variant_constructor_uses_address_of_for_self_ref_fields
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

    assert_match(/\.left = &left/, generated, "branch constructor must use address-of for left field")
    assert_match(/\.right = &right/, generated, "branch constructor must use address-of for right field")
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
end

# frozen_string_literal: true

require "set"
require_relative "../test_helper"

class MilkTeaCFGTest < Minitest::Test
  def test_liveness_tracks_loop_backedge_reads
    body = function_body(<<~MT)
      module demo.cfg

      def main() -> i32:
          var index: i32 = 0
          while index < 3:
              index += 1
          return index
    MT

    graph = MilkTea::CFG::Builder.new.build(body)
    liveness = MilkTea::CFG::Liveness.solve(graph)

    write_node = graph.each_node.find { |node| node.writes.include?("index") && node.kind == :assignment }
    refute_nil write_node
    assert_includes liveness.live_out[write_node.id], "index"
  end

  def test_initializer_is_live_when_only_conditionally_overwritten
    body = function_body(<<~MT)
      module demo.cfg

      def main(cond: bool) -> i32:
          var count: i32 = 0
          if cond:
              count = 1
          return count
    MT

    graph = MilkTea::CFG::Builder.new.build(body)
    liveness = MilkTea::CFG::Liveness.solve(graph)

    init_node = graph.each_node.find do |node|
      node.writes_info.any? { |w| w[:name] == "count" && w[:origin] == :declaration }
    end
    refute_nil init_node
    assert_includes liveness.live_out[init_node.id], "count"
  end

  def test_initializer_is_dead_when_overwritten_on_all_paths
    body = function_body(<<~MT)
      module demo.cfg

      def main(cond: bool) -> i32:
          var x: i32 = 0
          if cond:
              x = 1
          else:
              x = 2
          return x
    MT

    graph = MilkTea::CFG::Builder.new.build(body)
    liveness = MilkTea::CFG::Liveness.solve(graph)

    init_node = graph.each_node.find do |node|
      node.writes_info.any? { |w| w[:name] == "x" && w[:origin] == :declaration }
    end
    refute_nil init_node
    refute_includes liveness.live_out[init_node.id], "x"
  end

  def test_builder_uses_sema_binding_ids_for_shadowed_locals
    context = sema_function_context(<<~MT)
      module demo.cfg

      def main(flag: bool) -> i32:
          let x: i32 = 1
          if flag:
              let x: i32 = 2
              return x
          return x
    MT

    graph = MilkTea::CFG::Builder.new(
      binding_resolution: context[:analysis].binding_resolution,
      strict_binding_ids: true,
    ).build(context[:function].body)

    x_decl_keys = graph.each_node.flat_map { |node| node.writes_info }
      .select { |w| w[:name] == "x" && w[:origin] == :declaration }
      .map { |w| w[:binding_key] }

    assert_equal 2, x_decl_keys.uniq.length
  end

  def test_definite_assignment_reports_read_before_assignment_with_partial_writes
    context = sema_function_context(<<~MT)
      module demo.cfg

      def main(flag: bool) -> i32:
          var x: i32
          if flag:
              x = 1
          return x
    MT

    graph = MilkTea::CFG::Builder.new(
      binding_resolution: context[:analysis].binding_resolution,
      strict_binding_ids: true,
      local_decl_without_initializer_writes: false,
    ).build(context[:function].body)

    initially_assigned = context[:binding].body_params.each_with_object(Set.new) { |param, set| set << param.id }
    result = MilkTea::CFG::DefiniteAssignment.solve(graph, initially_assigned:)

    refute_empty result.read_before_assignment
  end

  def test_definite_assignment_treats_format_string_interpolation_as_read
    body = function_body(<<~MT)
      module demo.cfg

      def main(flag: bool) -> str:
          var x: i32
          if flag:
              x = 1
          return f"\#{x}"
    MT

    graph = MilkTea::CFG::Builder.new(
      local_decl_without_initializer_writes: false,
    ).build(body)

    result = MilkTea::CFG::DefiniteAssignment.solve(graph, initially_assigned: Set["flag"])

    assert_includes result.read_before_assignment.map(&:binding_key), "x"
  end

  def test_assignment_reads_expression_list_values
    body = function_body(<<~MT)
      module demo.cfg

      def main(left: i32, right: i32) -> i32:
          var values = array[i32, 2](0, 0)
          values[0..1] = (left, right)
          return left + right
    MT

    graph = MilkTea::CFG::Builder.new.build(body)
    assignment_node = graph.each_node.find { |node| node.kind == :assignment }

    refute_nil assignment_node
    assert_includes assignment_node.reads, "left"
    assert_includes assignment_node.reads, "right"
  end

  # ── Reachability ─────────────────────────────────────────────────────────

  def test_reachability_marks_post_return_as_unreachable
    body = function_body(<<~MT)
      module demo.cfg

      def main() -> i32:
          return 0
          let dead = 1
    MT

    graph    = MilkTea::CFG::Builder.new.build(body)
    reach    = MilkTea::CFG::Reachability.solve(graph)
    dead_node = graph.each_node.find { |n| n.kind == :local_decl && n.statement.respond_to?(:name) && n.statement.name == "dead" }

    refute_nil dead_node
    refute_includes reach.reachable_ids, dead_node.id
  end

  def test_reachability_all_branches_terminate_makes_successor_unreachable
    body = function_body(<<~MT)
      module demo.cfg

      def main(flag: bool) -> i32:
          if flag:
              return 1
          else:
              return 2
          let dead = 3
    MT

    graph    = MilkTea::CFG::Builder.new.build(body)
    reach    = MilkTea::CFG::Reachability.solve(graph)
    dead_node = graph.each_node.find { |n| n.kind == :local_decl && n.statement.respond_to?(:name) && n.statement.name == "dead" }

    refute_nil dead_node
    refute_includes reach.reachable_ids, dead_node.id
  end

  def test_reachability_entry_always_reachable
    body = function_body(<<~MT)
      module demo.cfg

      def main() -> i32:
          return 42
    MT

    graph = MilkTea::CFG::Builder.new.build(body)
    reach = MilkTea::CFG::Reachability.solve(graph)

    assert_includes reach.reachable_ids, graph.entry_id
  end

  # ── Labeled edges and NullabilityFlow ───────────────────────────────────

  def test_labeled_edges_on_if_condition
    body = function_body(<<~MT)
      module demo.cfg

      def main(p: bool) -> i32:
          if p:
              return 1
          return 0
    MT

    graph = MilkTea::CFG::Builder.new.build(body)
    cond  = graph.each_node.find { |n| n.kind == :if_condition }

    refute_nil cond
    true_succ  = cond.succs.first
    false_succ = cond.succs.last
    assert_equal :true_branch,  graph.edge_label(cond.id, true_succ)
    assert_equal :false_branch, graph.edge_label(cond.id, false_succ)
  end

  def test_nullability_flow_propagates_non_null_after_check
    body = function_body(<<~MT)
      module demo.cfg

      def main(p: bool) -> i32:
          if p:
              return 1
          return 0
    MT

    graph  = MilkTea::CFG::Builder.new.build(body)
    result = MilkTea::CFG::NullabilityFlow.solve(graph)

    # All nodes should have in_states populated (no errors)
    assert_equal graph.nodes.count, result.in_states.size
  end

  def test_nullability_flow_keeps_all_non_null_bindings_for_conjunction
    body = function_body(<<~MT)
      module demo.cfg

      def main(x: ptr[i32]?, y: ptr[i32]?) -> i32:
          if x != null and y != null:
              if x != null:
                  return 1
          return 0
    MT

    graph = MilkTea::CFG::Builder.new.build(body)
    result = MilkTea::CFG::NullabilityFlow.solve(graph)
    outer_if = body.first
    inner_if = outer_if.branches.first.body.first
    inner_branch = inner_if.branches.first

    assert_includes result.nonnull_before(inner_branch), "x"
    assert_includes result.nonnull_before(inner_branch), "y"
  end

  # ── ConstantPropagation ──────────────────────────────────────────────────

  def test_constant_propagation_simple_literal
    body = function_body(<<~MT)
      module demo.cfg

      def main() -> i32:
          let x: i32 = 42
          return x
    MT

    graph  = MilkTea::CFG::Builder.new.build(body)
    result = MilkTea::CFG::ConstantPropagation.solve(graph)

    ret_node = graph.each_node.find { |n| n.kind == :return }
    refute_nil ret_node
    const_val = result.constant_at(ret_node.id, "x")
    assert_equal 42, const_val
  end

  def test_constant_propagation_arithmetic
    body = function_body(<<~MT)
      module demo.cfg

      def main() -> i32:
          let a: i32 = 10
          let b: i32 = 32
          let c: i32 = a + b
          return c
    MT

    graph  = MilkTea::CFG::Builder.new.build(body)
    result = MilkTea::CFG::ConstantPropagation.solve(graph)

    ret_node = graph.each_node.find { |n| n.kind == :return }
    refute_nil ret_node
    assert_equal 42, result.constant_at(ret_node.id, "c")
  end

  def test_constant_propagation_nac_on_unknown
    body = function_body(<<~MT)
      module demo.cfg

      def main(x: i32) -> i32:
          let y: i32 = x + 1
          return y
    MT

    graph  = MilkTea::CFG::Builder.new.build(body)
    result = MilkTea::CFG::ConstantPropagation.solve(graph)

    ret_node = graph.each_node.find { |n| n.kind == :return }
    refute_nil ret_node
    assert_nil result.constant_at(ret_node.id, "y")  # not a constant
  end

  def test_constant_propagation_with_binding_ids_handles_shadowing
    context = sema_function_context(<<~MT)
      module demo.cfg

      def main(flag: bool) -> i32:
          let x: i32 = 10
          if flag:
              let x: i32 = 20
              return x
          return x
    MT

    resolution = context[:analysis].binding_resolution
    graph = MilkTea::CFG::Builder.new(
      binding_resolution: resolution,
      strict_binding_ids: true,
    ).build(context[:function].body)

    result = MilkTea::CFG::ConstantPropagation.solve(
      graph,
      binding_resolution: resolution,
      strict_binding_ids: true,
    )

    return_nodes = graph.each_node.select { |node| node.kind == :return }
    assert_equal 2, return_nodes.length

    return_constants = return_nodes.map do |node|
      id_reads = node.reads.select { |k| k.is_a?(Integer) }
      assert_equal 1, id_reads.length
      result.constant_at(node.id, id_reads.first)
    end

    assert_equal [10, 20], return_constants.sort
  end

  private

  def function_body(source)
    ast = MilkTea::Parser.parse(source, path: "demo.mt")
    fn = ast.declarations.find { |decl| decl.is_a?(MilkTea::AST::FunctionDef) }
    refute_nil fn
    fn.body
  end

  def sema_function_context(source, function_name = "main")
    ast = MilkTea::Parser.parse(source, path: "demo.mt")
    analysis = MilkTea::Sema.check(ast)
    function = ast.declarations.find { |decl| decl.is_a?(MilkTea::AST::FunctionDef) && decl.name == function_name }
    binding = analysis.functions.fetch(function_name)
    { analysis:, function:, binding: }
  end
end

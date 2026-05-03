# frozen_string_literal: true

require "set"

module MilkTea
  module CFG
    BindingResolution = Data.define(:identifier_binding_ids, :declaration_binding_ids)

    Node = Struct.new(
      :id,
      :kind,
      :statement,
      :line,
      :reads,
      :writes,
      :writes_info,
      :succs,
      :preds,
      keyword_init: true
    )

    class Graph
      attr_accessor :entry_id, :exit_id
      attr_reader :nodes

      def initialize
        @nodes = {}
        @next_id = 1
        @entry_id = nil
        @exit_id = nil
        @edge_labels = {}      # Hash[(from_id, to_id) → :true_branch | :false_branch]
        @edge_refinements = {} # Hash[(from_id, to_id) → Hash[binding_key → :non_null | :null]]
      end

      def add_node(kind:, statement: nil, line: nil, reads: Set.new, writes: Set.new, writes_info: [])
        id = @next_id
        @next_id += 1
        @nodes[id] = Node.new(
          id:,
          kind:,
          statement:,
          line:,
          reads: reads.dup,
          writes: writes.dup,
          writes_info: writes_info.map(&:dup),
          succs: [],
          preds: []
        )
        id
      end

      def add_edge(from, to, label: nil)
        return unless @nodes[from] && @nodes[to]

        @nodes[from].succs << to unless @nodes[from].succs.include?(to)
        @nodes[to].preds << from unless @nodes[to].preds.include?(from)
        @edge_labels[[from, to]] = label if label
      end

      def edge_label(from, to)
        @edge_labels[[from, to]]
      end

      def edge_refinement(from, to)
        @edge_refinements[[from, to]]
      end

      def set_edge_refinement(from, to, refinement)
        @edge_refinements[[from, to]] = refinement
      end

      def each_node
        return enum_for(:each_node) unless block_given?

        @nodes.each_value { |node| yield node }
      end

      def ids
        @nodes.keys
      end

      def read_names
        names = Set.new
        each_node { |node| names.merge(node.reads) }
        names
      end

      def read_bindings
        keys = Set.new
        each_node { |node| keys.merge(node.reads) }
        keys
      end
    end

    class Builder
      def initialize(ignore_name: nil, binding_resolution: nil, strict_binding_ids: false, local_decl_without_initializer_writes: false)
        @ignore_name = ignore_name || ->(_name) { false }
        @binding_resolution = binding_resolution
        @strict_binding_ids = strict_binding_ids
        @local_decl_without_initializer_writes = local_decl_without_initializer_writes
      end

      def build(stmts)
        @graph = Graph.new
        @graph.exit_id = @graph.add_node(kind: :exit)
        @graph.entry_id = build_block(stmts || [], @graph.exit_id, break_target: nil, continue_target: nil)
        @graph
      ensure
        @graph = nil
      end

      private

      def build_block(stmts, next_id, break_target:, continue_target:)
        current_next = next_id
        stmts.reverse_each do |stmt|
          current_next = build_statement(stmt, current_next, break_target:, continue_target:)
        end
        current_next
      end

      def build_statement(stmt, next_id, break_target:, continue_target:)
        case stmt
        when AST::LocalDecl
          reads = read_identifiers(stmt.value)
          writes = Set.new
          writes_info = []
          declaration_key = declaration_binding_key(stmt, stmt.name)
          if declaration_key && (stmt.value || @local_decl_without_initializer_writes)
            writes << declaration_key
            writes_info << { name: stmt.name, binding_key: declaration_key, line: stmt.line, column: stmt.column, origin: :declaration }
          end
          add_linear_node(:local_decl, stmt, next_id, reads:, writes:, writes_info:)
        when AST::Assignment
          reads = read_identifiers(stmt.value)
          reads.merge(assignment_target_reads(stmt.target, stmt.operator))
          reads.merge(assignment_target_side_effect_reads(stmt.target))

          writes = Set.new
          writes_info = []
          if stmt.target.is_a?(AST::Identifier)
            target_key = identifier_binding_key(stmt.target)
            if target_key
              writes << target_key
              writes_info << { name: stmt.target.name, binding_key: target_key, line: stmt.line, column: stmt.target.column, origin: :assignment }
            end
          end
          add_linear_node(:assignment, stmt, next_id, reads:, writes:, writes_info:)
        when AST::IfStmt
          fallback_entry = stmt.else_body ? build_block(stmt.else_body, next_id, break_target:, continue_target:) : next_id
          stmt.branches.reverse_each do |branch|
            then_entry = build_block(branch.body, next_id, break_target:, continue_target:)
            cond_id = @graph.add_node(
              kind: :if_condition,
              statement: branch,
              line: branch.respond_to?(:line) ? branch.line : stmt.line,
              reads: read_identifiers(branch.condition)
            )
            @graph.add_edge(cond_id, then_entry, label: :true_branch)
            @graph.add_edge(cond_id, fallback_entry, label: :false_branch)
            emit_null_test_refinements(cond_id, then_entry, fallback_entry, branch.condition)
            fallback_entry = cond_id
          end
          fallback_entry
        when AST::MatchStmt
          match_id = @graph.add_node(
            kind: :match_condition,
            statement: stmt,
            line: stmt.line,
            reads: read_identifiers(stmt.expression)
          )
          if stmt.arms.empty?
            @graph.add_edge(match_id, next_id)
          else
            stmt.arms.each do |arm|
              arm_entry = build_block(arm.body, next_id, break_target:, continue_target:)
              if arm.binding_name
                binding_key = declaration_binding_key(arm, arm.binding_name)
                if binding_key
                  bind_id = @graph.add_node(
                    kind: :match_binding,
                    statement: arm,
                    line: arm.binding_line || stmt.line,
                    writes: Set[binding_key],
                    writes_info: [{
                      name: arm.binding_name,
                      binding_key:,
                      line: arm.binding_line || stmt.line,
                      column: arm.binding_column,
                      origin: :match_binding,
                    }],
                  )
                  @graph.add_edge(bind_id, arm_entry)
                  arm_entry = bind_id
                end
              end
              @graph.add_edge(match_id, arm_entry)
            end
          end
          match_id
        when AST::WhileStmt
          cond_id = @graph.add_node(
            kind: :while_condition,
            statement: stmt,
            line: stmt.line,
            reads: read_identifiers(stmt.condition)
          )
          body_entry = build_block(stmt.body, cond_id, break_target: next_id, continue_target: cond_id)
          @graph.add_edge(cond_id, body_entry, label: :true_branch)
          @graph.add_edge(cond_id, next_id, label: :false_branch)
          emit_null_test_refinements(cond_id, body_entry, next_id, stmt.condition)
          cond_id
        when AST::ForStmt
          writes = Set.new
          writes_info = []
          if stmt.name
            loop_key = declaration_binding_key(stmt, stmt.name)
            if loop_key
              writes << loop_key
              writes_info << {
                name: stmt.name,
                binding_key: loop_key,
                line: stmt.line,
                column: stmt.column,
                origin: :for_binding,
              }
            end
          end
          header_id = @graph.add_node(
            kind: :for_header,
            statement: stmt,
            line: stmt.line,
            reads: read_identifiers(stmt.iterable),
            writes:,
            writes_info:
          )
          body_entry = build_block(stmt.body, header_id, break_target: next_id, continue_target: header_id)
          @graph.add_edge(header_id, body_entry)
          @graph.add_edge(header_id, next_id)
          header_id
        when AST::UnsafeStmt
          build_block(stmt.body, next_id, break_target:, continue_target:)
        when AST::DeferStmt
          body_entry = stmt.body ? build_block(stmt.body, next_id, break_target:, continue_target:) : next_id
          defer_id = @graph.add_node(
            kind: :defer,
            statement: stmt,
            line: stmt.line,
            reads: stmt.expression ? read_identifiers(stmt.expression) : Set.new
          )
          @graph.add_edge(defer_id, body_entry)
          defer_id
        when AST::ReturnStmt
          @graph.add_node(
            kind: :return,
            statement: stmt,
            line: stmt.line,
            reads: read_identifiers(stmt.value)
          )
        when AST::ExpressionStmt
          reads = read_identifiers(stmt.expression)
          writes, writes_info = write_targets_from_expression(stmt.expression, line: stmt.line)
          add_linear_node(:expression, stmt, next_id, reads:, writes:, writes_info:)
        when AST::StaticAssert
          add_linear_node(:static_assert, stmt, next_id, reads: read_identifiers(stmt.condition))
        when AST::BreakStmt
          target = break_target || next_id
          add_linear_node(:break, stmt, target)
        when AST::ContinueStmt
          target = continue_target || next_id
          add_linear_node(:continue, stmt, target)
        else
          add_linear_node(:other, stmt, next_id)
        end
      end

      def add_linear_node(kind, stmt, next_id, reads: Set.new, writes: Set.new, writes_info: [])
        node_id = @graph.add_node(kind:, statement: stmt, line: stmt.respond_to?(:line) ? stmt.line : nil, reads:, writes:, writes_info:)
        @graph.add_edge(node_id, next_id)
        node_id
      end

      def assignment_target_reads(target, operator)
        return Set.new if operator == "="
        return Set[identifier_binding_key(target)].compact if target.is_a?(AST::Identifier)

        assignment_target_side_effect_reads(target)
      end

      def assignment_target_side_effect_reads(target)
        case target
        when AST::Identifier
          Set.new
        when AST::MemberAccess
          read_identifiers(target.receiver)
        when AST::IndexAccess
          read_identifiers(target.receiver).merge(read_identifiers(target.index))
        else
          read_identifiers(target)
        end
      end

      def read_identifiers(expression, names = Set.new)
        case expression
        when nil
          nil
        when AST::Identifier
          key = identifier_binding_key(expression)
          names << key if key
        when AST::MemberAccess
          read_identifiers(expression.receiver, names)
        when AST::IndexAccess
          read_identifiers(expression.receiver, names)
          read_identifiers(expression.index, names)
        when AST::Specialization
          read_identifiers(expression.callee, names)
        when AST::Call
          read_identifiers(expression.callee, names)
          expression.arguments.each { |argument| read_identifiers(argument.value, names) }
        when AST::UnaryOp
          read_identifiers(expression.operand, names)
        when AST::BinaryOp
          read_identifiers(expression.left, names)
          read_identifiers(expression.right, names)
        when AST::IfExpr
          read_identifiers(expression.condition, names)
          read_identifiers(expression.then_expression, names)
          read_identifiers(expression.else_expression, names)
        when AST::ProcExpr
          nil
        when AST::AwaitExpr
          read_identifiers(expression.expression, names)
        when AST::IntegerLiteral, AST::FloatLiteral, AST::StringLiteral,
             AST::FormatString, AST::BooleanLiteral, AST::NullLiteral,
             AST::SizeofExpr, AST::AlignofExpr, AST::OffsetofExpr
          nil
        else
          nil
        end
        names
      end

      def write_targets_from_expression(expression, line: nil, writes: Set.new, writes_info: [])
        case expression
        when nil
          nil
        when AST::MemberAccess
          write_targets_from_expression(expression.receiver, line:, writes:, writes_info:)
        when AST::IndexAccess
          write_targets_from_expression(expression.receiver, line:, writes:, writes_info:)
          write_targets_from_expression(expression.index, line:, writes:, writes_info:)
        when AST::Specialization
          write_targets_from_expression(expression.callee, line:, writes:, writes_info:)
        when AST::Call
          write_targets_from_expression(expression.callee, line:, writes:, writes_info:)
          expression.arguments.each do |argument|
            value = argument.value
            if value.is_a?(AST::UnaryOp) && %w[out inout].include?(value.operator) && value.operand.is_a?(AST::Identifier)
              key = identifier_binding_key(value.operand)
              if key
                writes << key
                writes_info << {
                  name: value.operand.name,
                  binding_key: key,
                  line: line,
                  column: nil,
                  origin: :call_argument,
                }
              end
            end
            write_targets_from_expression(value, line:, writes:, writes_info:)
          end
        when AST::UnaryOp
          write_targets_from_expression(expression.operand, line:, writes:, writes_info:)
        when AST::BinaryOp
          write_targets_from_expression(expression.left, line:, writes:, writes_info:)
          write_targets_from_expression(expression.right, line:, writes:, writes_info:)
        when AST::IfExpr
          write_targets_from_expression(expression.condition, line:, writes:, writes_info:)
          write_targets_from_expression(expression.then_expression, line:, writes:, writes_info:)
          write_targets_from_expression(expression.else_expression, line:, writes:, writes_info:)
        when AST::AwaitExpr
          write_targets_from_expression(expression.expression, line:, writes:, writes_info:)
        when AST::ProcExpr,
             AST::Identifier,
             AST::IntegerLiteral,
             AST::FloatLiteral,
             AST::StringLiteral,
             AST::FormatString,
             AST::BooleanLiteral,
             AST::NullLiteral,
             AST::SizeofExpr,
             AST::AlignofExpr,
             AST::OffsetofExpr
          nil
        else
          nil
        end

        [writes, writes_info]
      end

      def identifier_binding_key(identifier_expression)
        return nil unless identifier_expression.is_a?(AST::Identifier)
        return nil if @ignore_name.call(identifier_expression.name)

        if @binding_resolution && (id = @binding_resolution.identifier_binding_ids[identifier_expression.object_id])
          return id
        end

        return nil if @strict_binding_ids

        identifier_expression.name
      end

      def declaration_binding_key(node, name)
        return nil if @ignore_name.call(name)

        if @binding_resolution && (id = @binding_resolution.declaration_binding_ids[node.object_id])
          return id
        end

        return nil if @strict_binding_ids

        name
      end

      # Analyze a boolean condition expression and annotate the two outgoing
      # edges of a branch node with nullability refinements.
      # true_succ is the true-branch target, false_succ the false/fallback target.
      def emit_null_test_refinements(cond_id, true_succ, false_succ, condition)
        pairs = null_check_pairs(condition, positive: true)
        return if pairs.empty?

        true_refs  = {}
        false_refs = {}
        pairs.each do |key, direction|
          if direction == :non_null_if_true
            true_refs[key]  = :non_null
            false_refs[key] = :null
          else # :null_if_true
            true_refs[key]  = :null
            false_refs[key] = :non_null
          end
        end
        @graph.set_edge_refinement(cond_id, true_succ, true_refs)  unless true_refs.empty?
        @graph.set_edge_refinement(cond_id, false_succ, false_refs) unless false_refs.empty?
      end

      # Returns Hash[binding_key => :non_null_if_true | :null_if_true] for a
      # condition expression, respecting `not`, `and`, and `or`.
      # `positive` flips meaning when inside a `not`.
      def null_check_pairs(expr, positive:)
        case expr
        when AST::UnaryOp
          return null_check_pairs(expr.operand, positive: !positive) if expr.operator == "not"
        when AST::BinaryOp
          case expr.operator
          when "and"
            return merge_null_pairs(null_check_pairs(expr.left, positive:), null_check_pairs(expr.right, positive:)) if positive
          when "or"
            return merge_null_pairs(null_check_pairs(expr.left, positive:), null_check_pairs(expr.right, positive:)) unless positive
          when "=="
            return single_null_pair(expr, positive:, null_on_true: true)
          when "!="
            return single_null_pair(expr, positive:, null_on_true: false)
          end
        end
        {}
      end

      def single_null_pair(binary_expr, positive:, null_on_true:)
        identifier =
          if binary_expr.left.is_a?(AST::Identifier) && binary_expr.right.is_a?(AST::NullLiteral)
            binary_expr.left
          elsif binary_expr.left.is_a?(AST::NullLiteral) && binary_expr.right.is_a?(AST::Identifier)
            binary_expr.right
          end
        return {} unless identifier

        key = identifier_binding_key(identifier)
        return {} unless key

        direction = null_on_true == positive ? :null_if_true : :non_null_if_true
        { key => direction }
      end

      def merge_null_pairs(left, right)
        # Keep only pairs that agree between both branches
        left.each_with_object({}) do |(key, dir), merged|
          merged[key] = dir if right[key] == dir
        end.merge(
          right.each_with_object({}) { |(key, dir), merged| merged[key] = dir unless left.key?(key) }
        )
      end
    end

    class Dataflow
      Result = Data.define(:in_states, :out_states)

      # Solves a dataflow equation over `graph`.
      #
      # When `edge_transfer:` is provided it is called as
      #   edge_transfer(node, in_state, succ_id, edge_label) -> out_state_for_that_edge
      # and replaces `transfer:` for producing per-successor states (forward only).
      # `transfer:` remains required when `edge_transfer:` is absent.
      def self.solve(graph, direction:, initial:, join:, transfer: nil, edge_transfer: nil, boundary_in: {}, boundary_out: {})
        raise ArgumentError, "direction must be :forward or :backward" unless %i[forward backward].include?(direction)
        raise ArgumentError, "provide either transfer: or edge_transfer:" if transfer.nil? && edge_transfer.nil?

        in_states  = {}
        out_states = {}
        edge_out   = {}  # [from_id, to_id] => state  (only when edge_transfer given)
        graph.ids.each do |id|
          in_states[id]  = initial.call
          out_states[id] = initial.call
        end

        changed = true
        while changed
          changed = false
          iteration_ids = direction == :forward ? graph.ids : graph.ids.reverse
          iteration_ids.each do |id|
            node = graph.nodes[id]

            if direction == :forward
              incoming =
                if boundary_in.key?(id)
                  boundary_in[id]
                elsif edge_transfer
                  join.call(node.preds.map { |pred| edge_out[[pred, id]] || initial.call })
                else
                  join.call(node.preds.map { |pred| out_states[pred] })
                end

              if edge_transfer
                node.succs.each do |succ|
                  label     = graph.edge_label(id, succ)
                  new_edge  = edge_transfer.call(node, incoming, succ, label)
                  old_edge  = edge_out[[id, succ]]
                  if old_edge != new_edge
                    edge_out[[id, succ]] = new_edge
                    changed = true
                  end
                end
                new_out = node.succs.empty? ? initial.call : join.call(node.succs.map { |s| edge_out[[id, s]] || initial.call })
              else
                new_out = boundary_out.fetch(id) { transfer.call(node, incoming) }
              end

              if in_states[id] != incoming || out_states[id] != new_out
                in_states[id]  = incoming
                out_states[id] = new_out
                changed = true
              end
            else
              outgoing = boundary_out.fetch(id) { join.call(node.succs.map { |succ| in_states[succ] }) }
              incoming = boundary_in.fetch(id)  { transfer.call(node, outgoing) }
              if in_states[id] != incoming || out_states[id] != outgoing
                in_states[id]  = incoming
                out_states[id] = outgoing
                changed = true
              end
            end
          end
        end

        Result.new(in_states:, out_states:)
      end
    end

    class Liveness
      Result = Data.define(:live_in, :live_out)

      def self.solve(graph)
        result = Dataflow.solve(
          graph,
          direction: :backward,
          initial: -> { Set.new },
          join: lambda do |states|
            states.reduce(Set.new) { |acc, state| acc | state }
          end,
          transfer: lambda do |node, live_out|
            node.reads | (live_out - node.writes)
          end,
        )
        Result.new(live_in: result.in_states, live_out: result.out_states)
      end
    end

    class DefiniteAssignment
      ReadBeforeAssignment = Data.define(:node_id, :binding_key, :line)
      Result = Data.define(:definitely_assigned_in, :definitely_assigned_out, :read_before_assignment)

      def self.solve(graph, initially_assigned: Set.new)
        initially_assigned = initially_assigned.dup
        universe = initial_universe(graph, initially_assigned)

        result = Dataflow.solve(
          graph,
          direction: :forward,
          initial: -> { universe.dup },
          join: lambda do |states|
            if states.empty?
              universe.dup
            else
              states.reduce(universe.dup) { |acc, state| acc & state }
            end
          end,
          transfer: lambda do |node, in_state|
            in_state | node.writes
          end,
          boundary_in: { graph.entry_id => initially_assigned.dup }
        )

        read_before_assignment = []
        graph.each_node do |node|
          in_state = result.in_states[node.id]
          node.reads.each do |binding_key|
            next if in_state.include?(binding_key)

            read_before_assignment << ReadBeforeAssignment.new(
              node_id: node.id,
              binding_key:,
              line: node.line,
            )
          end
        end

        Result.new(
          definitely_assigned_in: result.in_states,
          definitely_assigned_out: result.out_states,
          read_before_assignment:
        )
      end

      def self.initial_universe(graph, initially_assigned)
        universe = initially_assigned.dup
        graph.each_node do |node|
          universe.merge(node.writes)
          universe.merge(node.reads)
        end
        universe
      end
      private_class_method :initial_universe
    end

    # ── Reachability ─────────────────────────────────────────────────────────
    # Forward DFS from entry; returns the set of node IDs reachable from entry.
    class Reachability
      Result = Data.define(:reachable_ids)

      def self.solve(graph)
        reachable = Set.new
        queue = [graph.entry_id]
        until queue.empty?
          id = queue.shift
          next if reachable.include?(id)

          reachable << id
          (graph.nodes[id]&.succs || []).each { |succ| queue << succ }
        end
        Result.new(reachable_ids: reachable)
      end
    end

    class Builder
      # Build a CFG for `stmts` as if they are a loop body: break targets a
      # dedicated non-exit node, so the main exit represents only the fall-through
      # back-edge.  Used by Termination.loop_body_always_exits?.
      def build_loop_body(stmts)
        @graph = Graph.new
        @graph.exit_id  = @graph.add_node(kind: :exit)         # fall-through (back-edge)
        break_exit_id   = @graph.add_node(kind: :break_exit)   # break target
        @graph.entry_id = build_block(stmts || [], @graph.exit_id, break_target: break_exit_id, continue_target: @graph.exit_id)
        @graph
      ensure
        @graph = nil
      end
    end

    class Termination
      # Returns true when every path from block entry terminates before the
      # continuation (i.e., the synthetic CFG exit is unreachable).
      def self.block_always_terminates?(statements, **builder_options)
        return false if statements.nil? || statements.empty?

        graph = Builder.new(**builder_options).build(statements)
        reachability = Reachability.solve(graph)
        !reachability.reachable_ids.include?(graph.exit_id)
      end

      # Returns true when every path through `statements` (treated as a loop body)
      # exits via return or break — never falling through to the back-edge.
      def self.loop_body_always_exits?(statements, **builder_options)
        return false if statements.nil? || statements.empty?

        graph = Builder.new(**builder_options).build_loop_body(statements)
        reachability = Reachability.solve(graph)
        !reachability.reachable_ids.include?(graph.exit_id)
      end
    end

    # ── NullabilityFlow ──────────────────────────────────────────────────────
    # Forward must-analysis that tracks which binding keys are *definitely
    # non-null* at each program point.
    #
    # State: Set[binding_key] = bindings proven non-null on every incoming path.
    # - Edge refinements (from Builder) inject non-null facts on conditional edges.
    # - Any write to a binding conservatively clears its non-null status.
    # - Join: intersection (must-analysis).
    #
    # Result exposes `nonnull_before(stmt)` for sema integration.
    class NullabilityFlow
      Result = Data.define(:in_states, :out_states, :stmt_to_node_id) do
        # Returns the Set of binding keys definitely non-null just before `stmt`
        # is executed (i.e., at the CFG node's in_state).
        def nonnull_before(stmt)
          node_id = stmt_to_node_id[stmt.object_id]
          return Set.new unless node_id

          in_states[node_id] || Set.new
        end
      end

      def self.solve(graph)
        stmt_to_node_id = {}
        graph.each_node { |n| stmt_to_node_id[n.statement.object_id] = n.id if n.statement }

        result = Dataflow.solve(
          graph,
          direction: :forward,
          initial: -> { Set.new },
          join: lambda do |states|
            return Set.new if states.empty?

            states.reduce { |acc, s| acc & s }
          end,
          edge_transfer: lambda do |node, in_state, succ_id, _edge_label|
            state = in_state - node.writes   # writes conservatively clear non-null
            refs  = graph.edge_refinement(node.id, succ_id) || {}
            refs.each do |key, ref|
              ref == :non_null ? (state = state | Set[key]) : (state = state - Set[key])
            end
            state
          end,
          boundary_in: { graph.entry_id => Set.new }
        )

        Result.new(in_states: result.in_states, out_states: result.out_states, stmt_to_node_id:)
      end
    end

    # ── ConstantPropagation ──────────────────────────────────────────────────
    # Sparse forward lattice analysis.
    #
    # Lattice per binding key:
    #   :undef           – not yet assigned on any path (bottom)
    #   ConstVal(value)  – assigned a known constant on all paths
    #   :nac             – not a constant (top / conflict)
    #
    # Join:  undef ⊔ x = x;  ConstVal(v) ⊔ ConstVal(v) = ConstVal(v);
    #        ConstVal(v) ⊔ ConstVal(w) = :nac (v≠w);  x ⊔ :nac = :nac.
    #
    # The result state is Hash[binding_key => :undef | :nac | ConstVal].
    class ConstantPropagation
      ConstVal = Data.define(:value)

      UNDEF = :undef
      NAC   = :nac

      Result = Data.define(:in_states, :out_states) do
        # Convenience: returns the constant value for `key` at `node_id`, or nil.
        def constant_at(node_id, key)
          entry = in_states[node_id]
          return nil unless entry

          v = entry[key]
          v.is_a?(ConstVal) ? v.value : nil
        end
      end

      def self.solve(graph, binding_resolution: nil, strict_binding_ids: false)
        result = Dataflow.solve(
          graph,
          direction: :forward,
          initial: -> { {} },
          join: lambda do |states|
            return {} if states.empty?

            states.reduce do |acc, state|
              keys = acc.keys | state.keys
              keys.each_with_object({}) do |k, merged|
                a = acc[k]   || UNDEF
                b = state[k] || UNDEF
                merged[k] = join_lattice(a, b)
              end
            end
          end,
          transfer: lambda do |node, in_state|
            out = in_state.dup
            node.writes_info.each do |write|
              key = write[:binding_key]
              val = eval_const(node.statement, write, in_state, binding_resolution:, strict_binding_ids:)
              out[key] = val
            end
            out
          end,
          boundary_in: { graph.entry_id => {} }
        )

        Result.new(in_states: result.in_states, out_states: result.out_states)
      end

      def self.join_lattice(a, b)
        return b if a == UNDEF
        return a if b == UNDEF
        return NAC if a == NAC || b == NAC

        a == b ? a : NAC
      end
      private_class_method :join_lattice

      # Attempt to evaluate the assigned value as a compile-time constant.
      # Handles LocalDecl and Assignment with simple RHS literals/arithmetic.
      def self.eval_const(statement, _write, in_state, binding_resolution:, strict_binding_ids:)
        rhs =
          case statement
          when AST::LocalDecl  then statement.value
          when AST::Assignment then statement.value
          end
        eval_expr_const(rhs, in_state, binding_resolution:, strict_binding_ids:)
      end
      private_class_method :eval_const

      def self.eval_expr_const(expr, state, binding_resolution:, strict_binding_ids:)
        case expr
        when nil                 then NAC
        when AST::IntegerLiteral then ConstVal.new(expr.value.to_i)
        when AST::FloatLiteral   then ConstVal.new(expr.value.to_f)
        when AST::BooleanLiteral then ConstVal.new(expr.value)
        when AST::Identifier
          key = identifier_key(expr, binding_resolution:, strict_binding_ids:)
          return NAC unless key

          v = state[key]
          v.is_a?(ConstVal) ? v : NAC
        when AST::UnaryOp
          operand = eval_expr_const(expr.operand, state, binding_resolution:, strict_binding_ids:)
          return NAC unless operand.is_a?(ConstVal)

          case expr.operator
          when "-" then ConstVal.new(-operand.value)
          when "not" then ConstVal.new(!operand.value)
          else NAC
          end
        when AST::BinaryOp
          left  = eval_expr_const(expr.left,  state, binding_resolution:, strict_binding_ids:)
          right = eval_expr_const(expr.right, state, binding_resolution:, strict_binding_ids:)
          return NAC unless left.is_a?(ConstVal) && right.is_a?(ConstVal)

          begin
            v = case expr.operator
                when "+"   then left.value + right.value
                when "-"   then left.value - right.value
                when "*"   then left.value * right.value
                when "/"   then right.value.zero? ? (return NAC) : left.value / right.value
                when "%"   then right.value.zero? ? (return NAC) : left.value % right.value
                when "=="  then left.value == right.value
                when "!="  then left.value != right.value
                when "<"   then left.value < right.value
                when "<="  then left.value <= right.value
                when ">"   then left.value > right.value
                when ">="  then left.value >= right.value
                when "and" then left.value && right.value
                when "or"  then left.value || right.value
                else return NAC
                end
            ConstVal.new(v)
          rescue StandardError
            NAC
          end
        else
          NAC
        end
      end
      private_class_method :eval_expr_const

      # Public API: evaluate `expr` against `in_state` and return the constant
      # Ruby value, or nil if the expression is not a compile-time constant.
      def self.constant_value_of(expr, in_state, binding_resolution: nil, strict_binding_ids: false)
        result = send(:eval_expr_const, expr, in_state, binding_resolution:, strict_binding_ids:)
        result.is_a?(ConstVal) ? result.value : nil
      end

      def self.identifier_key(identifier_expression, binding_resolution:, strict_binding_ids:)
        if binding_resolution && (id = binding_resolution.identifier_binding_ids[identifier_expression.object_id])
          return id
        end

        return nil if strict_binding_ids

        identifier_expression.name
      end
      private_class_method :identifier_key
    end
  end
end

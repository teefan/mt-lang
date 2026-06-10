# frozen_string_literal: true

module MilkTea
  class Linter
    module LinterFlowRules
      private

      def emit_dead_assignment_warnings(stmts)
        analysis = dead_assignment_analysis(stmts)
        return unless analysis
  
        graph = analysis.graph
        liveness = analysis.liveness
        readable_bindings = analysis.readable_bindings
        locally_declared = analysis.locally_declared
  
        graph.each_node do |node|
          node.writes_info.each do |write|
            next if write[:origin] == :call_argument
              next if write[:origin] == :declaration
  
            binding_key = write[:binding_key]
            name = write[:name]
            next unless readable_bindings.include?(binding_key)
            next unless locally_declared.include?(binding_key)
            next if liveness.live_out[node.id].include?(binding_key)
  
            @warnings << Warning.new(
              path: @path,
              line: write[:line],
              column: write[:column],
              length: name.length,
              code: "dead-assignment",
              message: "value assigned to '#{name}' is never read",
              symbol_name: name
            )
          end
        end
      end
      def emit_unreachable_warnings(stmts)
        analysis = statement_flow_analysis(stmts)
        return unless analysis
  
        graph = analysis.graph
        reachable = analysis.reachability
  
        graph.each_node do |node|
          next if reachable.reachable_ids.include?(node.id)
          next if node.kind == :exit
          next unless node.statement
  
          statement = node.statement
          line = statement.respond_to?(:line) ? statement.line : nil
          @warnings << Warning.new(
            path: @path,
            line:,
            column: statement_column(statement),
            length: statement_length(statement),
            code: "unreachable-code",
            message: "unreachable code"
          )
        end
      end
      # Detects obvious aliasing hazards: a mutable reference (ref_of / ptr_of)
      # is taken from a local variable that is also written later in the same body.
      def emit_borrow_warnings(stmts)
        return if stmts.nil? || stmts.empty?
  
        borrowed = collect_borrowed_names(stmts)
        return if borrowed.empty?
  
        written = collect_written_names(stmts)
        (borrowed & written).each do |name|
          # Find the earliest borrow site for the warning location
          borrow_line, borrow_column, borrow_length = find_borrow_location(stmts, name)
          @warnings << Warning.new(
            path: @path,
            line: borrow_line,
            column: borrow_column,
            length: borrow_length,
            code: "borrow-and-mutate",
            message: "'#{name}' is borrowed via ref_of/ptr_of and also mutated in the same scope — potential aliasing hazard",
            severity: :warning,
            symbol_name: name,
          )
        end
      end
      def cfg_binding_resolution
        return @cfg_binding_resolution if @cfg_binding_resolution_computed
  
        binding_resolution = @sema_facts&.binding_resolution
        @cfg_binding_resolution = if binding_resolution
                                    CFG::BindingResolution.new(
                                      identifier_binding_ids: binding_resolution.identifier_binding_ids,
                                      declaration_binding_ids: binding_resolution.declaration_binding_ids,
                                      mutating_argument_identifier_ids: binding_resolution.mutating_argument_identifier_ids,
                                    )
                                  end
        @cfg_binding_resolution_computed = true
        @cfg_binding_resolution
      end
      def statement_flow_analysis(stmts)
        return nil if stmts.nil? || stmts.empty?
  
        @statement_flow_analysis_cache[stmts.object_id] ||= begin
          binding_resolution = cfg_binding_resolution
          graph = profile_phase("flow.graph") do
            CFG::Builder.new(ignore_name: method(:ignored_binding_name?), binding_resolution:).build(stmts)
          end
          reachability = profile_phase("flow.reachability") { CFG::Reachability.solve(graph) }
          nullability = profile_phase("flow.nullability") { CFG::NullabilityFlow.solve(graph) }
          constant_propagation = profile_phase("flow.constant_propagation") do
            CFG::ConstantPropagation.solve(graph, binding_resolution:, strict_binding_ids: !binding_resolution.nil?)
          end
          loop_body_nodes = profile_phase("flow.loop_body_nodes") { compute_loop_body_nodes(graph) }
          StatementFlowAnalysis.new(graph:, reachability:, nullability:, constant_propagation:, loop_body_nodes:)
        end
      end
      def dead_assignment_analysis(stmts)
        return nil if stmts.nil? || stmts.empty?
  
        @dead_assignment_analysis_cache[stmts.object_id] ||= begin
          binding_resolution = cfg_binding_resolution
          graph = profile_phase("dead_assignment.graph") do
            CFG::Builder.new(
              ignore_name: method(:ignored_binding_name?),
              binding_resolution:,
              local_decl_without_initializer_writes: true,
            ).build(stmts)
          end
          liveness = profile_phase("dead_assignment.liveness") { CFG::Liveness.solve(graph) }
          locally_declared = profile_phase("dead_assignment.locals") do
            graph.each_node.each_with_object(Set.new) do |node, bindings|
              node.writes_info.each do |write|
                bindings << write[:binding_key] if write[:origin] == :declaration
              end
            end
          end
          DeadAssignmentAnalysis.new(
            graph:,
            liveness:,
            readable_bindings: graph.read_bindings,
            locally_declared:,
          )
        end
      end
      def cfg_identifier_binding_key(identifier)
        binding_resolution = cfg_binding_resolution
        return identifier.name unless binding_resolution
  
        binding_resolution.identifier_binding_ids[identifier.object_id] || identifier.name
      end
      def ignored_binding_name?(name)
        name == "_" || name.start_with?("_")
      end
      # ── constant-condition ─────────────────────────────────────────────────
      # Uses ConstantPropagation to detect conditions that are always true/false.
      # Skips `while true` — it is an idiomatic infinite loop.
      # Skips if conditions inside loops, since variables can change across iterations.
  
      def emit_constant_condition_warnings(stmts)
        return if stmts.nil? || stmts.empty?
  
        analysis = statement_flow_analysis(stmts)
        return unless analysis
  
        binding_resolution = cfg_binding_resolution
        graph = analysis.graph
        cp = analysis.constant_propagation
        loop_bodies = analysis.loop_body_nodes
  
        graph.each_node do |node|
          cond_expr, line, keyword_pattern, skip_node =
            case node.kind
            when :if_condition
              branch = node.statement
              # Skip if conditions inside loops; variables can change across iterations.
              skip = loop_bodies.include?(node.id)
              [branch&.condition, branch&.line || node.line, "else if|if", skip]
            when :while_condition
              wstmt = node.statement
              # `while true` is an idiomatic infinite loop — do not warn
              skip = wstmt&.condition.is_a?(AST::BooleanLiteral) && wstmt.condition.value == true
              condition = wstmt&.condition
              [condition, node.line, "while", skip]
            else
              next
            end
  
          next if skip_node || cond_expr.nil?
  
          in_state  = cp.in_states[node.id] || {}
          const_val = CFG::ConstantPropagation.constant_value_of(
            cond_expr,
            in_state,
            binding_resolution:,
            strict_binding_ids: !binding_resolution.nil?
          )
          next unless const_val == true || const_val == false
  
          ctx = node.kind == :while_condition ? "loop condition" : "branch condition"
          line, column, length = condition_span(cond_expr, line:, keyword_pattern:)
          @warnings << Warning.new(
            path: @path,
            line:,
            column:,
            length:,
            code: "constant-condition",
            message: "#{ctx} is always #{const_val}",
            severity: :warning,
            symbol_name: condition_symbol_name(cond_expr)
          )
        end
      end
      # Returns the set of node IDs that are inside loops (reachable from a back-edge).
      # A back-edge exists when a node is reachable from its own successors.
      private def compute_loop_body_nodes(graph)
        loop_nodes = Set.new
  
        # Find all back-edges: detect cycles by checking if any successor of a node
        # can reach back to that node.
        graph.each_node do |node|
          node.succs.each do |succ_id|
            # Check if succ can reach back to node (indicating a loop/cycle).
            if reachable_from?(graph, succ_id, node.id)
              # Mark all nodes reachable from succ (the loop body) as inside a loop.
              mark_reachable_nodes(graph, succ_id, loop_nodes)
            end
          end
        end
  
        loop_nodes
      end
  
      # Returns true if target_id is reachable from start_id via forward edges.
      private def reachable_from?(graph, start_id, target_id)
        visited = Set.new
        queue = [start_id]
  
        while queue.any?
          node_id = queue.shift
          return true if node_id == target_id
          next if visited.include?(node_id)
  
          visited.add(node_id)
          node = graph.nodes[node_id]
          node.succs.each { |succ| queue.push(succ) }
        end
  
        false
      end
  
      # Mark all nodes reachable from start_id as being inside a loop.
      private def mark_reachable_nodes(graph, start_id, loop_nodes)
        visited = Set.new
        queue = [start_id]
  
        while queue.any?
          node_id = queue.shift
          loop_nodes.add(node_id)
          next if visited.include?(node_id)
  
          visited.add(node_id)
          node = graph.nodes[node_id]
          node.succs.each { |succ| queue.push(succ) unless visited.include?(succ) }
        end
      end
      # ── redundant-null-check ───────────────────────────────────────────────
      # After a variable has been narrowed to non-null by a prior check,
      # a subsequent `x != nil` guard is always true.
  
      def emit_redundant_null_check_warnings(stmts)
        return if stmts.nil? || stmts.empty?
  
        analysis = statement_flow_analysis(stmts)
        return unless analysis
  
        graph = analysis.graph
        nf = analysis.nullability
  
        graph.each_node do |node|
          next unless node.kind == :if_condition
  
          branch = node.statement
          next unless branch.is_a?(AST::IfBranch)
  
          identifier = null_check_identifier(branch.condition)
          next unless identifier
          next if ignored_binding_name?(identifier.name)
  
          nonnull = nf.nonnull_before(branch)
          next unless nonnull.include?(cfg_identifier_binding_key(identifier))
  
          line, column, length = condition_span(branch.condition, line: node.line, keyword_pattern: "else if|if")
  
          @warnings << Warning.new(
            path: @path,
            line:,
            column:,
            length:,
            code: "redundant-null-check",
            message: "'#{identifier.name}' is already known to be non-null here — this nil check is redundant",
            severity: :hint,
            symbol_name: identifier.name
          )
        end
      end
  
      # Returns the Identifier being nil-tested if `cond` is `x != nil` or
      # `nil != x`, otherwise nil.
      def null_check_identifier(cond)
        return nil unless cond.is_a?(AST::BinaryOp) && cond.operator == "!="
  
        if cond.left.is_a?(AST::Identifier) && cond.right.is_a?(AST::NullLiteral)
          cond.left
        elsif cond.left.is_a?(AST::NullLiteral) && cond.right.is_a?(AST::Identifier)
          cond.right
        end
      end
      # ── loop-single-iteration ──────────────────────────────────────────────
      # A loop whose body unconditionally exits (return/break) before the
      # back-edge is taken will execute at most once.
  
      def emit_loop_single_iteration_warnings(stmts)
        return if stmts.nil? || stmts.empty?
  
        walk_stmts_for_loop_check(stmts)
      end
  
      def walk_stmts_for_loop_check(stmts)
        stmts.each do |stmt|
          case stmt
          when AST::WhileStmt
            body = stmt.body || []
            if !body.empty? && CFG::Termination.loop_body_always_exits?(body)
              @warnings << Warning.new(
                path: @path,
                line: stmt.line,
                column: stmt.column,
                length: stmt.length || "while".length,
                code: "loop-single-iteration",
                message: "loop body always exits on the first iteration - consider replacing with an 'if' block",
                severity: :warning
              )
            end
            walk_stmts_for_loop_check(body)
          when AST::ForStmt
            body = stmt.body || []
            if !body.empty? && CFG::Termination.loop_body_always_exits?(body)
              @warnings << Warning.new(
                path: @path,
                line: stmt.line,
                column: stmt.column,
                length: (stmt.respond_to?(:length) ? stmt.length : nil) || "for".length,
                code: "loop-single-iteration",
                message: "loop body always exits on the first iteration - consider iterating directly without a loop",
                severity: :warning
              )
            end
            walk_stmts_for_loop_check(body)
          when AST::IfStmt
            stmt.branches.each { |b| walk_stmts_for_loop_check(b.body) }
            walk_stmts_for_loop_check(stmt.else_body) if stmt.else_body
          when AST::MatchStmt
            stmt.arms.each { |arm| walk_stmts_for_loop_check(arm.body) }
          when AST::UnsafeStmt
            walk_stmts_for_loop_check(stmt.body) if stmt.body
          when AST::DeferStmt
            walk_stmts_for_loop_check(stmt.body) if stmt.body
          end
        end
      end
    end
  end
end

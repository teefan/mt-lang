# frozen_string_literal: true

module MilkTea
  class Linter
    module LinterReleaseRules
      private

      # Entry point — called from visit_function and proc expr in full_tier mode.
      def emit_owning_release_warnings(function_or_body)
        body = function_or_body.is_a?(Array) ? function_or_body : function_or_body.body
        return unless body && !body.empty?

        cfg_available = false
        if @sema_facts
          cfg_available = begin
            analysis = profile_phase("rule.owning_release.cfg") { statement_flow_analysis(body) }
            analysis || false
          rescue StandardError
            false
          end
        end

        if cfg_available
          emit_owning_release_cfg_warnings(cfg_available, body)
        else
          # No CFG — emit struct-type leaks via simple pattern-matching
          leak_names = check_owning_release_leaks(body)
          emit_owning_release_leak_warnings(leak_names)
        end
        # Always run own[T] checks (AST-based, works with or without CFG)
        own_leaks = check_own_release_leaks(body)
        emit_owning_release_leak_warnings(own_leaks)

        double_names_lines = check_owning_release_double(body)
        emit_owning_release_double_warnings(double_names_lines)
      end

      # ── Simple leak detection ──────────────────────────────────────────

      def check_owning_release_leaks(stmts)
        locals = owning_local_bindings(stmts)
        released = all_released_names(stmts)
        locals.reject { |name, _info| released.include?(name) || ownership_transferred?(stmts, name) }
      end

      # Check only own[T] typed leaks (separate from struct-type leaks)
      def check_own_release_leaks(stmts)
        own_locals = own_typed_local_bindings(stmts)
        own_released = all_own_released_names(stmts)
        own_locals.reject { |name, _info| own_released.include?(name) || own_transferred?(stmts, name) }
      end

      def emit_owning_release_leak_warnings(leak_names)
        leak_names.each do |name, info|
          @warnings << Warning.new(
            path: @path,
            line: info[:line],
            column: info[:column],
            length: name.length,
            code: "owning-release-leak",
            message: "owning binding '#{name}' of type '#{info[:type_name]}' is never released",
            severity: :warning,
            symbol_name: name,
          )
        end
      end

      # ── own[T] typed local detection ──────────────────────────────────

      def own_typed_local_bindings(stmts)
        result = {}
        _collect_own_typed_locals(stmts, result)
        result
      end

      def _collect_own_typed_locals(stmts, result)
        return if stmts.nil?

        stmts.each do |stmt|
          case stmt
          when AST::LocalDecl
            type_name = resolve_local_own_pointer_type(stmt)
            if type_name
              result[stmt.name] = {
                line: stmt.line,
                column: stmt.respond_to?(:column) ? stmt.column : nil,
                type_name: type_name,
              }
            end
          when AST::IfStmt
            stmt.branches.each { |b| _collect_own_typed_locals(b.body, result) }
            _collect_own_typed_locals(stmt.else_body, result) if stmt.else_body
          when AST::WhileStmt
            _collect_own_typed_locals(stmt.body, result)
          when AST::ForStmt
            _collect_own_typed_locals(stmt.body, result)
          when AST::MatchStmt
            stmt.arms.each { |arm| _collect_own_typed_locals(arm.body, result) }
          when AST::UnsafeStmt
            _collect_own_typed_locals(stmt.body, result)
          when AST::DeferStmt
            _collect_own_typed_locals(stmt.body, result) if stmt.body.is_a?(Array)
          end
        end
      end

      def resolve_local_own_pointer_type(decl)
        if is_heap_alloc_call?(decl.value)
          return "own[<inferred>]"
        end
        type = resolve_expr_type(decl.value) if decl.value
        return nil unless type
        return nil unless type.is_a?(MilkTea::Types::GenericInstance)
        return nil unless type.name == "own"
        type.to_s
      rescue StandardError
        nil
      end

      def is_heap_alloc_call?(expr)
        return false unless expr.is_a?(AST::Call)
        callee = expr.callee
        non_null_method_names = %w[must_alloc must_alloc_aligned
                                   must_alloc_zeroed must_resize].to_set
        case callee
        when AST::MemberAccess
          callee.receiver.is_a?(AST::Identifier) &&
            non_null_method_names.include?(callee.member)
        when AST::Specialization
          inner = callee.callee
          inner.is_a?(AST::MemberAccess) &&
            inner.receiver.is_a?(AST::Identifier) &&
            non_null_method_names.include?(inner.member)
        else
          false
        end
      end

      # ── own[T] release detection ──────────────────────────────────────

      def all_own_released_names(stmts)
        result = Set.new
        _collect_own_released_names(stmts, result)
        result
      end

      def _collect_own_released_names(stmts, result)
        return if stmts.nil?
        stmts.each { |s| _collect_own_released_names_in_stmt(s, result) }
      end

      def _collect_own_released_names_in_stmt(stmt, result)
        case stmt
        when AST::ExpressionStmt
          _collect_heap_release_names(stmt.expression, result)
        when AST::ReturnStmt
          _collect_heap_release_names(stmt.value, result) if stmt.value
        when AST::LocalDecl
          _collect_heap_release_names(stmt.value, result) if stmt.value
        when AST::Assignment
          _collect_heap_release_names(stmt.value, result)
        when AST::IfStmt
          stmt.branches.each { |b| _collect_own_released_names(b.body, result) }
          _collect_own_released_names(stmt.else_body, result) if stmt.else_body
        when AST::WhileStmt
          _collect_own_released_names(stmt.body, result)
        when AST::ForStmt
          _collect_own_released_names(stmt.body, result)
        when AST::MatchStmt
          stmt.arms.each { |arm| _collect_own_released_names(arm.body, result) }
        when AST::UnsafeStmt
          _collect_own_released_names(stmt.body, result)
        when AST::DeferStmt
          if stmt.expression
            _collect_heap_release_names(stmt.expression, result)
          end
          _collect_own_released_names(stmt.body, result) if stmt.body.is_a?(Array)
        end
      end

      def _collect_heap_release_names(expr, result)
        return if expr.nil?
        if heap_release_call_on_name?(expr)
          result << heap_release_target_name(expr)
        end
        case expr
        when AST::Call
          expr.arguments.each { |a| _collect_heap_release_names(a.value, result) }
          _collect_heap_release_names(expr.callee, result) if expr.callee.is_a?(AST::Call)
        when AST::BinaryOp
          _collect_heap_release_names(expr.left, result)
          _collect_heap_release_names(expr.right, result)
        when AST::UnaryOp
          _collect_heap_release_names(expr.operand, result)
        end
      end

      def heap_release_call_on_name?(expr)
        return false unless expr.is_a?(AST::Call)
        return false unless expr.callee.is_a?(AST::MemberAccess)
        return false unless %w[release release_and_null].include?(expr.callee.member)
        return false unless expr.arguments.length >= 1
        arg = expr.arguments.first
        return false unless arg.is_a?(AST::Argument)
        target_name = heap_release_target_name(expr)
        target_name && !target_name.empty?
      end

      def heap_release_target_name(expr)
        return nil unless expr.is_a?(AST::Call)
        return nil unless expr.arguments.length >= 1
        # For multi-arg release (e.g. tracking.release(tracker, p)), find
        # the argument that names the released value by preferring the last
        # direct-identifier argument.
        released = nil
        expr.arguments.each do |arg|
          next unless arg.is_a?(AST::Argument)
          value = arg.value
          value = value.expression if value.is_a?(AST::UnsafeStmt)
          if value.is_a?(AST::Identifier)
            released = value.name
          elsif value.is_a?(AST::Call) && value.callee.is_a?(AST::Identifier) && value.callee.name == "ref_of"
            ref_arg = value.arguments.first
            if ref_arg.is_a?(AST::Argument) && ref_arg.value.is_a?(AST::Identifier)
              released = ref_arg.value.name
            end
          end
        end
        released
      end

      # ── own[T] ownership transfer ─────────────────────────────────────

      def own_transferred?(stmts, name)
        _any_stmt?(stmts) do |stmt|
          if stmt.is_a?(AST::ReturnStmt) && stmt.value.is_a?(AST::Identifier) && stmt.value.name == name
            true
          elsif (expr = extract_expr(stmt)) && own_struct_field_transfer?(expr, name)
            true
          else
            false
          end
        end
      end

      def own_struct_field_transfer?(expr, name)
        return false unless expr.is_a?(AST::Call)
        expr.arguments.any? do |arg|
          arg.is_a?(AST::Argument) && arg.value.is_a?(AST::Identifier) && arg.value.name == name
        end
      end

      def owning_local_bindings(stmts)
        result = {}
        _collect_owning_locals(stmts, result)
        result
      end

      def _collect_owning_locals(stmts, result)
        return if stmts.nil?

        stmts.each do |stmt|
          case stmt
          when AST::LocalDecl
            type_name = resolve_local_owning_type(stmt)
            if type_name
              result[stmt.name] = {
                line: stmt.line,
                column: stmt.respond_to?(:column) ? stmt.column : nil,
                type_name: type_name,
              }
            end
          when AST::IfStmt
            stmt.branches.each { |b| _collect_owning_locals(b.body, result) }
            _collect_owning_locals(stmt.else_body, result) if stmt.else_body
          when AST::WhileStmt
            _collect_owning_locals(stmt.body, result)
          when AST::ForStmt
            _collect_owning_locals(stmt.body, result)
          when AST::MatchStmt
            stmt.arms.each { |arm| _collect_owning_locals(arm.body, result) }
          when AST::UnsafeStmt
            _collect_owning_locals(stmt.body, result)
          when AST::DeferStmt
            _collect_owning_locals(stmt.body, result) if stmt.body.is_a?(Array)
          end
        end
      end

      # ── Simple sequential double-release ─────────────────────────────

      def check_owning_release_double(stmts)
        result = {}
        _check_double_release_in_seq(stmts, result)
        result
      end

      def emit_owning_release_double_warnings(double_names_lines)
        double_names_lines.each do |name, lines|
          @warnings << Warning.new(
            path: @path,
            line: lines.last,
            column: nil,
            length: nil,
            code: "owning-release-double",
            message: "owning binding '#{name}' may be released more than once",
            severity: :warning,
            symbol_name: name,
          )
        end
      end

      def _check_double_release_in_seq(stmts, result)
        return if stmts.nil?

        scope_releases = Hash.new { |hash, key| hash[key] = [] }

        stmts.each do |stmt|
          expr = extract_expr(stmt)
          if expr && release_call_on_binding?(expr)
            name = expr.callee.receiver.name
            scope_releases[name] << extract_line(stmt)
          elsif expr && heap_release_call_on_name?(expr)
            name = heap_release_target_name(expr)
            scope_releases[name] << extract_line(stmt) if name
          end

          scope_releases.delete(stmt.target.name) if reassigns_owning_binding?(stmt)

          case stmt
          when AST::UnsafeStmt
            _check_double_release_in_seq(stmt.body, result)
          when AST::DeferStmt
            _check_double_release_in_seq(stmt.body, result) if stmt.body.is_a?(Array)
          end
        end

        scope_releases.each do |name, lines|
          result[name] = lines if lines.length > 1
        end
      end

      # ── Type resolution ────────────────────────────────────────────────

      def resolve_local_owning_type(decl)
        if decl.type && decl.type.is_a?(AST::TypeRef)
          base = owning_base_name(decl.type.name.to_s)
          return base if owning_type_by_name?(base)
        end
        if decl.value
          type_name = extract_initializer_type(decl.value)
          return type_name if type_name && owning_type_by_name?(type_name)
        end
        nil
      end

      def extract_initializer_type(expr)
        return nil unless expr.is_a?(AST::Call)
        return nil unless expr.arguments.empty?

        callee = expr.callee
        method_name = case callee
                      when AST::MemberAccess then callee.member
                      when AST::Specialization
                        inner = callee.callee
                        inner.is_a?(AST::MemberAccess) ? inner.member : nil
                      else nil
                      end
        return nil unless %w[create with_capacity empty from_str].include?(method_name)

        receiver = case callee
                   when AST::MemberAccess then callee.receiver
                   when AST::Specialization then callee
                   else nil
                   end

        owning_type_from_receiver(receiver)
      end

      def owning_type_from_receiver(receiver)
        case receiver
        when AST::Identifier then owning_base_name(receiver.name)
        when AST::MemberAccess then owning_base_name(receiver.member)
        when AST::Specialization then owning_type_from_receiver(receiver.callee)
        else nil
        end
      end

      # ── Ownership transfer detection ──────────────────────────────────

      def ownership_transferred?(stmts, name)
        returned_name?(stmts, name) || struct_field_transfer?(stmts, name)
      end

      def returned_name?(stmts, name)
        _any_stmt?(stmts) do |stmt|
          stmt.is_a?(AST::ReturnStmt) &&
            stmt.value.is_a?(AST::Identifier) &&
            stmt.value.name == name
        end
      end

      def struct_field_transfer?(stmts, name)
        _any_stmt_or_expr?(stmts) { |expr| _expr_contains_transfer?(expr, name) }
      end

      def _expr_contains_transfer?(expr, name)
        return false unless expr.is_a?(AST::Call)

        expr.arguments.any? do |arg|
          next false unless arg.is_a?(AST::Argument) && arg.name

          if arg.value.is_a?(AST::Identifier) && arg.value.name == name
            true
          elsif arg.value.is_a?(AST::Call)
            _expr_contains_transfer?(arg.value, name)
          else
            false
          end
        end
      end

      # ── Shared AST walkers ────────────────────────────────────────────

      def all_released_names(stmts)
        result = Set.new
        _collect_released_names(stmts, result)
        result
      end

      def _collect_released_names(stmts, result)
        return if stmts.nil?
        stmts.each { |s| _collect_released_names_in_stmt(s, result) }
      end

      def _collect_released_names_in_stmt(stmt, result)
        case stmt
        when AST::ExpressionStmt
          _collect_released_names_in_expr(stmt.expression, result)
        when AST::ReturnStmt
          _collect_released_names_in_expr(stmt.value, result) if stmt.value
        when AST::LocalDecl
          _collect_released_names_in_expr(stmt.value, result) if stmt.value
        when AST::Assignment
          _collect_released_names_in_expr(stmt.value, result)
        when AST::IfStmt
          stmt.branches.each { |b| _collect_released_names(b.body, result) }
          _collect_released_names(stmt.else_body, result) if stmt.else_body
        when AST::WhileStmt
          _collect_released_names(stmt.body, result)
        when AST::ForStmt
          _collect_released_names(stmt.body, result)
        when AST::MatchStmt
          stmt.arms.each { |arm| _collect_released_names(arm.body, result) }
        when AST::UnsafeStmt
          _collect_released_names(stmt.body, result)
        when AST::DeferStmt
          _collect_released_names_in_expr(stmt.expression, result) if stmt.expression
          _collect_released_names(stmt.body, result) if stmt.body.is_a?(Array)
        end
      end

      def _collect_released_names_in_expr(expr, result)
        return if expr.nil?

        result << expr.callee.receiver.name if release_call_on_binding?(expr)

        case expr
        when AST::Call
          expr.arguments.each { |a| _collect_released_names_in_expr(a.value, result) }
          _collect_released_names_in_expr(expr.callee, result)
        when AST::MemberAccess
          _collect_released_names_in_expr(expr.receiver, result)
        when AST::BinaryOp
          _collect_released_names_in_expr(expr.left, result)
          _collect_released_names_in_expr(expr.right, result)
        when AST::UnaryOp
          _collect_released_names_in_expr(expr.operand, result)
        end
      end

      def _any_stmt?(stmts, &pred)
        return false if stmts.nil?

        stmts.any? do |stmt|
          if pred.call(stmt)
            true
          else
            case stmt
            when AST::IfStmt
              stmt.branches.any? { |b| _any_stmt?(b.body, &pred) } ||
                _any_stmt?(stmt.else_body, &pred)
            when AST::WhileStmt then _any_stmt?(stmt.body, &pred)
            when AST::ForStmt then _any_stmt?(stmt.body, &pred)
            when AST::MatchStmt then stmt.arms.any? { |arm| _any_stmt?(arm.body, &pred) }
            when AST::UnsafeStmt then _any_stmt?(stmt.body, &pred)
            when AST::DeferStmt then stmt.body.is_a?(Array) && _any_stmt?(stmt.body, &pred)
            else false
            end
          end
        end
      end

      def _any_stmt_or_expr?(stmts, &pred)
        _any_stmt?(stmts) do |stmt|
          expr = extract_expr(stmt)
          expr && pred.call(expr)
        end
      end

      # ── CFG-based precision analysis ──────────────────────────────────

      def emit_owning_release_cfg_warnings(cfg_analysis, body)
        graph = cfg_analysis.graph
        reachable_ids = cfg_analysis.reachability.reachable_ids
                exit_kinds = %i[exit return break_exit continue_exit].to_set.freeze
        owning_locals = owning_local_bindings(body)
        return if owning_locals.empty?

        owning_locals.each do |name, info|
          decl_id = find_decl_node_id(graph, name)
          next unless decl_id && reachable_ids.include?(decl_id)

          releases, consumers, reassigns = classify_cfg_nodes(graph, reachable_ids, name)

          unless every_path_to_exit_has_consumer?(graph, decl_id, consumers, exit_kinds, reachable_ids)
            emit_owning_release_leak_warnings({ name => info })
          end

          releases.each do |rel_id|
            reachable_release = find_reachable_release(graph, rel_id, releases, reassigns, reachable_ids)
            next unless reachable_release

            node = graph.nodes[reachable_release]
            @warnings << Warning.new(
              path: @path,
              line: node&.line,
              column: nil,
              length: nil,
              code: "owning-release-double",
              message: "owning binding '#{name}' may be released more than once",
              severity: :warning,
              symbol_name: name,
            )
            break
          end
        end
      end

      def find_decl_node_id(graph, name)
        graph.each_node do |node|
          next unless node.kind == :local_decl
          node.writes_info.each do |write|
            return node.id if write[:origin] == :declaration && write[:name] == name
          end
        end
        nil
      end

      def classify_cfg_nodes(graph, reachable_ids, name)
        releases = Set.new
        consumers = Set.new
        reassigns = Set.new

        graph.each_node do |node|
          next unless reachable_ids.include?(node.id)
          next unless node.statement

          is_defer = node.statement.is_a?(AST::DeferStmt)

          if release_call_in_stmt?(node.statement, name)
            consumers << node.id
            releases << node.id unless is_defer
          end

          if return_for_name?(node.statement, name) || struct_transfer_in_stmt?(node.statement, name)
            consumers << node.id
          end

          if node.kind == :assignment
            node.writes_info.each do |write|
              reassigns << node.id if write[:origin] == :assignment && write[:name] == name
            end
          end
        end

        [releases, consumers, reassigns]
      end

      def release_call_in_stmt?(stmt, name)
        return false unless stmt

        # DeferStmt: inline form `defer x.release()` or block form `defer: …`
        if stmt.is_a?(AST::DeferStmt)
          return true if stmt.expression && _expr_has_release?(stmt.expression, name)
          return stmt.body.is_a?(Array) && stmt.body.any? { |s| release_call_in_stmt?(s, name) }
        end

        expr = extract_expr(stmt)
        expr && _expr_has_release?(expr, name)
      end

      def _expr_has_release?(expr, name)
        return false unless expr

        return true if release_call_on_binding?(expr) && expr.callee.receiver.name == name

        case expr
        when AST::Call
          expr.arguments.any? { |a| _expr_has_release?(a.value, name) } ||
            _expr_has_release?(expr.callee, name)
        when AST::MemberAccess then _expr_has_release?(expr.receiver, name)
        when AST::BinaryOp
          _expr_has_release?(expr.left, name) || _expr_has_release?(expr.right, name)
        when AST::UnaryOp then _expr_has_release?(expr.operand, name)
        else false
        end
      end

      def return_for_name?(stmt, name)
        stmt.is_a?(AST::ReturnStmt) &&
          stmt.value.is_a?(AST::Identifier) &&
          stmt.value.name == name
      end

      def struct_transfer_in_stmt?(stmt, name)
        expr = extract_expr(stmt)
        expr && _expr_contains_transfer?(expr, name)
      end

      def every_path_to_exit_has_consumer?(graph, start_id, consumers, exit_kinds, reachable_ids)
        visited = Set.new
        queue = (graph.nodes[start_id]&.succs || []).dup
        until queue.empty?
          nid = queue.shift
          next if visited.include?(nid)
          visited << nid
          next unless reachable_ids.include?(nid)

          node = graph.nodes[nid]
          next unless node

          if consumers.include?(nid)
            nil
          elsif exit_kinds.include?(node.kind)
            return false
          else
            node.succs.each { |s| queue << s }
          end
        end
        true
      end

      def find_reachable_release(graph, start_id, release_ids, reassign_ids, reachable_ids)
        visited = Set.new
        queue = (graph.nodes[start_id]&.succs || []).dup
        until queue.empty?
          nid = queue.shift
          next if visited.include?(nid)
          visited << nid
          next unless reachable_ids.include?(nid)

          return nid if release_ids.include?(nid) && nid != start_id
          next if reassign_ids.include?(nid)

          node = graph.nodes[nid]
          next unless node

          queue.concat(node.succs)
        end
        nil
      end

      # ── Helpers ───────────────────────────────────────────────────────

      def release_call_on_binding?(expr)
        return false unless expr.is_a?(AST::Call)
        return false unless expr.callee.is_a?(AST::MemberAccess)
        return false unless expr.callee.member == "release"
        return false unless expr.callee.receiver.is_a?(AST::Identifier)
        return false unless expr.arguments.empty?
        true
      end

      def reassigns_owning_binding?(stmt)
        return false unless stmt.is_a?(AST::Assignment)
        return false unless stmt.target.is_a?(AST::Identifier)
        return false unless stmt.operator == "="

        @scopes.reverse_each { |scope| return true if scope.key?(stmt.target.name) }
        false
      end

      def extract_expr(stmt)
        case stmt
        when AST::ExpressionStmt then stmt.expression
        when AST::ReturnStmt then stmt.value
        when AST::LocalDecl then stmt.value
        when AST::Assignment then stmt.value
        else nil
        end
      end

      def extract_line(stmt)
        stmt.respond_to?(:line) ? stmt.line : nil
      end

      def owning_base_name(qname)
        last_dot = qname.rindex(".")
        last_dot ? qname[(last_dot + 1)..] : qname
      end

      def owning_type_by_name?(type_name)
        return false unless type_name
        @owning_type_set ||= build_owning_type_set
        @owning_type_set.include?(type_name)
      end

      def build_owning_type_set
        set = Set.new
        return set unless @sema_facts

        all_methods = [@sema_facts.methods]
        (@imported_modules || {}).each_value do |mod_binding|
          all_methods << mod_binding.methods if mod_binding.respond_to?(:methods)
        end

        all_methods.compact.each do |methods_hash|
          methods_hash.each do |type, methods|
            next unless methods.is_a?(Hash) && methods.key?("release")
            set << type_base_name(type)
          end
        end
        set
      end

      def type_base_name(type)
        return nil unless type
        return type.name.to_s if type.respond_to?(:name) && type.name
        type.to_s
      end
    end
  end
end

# frozen_string_literal: true

module MilkTea
  class SemanticAnalyzer
    class Checker
      def with_unsafe
        @unsafe_depth += 1
        yield
      ensure
        @unsafe_depth -= 1
      end

      def mark_current_unsafe_required!
        current_line = @unsafe_statement_lines.last
        return unless current_line

        @required_unsafe_lines << current_line
      end

      def require_unsafe!(message, line: nil, column: nil)
        if unsafe_context?
          mark_current_unsafe_required!
          return
        end

        suggestion = "wrap in an unsafe block: `unsafe: <expression>`"
        if line || column
          raise SemanticError.new(message, line:, column:, path: @path, suggestion:)
        end

        raise_sema_error(message, suggestion:)
      end

      def with_foreign_mapping_context
        @foreign_mapping_depth += 1
        yield
      ensure
        @foreign_mapping_depth -= 1
      end

      def with_async_function
        @async_function_depth += 1
        yield
      ensure
        @async_function_depth -= 1
      end

      def with_loop
        @loop_depth += 1
        yield
      ensure
        @loop_depth -= 1
      end

      def with_compile_time
        @compile_time_depth += 1
        yield
      ensure
        @compile_time_depth -= 1
      end

      # Tracks the innermost value scopes during body checking so that
      # `resolve_type_ref` can resolve a compile-time reflection type expression
      # (e.g. `field.type` inside an `inline for`) by evaluating it against the
      # local bindings in scope. Nil outside body checking.
      def with_type_resolution_scopes(scopes)
        saved = @type_resolution_scopes
        @type_resolution_scopes = scopes
        yield
      ensure
        @type_resolution_scopes = saved
      end

      def with_loop_barrier
        previous_loop_depth = @loop_depth
        @loop_depth = 0
        yield
      ensure
        @loop_depth = previous_loop_depth
      end

      def unsafe_context?
        @unsafe_depth.positive?
      end

      def inside_async_function?
        @async_function_depth.positive?
      end

      def inside_loop?
        @loop_depth.positive?
      end

      def foreign_mapping_context?
        @foreign_mapping_depth.positive?
      end

      def with_return_context(return_type, allow_return:)
        @return_context_stack << { return_type:, allow_return: }
        yield
      ensure
        @return_context_stack.pop
      end

      def current_return_context
        @return_context_stack.last
      end

      def with_scope(bindings)
        scope = {}
        bindings.each do |binding|
          raise_sema_error("duplicate local #{binding.name}") if scope.key?(binding.name)

          scope[binding.name] = binding
        end

        yield([scope])
      end

      def with_nested_scope(scopes)
        nested_scopes = scopes + [{}]
        yield(nested_scopes)
      end

      def validate_async_function_body!(statements)
        statements.each { |statement| validate_async_statement!(statement) }
      end

      def validate_async_statement!(statement)
        case statement
        when AST::ErrorBlockStmt
          statement.body.each { |s| validate_async_statement!(s) }
        when AST::ErrorStmt
          nil
        when AST::LocalDecl
          statement.else_body&.each { |s| validate_async_statement!(s) }
        when AST::Assignment, AST::ExpressionStmt, AST::ReturnStmt
          nil
        when AST::IfStmt
          statement.branches.each do |branch|
            branch.body.each { |s| validate_async_statement!(s) }
          end
          statement.else_body&.each { |s| validate_async_statement!(s) }
        when AST::WhileStmt
          statement.body.each { |s| validate_async_statement!(s) }
        when AST::ForStmt
          statement.body.each { |s| validate_async_statement!(s) }
        when AST::MatchStmt
          statement.arms.each { |arm| arm.body.each { |s| validate_async_statement!(s) } }
        when AST::UnsafeStmt
          statement.body.each { |s| validate_async_statement!(s) }
        when AST::DeferStmt
          statement.body.each { |s| validate_async_statement!(s) }
        when AST::WhenStmt
          statement.branches.each { |branch| branch.body.each { |s| validate_async_statement!(s) } }
          statement.else_body&.each { |s| validate_async_statement!(s) }
        when AST::BreakStmt, AST::ContinueStmt, AST::StaticAssert, AST::PassStmt
          nil
        else
          raise_sema_error("async functions currently only support straight-line local declarations, assignments, expression statements, and return statements")
        end
      end

      def suggest_name(wrong, candidates, max_distance: 2)
        return nil if wrong.nil? || wrong.to_s.empty? || candidates.nil? || candidates.empty?

        wrong_str = wrong.to_s
        closest = nil
        closest_dist = max_distance + 1
        candidates.each do |candidate|
          next if candidate.nil?
          cand_str = candidate.to_s
          next if cand_str.empty? || cand_str == wrong_str
          dist = levenshtein(wrong_str, cand_str)
          if dist < closest_dist
            closest_dist = dist
            closest = cand_str
          end
        end
        closest_dist <= max_distance ? closest : nil
      end

      # Common std-library types that are usually used bare. When one of these
      # names is unresolved, the compiler points at the module that exports it
      # instead of leaving a generic "unknown name" diagnostic.
      STD_TYPE_IMPORT_HINTS = {
        "String" => "std.string",
        "Vec" => "std.vec",
        "Deque" => "std.deque",
        "Map" => "std.map",
        "Set" => "std.set",
        "LinkedMap" => "std.linked_map",
        "LinkedSet" => "std.linked_set",
        "OrderedMap" => "std.ordered_map",
        "OrderedSet" => "std.ordered_set",
        "BinaryHeap" => "std.binary_heap",
        "PriorityQueue" => "std.priority_queue",
        "Counter" => "std.counter",
      }.freeze

      def import_hint_for_known_std_name(name)
        module_path = STD_TYPE_IMPORT_HINTS[name.to_s]
        return nil unless module_path

        "type '#{name}' is available via 'import #{module_path}'"
      end

      def levenshtein(s, t)
        m = s.length
        n = t.length
        return m if n.zero?
        return n if m.zero?
        d = Array.new(m + 1) { Array.new(n + 1, 0) }
        (0..m).each { |i| d[i][0] = i }
        (0..n).each { |j| d[0][j] = j }
        (1..m).each do |i|
          (1..n).each do |j|
            cost = s[i - 1] == t[j - 1] ? 0 : 1
            d[i][j] = [d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost].min
          end
        end
        d[m][n]
      end

    end
  end
end

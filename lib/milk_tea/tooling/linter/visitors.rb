# frozen_string_literal: true

module MilkTea
  class Linter
    module LinterVisitors
      private

      def visit_source_file(source_file)
        @declared_callable_names = declared_callable_names(source_file)
        @declared_directional_functions = declared_directional_functions(source_file)
        profile_phase("seed_module_bindings") { seed_module_bindings(source_file) }
        profile_phase("rule.unused_imports") { check_unused_imports(source_file) }
        profile_phase("rule.platform_api_drift") { check_platform_api_drift(source_file) } if full_tier?
        source_file.declarations.each do |declaration|
          case declaration
          when AST::FunctionDef
            visit_function(declaration)
          when AST::MethodDef
            warn_reserved_primitive_name(declaration.name, line: declaration.line, column: declaration.column, kind_label: "function")
            visit_function(declaration)
          when AST::ExtendingBlock
            generic_context = extending_block_generic?(declaration)
            declaration.methods.each do |method|
              warn_reserved_primitive_name(method.name, line: method.line, column: method.column, kind_label: "function")
              visit_function(method, generic_context:)
            end
          end
        end
      end
      def seed_module_bindings(source_file)
        @module_bindings = {}
  
        import_names = source_file.imports.filter_map do |import|
          import.alias_name || import.path.parts.last
        end
        source_file.imports.each do |import|
          local_name = import.alias_name || import.path.parts.last
          next if ignored_binding_name?(local_name)
  
          declare_reserved_import_alias_module_binding(
            local_name,
            kind_label: "import alias",
            line: import.line,
            column: import.column,
            unavailable_names: import_names,
          )
        end
  
        source_file.declarations.each do |declaration|
          kind_label = case declaration
                       when AST::FunctionDef, AST::ExternFunctionDecl, AST::ForeignFunctionDecl
                         "function"
                       when AST::ConstDecl
                         "constant"
                       when AST::VarDecl
                         "module variable"
                       when AST::EventDecl
                         "event"
                       else
                         nil
                       end
          next unless kind_label
          next if ignored_binding_name?(declaration.name)
  
          declare_reserved_primitive_module_binding(
            declaration.name,
            kind_label:,
            line: declaration.line,
            column: declaration_column(declaration),
            unavailable_names: @declared_callable_names,
          )
        end
      end
      def extending_block_generic?(declaration)
        declaration.type_name.respond_to?(:arguments) && declaration.type_name.arguments.any?
      end
      def declared_callable_names(source_file)
        source_file.declarations.each_with_object(Set.new) do |declaration, names|
          case declaration
          when AST::FunctionDef, AST::ExternFunctionDecl, AST::ForeignFunctionDecl,
               AST::ConstDecl, AST::VarDecl, AST::EventDecl
            names << declaration.name
          end
        end
      end
      def declared_directional_functions(source_file)
        source_file.declarations.each_with_object({}) do |declaration, functions|
          next unless declaration.is_a?(AST::ExternFunctionDecl) || declaration.is_a?(AST::ForeignFunctionDecl)
          next unless declaration.params.any? { |param| %i[in out inout].include?(param.mode) }
  
          functions[declaration.name] = declaration
        end
      end
      def visit_function(function, generic_context: false)
        generic_body = generic_context || function.type_params.any?
        @generic_function_depth += 1 if generic_body
        @current_function_stack << function
        with_scope do
          profile_phase("rule.reserved_primitive_type_params") do
            warn_reserved_primitive_type_params(function.type_params, kind_label: "type parameter")
          end
          profile_phase("declare_params") do
            function.params.each do |param|
              declare_param(
                param.name,
                line: param_line(param, fallback: function.line),
                column: param_column(param)
              )
            end
          end
          profile_phase("visit_statement_list") { visit_statement_list(function.body) }
          if full_tier?
            profile_phase("rule.dead_assignment") { emit_dead_assignment_warnings(function.body) }
            profile_phase("rule.unreachable") { emit_unreachable_warnings(function.body) }
            profile_phase("rule.borrow") { emit_borrow_warnings(function.body) }
            profile_phase("rule.constant_condition") { emit_constant_condition_warnings(function.body) }
            profile_phase("rule.redundant_null_check") { emit_redundant_null_check_warnings(function.body) }
            profile_phase("rule.loop_single_iteration") { emit_loop_single_iteration_warnings(function.body) }
          end
        end
        profile_phase("rule.missing_return") { check_missing_return(function) }
      ensure
        @current_function_stack.pop
        @generic_function_depth -= 1 if generic_body
      end
      def generic_function_context?
        @generic_function_depth > 0
      end
      def visit_statement_list(stmts)
        terminated = false
        stmts.each do |stmt|
          next if terminated  # skip visitation only; CFG emits the warning
  
          visit_statement(stmt)
          terminated = true if terminator?(stmt)
        end
      end
      def terminator?(stmt)
        stmt.is_a?(AST::ReturnStmt) || stmt.is_a?(AST::BreakStmt) || stmt.is_a?(AST::ContinueStmt)
      end
      def visit_statement(statement)
        case statement
        when AST::LocalDecl
          visit_expression(statement.value) if statement.value
          declare_local(
            statement.name,
            statement.line,
            column: statement.column,
            var: statement.kind == :var
          )
        when AST::Assignment
          visit_expression(statement.value)          # visit RHS first — reads in RHS count against dead-assignment
          mark_assignment_target_reads(statement.target, statement.operator) # compound: marks target as read
          visit_assignment_target(statement.target)  # non-identifier sub-expressions in target
          mark_mutated(statement.target)
          check_self_assignment(statement)
          check_noop_compound_assignment(statement)
        when AST::IfStmt
          statement.branches.each do |branch|
            visit_expression(branch.condition)
            with_scope { visit_statement_list(branch.body) }
          end
          with_scope { visit_statement_list(statement.else_body) } if statement.else_body
          check_redundant_else(statement)
          check_duplicate_if_conditions(statement)
        when AST::MatchStmt
          visit_expression(statement.expression)
          statement.arms.each do |arm|
            with_scope do
              binding_line = arm.binding_line || statement.line
              binding_column = arm.binding_column
              warn_redundant_ignored_match_binding(arm.binding_name, line: binding_line, column: binding_column)
              declare_local(arm.binding_name, binding_line, column: binding_column, var: false) if arm.binding_name
              visit_statement_list(arm.body)
            end
          end
        when AST::UnsafeStmt
          with_scope { visit_statement_list(statement.body) }
        when AST::ForStmt
          visit_expression(statement.iterable)
          with_scope do
            declare_local(statement.name, statement.line, column: statement.column, var: false) if statement.name
            visit_statement_list(statement.body)
          end
        when AST::WhileStmt
          visit_expression(statement.condition)
          with_scope { visit_statement_list(statement.body) }
        when AST::ReturnStmt
          visit_expression(statement.value) if statement.value
        when AST::DeferStmt
          visit_expression(statement.expression) if statement.expression
          with_scope { visit_statement_list(statement.body) } if statement.body
        when AST::ExpressionStmt
          visit_expression(statement.expression)
          check_useless_expression(statement)
        when AST::StaticAssert
          visit_expression(statement.condition)
        when AST::BreakStmt, AST::ContinueStmt
          nil
        when AST::WhenStmt
          visit_expression(statement.discriminant)
          statement.branches.each do |branch|
            with_scope { visit_statement_list(branch.body) }
          end
          with_scope { visit_statement_list(statement.else_body) } if statement.else_body
        when AST::ErrorBlockStmt
          with_scope { visit_statement_list(statement.body) } if statement.body
        else
          nil
        end
      end
      def visit_expression(expression)
        case expression
        when nil
          nil
        when AST::Identifier
          mark_used(expression.name, identifier: expression)
        when AST::MemberAccess
          visit_expression(expression.receiver)
        when AST::IndexAccess
          visit_expression(expression.receiver)
          visit_expression(expression.index)
        when AST::Specialization
          visit_expression(expression.callee)
          expression.arguments.each { |argument| visit_type_argument(argument) }
        when AST::Call
          visit_expression(expression.callee)
          expression.arguments.each do |argument|
            visit_expression(argument.value)
            mark_call_argument_mutated(argument.value)
          end
          mark_alias_source_mutated(expression)
          mark_call_receiver_mutated(expression)
          check_directional_ffi_call(expression)
        when AST::UnaryOp
          visit_expression(expression.operand)
        when AST::BinaryOp
          visit_expression(expression.left)
          visit_expression(expression.right)
          check_self_comparison(expression)
          check_redundant_bool_compare(expression)
        when AST::RangeExpr
          visit_expression(expression.start_expr)
          visit_expression(expression.end_expr)
        when AST::ExpressionList
          expression.elements.each { |e| visit_expression(e) }
        when AST::IfExpr
          visit_expression(expression.condition)
          visit_expression(expression.then_expression)
          visit_expression(expression.else_expression)
        when AST::MatchExpr
          visit_expression(expression.expression)
          expression.arms.each do |arm|
            with_scope do
              binding_line = arm.binding_line || expression.line
              binding_column = arm.binding_column
              warn_redundant_ignored_match_binding(arm.binding_name, line: binding_line, column: binding_column)
              declare_local(arm.binding_name, binding_line, column: binding_column, var: false) if arm.binding_name
              visit_expression(arm.value)
            end
          end
        when AST::UnsafeExpr
          visit_expression(expression.expression)
        when AST::ProcExpr
          with_scope do
            fallback_line = expression.respond_to?(:line) ? expression.line : nil
            expression.params.each do |param|
              declare_param(
                param.name,
                line: param_line(param, fallback: fallback_line),
                column: param_column(param)
              )
            end
            visit_statement_list(expression.body)
            if full_tier?
              emit_dead_assignment_warnings(expression.body)
              emit_unreachable_warnings(expression.body)
              emit_borrow_warnings(expression.body)
              emit_constant_condition_warnings(expression.body)
              emit_redundant_null_check_warnings(expression.body)
              emit_loop_single_iteration_warnings(expression.body)
            end
          end
        when AST::AwaitExpr
          visit_expression(expression.expression)
        when AST::FormatString
          expression.parts.each do |part|
            next unless part.is_a?(AST::FormatExprPart)
  
            visit_expression(part.expression)
          end
        when AST::IntegerLiteral, AST::FloatLiteral, AST::StringLiteral, AST::BooleanLiteral, AST::NullLiteral
          nil
        when AST::SizeofExpr, AST::AlignofExpr
          visit_type_ref(expression.type)
        when AST::OffsetofExpr
          mark_used(expression.field)
        else
          nil
        end
      end
      def visit_type_argument(argument)
        visit_expression(argument.value) if argument.respond_to?(:value)
      end
      def visit_type_ref(type_ref)
        return unless type_ref

        type_ref.name.parts.each { |part| mark_used(part) }
        type_ref.arguments.each do |argument|
          next unless argument.respond_to?(:value)

          visit_type_ref(argument.value) if argument.value.is_a?(AST::TypeRef)
        end
      end
      def visit_assignment_target(target)
        case target
        when AST::Identifier
          nil
        when AST::MemberAccess
          visit_expression(target.receiver)
        when AST::IndexAccess
          visit_expression(target.receiver)
          visit_expression(target.index)
        else
          visit_expression(target)
        end
      end
      def mark_assignment_target_reads(target, operator)
        return if operator == "="
  
        mark_used(target.name, identifier: target) if target.is_a?(AST::Identifier)
      end
      def mark_mutated(target)
        return unless target.is_a?(AST::Identifier) || target.is_a?(AST::IndexAccess) || target.is_a?(AST::MemberAccess)
  
        # For direct identifier assignment (e.g., x = value), mark x as mutated.
        if target.is_a?(AST::Identifier)
          @scopes.reverse_each do |scope|
            binding = scope[target.name]
            next unless binding
  
            binding.mutated = true
            return
          end
        end
  
        # For index assignment (e.g., array[0] = value), mark the array as mutated.
        if target.is_a?(AST::IndexAccess)
          mark_mutated(target.receiver)
        end
  
        # For field assignment (e.g., rect.w = value), mark the struct variable as mutated.
        if target.is_a?(AST::MemberAccess)
          mark_mutated(target.receiver)
        end
      end
      def mark_call_argument_mutated(expression)
        if expression.is_a?(AST::Identifier) && mutating_argument_identifier?(expression)
          mark_mutated(expression)
          return
        end
  
        if expression.is_a?(AST::UnaryOp) && %w[out inout].include?(expression.operator)
          mark_mutated(expression.operand)
          return
        end
  
        # ref_of(x) and ptr_of(x) can expose writable aliases — treat as potential
        # mutation since callees may write through them (common C-FFI out-param pattern).
        if expression.is_a?(AST::Call) &&
           expression.callee.is_a?(AST::Identifier) &&
          ["ref_of", "ptr_of"].include?(expression.callee.name) &&
           expression.arguments.length == 1
          mark_mutated(expression.arguments.first.value)
        end
      end
      def mutating_argument_identifier?(expression)
        return false unless expression.is_a?(AST::Identifier)
  
        binding_resolution = @sema_facts&.binding_resolution
        return false unless binding_resolution
  
        binding_resolution.mutating_argument_identifier_ids&.key?(expression.object_id) ||
          binding_resolution.mutable_lvalue_argument_identifier_ids&.key?(expression.object_id)
      end
      def mark_call_receiver_mutated(expression)
        return unless expression.is_a?(AST::Call)
        return unless expression.callee.is_a?(AST::MemberAccess)
        return unless editable_receiver_expression?(expression.callee.receiver)
  
        mark_mutated(expression.callee.receiver)
      end
      def mark_alias_source_mutated(expression)
        return unless expression.is_a?(AST::Call)
        return unless expression.callee.is_a?(AST::Identifier)
        return unless %w[ref_of ptr_of].include?(expression.callee.name)
        return unless expression.arguments.length == 1
  
        mark_mutated(expression.arguments.first.value)
      end
      def editable_receiver_expression?(expression)
        return true unless @sema_facts
  
        @sema_facts&.binding_resolution&.editable_receiver_expression_ids&.key?(expression.object_id)
      end
      def with_scope
        @scopes << {}
        yield
      ensure
        emit_scope_warnings(@scopes.pop)
      end
      def declare_local(name, line, column: nil, var: false)
        return if ignored_binding_name?(name)
  
        resolve_reserved_primitive_name_conflicts!(name)
  
        replacement_name = nil
        replacement_base_name = nil
        if RESERVED_VALUE_TYPE_NAMES.include?(name)
          replacement_base_name = suggested_reserved_primitive_name(name, kind_label: "local")
          replacement_name = next_available_reserved_primitive_name(
            replacement_base_name,
            visible_binding_names(excluding_name: name),
          )
        end
  
        # shadow: check whether any outer scope already has a binding for this name
        if @scopes.length > 1
          @scopes[0..-2].each do |outer_scope|
            if outer_scope.key?(name)
              @warnings << Warning.new(
                path: @path, line:, column:, length: name.length, code: "shadow",
                message: "local '#{name}' shadows a binding from an outer scope",
                symbol_name: name
              )
              break
            end
          end
        end
  
        @scopes.last[name] = Binding.new(
          name:, line:, column:, used: false,
          binding_kind: :local,
          allow_prefer_let: var && !generic_function_context?,
          mutated: false,
          replacement_name:,
          replacement_base_name:,
        )
        register_reserved_primitive_name_fix(@scopes.last[name], kind_label: "local", replacement_name:) if replacement_name
      end
      def declare_param(name, line: nil, column: nil)
        return if ignored_binding_name?(name)
  
        resolve_reserved_primitive_name_conflicts!(name)
  
        replacement_name = nil
        replacement_base_name = nil
        if RESERVED_VALUE_TYPE_NAMES.include?(name)
          replacement_base_name = suggested_reserved_primitive_name(name, kind_label: "parameter")
          replacement_name = next_available_reserved_primitive_name(
            replacement_base_name,
            visible_binding_names(excluding_name: name),
          )
        end
  
        @scopes.last[name] = Binding.new(
          name:, line:, column:, used: false,
          binding_kind: :param,
          allow_prefer_let: false,
          mutated: false,
          replacement_name:,
          replacement_base_name:,
        )
        register_reserved_primitive_name_fix(@scopes.last[name], kind_label: "parameter", replacement_name:) if replacement_name
      end
      def mark_used(name, identifier: nil)
        @scopes.reverse_each do |scope|
          binding = scope[name]
          next unless binding
  
          binding.used = true
          record_reserved_primitive_identifier_use(binding, identifier)
          return
        end
  
        binding = @module_bindings[name]
        return unless binding
  
        binding.used = true
        record_reserved_primitive_identifier_use(binding, identifier)
      end
      def emit_scope_warnings(scope)
        scope.each_value do |binding|
          if !binding.used
            code = binding.binding_kind == :param ? "unused-param" : "unused-local"
            kind_label = binding.binding_kind == :param ? "parameter" : "local"
            @warnings << Warning.new(
              path: @path,
              line: binding.line,
              column: binding.column,
              length: binding.name.length,
              code: code,
              message: "unused #{kind_label} '#{binding.name}'",
              symbol_name: binding.name,
            )
          else
            if binding.allow_prefer_let && !binding.mutated
              @warnings << Warning.new(
                path: @path,
                line: binding.line,
                column: binding.column,
                length: binding.name.length,
                code: "prefer-let",
                message: "variable '#{binding.name}' is never reassigned, prefer 'let'",
                severity: :hint,
                symbol_name: binding.name
              )
            end
          end
        end
      end
      # ── borrow facts helpers ──────────────────────────────────────────────────
  
      BORROW_CALL_NAMES = %w[ref_of ptr_of].freeze
  
      def collect_borrowed_names(stmts)
        names = Set.new
        stmts.each { |s| collect_borrows_from_stmt(s, names) }
        names
      end
  
      def collect_borrows_from_stmt(stmt, names)
        case stmt
        when AST::LocalDecl
          collect_borrows_from_expr(stmt.value, names) if stmt.value
        when AST::Assignment
          collect_borrows_from_expr(stmt.value, names)
        when AST::ExpressionStmt
          collect_borrows_from_expr(stmt.expression, names)
        when AST::IfStmt
          stmt.branches.each do |b|
            collect_borrows_from_expr(b.condition, names)
            b.body.each { |s| collect_borrows_from_stmt(s, names) }
          end
          stmt.else_body&.each { |s| collect_borrows_from_stmt(s, names) }
        when AST::WhileStmt
          collect_borrows_from_expr(stmt.condition, names)
          stmt.body.each { |s| collect_borrows_from_stmt(s, names) }
        when AST::ForStmt
          stmt.body.each { |s| collect_borrows_from_stmt(s, names) }
        when AST::ReturnStmt
          collect_borrows_from_expr(stmt.value, names) if stmt.value
        when AST::MatchStmt
          collect_borrows_from_expr(stmt.expression, names)
          stmt.arms.each { |arm| arm.body.each { |s| collect_borrows_from_stmt(s, names) } }
        when AST::UnsafeStmt
          stmt.body.each { |s| collect_borrows_from_stmt(s, names) }
        when AST::DeferStmt
          collect_borrows_from_expr(stmt.expression, names) if stmt.expression
          stmt.body&.each { |s| collect_borrows_from_stmt(s, names) }
        when AST::WhenStmt
          collect_borrows_from_expr(stmt.discriminant, names)
          stmt.branches.each { |b| b.body.each { |s| collect_borrows_from_stmt(s, names) } }
          stmt.else_body&.each { |s| collect_borrows_from_stmt(s, names) }
        end
      end
  
      def collect_borrows_from_expr(expr, names, inside_call_argument: false)
        case expr
        when nil then nil
        when AST::Call
          if !inside_call_argument && expr.callee.is_a?(AST::Identifier) && BORROW_CALL_NAMES.include?(expr.callee.name)
            arg = expr.arguments.first
            if arg&.value.is_a?(AST::Identifier)
              names << arg.value.name
            end
          else
            collect_borrows_from_expr(expr.callee, names)
            expr.arguments.each { |a| collect_borrows_from_expr(a.value, names, inside_call_argument: true) }
          end
        when AST::UnaryOp  then collect_borrows_from_expr(expr.operand, names, inside_call_argument:)
        when AST::BinaryOp
          collect_borrows_from_expr(expr.left, names, inside_call_argument:)
          collect_borrows_from_expr(expr.right, names, inside_call_argument:)
        when AST::IfExpr
          collect_borrows_from_expr(expr.condition, names, inside_call_argument:)
          collect_borrows_from_expr(expr.then_expression, names, inside_call_argument:)
          collect_borrows_from_expr(expr.else_expression, names, inside_call_argument:)
        when AST::AwaitExpr
          collect_borrows_from_expr(expr.expression, names, inside_call_argument:)
        when AST::UnsafeExpr
          collect_borrows_from_expr(expr.expression, names, inside_call_argument:)
        when AST::MemberAccess  then collect_borrows_from_expr(expr.receiver, names, inside_call_argument:)
        when AST::IndexAccess
          collect_borrows_from_expr(expr.receiver, names, inside_call_argument:)
          collect_borrows_from_expr(expr.index, names, inside_call_argument:)
        end
      end
  
      def collect_written_names(stmts)
        names = Set.new
        stmts.each { |s| collect_writes_from_stmt(s, names) }
        names
      end
  
      def collect_writes_from_stmt(stmt, names)
        case stmt
        when AST::Assignment
          names << stmt.target.name if stmt.target.is_a?(AST::Identifier)
          collect_writes_from_stmt_list(stmt_sub_stmts(stmt), names)
        when AST::IfStmt
          stmt.branches.each { |b| b.body.each { |s| collect_writes_from_stmt(s, names) } }
          stmt.else_body&.each { |s| collect_writes_from_stmt(s, names) }
        when AST::WhileStmt
          stmt.body.each { |s| collect_writes_from_stmt(s, names) }
        when AST::ForStmt
          stmt.body.each { |s| collect_writes_from_stmt(s, names) }
        when AST::MatchStmt
          stmt.arms.each { |arm| arm.body.each { |s| collect_writes_from_stmt(s, names) } }
        when AST::WhenStmt
          stmt.branches.each { |b| b.body.each { |s| collect_writes_from_stmt(s, names) } }
          stmt.else_body&.each { |s| collect_writes_from_stmt(s, names) }
        when AST::UnsafeStmt
          stmt.body.each { |s| collect_writes_from_stmt(s, names) }
        when AST::DeferStmt
          stmt.body&.each { |s| collect_writes_from_stmt(s, names) }
        end
      end
  
      def collect_writes_from_stmt_list(stmts, names)
        stmts.each { |s| collect_writes_from_stmt(s, names) }
      end
  
      def stmt_sub_stmts(_stmt)
        []
      end
  
      def find_borrow_location(stmts, name)
        stmts.each do |stmt|
          location = find_borrow_location_in_stmt(stmt, name)
          return location if location
        end
        nil
      end
  
      def find_borrow_location_in_stmt(stmt, name)
        case stmt
        when AST::LocalDecl
          find_borrow_location_in_expr(stmt.value, name) if stmt.value
        when AST::Assignment
          find_borrow_location_in_expr(stmt.value, name)
        when AST::ExpressionStmt
          find_borrow_location_in_expr(stmt.expression, name)
        when AST::IfStmt
          stmt.branches.each do |b|
            location = find_borrow_location_in_expr(b.condition, name)
            return location if location
            b.body.each { |s| location = find_borrow_location_in_stmt(s, name); return location if location }
          end
          stmt.else_body&.each { |s| location = find_borrow_location_in_stmt(s, name); return location if location }
          nil
        when AST::WhileStmt
          location = find_borrow_location_in_expr(stmt.condition, name)
          return location if location
          stmt.body.each { |s| location = find_borrow_location_in_stmt(s, name); return location if location }
          nil
        when AST::ForStmt
          stmt.body.each { |s| location = find_borrow_location_in_stmt(s, name); return location if location }
          nil
        when AST::ReturnStmt
          find_borrow_location_in_expr(stmt.value, name) if stmt.value
        when AST::MatchStmt
          location = find_borrow_location_in_expr(stmt.expression, name)
          return location if location
          stmt.arms.each do |arm|
            arm.body.each { |s| location = find_borrow_location_in_stmt(s, name); return location if location }
          end
          nil
        when AST::UnsafeStmt
          stmt.body.each { |s| location = find_borrow_location_in_stmt(s, name); return location if location }
          nil
        when AST::DeferStmt
          location = find_borrow_location_in_expr(stmt.expression, name) if stmt.expression
          return location if location
          stmt.body&.each { |s| location = find_borrow_location_in_stmt(s, name); return location if location }
          nil
        when AST::WhenStmt
          location = find_borrow_location_in_expr(stmt.discriminant, name)
          return location if location
          stmt.branches.each do |b|
            b.body.each { |s| location = find_borrow_location_in_stmt(s, name); return location if location }
          end
          stmt.else_body&.each { |s| location = find_borrow_location_in_stmt(s, name); return location if location }
          nil
        end
      end
  
      def find_borrow_location_in_expr(expr, name)
        case expr
        when nil then nil
        when AST::Call
          if expr.callee.is_a?(AST::Identifier) && BORROW_CALL_NAMES.include?(expr.callee.name)
            arg = expr.arguments.first
            if arg&.value.is_a?(AST::Identifier) && arg.value.name == name
              return [arg.value.line, arg.value.column, arg.value.name.length]
            end
          end
          location = find_borrow_location_in_expr(expr.callee, name)
          return location if location
          expr.arguments.each do |a|
            location = find_borrow_location_in_expr(a.value, name)
            return location if location
          end
          nil
        when AST::UnaryOp  then find_borrow_location_in_expr(expr.operand, name)
        when AST::BinaryOp
          find_borrow_location_in_expr(expr.left, name) || find_borrow_location_in_expr(expr.right, name)
        when AST::IfExpr
          find_borrow_location_in_expr(expr.condition, name) ||
            find_borrow_location_in_expr(expr.then_expression, name) ||
            find_borrow_location_in_expr(expr.else_expression, name)
        when AST::AwaitExpr
          find_borrow_location_in_expr(expr.expression, name)
        when AST::UnsafeExpr
          find_borrow_location_in_expr(expr.expression, name)
        else
          nil
        end
      end
    end
  end
end

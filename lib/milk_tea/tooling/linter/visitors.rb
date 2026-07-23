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
          profile_phase("rule.owning_release") { emit_owning_release_warnings(function) }
          profile_phase("rule.prefer_let_else") { emit_prefer_let_else_warnings(function.body) }
          profile_phase("rule.prefer_var_else") { emit_prefer_var_else_warnings(function.body) }
          profile_phase("rule.redundant_return") { emit_redundant_return_warnings(function) }
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
          next if terminated  # skip visitation only; ControlFlow emits the warning
  
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
          check_redundant_type_annotation(statement)
          flag_redundant_widening_cast(statement.value) if statement.type && statement.value
          record_ptr_candidate(statement)
        when AST::Assignment
          visit_expression(statement.value)          # visit RHS first — reads in RHS count against dead-assignment
          mark_assignment_target_reads(statement.target, statement.operator) # compound: marks target as read
          visit_assignment_target(statement.target)  # non-identifier sub-expressions in target
          mark_mutated(statement.target)
          check_self_assignment(statement)
          check_noop_compound_assignment(statement)
          flag_redundant_widening_cast(statement.value) if statement.operator == "="
        when AST::IfStmt
          statement.branches.each do |branch|
            visit_expression(branch.condition)
            with_scope { visit_statement_list(branch.body) }
          end
          with_scope { visit_statement_list(statement.else_body) } if statement.else_body
          check_redundant_else(statement)
          check_duplicate_if_conditions(statement)
          if full_tier?
            check_prefer_inline_if(statement)
            check_prefer_conditional_expression_if(statement)
          end
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
          if full_tier?
            check_prefer_conditional_expression_match(statement)
            check_prefer_or_pattern(statement.arms, body_of: ->(arm) { arm.body })
            check_prefer_try(statement.expression, statement.arms)
          end
        when AST::UnsafeStmt
          @unsafe_depth += 1
          with_scope { visit_statement_list(statement.body) }
          @unsafe_depth -= 1
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
          flag_redundant_widening_cast(statement.value) if statement.value
        when AST::DeferStmt
          visit_expression(statement.expression) if statement.expression
          with_scope { visit_statement_list(statement.body) } if statement.body
        when AST::ExpressionStmt
          visit_expression(statement.expression)
          check_useless_expression(statement)
        when AST::GatherStmt
          statement.handles.each { |handle| mark_used(handle.name) if handle.is_a?(AST::Identifier) }
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
          check_prefer_struct_with(expression) if full_tier?
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
          if full_tier?
            check_prefer_is_variant(expression)
            check_prefer_or_pattern(expression.arms, body_of: ->(arm) { arm.value })
          end
        when AST::UnsafeExpr
          @unsafe_depth += 1
          visit_expression(expression.expression)
          @unsafe_depth -= 1
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
              emit_owning_release_warnings(expression.body)
            end
            emit_prefer_let_else_warnings(expression.body)
            emit_prefer_var_else_warnings(expression.body)
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
        when AST::PrefixCast
          visit_expression(expression.expression)
          check_redundant_cast(expression)
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
          track_binding_unsafe_use(name)
          record_reserved_primitive_identifier_use(binding, identifier)
          return
        end

        binding = @module_bindings[name]
        return unless binding

        binding.used = true
        record_reserved_primitive_identifier_use(binding, identifier)
      end

      def track_binding_unsafe_use(name)
        uses = @binding_ptr_unsafe_uses[name]
        if @unsafe_depth > 0
          uses[:unsafe] += 1
        else
          uses[:safe] += 1
        end
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

            uses = @binding_ptr_unsafe_uses[binding.name]
            if binding.binding_kind != :param && uses[:unsafe] > 0 && uses[:safe] == 0 && @ptr_candidates.include?(binding.name)
              @warnings << Warning.new(
                path: @path,
                line: binding.line,
                column: binding.column,
                length: binding.name.length,
                code: "prefer-own-ptr",
                message: "binding '#{binding.name}' is only used inside unsafe — consider converting its type from ptr to own for auto-deref",
                severity: :hint,
                symbol_name: binding.name,
              )
            end
          end
        end
      end
      # ── redundant type annotation ─────────────────────────────────────────────

      def check_redundant_type_annotation(statement)
        return unless statement.is_a?(AST::LocalDecl)
        return unless statement.kind == :let
        return unless statement.type
        return unless statement.value

        declared_name = type_ref_name(statement.type)
        return unless declared_name

        inferred_name = expression_literal_type_name(statement.value)
        return unless inferred_name
        return unless declared_name == inferred_name

        @warnings << Warning.new(
          path: @path,
          line: statement.line,
          column: statement.column,
          length: statement.name.length,
          code: "redundant-type-annotation",
          message: "type annotation ': #{declared_name}' is redundant, inferred from initializer",
          severity: :hint,
          symbol_name: statement.name,
        )
      end

      def record_ptr_candidate(statement)
        return unless statement.is_a?(AST::LocalDecl)
        return unless statement.value

        if statement.type && statement.type.is_a?(AST::TypeRef)
          type_text = type_ref_source(statement.type)
          return unless type_text&.include?("ptr[")
        else
          value = statement.value
          unless heap_alloc_call?(value)
            alloc_name = alloc_wrapper_name(value)
            return unless alloc_name
          end
        end

        @ptr_candidates.add(statement.name)
      end

      def heap_alloc_call?(expr)
        return false unless expr.is_a?(AST::Call)
        return false unless expr.callee.is_a?(AST::MemberAccess)

        %w[must_alloc alloc must_alloc_zeroed must_resize].include?(expr.callee.member)
      end

      def alloc_wrapper_name(expr)
        return nil unless expr.is_a?(AST::Call)
        return nil unless expr.callee.is_a?(AST::Identifier)

        name = expr.callee.name
        %w[alloc_expr alloc_stmt alloc_decl].include?(name) ? name : nil
      end

      def type_ref_source(type_node)
        return nil unless type_node.is_a?(AST::TypeRef)
        return nil if type_node.name.parts.empty?

        type_node.name.parts.last
      rescue StandardError
        nil
      end

      def type_ref_name(type_node)
        return nil unless type_node.is_a?(AST::TypeRef)
        return nil if type_node.name.parts.empty?

        type_node.name.parts.first
      rescue StandardError
        nil
      end

      # ── redundant cast ─────────────────────────────────────────────────────────

      # Detects a two-arm match expression that only maps a single variant arm
      # to a boolean and everything else to the opposite boolean, e.g.
      #   match token: TokenKind.eof: true; _: false
      # which is exactly what `token is TokenKind.eof` desugars to. Only fires
      # when the scrutinee is a variant (the `is` operator is variant-only), so
      # enum/int/str bool-matches are never misreported.
      def check_prefer_is_variant(match_expr)
        return unless @sema_facts

        arms = match_expr.arms
        return unless arms.size == 2

        wildcard_arm, arm_pattern_arm = classify_is_variant_arms(arms)
        return unless wildcard_arm && arm_pattern_arm

        # The variant arm must be a bare `Type.arm` reference: no payload
        # destructure and no `as` binding, otherwise it is not equivalent to `is`.
        pattern = arm_pattern_arm.pattern
        return unless pattern.is_a?(AST::MemberAccess)
        return unless arm_pattern_arm.binding_name.nil?

        variant_value = boolean_literal_value(arm_pattern_arm.value)
        wildcard_value = boolean_literal_value(wildcard_arm.value)
        return if variant_value.nil? || wildcard_value.nil?
        return if variant_value == wildcard_value

        scrutinee_type = resolve_expr_type(match_expr.expression)
        return unless scrutinee_type.is_a?(Types::Variant)

        arm_text = expr_source_name(pattern)
        suggestion = variant_value ? "expr is #{arm_text}" : "not (expr is #{arm_text})"

        @warnings << Warning.new(
          path: @path,
          line: match_expr.line,
          column: match_expr.column,
          length: match_expr.length,
          code: "prefer-is-variant",
          message: "prefer `#{suggestion}` over a match that maps one variant arm to a boolean",
          severity: :hint,
        )
      end

      def classify_is_variant_arms(arms)
        wildcard = arms.find { |arm| wildcard_pattern?(arm.pattern) }
        other = arms.find { |arm| !wildcard_pattern?(arm.pattern) }
        return [nil, nil] unless wildcard && other

        [wildcard, other]
      end

      def wildcard_pattern?(pattern)
        pattern.is_a?(AST::Identifier) && pattern.name == "_"
      end

      def boolean_literal_value(expr)
        expr.is_a?(AST::BooleanLiteral) ? expr.value : nil
      end

      def expr_source_name(expr)
        case expr
        when AST::Identifier then expr.name
        when AST::MemberAccess then "#{expr_source_name(expr.receiver)}.#{expr.member}"
        else "…"
        end
      end

      # ── conciseness hints ─────────────────────────────────────────────────

      def emit_conciseness_hint(code, line:, column:, message:, length: nil)
        @warnings << Warning.new(path: @path, line:, column:, length:, code:, message:, severity: :hint)
      end

      # Position-insensitive structural fingerprint of an AST node, used to test
      # whether two branch/arm bodies are equivalent regardless of source
      # location.
      def node_fingerprint(node)
        case node
        when ::Data
          skip = %i[line column length else_line else_column binding_line binding_column]
          parts = node.deconstruct_keys(nil).reject { |k, _| skip.include?(k) }
          "#{node.class.name}(#{parts.map { |k, v| "#{k}:#{node_fingerprint(v)}" }.join(",")})"
        when Array
          "[#{node.map { |e| node_fingerprint(e) }.join(",")}]"
        else
          node.inspect
        end
      end

      def single_statement_body(body)
        body.is_a?(Array) && body.size == 1 ? body.first : nil
      end

      def inline_simple_statement?(stmt)
        case stmt
        when AST::ReturnStmt, AST::Assignment, AST::ExpressionStmt, AST::BreakStmt, AST::ContinueStmt, AST::LocalDecl
          true
        else
          false
        end
      end

      # prefer-inline-if: a block-form if/else whose every branch is a single
      # simple statement can be written on one line.
      def check_prefer_inline_if(statement)
        return if statement.inline
        return unless statement.else_body

        bodies = statement.branches.map(&:body) + [statement.else_body]
        stmts = bodies.map { |b| single_statement_body(b) }
        return if stmts.any?(&:nil?)
        return unless stmts.all? { |s| inline_simple_statement?(s) }

        emit_conciseness_hint(
          "prefer-inline-if",
          line: statement.line,
          column: statement.branches.first&.column,
          message: "if/else with single-statement branches can be written inline",
        )
      end

      # prefer-conditional-expression: if/match whose every branch either
      # returns a value or assigns the same lvalue can become an expression form
      # (`return if …: … else: …` or `x = match …`).
      def check_prefer_conditional_expression_if(statement)
        return unless statement.else_body

        stmts = (statement.branches.map(&:body) + [statement.else_body]).map { |b| single_statement_body(b) }
        report_conditional_expression(stmts, line: statement.line, column: statement.branches.first&.column, kind: "if")
      end

      def check_prefer_conditional_expression_match(statement)
        return unless statement.arms.any? { |arm| wildcard_pattern?(arm.pattern) }
        return if statement.arms.any? { |arm| arm.binding_name }

        stmts = statement.arms.map { |arm| single_statement_body(arm.body) }
        report_conditional_expression(stmts, line: statement.line, column: statement.column, kind: "match")
      end

      def report_conditional_expression(stmts, line:, column:, kind:)
        return if stmts.empty? || stmts.any?(&:nil?)

        if stmts.all? { |s| s.is_a?(AST::ReturnStmt) && s.value }
          emit_conciseness_hint(
            "prefer-conditional-expression",
            line:, column:,
            message: "every #{kind} branch returns a value; rewrite as `return #{kind} …` expression",
          )
        elsif stmts.all? { |s| s.is_a?(AST::Assignment) && s.operator == "=" } &&
              stmts.map { |s| node_fingerprint(s.target) }.uniq.size == 1
          target_name = stmts.first.target.name
          emit_conciseness_hint(
            "prefer-conditional-expression",
            line:, column:,
            message: "every #{kind} branch assigns to '#{target_name}'; rewrite as `let #{target_name} = #{kind} …` expression",
          )
        end
      end

      # prefer-or-pattern: adjacent match arms with identical bodies and no
      # bindings can be merged with `|`.
      def check_prefer_or_pattern(arms, body_of:)
        arms.each_cons(2) do |first, second|
          next if first.binding_name || second.binding_name
          next if wildcard_pattern?(first.pattern) || wildcard_pattern?(second.pattern)
          next if body_of.call(first).equal?(body_of.call(second))
          next unless node_fingerprint(body_of.call(first)) == node_fingerprint(body_of.call(second))

          pattern = second.pattern
          pattern_line = pattern.respond_to?(:line) ? pattern.line : second.binding_line
          pattern_column = pattern.respond_to?(:column) ? pattern.column : second.binding_column
          emit_conciseness_hint(
            "prefer-or-pattern",
            line: pattern_line,
            column: pattern_column,
            message: "adjacent match arms have identical bodies; merge them with `|`",
          )
        end
      end

      # prefer-struct-with: a constructor literal that copies all-but-one field
      # from the same source value can use `.with(...)`.
      def check_prefer_struct_with(call)
        return unless @sema_facts
        return unless call.callee.is_a?(AST::Identifier) || call.callee.is_a?(AST::MemberAccess)
        return if call.arguments.empty?
        return unless call.arguments.all? { |arg| arg.name }

        copied, changed = call.arguments.partition { |arg| copy_field_argument?(arg) }
        return unless changed.size >= 1 && copied.size >= 2

        sources = copied.map { |arg| node_fingerprint(arg.value.receiver) }.uniq
        return unless sources.size == 1

        struct_type = resolve_expr_type(call)
        return unless struct_type.is_a?(Types::Struct)
        source_type = resolve_expr_type(copied.first.value.receiver)
        return unless source_type.equal?(struct_type) || (source_type.respond_to?(:name) && source_type.name == struct_type.name)

        field_names = struct_type.fields.keys.map(&:to_s).to_set
        copied_names = copied.map { |arg| arg.name.to_s }.to_set
        changed_names = changed.map { |arg| arg.name.to_s }
        return unless (field_names - changed_names.to_set) == copied_names

        source_text = expr_source_name(copied.first.value.receiver)
        emit_conciseness_hint(
          "prefer-struct-with",
          line: call.callee.respond_to?(:line) ? call.callee.line : nil,
          column: call.callee.respond_to?(:column) ? call.callee.column : nil,
          message: "copies #{copied.size} field(s) from `#{source_text}`; use `#{source_text}.with(#{changed_names.join(", ")} = …)`",
        )
      end

      def copy_field_argument?(argument)
        value = argument.value
        value.is_a?(AST::MemberAccess) && value.member.to_s == argument.name.to_s
      end

      # prefer-try: a two-arm match on Result/Option whose failure/none arm only
      # returns is error-propagation and can usually be written `expr?`.
      def check_prefer_try(scrutinee, arms)
        return unless @sema_facts
        return unless arms.size == 2

        scrutinee_type = resolve_expr_type(scrutinee)
        return unless scrutinee_type.is_a?(Types::Variant)
        base = scrutinee_type.name.to_s.split(".").last
        return unless %w[Result Option].include?(base)

        early_return_arm = arms.find do |arm|
          stmt = single_statement_body(arm.body)
          next false unless stmt.is_a?(AST::ReturnStmt) && stmt.value
          next false unless short_circuit_arm_pattern?(arm.pattern, base)

          propagation_return?(stmt.value, base, arm.binding_name)
        end
        return unless early_return_arm

        emit_conciseness_hint(
          "prefer-try",
          line: scrutinee.respond_to?(:line) ? scrutinee.line : nil,
          column: scrutinee.respond_to?(:column) ? scrutinee.column : nil,
          message: "this #{base} match only propagates the failure branch; consider `expr?`",
        )
      end

      def short_circuit_arm_pattern?(pattern, base)
        name = pattern.is_a?(AST::MemberAccess) ? pattern.member.to_s : nil
        return false unless name

        (base == "Result" && name == "failure") || (base == "Option" && name == "none")
      end

      # The early-return value must re-propagate the short-circuit case
      # *unchanged*: `Option[_].none`, or `Result[_, _].failure(error = <b>.error)`
      # where `<b>` is the arm's own binding. This excludes map/map_error
      # patterns (transformed error or value), which `expr?` cannot express.
      def propagation_return?(value, base, binding_name)
        if base == "Option"
          return member_named?(value, "none") || (value.is_a?(AST::Call) && member_named?(value.callee, "none"))
        end

        return false unless binding_name
        return false unless value.is_a?(AST::Call) && member_named?(value.callee, "failure")
        return false unless value.arguments.size == 1

        error_arg = value.arguments.first
        return false unless error_arg.name.to_s == "error"

        forwarded = error_arg.value
        forwarded.is_a?(AST::MemberAccess) &&
          forwarded.member.to_s == "error" &&
          forwarded.receiver.is_a?(AST::Identifier) &&
          forwarded.receiver.name == binding_name
      end

      def member_named?(node, name)
        node.is_a?(AST::MemberAccess) && node.member.to_s == name
      end

      def check_redundant_cast(cast_expr)
        return unless cast_expr.is_a?(AST::PrefixCast)
        return unless cast_expr.target_type

        target_name = type_ref_name(cast_expr.target_type)
        return unless target_name

        # When facts are available compare the *full* resolved types, not just
        # the nominal base name. Comparing names alone wrongly treats e.g.
        # `ptr[void]<-p` (p: ptr[ubyte]) as same-type because both are "ptr",
        # and removing that cast is a real type error.
        if @sema_facts
          cast_type = resolve_expr_type(cast_expr)
          inner_type = resolve_expr_type(cast_expr.expression)
          if cast_type && inner_type
            emit_redundant_cast(cast_expr, target_name, "cast to same type is redundant") if same_resolved_type?(cast_type, inner_type)
            if own_to_pointer_cast_redundant?(inner_type, cast_type)
              emit_redundant_cast(cast_expr, target_name, "implicit own->ptr coercion makes this cast redundant")
            end
            return
          end
        end

        # Fallback when the inner type cannot be resolved (e.g. no sema facts):
        # a value literal whose type is known by name.
        literal_name = expression_literal_type_name(cast_expr.expression)
        if literal_name && literal_name == target_name
          emit_redundant_cast(cast_expr, target_name, "cast to same type is redundant")
        end

        # NOTE: widening redundancy is intentionally NOT reported here. A
        # widening cast can be load-bearing at its site (e.g. `(ulong<-x) << 32`
        # controls the shift width), so it is only redundant at a coercion
        # boundary whose declared type is the target. Those cases are handled by
        # check_boundary_widening_cast at the specific boundary sites.
      end

      # Reports a widening cast as redundant only when it sits *directly* at a
      # coercion slot: the RHS of a typed `let`/`var`, a `return` value, or the
      # RHS of a plain `=` assignment. At those positions the slot type is
      # pinned by an annotation / return type / declared lvalue, so the value is
      # coerced to that type and never consumed by a width-sensitive operator at
      # the site. Because widening composes losslessly, removing the cast
      # preserves both type and behavior regardless of the exact slot type.
      #
      # Call arguments and aggregate field initializers are intentionally NOT
      # treated as slots: a generic parameter/field would let the removed cast
      # change type inference (and hence behavior), which is not sound without
      # resolving the callee/struct signature.
      def flag_redundant_widening_cast(value)
        return unless value.is_a?(AST::PrefixCast)
        return unless @sema_facts

        target_name = type_ref_name(value.target_type)
        return unless target_name

        inner_type = resolve_expr_type(value.expression)
        return unless inner_type.is_a?(Types::Primitive)
        return if inner_type.name == target_name # same-type handled elsewhere
        return unless implicit_cast_allowed?(inner_type, target_name)

        emit_redundant_cast(value, target_name, "implicit widening makes this cast redundant")
      end

      def same_resolved_type?(left, right)
        return true if left.equal?(right)

        left.to_s == right.to_s
      end

      def own_to_pointer_cast_redundant?(inner_type, cast_type)
        return false unless inner_type.is_a?(Types::GenericInstance) && inner_type.name == "own"
        return false unless cast_type.is_a?(Types::GenericInstance)
        return false unless %w[ptr const_ptr].include?(cast_type.name)
        return false unless inner_type.arguments.length == 1 && cast_type.arguments.length == 1

        inner_type.arguments.first.to_s == cast_type.arguments.first.to_s
      end

      def emit_redundant_cast(cast_expr, target_name, reason)
        line = cast_expr.respond_to?(:line) ? cast_expr.line : expression_line(cast_expr)
        column = cast_expr.respond_to?(:column) ? cast_expr.column : expression_column(cast_expr)

        @warnings << Warning.new(
          path: @path,
          line: line,
          column: column,
          length: expression_length(cast_expr),
          code: "redundant-cast",
          message: "#{reason}: #{target_name}<-",
          severity: :hint,
        )
      end

      def implicit_cast_allowed?(inner_type, target_name)
        return true if inner_type.name == target_name

        target = find_primitive_type(target_name)
        return false unless target
        return false unless target.is_a?(Types::Primitive)
        return false unless inner_type.fixed_width_integer? && target.fixed_width_integer?

        if inner_type.signed_integer? == target.signed_integer?
          return target.integer_width >= inner_type.integer_width
        end

        return false if inner_type.signed_integer?

        target.signed_integer? && target.integer_width > inner_type.integer_width
      end

      def find_primitive_type(name)
        return nil unless @sema_facts
        return nil unless @sema_facts.types

        @sema_facts.types[name]
      end

      def resolve_expr_type(expr)
        return nil unless @sema_facts
        return nil unless expr

        node_id = @sema_facts.ast.node_ids[expr.object_id]
        return nil unless node_id

        @sema_facts.resolved_expr_types[node_id]
      end

      def expression_literal_type_name(expr)
        case expr
        when AST::IntegerLiteral then "int"
        when AST::StringLiteral  then expr.cstring ? "cstr" : "str"
        when AST::FloatLiteral   then "float"
        when AST::BooleanLiteral then "bool"
        else nil
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

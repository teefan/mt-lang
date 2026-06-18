# frozen_string_literal: true

module MilkTea
  class Sema
    class Checker
      private

      def cfg_block_always_terminates?(statements)
        CFG::Termination.block_always_terminates?(statements, ignore_name: ->(_name) { false })
      end

      def check_statement(statement, scopes:, return_type:, allow_return: true)
        with_error_node(statement) do
          case statement
          when AST::ErrorBlockStmt
            if statement.header_type == :unsafe
              @unsafe_statement_lines << statement.line
              begin
                with_unsafe do
                  check_block(statement.body, scopes:, return_type:, allow_return:)
                end
              ensure
                @unsafe_statement_lines.pop
              end
            elsif statement.header_type == :if && statement.header_expression
              validate_consuming_foreign_expression!(statement.header_expression, scopes:, root_allowed: false)
              condition_type = infer_expression(statement.header_expression, scopes:, expected_type: @ctx.types.fetch("bool"))
              ensure_assignable!(condition_type, @ctx.types.fetch("bool"), "if condition must be bool, got #{condition_type}", expression: statement.header_expression, line: statement.line, column: statement.column)
              true_refinements = flow_refinements(statement.header_expression, truthy: true, scopes:)
              check_block(statement.body, scopes: scopes_with_refinements(scopes, true_refinements), return_type:, allow_return:)
              return flow_refinements(statement.header_expression, truthy: false, scopes:) if cfg_block_always_terminates?(statement.body)
            elsif statement.header_type == :while && statement.header_expression
              validate_consuming_foreign_expression!(statement.header_expression, scopes:, root_allowed: false)
              condition_type = infer_expression(statement.header_expression, scopes:, expected_type: @ctx.types.fetch("bool"))
              ensure_assignable!(condition_type, @ctx.types.fetch("bool"), "while condition must be bool, got #{condition_type}", expression: statement.header_expression, line: statement.line, column: statement.column)
              with_loop do
                body_scopes = scopes_with_refinements(scopes, flow_refinements(statement.header_expression, truthy: true, scopes:))
                check_block(statement.body, scopes: body_scopes, return_type:, allow_return:)
              end
            elsif statement.header_type == :for
              if statement.header_bindings && statement.header_iterables
                check_for_stmt(recovered_for_statement(statement), scopes:, return_type:, allow_return:)
              else
                with_loop do
                  check_block(statement.body, scopes:, return_type:, allow_return:)
                end
              end
            else
              check_block(statement.body, scopes:, return_type:, allow_return:)
            end
          when AST::LocalDecl
            check_local_decl(statement, scopes:, return_type:, allow_return:)
          when AST::ErrorStmt
            nil
          when AST::Assignment
            check_assignment(statement, scopes:)
          when AST::IfStmt
            if statement.inline
              check_inline_if_stmt(statement, scopes:, return_type:, allow_return:)
              next
            end

            false_refinements = {}
            branch_bodies_terminate = []
            statement.branches.each do |branch|
              branch_scopes = scopes_with_refinements(scopes, false_refinements)
              if branch.condition.is_a?(AST::ErrorExpr)
                check_block(branch.body, scopes: branch_scopes, return_type:, allow_return:)
                branch_bodies_terminate << cfg_block_always_terminates?(branch.body)
                next
              end

              validate_consuming_foreign_expression!(branch.condition, scopes: branch_scopes, root_allowed: false)
              condition_type = infer_expression(branch.condition, scopes: branch_scopes, expected_type: @ctx.types.fetch("bool"))
              ensure_assignable!(condition_type, @ctx.types.fetch("bool"), "if condition must be bool, got #{condition_type}", expression: branch.condition, line: branch.line, column: branch.column)
              true_refinements = merge_refinements(false_refinements, flow_refinements(branch.condition, truthy: true, scopes: branch_scopes))
              check_block(branch.body, scopes: scopes_with_refinements(scopes, true_refinements), return_type:, allow_return:)
              branch_bodies_terminate << cfg_block_always_terminates?(branch.body)
              false_refinements = merge_refinements(false_refinements, flow_refinements(branch.condition, truthy: false, scopes: branch_scopes))
            end
            check_block(statement.else_body, scopes: scopes_with_refinements(scopes, false_refinements), return_type:, allow_return:) if statement.else_body
            return false_refinements if statement.else_body.nil? && branch_bodies_terminate.all?
          when AST::MatchStmt
            if statement.inline
              check_inline_match_stmt(statement, scopes:, return_type:, allow_return:)
            else
              check_match_stmt(statement, scopes:, return_type:, allow_return:)
            end
          when AST::UnsafeStmt
            @unsafe_statement_lines << statement.line
            begin
              with_unsafe do
                check_block(statement.body, scopes:, return_type:, allow_return:)
              end
            ensure
              @unsafe_statement_lines.pop
            end
          when AST::StaticAssert
            check_static_assert(statement, scopes:)
          when AST::EmitStmt
            check_emit_stmt(statement)
          when AST::ForStmt
            if statement.inline
              check_inline_for_stmt(statement, scopes:, return_type:, allow_return:)
            else
              check_for_stmt(statement, scopes:, return_type:, allow_return:)
            end
          when AST::ParallelBlockStmt
            check_parallel_block_stmt(statement, scopes:, return_type:)
          when AST::GatherStmt
            check_gather_stmt(statement, scopes:)
          when AST::WhileStmt
            if statement.inline
              check_inline_while_stmt(statement, scopes:, return_type:, allow_return:)
            elsif statement.condition.is_a?(AST::ErrorExpr)
              with_loop do
                check_block(statement.body, scopes:, return_type:, allow_return:)
              end
            else
              validate_consuming_foreign_expression!(statement.condition, scopes:, root_allowed: false)
              condition_type = infer_expression(statement.condition, scopes:, expected_type: @ctx.types.fetch("bool"))
              ensure_assignable!(condition_type, @ctx.types.fetch("bool"), "while condition must be bool, got #{condition_type}", expression: statement.condition, line: statement.line, column: statement.column)
              with_loop do
                body_scopes = scopes_with_refinements(scopes, flow_refinements(statement.condition, truthy: true, scopes:))
                check_block(statement.body, scopes: body_scopes, return_type:, allow_return:)
              end
            end
          when AST::PassStmt
            nil
          when AST::BreakStmt
            raise_sema_error("break must be inside a loop") unless inside_loop?
          when AST::ContinueStmt
            raise_sema_error("continue must be inside a loop") unless inside_loop?
          when AST::ReturnStmt
            raise_sema_error("return is not allowed inside defer blocks") unless allow_return

            validate_consuming_foreign_expression!(statement.value, scopes:, root_allowed: false) if statement.value
            value_type = statement.value ? infer_expression(statement.value, scopes:, expected_type: return_type) : @ctx.types.fetch("void")
            ensure_assignable!(
              value_type,
              return_type,
              "return type mismatch: expected #{return_type}, got #{value_type}",
              expression: statement.value,
              contextual_int_to_float: contextual_int_to_float_target?(return_type),
              line: statement.line,
            )
          when AST::DeferStmt
            if statement.body
              with_loop_barrier do
                check_block(statement.body, scopes:, return_type:, allow_return: false)
              end
            else
              validate_consuming_foreign_expression!(statement.expression, scopes:, root_allowed: true)
              validate_hoistable_foreign_expression!(statement.expression, scopes:, root_hoistable: false)
              infer_expression(statement.expression, scopes:)
            end
          when AST::ExpressionStmt
            validate_consuming_foreign_expression!(statement.expression, scopes:, root_allowed: true)
            if statement.expression.is_a?(AST::UnaryOp) && statement.expression.operator == "?"
              infer_propagate_expression(statement.expression.operand, scopes:, allow_void_success: true)
            else
              infer_expression(statement.expression, scopes:)
            end
            return consuming_foreign_call_refinements(statement.expression, scopes:)
          when AST::WhenStmt
            check_when_stmt(statement, scopes:, return_type:, allow_return:)
          else
            raise_sema_error("unsupported statement #{statement.class.name}")
          end

          nil
        end
      end

      def check_local_decl(statement, scopes:, return_type:, allow_return:)
        if statement.destructure_bindings
          check_local_decl_destructure(statement, scopes:, return_type:, allow_return:)
          return
        end

        current_scope = current_actual_scope(scopes)
        discard_binding = statement.name == "_" || let_else_discard_binding_syntax?(statement)
        raise_sema_error("duplicate local #{statement.name}") if !discard_binding && current_scope.key?(statement.name)
        ensure_non_reserved_primitive_name!(statement.name, kind_label: "local", line: statement.line, column: statement.column) unless discard_binding

        declared_type = statement.type ? resolve_type_ref(statement.type) : nil
        if statement.value
          validate_consuming_foreign_expression!(statement.value, scopes:, root_allowed: false)
          inferred_type = if statement.value.is_a?(AST::ProcExpr)
                            with_proc_expression do
                              infer_expression(statement.value, scopes:, expected_type: declared_type)
                            end
                          else
                            infer_expression(statement.value, scopes:, expected_type: declared_type)
                          end
        else
          raise_sema_error("local #{statement.name} without initializer requires an explicit type") unless declared_type

          begin
            zero_initializable_type?(declared_type)
          rescue SemaError
            raise_sema_error("local #{statement.name} without initializer requires a zero-initializable type, got #{declared_type}")
          end

          inferred_type = declared_type
        end

        storage_type, final_type, const_value =
          if statement.else_body || statement.recovered_else
            check_local_decl_let_else(statement, scopes:, return_type:, allow_return:,
                                      discard_binding:, declared_type:, inferred_type:)
          else
            check_local_decl_plain(statement, scopes:, discard_binding:,
                                   declared_type:, inferred_type:)
          end

        if noncopyable_event_storage_type?(final_type) && !fresh_noncopyable_event_initializer?(statement.value, final_type, scopes:)
          raise_sema_error("local #{statement.name} cannot copy event storage type #{final_type}")
        end

        unless discard_binding
          current_scope[statement.name] = value_binding(
            name: statement.name,
            type: storage_type,
            mutable: statement.kind == :var,
            kind: statement.kind,
            flow_type: final_type,
            const_value:,
            id: @preassigned_local_binding_ids[statement.object_id],
          )
          record_declaration_binding(statement, current_scope[statement.name])
        end
      end

      def check_local_decl_destructure(statement, scopes:, return_type:, allow_return:)
        value_type = infer_expression(statement.value, scopes:)

        if statement.destructure_type_name
          check_local_decl_struct_destructure(statement, value_type, scopes:)
        elsif value_type.is_a?(Types::Tuple)
          check_local_decl_tuple_destructure(statement, value_type, scopes:)
        else
          raise_sema_error("destructure requires a tuple or struct, got #{value_type}")
        end
      end

      def check_local_decl_tuple_destructure(statement, value_type, scopes:)
        raise_sema_error("destructure pattern has #{statement.destructure_bindings.length} bindings but tuple has #{value_type.element_types.length} elements") unless statement.destructure_bindings.length == value_type.element_types.length

        current_scope = current_actual_scope(scopes)
        statement.destructure_bindings.each_with_index do |name, index|
          raise_sema_error("duplicate local #{name} in destructure") if current_scope.key?(name)
          ensure_non_reserved_primitive_name!(name, kind_label: "local", line: statement.line, column: statement.column)
          field_type = value_type.element_types[index]
          current_scope[name] = value_binding(
            name:,
            type: field_type,
            mutable: false,
            kind: :let,
            id: @preassigned_local_binding_ids[statement.object_id],
          )
          record_declaration_binding(statement, current_scope[name])
        end
      end

      def check_local_decl_struct_destructure(statement, value_type, scopes:)
        type_name = statement.destructure_type_name
        struct_type = if type_name.is_a?(Array)
                        resolve_qualified_type_name(type_name)
                      else
                        @ctx.types[type_name]
                      end
        display_name = type_name.is_a?(Array) ? type_name.join(".") : type_name
        raise_sema_error("unknown type #{display_name} for struct destructure") unless struct_type
        raise_sema_error("#{display_name} is not a struct") unless struct_type.is_a?(Types::Struct) || struct_type.is_a?(Types::Tuple)
        ensure_assignable!(value_type, struct_type, "cannot destructure #{value_type} as #{display_name}")

        fields = struct_type.fields
        raise_sema_error("destructure pattern has #{statement.destructure_bindings.length} bindings but #{display_name} has #{fields.length} fields") unless statement.destructure_bindings.length == fields.length

        current_scope = current_actual_scope(scopes)
        statement.destructure_bindings.each do |name|
          raise_sema_error("duplicate local #{name} in destructure") if current_scope.key?(name)
          raise_sema_error("unknown field #{display_name}.#{name}") unless fields.key?(name)
          ensure_non_reserved_primitive_name!(name, kind_label: "local", line: statement.line, column: statement.column)
          field_type = fields[name]
          current_scope[name] = value_binding(
            name:,
            type: field_type,
            mutable: false,
            kind: :let,
            id: @preassigned_local_binding_ids[statement.object_id],
          )
          record_declaration_binding(statement, current_scope[name])
        end
      end

      def resolve_qualified_type_name(parts)
        return nil unless parts.length >= 2

        if @ctx.imports.key?(parts.first)
          imported_module = @ctx.imports.fetch(parts.first)
          type = imported_module.types[parts.last]
          if imported_module.private_type?(parts.last)
            raise_sema_error("#{parts.first}.#{parts.last} is private to module #{imported_module.name}")
          end
          raise_sema_error("unknown type #{parts.join('.')} for struct destructure") unless type
          return type
        end

        parent_type = @ctx.types[parts.first]
        if parent_type.respond_to?(:nested_types) && parent_type.nested_types.key?(parts.last)
          return parent_type.nested_types[parts.last]
        end

        raise_sema_error("unknown type #{parts.join('.')} for struct destructure")
      end

      def check_local_decl_let_else(statement, scopes:, return_type:, allow_return:,
                                      discard_binding:, declared_type:, inferred_type:)
        success_type = let_else_success_type(inferred_type)
        error_type = let_else_error_type(inferred_type)

        if statement.recovered_else
          success_type ||= declared_type || @error_type
          error_type ||= @error_type if statement.else_binding
        else
          raise_sema_error("let-else initializer for #{statement.name} must be nullable, Option[T], or Result[T, E], got #{inferred_type}") unless success_type
        end

        if discard_binding && declared_type
          raise_sema_error("let-else discard binding _ cannot have a type annotation")
        end

        if discard_binding && statement.kind == :var
          raise_sema_error("var-else discard binding _ is not allowed")
        end

        if statement.else_binding && !error_type
          raise_sema_error("let-else error binding for #{statement.name} requires Result[T, E], got #{inferred_type}")
        end

        if declared_type && let_else_source_type?(declared_type)
          raise_sema_error("let-else type annotation for #{statement.name} must be the success type, got #{declared_type}")
        end

        if declared_type
          validate_local_ref_type!(declared_type, statement.name)
          validate_local_proc_type!(declared_type, statement.name, initializer: statement.value)
          ensure_assignable!(
            success_type, declared_type,
            "cannot assign #{success_type} to #{statement.name}: expected #{declared_type}",
            expression: statement.value, scopes:,
            contextual_int_to_float: contextual_int_to_float_target?(declared_type),
            line: statement.line, column: statement.column,
          )
          final_type = declared_type
        else
          raise_sema_error("cannot bind void result to #{statement.name}") if success_type.void? && !discard_binding
          final_type = success_type
        end

        unless discard_binding
          validate_local_ref_type!(final_type, statement.name)
          validate_local_proc_type!(final_type, statement.name, initializer: statement.value)
        end

        else_scopes = scopes
        if statement.else_binding
          ensure_non_reserved_primitive_name!(statement.else_binding.name, kind_label: "let-else error binding", line: statement.else_binding.line, column: statement.else_binding.column)
          else_binding = value_binding(
            name: statement.else_binding.name, type: error_type, mutable: false, kind: :let,
            id: preassigned_local_binding_id_for(statement.else_binding),
          )
          record_declaration_binding(statement.else_binding, else_binding)
          else_scopes = scopes + [{ statement.else_binding.name => else_binding }]
        end

        check_block(statement.else_body, scopes: else_scopes, return_type:, allow_return:) if statement.else_body
        if statement.else_body && !statement.recovered_else
          terminator = if inside_loop?
                         CFG::Termination.block_always_terminates_in_loop?(statement.else_body)
                       else
                         cfg_block_always_terminates?(statement.else_body)
                       end
          unless terminator
            raise_sema_error("else block for #{statement.name} must exit control flow at line #{statement.line}")
          end
        end

        storage_type = statement.kind == :var ? final_type : inferred_type
        [storage_type, final_type, nil]
      end

      def check_local_decl_plain(statement, scopes:, discard_binding:, declared_type:, inferred_type:)
        if declared_type
          validate_local_ref_type!(declared_type, statement.name)
          validate_local_proc_type!(declared_type, statement.name, initializer: statement.value)
          ensure_assignable!(
            inferred_type, declared_type,
            "cannot assign #{inferred_type} to #{statement.name}: expected #{declared_type}",
            expression: statement.value, scopes:,
            contextual_int_to_float: contextual_int_to_float_target?(declared_type),
            line: statement.line, column: statement.column,
          )
          final_type = declared_type
        else
          raise_sema_error("cannot infer type for #{statement.name} from null") if inferred_type.is_a?(Types::Null)
          raise_sema_error("cannot bind void result to #{statement.name}") if inferred_type.void?
          final_type = inferred_type
        end

        validate_local_ref_type!(final_type, statement.name)
        validate_local_proc_type!(final_type, statement.name, initializer: statement.value)

        const_value = statement.kind == :let && statement.value ? evaluate_compile_time_const_value(statement.value, scopes:) : nil
        [final_type, final_type, const_value]
      end

      def check_assignment(statement, scopes:)
        if statement.operator == "=" &&
           statement.target.is_a?(AST::IndexAccess) &&
           statement.target.index.is_a?(AST::RangeExpr)
          return check_range_index_assignment(statement, scopes:)
        end

        target_type = infer_lvalue(statement.target, scopes:)
        raise_sema_error("cannot assign to non-copyable event storage type #{target_type}") if noncopyable_event_storage_type?(target_type)

        validate_consuming_foreign_expression!(statement.value, scopes:, root_allowed: false)
        value_type = infer_expression(statement.value, scopes:, expected_type: target_type)

        case statement.operator
        when "="
          ensure_assignable!(
            value_type,
            target_type,
            "cannot assign #{value_type} to #{target_type}",
            expression: statement.value,
            external_numeric: external_numeric_assignment_target?(statement.target, scopes:),
            contextual_int_to_float: contextual_int_to_float_target?(target_type),
            line: statement.line, column: statement.column,
          )
        when "+=", "-=", "*=", "/="
          raise_sema_error("operator #{statement.operator} requires matching numeric types, got #{target_type} and #{value_type}") unless target_type.numeric? && value_type.numeric?

          ensure_assignable!(
            value_type,
            target_type,
            "operator #{statement.operator} requires matching numeric types, got #{target_type} and #{value_type}",
            expression: statement.value,
            contextual_int_to_float: contextual_int_to_float_target?(target_type),
            line: statement.line, column: statement.column,
          )
        when "%="
          unless common_integer_type(target_type, value_type) == target_type
            raise_sema_error("operator #{statement.operator} requires compatible integer types, got #{target_type} and #{value_type}")
          end
        when "&=", "|=", "^="
          unless target_type == value_type && bitwise_type?(target_type)
            raise_sema_error("operator #{statement.operator} requires matching integer or flags types, got #{target_type} and #{value_type}")
          end
        when "<<=", ">>="
          unless target_type.is_a?(Types::Primitive) && target_type.integer? && value_type.is_a?(Types::Primitive) && value_type.integer?
            raise_sema_error("operator #{statement.operator} requires integer operands, got #{target_type} and #{value_type}")
          end
        else
          raise_sema_error("unsupported assignment operator #{statement.operator}")
        end
      end

      def check_range_index_assignment(statement, scopes:)
        target = statement.target
        range = target.index

        raise_sema_error("range index assignment requires an expression list on the right-hand side") unless statement.value.is_a?(AST::ExpressionList)
        raise_sema_error("range index assignment requires integer literal bounds") unless range.start_expr.is_a?(AST::IntegerLiteral) && range.end_expr.is_a?(AST::IntegerLiteral)

        start_val = range.start_expr.value
        end_val = range.end_expr.value
        raise_sema_error("range start must be less than end in range index assignment") unless start_val < end_val

        count = end_val - start_val
        raise_sema_error("range index assignment: range [#{start_val}..#{end_val}) spans #{count} elements but tuple has #{statement.value.elements.length}") unless statement.value.elements.length == count

        receiver_type = infer_lvalue_receiver(
          target.receiver,
          scopes:,
          allow_pointer_identifier: true,
          require_mutable_pointer: true,
          allow_span_param_identifier: true,
        )
        element_type = infer_index_result_type(receiver_type, @ctx.types.fetch("ptr_uint"))

        statement.value.elements.each_with_index do |elem, i|
          elem = elem.is_a?(AST::Argument) ? elem.value : elem
          validate_consuming_foreign_expression!(elem, scopes:, root_allowed: false)
          elem_type = infer_expression(elem, scopes:, expected_type: element_type)
          ensure_assignable!(
            elem_type,
            element_type,
            "range index assignment element #{i}: cannot assign #{elem_type} to #{element_type}",
            expression: elem,
            contextual_int_to_float: contextual_int_to_float_target?(element_type),
            line: statement.line,
          )
        end
      end

      def check_match_stmt(statement, scopes:, return_type:, allow_return:)
        validate_consuming_foreign_expression!(statement.expression, scopes:, root_allowed: false)
        scrutinee_type = infer_expression(statement.expression, scopes:)
        if error_type?(scrutinee_type)
          check_recovered_match_stmt(statement, scopes:, return_type:, allow_return:)
        elsif scrutinee_type.is_a?(Types::Enum)
          check_enum_match_stmt(statement, scrutinee_type, scopes:, return_type:, allow_return:)
        elsif scrutinee_type.is_a?(Types::Variant)
          check_variant_match_stmt(statement, scrutinee_type, scopes:, return_type:, allow_return:)
        elsif integer_type?(scrutinee_type)
          check_integer_match_stmt(statement, scrutinee_type, scopes:, return_type:, allow_return:)
        else
          raise_sema_error("match requires an enum, variant, or integer scrutinee, got #{scrutinee_type}")
        end
      end

      def check_enum_match_stmt(statement, scrutinee_type, scopes:, return_type:, allow_return:)
        each_enum_match_arm(statement, scrutinee_type, scopes:) do |arm, arm_scopes|
          check_block(arm.body, scopes: arm_scopes, return_type:, allow_return:)
        end
      end

      def each_enum_match_arm(statement, scrutinee_type, scopes:)
        covered_members = {}
        wildcard_seen = false
        statement.arms.each do |arm|
          if arm.pattern.is_a?(AST::ErrorExpr)
            yield arm, scopes
            next
          end

          if wildcard_pattern?(arm.pattern)
            raise_sema_error("duplicate wildcard arm in match") if wildcard_seen
            wildcard_seen = true
            yield arm, scopes
            next
          end
          validate_consuming_foreign_expression!(arm.pattern, scopes:, root_allowed: false)
          validate_hoistable_foreign_expression!(arm.pattern, scopes:, root_hoistable: false)
          pattern_type = infer_expression(arm.pattern, scopes:, expected_type: scrutinee_type)
          ensure_assignable!(pattern_type, scrutinee_type, "match arm expects #{scrutinee_type}, got #{pattern_type}")

          member_name = match_member_name(arm.pattern, scrutinee_type)
          raise_sema_error("match arm must be an enum member of #{scrutinee_type}") unless member_name
          raise_sema_error("duplicate match arm #{scrutinee_type}.#{member_name}") if covered_members.key?(member_name)

          covered_members[member_name] = true
          yield arm, scopes
        end

        return if wildcard_seen

        missing_members = scrutinee_type.members - covered_members.keys
        return if missing_members.empty?

        raise_sema_error("match on #{scrutinee_type} is missing cases: #{missing_members.join(', ')}")
      end

      def check_integer_match_stmt(statement, scrutinee_type, scopes:, return_type:, allow_return:)
        has_wildcard = statement.arms.any? { |arm| wildcard_pattern?(arm.pattern) }
        raise_sema_error("match on integer type #{scrutinee_type} requires a wildcard arm (_:)") unless has_wildcard

        covered_values = {}
        wildcard_seen = false
        statement.arms.each do |arm|
          if arm.pattern.is_a?(AST::ErrorExpr)
            check_recovered_match_arm_body(arm, scopes:, return_type:, allow_return:)
            next
          end

          if wildcard_pattern?(arm.pattern)
            raise_sema_error("duplicate wildcard arm in match") if wildcard_seen
            wildcard_seen = true
            check_block(arm.body, scopes:, return_type:, allow_return:)
            next
          end
          unless arm.pattern.is_a?(AST::IntegerLiteral)
            raise_sema_error("match arm for integer scrutinee must be an integer literal or _, got #{arm.pattern.class.name}")
          end
          value = arm.pattern.value
          raise_sema_error("duplicate match arm value #{value}") if covered_values.key?(value)
          covered_values[value] = true
          check_block(arm.body, scopes:, return_type:, allow_return:)
        end
      end

      def wildcard_pattern?(expression)
        expression.is_a?(AST::Identifier) && expression.name == "_"
      end

      def let_else_discard_binding_syntax?(statement)
        statement.is_a?(AST::LocalDecl) && (statement.else_body || statement.recovered_else) && statement.name == "_"
      end

      def let_else_source_type?(type)
        type.is_a?(Types::Nullable) || result_let_else_type?(type) || option_let_else_type?(type)
      end

      def let_else_success_type(type)
        return @error_type if error_type?(type)
        return type.base if type.is_a?(Types::Nullable)
        return type.arm("some").fetch("value") if option_let_else_type?(type)
        return unless result_let_else_type?(type)

        type.arm("success").fetch("value")
      end

      def let_else_error_type(type)
        return @error_type if error_type?(type)
        return unless result_let_else_type?(type)

        type.arm("failure").fetch("error")
      end

      def option_let_else_type?(type)
        return false unless type.is_a?(Types::Variant)
        return false unless type.module_name.nil? && type.name == "Option"

        some_fields = type.arm("some")
        none_fields = type.arm("none")
        some_fields && some_fields.length == 1 && some_fields.key?("value") &&
          none_fields && none_fields.empty?
      end

      def result_let_else_type?(type)
        return false unless type.is_a?(Types::Variant)
        return false unless type.module_name.nil? && type.name == "Result"

        success_fields = type.arm("success")
        failure_fields = type.arm("failure")
        success_fields && success_fields.length == 1 && success_fields.key?("value") &&
          failure_fields && failure_fields.length == 1 && failure_fields.key?("error")
      end

      def check_variant_match_stmt(statement, scrutinee_type, scopes:, return_type:, allow_return:)
        each_variant_match_arm(statement, scrutinee_type, scopes:) do |arm, arm_scopes|
          check_block(arm.body, scopes: arm_scopes, return_type:, allow_return:)
        end
      end

      def each_variant_match_arm(statement, scrutinee_type, scopes:)
        covered_arms = {}
        wildcard_seen = false
        equality_cover_table = {}
        statement.arms.each do |arm|
          if arm.pattern.is_a?(AST::ErrorExpr)
            yield arm, scopes
            next
          end

          if wildcard_pattern?(arm.pattern)
            raise_sema_error("duplicate wildcard arm in match") if wildcard_seen
            wildcard_seen = true
            yield arm, scopes
            next
          end
          validate_consuming_foreign_expression!(arm.pattern, scopes:, root_allowed: false)
          validate_hoistable_foreign_expression!(arm.pattern, scopes:, root_hoistable: false)

          arm_name = variant_match_arm_name(arm.pattern, scrutinee_type)
          raise_sema_error("match arm must be a variant arm of #{scrutinee_type}") unless arm_name

          arm_scopes = scopes.dup
          has_guards = false
          equality_cover = {}

          if arm.pattern.is_a?(AST::Call) && !arm.pattern.arguments.empty?
            has_guards, equality_cover = check_struct_match_pattern(arm.pattern.arguments, arm_name, scrutinee_type, arm_scopes, scopes:, arm:)
          end

          unless has_guards
            raise_sema_error("duplicate match arm #{scrutinee_type}.#{arm_name}") if covered_arms.key?(arm_name)
            covered_arms[arm_name] = true
          else
            equality_cover_table[arm_name] = merge_equality_cover(equality_cover_table[arm_name], equality_cover)
          end

          if arm.binding_name
            ensure_non_reserved_primitive_name!(arm.binding_name, kind_label: "match binding", line: arm.binding_line, column: arm.binding_column)
            fields = scrutinee_type.arm(arm_name)
            if fields.nil? || fields.empty?
              raise_sema_error("variant arm #{scrutinee_type}.#{arm_name} has no payload; 'as' binding is not allowed")
            end

            payload_type = Types::VariantArmPayload.new(scrutinee_type, arm_name, fields)
            binding = value_binding(
              name: arm.binding_name,
              type: payload_type,
              mutable: true,
              kind: :local,
              id: @preassigned_local_binding_ids[arm.object_id],
            )
            arm_scopes = arm_scopes + [{ arm.binding_name => binding }]
            record_declaration_binding(arm, binding)
          end
          yield arm, arm_scopes
        end

        equality_cover_table.each do |arm_name, field_covers|
          next if covered_arms.key?(arm_name)
          payload_fields = scrutinee_type.arm(arm_name)
          next unless payload_fields
          covered = field_covers.any? do |field_name, covered_members|
            field_type = payload_fields[field_name]
            next unless field_type.is_a?(Types::Enum)
            all_members = field_type.members
            all_members.any? && (all_members - covered_members).empty?
          end
          covered_arms[arm_name] = true if covered
        end

        return if wildcard_seen

        missing_arms = scrutinee_type.arm_names - covered_arms.keys
        return if missing_arms.empty?

        raise_sema_error("match on #{scrutinee_type} is missing cases: #{missing_arms.join(', ')}")
      end

      def merge_equality_cover(existing, new_cover)
        return new_cover unless existing
        merged = existing.dup
        new_cover.each do |field, members|
          merged[field] = (merged[field] || []) + members
        end
        merged
      end

      def check_recovered_match_stmt(statement, scopes:, return_type:, allow_return:)
        statement.arms.each do |arm|
          check_recovered_match_arm_body(arm, scopes:, return_type:, allow_return:)
        end
      end

      def check_recovered_match_arm_body(arm, scopes:, return_type:, allow_return:)
        arm_scopes = scopes.dup
        if arm.binding_name
          ensure_non_reserved_primitive_name!(arm.binding_name, kind_label: "match binding", line: arm.binding_line, column: arm.binding_column)
          binding = value_binding(
            name: arm.binding_name,
            type: @error_type,
            mutable: true,
            kind: :local,
            id: @preassigned_local_binding_ids.fetch(arm.object_id),
          )
          arm_scopes = arm_scopes + [{ arm.binding_name => binding }]
          record_declaration_binding(arm, binding)
        end
        check_block(arm.body, scopes: arm_scopes, return_type:, allow_return:)
      end

      def variant_match_arm_name(pattern, scrutinee_type)
        # Pattern must be `TypeName.arm_name` or `module.TypeName.arm_name`
        # For struct patterns, the pattern is Call(MemberAccess(...), args) — unwrap the callee
        callee = case pattern
                 when AST::Call
                   pattern.callee
                 else
                   pattern
                 end
        return nil unless callee.is_a?(AST::MemberAccess)

        member = callee.member
        return nil unless scrutinee_type.arm_names.include?(member)

        # Verify the receiver resolves to the scrutinee variant type
        receiver_type = resolve_type_expression(callee.receiver)
        return member if receiver_type == scrutinee_type

        if scrutinee_type.is_a?(Types::VariantInstance) && receiver_type.is_a?(Types::GenericVariantDefinition)
          return member if receiver_type == scrutinee_type.definition
        end

        return nil unless scrutinee_type.is_a?(Types::VariantInstance) && receiver_type.is_a?(Types::Variant)
        return nil unless receiver_type.name == scrutinee_type.name && receiver_type.module_name == scrutinee_type.module_name

        member
      end

      def check_struct_match_pattern(arguments, arm_name, scrutinee_type, arm_scopes, scopes:, arm:)
        payload_fields = scrutinee_type.arm(arm_name)
        raise_sema_error("variant arm #{scrutinee_type}.#{arm_name} has no payload fields for struct pattern") if payload_fields.nil? || payload_fields.empty?

        # Nested struct detection: if arm has exactly one field whose type is a struct,
        # auto-destructure through to the struct's own fields, but only when none of
        # the arguments reference the arm's own field name directly.
        if payload_fields.size == 1
          native_field = payload_fields.keys.first
          has_native_reference = arguments.any? do |arg|
            name = arg.name || (arg.value.is_a?(AST::Identifier) ? arg.value.name : nil)
            name == native_field
          end
          unless has_native_reference
            single_field_type = payload_fields.values.first
            payload_fields = single_field_type.fields if single_field_type.is_a?(Types::Struct)
          end
        end

        has_guards = false
        seen_fields = {}
        equality_cover = {}

        arguments.each do |arg|
          if arg.name
            # Equality pattern: kind = Kind.boss
            field_name = arg.name
            raise_sema_error("unknown field #{scrutinee_type}.#{arm_name}.#{field_name}") unless payload_fields.key?(field_name)
            raise_sema_error("duplicate field #{field_name} in struct pattern") if seen_fields.key?(field_name)
            seen_fields[field_name] = true
            has_guards = true

            field_type = payload_fields[field_name]
            actual_type = infer_expression(arg.value, scopes:, expected_type: field_type)
            ensure_assignable!(actual_type, field_type, "field #{field_name} expects #{field_type}, got #{actual_type}", expression: arg.value)

            if field_type.is_a?(Types::Enum) && arg.value.is_a?(AST::MemberAccess)
              equality_cover[field_name] = [] unless equality_cover.key?(field_name)
              equality_cover[field_name] << arg.value.member
            end
          elsif arg.value.is_a?(AST::Identifier)
            # Binding: position
            field_name = arg.value.name
            raise_sema_error("unknown field #{scrutinee_type}.#{arm_name}.#{field_name}") unless payload_fields.key?(field_name)
            raise_sema_error("duplicate field #{field_name} in struct pattern") if seen_fields.key?(field_name)
            seen_fields[field_name] = true

            field_type = payload_fields[field_name]
            binding = value_binding(
              name: field_name,
              type: field_type,
              mutable: false,
              kind: :local,
              id: @preassigned_local_binding_ids[arg.object_id],
            )
            arm_scopes.last[field_name] = binding
          elsif arg.value.is_a?(AST::BinaryOp) && arg.value.left.is_a?(AST::Identifier)
            # Guard: hp > 0
            field_name = arg.value.left.name
            raise_sema_error("unknown field #{scrutinee_type}.#{arm_name}.#{field_name}") unless payload_fields.key?(field_name)
            raise_sema_error("duplicate field #{field_name} in struct pattern") if seen_fields.key?(field_name)
            seen_fields[field_name] = true
            has_guards = true

            field_type = payload_fields[field_name]
            comparison_operators = ["==", "!=", "<", "<=", ">", ">="]
            unless comparison_operators.include?(arg.value.operator)
              raise_sema_error("unsupported guard operator '#{arg.value.operator}' in struct pattern; use ==, !=, <, <=, >, or >=", arg.value)
            end

            operand_type = infer_expression(arg.value.right, scopes:, expected_type: field_type)
            ensure_assignable!(operand_type, field_type, "guard comparison expects #{field_type}, got #{operand_type}", expression: arg.value.right)
          else
            raise_sema_error("invalid field pattern in struct match arm; expected field name, comparison, or equality", expression: arg.value)
          end
        end

        [has_guards, equality_cover]
      end

      def check_for_stmt(statement, scopes:, return_type:, allow_return:)
        if statement.threaded
          check_threaded_for_stmt(statement, scopes:, return_type:, allow_return:)
          return
        end

        statement.iterables.each do |iterable|
          validate_consuming_foreign_expression!(iterable, scopes:, root_allowed: false)
        end

        raise_sema_error("for loop binder count must match iterable count") unless statement.bindings.length == statement.iterables.length

        binding_infos = if statement.parallel?
                          check_parallel_for_bindings(statement, scopes:)
                        else
                          iterable_type = nil
                          loop_type = if range_expr?(statement.iterable)
                                        check_range_expr_loop(statement.iterable, scopes:)
                                      else
                                        iterable_type = infer_expression(statement.iterable, scopes:)
                                        collection_loop_type(iterable_type) || iterator_loop_type(iterable_type)
                                      end

                          raise_sema_error("for loop expects start..stop, array[T, N], span[T], or an iterable with iter()/next()") unless loop_type

                          binding_type = if iterable_type
                                           collection_loop_binding_type(iterable_type, loop_type) || loop_type
                                         else
                                           loop_type
                                         end
                          [{ binding: statement.binding, type: binding_type }]
                        end

        with_nested_scope(scopes) do |loop_scopes|
          binding_infos.each do |entry|
            binding = entry[:binding]
            ensure_non_reserved_primitive_name!(binding.name, kind_label: "for binding", line: binding.line, column: binding.column)
            current_actual_scope(loop_scopes)[binding.name] = value_binding(
              name: binding.name,
              type: entry[:type],
              mutable: false,
              kind: :let,
              id: @preassigned_local_binding_ids[binding.object_id],
            )
            record_declaration_binding(binding, current_actual_scope(loop_scopes)[binding.name])
          end
          with_loop do
            check_block(statement.body, scopes: loop_scopes, return_type:, allow_return:)
          end
        end
      end

      def check_parallel_for_bindings(statement, scopes:)
        raise_sema_error("parallel for loops currently support arrays and spans only") if statement.iterables.any? { |iterable| range_expr?(iterable) }

        iterable_types = statement.iterables.map { |iterable| infer_expression(iterable, scopes:) }
        binding_infos = iterable_types.each_with_index.map do |iterable_type, index|
          loop_type = collection_loop_type(iterable_type)
          raise_sema_error("parallel for loops expect arrays or spans for each iterable") unless loop_type

          binding_type = collection_loop_binding_type(iterable_type, loop_type) || loop_type
          { binding: statement.bindings[index], iterable_type:, type: binding_type }
        end

        ensure_parallel_for_static_lengths_match!(binding_infos.map { |entry| entry[:iterable_type] })
        binding_infos
      end

      def ensure_parallel_for_static_lengths_match!(iterable_types)
        lengths = iterable_types.filter_map { |iterable_type| array_type?(iterable_type) ? array_length(iterable_type) : nil }
        return if lengths.empty? || lengths.all? { |length| length == lengths.first }

        raise_sema_error("parallel for iterables must have matching lengths")
      end

      def check_threaded_for_stmt(statement, scopes:, return_type:, allow_return:)
        @uses_parallel_for = true
        raise_sema_error("parallel for requires a range expression (start..end)") unless range_expr?(statement.iterable)

        loop_type = check_range_expr_loop(statement.iterable, scopes:)
        validate_threaded_for_body!(statement.body)

        with_nested_scope(scopes) do |loop_scopes|
          binding = statement.binding
          ensure_non_reserved_primitive_name!(binding.name, kind_label: "for binding", line: binding.line, column: binding.column)
          current_actual_scope(loop_scopes)[binding.name] = value_binding(
            name: binding.name,
            type: loop_type,
            mutable: false,
            kind: :let,
            id: @preassigned_local_binding_ids[binding.object_id],
          )
          record_declaration_binding(binding, current_actual_scope(loop_scopes)[binding.name])
          check_block(statement.body, scopes: loop_scopes, return_type:, allow_return: false)
        end
      end

      def validate_threaded_for_body!(body)
        body.each { |stmt| validate_threaded_for_statement!(stmt) }
      end

      def validate_threaded_for_statement!(stmt)
        case stmt
        when AST::BreakStmt
          raise_sema_error("break is not allowed inside parallel for", line: stmt.line, column: stmt.column)
        when AST::ContinueStmt
          raise_sema_error("continue is not allowed inside parallel for", line: stmt.line, column: stmt.column)
        when AST::ReturnStmt
          raise_sema_error("return is not allowed inside parallel for", line: stmt.line, column: stmt.column)
        when AST::DeferStmt
          raise_sema_error("defer is not allowed inside parallel for", line: stmt.line, column: stmt.column)
        when AST::AwaitExpr
          raise_sema_error("await is not allowed inside parallel for", line: stmt.line, column: stmt.column)
        when AST::IfStmt
          validate_threaded_for_body!(stmt.then_body)
          stmt.else_if_clauses&.each { |clause| validate_threaded_for_body!(clause.body) }
          validate_threaded_for_body!(stmt.else_body) if stmt.else_body
        when AST::WhileStmt
          validate_threaded_for_body!(stmt.body)
        when AST::ForStmt
          raise_sema_error("nested for loops are not allowed inside parallel for", line: stmt.line, column: stmt.column) if stmt.threaded
          validate_threaded_for_body!(stmt.body)
        when AST::MatchStmt
          stmt.arms&.each { |arm| validate_threaded_for_body!(arm.body) }
        when AST::UnsafeStmt
          validate_threaded_for_body!(stmt.body) if stmt.body.is_a?(Array)
        end
      end

      def check_parallel_block_stmt(statement, scopes:, return_type:)
        @uses_parallel_for = true
        raise_sema_error("parallel block must contain at least two statements", line: statement.line, column: statement.column) if statement.bodies.length < 2

        statement.bodies.each do |body|
          validate_threaded_for_body!(body)
          check_block(body, scopes:, return_type:, allow_return: false)
        end
      end

      def check_gather_stmt(statement, scopes:)
        raise_sema_error("gather requires at least one handle", line: statement.line, column: statement.column) if statement.handles.empty?

        statement.handles.each do |handle|
          handle_type = infer_expression(handle, scopes:)
          raise_sema_error("gather expects Handle, got #{handle_type}", line: statement.line, column: statement.column) unless handle_type.is_a?(Types::Handle)
        end
      end


      def check_static_assert(statement, scopes:)
        validate_consuming_foreign_expression!(statement.condition, scopes:, root_allowed: false)
        validate_consuming_foreign_expression!(statement.message, scopes:, root_allowed: false)
        validate_hoistable_foreign_expression!(statement.condition, scopes:, root_hoistable: false)
        validate_hoistable_foreign_expression!(statement.message, scopes:, root_hoistable: false)
        condition_type = infer_expression(statement.condition, scopes:, expected_type: @ctx.types.fetch("bool"))
        ensure_assignable!(condition_type, @ctx.types.fetch("bool"), "static_assert condition must be bool, got #{condition_type}")
        condition_value = evaluate_compile_time_const_value(statement.condition, scopes:)
        raise_sema_error("static_assert condition must be a compile-time bool constant") unless condition_value == true || condition_value == false
        raise_sema_error("static_assert message must be a string literal") unless statement.message.is_a?(AST::StringLiteral)

        message_type = infer_expression(statement.message, scopes:, expected_type: @ctx.types.fetch("str"))
        return if string_like_type?(message_type)

        raise_sema_error("static_assert message must be str or cstr, got #{message_type}")
      end

      def check_emit_stmt(statement)
        raise_sema_error("emit is only allowed inside const function or inline blocks") unless @compile_time_depth.positive?
      end

      def check_range_expr_loop(expression, scopes:)
        start_type = infer_expression(expression.start_expr, scopes:)
        stop_type = infer_expression(expression.end_expr, scopes:)

        unless integer_type?(start_type) && integer_type?(stop_type)
          raise_sema_error("range bounds must be integer types, got #{start_type} and #{stop_type}")
        end

        if start_type != stop_type
          if expression.start_expr.is_a?(AST::IntegerLiteral)
            start_type = infer_expression(expression.start_expr, scopes:, expected_type: stop_type)
          elsif expression.end_expr.is_a?(AST::IntegerLiteral)
            stop_type = infer_expression(expression.end_expr, scopes:, expected_type: start_type)
          end
        end

        raise_sema_error("range bounds must use matching integer types, got #{start_type} and #{stop_type}") unless start_type == stop_type

        start_type
      end

      def when_chosen_body(decl)
        discriminant_value = evaluate_compile_time_const_value(decl.discriminant, scopes: [])
        return nil if discriminant_value.nil?

        chosen_branch = decl.branches.find do |branch|
          pattern_value = evaluate_compile_time_const_value(branch.pattern, scopes: [])
          discriminant_value == pattern_value
        end

        chosen_branch&.body || decl.else_body
      end

      def check_when_stmt(statement, scopes:, return_type:, allow_return:)
        discriminant_value = evaluate_when_discriminant(statement.discriminant)

        chosen_branch = statement.branches.find do |branch|
          pattern_value = evaluate_compile_time_const_value(branch.pattern, scopes:)
          discriminant_value == pattern_value
        end

        if chosen_branch
          check_block(chosen_branch.body, scopes:, return_type:, allow_return:)
        elsif statement.else_body
          check_block(statement.else_body, scopes:, return_type:, allow_return:)
        else
          raise_sema_error("when discriminant value #{discriminant_value} does not match any branch and no else is provided")
        end
      end

      def evaluate_when_discriminant(expression)
        value = evaluate_compile_time_const_value(expression, scopes: [])
        raise_sema_error("when discriminant must be a compile-time constant", expression) if value.nil?

        value
      end

      def check_inline_for_stmt(statement, scopes:, return_type:, allow_return:)
        iterable = evaluate_compile_time_const_value(statement.iterables.first, scopes:)
        raise_sema_error("inline for iterable must be a compile-time constant") unless iterable.is_a?(Array)
        raise_sema_error("inline for iterable is empty") if iterable.empty?

        loop_var_name = statement.bindings.first.name
        element = iterable.first
        element_type = if element.is_a?(Types::FieldHandle)
                         builtin_field_handle_type
                       elsif element.is_a?(Types::CallableHandle)
                         builtin_callable_handle_type
                       elsif element.is_a?(Types::AttributeHandle)
                         builtin_attribute_handle_type
                       elsif element.is_a?(Types::MemberHandle)
                         builtin_member_handle_type
                       elsif element.is_a?(Types::StructHandle)
                         builtin_struct_handle_type
                       else
                         @ctx.types.fetch("int")
                       end

        with_nested_scope(scopes) do |loop_scopes|
          ensure_non_reserved_primitive_name!(loop_var_name, kind_label: "for binding", line: statement.bindings.first.line, column: statement.bindings.first.column)
          current_actual_scope(loop_scopes)[loop_var_name] = value_binding(
            name: loop_var_name,
            type: element_type,
            mutable: false,
            kind: :let,
            id: @preassigned_local_binding_ids[statement.bindings.first.object_id],
            const_value: element,
          )
          with_loop do
            with_compile_time do
              check_block(statement.body, scopes: loop_scopes, return_type:, allow_return:)
            end
          end
        end
      end

      def check_inline_while_stmt(statement, scopes:, return_type:, allow_return:)
        condition = evaluate_compile_time_const_value(statement.condition, scopes:)
        raise_sema_error("inline while condition must be a compile-time constant") if condition.nil?

        with_loop do
          with_compile_time do
            check_block(statement.body, scopes:, return_type:, allow_return:)
          end
        end
      end

      def check_inline_if_stmt(statement, scopes:, return_type:, allow_return:)
        chosen_branch = statement.branches.find do |branch|
          condition_value = evaluate_compile_time_const_value(branch.condition, scopes:)
          raise_sema_error("inline if condition must be a compile-time constant") if condition_value.nil?
          raise_sema_error("inline if condition must be bool") unless condition_value == true || condition_value == false
          condition_value
        end

        if chosen_branch
          with_compile_time do
            check_block(chosen_branch.body, scopes:, return_type:, allow_return:)
          end
        elsif statement.else_body
          with_compile_time do
            check_block(statement.else_body, scopes:, return_type:, allow_return:)
          end
        end
      end

      def check_inline_match_stmt(statement, scopes:, return_type:, allow_return:)
        scrutinee = evaluate_compile_time_const_value(statement.expression, scopes:)
        raise_sema_error("inline match scrutinee must be a compile-time constant") if scrutinee.nil?

        chosen_arm = statement.arms.find do |arm|
          pattern_value = evaluate_compile_time_const_value(arm.pattern, scopes:)
          scrutinee == pattern_value
        end

        if chosen_arm
          with_compile_time do
            check_block(chosen_arm.body, scopes:, return_type:, allow_return:)
          end
        end
      end

    end
  end
end

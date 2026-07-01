# frozen_string_literal: true

module MilkTea
  class CBackend
    module Statements
      private

          def emit_statement_sequence(statements, level, function:, used_labels:, loop_continue_label: nil, loop_break_label: nil)
            statements.each_with_index.flat_map do |statement, index|
              emit_statement(
                statement,
                level,
                function:,
                used_labels:,
                loop_continue_label:,
                loop_break_label:,
                remaining_statements: statements[(index + 1)..] || [],
              )
            end
          end

          def emit_statement(statement, level, function:, used_labels:, loop_continue_label: nil, loop_break_label: nil, remaining_statements: [])
            indent = INDENT * level
            aliases = checked_index_aliases_for_statement(statement)
            alias_lines = emit_checked_index_alias_declarations(aliases, indent)
            line_directive = if @emit_line_directives && statement.respond_to?(:line) && statement.line
                               sp = (statement.respond_to?(:source_path) && statement.source_path) || @source_path
                               sp ? ["#line #{statement.line} #{sp.inspect}"] : []
                             else
                               []
                             end
            statement_lines = with_checked_index_aliases(aliases) do
              case statement
              when IR::LocalDecl
                if array_type?(statement.type) && statement.value.is_a?(IR::Call)
                  lines = ["#{indent}#{c_declaration(statement.type, statement.linkage_name)};"]
                  lines << emit_array_call_statement(statement.value, emit_array_out_argument(statement.linkage_name), indent)
                  lines
                elsif array_type?(statement.type) && !statement.value.is_a?(IR::ArrayLiteral) && !statement.value.is_a?(IR::ZeroInit)
                  lines = ["#{indent}#{c_declaration(statement.type, statement.linkage_name)};"]
                  lines << emit_array_copy_statement(statement.linkage_name, statement.value, indent)
                  lines
                else
                  [
                    "#{indent}#{c_declaration(statement.type, statement.linkage_name)} = #{emit_initializer(statement.value)};",
                  ]
                end
              when IR::Assignment
                if array_type?(statement.target.type) && statement.operator == "=" && statement.value.is_a?(IR::Call)
                  [emit_array_call_statement(statement.value, emit_array_out_argument(emit_expression(statement.target)), indent)]
                elsif array_type?(statement.target.type) && statement.operator == "="
                  [emit_array_copy_statement(emit_expression(statement.target), statement.value, indent)]
                else
                  ["#{indent}#{emit_expression(statement.target)} #{statement.operator} #{emit_expression(statement.value)};"]
                end
              when IR::BlockStmt
                if block_requires_scope?(statement.body)
                  lines = ["#{indent}{"]
                  lines.concat(emit_statement_sequence(statement.body, level + 1, function:, used_labels:, loop_continue_label:, loop_break_label:))
                  lines << "#{indent}}"
                  lines
                else
                  emit_statement_sequence(statement.body, level, function:, used_labels:, loop_continue_label:, loop_break_label:)
                end
              when IR::ExpressionStmt
                if statement.expression.is_a?(IR::Assignment)
                  emit_assignment_expression(statement.expression, indent)
                else
                  ["#{indent}#{emit_expression(statement.expression)};"]
                end
              when IR::ReturnStmt
                if statement.value
                  if array_type?(function.return_type)
                    emit_array_return(statement.value, indent)
                  else
                    ["#{indent}return #{emit_expression(statement.value)};"]
                  end
                else
                  ["#{indent}return;"]
                end
              when IR::WhileStmt
                body_continue_label = loop_continue_label_name(statement.body)
                body = body_continue_label ? statement.body[0...-1] : statement.body
                body_break_label = loop_break_label_name(body, remaining_statements)
                @suppressed_labels << body_break_label if body_break_label && !statements_need_explicit_break_label_after_emission?(body, body_break_label, loop_break_label_active: true)
                lines = ["#{indent}while (#{emit_expression(statement.condition)}) {"]
                lines.concat(emit_statement_sequence(body, level + 1, function:, used_labels:, loop_continue_label: body_continue_label, loop_break_label: body_break_label))
                lines << "#{indent}}"
                lines
              when IR::ForStmt
                body_continue_label = loop_continue_label_name(statement.body)
                body = body_continue_label ? statement.body[0...-1] : statement.body
                body_break_label = loop_break_label_name(body, remaining_statements)
                @suppressed_labels << body_break_label if body_break_label && !statements_need_explicit_break_label_after_emission?(body, body_break_label, loop_break_label_active: true)
                lines = ["#{indent}for (#{emit_for_clause_statement(statement.init)}; #{emit_expression(statement.condition)}; #{emit_for_clause_statement(statement.post)}) {"]
                lines.concat(emit_statement_sequence(body, level + 1, function:, used_labels:, loop_continue_label: body_continue_label, loop_break_label: body_break_label))
                lines << "#{indent}}"
                lines
              when IR::BreakStmt
                ["#{indent}break;"]
              when IR::ContinueStmt
                ["#{indent}continue;"]
              when IR::GotoStmt
                return ["#{indent}continue;"] if loop_continue_label && statement.label == loop_continue_label
                return ["#{indent}break;"] if loop_break_label && statement.label == loop_break_label

                ["#{indent}goto #{statement.label};"]
              when IR::LabelStmt
                return [] if @suppressed_labels.include?(statement.name)
                return [] if loop_continue_label && statement.name == loop_continue_label
                return [] unless used_labels.include?(statement.name)

                ["#{indent}#{statement.name}:;"]
              when IR::StaticAssert
                ["#{indent}#{emit_static_assert(statement)}"]
              when IR::IfStmt
                emit_if_statement(statement, level, function:, used_labels:, loop_continue_label:, loop_break_label:)
              when IR::SwitchStmt
                if switch_emittable_as_if?(statement, loop_break_label:)
                  emit_switch_as_if_statement(statement, level, function:, used_labels:, loop_continue_label:, loop_break_label:)
                else
                lines = ["#{indent}switch (#{emit_expression(statement.expression)}) {"]
                statement.cases.each do |switch_case|
                  if switch_case.is_a?(IR::SwitchDefaultCase)
                    lines << "#{indent}#{INDENT}default: {"
                  else
                    lines << "#{indent}#{INDENT}case #{emit_expression(switch_case.value)}: {"
                  end
                  lines.concat(emit_statement_sequence(switch_case.body, level + 2, function:, used_labels:, loop_continue_label:))
                  lines << "#{indent}#{INDENT}#{INDENT}break;" unless body_terminates?(switch_case.body)
                  lines << "#{indent}#{INDENT}}"
                end
                lines << "#{indent}}"
                lines
                end
              else
                raise CBackendError, "unsupported IR statement #{statement.class.name}"
              end
            end

            alias_lines + line_directive + statement_lines
          end

          def compact_generated_statement_sequence(statements)
            transformed = statements.map { |statement| transform_compactable_nested_bodies(statement) }
            compacted = []
            index = 0
            reachable = true

            while index < transformed.length
              current = transformed[index]

              unless reachable
                if current.is_a?(IR::LabelStmt)
                  compacted << current
                  reachable = true
                end
                index += 1
                next
              end

              following = transformed[index + 1]
              remaining = transformed[(index + 2)..] || []

              if following && (folded_local_alias = fold_single_use_local_alias(current, following, remaining))
                compacted << folded_local_alias
                reachable = !statement_prevents_sequential_fallthrough?(folded_local_alias)
                index += 2
                next
              end

              if following && (folded_if = fold_single_use_bool_if_temp(current, following, remaining))
                compacted << folded_if
                reachable = !statement_prevents_sequential_fallthrough?(folded_if)
                index += 2
                next
              end

              compacted << current
              reachable = !statement_prevents_sequential_fallthrough?(current)
              index += 1
            end

            compacted
          end

          def transform_compactable_nested_bodies(statement)
            case statement
            when IR::BlockStmt
              IR::BlockStmt.new(body: compact_generated_statement_sequence(statement.body))
            when IR::WhileStmt
              canonicalize_top_guarded_while(
                IR::WhileStmt.new(condition: statement.condition, body: compact_generated_statement_sequence(statement.body))
              )
            when IR::ForStmt
              IR::ForStmt.new(
                init: statement.init,
                condition: statement.condition,
                post: statement.post,
                body: compact_generated_statement_sequence(statement.body),
              )
            when IR::IfStmt
              IR::IfStmt.new(
                condition: statement.condition,
                then_body: compact_generated_statement_sequence(statement.then_body),
                else_body: statement.else_body ? compact_generated_statement_sequence(statement.else_body) : nil,
              )
            when IR::SwitchStmt
              IR::SwitchStmt.new(
                expression: statement.expression,
                exhaustive: statement.exhaustive,
                cases: statement.cases.map do |switch_case|
                  if switch_case.is_a?(IR::SwitchDefaultCase)
                    IR::SwitchDefaultCase.new(body: compact_generated_statement_sequence(switch_case.body))
                  else
                    IR::SwitchCase.new(value: switch_case.value, body: compact_generated_statement_sequence(switch_case.body))
                  end
                end,
              )
            else
              statement
            end
          end

          def fold_single_use_local_alias(source_decl, alias_decl, remaining_statements)
            return unless source_decl.is_a?(IR::LocalDecl)
            return unless alias_decl.is_a?(IR::LocalDecl)
            return unless compiler_generated_local_name?(source_decl.linkage_name)
            return if array_type?(source_decl.type) || array_type?(alias_decl.type)
            return unless source_decl.type == alias_decl.type
            return unless alias_decl.value.is_a?(IR::Name) && alias_decl.value.name == source_decl.linkage_name
            return unless name_reference_count_in_statements(remaining_statements, source_decl.linkage_name).zero?

            IR::LocalDecl.new(name: alias_decl.name, linkage_name: alias_decl.linkage_name, type: alias_decl.type, value: source_decl.value)
          end

          def compiler_generated_local_name?(name)
            name.start_with?("__mt_")
          end

          def fold_single_use_bool_if_temp(local_decl, if_stmt, remaining_statements)
            return unless local_decl.is_a?(IR::LocalDecl)
            return unless if_stmt.is_a?(IR::IfStmt)
            return unless bool_type?(local_decl.type)

            condition_kind = single_use_bool_if_condition_kind(if_stmt.condition, local_decl.linkage_name)
            return unless condition_kind
            return unless name_reference_count_in_statements(if_stmt.then_body, local_decl.linkage_name).zero?
            return unless name_reference_count_in_statements(if_stmt.else_body || [], local_decl.linkage_name).zero?
            return unless name_reference_count_in_statements(remaining_statements, local_decl.linkage_name).zero?

            condition = if condition_kind == :direct
                          local_decl.value
                        else
                          IR::Unary.new(operator: "not", operand: local_decl.value, type: local_decl.type)
                        end

            IR::IfStmt.new(condition:, then_body: if_stmt.then_body, else_body: if_stmt.else_body)
          end

          def single_use_bool_if_condition_kind(condition, temp_name)
            return :direct if condition.is_a?(IR::Name) && condition.name == temp_name

            if condition.is_a?(IR::Unary) && condition.operator == "not" && condition.operand.is_a?(IR::Name) && condition.operand.name == temp_name
              return :negated
            end

            nil
          end

          def name_reference_count_in_statements(statements, name)
            statements.sum { |statement| name_reference_count_in_statement(statement, name) }
          end

          def name_reference_count_in_statement(statement, name)
            case statement
            when IR::LocalDecl
              name_reference_count_in_expression(statement.value, name)
            when IR::Assignment
              name_reference_count_in_expression(statement.target, name) + name_reference_count_in_expression(statement.value, name)
            when IR::BlockStmt, IR::WhileStmt, IR::ForStmt
              count = name_reference_count_in_statements(statement.body, name)
              return count unless statement.is_a?(IR::WhileStmt) || statement.is_a?(IR::ForStmt)

              count += name_reference_count_in_expression(statement.condition, name)
              count += name_reference_count_in_statement(statement.init, name) if statement.is_a?(IR::ForStmt)
              count += name_reference_count_in_statement(statement.post, name) if statement.is_a?(IR::ForStmt)
              count
            when IR::IfStmt
              name_reference_count_in_expression(statement.condition, name) +
                name_reference_count_in_statements(statement.then_body, name) +
                name_reference_count_in_statements(statement.else_body || [], name)
            when IR::SwitchStmt
              name_reference_count_in_expression(statement.expression, name) +
                statement.cases.sum { |switch_case| (switch_case.is_a?(IR::SwitchCase) ? name_reference_count_in_expression(switch_case.value, name) : 0) + name_reference_count_in_statements(switch_case.body, name) }
            when IR::StaticAssert
              name_reference_count_in_expression(statement.condition, name) + name_reference_count_in_expression(statement.message, name)
            when IR::ReturnStmt
              statement.value ? name_reference_count_in_expression(statement.value, name) : 0
            when IR::ExpressionStmt
              name_reference_count_in_expression(statement.expression, name)
            else
              0
            end
          end

          def name_reference_count_in_expression(expression, name)
            case expression
            when IR::Name
              expression.name == name ? 1 : 0
            when IR::Member
              name_reference_count_in_expression(expression.receiver, name)
            when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex, IR::NullableIndex, IR::NullableSpanIndex
              name_reference_count_in_expression(expression.receiver, name) + name_reference_count_in_expression(expression.index, name)
            when IR::Call
              callee_count = expression.callee.is_a?(String) ? 0 : name_reference_count_in_expression(expression.callee, name)
              callee_count + expression.arguments.sum { |argument| name_reference_count_in_expression(argument, name) }
            when IR::Unary
              name_reference_count_in_expression(expression.operand, name)
            when IR::Binary
              name_reference_count_in_expression(expression.left, name) + name_reference_count_in_expression(expression.right, name)
            when IR::Conditional
              name_reference_count_in_expression(expression.condition, name) +
                name_reference_count_in_expression(expression.then_expression, name) +
                name_reference_count_in_expression(expression.else_expression, name)
            when IR::ReinterpretExpr
              name_reference_count_in_expression(expression.expression, name)
            when IR::AddressOf, IR::Cast
              name_reference_count_in_expression(expression.expression, name)
            when IR::AggregateLiteral
              expression.fields.sum { |field| name_reference_count_in_expression(field.value, name) }
            when IR::ArrayLiteral
              expression.elements.sum { |element| name_reference_count_in_expression(element, name) }
            when IR::VariantLiteral
              expression.fields.sum { |field| name_reference_count_in_expression(field.value, name) }
            else
              0
            end
          end

          def bool_type?(type)
            type.is_a?(Types::Primitive) && type.name == "bool"
          end

          def checked_index_aliases_for_statement(statement)
            expressions = case statement
                          when IR::LocalDecl
                            [statement.value]
                          when IR::Assignment
                            [statement.target, statement.value]
                          when IR::ExpressionStmt
                            [statement.expression]
                          when IR::ReturnStmt
                            statement.value ? [statement.value] : []
                          else
                            []
                          end

            collect_checked_index_aliases(expressions.compact)
          end

          def collect_checked_index_aliases(expressions)
            counts = Hash.new(0)
            order = []
            expressions.each do |expression|
              collect_checked_index_alias_candidates(expression, counts, order)
            end

            order.each_with_object({}) do |expression, aliases|
              next unless counts[expression] > 1
              next unless hoistable_checked_index_alias?(expression)

              aliases[expression] = fresh_checked_index_alias_name
            end
          end

          def collect_checked_index_alias_candidates(expression, counts, order)
            case expression
            when IR::Member
              collect_checked_index_alias_candidates(expression.receiver, counts, order)
            when IR::Index
              collect_checked_index_alias_candidates(expression.receiver, counts, order)
              collect_checked_index_alias_candidates(expression.index, counts, order)
            when IR::CheckedIndex, IR::CheckedSpanIndex, IR::NullableIndex, IR::NullableSpanIndex
              order << expression unless counts.key?(expression)
              counts[expression] += 1
              collect_checked_index_alias_candidates(expression.receiver, counts, order)
              collect_checked_index_alias_candidates(expression.index, counts, order)
            when IR::Call
              collect_checked_index_alias_candidates(expression.callee, counts, order) unless expression.callee.is_a?(String)
              expression.arguments.each { |argument| collect_checked_index_alias_candidates(argument, counts, order) }
            when IR::Unary
              collect_checked_index_alias_candidates(expression.operand, counts, order)
            when IR::Binary
              collect_checked_index_alias_candidates(expression.left, counts, order)
              collect_checked_index_alias_candidates(expression.right, counts, order)
            when IR::Conditional
              collect_checked_index_alias_candidates(expression.condition, counts, order)
              collect_checked_index_alias_candidates(expression.then_expression, counts, order)
              collect_checked_index_alias_candidates(expression.else_expression, counts, order)
            when IR::ReinterpretExpr, IR::AddressOf, IR::Cast
              collect_checked_index_alias_candidates(expression.expression, counts, order)
            when IR::AggregateLiteral
              expression.fields.each { |field| collect_checked_index_alias_candidates(field.value, counts, order) }
            when IR::ArrayLiteral
              expression.elements.each { |element| collect_checked_index_alias_candidates(element, counts, order) }
            when IR::VariantLiteral
              expression.fields.each { |field| collect_checked_index_alias_candidates(field.value, counts, order) }
            end
          end

          def hoistable_checked_index_alias?(expression)
            side_effect_free_expression?(expression.receiver) && side_effect_free_expression?(expression.index)
          end

          def side_effect_free_expression?(expression)
            case expression
            when IR::Name, IR::IntegerLiteral, IR::FloatLiteral, IR::StringLiteral, IR::BooleanLiteral, IR::NullLiteral, IR::ZeroInit, IR::SizeofExpr, IR::AlignofExpr, IR::OffsetofExpr
              true
            when IR::Member
              side_effect_free_expression?(expression.receiver)
            when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex, IR::NullableIndex, IR::NullableSpanIndex
              side_effect_free_expression?(expression.receiver) && side_effect_free_expression?(expression.index)
            when IR::Unary
              side_effect_free_expression?(expression.operand)
            when IR::Binary
              side_effect_free_expression?(expression.left) && side_effect_free_expression?(expression.right)
            when IR::Conditional
              side_effect_free_expression?(expression.condition) &&
                side_effect_free_expression?(expression.then_expression) &&
                side_effect_free_expression?(expression.else_expression)
            when IR::ReinterpretExpr, IR::AddressOf, IR::Cast
              side_effect_free_expression?(expression.expression)
            when IR::AggregateLiteral
              expression.fields.all? { |field| side_effect_free_expression?(field.value) }
            when IR::VariantLiteral
              expression.fields.all? { |field| side_effect_free_expression?(field.value) }
            when IR::ArrayLiteral
              expression.elements.all? { |element| side_effect_free_expression?(element) }
            when IR::Call
              false
            else
              false
            end
          end

          def emit_checked_index_alias_declarations(aliases, indent)
            aliases.map do |expression, alias_name|
              "#{indent}#{c_declaration(pointer_to(expression.type), alias_name)} = #{emit_checked_index_pointer(expression)};"
            end
          end

          def emit_checked_index_pointer(expression)
            case expression
            when IR::CheckedIndex
              "#{checked_array_index_helper_name(expression.receiver_type)}(#{emit_address_of_operand(expression.receiver)}, #{emit_expression(expression.index)})"
            when IR::CheckedSpanIndex
              "#{checked_span_index_helper_name(expression.receiver_type)}(#{emit_expression(expression.receiver)}, #{emit_expression(expression.index)})"
            else
              raise CBackendError, "unsupported checked index alias expression #{expression.class.name}"
            end
          end

          def fresh_checked_index_alias_name
            @checked_index_alias_id += 1
            "__mt_checked_index_ptr_#{@checked_index_alias_id}"
          end

          def with_checked_index_aliases(aliases)
            @checked_index_alias_stack << aliases
            yield
          ensure
            @checked_index_alias_stack.pop
          end

          def checked_index_alias(expression)
            @checked_index_alias_stack.reverse_each do |aliases|
              alias_name = aliases[expression]
              return alias_name if alias_name
            end

            nil
          end

          def block_requires_scope?(statements)
            statements.any? { |statement| statement.is_a?(IR::LocalDecl) }
          end

          def emit_for_clause_statement(statement)
            case statement
            when IR::LocalDecl
              raise CBackendError, "array for-loop init declarations are unsupported" if array_type?(statement.type)

              "#{c_declaration(statement.type, statement.linkage_name)} = #{emit_initializer(statement.value)}"
            when IR::Assignment
              if array_type?(statement.target.type) && statement.operator == "="
                raise CBackendError, "array for-loop assignment clauses are unsupported"
              end

              "#{emit_expression(statement.target)} #{statement.operator} #{emit_expression(statement.value)}"
            when IR::ExpressionStmt
              emit_expression(statement.expression)
            else
              raise CBackendError, "unsupported for-loop clause #{statement.class.name}"
            end
          end

          def emit_static_assert(statement)
            message = if statement.message.is_a?(IR::StringLiteral)
                        statement.message.value.inspect
                      else
                        emit_expression(statement.message)
                      end

            "_Static_assert(#{emit_expression(statement.condition)}, #{message});"
          end

          def emit_assignment_expression(assignment, indent)
            ["#{indent}#{emit_expression(assignment.target)} #{assignment.operator} #{emit_expression(assignment.value)};"]
          end
    end
  end
end

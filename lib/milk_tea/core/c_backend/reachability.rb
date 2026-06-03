# frozen_string_literal: true

module MilkTea
  class CBackend
    module CBackendReachability
      private

          def emitted_constants
            @emitted_constants ||= begin
              constants_by_name = @program.constants.each_with_object({}) do |constant, result|
                result[constant.c_name] = constant
              end
              referenced_names = {}
              root_module_prefix = "#{module_c_prefix(@program.module_name)}_"

              @program.constants.each do |constant|
                next unless constant.c_name.start_with?(root_module_prefix)

                referenced_names[constant.c_name] = true
                collect_referenced_constant_names_from_expression(constant.value, constants_by_name, referenced_names)
              end

              @program.globals.each do |global|
                collect_referenced_constant_names_from_expression(global.value, constants_by_name, referenced_names)
              end

              @program.static_asserts.each do |statement|
                collect_referenced_constant_names_from_expression(statement.condition, constants_by_name, referenced_names)
                collect_referenced_constant_names_from_expression(statement.message, constants_by_name, referenced_names)
              end

              emitted_functions.each do |function|
                collect_referenced_constant_names_from_statements(function.body, constants_by_name, referenced_names)
              end

              @program.constants.select { |constant| referenced_names[constant.c_name] }
            end
          end

          def emitted_functions
            @emitted_functions ||= begin
              functions_by_name = @program.functions.each_with_object({}) do |function, result|
                result[function.c_name] = function
              end

              seeds = @program.functions.select(&:entry_point)
              if seeds.empty?
                root_module_prefix = "#{module_c_prefix(@program.module_name)}_"
                seeds = @program.functions.select { |function| function.c_name.start_with?(root_module_prefix) }
              end

              reachable_names = {}
              worklist = seeds.dup

              until worklist.empty?
                function = worklist.shift
                next if reachable_names[function.c_name]

                reachable_names[function.c_name] = true
                collect_called_function_names_from_statements(function.body, functions_by_name, reachable_names, worklist)
              end

              (@program.constants + @program.globals).each do |value|
                collect_called_function_names_from_expression(value.value, functions_by_name, reachable_names, worklist)
              end

              until worklist.empty?
                function = worklist.shift
                next if reachable_names[function.c_name]

                reachable_names[function.c_name] = true
                collect_called_function_names_from_statements(function.body, functions_by_name, reachable_names, worklist)
              end

              @program.functions.select { |function| reachable_names[function.c_name] }
            end
          end

          def all_emitted_top_level_values
            emitted_constants + @program.globals
          end

          def collect_called_function_names_from_statements(statements, functions_by_name, reachable_names, worklist)
            traverse_ir_statements(statements) do |expression|
              case expression
              when IR::Name
                callee = functions_by_name[expression.name]
                worklist << callee if callee && !reachable_names[callee.c_name]
              when IR::Call
                next unless expression.callee.is_a?(String)

                callee = functions_by_name[expression.callee]
                worklist << callee if callee && !reachable_names[callee.c_name]
              end
            end
          end

          def collect_called_function_names_from_expression(expression, functions_by_name, reachable_names, worklist)
            traverse_ir_expression(expression) do |candidate|
              case candidate
              when IR::Name
                callee = functions_by_name[candidate.name]
                worklist << callee if callee && !reachable_names[callee.c_name]
              when IR::Call
                next unless candidate.callee.is_a?(String)

                callee = functions_by_name[candidate.callee]
                worklist << callee if callee && !reachable_names[callee.c_name]
              end
            end
          end

          def collect_referenced_constant_names_from_statements(statements, constants_by_name, referenced_names)
            visitor = constant_reference_visitor(constants_by_name, referenced_names)
            traverse_ir_statements(statements, visit_switch_case_values: true, &visitor)
          end

          def collect_referenced_constant_names_from_expression(expression, constants_by_name, referenced_names)
            visitor = constant_reference_visitor(constants_by_name, referenced_names)
            traverse_ir_expression(expression, &visitor)
          end

          def constant_reference_visitor(constants_by_name, referenced_names)
            lambda do |expression|
              next unless expression.is_a?(IR::Name)

              constant = constants_by_name[expression.name]
              next unless constant
              next if referenced_names[constant.c_name]

              referenced_names[constant.c_name] = true
              traverse_ir_expression(constant.value, &constant_reference_visitor(constants_by_name, referenced_names))
            end
          end

          def traverse_ir_statements(statements, visit_switch_case_values: false, &expression_visitor)
            Array(statements).compact.each do |statement|
              case statement
              when IR::LocalDecl
                traverse_ir_expression(statement.value, &expression_visitor)
              when IR::Assignment
                traverse_ir_expression(statement.target, &expression_visitor)
                traverse_ir_expression(statement.value, &expression_visitor)
              when IR::BlockStmt
                traverse_ir_statements(statement.body, visit_switch_case_values:, &expression_visitor)
              when IR::WhileStmt
                traverse_ir_expression(statement.condition, &expression_visitor)
                traverse_ir_statements(statement.body, visit_switch_case_values:, &expression_visitor)
              when IR::ForStmt
                traverse_ir_statements([statement.init], visit_switch_case_values:, &expression_visitor)
                traverse_ir_expression(statement.condition, &expression_visitor)
                traverse_ir_statements(statement.body, visit_switch_case_values:, &expression_visitor)
                traverse_ir_statements([statement.post], visit_switch_case_values:, &expression_visitor)
              when IR::IfStmt
                traverse_ir_expression(statement.condition, &expression_visitor)
                traverse_ir_statements(statement.then_body, visit_switch_case_values:, &expression_visitor)
                traverse_ir_statements(statement.else_body, visit_switch_case_values:, &expression_visitor) if statement.else_body
              when IR::SwitchStmt
                traverse_ir_expression(statement.expression, &expression_visitor)
                statement.cases.each do |switch_case|
                  if visit_switch_case_values && switch_case.is_a?(IR::SwitchCase)
                    traverse_ir_expression(switch_case.value, &expression_visitor)
                  end
                  traverse_ir_statements(switch_case.body, visit_switch_case_values:, &expression_visitor)
                end
              when IR::StaticAssert
                traverse_ir_expression(statement.condition, &expression_visitor)
                traverse_ir_expression(statement.message, &expression_visitor)
              when IR::ReturnStmt
                traverse_ir_expression(statement.value, &expression_visitor) if statement.value
              when IR::ExpressionStmt
                traverse_ir_expression(statement.expression, &expression_visitor)
              end
            end
          end

          def traverse_ir_expression(expression, &expression_visitor)
            return if expression.nil?

            expression_visitor.call(expression) if expression_visitor

            case expression
            when IR::Member
              traverse_ir_expression(expression.receiver, &expression_visitor)
            when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex
              traverse_ir_expression(expression.receiver, &expression_visitor)
              traverse_ir_expression(expression.index, &expression_visitor)
            when IR::Call
              traverse_ir_expression(expression.callee, &expression_visitor) unless expression.callee.is_a?(String)
              expression.arguments.each { |argument| traverse_ir_expression(argument, &expression_visitor) }
            when IR::Unary
              traverse_ir_expression(expression.operand, &expression_visitor)
            when IR::Binary
              traverse_ir_expression(expression.left, &expression_visitor)
              traverse_ir_expression(expression.right, &expression_visitor)
            when IR::Conditional
              traverse_ir_expression(expression.condition, &expression_visitor)
              traverse_ir_expression(expression.then_expression, &expression_visitor)
              traverse_ir_expression(expression.else_expression, &expression_visitor)
            when IR::ReinterpretExpr, IR::AddressOf, IR::Cast
              traverse_ir_expression(expression.expression, &expression_visitor)
            when IR::AggregateLiteral
              expression.fields.each { |field| traverse_ir_expression(field.value, &expression_visitor) }
            when IR::ArrayLiteral
              expression.elements.each { |element| traverse_ir_expression(element, &expression_visitor) }
            when IR::VariantLiteral
              expression.fields.each { |field| traverse_ir_expression(field.value, &expression_visitor) }
            end
          end

          def uses_fatal_helper?
            uses_mt_fatal_helper? || uses_mt_fatal_str_helper?
          end

          def uses_mt_fatal_helper?
            collect_checked_array_index_types.any? || collect_checked_span_index_types.any? ||
              uses_format_helpers? ||
              emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_fatal mt_str_buffer_len mt_str_buffer_as_cstr mt_str_buffer_assign mt_str_buffer_append mt_foreign_str_to_cstr_temp mt_foreign_strs_to_cstrs_temp]) }
          end

          def uses_mt_fatal_str_helper?
            emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_fatal_str]) }
          end

          def uses_foreign_temp_cstr_helpers?
            emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_foreign_str_to_cstr_temp mt_free_foreign_cstr_temp mt_foreign_strs_to_cstrs_temp mt_free_foreign_cstrs_temp]) }
          end

          def uses_entrypoint_argv_helpers?
            emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_entry_argv_to_span_str mt_free_entry_argv_strs]) }
          end

          def uses_text_buffer_helpers?
            uses_str_buffer_helpers?
          end

          def uses_str_buffer_helpers?
            emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_str_buffer_len mt_str_buffer_as_cstr mt_str_buffer_clear mt_str_buffer_assign mt_str_buffer_append mt_str_buffer_prepare_write]) }
          end

          def uses_async_memory_helpers?
            emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_async_alloc mt_async_free]) }
          end

          def format_helper_callees
            %w[
              mt_format_str_make
              mt_format_str_release
              mt_format_cstr_len
              mt_format_bool_len
              mt_format_ptr_uint_len
              mt_format_ulong_len
              mt_format_uint_len
              mt_format_long_len
              mt_format_int_len
              mt_format_ulong_hex_len
              mt_format_long_hex_len
              mt_format_float_len
              mt_format_double_len
              mt_format_double_precision_len
              mt_format_ulong_oct_len
              mt_format_long_oct_len
              mt_format_ulong_bin_len
              mt_format_long_bin_len
              mt_format_append_str
              mt_format_append_cstr
              mt_format_append_bool
              mt_format_append_ptr_uint
              mt_format_append_ulong
              mt_format_append_uint
              mt_format_append_long
              mt_format_append_int
              mt_format_append_ulong_hex
              mt_format_append_ulong_hex_upper
              mt_format_append_long_hex
              mt_format_append_long_hex_upper
              mt_format_append_float
              mt_format_append_double
              mt_format_append_double_precision
              mt_format_append_ulong_oct
              mt_format_append_long_oct
              mt_format_append_ulong_bin
              mt_format_append_long_bin
            ]
          end

          def used_format_helpers
            @used_format_helpers ||= begin
              helpers = {}

              emitted_functions.each do |function|
                format_helper_callees.each do |callee|
                  helpers[callee] = true if function_uses_named_call?(function, [callee])
                end
              end

              loop do
                changed = false

                helpers.keys.each do |helper|
                  format_helper_dependencies(helper).each do |dependency|
                    next if helpers[dependency]

                    helpers[dependency] = true
                    changed = true
                  end
                end

                break unless changed
              end

              helpers
            end
          end

          def format_helper_dependencies(helper)
            case helper
            when 'mt_format_append_str'
              %w[mt_format_append_bytes mt_format_check_capacity]
            when 'mt_format_append_cstr'
              %w[mt_format_append_bytes mt_format_check_capacity mt_format_cstr_len]
            when 'mt_format_append_bool'
              %w[mt_format_append_bytes mt_format_check_capacity]
            when 'mt_format_append_ptr_uint'
              %w[mt_format_check_capacity mt_format_ptr_uint_len]
            when 'mt_format_append_ulong'
              %w[mt_format_check_capacity mt_format_ulong_len]
            when 'mt_format_append_uint'
              %w[mt_format_append_ptr_uint mt_format_check_capacity mt_format_ptr_uint_len]
            when 'mt_format_append_long'
              %w[mt_format_append_bytes mt_format_check_capacity mt_format_append_ulong mt_format_ulong_len]
            when 'mt_format_append_int'
              %w[mt_format_append_bytes mt_format_check_capacity mt_format_append_ptr_uint mt_format_ptr_uint_len]
            when 'mt_format_append_ulong_hex'
              %w[mt_format_check_capacity mt_format_ulong_hex_len]
            when 'mt_format_append_ulong_hex_upper'
              %w[mt_format_check_capacity mt_format_ulong_hex_len]
            when 'mt_format_append_long_hex'
              %w[mt_format_append_bytes mt_format_check_capacity mt_format_append_ulong_hex mt_format_ulong_hex_len]
            when 'mt_format_append_long_hex_upper'
              %w[mt_format_append_bytes mt_format_check_capacity mt_format_append_ulong_hex_upper mt_format_ulong_hex_len]
            when 'mt_format_append_ulong_oct'
              %w[mt_format_check_capacity mt_format_ulong_oct_len]
            when 'mt_format_append_long_oct'
              %w[mt_format_append_bytes mt_format_check_capacity mt_format_append_ulong_oct mt_format_ulong_oct_len]
            when 'mt_format_append_ulong_bin'
              %w[mt_format_check_capacity mt_format_ulong_bin_len]
            when 'mt_format_append_long_bin'
              %w[mt_format_append_bytes mt_format_check_capacity mt_format_append_ulong_bin mt_format_ulong_bin_len]
            when 'mt_format_append_float'
              %w[mt_format_check_capacity mt_format_float_len]
            when 'mt_format_append_double'
              %w[mt_format_check_capacity mt_format_double_len]
            when 'mt_format_append_double_precision'
              %w[mt_format_check_capacity mt_format_double_precision_len]
            when 'mt_format_int_len'
              %w[mt_format_ptr_uint_len]
            when 'mt_format_long_len'
              %w[mt_format_ulong_len]
            when 'mt_format_long_hex_len'
              %w[mt_format_ulong_hex_len]
            when 'mt_format_long_oct_len'
              %w[mt_format_ulong_oct_len]
            when 'mt_format_long_bin_len'
              %w[mt_format_ulong_bin_len]
            else
              []
            end
          end

          def uses_format_helpers?
            !used_format_helpers.empty?
          end

          def uses_str_equality_helper?
            emitted_functions.any? { |function| function_uses_str_equality?(function) }
          end

          def function_uses_named_call?(function, callees)
            function.body.any? { |statement| statement_uses_named_call?(statement, callees) }
          end

          def function_uses_str_equality?(function)
            function.body.any? { |statement| statement_uses_str_equality?(statement) }
          end

          def statement_uses_named_call?(statement, callees)
            case statement
            when IR::LocalDecl
              expression_uses_named_call?(statement.value, callees)
            when IR::Assignment
              expression_uses_named_call?(statement.target, callees) || expression_uses_named_call?(statement.value, callees)
            when IR::BlockStmt
              statement.body.any? { |inner| statement_uses_named_call?(inner, callees) }
            when IR::WhileStmt
              expression_uses_named_call?(statement.condition, callees) || statement.body.any? { |inner| statement_uses_named_call?(inner, callees) }
            when IR::ForStmt
              statement_uses_named_call?(statement.init, callees) ||
                expression_uses_named_call?(statement.condition, callees) ||
                statement.body.any? { |inner| statement_uses_named_call?(inner, callees) } ||
                statement_uses_named_call?(statement.post, callees)
            when IR::IfStmt
              expression_uses_named_call?(statement.condition, callees) ||
                statement.then_body.any? { |inner| statement_uses_named_call?(inner, callees) } ||
                (statement.else_body && statement.else_body.any? { |inner| statement_uses_named_call?(inner, callees) })
            when IR::SwitchStmt
              expression_uses_named_call?(statement.expression, callees) || statement.cases.any? { |switch_case| switch_case.body.any? { |inner| statement_uses_named_call?(inner, callees) } }
            when IR::StaticAssert
              expression_uses_named_call?(statement.condition, callees) || expression_uses_named_call?(statement.message, callees)
            when IR::ReturnStmt
              statement.value && expression_uses_named_call?(statement.value, callees)
            when IR::ExpressionStmt
              expression_uses_named_call?(statement.expression, callees)
            end
          end

          def statement_uses_str_equality?(statement)
            case statement
            when IR::LocalDecl
              expression_uses_str_equality?(statement.value)
            when IR::Assignment
              expression_uses_str_equality?(statement.target) || expression_uses_str_equality?(statement.value)
            when IR::BlockStmt
              statement.body.any? { |inner| statement_uses_str_equality?(inner) }
            when IR::WhileStmt
              expression_uses_str_equality?(statement.condition) || statement.body.any? { |inner| statement_uses_str_equality?(inner) }
            when IR::ForStmt
              statement_uses_str_equality?(statement.init) ||
                expression_uses_str_equality?(statement.condition) ||
                statement.body.any? { |inner| statement_uses_str_equality?(inner) } ||
                statement_uses_str_equality?(statement.post)
            when IR::IfStmt
              expression_uses_str_equality?(statement.condition) ||
                statement.then_body.any? { |inner| statement_uses_str_equality?(inner) } ||
                (statement.else_body && statement.else_body.any? { |inner| statement_uses_str_equality?(inner) })
            when IR::SwitchStmt
              expression_uses_str_equality?(statement.expression) || statement.cases.any? { |switch_case| switch_case.body.any? { |inner| statement_uses_str_equality?(inner) } }
            when IR::StaticAssert
              expression_uses_str_equality?(statement.condition) || expression_uses_str_equality?(statement.message)
            when IR::ReturnStmt
              statement.value && expression_uses_str_equality?(statement.value)
            when IR::ExpressionStmt
              expression_uses_str_equality?(statement.expression)
            else
              false
            end
          end

          def expression_uses_named_call?(expression, callees)
            case expression
            when IR::Call
              callees.include?(expression.callee) ||
                (!expression.callee.is_a?(String) && expression_uses_named_call?(expression.callee, callees)) ||
                expression.arguments.any? { |argument| expression_uses_named_call?(argument, callees) }
            when IR::Member
              expression_uses_named_call?(expression.receiver, callees)
            when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex
              expression_uses_named_call?(expression.receiver, callees) || expression_uses_named_call?(expression.index, callees)
            when IR::Unary
              expression_uses_named_call?(expression.operand, callees)
            when IR::Binary
              expression_uses_named_call?(expression.left, callees) || expression_uses_named_call?(expression.right, callees)
            when IR::Conditional
              expression_uses_named_call?(expression.condition, callees) || expression_uses_named_call?(expression.then_expression, callees) || expression_uses_named_call?(expression.else_expression, callees)
            when IR::ReinterpretExpr, IR::Cast, IR::AddressOf
              expression_uses_named_call?(expression.expression, callees)
            when IR::AggregateLiteral
              expression.fields.any? { |field| expression_uses_named_call?(field.value, callees) }
            when IR::ArrayLiteral
              expression.elements.any? { |element| expression_uses_named_call?(element, callees) }
            else
              false
            end
          end

          def expression_uses_str_equality?(expression)
            case expression
            when IR::Binary
              str_equality_expression?(expression) || expression_uses_str_equality?(expression.left) || expression_uses_str_equality?(expression.right)
            when IR::Call
              (!expression.callee.is_a?(String) && expression_uses_str_equality?(expression.callee)) || expression.arguments.any? { |argument| expression_uses_str_equality?(argument) }
            when IR::Member
              expression_uses_str_equality?(expression.receiver)
            when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex
              expression_uses_str_equality?(expression.receiver) || expression_uses_str_equality?(expression.index)
            when IR::Unary
              expression_uses_str_equality?(expression.operand)
            when IR::Conditional
              expression_uses_str_equality?(expression.condition) || expression_uses_str_equality?(expression.then_expression) || expression_uses_str_equality?(expression.else_expression)
            when IR::ReinterpretExpr, IR::Cast, IR::AddressOf
              expression_uses_str_equality?(expression.expression)
            when IR::AggregateLiteral
              expression.fields.any? { |field| expression_uses_str_equality?(field.value) }
            when IR::ArrayLiteral
              expression.elements.any? { |element| expression_uses_str_equality?(element) }
            else
              false
            end
          end

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
                  lines = ["#{indent}#{c_declaration(statement.type, statement.c_name)};"]
                  lines << emit_array_call_statement(statement.value, emit_array_out_argument(statement.c_name), indent)
                  lines << unused_local_suppression_line(statement, indent, remaining_statements)
                  lines
                elsif array_type?(statement.type) && !statement.value.is_a?(IR::ArrayLiteral) && !statement.value.is_a?(IR::ZeroInit)
                  lines = ["#{indent}#{c_declaration(statement.type, statement.c_name)};"]
                  lines << emit_array_copy_statement(statement.c_name, statement.value, indent)
                  lines << unused_local_suppression_line(statement, indent, remaining_statements)
                  lines
                else
                  [
                    "#{indent}#{c_declaration(statement.type, statement.c_name)} = #{emit_initializer(statement.value)};",
                    unused_local_suppression_line(statement, indent, remaining_statements),
                  ].compact
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
                ["#{indent}#{emit_expression(statement.expression)};"]
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
                raise LoweringError, "unsupported IR statement #{statement.class.name}"
              end
            end

            alias_lines + line_directive + statement_lines
          end

          def unused_local_suppression_line(statement, indent, remaining_statements)
            return unless name_reference_count_in_statements(remaining_statements, statement.c_name).zero?

            "#{indent}(void)#{statement.c_name};"
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

          def loop_continue_label_name(statements)
            return if statements.empty?

            label = statements.last
            return unless label.is_a?(IR::LabelStmt)

            label.name
          end

          def loop_break_label_name(statements, remaining_statements)
            return if remaining_statements.empty?

            label = remaining_statements.first
            return unless label.is_a?(IR::LabelStmt)
            return unless statements_reference_label?(statements, label.name)

            label.name
          end

          def statements_reference_label?(statements, label_name)
            statements.any? { |statement| statement_references_label?(statement, label_name) }
          end

          def statement_references_label?(statement, label_name)
            case statement
            when IR::BlockStmt, IR::WhileStmt, IR::ForStmt
              statements_reference_label?(statement.body, label_name)
            when IR::IfStmt
              statements_reference_label?(statement.then_body, label_name) ||
                (statement.else_body && statements_reference_label?(statement.else_body, label_name))
            when IR::SwitchStmt
              statement.cases.any? { |switch_case| statements_reference_label?(switch_case.body, label_name) }
            when IR::GotoStmt
              statement.label == label_name
            else
              false
            end
          end

          def statements_need_explicit_break_label_after_emission?(statements, label_name, loop_break_label_active:)
            statements.any? do |statement|
              statement_needs_explicit_break_label_after_emission?(statement, label_name, loop_break_label_active:)
            end
          end

          def statement_needs_explicit_break_label_after_emission?(statement, label_name, loop_break_label_active:)
            case statement
            when IR::BlockStmt, IR::IfStmt
              then_body = statement.is_a?(IR::IfStmt) ? statement.then_body : statement.body
              else_body = statement.is_a?(IR::IfStmt) ? statement.else_body : nil
              statements_need_explicit_break_label_after_emission?(then_body, label_name, loop_break_label_active:) ||
                (else_body && statements_need_explicit_break_label_after_emission?(else_body, label_name, loop_break_label_active:))
            when IR::WhileStmt, IR::ForStmt
              statements_need_explicit_break_label_after_emission?(statement.body, label_name, loop_break_label_active: false)
            when IR::SwitchStmt
              return false unless statement_references_label?(statement, label_name)

              active = loop_break_label_active && switch_emittable_as_if?(statement, loop_break_label: label_name)
              statements_need_explicit_break_label_after_emission?(
                statement.cases.flat_map(&:body),
                label_name,
                loop_break_label_active: active,
              )
            when IR::GotoStmt
              statement.label == label_name && !loop_break_label_active
            else
              false
            end
          end

          def switch_emittable_as_if?(statement, loop_break_label: nil)
            return false unless loop_break_label
            return false unless statement.exhaustive
            return false unless statement.cases.length == 2
            return false unless side_effect_free_expression?(statement.expression)
            return false unless statement_references_label?(statement, loop_break_label)

            statement.cases.count { |switch_case| switch_case.is_a?(IR::SwitchDefaultCase) } <= 1
          end

          def emit_switch_as_if_statement(statement, level, function:, used_labels:, loop_continue_label:, loop_break_label:)
            explicit_cases = statement.cases.select { |switch_case| switch_case.is_a?(IR::SwitchCase) }
            default_case = statement.cases.find { |switch_case| switch_case.is_a?(IR::SwitchDefaultCase) }

            condition, then_body, else_body = if default_case
                                                explicit_case = explicit_cases.first
                                                [
                                                  IR::Binary.new(operator: "==", left: statement.expression, right: explicit_case.value, type: nil),
                                                  strip_terminal_switch_break(explicit_case.body),
                                                  strip_terminal_switch_break(default_case.body),
                                                ]
                                              else
                                                [
                                                  IR::Binary.new(operator: "==", left: statement.expression, right: explicit_cases.first.value, type: nil),
                                                  strip_terminal_switch_break(explicit_cases.first.body),
                                                  strip_terminal_switch_break(explicit_cases.last.body),
                                                ]
                                              end

            emit_if_statement(
              IR::IfStmt.new(condition:, then_body:, else_body:),
              level,
              function:,
              used_labels:,
              loop_continue_label:,
              loop_break_label:,
            )
          end

          def strip_terminal_switch_break(statements)
            return statements unless statements.last.is_a?(IR::BreakStmt)

            statements[0...-1]
          end

          def canonicalize_top_guarded_while(statement)
            return statement unless constant_boolean_value(statement.condition) == true
            return statement if statement.body.empty?

            break_condition = top_guard_break_condition(statement.body.first)
            return statement unless break_condition

            IR::WhileStmt.new(
              condition: invert_break_guard_condition(break_condition),
              body: statement.body.drop(1),
            )
          end

          def top_guard_break_condition(statement)
            return unless statement.is_a?(IR::IfStmt)
            return unless statement.else_body.nil? || statement.else_body.empty?
            return unless statement.then_body.length == 1 && statement.then_body.first.is_a?(IR::BreakStmt)

            statement.condition
          end

          def invert_break_guard_condition(expression)
            case expression
            when IR::BooleanLiteral
              IR::BooleanLiteral.new(value: !expression.value, type: expression.type)
            when IR::Unary
              return expression.operand if expression.operator == "not"
            when IR::Binary
              if (operator = inverted_boolean_operator(expression.operator))
                return IR::Binary.new(operator:, left: expression.left, right: expression.right, type: expression.type)
              end
            end

            IR::Unary.new(operator: "not", operand: expression, type: expression.type)
          end

          def inverted_boolean_operator(operator)
            {
              "==" => "!=",
              "!=" => "==",
              "<" => ">=",
              "<=" => ">",
              ">" => "<=",
              ">=" => "<",
            }[operator]
          end

          def emit_if_statement(statement, level, function:, used_labels:, loop_continue_label: nil, loop_break_label: nil)
            indent = INDENT * level

            case constant_boolean_value(statement.condition)
            when true
              return emit_statement(IR::BlockStmt.new(body: statement.then_body), level, function:, used_labels:, loop_continue_label:, loop_break_label:)
            when false
              return [] unless statement.else_body && !statement.else_body.empty?

              return emit_statement(IR::BlockStmt.new(body: statement.else_body), level, function:, used_labels:, loop_continue_label:, loop_break_label:)
            end

            lines = ["#{indent}if (#{emit_expression(statement.condition)}) {"]
            lines.concat(emit_statement_sequence(statement.then_body, level + 1, function:, used_labels:, loop_continue_label:, loop_break_label:))

            nested_else_if = nested_else_if_statement(statement.else_body)
            if nested_else_if
              nested_lines = emit_if_statement(nested_else_if, level, function:, used_labels:, loop_continue_label:, loop_break_label:)
              lines << "#{indent}} else #{nested_lines.first.sub(/^#{Regexp.escape(indent)}/, "") }"
              lines.concat(nested_lines.drop(1))
              return lines
            end

            if statement.else_body && !statement.else_body.empty?
              lines << "#{indent}} else {"
              lines.concat(emit_statement_sequence(statement.else_body, level + 1, function:, used_labels:, loop_continue_label:, loop_break_label:))
            end
            lines << "#{indent}}"
            lines
          end

          def nested_else_if_statement(else_body)
            return unless else_body && else_body.length == 1

            nested = else_body.first
            nested if nested.is_a?(IR::IfStmt)
          end

          def fold_single_use_local_alias(source_decl, alias_decl, remaining_statements)
            return unless source_decl.is_a?(IR::LocalDecl)
            return unless alias_decl.is_a?(IR::LocalDecl)
            return unless compiler_generated_local_name?(source_decl.c_name)
            return if array_type?(source_decl.type) || array_type?(alias_decl.type)
            return unless source_decl.type == alias_decl.type
            return unless alias_decl.value.is_a?(IR::Name) && alias_decl.value.name == source_decl.c_name
            return unless name_reference_count_in_statements(remaining_statements, source_decl.c_name).zero?

            IR::LocalDecl.new(name: alias_decl.name, c_name: alias_decl.c_name, type: alias_decl.type, value: source_decl.value)
          end

          def compiler_generated_local_name?(name)
            name.start_with?("__mt_")
          end

          def fold_single_use_bool_if_temp(local_decl, if_stmt, remaining_statements)
            return unless local_decl.is_a?(IR::LocalDecl)
            return unless if_stmt.is_a?(IR::IfStmt)
            return unless bool_type?(local_decl.type)

            condition_kind = single_use_bool_if_condition_kind(if_stmt.condition, local_decl.c_name)
            return unless condition_kind
            return unless name_reference_count_in_statements(if_stmt.then_body, local_decl.c_name).zero?
            return unless name_reference_count_in_statements(if_stmt.else_body || [], local_decl.c_name).zero?
            return unless name_reference_count_in_statements(remaining_statements, local_decl.c_name).zero?

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
            when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex
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
            when IR::CheckedIndex, IR::CheckedSpanIndex
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
            when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex
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
              raise LoweringError, "unsupported checked index alias expression #{expression.class.name}"
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

          def body_terminates?(statements)
            return false if statements.empty?

            statement_terminates?(statements.last)
          end

          def body_needs_fallback_return?(statements)
            return true if statements.empty?

            !statement_prevents_c_fallthrough?(statements.last)
          end

          def constant_boolean_value(expression)
            case expression
            when IR::BooleanLiteral
              expression.value
            when IR::Unary
              operand = constant_boolean_value(expression.operand)
              return nil if operand.nil? || expression.operator != "not"

              !operand
            when IR::Binary
              left_int = constant_integer_value(expression.left)
              right_int = constant_integer_value(expression.right)
              if !left_int.nil? && !right_int.nil?
                return left_int == right_int if expression.operator == "=="
                return left_int != right_int if expression.operator == "!="
                return left_int < right_int if expression.operator == "<"
                return left_int <= right_int if expression.operator == "<="
                return left_int > right_int if expression.operator == ">"
                return left_int >= right_int if expression.operator == ">="
              end

              left_bool = constant_boolean_value(expression.left)
              right_bool = constant_boolean_value(expression.right)
              if !left_bool.nil? && !right_bool.nil?
                return left_bool == right_bool if expression.operator == "=="
                return left_bool != right_bool if expression.operator == "!="
                return left_bool && right_bool if expression.operator == "and"
                return left_bool || right_bool if expression.operator == "or"
              end

              nil
            else
              nil
            end
          end

          def constant_integer_value(expression)
            case expression
            when IR::IntegerLiteral
              expression.value
            when IR::Unary
              operand = constant_integer_value(expression.operand)
              return nil if operand.nil?

              return operand if expression.operator == "+"
              return -operand if expression.operator == "-"

              nil
            else
              nil
            end
          end

          def statement_terminates?(statement)
            case statement
            when IR::ReturnStmt
              true
            when IR::BreakStmt, IR::ContinueStmt
              true
            when IR::GotoStmt
              true
            when IR::BlockStmt
              body_terminates?(statement.body)
            when IR::IfStmt
              statement.else_body && body_terminates?(statement.then_body) && body_terminates?(statement.else_body)
            when IR::SwitchStmt
              switch_statement_prevents_outer_fallthrough?(statement)
            else
              false
            end
          end

          def statement_prevents_c_fallthrough?(statement)
            case statement
            when IR::ReturnStmt
              true
            when IR::BlockStmt
              !body_needs_fallback_return?(statement.body)
            when IR::IfStmt
              statement.else_body && !body_needs_fallback_return?(statement.then_body) && !body_needs_fallback_return?(statement.else_body)
            when IR::SwitchStmt
              switch_statement_prevents_outer_fallthrough?(statement)
            when IR::WhileStmt
              constant_boolean_value(statement.condition) == true && !contains_visible_loop_exit?(statement.body)
            else
              false
            end
          end

          def statement_prevents_sequential_fallthrough?(statement)
            case statement
            when IR::ReturnStmt, IR::BreakStmt, IR::ContinueStmt, IR::GotoStmt
              true
            when IR::BlockStmt
              !body_has_sequential_fallthrough?(statement.body)
            when IR::IfStmt
              statement.else_body && !body_has_sequential_fallthrough?(statement.then_body) && !body_has_sequential_fallthrough?(statement.else_body)
            when IR::SwitchStmt
              switch_statement_prevents_outer_fallthrough?(statement)
            when IR::WhileStmt
              constant_boolean_value(statement.condition) == true && !contains_visible_loop_exit?(statement.body)
            else
              false
            end
          end

          def switch_statement_prevents_outer_fallthrough?(statement)
            return false unless statement.exhaustive && statement.cases.any?

            statement.cases.all? { |switch_case| switch_case_body_prevents_outer_fallthrough?(switch_case.body) }
          end

          def switch_case_body_prevents_outer_fallthrough?(statements)
            return false if statements.empty?

            switch_case_statement_prevents_outer_fallthrough?(statements.last)
          end

          def switch_case_statement_prevents_outer_fallthrough?(statement)
            case statement
            when IR::ReturnStmt, IR::ContinueStmt, IR::GotoStmt
              true
            when IR::BreakStmt
              false
            when IR::BlockStmt
              switch_case_body_prevents_outer_fallthrough?(statement.body)
            when IR::IfStmt
              statement.else_body &&
                switch_case_body_prevents_outer_fallthrough?(statement.then_body) &&
                switch_case_body_prevents_outer_fallthrough?(statement.else_body)
            when IR::SwitchStmt
              switch_statement_prevents_outer_fallthrough?(statement)
            when IR::WhileStmt
              constant_boolean_value(statement.condition) == true && !contains_visible_loop_exit?(statement.body)
            else
              false
            end
          end

          def body_has_sequential_fallthrough?(statements)
            return true if statements.empty?

            !statement_prevents_sequential_fallthrough?(statements.last)
          end

          def contains_visible_loop_exit?(statements)
            statements.any? do |statement|
              case statement
              when IR::BreakStmt, IR::GotoStmt
                true
              when IR::BlockStmt
                contains_visible_loop_exit?(statement.body)
              when IR::IfStmt
                contains_visible_loop_exit?(statement.then_body) || (statement.else_body && contains_visible_loop_exit?(statement.else_body))
              when IR::SwitchStmt
                statement.cases.any? { |switch_case| contains_visible_loop_exit?(switch_case.body) }
              when IR::WhileStmt, IR::ForStmt
                false
              else
                false
              end
            end
          end

          def collect_used_labels(statements)
            labels = []
            collect_used_labels_from_statements(statements, labels)
            labels.uniq
          end

          def collect_used_labels_from_statements(statements, labels)
            statements.each do |statement|
              case statement
              when IR::BlockStmt, IR::WhileStmt, IR::ForStmt
                collect_used_labels_from_statements(statement.body, labels)
              when IR::IfStmt
                collect_used_labels_from_statements(statement.then_body, labels)
                collect_used_labels_from_statements(statement.else_body, labels) if statement.else_body
              when IR::SwitchStmt
                statement.cases.each do |switch_case|
                  collect_used_labels_from_statements(switch_case.body, labels)
                end
              when IR::GotoStmt
                labels << statement.label
              end
            end
          end

          def block_requires_scope?(statements)
            statements.any? { |statement| statement.is_a?(IR::LocalDecl) }
          end

          def emit_for_clause_statement(statement)
            case statement
            when IR::LocalDecl
              raise LoweringError, "array for-loop init declarations are unsupported" if array_type?(statement.type)

              "#{c_declaration(statement.type, statement.c_name)} = #{emit_initializer(statement.value)}"
            when IR::Assignment
              if array_type?(statement.target.type) && statement.operator == "="
                raise LoweringError, "array for-loop assignment clauses are unsupported"
              end

              "#{emit_expression(statement.target)} #{statement.operator} #{emit_expression(statement.value)}"
            when IR::ExpressionStmt
              emit_expression(statement.expression)
            else
              raise LoweringError, "unsupported for-loop clause #{statement.class.name}"
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
    end
  end
end

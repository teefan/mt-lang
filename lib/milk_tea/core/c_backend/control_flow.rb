# frozen_string_literal: true

module MilkTea
  class CBackend
    module CBackendControlFlow
      private

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
    end
  end
end

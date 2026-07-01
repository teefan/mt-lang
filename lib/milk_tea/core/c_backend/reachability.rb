# frozen_string_literal: true

require "set"

module MilkTea
  class CBackend
    module Reachability
      private

          def emitted_constants
            @emitted_constants ||= begin
              constants_by_name = @program.constants.each_with_object({}) do |constant, result|
                result[constant.linkage_name] = constant
              end
              referenced_names = {}
              root_module_prefix = "#{module_c_prefix(@program.module_name)}_"

              @program.constants.each do |constant|
                next unless constant.linkage_name.start_with?(root_module_prefix)

                referenced_names[constant.linkage_name] = true
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

              @program.constants.select { |constant| referenced_names[constant.linkage_name] }
            end
          end

          def emitted_functions
            @emitted_functions ||= begin
              functions_by_name = @program.functions.each_with_object({}) do |function, result|
                result[function.linkage_name] = function
              end

              seeds = @program.functions.select(&:entry_point)
              if seeds.empty?
                root_module_prefix = "#{module_c_prefix(@program.module_name)}_"
                seeds = @program.functions.select { |function| function.linkage_name.start_with?(root_module_prefix) }
              end

              reachable_names = {}
              worklist = seeds.dup

              until worklist.empty?
                function = worklist.shift
                next if reachable_names[function.linkage_name]

                reachable_names[function.linkage_name] = true
                collect_called_function_names_from_statements(function.body, functions_by_name, reachable_names, worklist)
              end

              (@program.constants + @program.globals).each do |value|
                collect_called_function_names_from_expression(value.value, functions_by_name, reachable_names, worklist)
              end

              until worklist.empty?
                function = worklist.shift
                next if reachable_names[function.linkage_name]

                reachable_names[function.linkage_name] = true
                collect_called_function_names_from_statements(function.body, functions_by_name, reachable_names, worklist)
              end

              @program.functions.select { |function| reachable_names[function.linkage_name] }
            end
          end

          def all_emitted_top_level_values
            emitted_constants + emitted_globals
          end

          def collect_active_module_names
            active = Set.new
            active << @program.module_name

            collect_type_referenced_module_names.each { |mod| active << mod }

            emitted_functions.each do |fn|
              prefix = module_c_prefix(@program.module_name)
              if fn.linkage_name != prefix && !fn.linkage_name.start_with?("#{prefix}_")
                candidate = fn.linkage_name.split("_")
                candidate.pop
                active << candidate.join("_")
              end
            end

            (@program.structs + @program.unions + @program.variants + @program.opaques).each do |decl|
              active << decl.source_module if decl.source_module
            end

            loop do
              size_before = active.size
              (@program.structs + @program.unions).each do |decl|
                next unless decl.source_module
                next unless active.include?(decl.source_module)

                decl.fields.each { |f| add_type_module(f.type, active) }
              end
              @program.variants.each do |decl|
                next unless decl.source_module
                next unless active.include?(decl.source_module)

                decl.arms.each { |arm| arm.fields.each { |f| add_type_module(f.type, active) } }
              end
              break if active.size == size_before
            end

            active
          end

          def collect_type_referenced_module_names
            modules = Set.new
            emitted_functions.each do |fn|
              fn.params.each { |p| add_type_module(p.type, modules) }
              add_type_module(fn.return_type, modules)
              fn.body.each { |stmt| add_statement_type_modules(stmt, modules) }
            end
            modules
          end

          def add_statement_type_modules(stmt, modules)
            case stmt
            when IR::LocalDecl
              add_type_module(stmt.type, modules)
            when IR::ExpressionStmt
              add_expr_type_module(stmt.expression, modules)
            when IR::Assignment
              add_expr_type_module(stmt.value, modules)
            when IR::ReturnStmt
              add_expr_type_module(stmt.value, modules) if stmt.value
            when IR::IfStmt
              stmt.then_body.each { |s| add_statement_type_modules(s, modules) }
              stmt.else_body&.each { |s| add_statement_type_modules(s, modules) }
            when IR::WhileStmt
              stmt.body.each { |s| add_statement_type_modules(s, modules) }
            when IR::ForStmt
              stmt.body.each { |s| add_statement_type_modules(s, modules) }
            end
          end

          def add_expr_type_module(expr, modules)
            return unless expr
            add_type_module(expr.type, modules) if expr.respond_to?(:type)
            case expr
            when IR::Call
              expr.arguments.each { |a| add_expr_type_module(a, modules) }
            when IR::Binary
              add_expr_type_module(expr.left, modules)
              add_expr_type_module(expr.right, modules)
            when IR::AggregateLiteral
              expr.fields.each { |f| add_expr_type_module(f.value, modules) }
            when IR::VariantLiteral
              expr.fields.each { |f| add_expr_type_module(f.value, modules) }
            when IR::Conditional
              add_expr_type_module(expr.then_expression, modules)
              add_expr_type_module(expr.else_expression, modules)
            when IR::Cast, IR::ReinterpretExpr, IR::AddressOf
              add_expr_type_module(expr.expression, modules)
            end
          end

          def add_type_module(type, modules)
            return unless type
            modules << type.module_name if type.respond_to?(:module_name) && type.module_name

            case type
            when Types::Nullable
              add_type_module(type.base, modules)
            when Types::Span
              add_type_module(type.element_type, modules)
            when Types::GenericInstance
              type.arguments.each { |a| add_type_module(a, modules) unless a.is_a?(Types::LiteralTypeArg) }
            when Types::Task
              add_type_module(type.result_type, modules)
            end
          end


          def emitted_aggregate_structs
            @emitted_aggregate_structs ||= filter_by_type_reachability(@program.structs)
          end

          def emitted_aggregate_unions
            @emitted_aggregate_unions ||= filter_by_type_reachability(@program.unions)
          end

          def emitted_aggregate_variants
            @emitted_aggregate_variants ||= filter_by_type_reachability(@program.variants)
          end

          def filter_by_type_reachability(decls)
            return decls if decls.empty?
            return decls if decls.all? { |d| d.source_module.nil? }

            active_modules = collect_active_module_names
            by_c_name = decls.each_with_object({}) { |d, h| h[d.linkage_name] = d }

            reachable = Set.new
            decls.each do |decl|
              next unless decl.source_module.nil? || active_modules.include?(decl.source_module)
              reachable << decl.linkage_name
            end

            worklist = reachable.to_a
            until worklist.empty?
              linkage_name = worklist.shift
              decl = by_c_name[linkage_name]
              next unless decl

              deps = aggregate_decl_dependencies(decl)
              deps.each do |dep_name|
                next unless by_c_name.key?(dep_name)
                next if reachable.include?(dep_name)
                reachable << dep_name
                worklist << dep_name
              end
            end

            decls.select { |d| reachable.include?(d.linkage_name) }
          end

          def emitted_globals
            @emitted_globals ||= begin
              root_module_prefix = "#{module_c_prefix(@program.module_name)}_"
              reachable_names = {}
              @program.globals.select { |g| g.linkage_name.start_with?(root_module_prefix) }.each { |g| reachable_names[g.linkage_name] = true }

              emitted_functions.each do |function|
                traverse_ir_statements(function.body) do |expression|
                  next unless expression.is_a?(IR::Name)
                  global = @program.globals.find { |g| g.linkage_name == expression.name }
                  next unless global
                  next if reachable_names[global.linkage_name]
                  reachable_names[global.linkage_name] = true
                  traverse_ir_expression(global.value) do |inner|
                    next unless inner.is_a?(IR::Name)
                    dep = @program.globals.find { |g| g.linkage_name == inner.name }
                    reachable_names[dep.linkage_name] = true if dep
                  end
                end
              end

              @program.globals.each do |global|
                next unless reachable_names[global.linkage_name]
                traverse_ir_expression(global.value) do |inner|
                  next unless inner.is_a?(IR::Name)
                  dep = @program.globals.find { |g| g.linkage_name == inner.name }
                  reachable_names[dep.linkage_name] = true if dep
                end
              end

              @program.globals.select { |g| reachable_names[g.linkage_name] }
            end
          end

          def collect_called_function_names_from_statements(statements, functions_by_name, reachable_names, worklist)
            traverse_ir_statements(statements) do |expression|
              case expression
              when IR::Name
                callee = functions_by_name[expression.name]
                worklist << callee if callee && !reachable_names[callee.linkage_name]
              when IR::Call
                next unless expression.callee.is_a?(String)

                callee = functions_by_name[expression.callee]
                worklist << callee if callee && !reachable_names[callee.linkage_name]
              end
            end
          end

          def collect_called_function_names_from_expression(expression, functions_by_name, reachable_names, worklist)
            traverse_ir_expression(expression) do |candidate|
              case candidate
              when IR::Name
                callee = functions_by_name[candidate.name]
                worklist << callee if callee && !reachable_names[callee.linkage_name]
              when IR::Call
                next unless candidate.callee.is_a?(String)

                callee = functions_by_name[candidate.callee]
                worklist << callee if callee && !reachable_names[callee.linkage_name]
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
              next if referenced_names[constant.linkage_name]

              referenced_names[constant.linkage_name] = true
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
            when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex, IR::NullableIndex, IR::NullableSpanIndex
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
    end
  end
end

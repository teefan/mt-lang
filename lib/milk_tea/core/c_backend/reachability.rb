# frozen_string_literal: true

require "set"

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
            emitted_constants + emitted_globals
          end

          def collect_active_module_names
            active = Set.new
            active << @program.module_name
            prefix_set = collect_reachable_module_prefixes
            (@program.structs + @program.unions + @program.variants).each do |decl|
              next unless decl.source_module
              active << decl.source_module if prefix_set.include?(module_c_prefix(decl.source_module) + "_")
            end

            collect_type_referenced_module_names.each { |mod| active << mod }

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

          def collect_reachable_module_prefixes
            prefixes = Set.new
            emitted_functions.each do |fn|
              parts = fn.c_name.split("_")
              parts.each_index do |i|
                prefixes << parts[0..i].join("_") + "_"
              end
            end
            prefixes
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
            by_c_name = decls.each_with_object({}) { |d, h| h[d.c_name] = d }

            reachable = Set.new
            decls.each do |decl|
              next unless decl.source_module.nil? || active_modules.include?(decl.source_module)
              reachable << decl.c_name
            end

            worklist = reachable.to_a
            until worklist.empty?
              c_name = worklist.shift
              decl = by_c_name[c_name]
              next unless decl

              deps = aggregate_decl_dependencies(decl)
              deps.each do |dep_name|
                next unless by_c_name.key?(dep_name)
                next if reachable.include?(dep_name)
                reachable << dep_name
                worklist << dep_name
              end
            end

            decls.select { |d| reachable.include?(d.c_name) }
          end

          def emitted_globals
            @emitted_globals ||= begin
              root_module_prefix = "#{module_c_prefix(@program.module_name)}_"
              reachable_names = {}
              @program.globals.select { |g| g.c_name.start_with?(root_module_prefix) }.each { |g| reachable_names[g.c_name] = true }

              emitted_functions.each do |function|
                traverse_ir_statements(function.body) do |expression|
                  next unless expression.is_a?(IR::Name)
                  global = @program.globals.find { |g| g.c_name == expression.name }
                  next unless global
                  next if reachable_names[global.c_name]
                  reachable_names[global.c_name] = true
                  traverse_ir_expression(global.value) do |inner|
                    next unless inner.is_a?(IR::Name)
                    dep = @program.globals.find { |g| g.c_name == inner.name }
                    reachable_names[dep.c_name] = true if dep
                  end
                end
              end

              @program.globals.each do |global|
                next unless reachable_names[global.c_name]
                traverse_ir_expression(global.value) do |inner|
                  next unless inner.is_a?(IR::Name)
                  dep = @program.globals.find { |g| g.c_name == inner.name }
                  reachable_names[dep.c_name] = true if dep
                end
              end

              @program.globals.select { |g| reachable_names[g.c_name] }
            end
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

          def uses_string_view?
            return @uses_string_view if defined?(@uses_string_view)
            @uses_string_view = begin
              uses_fatal_helper? || uses_format_helpers? || uses_str_buffer_helpers? ||
                uses_entrypoint_argv_helpers? || uses_str_equality_helper? ||
                uses_foreign_temp_cstr_helpers? ||
                emitted_functions.any? do |function|
                  type_contains_string_view?(function.return_type) ||
                    function.params.any? { |param| type_contains_string_view?(param.type) }
                end ||
                emitted_aggregate_structs.any? { |s| s.fields.any? { |f| type_contains_string_view?(f.type) } } ||
                emitted_aggregate_unions.any? { |u| u.fields.any? { |f| type_contains_string_view?(f.type) } } ||
                emitted_aggregate_variants.any? { |v| v.arms.any? { |a| a.fields.any? { |f| type_contains_string_view?(f.type) } } } ||
                emitted_constants.any? { |c| type_contains_string_view?(c.type) } ||
                emitted_globals.any? { |g| type_contains_string_view?(g.type) }
            end
          end

          def type_contains_string_view?(type)
            return false unless type
            return true if type.is_a?(Types::StringView)
            case type
            when Types::Nullable
              type_contains_string_view?(type.base)
            when Types::Span
              type_contains_string_view?(type.element_type)
            when Types::GenericInstance
              type.arguments.any? { |a| type_contains_string_view?(a) }
            else
              false
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
            when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex, IR::NullableIndex, IR::NullableSpanIndex
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
            when IR::VariantLiteral
              expression.fields.any? { |field| expression_uses_named_call?(field.value, callees) }
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
            when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex, IR::NullableIndex, IR::NullableSpanIndex
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
            when IR::VariantLiteral
              expression.fields.any? { |field| expression_uses_str_equality?(field.value) }
            else
              false
            end
          end
    end
  end
end

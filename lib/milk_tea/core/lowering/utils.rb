# frozen_string_literal: true

module MilkTea
  module Lowering
    module Utils
      def range_iterable?(expression)
        range_expr?(expression)
      end

      def lower_range_match_condition(range_pattern, scrutinee_ir, bool_type, env:)
        start_ir = lower_expression(range_pattern.start_expr, env:, expected_type: nil)
        end_ir   = lower_expression(range_pattern.end_expr, env:, expected_type: nil)
        ge = IR::Binary.new(operator: ">=", left: scrutinee_ir, right: start_ir, type: bool_type)
        le = IR::Binary.new(operator: "<=", left: scrutinee_ir, right: end_ir, type: bool_type)
        IR::Binary.new(operator: "and", left: ge, right: le, type: bool_type)
      end

      def range_start_of(iterable)
        iterable.start_expr
      end

      def range_end_of(iterable)
        iterable.end_expr
      end

      def wildcard_arm_pattern?(expression)
        expression.is_a?(AST::Identifier) && expression.name == "_"
      end

      def variant_match_arm_name_from_pattern(pattern)
        callee = case pattern
        when AST::Call
          pattern.callee
        else
          pattern
        end
        callee.is_a?(AST::MemberAccess) ? callee.member : nil
      end

      def array_type?(type)
        type.is_a?(Types::GenericInstance) && type.name == "array" && type.arguments.length == 2 &&
          type.arguments[1].is_a?(Types::LiteralTypeArg)
      end

      def simd_type?(type)
        type.is_a?(Types::Simd)
      end

      def array_element_type(type)
        return unless array_type?(type)

        type.arguments.first
      end

      def array_to_span_compatible?(actual_type, expected_type)
        array_type?(actual_type) && expected_type.is_a?(Types::Span) && array_element_type(actual_type) == expected_type.element_type
      end

      def cstr_trackable_type?(type)
        type == @ctx.types.fetch("str") || type == @ctx.types.fetch("cstr")
      end

      def struct_contains_string_field?(type)
        return false unless type.is_a?(Types::Struct)

        type.fields.any? { |_name, field_type| cstr_trackable_type?(field_type) || struct_contains_string_field?(field_type) }
      end

      def reject_format_releases_for_assignment(cleanups, target_type)
        return cleanups unless cstr_trackable_type?(target_type) || struct_contains_string_field?(target_type)

        cleanups.reject do |items|
          items.any? { |stmt| stmt.is_a?(IR::ExpressionStmt) && stmt.expression.is_a?(IR::Call) && stmt.expression.callee == "mt_format_str_release" }
        end
      end

      def cstr_list_trackable_type?(type)
        return false unless array_type?(type)

        element_type = array_element_type(type)
        element_type == @ctx.types.fetch("str") || element_type == @ctx.types.fetch("cstr")
      end

      def str_buffer_to_span_compatible?(actual_type, expected_type)
        str_buffer_type?(actual_type) && expected_type.is_a?(Types::Span) && expected_type.element_type == @ctx.types.fetch("char")
      end

      def array_length(type)
        return unless array_type?(type)

        type.arguments[1].value
      end

      def char_array_text_type?(type)
        array_type?(type) && array_element_type(type) == @ctx.types.fetch("char")
      end

      def str_buffer_type?(type)
        type.is_a?(Types::GenericInstance) && type.name == "str_buffer" && type.arguments.length == 1 &&
          type.arguments.first.is_a?(Types::LiteralTypeArg) && type.arguments.first.value.is_a?(Integer)
      end

      def str_buffer_capacity(type)
        type.arguments.first.value
      end

      def str_buffer_storage_capacity(type)
        str_buffer_capacity(type) + 1
      end

      def addressable_storage_expression?(expression)
        case expression
        when AST::Identifier
          true
        when AST::MemberAccess, AST::IndexAccess
          addressable_storage_expression?(expression.receiver)
        when AST::Call
          read_call?(expression)
        else
          false
        end
      end

      def read_call?(expression)
        expression.is_a?(AST::Call) && expression.callee.is_a?(AST::Identifier) && expression.callee.name == "read"
      end

      def infer_value_type(handle_expression, env:)
        handle_type = infer_expression_type(handle_expression, env:)
        return referenced_type(handle_type) if ref_type?(handle_type)
        return pointee_type(handle_type) if pointer_type?(handle_type)

        raise LoweringError.new("read expects ref[...] or ptr[...], got #{handle_type}", line: 0, column: 0, path: @ctx.current_analysis_path)
      end

      def infer_method_receiver_type(receiver_expression, env:, member_name: nil)
        receiver_type = infer_expression_type(receiver_expression, env:)
        receiver_type = referenced_type(receiver_type) if ref_type?(receiver_type)

        if pointer_type?(receiver_type)
          dispatch_receiver_type = method_dispatch_receiver_type(receiver_type)
          return receiver_type if member_name && (@method_definitions.key?([receiver_type, member_name]) || @method_definitions.key?([dispatch_receiver_type, member_name]) || @method_definitions.key?([receiver_type, "static:#{member_name}"]) || @method_definitions.key?([dispatch_receiver_type, "static:#{member_name}"]))

          return pointee_type(receiver_type)
        end

        receiver_type
      end

      def infer_field_receiver_type(receiver_expression, env:)
        receiver_type = infer_expression_type(receiver_expression, env:)
        return referenced_type(receiver_type) if ref_type?(receiver_type)
        return pointee_type(receiver_type) if pointer_type?(receiver_type)

        receiver_type
      end

      def collection_loop_type(type)
        super
      end

      def collection_loop_binding_type(iterable_type, element_type)
        super
      end

      def collection_loop_ref_element_type?(type)
        super
      end

      def collection_loop_item_value(iterable_ref, iterable_type, index_ref, element_type)
        if array_type?(iterable_type)
          IR::Index.new(receiver: iterable_ref, index: index_ref, type: element_type)
        else
          data_ref = IR::Member.new(receiver: iterable_ref, member: "data", type: pointer_to(element_type))
          IR::Index.new(receiver: data_ref, index: index_ref, type: element_type)
        end
      end

      def collection_loop_stop_value(iterable_ref, iterable_type)
        if array_type?(iterable_type)
          IR::IntegerLiteral.new(value: array_length(iterable_type), type: @ctx.types.fetch("ptr_uint"))
        else
          IR::Member.new(receiver: iterable_ref, member: "len", type: @ctx.types.fetch("ptr_uint"))
        end
      end

      def lower_fatal_statement(message, env:)
        IR::ExpressionStmt.new(
          expression: lower_expression(
            AST::Call.new(
              callee: AST::Identifier.new(name: "fatal"),
              arguments: [AST::Argument.new(name: nil, value: AST::StringLiteral.new(lexeme: message.inspect, value: message, cstring: false))],
            ),
            env:,
            expected_type: @ctx.types.fetch("void"),
          ),
        )
      end

      def infer_range_loop_type(expression, env:)
        start_expr = range_start_of(expression)
        stop_expr = range_end_of(expression)
        start_type = infer_expression_type(start_expr, env:)
        stop_type = infer_expression_type(stop_expr, env:)

        if start_type != stop_type
          if start_expr.is_a?(AST::IntegerLiteral)
            start_type = infer_expression_type(start_expr, env:, expected_type: stop_type)
          elsif stop_expr.is_a?(AST::IntegerLiteral)
            stop_type = infer_expression_type(stop_expr, env:, expected_type: start_type)
          end
        end

        raise LoweringError.new("range bounds must use matching integer types, got #{start_type} and #{stop_type}", line: 0, column: 0, path: @ctx.current_analysis_path) unless start_type == stop_type

        start_type
      end

      def integer_type?(type)
        type.is_a?(Types::Primitive) && type.integer?
      end

      def infer_index_result_type(receiver_type, index_type)
        raise LoweringError.new("index must be an integer type, got #{index_type}", line: 0, column: 0, path: @ctx.current_analysis_path) unless integer_type?(index_type)

        receiver_type = referenced_type(receiver_type) if ref_type?(receiver_type)

        if array_type?(receiver_type)
          return array_element_type(receiver_type)
        end

        if receiver_type.is_a?(Types::Span)
          return receiver_type.element_type
        end

        if receiver_type.is_a?(Types::SoA)
          return receiver_type.element_type
        end

        if simd_type?(receiver_type)
          return receiver_type.element_type
        end

        if pointer_type?(receiver_type)
          return pointee_type(receiver_type)
        end

        raise LoweringError.new("cannot index #{receiver_type}", line: 0, column: 0, path: @ctx.current_analysis_path)
      end

      def contains_type_var?(type)
        super
      end


      def stored_ref_supported_type?(type, visited = {})
        return true unless type

        visit_key = [type.class, type.object_id]
        return true if visited[visit_key]

        visited[visit_key] = true
        case type
        when Types::Nullable
          stored_ref_supported_type?(type.base, visited)
        when Types::GenericInstance
          if ref_type?(type)
            lt = ref_lifetime(type)
            return !!lt  # lifetime-ref is supported by default; bare ref is not
          end

          type.arguments.all? { |argument| argument.is_a?(Types::LiteralTypeArg) || stored_ref_supported_type?(argument, visited) }
        when Types::Span
          stored_ref_supported_type?(type.element_type, visited)
        when Types::Task
          stored_ref_supported_type?(type.result_type, visited)
        when Types::StructInstance, Types::VariantInstance
          type.arguments.all? { |argument| stored_ref_supported_type?(argument, visited) }
        when Types::Proc, Types::Function
          callable_param_ref_supported?(type)
        else
          !contains_ref_type?(type)
        end
      end

      def pointer_to(type)
        Types::Registry.generic_instance("ptr", [type])
      end

      def with_analysis_context(analysis)
        saved = @ctx.save
        @ctx.install(analysis)
        @ctx.module_prefix = module_c_prefix(@ctx.module_name)
        yield
      ensure
        @ctx.restore(saved)
      end

      def lookup_value(name, env)
        env[:scopes].reverse_each do |scope|
          return scope[name] if scope.key?(name)
        end

        if @ctx.values.key?(name)
          binding = @ctx.values.fetch(name)
          {
            type: binding.type,
            storage_type: binding.storage_type,
            linkage_name: value_c_name(name),
            mutable: binding.mutable,
            pointer: false,
            cstr_backed: cstr_trackable_type?(binding.type) && binding.const_value.is_a?(String),
            cstr_list_backed: false,
            const_value: binding.const_value,
          }
        end
      end

      def lower_static_storage_initializer(expression, env:, expected_type: nil)
        if expected_type && (literal = lower_compile_time_literal(compile_time_const_value(expression, env:), expected_type))
          return literal
        end

        rewritten = rewrite_static_storage_initializer(expression)
        if (imported_analysis = static_storage_imported_analysis(expression))
          with_analysis_context(imported_analysis) do
            lower_expression(rewritten, env:, expected_type: expected_type)
          end
        else
          lower_expression(rewritten, env:, expected_type: expected_type)
        end
      end

      def static_storage_imported_analysis(expression)
        return nil unless expression.is_a?(AST::MemberAccess)
        return nil unless expression.receiver.is_a?(AST::Identifier)
        return nil unless @ctx.imports.key?(expression.receiver.name)

        imported_module = @ctx.imports.fetch(expression.receiver.name)
        return nil unless imported_module.values[expression.member]&.kind == :const

        analysis_for_module(imported_module.name)
      end

      def lower_compile_time_literal(value, type)
        case value
        when true, false
          return IR::BooleanLiteral.new(value:, type:) if type.is_a?(Types::Primitive) && type.boolean?
        when Integer
          return IR::IntegerLiteral.new(value:, type:) if type.is_a?(Types::Primitive) && type.integer?
          return IR::FloatLiteral.new(value: value.to_f, type:) if type.is_a?(Types::Primitive) && type.float?
        when Float
          return IR::FloatLiteral.new(value:, type:) if type.is_a?(Types::Primitive) && type.float?
        when String
          if type == @ctx.types.fetch("str") || type == @ctx.types.fetch("cstr")
            return IR::StringLiteral.new(value:, type:, cstring: type == @ctx.types.fetch("cstr"))
          end
        when Array
          return nil unless array_type?(type)

          element_type = type.arguments.first
          elements = value.map { |element| lower_compile_time_literal(element, element_type) }
          return nil if elements.any?(&:nil?)

          IR::ArrayLiteral.new(type:, elements:)
        when Hash
          return nil unless type.is_a?(Types::Struct)
          fields = value.map do |name, field_value|
            field_type = type.field(name)
            return nil unless field_type
            lowered = lower_compile_time_literal(field_value, field_type)
            return nil unless lowered
            IR::AggregateField.new(name:, value: lowered)
          end
          return IR::AggregateLiteral.new(type:, fields:)
        end

        nil
      end

      def compile_time_builtin_function_type(name, arguments, env)
        return_type = case name
        when "field_of"
          @ctx.types.fetch("field_handle")
        when "callable_of"
          @ctx.types.fetch("callable_handle")
        when "has_attribute"
          @ctx.types.fetch("bool")
        when "attribute_of"
          @ctx.types.fetch("attribute_handle")
        else
          nil
        end
        raise LoweringError.new("unsupported compile-time builtin #{name}", line: 0, column: 0, path: @ctx.current_analysis_path) unless return_type

        Types::Registry.function(name, params: [], return_type: return_type)
      end

      def compile_time_builtin_specialization_function_type(callee)
        Types::Registry.function("attribute_arg", params: [], return_type: resolve_type_ref(callee.arguments.fetch(0).value))
      end

      def rewrite_static_storage_initializer(expression)
        case expression
        when AST::Identifier
          binding = @ctx.values[expression.name]
          if binding&.kind == :const
            declaration = const_declaration_for_module(@ctx.module_name, expression.name)
            return rewrite_static_storage_initializer(declaration.value)
          end

          expression
        when AST::MemberAccess
          if expression.receiver.is_a?(AST::Identifier) && @ctx.imports.key?(expression.receiver.name)
            imported_module = @ctx.imports.fetch(expression.receiver.name)
            if (binding = imported_module.values[expression.member])&.kind == :const
              imported_analysis = analysis_for_module(imported_module.name)
              declaration = const_declaration_for_module(imported_module.name, expression.member)
              return with_analysis_context(imported_analysis) do
                rewrite_static_storage_initializer(declaration.value)
              end
            end
          end

          AST::MemberAccess.new(
            receiver: rewrite_static_storage_initializer(expression.receiver),
            member: expression.member,
          )
        when AST::UnaryOp
          AST::UnaryOp.new(operator: expression.operator, operand: rewrite_static_storage_initializer(expression.operand))
        when AST::BinaryOp
          AST::BinaryOp.new(
            operator: expression.operator,
            left: rewrite_static_storage_initializer(expression.left),
            right: rewrite_static_storage_initializer(expression.right),
          )
        when AST::IfExpr
          AST::IfExpr.new(
            condition: rewrite_static_storage_initializer(expression.condition),
            then_expression: rewrite_static_storage_initializer(expression.then_expression),
            else_expression: rewrite_static_storage_initializer(expression.else_expression),
          )
        when AST::UnsafeExpr
          AST::UnsafeExpr.new(expression: rewrite_static_storage_initializer(expression.expression))
        when AST::Call
          AST::Call.new(
            callee: rewrite_static_storage_initializer(expression.callee),
            arguments: expression.arguments.map do |argument|
              AST::Argument.new(name: argument.name, value: rewrite_static_storage_initializer(argument.value))
            end,
          )
        when AST::Specialization
          AST::Specialization.new(
            callee: rewrite_static_storage_initializer(expression.callee),
            arguments: expression.arguments.map { |argument| AST::TypeArgument.new(value: argument.value) },
          )
        else
          expression
        end
      end

      def local_binding(type:, linkage_name:, mutable:, pointer:, storage_type: nil, projection: nil, cstr_backed: false, cstr_list_backed: false, const_value: nil)
        { type:, storage_type: storage_type || type, linkage_name:, mutable:, pointer:, projection:, cstr_backed:, cstr_list_backed:, const_value: }
      end

      def callable_type?(type)
        type.is_a?(Types::Function) || proc_type?(type)
      end

      def contains_proc_storage_type?(type, visited = Set.new)
        return false if visited.include?(type.object_id)

        case type
        when Types::Proc
          true
        when Types::Struct, Types::StructInstance
          visited.add(type.object_id)
          type.fields.each_value.any? { |field_type| contains_proc_storage_type?(field_type, visited) }
        when Types::Nullable
          contains_proc_storage_type?(type.base, visited)
        else
          false
        end
      end

      def contains_task_type?(type, visited = Set.new)
        return false if visited.include?(type.object_id)

        case type
        when Types::Task
          true
        when Types::Struct, Types::StructInstance, Types::Union, Types::GenericStructDefinition, Types::VariantArmPayload
          visited.add(type.object_id)
          type.fields.each_value.any? { |ft| contains_task_type?(ft, visited) }
        when Types::VariantInstance
          type.arguments.any? { |arg| contains_task_type?(arg, visited) }
        when Types::Variant, Types::GenericVariantDefinition
          visited.add(type.object_id)
          type.arms.each_value.any? do |arm_fields|
            arm_fields.each_value.any? { |ft| contains_task_type?(ft, visited) }
          end
        when Types::GenericInstance
          type.arguments.any? { |arg| contains_task_type?(arg, visited) }
        when Types::Nullable
          contains_task_type?(type.base, visited)
        else
          false
        end
      end

      def proc_env_pointer_type
        @proc_env_pointer_type ||= pointer_to(@ctx.types.fetch("void"))
      end

      def proc_invoke_function_type(proc_type)
        Types::Registry.function(
          nil,
          params: [Types::Registry.parameter("env", proc_env_pointer_type), *proc_type.params],
          return_type: proc_type.return_type,
        )
      end

      def proc_release_function_type
        @proc_release_function_type ||= Types::Registry.function(
          nil,
          params: [Types::Registry.parameter("env", proc_env_pointer_type)],
          return_type: @ctx.types.fetch("void"),
        )
      end

      def proc_retain_function_type
        @proc_retain_function_type ||= Types::Registry.function(
          nil,
          params: [Types::Registry.parameter("env", proc_env_pointer_type)],
          return_type: @ctx.types.fetch("void"),
        )
      end

      def fresh_proc_symbol
        @synthetic_proc_counter += 1
      end

      def current_actual_scope(scopes)
        scopes.reverse_each do |scope|
          return scope unless scope.is_a?(FlowScope)
        end

        raise LoweringError.new("missing lexical scope", line: 0, column: 0, path: @ctx.current_analysis_path)
      end

      def env_with_refinements(env, refinements)
        updated = env.dup
        updated[:scopes] = scopes_with_refinements(env[:scopes], refinements)
        updated
      end

      def scopes_with_refinements(scopes, refinements)
        return scopes if refinements.nil? || refinements.empty?

        base_scopes = scopes.last.is_a?(FlowScope) ? scopes[0...-1] : scopes
        merged_refinements = scopes.last.is_a?(FlowScope) ? scopes.last.each_with_object({}) { |(name, binding), result| result[name] = binding[:type] } : {}
        merged_refinements = merge_refinements(merged_refinements, refinements)
        flow_scope = FlowScope.new

        merged_refinements.each do |name, refined_type|
          binding = lookup_value(name, { scopes: base_scopes })
          next unless binding

          flow_scope[name] = binding.merge(type: refined_type)
        end

        return base_scopes if flow_scope.empty?

        base_scopes + [flow_scope]
      end

      def merge_refinements(existing, incoming)
        merged = existing.dup
        incoming.each do |name, refined_type|
          if merged.key?(name) && merged[name] != refined_type
            merged.delete(name)
          else
            merged[name] = refined_type
          end
        end

        merged
      end

      def flow_refinements(expression, truthy:, env:)
        case expression
        when AST::UnaryOp
          return flow_refinements(expression.operand, truthy: !truthy, env:) if expression.operator == "not"
        when AST::BinaryOp
          case expression.operator
          when "and"
            if truthy
              left_truthy = flow_refinements(expression.left, truthy: true, env:)
              right_env = env_with_refinements(env, left_truthy)
              right_truthy = flow_refinements(expression.right, truthy: true, env: right_env)
              return merge_refinements(left_truthy, right_truthy)
            end
          when "or"
            unless truthy
              left_falsy = flow_refinements(expression.left, truthy: false, env:)
              right_env = env_with_refinements(env, left_falsy)
              right_falsy = flow_refinements(expression.right, truthy: false, env: right_env)
              return merge_refinements(left_falsy, right_falsy)
            end
          when "==", "!="
            return null_test_refinements(expression, truthy:, env:)
          end
        end

        {}
      end

      def null_test_refinements(expression, truthy:, env:)
        identifier_expression = nil
        if expression.left.is_a?(AST::Identifier) && expression.right.is_a?(AST::NullLiteral)
          identifier_expression = expression.left
        elsif expression.left.is_a?(AST::NullLiteral) && expression.right.is_a?(AST::Identifier)
          identifier_expression = expression.right
        else
          return {}
        end

        binding = lookup_value(identifier_expression.name, env)
        return {} unless binding && binding[:storage_type].is_a?(Types::Nullable)

        null_result = expression.operator == "==" ? truthy : !truthy
        refined_type = null_result ? null_type : binding[:storage_type].base
        { identifier_expression.name => refined_type }
      end

      def cfg_block_always_terminates?(statements)
        ControlFlow::Termination.block_always_terminates?(statements, ignore_name: ->(_name) { false })
      end

      def conditional_common_type(then_type, else_type)
        return then_type if then_type == else_type

        numeric_type = common_numeric_type(then_type, else_type)
        return numeric_type if numeric_type

        if (nullable_type = conditional_null_common_type(then_type, else_type))
          return nullable_type
        end

        if (nullable_type = conditional_null_common_type(else_type, then_type))
          return nullable_type
        end

        return then_type if then_type.is_a?(Types::Nullable) && else_type == then_type.base
        return else_type if else_type.is_a?(Types::Nullable) && then_type == else_type.base

        nil
      end

      def if_expression_branch_compatible?(actual_type, expected_type)
        return true if actual_type == expected_type
        return true if null_assignable_to?(actual_type, expected_type)
        return true if expected_type.is_a?(Types::Nullable) && actual_type == expected_type.base
        return true if common_numeric_type(actual_type, expected_type) == expected_type

        false
      end

      def nullable_candidate?(type)
        !ref_type?(type) && type != @ctx.types.fetch("void")
      end

      def conditional_null_common_type(null_type, other_type)
        return unless null_type.is_a?(Types::Null)

        if other_type.is_a?(Types::Nullable)
          return other_type if null_type.target_type.nil? || null_type.target_type == other_type.base

          return nil
        end

        return unless nullable_candidate?(other_type)
        return if null_type.target_type && null_type.target_type != other_type

        Types::Registry.nullable(other_type)
      end

      def null_type
        @null_type ||= Types::Null.new
      end

      def loop_flow(break_target:, continue_target:, break_defers: [], continue_defers: [])
        {
          break_target:,
          continue_target:,
          break_defers:,
          continue_defers:,
        }
      end

      def nested_loop_flow(current_loop_flow, local_defers)
        return nil unless current_loop_flow

        loop_flow(
          break_target: current_loop_flow[:break_target],
          continue_target: current_loop_flow[:continue_target],
          break_defers: current_loop_flow[:break_defers] + local_defers,
          continue_defers: current_loop_flow[:continue_defers] + local_defers,
        )
      end

      def switch_loop_target(target)
        return target unless target && target[:label]

        loop_exit_label(target[:label])
      end

      def switch_loop_flow(current_loop_flow, local_defers)
        nested = nested_loop_flow(current_loop_flow, local_defers)
        return nil unless nested

        loop_flow(
          break_target: switch_loop_target(nested[:break_target]),
          continue_target: switch_loop_target(nested[:continue_target]),
          break_defers: nested[:break_defers],
          continue_defers: nested[:continue_defers],
        )
      end

      def cleanup_statements(local_defers, outer_defers)
        local_defers.reverse.flat_map(&:itself) + outer_defers.reverse.flat_map(&:itself)
      end

      def loop_exit_break(label = nil)
        { kind: :break, label: }
      end

      def loop_exit_continue(label = nil)
        { kind: :continue, label: }
      end

      def loop_exit_label(label)
        { kind: :label, label: }
      end

      def loop_exit_statement(target, local_defers:, outer_defers:)
        case target[:kind]
        when :break
          IR::BreakStmt.new
        when :continue
          IR::ContinueStmt.new
        when :label
          return IR::GotoStmt.new(label: target[:label]) if target[:label]

          IR::GotoStmt.new(label: target[:label])
        else
          raise LoweringError.new("unsupported loop exit target #{target.inspect}", line: 0, column: 0, path: @ctx.current_analysis_path)
        end
      end

      def lower_loop_exit(target, local_defers, outer_defers)
        cleanup = cleanup_statements(local_defers, outer_defers)
        if cleanup.empty?
          [loop_exit_statement(target, local_defers:, outer_defers:)]
        else
          label = target[:label]
          raise LoweringError.new("structured loop exits with cleanup are unsupported", line: 0, column: 0, path: @ctx.current_analysis_path) unless label

          cleanup + [IR::GotoStmt.new(label:)]
        end
      end

      def contains_label_target?(statements, label)
        statements.any? do |statement|
          case statement
          when IR::GotoStmt
            statement.label == label
          when IR::BlockStmt, IR::WhileStmt, IR::ForStmt
            contains_label_target?(statement.body, label)
          when IR::IfStmt
            contains_label_target?(statement.then_body, label) || (statement.else_body && contains_label_target?(statement.else_body, label))
          when IR::SwitchStmt
            statement.cases.any? { |switch_case| contains_label_target?(switch_case.body, label) }
          else
            false
          end
        end
      end

      def lower_defer_cleanup_body(statements, env:, return_type:)
        lower_block(statements, env:, active_defers: [], return_type:, loop_flow: nil, allow_return: false)
      end

      def terminating_ir_statement?(statement)
        statement.is_a?(IR::ReturnStmt) || statement.is_a?(IR::GotoStmt)
      end

      def empty_env
        { scopes: [{}], counter: { value: 0 } }
      end

      def snapshot_env(env)
        { scopes: env[:scopes].map(&:dup), counter: env[:counter] }
      end

      def duplicate_env(env)
        duplicated = env.dup
        duplicated[:scopes] = env[:scopes].map(&:dup) + [{}]
        duplicated[:counter] = env[:counter]
        duplicated.delete(:prepared_expression_cleanups)
        duplicated
      end

      def let_else_discards_binding?(statement)
        statement.is_a?(AST::LocalDecl) && statement.else_body && statement.name == "_"
      end

      def bind_let_else_local?(statement)
        !let_else_discards_binding?(statement)
      end

      def let_else_storage_c_name(statement, env)
        return fresh_c_temp_name(env, "let_else_discard") if let_else_discards_binding?(statement)

        return fresh_c_temp_name(env, "_") if statement.name == "_"

        c_local_name(statement.name)
      end

      def let_else_success_type(type)
        return type.base if type.is_a?(Types::Nullable)
        return type.arm("some").fetch("value") if option_let_else_type?(type)
        return unless result_let_else_type?(type)

        type.arm("success").fetch("value")
      end

      def let_else_error_type(type)
        return unless result_let_else_type?(type)

        type.arm("failure").fetch("error")
      end

      def let_else_binding_projection(type)
        return :result_success_value if result_let_else_type?(type)
        return :option_some_value if option_let_else_type?(type)

        nil
      end

      def option_let_else_type?(type)
        return false unless type.is_a?(Types::Variant)

        some_fields = type.arm("some")
        none_fields = type.arm("none")
        some_fields && some_fields.length == 1 && some_fields.key?("value") &&
          none_fields && none_fields.empty?
      end

      def result_let_else_type?(type)
        return false unless type.is_a?(Types::Variant)

        success_fields = type.arm("success")
        failure_fields = type.arm("failure")
        success_fields && success_fields.length == 1 && success_fields.key?("value") &&
          failure_fields && failure_fields.length == 1 && failure_fields.key?("error")
      end

      def let_else_failure_condition(storage_expr, storage_type)
        if storage_type.is_a?(Types::Nullable)
          return IR::Binary.new(
            operator: "==",
            left: storage_expr,
            right: IR::NullLiteral.new(type: storage_type),
            type: @ctx.types.fetch("bool"),
          )
        end

        if result_let_else_type?(storage_type)
          kind_type = @ctx.types.fetch("int")
          return IR::Binary.new(
            operator: "==",
            left: IR::Member.new(receiver: storage_expr, member: "kind", type: kind_type),
            right: IR::Name.new(name: "#{c_type_name(storage_type)}_kind_failure", type: kind_type, pointer: false),
            type: @ctx.types.fetch("bool"),
          )
        end

        if option_let_else_type?(storage_type)
          kind_type = @ctx.types.fetch("int")
          return IR::Binary.new(
            operator: "==",
            left: IR::Member.new(receiver: storage_expr, member: "kind", type: kind_type),
            right: IR::Name.new(name: "#{c_type_name(storage_type)}_kind_none", type: kind_type, pointer: false),
            type: @ctx.types.fetch("bool"),
          )
        end

        raise LoweringError.new("unsupported let-else storage type #{storage_type}", line: 0, column: 0, path: @ctx.current_analysis_path)
      end

      def lower_bound_identifier(binding, expected_type: nil)
        storage_type = binding[:storage_type]
        visible_type = binding[:type]
        projection = binding[:projection]

        if projection == :result_success_value
          local_ref = IR::Name.new(name: binding[:linkage_name], type: storage_type, pointer: binding[:pointer])
          return variant_binding_projection_expression(local_ref, storage_type, "success", "value", visible_type)
        end

        if projection == :result_failure_error
          local_ref = IR::Name.new(name: binding[:linkage_name], type: storage_type, pointer: binding[:pointer])
          return variant_binding_projection_expression(local_ref, storage_type, "failure", "error", visible_type)
        end

        if projection == :option_some_value
          local_ref = IR::Name.new(name: binding[:linkage_name], type: storage_type, pointer: binding[:pointer])
          return variant_binding_projection_expression(local_ref, storage_type, "some", "value", visible_type)
        end

        return IR::Name.new(name: binding[:linkage_name], type: visible_type, pointer: binding[:pointer]) if visible_type == storage_type
        if storage_type.is_a?(Types::Nullable) && storage_type.base == visible_type
          name = IR::Name.new(name: binding[:linkage_name], type: storage_type, pointer: binding[:pointer])
          return name if pointer_like_type?(storage_type.base)
          return name if expected_type == storage_type
          return IR::Member.new(receiver: name, member: "value", type: visible_type)
        end

        if result_let_else_type?(storage_type) && let_else_success_type(storage_type) == visible_type
          local_ref = IR::Name.new(name: binding[:linkage_name], type: storage_type, pointer: binding[:pointer])
          return variant_binding_projection_expression(local_ref, storage_type, "success", "value", visible_type)
        end

        if option_let_else_type?(storage_type) && let_else_success_type(storage_type) == visible_type
          local_ref = IR::Name.new(name: binding[:linkage_name], type: storage_type, pointer: binding[:pointer])
          return variant_binding_projection_expression(local_ref, storage_type, "some", "value", visible_type)
        end

        IR::Name.new(name: binding[:linkage_name], type: visible_type, pointer: binding[:pointer])
      end

      def variant_binding_projection_expression(storage_expr, storage_type, arm_name, field_name, field_type)
        payload_type = Types::VariantArmPayload.new(storage_type, arm_name, storage_type.arm(arm_name))
        data_expr = IR::Member.new(receiver: storage_expr, member: "data", type: nil)
        arm_expr = IR::Member.new(receiver: data_expr, member: arm_name, type: payload_type)
        member_expr = IR::Member.new(receiver: arm_expr, member: field_name, type: field_type)
        if type_reaches_target?(field_type, payload_type.variant_type)
          return IR::Unary.new(operator: "*", operand: member_expr, type: field_type)
        end

        member_expr
      end

      def infer_result_propagation_type(expression, env:)
        _storage_type, success_type, = infer_result_propagation_types(expression, env:)

        success_type
      end

      def infer_result_propagation_types(expression, env:, allow_void_success: false)
        storage_type = infer_expression_type(expression.operand, env:)
        if result_let_else_type?(storage_type)
          infer_result_propagation_details(storage_type, env:, allow_void_success:)
        elsif option_let_else_type?(storage_type)
          infer_option_propagation_details(storage_type, env:, allow_void_success:)
        else
          raise LoweringError.new("propagation expects Result[T, E] or Option[T], got #{storage_type}", line: 0, column: 0, path: @ctx.current_analysis_path)
        end
      end

      def infer_result_propagation_details(storage_type, env:, allow_void_success:)
        success_type = let_else_success_type(storage_type)
        error_type = let_else_error_type(storage_type)
        raise LoweringError.new("propagation requires a non-void Result success type", line: 0, column: 0, path: @ctx.current_analysis_path) if success_type == @ctx.types.fetch("void") && !allow_void_success

        context = env[:return_context]
        raise LoweringError.new("propagation is only allowed inside function and proc bodies", line: 0, column: 0, path: @ctx.current_analysis_path) unless context
        raise LoweringError.new("propagation is not allowed inside defer blocks", line: 0, column: 0, path: @ctx.current_analysis_path) unless context[:allow_return]

        return_type = context[:return_type]
        unless result_let_else_type?(return_type)
          raise LoweringError.new("propagation requires enclosing function/proc to return Result[_, #{error_type}], got #{return_type}", line: 0, column: 0, path: @ctx.current_analysis_path)
        end

        return_error_type = let_else_error_type(return_type)
        unless return_error_type == error_type
          raise LoweringError.new("propagation error type #{error_type} must match enclosing Result error type #{return_error_type}", line: 0, column: 0, path: @ctx.current_analysis_path)
        end

        [storage_type, success_type, return_type, error_type]
      end

      def infer_option_propagation_details(storage_type, env:, allow_void_success:)
        success_type = let_else_success_type(storage_type)
        raise LoweringError.new("propagation requires a non-void Option success type", line: 0, column: 0, path: @ctx.current_analysis_path) if success_type == @ctx.types.fetch("void") && !allow_void_success

        context = env[:return_context]
        raise LoweringError.new("propagation is only allowed inside function and proc bodies", line: 0, column: 0, path: @ctx.current_analysis_path) unless context
        raise LoweringError.new("propagation is not allowed inside defer blocks", line: 0, column: 0, path: @ctx.current_analysis_path) unless context[:allow_return]

        return_type = context[:return_type]
        unless option_let_else_type?(return_type)
          raise LoweringError.new("propagation requires enclosing function/proc to return Option[_], got #{return_type}", line: 0, column: 0, path: @ctx.current_analysis_path)
        end

        [storage_type, success_type, return_type, nil]
      end

      def c_type_name(type)
        if type.is_a?(Types::Nullable)
          return "nullable_#{c_type_name(type.base)}"
        end

        if type.respond_to?(:linkage_name) && type.linkage_name
          return type.linkage_name
        end

        if type.is_a?(Types::GenericInstance)
          base = if type.respond_to?(:module_name) && type.module_name&.start_with?("std.c.")
            type.name
          elsif type.respond_to?(:module_name) && !type.module_name.nil?
            "#{module_c_prefix(type.module_name)}_#{type.name}"
          else
            type.name
          end

          return "#{base}_#{sanitize_identifier(type.arguments.join('_'))}"
        end

        return type.name if type.respond_to?(:module_name) && type.module_name&.start_with?("std.c.")

        base = (type.respond_to?(:module_name) && type.module_name) ? "#{module_c_prefix(type.module_name)}_#{type.name}" : type.name
        return base unless type.is_a?(Types::StructInstance) || type.is_a?(Types::VariantInstance)

        "#{base}_#{sanitize_identifier(type.arguments.join('_'))}"
      end

      def opaque_c_type_name(type)
        type.linkage_name || c_type_name(type)
      end

      def opaque_forward_declarable?(type)
        return false unless opaque_c_type_name(type).match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)

        !type.external || type.linkage_name.nil?
      end

      def forward_declarable_external_opaque?(type)
        type.external && opaque_forward_declarable?(type)
      end

      def validate_generic_type!(name, arguments)
        super(name, arguments) { |msg| raise LoweringError.new(msg, line: 0, column: 0, path: @ctx.current_analysis_path) }
      end

      def integer_type_argument?(argument)
        argument.is_a?(Types::LiteralTypeArg) && argument.value.is_a?(Integer)
      end

      def generic_integer_type_argument?(argument)
        integer_type_argument?(argument) || argument.is_a?(Types::TypeVar)
      end

      def enum_member_c_name(type, member_name)
        "#{c_type_name(type)}_#{member_name}"
      end

      def function_binding_c_name(binding, module_name:, receiver_type: nil)
        if receiver_type.nil? && binding.name == "main" && binding.type_arguments.empty?
          return binding.async ? module_function_c_name(module_name, "__async_main") : module_function_c_name(module_name, "main")
        end
        if receiver_type
          base = "#{c_type_name(receiver_type)}_#{binding.name}"
          base = "#{base}_static" if binding.type.receiver_type.nil?
          return binding.type_arguments.empty? ? base : "#{base}__#{generic_type_argument_suffix(binding.type_arguments)}"
        end

        module_function_c_name(module_name, binding.name, type_arguments: binding.type_arguments)
      end

      def external_function_c_name(binding)
        return binding.ast.mapping.value if binding.external && binding.ast.is_a?(AST::ExternFunctionDecl) && binding.ast.mapping

        binding.name
      end

      def value_c_name(name)
        module_value_c_name(@ctx.module_name, name)
      end

      def imported_value_c_name(imported_module, name)
        imported_analysis = analysis_for_module(imported_module.name)
        return name if imported_analysis.module_kind == :raw_module

        module_value_c_name(imported_module.name, name)
      end

      def module_function_c_name(module_name, name, type_arguments: [])
        base = "#{module_c_prefix(module_name)}_#{name}"
        return base if type_arguments.empty?

        # A double-underscore separates a generic function instance's type
        # arguments so it cannot collide with a distinct regular function whose
        # name happens to be `<name>_<typearg>` (e.g. the instance
        # `expect_equal[str]` vs the function `expect_equal_str`). The method path
        # in `function_binding_c_name` uses the same scheme for consistency.
        "#{base}__#{generic_type_argument_suffix(type_arguments)}"
      end

      # Joins resolved generic type arguments into the instance-name suffix used
      # by both the free-function (`module_function_c_name`) and method
      # (`function_binding_c_name`) paths, keeping the scheme consistent.
      def generic_type_argument_suffix(type_arguments)
        sanitize_identifier(type_arguments.join('_'))
      end

      def module_value_c_name(module_name, name)
        "#{module_c_prefix(module_name)}_#{name}"
      end

      def module_c_prefix(module_name)
        sanitize_identifier(module_name.to_s.tr('.', '_'))
      end

      def c_local_name(name)
        return "value" unless name
        return "#{name}_" if c_reserved_identifier?(name)

        name
      end

      def c_reserved_identifier?(identifier)
        %w[
          auto break case char const continue default do double else enum extern
          float for goto if inline int long register restrict return short signed
          sizeof static struct switch typedef union unsigned void volatile while
          _Alignas _Alignof _Atomic _Bool _Complex _Generic _Imaginary _Noreturn
          _Static_assert _Thread_local
        ].include?(identifier)
      end

      def fresh_c_temp_name(env, prefix)
        env[:counter][:value] += 1
        "__mt_#{prefix}_#{env[:counter][:value]}"
      end

      def cleanup_safe_return_expression?(expression)
        case expression
        when AST::IntegerLiteral, AST::FloatLiteral, AST::StringLiteral, AST::BooleanLiteral, AST::NullLiteral
          true
        else
          false
        end
      end

      def sanitize_identifier(text)
        return "value" unless text

        cache = (@sanitize_identifier_cache ||= {})
        cached = cache[text]
        return cached if cached

        identifier = text.gsub(/[^A-Za-z0-9_]+/, "_").gsub(/_+/, "_").sub(/_+$/, "").sub(/^_+/, "")
        cache[text] = identifier.empty? ? "value" : identifier
      end

      def lower_assignment_target(expression, env:)
        case expression
        when AST::Identifier
          binding = lookup_value(expression.name, env)
          lower_assignment_binding_target(binding)
        when AST::MemberAccess
          if expression.receiver.is_a?(AST::IndexAccess)
            base_type = infer_expression_type(expression.receiver.receiver, env:)
            if base_type.is_a?(Types::SoA)
              soa_base = lower_expression(expression.receiver.receiver, env:)
              index = lower_expression(expression.receiver.index, env:)
              field_type = base_type.fields[expression.member]
              target_type = infer_expression_type(expression, env:)
              return IR::Index.new(
                receiver: IR::Member.new(receiver: soa_base, member: expression.member, type: field_type),
                index:,
                type: target_type,
              )
            end
          end
          receiver_type = infer_expression_type(expression.receiver, env:)
          receiver = lower_expression(expression.receiver, env:)
          type = infer_expression_type(expression, env:)
          IR::Member.new(receiver:, member: member_c_name(receiver_type, expression.member), type:)
        when AST::IndexAccess
          receiver_type = infer_expression_type(expression.receiver, env:)
          receiver = lower_expression(expression.receiver, env:)
          index = lower_expression(expression.index, env:)
          type = infer_expression_type(expression, env:)
          if array_type?(receiver_type)
            IR::CheckedIndex.new(receiver:, index:, receiver_type:, type:)
          elsif receiver_type.is_a?(Types::Span)
            IR::CheckedSpanIndex.new(receiver:, index:, receiver_type:, type:)
          else
            IR::Index.new(receiver:, index:, type:)
          end
        when AST::Call
          if read_call?(expression)
            type = infer_expression_type(expression, env:)
            operand = lower_expression(expression.arguments.first.value, env:)
            return IR::Unary.new(operator: "*", operand:, type:)
          end

          raise LoweringError.new("unsupported assignment target #{expression.class.name}", line: 0, column: 0, path: @ctx.current_analysis_path)
        else
          raise LoweringError.new("unsupported assignment target #{expression.class.name}", line: 0, column: 0, path: @ctx.current_analysis_path)
        end
      end

      def lower_assignment_binding_target(binding)
        storage_type = binding[:storage_type]
        visible_type = binding[:type]
        storage_ref = IR::Name.new(name: binding[:linkage_name], type: storage_type, pointer: binding[:pointer])

        case binding[:projection]
        when :result_success_value
          variant_binding_projection_expression(storage_ref, storage_type, "success", "value", visible_type)
        when :option_some_value
          variant_binding_projection_expression(storage_ref, storage_type, "some", "value", visible_type)
        else
          if visible_type == storage_type || (storage_type.is_a?(Types::Nullable) && storage_type.base == visible_type)
            IR::Name.new(name: binding[:linkage_name], type: visible_type, pointer: binding[:pointer])
          else
            storage_ref
          end
        end
      end

      def wrap_nullable_field_value(field_type, lowered_value, env)
        return lowered_value unless field_type.is_a?(Types::Nullable)
        return lowered_value if pointer_like_type?(field_type.base)
        return lowered_value if lowered_value.type.is_a?(Types::Nullable)

        nullable_some_literal(field_type, lowered_value)
      end

      def nullable_some_literal(nullable_type, value)
        IR::AggregateLiteral.new(
          type: nullable_type,
          fields: [
            IR::AggregateField.new(name: "has_value", value: IR::BooleanLiteral.new(value: true, type: @ctx.types.fetch("bool"))),
            IR::AggregateField.new(name: "value", value:),
          ],
        )
      end

      def pointer_like_type?(type)
        pointer_type?(type) || own_type?(type) || (type.is_a?(Types::Primitive) && type.name == "cstr") || type.is_a?(Types::Function) || type.is_a?(Types::Proc) || type.is_a?(Types::Opaque)
      end
    end
  end
end

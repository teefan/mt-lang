# frozen_string_literal: true

module MilkTea
  module LowererUtils
    private


      def range_iterable?(expression)
        range_expr?(expression)
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
        # pattern is TypeName.arm_name or module.TypeName.arm_name
        pattern.is_a?(AST::MemberAccess) ? pattern.member : nil
      end

      def async_variant_match_arm_binding(arm, scrutinee_expr, scrutinee_type, env:)
        arm_env = duplicate_env(env)
        binding_decl = nil

        if arm.binding_name && !wildcard_arm_pattern?(arm.pattern)
          arm_name = variant_match_arm_name_from_pattern(arm.pattern)
          if arm_name && scrutinee_type.has_payload?(arm_name)
            fields = scrutinee_type.arm(arm_name)
            payload_type = Types::VariantArmPayload.new(scrutinee_type, arm_name, fields)
            data_expr = IR::Member.new(receiver: scrutinee_expr, member: "data", type: nil)
            arm_expr = IR::Member.new(receiver: data_expr, member: arm_name, type: payload_type)
            binding_c = c_local_name(arm.binding_name)
            arm_env[:scopes].last[arm.binding_name] = local_binding(type: payload_type, c_name: binding_c, mutable: false, pointer: false)
            binding_decl = IR::LocalDecl.new(name: arm.binding_name, c_name: binding_c, type: payload_type, value: arm_expr)
          end
        end

        [arm_env, binding_decl]
      end

      def bind_async_variant_match_arm_env!(arm_env, scrutinee_type, arm)
        return unless scrutinee_type.is_a?(Types::Variant)
        return unless arm.binding_name && !wildcard_arm_pattern?(arm.pattern)

        arm_name = variant_match_arm_name_from_pattern(arm.pattern)
        return unless arm_name && scrutinee_type.has_payload?(arm_name)

        fields = scrutinee_type.arm(arm_name)
        payload_type = Types::VariantArmPayload.new(scrutinee_type, arm_name, fields)
        arm_env[:scopes].last[arm.binding_name] = local_binding(type: payload_type, c_name: c_local_name(arm.binding_name), mutable: false, pointer: false)
      end

      def array_type?(type)
        type.is_a?(Types::GenericInstance) && type.name == "array" && type.arguments.length == 2 &&
          type.arguments[1].is_a?(Types::LiteralTypeArg)
      end

      def array_element_type(type)
        return unless array_type?(type)

        type.arguments.first
      end

      def array_to_span_compatible?(actual_type, expected_type)
        array_type?(actual_type) && expected_type.is_a?(Types::Span) && array_element_type(actual_type) == expected_type.element_type
      end

      def cstr_trackable_type?(type)
        type == @types.fetch("str") || type == @types.fetch("cstr")
      end

      def cstr_list_trackable_type?(type)
        return false unless array_type?(type)

        element_type = array_element_type(type)
        element_type == @types.fetch("str") || element_type == @types.fetch("cstr")
      end

      def str_buffer_to_span_compatible?(actual_type, expected_type)
        str_buffer_type?(actual_type) && expected_type.is_a?(Types::Span) && expected_type.element_type == @types.fetch("char")
      end

      def array_length(type)
        return unless array_type?(type)

        type.arguments[1].value
      end

      def char_array_text_type?(type)
        array_type?(type) && array_element_type(type) == @types.fetch("char")
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

        raise LoweringError, "read expects ref[...] or ptr[...], got #{handle_type}"
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
        return array_element_type(type) if array_type?(type)
        return type.element_type if type.is_a?(Types::Span)

        nil
      end

      def collection_loop_binding_type(iterable_type, element_type)
        return nil unless array_type?(iterable_type) || iterable_type.is_a?(Types::Span)
        return nil unless collection_loop_ref_element_type?(element_type)

        Types::GenericInstance.new("ref", [element_type])
      end

      def collection_loop_ref_element_type?(type)
        type.is_a?(Types::Struct)
      end

      def iterator_loop_info(type, env:)
        iter_name = "__mt_for_iterable__"
        iterator_name = "__mt_for_iterator__"
        probe_env = duplicate_env(env)
        current_actual_scope(probe_env[:scopes])[iter_name] = local_binding(type:, c_name: iter_name, mutable: false, pointer: false)

        iter_call = AST::Call.new(
          callee: AST::MemberAccess.new(receiver: AST::Identifier.new(name: iter_name), member: "iter"),
          arguments: [],
        )
        iterator_type = infer_expression_type(iter_call, env: probe_env)

        current_actual_scope(probe_env[:scopes])[iterator_name] = local_binding(type: iterator_type, c_name: iterator_name, mutable: true, pointer: false)
        next_call = AST::Call.new(
          callee: AST::MemberAccess.new(receiver: AST::Identifier.new(name: iterator_name), member: "next"),
          arguments: [],
        )
        item_storage_type = infer_expression_type(next_call, env: probe_env)
        if item_storage_type.is_a?(Types::Nullable) && nullable_iterator_item_type?(item_storage_type.base)
          return {
            kind: :nullable_item,
            iterator_type:,
            item_storage_type:,
            item_type: item_storage_type.base,
          }
        end

        if item_storage_type == @types.fetch("bool")
          current_call = AST::Call.new(
            callee: AST::MemberAccess.new(receiver: AST::Identifier.new(name: iterator_name), member: "current"),
            arguments: [],
          )
          current_type = infer_expression_type(current_call, env: probe_env)
          return {
            kind: :current_item,
            iterator_type:,
            item_storage_type: current_type,
            item_type: current_type,
          }
        end

        nil
      rescue SemaError
        nil
      end

      def nullable_iterator_item_type?(type)
        type == @types.fetch("cstr") || pointer_type?(type)
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
          IR::IntegerLiteral.new(value: array_length(iterable_type), type: @types.fetch("ptr_uint"))
        else
          IR::Member.new(receiver: iterable_ref, member: "len", type: @types.fetch("ptr_uint"))
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
            expected_type: @types.fetch("void"),
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

        raise LoweringError, "range bounds must use matching integer types, got #{start_type} and #{stop_type}" unless start_type == stop_type

        start_type
      end

      def integer_type?(type)
        type.is_a?(Types::Primitive) && type.integer?
      end

      def infer_index_result_type(receiver_type, index_type)
        raise LoweringError, "index must be an integer type, got #{index_type}" unless integer_type?(index_type)

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

        if pointer_type?(receiver_type)
          return pointee_type(receiver_type)
        end

        raise LoweringError, "cannot index #{receiver_type}"
      end

      def contains_type_var?(type)
        case type
        when Types::TypeVar
          true
        when Types::Nullable
          contains_type_var?(type.base)
        when Types::GenericInstance
          type.arguments.any? { |argument| !argument.is_a?(Types::LiteralTypeArg) && contains_type_var?(argument) }
        when Types::Span
          contains_type_var?(type.element_type)
        when Types::Task
          contains_type_var?(type.result_type)
        when Types::Proc
          type.params.any? { |param| contains_type_var?(param.type) } || contains_type_var?(type.return_type)
        when Types::Function
          type.params.any? { |param| contains_type_var?(param.type) } || contains_type_var?(type.return_type)
        else
          false
        end
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
          return false if ref_type?(type)

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
        Types::GenericInstance.new("ptr", [type])
      end

      def with_analysis_context(analysis)
        saved_analysis = @analysis
        saved_module_name = @module_name
        saved_module_prefix = @module_prefix
        saved_imports = @imports
        saved_types = @types
        saved_values = @values
        saved_functions = @functions

        @analysis = analysis
        @module_name = analysis.module_name
        @module_prefix = module_c_prefix(@module_name)
        @imports = analysis.imports
        @types = analysis.types
        @values = analysis.values
        @functions = analysis.functions
        yield
      ensure
        @analysis = saved_analysis
        @module_name = saved_module_name
        @module_prefix = saved_module_prefix
        @imports = saved_imports
        @types = saved_types
        @values = saved_values
        @functions = saved_functions
      end

      def lookup_value(name, env)
        env[:scopes].reverse_each do |scope|
          return scope[name] if scope.key?(name)
        end

        if @values.key?(name)
          binding = @values.fetch(name)
          {
            type: binding.type,
            storage_type: binding.storage_type,
            c_name: value_c_name(name),
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

        lower_expression(rewrite_static_storage_initializer(expression), env:, expected_type: expected_type)
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
          if type == @types.fetch("str") || type == @types.fetch("cstr")
            return IR::StringLiteral.new(value:, type:, cstring: type == @types.fetch("cstr"))
          end
        end

        nil
      end

      def compile_time_builtin_function_type(name, arguments, env)
        return_type = case name
        when "field_of"
          @types.fetch("field_handle")
        when "callable_of"
          @types.fetch("callable_handle")
        when "has_attribute"
          @types.fetch("bool")
        when "attribute_of"
          @types.fetch("attribute_handle")
        else
          nil
        end
        raise LoweringError, "unsupported compile-time builtin #{name}" unless return_type

        Types::Function.new(name, params: [], return_type: return_type)
      end

      def compile_time_builtin_specialization_function_type(callee)
        Types::Function.new("attribute_arg", params: [], return_type: resolve_type_ref(callee.arguments.fetch(0).value))
      end


      def rewrite_static_storage_initializer(expression)
        case expression
        when AST::Identifier
          binding = @values[expression.name]
          if binding&.kind == :const
            declaration = const_declaration_for(analysis_for_module(@module_name), expression.name)
            return rewrite_static_storage_initializer(declaration.value)
          end

          expression
        when AST::MemberAccess
          if expression.receiver.is_a?(AST::Identifier) && @imports.key?(expression.receiver.name)
            imported_module = @imports.fetch(expression.receiver.name)
            if (binding = imported_module.values[expression.member])&.kind == :const
              imported_analysis = analysis_for_module(imported_module.name)
              declaration = const_declaration_for(imported_analysis, expression.member)
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

      def const_declaration_for(analysis, name)
        declaration = analysis.ast.declarations.find { |decl| decl.is_a?(AST::ConstDecl) && decl.name == name }
        raise LoweringError, "unknown constant #{analysis.module_name}.#{name}" unless declaration

        declaration
      end

      def local_binding(type:, c_name:, mutable:, pointer:, storage_type: nil, projection: nil, cstr_backed: false, cstr_list_backed: false, const_value: nil)
        { type:, storage_type: storage_type || type, c_name:, mutable:, pointer:, projection:, cstr_backed:, cstr_list_backed:, const_value: }
      end

      def callable_type?(type)
        type.is_a?(Types::Function) || proc_type?(type)
      end

      def contains_proc_storage_type?(type)
        case type
        when Types::Proc
          true
        when Types::Struct, Types::StructInstance
          type.fields.each_value.any? { |field_type| contains_proc_storage_type?(field_type) }
        when Types::Nullable
          contains_proc_storage_type?(type.base)
        else
          false
        end
      end

      def proc_env_pointer_type
        @proc_env_pointer_type ||= pointer_to(@types.fetch("void"))
      end

      def proc_invoke_function_type(proc_type)
        Types::Function.new(
          nil,
          params: [Types::Parameter.new("env", proc_env_pointer_type), *proc_type.params],
          return_type: proc_type.return_type,
        )
      end

      def proc_release_function_type
        @proc_release_function_type ||= Types::Function.new(
          nil,
          params: [Types::Parameter.new("env", proc_env_pointer_type)],
          return_type: @types.fetch("void"),
        )
      end

      def proc_retain_function_type
        @proc_retain_function_type ||= Types::Function.new(
          nil,
          params: [Types::Parameter.new("env", proc_env_pointer_type)],
          return_type: @types.fetch("void"),
        )
      end

      def fresh_proc_symbol
        @synthetic_proc_counter += 1
      end

      def current_actual_scope(scopes)
        scopes.reverse_each do |scope|
          return scope unless scope.is_a?(Sema::FlowScope)
        end

        raise LoweringError, "missing lexical scope"
      end

      def env_with_refinements(env, refinements)
        updated = env.dup
        updated[:scopes] = scopes_with_refinements(env[:scopes], refinements)
        updated
      end

      def scopes_with_refinements(scopes, refinements)
        return scopes if refinements.nil? || refinements.empty?

        base_scopes = scopes.last.is_a?(Sema::FlowScope) ? scopes[0...-1] : scopes
        merged_refinements = scopes.last.is_a?(Sema::FlowScope) ? scopes.last.each_with_object({}) { |(name, binding), result| result[name] = binding[:type] } : {}
        merged_refinements = merge_refinements(merged_refinements, refinements)
        flow_scope = Sema::FlowScope.new

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
        CFG::Termination.block_always_terminates?(statements, ignore_name: ->(_name) { false })
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
        !ref_type?(type) && type != @types.fetch("void")
      end

      def conditional_null_common_type(null_type, other_type)
        return unless null_type.is_a?(Types::Null)

        if other_type.is_a?(Types::Nullable)
          return other_type if null_type.target_type.nil? || null_type.target_type == other_type.base

          return nil
        end

        return unless nullable_candidate?(other_type)
        return if null_type.target_type && null_type.target_type != other_type

        Types::Nullable.new(other_type)
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
          raise LoweringError, "unsupported loop exit target #{target.inspect}"
        end
      end

      def lower_loop_exit(target, local_defers, outer_defers)
        cleanup = cleanup_statements(local_defers, outer_defers)
        if cleanup.empty?
          [loop_exit_statement(target, local_defers:, outer_defers:)]
        else
          label = target[:label]
          raise LoweringError, "structured loop exits with cleanup are unsupported" unless label

          cleanup + [IR::GotoStmt.new(label:)]
        end
      end

      def lower_async_loop_exit(target, local_defers, outer_defers, frame_expr:, raw_frame_expr:, async_info:)
        cleanup = lower_async_cleanup_entries(local_defers, outer_defers, frame_expr:, raw_frame_expr:, async_info:)
        if cleanup.empty?
          [loop_exit_statement(target, local_defers:, outer_defers:)]
        else
          label = target[:label]
          raise LoweringError, "structured loop exits with cleanup are unsupported" unless label

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

      def lower_defer_cleanup_expression(expression, env:)
        prepared_setup, prepared_expression, prepared_cleanups = prepare_expression_with_cleanups(
          expression,
          env:,
          expected_type: infer_expression_type(expression, env:),
          allow_root_statement_foreign: true,
        )

        lowered = []
        lowered.concat(prepared_setup)
        if (foreign_call = foreign_call_info(prepared_expression, env))
          setup, = lower_foreign_call_statement(
            foreign_call,
            env:,
            expected_type: foreign_call[:binding].type.return_type,
            statement_position: true,
            discard_result: true,
          )
          lowered.concat(setup)
        else
          lowered << IR::ExpressionStmt.new(expression: lower_expression(prepared_expression, env:))
        end
        lowered.concat(prepared_cleanups.flat_map(&:itself))
        lowered
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

      def let_else_discard_binding_syntax?(statement)
        statement.is_a?(AST::LocalDecl) && statement.else_body && statement.name == "_"
      end

      def bind_let_else_local?(statement)
        !let_else_discard_binding_syntax?(statement)
      end

      def async_local_decl_field_key(statement)
        return statement.name unless let_else_discard_binding_syntax?(statement)

        "__let_else_discard_#{statement.line}"
      end

      def async_local_decl_field_name(statement)
        return "local_#{statement.name}" unless let_else_discard_binding_syntax?(statement)

        "local_let_else_discard_#{statement.line}"
      end

      def let_else_storage_c_name(statement, env)
        return c_local_name(statement.name) unless let_else_discard_binding_syntax?(statement)

        fresh_c_temp_name(env, "let_else_discard")
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

      def let_else_failure_condition(storage_expr, storage_type)
        if storage_type.is_a?(Types::Nullable)
          return IR::Binary.new(
            operator: "==",
            left: storage_expr,
            right: IR::NullLiteral.new(type: storage_type),
            type: @types.fetch("bool"),
          )
        end

        if result_let_else_type?(storage_type)
          kind_type = @types.fetch("int")
          return IR::Binary.new(
            operator: "==",
            left: IR::Member.new(receiver: storage_expr, member: "kind", type: kind_type),
            right: IR::Name.new(name: "#{c_type_name(storage_type)}_kind_failure", type: kind_type, pointer: false),
            type: @types.fetch("bool"),
          )
        end

        if option_let_else_type?(storage_type)
          kind_type = @types.fetch("int")
          return IR::Binary.new(
            operator: "==",
            left: IR::Member.new(receiver: storage_expr, member: "kind", type: kind_type),
            right: IR::Name.new(name: "#{c_type_name(storage_type)}_kind_none", type: kind_type, pointer: false),
            type: @types.fetch("bool"),
          )
        end

        raise LoweringError, "unsupported let-else storage type #{storage_type}"
      end

      def lower_bound_identifier(binding)
        storage_type = binding[:storage_type]
        visible_type = binding[:type]
        projection = binding[:projection]

        if projection == :result_success_value
          local_ref = IR::Name.new(name: binding[:c_name], type: storage_type, pointer: binding[:pointer])
          return variant_binding_projection_expression(local_ref, storage_type, "success", "value", visible_type)
        end

        if projection == :result_failure_error
          local_ref = IR::Name.new(name: binding[:c_name], type: storage_type, pointer: binding[:pointer])
          return variant_binding_projection_expression(local_ref, storage_type, "failure", "error", visible_type)
        end

        if projection == :option_some_value
          local_ref = IR::Name.new(name: binding[:c_name], type: storage_type, pointer: binding[:pointer])
          return variant_binding_projection_expression(local_ref, storage_type, "some", "value", visible_type)
        end

        return IR::Name.new(name: binding[:c_name], type: visible_type, pointer: binding[:pointer]) if visible_type == storage_type
        return IR::Name.new(name: binding[:c_name], type: visible_type, pointer: binding[:pointer]) if storage_type.is_a?(Types::Nullable) && storage_type.base == visible_type

        if result_let_else_type?(storage_type) && let_else_success_type(storage_type) == visible_type
          local_ref = IR::Name.new(name: binding[:c_name], type: storage_type, pointer: binding[:pointer])
          return variant_binding_projection_expression(local_ref, storage_type, "success", "value", visible_type)
        end

        if option_let_else_type?(storage_type) && let_else_success_type(storage_type) == visible_type
          local_ref = IR::Name.new(name: binding[:c_name], type: storage_type, pointer: binding[:pointer])
          return variant_binding_projection_expression(local_ref, storage_type, "some", "value", visible_type)
        end

        IR::Name.new(name: binding[:c_name], type: visible_type, pointer: binding[:pointer])
      end

      def variant_binding_projection_expression(storage_expr, storage_type, arm_name, field_name, field_type)
        payload_type = Types::VariantArmPayload.new(storage_type, arm_name, storage_type.arm(arm_name))
        data_expr = IR::Member.new(receiver: storage_expr, member: "data", type: nil)
        arm_expr = IR::Member.new(receiver: data_expr, member: arm_name, type: payload_type)
        IR::Member.new(receiver: arm_expr, member: field_name, type: field_type)
      end

      def infer_result_propagation_type(expression, env:)
        _storage_type, success_type, = infer_result_propagation_types(expression, env:)

        success_type
      end

      def infer_result_propagation_types(expression, env:, allow_void_success: false)
        storage_type = infer_expression_type(expression.operand, env:)
        raise LoweringError, "propagation expects Result[T, E], got #{storage_type}" unless result_let_else_type?(storage_type)

        success_type = let_else_success_type(storage_type)
        error_type = let_else_error_type(storage_type)
        raise LoweringError, "propagation requires a non-void Result success type" if success_type == @types.fetch("void") && !allow_void_success

        context = env[:return_context]
        raise LoweringError, "propagation is only allowed inside function and proc bodies" unless context
        raise LoweringError, "propagation is not allowed inside defer blocks" unless context[:allow_return]

        return_type = context[:return_type]
        unless result_let_else_type?(return_type)
          raise LoweringError, "propagation requires enclosing function/proc to return Result[_, #{error_type}], got #{return_type}"
        end

        return_error_type = let_else_error_type(return_type)
        unless return_error_type == error_type
          raise LoweringError, "propagation error type #{error_type} must match enclosing Result error type #{return_error_type}"
        end

        [storage_type, success_type, return_type, error_type]
      end

      def prepare_result_propagation_for_inline_lowering(expression, env:, allow_void_success: false)
        storage_type, success_type, return_type, error_type = infer_result_propagation_types(expression, env:, allow_void_success:)

        env[:prepared_expression_cleanups] ||= []
        cleanup_start = env[:prepared_expression_cleanups].length
        operand_setup, operand = prepare_expression_for_inline_lowering(expression.operand, env:, expected_type: storage_type)
        operand_cleanups = env[:prepared_expression_cleanups].drop(cleanup_start)

        result_name = fresh_c_temp_name(env, "propagate")
        result_ref = IR::Name.new(name: result_name, type: storage_type, pointer: false)
        return_context = env.fetch(:return_context)
        failure_return = if storage_type == return_type
                           result_ref
                         else
                           IR::VariantLiteral.new(
                             type: return_type,
                             arm_name: "failure",
                             fields: [
                               IR::AggregateField.new(
                                 name: "error",
                                 value: variant_binding_projection_expression(result_ref, storage_type, "failure", "error", error_type),
                               ),
                             ],
                           )
                         end
        failure_cleanup = operand_cleanups.flat_map(&:itself)
        failure_terminator = if return_context[:async_info]
                               failure_cleanup +
                                 lower_async_cleanup_entries(
                                   return_context[:local_defers],
                                   return_context[:active_defers],
                                   frame_expr: return_context.fetch(:frame_expr),
                                   raw_frame_expr: return_context.fetch(:raw_frame_expr),
                                   async_info: return_context.fetch(:async_info),
                                 ) +
                                 async_complete_statements(
                                   frame_expr: return_context.fetch(:frame_expr),
                                   raw_frame_expr: return_context.fetch(:raw_frame_expr),
                                   async_info: return_context.fetch(:async_info),
                                   value: failure_return,
                                 )
                             else
                               failure_cleanup +
                                 cleanup_statements(return_context[:local_defers], return_context[:active_defers]) +
                                 [IR::ReturnStmt.new(value: failure_return, source_path: @current_analysis_path)]
                             end

        if success_type == @types.fetch("void")
          return [
            operand_setup + [
              IR::LocalDecl.new(
                name: result_name,
                c_name: result_name,
                type: storage_type,
                value: lower_contextual_expression(operand, env:, expected_type: storage_type),
              ),
              IR::IfStmt.new(
                condition: let_else_failure_condition(result_ref, storage_type),
                then_body: failure_terminator,
                else_body: nil,
              ),
            ],
            nil,
          ]
        end

        register_prepared_temp!(env, result_name, success_type, storage_type:, projection: :result_success_value)

        [
          operand_setup + [
            IR::LocalDecl.new(
              name: result_name,
              c_name: result_name,
              type: storage_type,
              value: lower_contextual_expression(operand, env:, expected_type: storage_type),
            ),
            IR::IfStmt.new(
              condition: let_else_failure_condition(result_ref, storage_type),
              then_body: failure_terminator,
              else_body: nil,
            ),
          ],
          AST::Identifier.new(name: result_name),
        ]
      end

      def c_type_name(type)
        if type.is_a?(Types::Nullable)
          return "nullable_#{c_type_name(type.base)}"
        end

        if type.respond_to?(:c_name) && type.c_name
          return type.c_name
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

        return type.name if type.module_name&.start_with?("std.c.")

        base = type.module_name ? "#{module_c_prefix(type.module_name)}_#{type.name}" : type.name
        return base unless type.is_a?(Types::StructInstance) || type.is_a?(Types::VariantInstance)

        "#{base}_#{sanitize_identifier(type.arguments.join('_'))}"
      end

      def opaque_c_type_name(type)
        type.c_name || c_type_name(type)
      end

      def opaque_forward_declarable?(type)
        return false unless opaque_c_type_name(type).match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)

        !type.external || type.c_name.nil?
      end

      def forward_declarable_external_opaque?(type)
        type.external && opaque_forward_declarable?(type)
      end

      def type_ref_from_specialization(expression)
        case expression.callee
        when AST::Identifier
          AST::TypeRef.new(name: AST::QualifiedName.new(parts: [expression.callee.name]), arguments: expression.arguments, nullable: false)
        when AST::MemberAccess
          return nil unless expression.callee.receiver.is_a?(AST::Identifier)

          AST::TypeRef.new(
            name: AST::QualifiedName.new(parts: [expression.callee.receiver.name, expression.callee.member]),
            arguments: expression.arguments,
            nullable: false,
          )
        end
      end

      def validate_generic_type!(name, arguments)
        case name
        when "ptr"
          raise LoweringError, "ptr requires exactly one type argument" unless arguments.length == 1
          raise LoweringError, "ptr type argument must be a type" if arguments.first.is_a?(Types::LiteralTypeArg)
        when "const_ptr"
          raise LoweringError, "const_ptr requires exactly one type argument" unless arguments.length == 1
          raise LoweringError, "const_ptr type argument must be a type" if arguments.first.is_a?(Types::LiteralTypeArg)
          raise LoweringError, "const_ptr cannot target ref types" if contains_ref_type?(arguments.first)
        when "ref"
          raise LoweringError, "ref requires exactly one type argument" unless arguments.length == 1
          raise LoweringError, "ref type argument must be a type" if arguments.first.is_a?(Types::LiteralTypeArg)
          raise LoweringError, "ref cannot target void" if arguments.first.is_a?(Types::Primitive) && arguments.first.void?
          raise LoweringError, "ref cannot target another ref type" if contains_ref_type?(arguments.first)
        when "span"
          raise LoweringError, "span requires exactly one type argument" unless arguments.length == 1
          raise LoweringError, "span element type must be a type" if arguments.first.is_a?(Types::LiteralTypeArg)
        when "array"
          raise LoweringError, "array requires exactly two type arguments" unless arguments.length == 2
          raise LoweringError, "array element type must be a type" if arguments.first.is_a?(Types::LiteralTypeArg)
          raise LoweringError, "array length must be an integer literal, named const, or type parameter" unless generic_integer_type_argument?(arguments[1])
          raise LoweringError, "array length must be positive" if integer_type_argument?(arguments[1]) && !arguments[1].value.positive?
        when "str_buffer"
          raise LoweringError, "str_buffer requires exactly one type argument" unless arguments.length == 1
          raise LoweringError, "str_buffer capacity must be an integer literal, named const, or type parameter" unless generic_integer_type_argument?(arguments.first)
          raise LoweringError, "str_buffer capacity must be positive" if integer_type_argument?(arguments.first) && !arguments.first.value.positive?
        when "Task"
          raise LoweringError, "Task requires exactly one type argument" unless arguments.length == 1
          raise LoweringError, "Task result type must be a type" if arguments.first.is_a?(Types::LiteralTypeArg)
        else
          raise LoweringError, "unknown generic type #{name}"
        end
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

      def local_named_type?(type)
        type.respond_to?(:module_name) && (type.module_name == @module_name || type.module_name.nil?)
      end

      def function_binding_c_name(binding, module_name:, receiver_type: nil)
        if receiver_type.nil? && binding.name == "main" && binding.type_arguments.empty?
          return binding.async ? module_function_c_name(module_name, "__async_main") : module_function_c_name(module_name, "main")
        end
        if receiver_type
          base = "#{c_type_name(receiver_type)}_#{binding.name}"
          base = "#{base}_static" if binding.type.receiver_type.nil?
          return binding.type_arguments.empty? ? base : "#{base}_#{sanitize_identifier(binding.type_arguments.join('_'))}"
        end

        module_function_c_name(module_name, binding.name, type_arguments: binding.type_arguments)
      end

      def value_c_name(name)
        module_value_c_name(@module_name, name)
      end

      def imported_value_c_name(imported_module, name)
        imported_analysis = analysis_for_module(imported_module.name)
        return name if imported_analysis.module_kind == :raw_module

        module_value_c_name(imported_module.name, name)
      end

      def module_function_c_name(module_name, name, type_arguments: [])
        base = "#{module_c_prefix(module_name)}_#{name}"
        return base if type_arguments.empty?

        "#{base}_#{sanitize_identifier(type_arguments.join('_'))}"
      end

      def module_value_c_name(module_name, name)
        "#{module_c_prefix(module_name)}_#{name}"
      end

      def module_c_prefix(module_name)
        sanitize_identifier(module_name.to_s.tr('.', '_'))
      end

      def c_local_name(name)
        identifier = sanitize_identifier(name)
        return "#{identifier}_" if c_reserved_identifier?(identifier)

        identifier
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
        identifier = text.gsub(/[^A-Za-z0-9_]+/, "_").gsub(/_+/, "_").sub(/_+$/, "").sub(/^_{2,}/, "_")
        identifier.empty? ? "value" : identifier
      end

      def lower_assignment_target(expression, env:)
        case expression
        when AST::Identifier
          binding = lookup_value(expression.name, env)
          lower_assignment_binding_target(binding)
        when AST::MemberAccess
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

          raise LoweringError, "unsupported assignment target #{expression.class.name}"
        else
          raise LoweringError, "unsupported assignment target #{expression.class.name}"
        end
      end

      def lower_assignment_binding_target(binding)
        storage_type = binding[:storage_type]
        visible_type = binding[:type]
        storage_ref = IR::Name.new(name: binding[:c_name], type: storage_type, pointer: binding[:pointer])

        case binding[:projection]
        when :result_success_value
          variant_binding_projection_expression(storage_ref, storage_type, "success", "value", visible_type)
        when :option_some_value
          variant_binding_projection_expression(storage_ref, storage_type, "some", "value", visible_type)
        else
          if visible_type == storage_type || (storage_type.is_a?(Types::Nullable) && storage_type.base == visible_type)
            IR::Name.new(name: binding[:c_name], type: visible_type, pointer: binding[:pointer])
          else
            storage_ref
          end
        end
      end
  end
end

# frozen_string_literal: true

module MilkTea
  module CompileTime
    # Compile-time folding for const-method calls and the resolution helpers
    # behind them. Included by both the semantic checker and the lowering
    # engine so the folding behavior lives in one place instead of two
    # near-identical copies. Each includer supplies a small set of `comptime_*`
    # adapters for the phase-specific lookups (ctx maps, scope/env evaluation,
    # and the BlockContext factory).
    module MethodFolding
      def comptime_methods_map_for_binding(type, keys)
        dispatch_type = type.respond_to?(:definition) ? type.definition : type
        method_map = comptime_methods_map.fetch(dispatch_type, nil)
        method_map ||= comptime_methods_map_by_to_s(dispatch_type)
        return nil unless method_map

        keys.each do |key|
          binding = method_map[key]
          next unless binding

          ast = binding.ast
          next unless ast.respond_to?(:const) && ast.const && ast.body
          next unless binding.type_params.empty?

          return binding
        end
        nil
      end

      def comptime_method_binding(member_access, ctx)
        member = member_access.member
        keys = ["static:#{member}", member]

        if (type = resolve_type_expression(member_access.receiver)) &&
           (binding = comptime_methods_map_for_binding(type, keys))
          return binding
        end

        receiver_type = comptime_receiver_type(member_access.receiver, ctx)
        return nil unless receiver_type

        comptime_methods_map_for_binding(receiver_type, keys)
      end

      def comptime_method_binding_for_receiver(receiver_type, member)
        comptime_methods_map_for_binding(receiver_type, ["static:#{member}", member])
      end

      def comptime_receiver_type(receiver, ctx)
        case receiver
        when AST::Identifier
          type = comptime_scoped_value_type(receiver.name, ctx)
          return type if type

          comptime_value_type(receiver.name)
        when AST::MemberAccess
          return nil unless receiver.receiver.is_a?(AST::Identifier)

          comptime_imported_value_type(receiver.receiver.name, receiver.member)
        when AST::Call, AST::Specialization
          comptime_call_return_type(receiver, ctx)
        end
      end

      def comptime_member_receiver_value(receiver, ctx)
        return nil if resolve_type_expression(receiver)

        comptime_eval(receiver, ctx)
      end

      def comptime_call_return_type(call_expr, ctx)
        case call_expr.callee
        when AST::MemberAccess
          binding = comptime_method_binding(call_expr.callee, ctx)
          return binding.body_return_type if binding
        when AST::Identifier
          func = comptime_const_function(call_expr.callee.name)
          return func.body_return_type if comptime_const_function_return?(func)
        when AST::Specialization
          callee_name = call_expr.callee.callee.is_a?(AST::Identifier) ? call_expr.callee.callee.name : nil
          if callee_name
            func = comptime_const_function(callee_name)
            return func.body_return_type if comptime_const_function_return?(func)
          end
        end
        nil
      end

      def comptime_expression_type(expression, scopes:)
        case expression
        when AST::Call, AST::Specialization
          comptime_call_return_type(expression, scopes)
        end
      end

      def comptime_struct_field_names(type_name)
        parts = type_name.is_a?(Array) ? type_name.map(&:to_s) : [type_name.to_s]
        return nil if parts.empty?

        type = resolve_type_expression(::MilkTea::AST.build_chain_from_parts(parts))
        return nil unless type
        return nil unless type.respond_to?(:fields) && type.fields

        type.fields.keys
      end

      def comptime_folded_value?(value)
        return false if value.nil?
        return false if value.is_a?(Types::Base)

        true
      end

      def comptime_const_function_return?(func)
        func && func.respond_to?(:ast) && func.ast.respond_to?(:const) && func.ast.const
      end

      def comptime_const_method_body(binding, arguments, scopes:, receiver_value:)
        method = binding.ast
        return nil unless method.respond_to?(:body) && method.body
        return nil if binding.type_params.any?
        return nil unless method.params.length == arguments.length

        initial_vars = {}
        if binding.type.receiver_type
          return nil unless comptime_folded_value?(receiver_value)

          initial_vars["this"] = receiver_value
        end

        method.params.each_with_index do |param, idx|
          arg_value = comptime_eval(arguments[idx].value, scopes)
          return nil unless arg_value

          initial_vars[param.name] = arg_value
        end

        variable_types = binding.body_params.each_with_object({}) do |param, acc|
          acc[param.name] = param.type
        end
        block_context = comptime_block_context(initial_vars, variable_types)
        result = block_context.evaluate_block(method.body, scopes: nil)
        result.is_a?(CompileTime::ReturnOutcome) ? result.value : result
      rescue CompileTime::Error => e
        comptime_raise_error(e)
      end

      def comptime_imported_value_type(import_name, member)
        imported_module = @ctx.imports.fetch(import_name, nil)
        return nil unless imported_module

        imported_module.values[member]&.type
      end
    end
  end
end

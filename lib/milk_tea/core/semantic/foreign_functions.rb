# frozen_string_literal: true

module MilkTea
  class SemanticAnalyzer::Checker
    private

    def validate_consuming_foreign_parameter!(type, function_name:, parameter_name:)
      if type.is_a?(Types::Nullable) || !(opaque_type?(type) || pointer_type?(type))
        raise_sema_error("consuming parameter #{parameter_name} of #{function_name} must use a non-null opaque or ptr[...] type")
      end
    end

    def foreign_cstr_boundary_parameter?(parameter)
      parameter.boundary_type == @ctx.types.fetch("cstr") && parameter.type == @ctx.types.fetch("str")
    end

    def foreign_cstr_argument_compatible?(actual_type, parameter, expression:)
      types_compatible?(actual_type, parameter.type, expression:) || actual_type == @ctx.types.fetch("cstr")
    end

    def foreign_parameter_boundary_type(param, public_type, type_params:, type_param_constraints: current_type_param_constraints)
      return resolve_type_ref(param.boundary_type, type_params:, type_param_constraints:) if param.boundary_type
      return const_pointer_to(public_type) if param.mode == :in
      return pointer_to(foreign_slot_boundary_value_type(public_type)) if [:out, :inout].include?(param.mode)

      nil
    end

    def foreign_slot_boundary_value_type(public_type)
      if public_type.is_a?(Types::Nullable) && pointer_type?(public_type.base)
        return public_type.base
      end

      public_type
    end

    def validate_in_foreign_parameter!(public_type, boundary_type, function_name:, parameter_name:)
      unless const_pointer_type?(boundary_type)
        raise_sema_error("in parameter #{parameter_name} of #{function_name} must lower to const_ptr[...], got #{boundary_type || public_type}")
      end

      expected_public_type = pointee_type(boundary_type)
      return if expected_public_type == public_type
      return if expected_public_type == @ctx.types.fetch("void")
      return if foreign_identity_projection_compatible?(public_type, expected_public_type)

      raise_sema_error("in parameter #{parameter_name} of #{function_name} cannot map #{public_type} as #{boundary_type}")
    end

    def foreign_mapping_public_alias_name(name)
      "#{name}_public"
    end

    def validate_foreign_boundary_type!(public_type, boundary_type, function_name:, parameter_name:)
      return if boundary_type == public_type
      return if boundary_type == @ctx.types.fetch("cstr") && public_type == @ctx.types.fetch("str")
      return if foreign_span_boundary_compatible?(public_type, boundary_type)
      return if foreign_char_pointer_buffer_boundary_compatible?(public_type, boundary_type)
      return if foreign_identity_projection_compatible?(public_type, boundary_type)

      raise_sema_error("foreign parameter #{parameter_name} of #{function_name} cannot map #{public_type} as #{boundary_type}")
    end

    def foreign_function_binding?(binding)
      binding.ast.is_a?(AST::ForeignFunctionDecl)
    end

    def foreign_mapping_expression(decl)
      return decl.mapping unless foreign_mapping_auto_call_shorthand?(decl.mapping)

      AST::Call.new(
        callee: decl.mapping,
        arguments: decl.params.map { |param| AST::Argument.new(name: nil, value: AST::Identifier.new(name: param.name)) },
      )
    end

    def foreign_mapping_auto_call_shorthand?(expression)
      case expression
      when AST::Identifier
        true
      when AST::MemberAccess
        foreign_mapping_auto_call_shorthand?(expression.receiver)
      when AST::Specialization
        foreign_mapping_auto_call_shorthand?(expression.callee)
      else
        false
      end
    end

    def foreign_argument_expression(argument)
      if argument.value.is_a?(AST::UnaryOp) && ["out", "in", "inout"].include?(argument.value.operator)
        argument.value.operand
      else
        argument.value
      end
    end

    def foreign_argument_legacy_passing_mode(argument)
      return nil unless argument.value.is_a?(AST::UnaryOp) && ["out", "in", "inout"].include?(argument.value.operator)

      argument.value.operator
    end

    def foreign_argument_actual_type(parameter, argument, scopes:, function_name:, expected_type: parameter.type)
      case parameter.passing_mode
      when :plain
        infer_expression(argument.value, scopes:, expected_type:)
      when :consuming
        foreign_consuming_argument_binding(parameter, argument, scopes:, function_name:)
        parameter.type
      when :in, :out, :inout
        if (legacy_passing_mode = foreign_argument_legacy_passing_mode(argument))
          raise_sema_error("argument #{parameter.name} to #{function_name} must not use #{legacy_passing_mode}; directional passing is declared on #{function_name}")
        end

        if parameter.passing_mode == :in
          infer_expression(argument.value, scopes:, expected_type: expected_type)
        else
          infer_lvalue(argument.value, scopes:)
        end
      else
        raise_sema_error("unsupported foreign passing mode #{parameter.passing_mode}")
      end
    end

    def foreign_consuming_argument_binding(parameter, argument, scopes:, function_name:)
      unless argument.value.is_a?(AST::Identifier)
        raise_sema_error("consuming argument #{parameter.name} to #{function_name} must be a bare nullable local or parameter binding")
      end

      binding = lookup_value(argument.value.name, scopes)
      unless binding && %i[let var param].include?(binding.kind) && binding.storage_type.is_a?(Types::Nullable) && binding.storage_type.base == parameter.type
        raise_sema_error("consuming argument #{parameter.name} to #{function_name} must be a bare nullable local or parameter binding")
      end

      binding
    end
  end
end

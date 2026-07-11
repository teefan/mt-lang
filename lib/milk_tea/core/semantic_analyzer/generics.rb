# frozen_string_literal: true

module MilkTea
  class SemanticAnalyzer::Checker
    private

    def infer_receiver_type_substitutions(binding, receiver_type)
      declared_receiver_type = binding.declared_receiver_type
      return {} unless declared_receiver_type
      case declared_receiver_type
      when Types::Nullable
        unless receiver_type.is_a?(Types::Nullable)
          raise_sema_error("cannot use method #{binding.name} with receiver #{receiver_type}")
        end

        infer_receiver_type_substitutions(
          binding.with(declared_receiver_type: declared_receiver_type.base),
          receiver_type.base,
        )
      when Types::StructInstance
        return {} unless declared_receiver_type.definition.is_a?(Types::GenericStructDefinition)

        unless receiver_type.is_a?(Types::StructInstance) && receiver_type.definition == declared_receiver_type.definition
          raise_sema_error("cannot use method #{binding.name} with receiver #{receiver_type}")
        end

        declared_receiver_type.definition.type_params.zip(receiver_type.arguments).to_h
      when Types::VariantInstance
        return {} unless declared_receiver_type.definition.is_a?(Types::GenericVariantDefinition)

        unless receiver_type.is_a?(Types::VariantInstance) && receiver_type.definition == declared_receiver_type.definition
          raise_sema_error("cannot use method #{binding.name} with receiver #{receiver_type}")
        end

        declared_receiver_type.definition.type_params.zip(receiver_type.arguments).to_h
      when Types::GenericInstance
        unless receiver_type.is_a?(Types::GenericInstance) && receiver_type.name == declared_receiver_type.name && receiver_type.arguments.length == declared_receiver_type.arguments.length
          raise_sema_error("cannot use method #{binding.name} with receiver #{receiver_type}")
        end

        declared_receiver_type.arguments.zip(receiver_type.arguments).each_with_object({}) do |(declared_argument, actual_argument), substitutions|
          if declared_argument.is_a?(Types::TypeVar)
            substitutions[declared_argument.name] = actual_argument
          elsif declared_argument != actual_argument
            raise_sema_error("cannot use method #{binding.name} with receiver #{receiver_type}")
          end
        end
      else
        {}
      end
    end

    def callable_receiver_type_for_specialization(callee, scopes:)
      return unless callee.is_a?(AST::MemberAccess)

      resolve_type_expression(callee.receiver)
    end

    def resolve_type_member(type, name)
      case type
      when Types::Enum, Types::Flags
        type.member(name)
      when Types::Variant
        return type if type.arm_names.include?(name) && !type.has_payload?(name)

        nil
      end
    end

    def function_type_for_name(name)
      @ctx.top_level_functions.fetch(name).type
    end

    def resolve_specialized_callable_binding(expression, scopes:)
      callable_kind = :function
      receiver = nil
      receiver_type = nil
      binding = case expression.callee
                when AST::Identifier
                  @ctx.top_level_functions[expression.callee.name]
                when AST::MemberAccess
                  if expression.callee.receiver.is_a?(AST::Identifier) && @ctx.imports.key?(expression.callee.receiver.name)
                    imported_module = @ctx.imports.fetch(expression.callee.receiver.name)
                    imported_function = imported_module.functions[expression.callee.member]
                    if imported_function.nil? && imported_module.private_function?(expression.callee.member)
                      raise_sema_error("#{expression.callee.receiver.name}.#{expression.callee.member} is private to module #{imported_module.name}")
                    end

                    imported_function
                  elsif (type_expr = resolve_type_expression(expression.callee.receiver))
                    associated_function = lookup_method(type_expr, expression.callee.member)
                    if associated_function&.type&.receiver_type.nil?
                      receiver_type = type_expr
                      associated_function
                    else
                      if (imported_module = imported_module_with_private_method(type_expr, expression.callee.member))
                        raise_sema_error("#{type_expr}.#{expression.callee.member} is private to module #{imported_module.name}")
                      end

                      nil
                    end
                  else
                    receiver_type = infer_method_receiver_type(expression.callee.receiver, scopes:, member_name: expression.callee.member)
                    method = lookup_method(receiver_type, expression.callee.member)
                    if method
                      callable_kind = :method
                      receiver = expression.callee.receiver
                      method
                    else
                      if (imported_module = imported_module_with_private_method(receiver_type, expression.callee.member))
                        raise_sema_error("#{receiver_type}.#{expression.callee.member} is private to module #{imported_module.name}")
                      end

                      nil
                    end
                  end
                end
      return nil unless binding

      type_arguments = resolve_specialization_type_arguments(expression)
      [callable_kind, instantiate_function_binding_with_receiver(binding, type_arguments, receiver_type:), receiver]
    end

    def resolve_specialization_type_arguments(expression)
      expression.arguments.map do |argument|
        resolve_type_argument(argument.value, type_params: current_type_params)
      end
    end

    def specialize_function_binding(binding, arguments, scopes:, receiver_type: nil)
      return binding if binding.type_params.empty?

      type_arguments = infer_function_type_arguments(binding, arguments, scopes:, receiver_type:)
      instantiate_function_binding(binding, type_arguments)
    end

    def instantiate_function_binding_with_receiver(binding, explicit_type_arguments, receiver_type: nil)
      if binding.type_params.empty?
        raise_sema_error("function #{binding.name} is not generic and cannot be specialized")
      end

      receiver_substitutions = infer_receiver_type_substitutions(binding, receiver_type)
      remaining_type_params = binding.type_params.reject { |name| receiver_substitutions.key?(name) }
      unless remaining_type_params.length == explicit_type_arguments.length
        raise_sema_error("function #{binding.name} expects #{remaining_type_params.length} type arguments, got #{explicit_type_arguments.length}")
      end

      substitutions = receiver_substitutions.dup
      remaining_type_params.zip(explicit_type_arguments).each do |name, type_argument|
        raise_sema_error("generic function #{binding.name} cannot be instantiated with ref types") if contains_ref_type?(type_argument)

        substitutions[name] = type_argument
      end

      type_arguments = binding.type_params.map do |name|
        inferred = substitutions[name]
        raise_sema_error("cannot infer type argument #{name} for function #{binding.name}") unless inferred

        inferred
      end

      instantiate_function_binding(binding, type_arguments)
    end

    def instantiate_function_binding(binding, type_arguments)
      if binding.type_params.empty?
        raise_sema_error("function #{binding.name} is not generic and cannot be specialized")
      end

      unless binding.type_params.length == type_arguments.length
        raise_sema_error("function #{binding.name} expects #{binding.type_params.length} type arguments, got #{type_arguments.length}")
      end

      if type_arguments.any? { |type_argument| contains_ref_type?(type_argument) }
        raise_sema_error("generic function #{binding.name} cannot be instantiated with ref types")
      end

      key = type_arguments.freeze
      return binding.instances.fetch(key) if binding.instances.key?(key)

      substitutions = binding.type_params.zip(type_arguments).to_h
      validate_function_type_param_constraints!(binding, substitutions)
      type = substitute_type(binding.type, substitutions)
      body_params = binding.body_params.map { |param| substitute_value_binding(param, substitutions) }
      validate_specialized_function_binding!(binding.name, type, body_params)

      instance = FunctionBinding.new(
        name: binding.name,
        type:,
        body_params:,
        body_return_type: substitute_type(binding.body_return_type, substitutions),
        ast: binding.ast,
        external: binding.external,
        async: binding.async,
        type_params: [].freeze,
        type_param_constraints: {}.freeze,
        instances: {},
        type_arguments: key,
        owner: binding.owner,
        specialization_owner: @current_specialization_owner || (binding.owner == self ? nil : self),
        type_substitutions: substitutions.freeze,
        declared_receiver_type: binding.declared_receiver_type ? substitute_type(binding.declared_receiver_type, substitutions) : nil,
      )
      binding.instances[key] = instance
    end

    def validate_function_type_param_constraints!(binding, substitutions)
      binding.type_param_constraints.each do |name, constraints|
        actual_type = substitutions[name]
        raise_sema_error("cannot infer type argument #{name} for function #{binding.name}") unless actual_type

        validate_type_param_constraint_binding!(constraints, actual_type, context: "function #{binding.name}")
      end
    end

    def infer_function_type_arguments(binding, arguments, scopes:, receiver_type: nil)
      expected_params = binding.type.params
      unless call_arity_matches?(binding.type, arguments.length)
        raise_sema_error(arity_error_message(binding.type, binding.name, arguments.length))
      end

      substitutions = infer_receiver_type_substitutions(binding, receiver_type)
      expected_params.each_with_index do |parameter, index|
        argument = arguments.fetch(index)
        candidate_type = substitute_type(parameter.type, substitutions)
        expected_argument_type = if callable_type?(candidate_type)
                                    candidate_type
                                  elsif contains_type_var?(candidate_type)
                                    nil
                                  else
                                    candidate_type
                                  end
        actual_type = foreign_argument_actual_type(parameter, argument, scopes:, function_name: binding.name, expected_type: expected_argument_type)
        collect_type_substitutions(parameter.type, actual_type, substitutions, binding.name)
      end

      binding.type_params.map do |name|
        inferred = substitutions[name]
        raise_sema_error("cannot infer type argument #{name} for function #{binding.name}") unless inferred

        raise_sema_error("generic function #{binding.name} cannot be instantiated with ref types") if contains_ref_type?(inferred)

        inferred
      end
    end

    def collect_type_substitutions(pattern_type, actual_type, substitutions, function_name)
      case pattern_type
      when Types::TypeVar
        existing = substitutions[pattern_type.name]
        if existing && existing != actual_type
          raise_sema_error("conflicting type argument #{pattern_type.name} for function #{function_name}: got #{existing} and #{actual_type}")
        end

        substitutions[pattern_type.name] ||= actual_type
      when Types::Nullable
        candidate = actual_type.is_a?(Types::Nullable) ? actual_type.base : actual_type
        collect_type_substitutions(pattern_type.base, candidate, substitutions, function_name)
      when Types::GenericInstance
        if ref_type?(pattern_type) && !ref_type?(actual_type)
          collect_type_substitutions(referenced_type(pattern_type), actual_type, substitutions, function_name)
          return
        end

        if own_type?(actual_type) && (mutable_pointer_type?(pattern_type) || const_pointer_type?(pattern_type))
          collect_type_substitutions(pointee_type(pattern_type), owned_referent_type(actual_type), substitutions, function_name)
          return
        end

        return unless actual_type.is_a?(Types::GenericInstance)
        return unless actual_type.name == pattern_type.name && actual_type.arguments.length == pattern_type.arguments.length

        pattern_type.arguments.zip(actual_type.arguments).each do |expected_argument, actual_argument|
          next if expected_argument.is_a?(Types::LiteralTypeArg)

          collect_type_substitutions(expected_argument, actual_argument, substitutions, function_name)
        end
      when Types::VariantInstance
        return unless actual_type.is_a?(Types::VariantInstance)
        return unless actual_type.definition == pattern_type.definition || (actual_type.name == pattern_type.name && actual_type.arguments.length == pattern_type.arguments.length)

        pattern_type.arguments.zip(actual_type.arguments).each do |expected_argument, actual_argument|
          next if expected_argument.is_a?(Types::LiteralTypeArg)

          collect_type_substitutions(expected_argument, actual_argument, substitutions, function_name)
        end
      when Types::Span
        return unless actual_type.is_a?(Types::Span)

        collect_type_substitutions(pattern_type.element_type, actual_type.element_type, substitutions, function_name)
      when Types::Task
        return unless actual_type.is_a?(Types::Task)

        collect_type_substitutions(pattern_type.result_type, actual_type.result_type, substitutions, function_name)
      when Types::Proc
        if task_root_proc_type?(pattern_type) && actual_type.is_a?(Types::Task)
          collect_type_substitutions(pattern_type.return_type, actual_type, substitutions, function_name)
          return
        end

        actual_params = case actual_type
                        when Types::Proc
                          return unless actual_type.params.length == pattern_type.params.length

                          actual_type.params
                        when Types::Function
                          return if actual_type.receiver_type || actual_type.variadic
                          return unless actual_type.params.length == pattern_type.params.length

                          actual_type.params
                        else
                          return
                        end

        pattern_type.params.zip(actual_params).each do |expected_param, actual_param|
          collect_type_substitutions(expected_param.type, actual_param.type, substitutions, function_name)
        end
        collect_type_substitutions(pattern_type.return_type, actual_type.return_type, substitutions, function_name)
      when Types::StructInstance
        return unless actual_type.is_a?(Types::StructInstance)
        return unless actual_type.definition == pattern_type.definition && actual_type.arguments.length == pattern_type.arguments.length

        pattern_type.arguments.zip(actual_type.arguments).each do |expected_argument, actual_argument|
          collect_type_substitutions(expected_argument, actual_argument, substitutions, function_name)
        end
      when Types::Function
        return unless actual_type.is_a?(Types::Function)
        return unless actual_type.params.length == pattern_type.params.length

        pattern_type.params.zip(actual_type.params).each do |expected_param, actual_param|
          collect_type_substitutions(expected_param.type, actual_param.type, substitutions, function_name)
        end
        collect_type_substitutions(pattern_type.return_type, actual_type.return_type, substitutions, function_name)
      end
    end

    def substitute_value_binding(binding, substitutions)
      ValueBinding.new(
        id: binding.id,
        name: binding.name,
        storage_type: substitute_type(binding.storage_type, substitutions),
        flow_type: binding.flow_type ? substitute_type(binding.flow_type, substitutions) : nil,
        mutable: binding.mutable,
        kind: binding.kind,
        const_value: binding.const_value,
      )
    end

    def validate_specialized_function_binding!(function_name, function_type, body_params)
      function_type.params.each do |param|
        validate_specialized_function_type!(param.type, function_name:, context: "parameter #{param.name}")
        validate_specialized_function_type!(param.boundary_type, function_name:, context: "boundary parameter #{param.name}") if param.boundary_type
      end
      validate_specialized_function_type!(function_type.return_type, function_name:, context: "return type")
      validate_specialized_function_type!(function_type.receiver_type, function_name:, context: "receiver type") if function_type.receiver_type

      body_params.each do |param|
        validate_specialized_function_type!(param.type, function_name:, context: "body parameter #{param.name}")
      end
    end

    def validate_specialized_function_type!(type, function_name:, context:)
      ValidateSpecializedTypeVisitor.new(
        function_name:,
        context:,
        on_error: ->(msg) { raise_sema_error(msg) },
        on_generic_instance: ->(name, args) { validate_generic_type!(name, args) },
      ).visit(type)
    end

    def substitute_type(type, substitutions)
      SubstituteTypeVisitor.new(substitutions).apply(type)
    end

    def bitwise_type?(type)
      type.respond_to?(:bitwise?) && type.bitwise?
    end

    def callable_type?(type)
      type.is_a?(Types::Function) || type.is_a?(Types::Proc)
    end
  end
end

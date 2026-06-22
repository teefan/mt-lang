# frozen_string_literal: true

module MilkTea
  class Sema
    class Checker
      private

      def validate_attribute_applications
        expanded_declarations.each do |decl|
          with_error_node(decl) do
            case decl
            when AST::StructDecl
              packed, alignment = validate_decl_attribute_applications!(decl.attributes, target_kind: :struct, target_label: "struct #{decl.name}", target_node: decl)
              @ctx.types.fetch(decl.name).set_layout(packed:, alignment:)

              decl.fields.each do |field|
                with_error_node(field) do
                  if raw_module? && field.attributes.any?
                    raise_sema_error("attributes are not allowed on fields in external files")
                  end

                  validate_decl_attribute_applications!(field.attributes, target_kind: :field, target_label: "field #{decl.name}.#{field.name}", target_node: field)
                end
              end
            when AST::FunctionDef, AST::ExternFunctionDecl, AST::ForeignFunctionDecl
              validate_decl_attribute_applications!(decl.attributes, target_kind: :callable, target_label: "callable #{decl.name}", target_node: decl)
            when AST::InterfaceDecl
              decl.methods.each do |method|
                with_error_node(method) do
                  validate_decl_attribute_applications!(method.attributes, target_kind: :callable, target_label: "callable #{decl.name}.#{method.name}", target_node: method)
                end
              end
            when AST::ExtendingBlock
              decl.methods.each do |method|
                with_error_node(method) do
                  validate_decl_attribute_applications!(method.attributes, target_kind: :callable, target_label: "callable #{decl.type_name}.#{method.name}", target_node: method)
                end
              end
            when AST::ConstDecl
              validate_decl_attribute_applications!(decl.attributes, target_kind: :const, target_label: "const #{decl.name}", target_node: decl)
            when AST::EventDecl
              validate_decl_attribute_applications!(decl.attributes, target_kind: :event, target_label: "event #{decl.name}", target_node: decl)
            when AST::UnionDecl
              validate_decl_attribute_applications!(decl.attributes, target_kind: :union, target_label: "union #{decl.name}", target_node: decl)
            when AST::EnumDecl
              validate_decl_attribute_applications!(decl.attributes, target_kind: :enum, target_label: "enum #{decl.name}", target_node: decl)
            when AST::FlagsDecl
              validate_decl_attribute_applications!(decl.attributes, target_kind: :flags, target_label: "flags #{decl.name}", target_node: decl)
            when AST::VariantDecl
              validate_decl_attribute_applications!(decl.attributes, target_kind: :variant, target_label: "variant #{decl.name}", target_node: decl)
            end
          end
        end
      end

      def validate_decl_attribute_applications!(applications, target_kind:, target_label:, target_node:)
        seen = {}
        packed = false
        alignment = nil
        resolved_applications = []

        applications.each do |application|
          with_error_node(application) do
            binding = resolve_attribute_binding(application.name)

            if raw_module?
              raise_sema_error("only built-in struct attributes are allowed in external files") unless binding.builtin && target_kind == :struct
            end

            unless binding.targets.include?(target_kind)
              raise_sema_error("attribute #{binding.name} cannot target #{target_kind}")
            end

            binding_key = [binding.module_name, binding.name]
            raise_sema_error("duplicate attribute #{binding.name} on #{target_label}") if seen.key?(binding_key)

            seen[binding_key] = true
            argument_values = validate_attribute_arguments!(binding, application)
            argument_values = argument_values.freeze
            @ctx.attribute_application_bindings[application.object_id] = binding
            @ctx.validated_attribute_arguments[application.object_id] = argument_values
            resolved_applications << ResolvedAttributeApplication.new(binding:, argument_values:)

            case binding.name
            when "packed"
              packed = true
            when "align"
              bytes = argument_values.fetch("bytes")
              raise_sema_error("align(...) requires a positive alignment") unless bytes.is_a?(Integer) && bytes.positive?
              raise_sema_error("align(...) requires a power-of-two alignment, got #{bytes}") unless power_of_two?(bytes)

              alignment = bytes
            end
          end
        end

        @ctx.resolved_attribute_applications[target_node.object_id] = resolved_applications.freeze

        [packed, alignment]
      end

      def validate_attribute_arguments!(binding, application)
        params = binding.params
        arguments = application.arguments

        if params.empty?
          raise_sema_error("attribute #{binding.name} does not take arguments") if arguments.any?

          return {}
        end

        bound_arguments = {}
        next_position = 0

        arguments.each do |argument|
          param = if argument.name
                    params.find { |candidate| candidate.name == argument.name }.tap do |candidate|
                      raise_sema_error("unknown attribute argument #{binding.name}.#{argument.name}") unless candidate
                    end
                  else
                    while next_position < params.length && bound_arguments.key?(params[next_position].name)
                      next_position += 1
                    end

                    raise_sema_error("attribute #{binding.name} expects #{params.length} arguments, got #{arguments.length}") if next_position >= params.length

                    param = params[next_position]
                    next_position += 1
                    param
                  end

          raise_sema_error("duplicate attribute argument #{binding.name}.#{param.name}") if bound_arguments.key?(param.name)

          bound_arguments[param.name] = argument.value
        end

        missing = params.reject { |param| bound_arguments.key?(param.name) }
        unless missing.empty?
          names = missing.map(&:name).join(", ")
          raise_sema_error("attribute #{binding.name} is missing required arguments: #{names}")
        end

        params.each_with_object({}) do |param, values|
          argument_expression = bound_arguments.fetch(param.name)
          actual_type = infer_expression(argument_expression, scopes: [], expected_type: param.type)
          ensure_assignable!(
            actual_type,
            param.type,
            "attribute #{binding.name} argument #{param.name} expects #{param.type}, got #{actual_type}",
            expression: argument_expression,
          )

          const_value = evaluate_compile_time_const_value(argument_expression)
          raise_sema_error("attribute #{binding.name} argument #{param.name} must be a compile-time constant") if const_value.nil?

          values[param.name] = const_value
        end
      end

      def resolve_attribute_binding(name)
        parts = name.parts

        if parts.length == 1
          binding = @ctx.attributes[parts.first]
          raise_sema_error("unknown attribute #{name}") unless binding

          return binding
        end

        if parts.length == 2 && @ctx.imports.key?(parts.first)
          imported_module = @ctx.imports.fetch(parts.first)
          raise_sema_error("#{parts.first}.#{parts.last} is private to module #{imported_module.name}") if imported_module.private_attribute?(parts.last)

          binding = imported_module.attributes[parts.last]
          raise_sema_error("unknown attribute #{name}") unless binding

          return binding
        end

        raise_sema_error("unknown attribute #{name}")
      end
    end
  end
end

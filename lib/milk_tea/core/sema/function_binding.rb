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

      def declare_functions
        expanded_declarations.each do |decl|
          with_error_node(decl) do
            case decl
            when AST::FunctionDef
              ensure_available_value_name!(decl.name, kind_label: "function", line: decl.line, column: decl.respond_to?(:column) ? decl.column : nil)
              @ctx.top_level_functions[decl.name] = declare_function_binding(decl)
            when AST::ExternFunctionDecl
              ensure_available_value_name!(decl.name, kind_label: "function", line: decl.line, column: decl.respond_to?(:column) ? decl.column : nil)
              if decl.mapping && !decl.mapping.is_a?(AST::StringLiteral)
                raise_sema_error("external function #{decl.name} mapping must be a c-string literal")
              end
              @ctx.top_level_functions[decl.name] = declare_function_binding(decl, external: true)
            when AST::ForeignFunctionDecl
              ensure_available_value_name!(decl.name, kind_label: "function", line: decl.line, column: decl.respond_to?(:column) ? decl.column : nil)
              @ctx.top_level_functions[decl.name] = declare_function_binding(decl)
            when AST::ExtendingBlock
              dispatch_receiver_type, receiver_type, receiver_type_param_names, receiver_type_param_constraints = resolve_methods_receiver_target(decl.type_name)

              decl.methods.each do |method|
                begin
                  binding = with_error_node(method) do
                    declare_function_binding(
                      method,
                      receiver_type:,
                      declared_receiver_type: receiver_type,
                      receiver_type_param_names:,
                      receiver_type_param_constraints:,
                    )
                  end
                  instance_method = receiver_type && method.kind != :static
                  method_key = instance_method ? binding.name : "static:#{binding.name}"
                  raise_sema_error("duplicate method #{decl.type_name}.#{binding.name}") if @ctx.methods[dispatch_receiver_type].key?(method_key)

                  @ctx.methods[dispatch_receiver_type][method_key] = binding
                rescue SemaError => e
                  collect_structural_error(e)
                end
              end
            end
          end
        rescue SemaError => e
          collect_structural_error(e)
        end
      end

      def declare_function_binding(decl, receiver_type: nil, declared_receiver_type: nil, receiver_type_param_names: [], receiver_type_param_constraints: {}, external: false)
        foreign = decl.is_a?(AST::ForeignFunctionDecl)
        async_function = decl.respond_to?(:async) ? decl.async : false
        if decl.is_a?(AST::MethodDef)
          ensure_non_reserved_primitive_name!(decl.name, kind_label: "function", line: decl.line, column: decl.column)
        end
        type_param_names = receiver_type_param_names + decl.type_params.map(&:name)
        type_param_constraints = receiver_type_param_constraints.merge(resolve_type_param_constraints(decl.type_params))
        raise_sema_error("external function #{decl.name} cannot be generic") if external && type_param_names.any?
        raise_sema_error("main cannot be generic") if decl.name == "main" && type_param_names.any?
        raise_sema_error("external function #{decl.name} cannot be async") if external && async_function
        raise_sema_error("foreign function #{decl.name} cannot be async") if foreign && async_function

        method_kind = decl.is_a?(AST::MethodDef) ? decl.kind : nil
        instance_method = receiver_type && method_kind != :static

        type_params = {}
        type_param_names.each do |name|
          raise_sema_error("duplicate type parameter #{decl.name}[#{name}]") if type_params.key?(name)

          type_params[name] = Types::TypeVar.new(name)
        end

        body_params = []
        if instance_method
          body_params << value_binding(
            name: "this",
            type: receiver_type,
            mutable: method_kind == :editable,
            kind: :param,
          )
        end

        public_params = []
        decl.params.each do |param|
          begin
            ensure_non_reserved_primitive_name!(param.name, kind_label: "parameter", line: param.respond_to?(:line) ? param.line : decl.line, column: param.respond_to?(:column) ? param.column : nil)
            type = resolve_type_ref(param.type, type_params:, type_param_constraints:)
            validate_parameter_ref_type!(type, function_name: decl.name, parameter_name: param.name, external:)
            validate_parameter_proc_type!(type, function_name: decl.name, parameter_name: param.name, external:, foreign:)
            raise_sema_error("parameter #{param.name} of #{decl.name} must pass event storage through ref[...] or pointers, got #{type}") if noncopyable_event_storage_type?(type)

            if external && array_type?(type)
              raise_sema_error("external function #{decl.name} cannot take array parameters")
            end

            if param.is_a?(AST::ForeignParam)
              if external
                raise_sema_error("external parameter #{param.name} of #{decl.name} cannot use `as`") if param.boundary_type
                unless %i[plain out inout].include?(param.mode)
                  raise_sema_error("external parameter #{param.name} of #{decl.name} cannot use `#{param.mode}`")
                end
              elsif foreign
                raise_sema_error("foreign parameter #{param.name} cannot use `as` with #{param.mode}") if ![:plain, :in].include?(param.mode) && param.boundary_type
                validate_consuming_foreign_parameter!(type, function_name: decl.name, parameter_name: param.name) if param.mode == :consuming
              end

              boundary_type = foreign_parameter_boundary_type(param, type, type_params:, type_param_constraints:)
              validate_foreign_boundary_type!(type, boundary_type, function_name: decl.name, parameter_name: param.name) if foreign && param.boundary_type && param.mode != :in
              validate_in_foreign_parameter!(type, boundary_type, function_name: decl.name, parameter_name: param.name) if foreign && param.mode == :in
              param_binding = value_binding(name: param.name, type: boundary_type || type, mutable: false, kind: :param)
              body_params << param_binding
              record_declaration_binding(param, param_binding)
              if foreign && param.boundary_type
                body_params << value_binding(
                  name: foreign_mapping_public_alias_name(param.name),
                  type:,
                  mutable: false,
                  kind: :param,
                )
              end
              public_params << Types::Registry.parameter(param.name, type, passing_mode: param.mode, boundary_type: boundary_type)
            else
              param_binding = value_binding(name: param.name, type:, mutable: false, kind: :param)
              body_params << param_binding
              record_declaration_binding(param, param_binding)
              public_params << Types::Registry.parameter(param.name, type) if external
            end
          rescue SemaError => e
            collect_structural_error(e)
            param_binding = value_binding(name: param.name, type: @error_type, mutable: false, kind: :param)
            body_params << param_binding
          end
        end

        receiver_editable = false
        call_params = body_params
        function_receiver_type = nil
        if instance_method
          receiver_editable = method_kind == :editable
          call_params = body_params.drop(1)
          function_receiver_type = receiver_type
        end

        call_params = public_params if foreign || external

        seen = {}
        body_params.each do |param|
          raise_sema_error("duplicate parameter #{param.name} in #{decl.name}") if seen.key?(param.name)

          seen[param.name] = true
        end

        body_return_type = decl.return_type ? resolve_type_ref(decl.return_type, type_params:, type_param_constraints:) : @ctx.types.fetch("void")
        validate_return_ref_type!(body_return_type, function_name: decl.name)
        validate_return_proc_type!(body_return_type, function_name: decl.name)
        raise_sema_error("function #{decl.name} cannot return event storage type #{body_return_type}") if noncopyable_event_storage_type?(body_return_type)
        if decl.name == "main" && async_function && body_return_type != @ctx.types.fetch("int") && body_return_type != @ctx.types.fetch("void")
          raise_sema_error("async main must return int or void")
        end
        if foreign && public_params.any? { |param| param.passing_mode == :consuming } && body_return_type != @ctx.types.fetch("void")
          raise_sema_error("foreign function #{decl.name} with consuming parameters must return void")
        end
        if external && array_type?(body_return_type)
          raise_sema_error("external function #{decl.name} cannot return arrays")
        end
        function_return_type = async_function ? Types::Registry.task(body_return_type) : body_return_type

        function_type = Types::Registry.function(
          decl.name,
          params: (foreign || external) ? call_params : call_params.map { |param| Types::Registry.parameter(param.name, param.type) },
          return_type: function_return_type,
          receiver_type: function_receiver_type,
          receiver_editable:,
          variadic: decl.respond_to?(:variadic) ? decl.variadic : false,
          external:,
        )

        FunctionBinding.new(
          name: decl.name,
          type: function_type,
          body_params:,
          body_return_type: body_return_type,
          ast: decl,
          external:,
          async: async_function,
          type_params: type_param_names.freeze,
          type_param_constraints: type_param_constraints.freeze,
          instances: {},
          type_arguments: [].freeze,
          owner: self,
          specialization_owner: nil,
          type_substitutions: {}.freeze,
          declared_receiver_type: declared_receiver_type,
        )
      end

      def resolve_type_param_constraints(type_params)
        type_params.each_with_object({}) do |type_param, constraints|
          if type_param.is_a?(AST::ValueTypeParam)
            ensure_non_reserved_type_binding_name!(
              type_param.name,
              kind_label: "type parameter",
              line: type_param.line,
              column: type_param.column,
              length: type_param.length,
            )
            next
          end

          ensure_non_reserved_type_binding_name!(
            type_param.name,
            kind_label: "type parameter",
            line: type_param.line,
            column: type_param.column,
            length: type_param.length,
          )
          next if type_param.constraints.empty?

          resolved_interfaces = []
          seen_interfaces = {}

          type_param.constraints.each do |constraint|
            case constraint.kind
            when :interface
              interface = resolve_interface_ref(constraint.interface_ref)
              raise_sema_error("duplicate interface constraint #{type_param.name} implements #{interface.name}") if seen_interfaces.key?(interface)

              seen_interfaces[interface] = true
              resolved_interfaces << interface
            else
              raise_sema_error("unsupported type parameter constraint #{constraint.kind}")
            end
          end

          constraints[type_param.name] = TypeParamConstraintBinding.new(
            interfaces: resolved_interfaces.freeze,
          )
        end
      end

      def check_functions
        @ctx.top_level_functions.each_value do |binding|
          check_function(binding)
        end

        @ctx.methods.each_value do |method_map|
          method_map.each_value do |binding|
            check_function(binding)
          end
        end
      end

      # Per-function error collection used by check_collecting_errors.
      # Continues past individual function failures, accumulating SemaErrors.
      def check_functions_collecting(errors)
        @ctx.top_level_functions.each_value do |binding|
          next if @checked_function_bindings[binding.object_id]

          prev_count = @structural_errors.length
          begin
            check_function(binding)
          rescue SemaError => e
            errors << e
          end
          errors.concat(@structural_errors[prev_count..].to_a)
        end

        @ctx.methods.each_value do |method_map|
          method_map.each_value do |binding|
            next if @checked_function_bindings[binding.object_id]

            prev_count = @structural_errors.length
            begin
              check_function(binding)
            rescue SemaError => e
              errors << e
            end
            errors.concat(@structural_errors[prev_count..].to_a)
          end
        end
      end

      def check_function(binding)
        @local_completion_frames = @local_completion_frames.dup if @local_completion_frames.frozen?

        previous_type_substitutions = @current_type_substitutions
        previous_specialization_owner = @current_specialization_owner
        started_check = false
        return if binding.external || binding.type_params.any?
        return if @checked_function_bindings[binding.object_id]
        return if @checking_function_bindings[binding.object_id]

        @checking_function_bindings[binding.object_id] = true
        started_check = true
        @current_type_substitutions = binding.type_substitutions
        @current_specialization_owner = binding.specialization_owner
        with_error_node(binding.ast) do
          with_scope(binding.body_params) do |scopes|
            start_local_completion_frame(binding, scopes)
            if binding.ast.is_a?(AST::ForeignFunctionDecl)
              record_callable_value_expression_site(binding.ast.mapping) unless binding.ast.mapping.is_a?(AST::Call)
              expression = foreign_mapping_expression(binding.ast)
              actual_type = with_foreign_mapping_context do
                infer_expression(expression, scopes:, expected_type: binding.type.return_type)
              end
              unless types_compatible?(actual_type, binding.type.return_type, expression:) || foreign_identity_projection_compatible?(actual_type, binding.type.return_type)
                raise_sema_error("foreign mapping #{binding.name} expects #{binding.type.return_type}, got #{actual_type}")
              end
            else
              validate_async_function_body!(binding.ast.body) if binding.async
              preassign_local_binding_ids(binding.ast.body)
              run_nullability_pre_pass(binding, scopes)
              if binding.ast.respond_to?(:const) && binding.ast.const
                with_compile_time do
                  if binding.async
                    with_async_function do
                      check_block(binding.ast.body, scopes:, return_type: binding.body_return_type)
                    end
                  else
                    check_block(binding.ast.body, scopes:, return_type: binding.type.return_type)
                  end
                end
              elsif binding.async
                with_async_function do
                  check_block(binding.ast.body, scopes:, return_type: binding.body_return_type)
                end
              else
                check_block(binding.ast.body, scopes:, return_type: binding.type.return_type)
              end
              check_definite_assignment(binding)
            end
          end
        end
        @checked_function_bindings[binding.object_id] = true
      ensure
        return unless started_check

        finish_local_completion_frame(binding)
        @preassigned_local_binding_ids = {}
        @nullability_flow_result = nil
        @current_type_substitutions = previous_type_substitutions
        @current_specialization_owner = previous_specialization_owner
        @checking_function_bindings.delete(binding.object_id)
      end

    end
  end
end

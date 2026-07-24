# frozen_string_literal: true

module MilkTea
  class SemanticAnalyzer
    class Checker
      private

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
                rescue SemanticError => e
                  collect_structural_error(e)
                end
              end
            end
          end
        rescue SemanticError => e
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
            reject_foreign_nullable_value_type!(type, function_name: decl.name, parameter_name: param.name) if foreign || external
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
          rescue SemanticError => e
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
        reject_foreign_nullable_value_type!(body_return_type, function_name: decl.name, parameter_name: nil) if foreign || external
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

      # Validates the body of a specialized (instantiated) function or method
      # binding.  The owner checker may be in collecting-errors mode, which
      # would silently swallow body errors into @structural_errors.  We
      # temporarily disable collect mode on the owner so the caller receives
      # the SemanticError directly.
      def validate_specialized_function_body(binding)
        owner = binding.owner
        prev_collecting = owner.instance_variable_get(:@collecting_errors)
        owner.instance_variable_set(:@collecting_errors, false)
        owner.send(:check_function, binding)
      ensure
        owner.instance_variable_set(:@collecting_errors, prev_collecting) if owner
      end

      # Per-function error collection used by check_collecting_errors.
      # Continues past individual function failures, accumulating SemanticErrors.
      def check_functions_collecting(errors)
        @ctx.top_level_functions.each_value do |binding|
          next if @checked_function_bindings[binding.object_id]

          prev_count = @structural_errors.length
          begin
            check_function(binding)
          rescue SemanticError => e
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
            rescue SemanticError => e
              errors << e
            end
            errors.concat(@structural_errors[prev_count..].to_a)
          end
        end
      end

      # Scans generic method bodies for assignments to this through a
      # non-editable receiver.  Full body checking is deferred to call-site
      # specialization, but immutable-this violations are type-independent.
      def check_generic_method_immutable_this(binding, scopes)
        this_binding = scopes.first&.values&.find { |v| v.name == "this" }
        return unless this_binding
        return if this_binding.mutable

        binding.ast.body&.each do |statement|
          next unless statement.is_a?(AST::Assignment) && statement.operator == "="
          next unless statement.target.is_a?(AST::MemberAccess) && statement.target.receiver.is_a?(AST::Identifier) && statement.target.receiver.name == "this"

          raise_sema_error("cannot assign through immutable this", statement.target)
        end
      end

      def check_function(binding)
        @local_completion_frames = @local_completion_frames.dup if @local_completion_frames.frozen?

        previous_type_substitutions = @current_type_substitutions
        previous_specialization_owner = @current_specialization_owner
        started_check = false
        return if binding.external
        return if @checked_function_bindings[binding.object_id]
        return if @checking_function_bindings[binding.object_id]

        @checking_function_bindings[binding.object_id] = true
        started_check = true
        @current_type_substitutions = binding.type_substitutions
        @current_specialization_owner = binding.specialization_owner
        with_error_node(binding.ast) do
          with_scope(binding.body_params) do |scopes|
            start_local_completion_frame(binding, scopes)
            if binding.type_params.any?
              check_generic_method_immutable_this(binding, scopes)
              return
            end

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
      ensure
        return unless started_check

        @checked_function_bindings[binding.object_id] = true
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

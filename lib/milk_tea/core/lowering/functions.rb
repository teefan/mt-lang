# frozen_string_literal: true

module MilkTea
  module LowererFunctions
    private


      def lower_functions
        lowered = []

        changed = true
        while changed
          changed = false

          @analysis.ast.declarations.each do |decl|
            case decl
            when AST::FunctionDef
              binding = @functions.fetch(decl.name)
              if binding.type_params.any?
                binding.instances.values.sort_by { |instance| instance.type_arguments.map(&:to_s).join(",") }.each do |instance|
                  c_name = function_binding_c_name(instance, module_name: @module_name)
                  next if @lowered_function_c_names[c_name]

                  lowered << lower_function_decl(instance)
                  @lowered_function_c_names[c_name] = true
                  changed = true
                end
              else
                c_name = function_binding_c_name(binding, module_name: @module_name)
                next if @lowered_function_c_names[c_name]

                lowered << lower_function_decl(binding)
                @lowered_function_c_names[c_name] = true
                if (entrypoint = build_root_main_entrypoint(binding))
                  next if @lowered_function_c_names[entrypoint.c_name]

                  lowered << entrypoint
                  @lowered_function_c_names[entrypoint.c_name] = true
                end
                changed = true
              end
            when AST::ExtendingBlock
              receiver_type = resolve_extending_receiver_type(@analysis, decl.type_name)
              decl.methods.each do |method|
                binding = @analysis.methods.fetch(receiver_type).fetch(method.name)
                if binding.type_params.any?
                  binding.instances.values.sort_by { |instance| instance.type_arguments.map(&:to_s).join(",") }.each do |instance|
                    c_name = function_binding_c_name(instance, module_name: @module_name, receiver_type:)
                    next if @lowered_function_c_names[c_name]

                    lowered << lower_function_decl(instance, receiver_type:)
                    @lowered_function_c_names[c_name] = true
                    changed = true
                  end
                else
                  c_name = function_binding_c_name(binding, module_name: @module_name, receiver_type:)
                  next if @lowered_function_c_names[c_name]

                  lowered << lower_function_decl(binding, receiver_type:)
                  @lowered_function_c_names[c_name] = true
                  changed = true
                end
              end
            end
          end
        end

        lowered
      end

      def resolve_extending_receiver_type(analysis, type_name)
        if type_name.is_a?(AST::TypeRef)
          generic_type = resolve_named_generic_type_for_analysis(analysis, type_name.name.parts)
          if generic_type.is_a?(Types::GenericStructDefinition)
            validate_methods_receiver_type_arguments!(type_name, generic_type)
            return generic_type
          end

          begin
            return resolve_type_ref_for_analysis(type_name, analysis)
          rescue LoweringError => error
            receiver_type_param_names = methods_receiver_type_argument_names!(type_name)
            raise error if receiver_type_param_names.empty?

            receiver_type_params = receiver_type_param_names.to_h { |name| [name, Types::TypeVar.new(name)] }
            receiver_type = resolve_type_ref_for_analysis(type_name, analysis, type_params: receiver_type_params)
            return method_dispatch_receiver_type(receiver_type)
          end
        end

        parts = type_name.name.parts
        if parts.length == 1
          return analysis.types.fetch(parts.first)
        end

        if parts.length == 2
          imported_module = analysis.imports.fetch(parts.first)
          return imported_module.types.fetch(parts.last)
        end

        raise LoweringError, "unsupported extending target #{type_name}"
      end

      def lower_function_decl(binding, receiver_type: nil)
        decl = binding.ast
        params = []
        env = empty_env
        parameter_setup = []
        previous_type_substitutions = @current_type_substitutions
        @current_type_substitutions = binding.type_substitutions

        return lower_async_function_decl(binding, receiver_type:) if binding.async

        receiver_by_pointer = pointer_lowered_sync_method_receiver?(binding)

        body_params = binding.body_params.dup
        if binding.type.receiver_type
          receiver_binding = body_params.shift
          c_name = c_local_name(receiver_binding.name)
          env[:scopes].last[receiver_binding.name] = local_binding(
            type: receiver_binding.type,
            c_name:,
            mutable: receiver_binding.mutable,
            pointer: receiver_by_pointer,
          )
          params << IR::Param.new(
            name: receiver_binding.name,
            c_name:,
            type: receiver_binding.type,
            pointer: receiver_by_pointer,
          )
        end

        body_params.each_with_index do |param_binding, index|
          type = param_binding.type

          c_name = c_local_name(param_binding.name)
          if array_type?(type)
            input_c_name = "#{c_name}_input"
            params << IR::Param.new(name: param_binding.name, c_name: input_c_name, type:, pointer: false)
            env[:scopes].last[param_binding.name] = local_binding(type:, c_name:, mutable: false, pointer: false)
            parameter_setup << IR::LocalDecl.new(
              name: param_binding.name,
              c_name:,
              type:,
              value: IR::Name.new(name: input_c_name, type:, pointer: false),
            )
          else
            env[:scopes].last[param_binding.name] = local_binding(type:, c_name:, mutable: false, pointer: false)
            params << IR::Param.new(name: param_binding.name, c_name:, type:, pointer: false)
          end
        end

        return_type = binding.type.return_type
        body = lower_block(decl.body, env:, active_defers: [], return_type:, loop_flow: nil, allow_return: true)
        body = parameter_setup + body

        IR::Function.new(
          name: decl.name,
          c_name: function_binding_c_name(binding, module_name: @module_name, receiver_type:),
          params:,
          return_type:,
          body:,
          entry_point: false,
          method_receiver_param: !binding.type.receiver_type.nil?,
        )
      ensure
        @current_type_substitutions = previous_type_substitutions
      end

      def lower_async_function_decl(binding, receiver_type: nil)
        decl = binding.ast
        normalized_statements = normalize_async_body(binding, decl.body)
        constructor_c_name = function_binding_c_name(binding, module_name: @module_name, receiver_type:)
        frame_c_name = "#{constructor_c_name}__frame"
        resume_c_name = "#{constructor_c_name}__resume"
        ready_c_name = "#{constructor_c_name}__ready"
        set_waiter_c_name = "#{constructor_c_name}__set_waiter"
        release_c_name = "#{constructor_c_name}__release"
        take_result_c_name = "#{constructor_c_name}__take_result"

        async_info = analyze_async_function(binding, normalized_statements)
        frame_type = build_async_frame_type(frame_c_name, async_info)

        @synthetic_structs << IR::StructDecl.new(
          name: frame_c_name,
          c_name: frame_c_name,
          fields: frame_type.fields.map { |field_name, field_type| IR::Field.new(name: field_name, type: field_type) },
          packed: false,
          alignment: nil,
        )
        @synthetic_functions << build_async_resume_function(binding, normalized_statements, frame_type, resume_c_name, async_info)
        @synthetic_functions << build_async_ready_function(frame_type, ready_c_name, async_info)
        @synthetic_functions << build_async_set_waiter_function(frame_type, set_waiter_c_name, async_info)
        @synthetic_functions << build_async_release_function(frame_type, release_c_name, async_info)
        @synthetic_functions << build_async_take_result_function(frame_type, take_result_c_name, async_info)

        if root_main_entrypoint_signature(binding)
          @synthetic_functions << build_async_constructor_function(
            binding,
            decl,
            frame_type,
            constructor_c_name,
            resume_c_name,
            ready_c_name,
            set_waiter_c_name,
            release_c_name,
            take_result_c_name,
            async_info,
          )

          return build_async_main_entrypoint(binding, constructor_c_name, async_info)
        end

        build_async_constructor_function(
          binding,
          decl,
          frame_type,
          constructor_c_name,
          resume_c_name,
          ready_c_name,
          set_waiter_c_name,
          release_c_name,
          take_result_c_name,
          async_info,
        )
      end
  end
end

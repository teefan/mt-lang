# frozen_string_literal: true

module MilkTea
  module LowererFunctions
    private


      def lower_functions
        lowered = []

        changed = true
        while changed
          changed = false

          expanded_declarations.each do |decl|
            case decl
            when AST::FunctionDef
              binding = @ctx.functions.fetch(decl.name)
              next if binding.body_return_type == Types::BUILTIN_TYPE_META_TYPE
              if binding.type_params.any?
                binding.instances.values.sort_by { |instance| instance.type_arguments.map(&:to_s).join(",") }.each do |instance|
                  linkage_name = function_binding_c_name(instance, module_name: @ctx.module_name)
                  next if @artifacts.lowered_function_linkage_names[linkage_name]

                  lowered << lower_function_decl(instance)
                  @artifacts.lowered_function_linkage_names[linkage_name] = true
                  changed = true
                end
              else
                linkage_name = function_binding_c_name(binding, module_name: @ctx.module_name)
                next if @artifacts.lowered_function_linkage_names[linkage_name]

                lowered << lower_function_decl(binding)
                @artifacts.lowered_function_linkage_names[linkage_name] = true
                if @ctx.module_name.to_s == @program.root_analysis.module_name.to_s
                  if (entrypoint = build_root_main_entrypoint(binding))
                    next if @artifacts.lowered_function_linkage_names[entrypoint.linkage_name]

                    lowered << entrypoint
                    @artifacts.lowered_function_linkage_names[entrypoint.linkage_name] = true
                  end
                end
                changed = true
              end
            when AST::ExtendingBlock
              receiver_type = resolve_extending_receiver_type(@ctx.analysis, decl.type_name)
              methods_hash = @ctx.methods[receiver_type]
              unless methods_hash
                methods_hash = @ctx.methods.find { |k, _| k.to_s == receiver_type.to_s }&.last
              end
              next unless methods_hash
              decl.methods.each do |method|
                binding = methods_hash[method.kind == :static ? "static:#{method.name}" : method.name]
                next unless binding
                if binding.type_params.any?
                  binding.instances.values.sort_by { |instance| instance.type_arguments.map(&:to_s).join(",") }.each do |instance|
                    linkage_name = function_binding_c_name(instance, module_name: @ctx.module_name, receiver_type:)
                    next if @artifacts.lowered_function_linkage_names[linkage_name]

                    lowered << lower_function_decl(instance, receiver_type:)
                    @artifacts.lowered_function_linkage_names[linkage_name] = true
                    changed = true
                  end
                else
                  linkage_name = function_binding_c_name(binding, module_name: @ctx.module_name, receiver_type:)
                  next if @artifacts.lowered_function_linkage_names[linkage_name]

                  lowered << lower_function_decl(binding, receiver_type:)
                  @artifacts.lowered_function_linkage_names[linkage_name] = true
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
          return types_for_module(analysis.module_name).fetch(parts.first)
        end

        if parts.length == 2
          imported_module = imports_for_module(analysis.module_name).fetch(parts.first)
          return imported_module.types.fetch(parts.last)
        end

        raise LoweringError, "unsupported extending target #{type_name}"
      end

      def lower_function_decl(binding, receiver_type: nil)
        decl = binding.ast
        params = []
        env = empty_env
        parameter_setup = []
        previous_type_substitutions = @ctx.current_type_substitutions
        @ctx.current_type_substitutions = binding.type_substitutions

        return lower_async_function_decl(binding, receiver_type:) if binding.async

        receiver_by_pointer = pointer_lowered_sync_method_receiver?(binding)

        body_params = binding.body_params.dup
        if binding.type.receiver_type
          receiver_binding = body_params.shift
          linkage_name = c_local_name(receiver_binding.name)
          env[:scopes].last[receiver_binding.name] = local_binding(
            type: receiver_binding.type,
            linkage_name:,
            mutable: receiver_binding.mutable,
            pointer: receiver_by_pointer,
          )
          params << IR::Param.new(
            name: receiver_binding.name,
            linkage_name:,
            type: receiver_binding.type,
            pointer: receiver_by_pointer,
          )
        end

        body_params.each_with_index do |param_binding, index|
          type = param_binding.type

          linkage_name = c_local_name(param_binding.name)
          if array_type?(type)
            input_linkage_name = "#{linkage_name}_input"
            params << IR::Param.new(name: param_binding.name, linkage_name: input_linkage_name, type:, pointer: false)
            env[:scopes].last[param_binding.name] = local_binding(type:, linkage_name:, mutable: false, pointer: false)
            parameter_setup << IR::LocalDecl.new(
              name: param_binding.name,
              linkage_name:,
              type:,
              value: IR::Name.new(name: input_linkage_name, type:, pointer: false),
            )
          else
            env[:scopes].last[param_binding.name] = local_binding(type:, linkage_name:, mutable: false, pointer: false)
            params << IR::Param.new(name: param_binding.name, linkage_name:, type:, pointer: false)
          end
        end

        return_type = binding.type.return_type
        body = lower_block(decl.body, env:, active_defers: [], return_type:, loop_flow: nil, allow_return: true)
        body = parameter_setup + body

        IR::Function.new(
          name: decl.name,
          linkage_name: function_binding_c_name(binding, module_name: @ctx.module_name, receiver_type:),
          params:,
          return_type:,
          body:,
          entry_point: false,
          method_receiver_param: !binding.type.receiver_type.nil?,
        )
      ensure
        @ctx.current_type_substitutions = previous_type_substitutions
      end

      def lower_async_function_decl(binding, receiver_type: nil)
        decl = binding.ast
        normalized_statements = normalize_async_body(binding, decl.body)
        constructor_linkage_name = function_binding_c_name(binding, module_name: @ctx.module_name, receiver_type:)
        frame_linkage_name = "#{constructor_linkage_name}__frame"
        resume_linkage_name = "#{constructor_linkage_name}__resume"
        ready_linkage_name = "#{constructor_linkage_name}__ready"
        set_waiter_linkage_name = "#{constructor_linkage_name}__set_waiter"
        release_linkage_name = "#{constructor_linkage_name}__release"
        take_result_linkage_name = "#{constructor_linkage_name}__take_result"
        cancel_linkage_name = "#{constructor_linkage_name}__cancel"

        async_info = analyze_async_function(binding, normalized_statements)
        frame_type = build_async_frame_type(frame_linkage_name, async_info)

        @artifacts.synthetic_structs << IR::StructDecl.new(
          name: frame_linkage_name,
          linkage_name: frame_linkage_name,
          fields: frame_type.fields.map { |field_name, field_type| IR::Field.new(name: field_name, type: field_type) },
          packed: false,
          alignment: nil,
        )
        @artifacts.synthetic_functions << build_async_resume_function(binding, normalized_statements, frame_type, resume_linkage_name, async_info)
        @artifacts.synthetic_functions << build_async_ready_function(frame_type, ready_linkage_name, async_info)
        @artifacts.synthetic_functions << build_async_set_waiter_function(frame_type, set_waiter_linkage_name, async_info)
        @artifacts.synthetic_functions << build_async_release_function(frame_type, release_linkage_name, async_info)
        @artifacts.synthetic_functions << build_async_take_result_function(frame_type, take_result_linkage_name, async_info)
        @artifacts.synthetic_functions << build_async_cancel_function(frame_type, cancel_linkage_name, async_info)

        if root_main_entrypoint_signature(binding)
          @artifacts.synthetic_functions << build_async_constructor_function(
            binding,
            decl,
            frame_type,
            constructor_linkage_name,
            resume_linkage_name,
            ready_linkage_name,
            set_waiter_linkage_name,
            release_linkage_name,
            take_result_linkage_name,
            cancel_linkage_name,
            async_info,
          )

          return build_async_main_entrypoint(binding, constructor_linkage_name, async_info)
        end

        build_async_constructor_function(
          binding,
          decl,
          frame_type,
          constructor_linkage_name,
          resume_linkage_name,
          ready_linkage_name,
          set_waiter_linkage_name,
          release_linkage_name,
          take_result_linkage_name,
          cancel_linkage_name,
          async_info,
        )
      end
  end
end

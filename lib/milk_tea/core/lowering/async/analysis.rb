# frozen_string_literal: true

module MilkTea
  module LowererAsync
    private

    def analyze_async_function(binding, statements)
      env = empty_env
      void_ptr = pointer_to(@ctx.types.fetch("void"))
      wake_type = Types::Function.new(
        nil,
        params: [Types::Parameter.new("frame", void_ptr)],
        return_type: @ctx.types.fetch("void"),
      )
      param_fields = {}
      local_fields = {}
      await_fields = {}
      await_counter = 0

      binding.body_params.each do |param_binding|
        pointer = binding.type.receiver_type && binding.type.receiver_editable && param_binding.name == "this"
        field_type = pointer ? pointer_to(param_binding.type) : param_binding.type
        field_name = "param_#{param_binding.name}"
        param_fields[param_binding.name] = {
          field_name:,
          type: field_type,
          param_type: param_binding.type,
          mutable: param_binding.mutable,
          pointer:,
        }
        env[:scopes].last[param_binding.name] = local_binding(
          type: param_binding.type,
          c_name: field_name,
          mutable: param_binding.mutable,
          pointer:,
        )
      end
      env[:return_context] = {
        return_type: binding.body_return_type,
        active_defers: [],
        local_defers: [],
        allow_return: true,
      }

      await_counter = analyze_async_statements!(statements, await_counter, env, param_fields, local_fields, await_fields)

      {
        task_type: binding.type.return_type,
        result_type: binding.body_return_type,
        void_ptr:,
        wake_type:,
        param_fields:,
        local_fields:,
        await_fields:,
        format_str_fields: {},
      }
    end

    # Recursively scan nested statement bodies for await slots, assigning state IDs.
    # Returns the updated await_counter.
    def analyze_async_statements!(statements, await_counter, env, param_fields, local_fields, await_fields)
      statements.each do |statement|
        case statement
        when AST::LocalDecl
          type, storage_type = async_local_decl_types(statement, env:)
          local_field_key = async_local_decl_field_key(statement)
          local_fields[local_field_key] ||= { field_name: async_local_decl_field_name(statement), type:, storage_type:, mutable: statement.kind == :var }
          if statement.value.is_a?(AST::AwaitExpr)
            await_fields[statement.value.object_id] = build_async_await_field_info(statement.value, await_counter, env:, param_fields:, local_fields:)
            await_counter += 1
          end
          if bind_let_else_local?(statement)
            env[:scopes].last[statement.name] = local_binding(
              type:,
              storage_type:,
              c_name: statement.name,
              mutable: statement.kind == :var,
              pointer: false,
              const_value: statement.else_body ? nil : statement.kind == :let && statement.value ? compile_time_const_value(statement.value, env:) : nil,
            )
          end
          await_counter = analyze_async_statements!(statement.else_body, await_counter, env, param_fields, local_fields, await_fields) if statement.else_body
        when AST::Assignment
          if statement.value.is_a?(AST::AwaitExpr)
            await_fields[statement.value.object_id] = build_async_await_field_info(statement.value, await_counter, env:, param_fields:, local_fields:)
            await_counter += 1
          end
        when AST::ExpressionStmt
          if statement.expression.is_a?(AST::AwaitExpr)
            await_fields[statement.expression.object_id] = build_async_await_field_info(statement.expression, await_counter, env:, param_fields:, local_fields:)
            await_counter += 1
          end
        when AST::ReturnStmt
          if statement.value&.is_a?(AST::AwaitExpr)
            await_fields[statement.value.object_id] = build_async_await_field_info(statement.value, await_counter, env:, param_fields:, local_fields:)
            await_counter += 1
          end
        when AST::IfStmt
          statement.branches.each do |branch|
            await_counter = analyze_async_statements!(branch.body, await_counter, env, param_fields, local_fields, await_fields)
          end
          await_counter = analyze_async_statements!(statement.else_body, await_counter, env, param_fields, local_fields, await_fields) if statement.else_body
        when AST::WhileStmt
          await_counter = analyze_async_statements!(statement.body, await_counter, env, param_fields, local_fields, await_fields)
        when AST::ForStmt
          if range_iterable?(statement.iterable)
            loop_type = infer_range_loop_type(statement.iterable, env:)
            local_fields[statement.name] ||= { field_name: "local_#{statement.name}", type: loop_type, storage_type: loop_type, mutable: true }
            stop_field_name = "local_#{statement.name}_stop"
            local_fields[stop_field_name] ||= { field_name: stop_field_name, type: loop_type, storage_type: loop_type, mutable: true }
          else
            statement.bindings.each_with_index do |binding, index|
              iterable_type = infer_expression_type(statement.iterables[index], env:)
              element_type = collection_loop_type(iterable_type)
              binding_type = collection_loop_binding_type(iterable_type, element_type) || element_type
              local_fields[binding.name] ||= { field_name: "local_#{binding.name}", type: binding_type, storage_type: binding_type, mutable: true }
              iterable_field_name = async_collection_iterable_field_name(statement, index)
              iterable_field_key = async_collection_iterable_field_key(statement, index)
              local_fields[iterable_field_key] ||= { field_name: iterable_field_name, type: iterable_type, storage_type: iterable_type, mutable: true }
            end
            index_field_name = async_collection_index_field_name(statement)
            index_field_key = async_collection_index_field_key(statement)
            local_fields[index_field_key] ||= { field_name: index_field_name, type: @ctx.types.fetch("ptr_uint"), storage_type: @ctx.types.fetch("ptr_uint"), mutable: true }
          end
          await_counter = analyze_async_statements!(statement.body, await_counter, env, param_fields, local_fields, await_fields)
        when AST::MatchStmt
          scrutinee_type = infer_expression_type(statement.expression, env:)
          statement.arms.each do |arm|
            arm_env = duplicate_env(env)
            bind_async_variant_match_arm_env!(arm_env, scrutinee_type, arm)
            arm_await_count = await_counter
            await_counter = analyze_async_statements!(arm.body, await_counter, arm_env, param_fields, local_fields, await_fields)
            if arm.binding_name && await_counter > arm_await_count
              field_key = async_match_binding_field_key(arm)
              unless local_fields.key?(field_key)
                arm_name = variant_match_arm_name_from_pattern(arm.pattern)
                if arm_name
                  arm_binding = arm_env[:scopes].last[arm.binding_name]
                  payload_type = arm_binding && arm_binding[:type]
                  if payload_type
                    local_fields[field_key] = { field_name: async_match_binding_field_name(arm), type: payload_type, storage_type: payload_type, mutable: false }
                  end
                end
              end
            end
          end
        when AST::UnsafeStmt
          await_counter = analyze_async_statements!(statement.body, await_counter, env, param_fields, local_fields, await_fields)
        when AST::DeferStmt
          if statement.body
            cleanup_env = duplicate_env(env)
            cleanup_env[:return_context] = cleanup_env[:return_context]&.merge(allow_return: false)
            await_counter = analyze_async_statements!(statement.body, await_counter, cleanup_env, param_fields, local_fields, await_fields)
          end
          if statement.expression.is_a?(AST::AwaitExpr)
            await_fields[statement.expression.object_id] = build_async_await_field_info(statement.expression, await_counter, env:, param_fields:, local_fields:)
            await_counter += 1
          end
        else
          nil
        end
      end
      await_counter
    end

    def async_local_decl_types(statement, env:)
      storage_type = if statement.else_body
                       infer_expression_type(statement.value, env:)
                     elsif statement.type
                       resolve_type_ref(statement.type)
                     else
                       infer_expression_type(statement.value, env:)
                     end
      type = if statement.else_body
               statement.type ? resolve_type_ref(statement.type) : let_else_success_type(storage_type)
             else
               storage_type
             end

      [type, storage_type]
    end

    def async_collection_iterable_field_key(statement, index = 0)
      "__async_for_iterable_#{statement.line}_#{index}"
    end

    def async_collection_iterable_field_name(statement, index = 0)
      "for_iterable_#{statement.line}_#{index}"
    end

    def async_collection_index_field_key(statement)
      "__async_for_index_#{statement.line}"
    end

    def async_collection_index_field_name(statement)
      "for_index_#{statement.line}"
    end

    def build_async_await_field_info(await_expression, await_counter, env:, param_fields:, local_fields:)
      task_expression = await_expression.expression
      reused_field_name = reusable_async_await_task_field_name(task_expression, param_fields:, local_fields:)
      {
        field_name: reused_field_name || "await_#{await_counter}",
        task_type: infer_expression_type(task_expression, env:),
        result_type: infer_expression_type(await_expression, env:),
        state: await_counter + 1,
        reuse_existing_storage: !reused_field_name.nil?,
      }
    end

    def reusable_async_await_task_field_name(task_expression, param_fields:, local_fields:)
      return unless task_expression.is_a?(AST::Identifier)
      return local_fields.fetch(task_expression.name)[:field_name] if local_fields.key?(task_expression.name)
      return param_fields.fetch(task_expression.name)[:field_name] if param_fields.key?(task_expression.name)

      nil
    end

    def build_async_frame_type(frame_c_name, async_info)
      fields = {
        "ready" => @ctx.types.fetch("bool"),
        "cancelled" => @ctx.types.fetch("bool"),
        "waiter_frame" => async_info[:void_ptr],
        "waiter" => async_info[:wake_type],
      }
      fields["state"] = @ctx.types.fetch("int") unless async_info[:await_fields].empty?
      unless async_info[:result_type] == @ctx.types.fetch("void")
        fields["result"] = async_info[:result_type]
      end
      async_info[:param_fields].each_value do |field_info|
        fields[field_info[:field_name]] = field_info[:type]
      end
      async_info[:local_fields].each_value do |field_info|
        fields[field_info[:field_name]] = field_info[:storage_type]
      end
      async_info[:await_fields].each_value do |field_info|
        next if fields.key?(field_info[:field_name])

        fields[field_info[:field_name]] = field_info[:task_type]
      end

      Types::Struct.new(frame_c_name).define_fields(fields)
    end
  end
end

# frozen_string_literal: true

module MilkTea
  module LowererAsync
    private


      def build_async_main_entrypoint(binding, _constructor_c_name, async_info)
        task_type = async_info[:task_type]
        signature = root_main_entrypoint_signature(binding)
        raise LoweringError, "async main entrypoint requires a supported signature" unless signature

        params, setup_statements, call_arguments, cleanup_statements = build_root_main_entrypoint_bridge(signature)
        body = []
        env = empty_env

        root_proc_name = "__mt_async_main_root"
        result_name = "__mt_result"

        body.concat(setup_statements)
        argument_names = binding.type.params.each_index.map { |index| "__mt_async_main_arg_#{index + 1}" }
        binding.type.params.each_with_index do |param, index|
          name = argument_names.fetch(index)
          env[:scopes].last[name] = local_binding(type: param.type, c_name: name, mutable: false, pointer: false)
          body << IR::LocalDecl.new(
            name: name,
            c_name: name,
            type: param.type,
            value: call_arguments.fetch(index),
          )
        end

        proc_expression = AST::ProcExpr.new(
          params: [],
          return_type: ast_type_ref_for(task_type),
          body: [
            AST::ReturnStmt.new(
              value: AST::Call.new(
                callee: AST::Identifier.new(name: binding.name),
                arguments: argument_names.map { |name| AST::Argument.new(name: nil, value: AST::Identifier.new(name: name)) },
              ),
            ),
          ],
        )
        root_proc_type = Types::Proc.new(params: [], return_type: task_type)
        proc_setup, proc_value = lower_proc_expression_for_local(proc_expression, env:, local_name: root_proc_name, proc_type: root_proc_type)
        body.concat(proc_setup)
        body << IR::LocalDecl.new(
          name: root_proc_name,
          c_name: root_proc_name,
          type: root_proc_type,
          value: proc_value,
        )

        root_proc_expr = IR::Name.new(name: root_proc_name, type: root_proc_type, pointer: false)

        if async_info[:result_type] == @types.fetch("int")
          wait_callee = async_main_runtime_callee_name("wait", type_arguments: [async_info[:result_type]])
          body << IR::LocalDecl.new(
            name: result_name,
            c_name: result_name,
            type: @types.fetch("int"),
            value: IR::Call.new(
              callee: wait_callee,
              arguments: [root_proc_expr],
              type: @types.fetch("int"),
            ),
          )
        else
          run_callee = async_main_runtime_callee_name("run")
          body << IR::ExpressionStmt.new(
            expression: IR::Call.new(
              callee: run_callee,
              arguments: [root_proc_expr],
              type: @types.fetch("void"),
            ),
          )
        end

        body << IR::ExpressionStmt.new(
          expression: lower_proc_release_expression(root_proc_expr, root_proc_type),
        )
        body.concat(cleanup_statements)
        body << IR::ReturnStmt.new(
          value: async_info[:result_type] == @types.fetch("int") ? IR::Name.new(name: result_name, type: @types.fetch("int"), pointer: false) : IR::IntegerLiteral.new(value: 0, type: @types.fetch("int")),
        )

        IR::Function.new(
          name: binding.name,
          c_name: "main",
          params:,
          return_type: @types.fetch("int"),
          body: body,
          entry_point: true,
        )
      end

      def async_main_runtime_callee_name(function_name, type_arguments: [])
        binding = analysis_for_module("std.async").functions.fetch(function_name)
        binding = binding.owner.send(:instantiate_function_binding, binding, type_arguments) if type_arguments.any?
        function_binding_c_name(binding, module_name: binding.owner.module_name)
      end

      def build_root_main_entrypoint(binding)
        return nil if binding.async

        signature = root_main_entrypoint_signature(binding)
        return nil unless signature

        params, setup_statements, call_arguments, cleanup_statements = build_root_main_entrypoint_bridge(signature)
        return_type = binding.body_return_type
        body = []
        call = IR::Call.new(
          callee: function_binding_c_name(binding, module_name: @module_name),
          arguments: call_arguments,
          type: return_type,
        )

        body.concat(setup_statements)
        if return_type == @types.fetch("void")
          body << IR::ExpressionStmt.new(expression: call)
          body.concat(cleanup_statements)
          body << IR::ReturnStmt.new(value: IR::IntegerLiteral.new(value: 0, type: @types.fetch("int")))
        elsif cleanup_statements.empty?
          body << IR::ReturnStmt.new(value: call)
        else
          result_name = "__mt_result"
          body << IR::LocalDecl.new(
            name: result_name,
            c_name: result_name,
            type: @types.fetch("int"),
            value: call,
          )
          body.concat(cleanup_statements)
          body << IR::ReturnStmt.new(value: IR::Name.new(name: result_name, type: @types.fetch("int"), pointer: false))
        end

        IR::Function.new(
          name: binding.name,
          c_name: "main",
          params:,
          return_type: @types.fetch("int"),
          body:,
          entry_point: true,
        )
      end

      def build_root_main_entrypoint_bridge(signature)
        argc_type = @types.fetch("int")
        raw_argv_type = pointer_to(pointer_to(@types.fetch("char")))
        argc_name = "argc"
        argv_name = "argv"

        case signature[:kind]
        when :none
          [[], [], [], []]
        when :raw_char_ptr_ptr
          argc_expr = IR::Name.new(name: argc_name, type: argc_type, pointer: false)
          argv_expr = IR::Name.new(name: argv_name, type: raw_argv_type, pointer: false)
          [
            [
              IR::Param.new(name: argc_name, c_name: argc_name, type: argc_type, pointer: false),
              IR::Param.new(name: argv_name, c_name: argv_name, type: raw_argv_type, pointer: false),
            ],
            [],
            [argc_expr, argv_expr],
            [],
          ]
        when :raw_cstr_ptr
          argc_expr = IR::Name.new(name: argc_name, type: argc_type, pointer: false)
          argv_expr = IR::Cast.new(
            target_type: signature[:argv_type],
            expression: IR::Name.new(name: argv_name, type: raw_argv_type, pointer: false),
            type: signature[:argv_type],
          )
          [
            [
              IR::Param.new(name: argc_name, c_name: argc_name, type: argc_type, pointer: false),
              IR::Param.new(name: argv_name, c_name: argv_name, type: raw_argv_type, pointer: false),
            ],
            [],
            [argc_expr, argv_expr],
            [],
          ]
        when :span_str
          items_type = pointer_to(@types.fetch("str"))
          items_name = "__mt_args_items"
          args_name = "__mt_args"
          items_expr = IR::Name.new(name: items_name, type: items_type, pointer: false)
          args_expr = IR::Name.new(name: args_name, type: signature[:args_type], pointer: false)
          argc_expr = IR::Name.new(name: argc_name, type: argc_type, pointer: false)
          argv_expr = IR::Name.new(name: argv_name, type: raw_argv_type, pointer: false)

          setup = [
            IR::LocalDecl.new(
              name: items_name,
              c_name: items_name,
              type: items_type,
              value: IR::NullLiteral.new(type: items_type),
            ),
            IR::LocalDecl.new(
              name: args_name,
              c_name: args_name,
              type: signature[:args_type],
              value: IR::Call.new(
                callee: "mt_entry_argv_to_span_str",
                arguments: [
                  argc_expr,
                  argv_expr,
                  IR::AddressOf.new(expression: items_expr, type: pointer_to(items_type)),
                ],
                type: signature[:args_type],
              ),
            ),
          ]
          cleanup = [
            IR::ExpressionStmt.new(
              expression: IR::Call.new(callee: "mt_free_entry_argv_strs", arguments: [items_expr], type: @types.fetch("void")),
            ),
          ]

          [
            [
              IR::Param.new(name: argc_name, c_name: argc_name, type: argc_type, pointer: false),
              IR::Param.new(name: argv_name, c_name: argv_name, type: raw_argv_type, pointer: false),
            ],
            setup,
            [args_expr],
            cleanup,
          ]
        else
          raise LoweringError, "unsupported root main entrypoint bridge #{signature[:kind]}"
        end
      end

      def root_main_entrypoint_signature(binding)
        return nil unless @analysis == @program.root_analysis
        return nil unless binding.type.receiver_type.nil?
        return nil unless binding.name == "main"
        return nil unless binding.type_arguments.empty?

        return_type = binding.body_return_type
        return nil unless return_type == @types.fetch("int") || return_type == @types.fetch("void")

        params = binding.type.params
        return { kind: :none } if params.empty?

        if params.length == 1 && params.first.type.is_a?(Types::Span) && params.first.type.element_type == @types.fetch("str")
          return { kind: :span_str, args_type: params.first.type }
        end

        return nil unless params.length == 2
        return nil unless params[0].type == @types.fetch("int")

        argv_type = params[1].type
        return { kind: :raw_cstr_ptr, argv_type: } if argv_type == pointer_to(@types.fetch("cstr"))
        return { kind: :raw_char_ptr_ptr, argv_type: } if argv_type == pointer_to(pointer_to(@types.fetch("char")))

        nil
      end

      def analyze_async_function(binding, statements)
        env = empty_env
        void_ptr = pointer_to(@types.fetch("void"))
        wake_type = Types::Function.new(
          nil,
          params: [Types::Parameter.new("frame", void_ptr)],
          return_type: @types.fetch("void"),
        )
        param_fields = {}
        local_fields = {}
        await_fields = {}
        await_counter = 0

        binding.body_params.each do |param_binding|
          pointer = binding.type.receiver_type && binding.type.receiver_mutable && param_binding.name == "this"
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

        statements.each_with_index do |statement, index|
          case statement
          when AST::LocalDecl
            type, storage_type = async_local_decl_types(statement, env:)
            local_field_key = async_local_decl_field_key(statement)
            local_fields[local_field_key] = { field_name: async_local_decl_field_name(statement), type:, storage_type:, mutable: statement.kind == :var }
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
            next unless statement.value.is_a?(AST::AwaitExpr)

            await_fields[statement.value.object_id] = build_async_await_field_info(statement.value, await_counter, env:, param_fields:, local_fields:)
            await_counter += 1
          when AST::ExpressionStmt
            next unless statement.expression.is_a?(AST::AwaitExpr)

            await_fields[statement.expression.object_id] = build_async_await_field_info(statement.expression, await_counter, env:, param_fields:, local_fields:)
            await_counter += 1
          when AST::ReturnStmt
            next unless statement.value&.is_a?(AST::AwaitExpr)

            await_fields[statement.value.object_id] = build_async_await_field_info(statement.value, await_counter, env:, param_fields:, local_fields:)
            await_counter += 1
          when AST::IfStmt
            statement.branches.each do |branch|
              await_counter = analyze_async_statements!(branch.body, await_counter, env, param_fields, local_fields, await_fields)
            end
            await_counter = analyze_async_statements!(statement.else_body, await_counter, env, param_fields, local_fields, await_fields) if statement.else_body
          when AST::WhileStmt
            await_counter = analyze_async_statements!(statement.body, await_counter, env, param_fields, local_fields, await_fields)
          when AST::ForStmt
            # For loops with await need the loop variable in the frame so it survives across suspension
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
              local_fields[index_field_key] ||= { field_name: index_field_name, type: @types.fetch("ptr_uint"), storage_type: @types.fetch("ptr_uint"), mutable: true }
            end
            await_counter = analyze_async_statements!(statement.body, await_counter, env, param_fields, local_fields, await_fields)
          when AST::MatchStmt
            scrutinee_type = infer_expression_type(statement.expression, env:)
            statement.arms.each do |arm|
              arm_env = duplicate_env(env)
              bind_async_variant_match_arm_env!(arm_env, scrutinee_type, arm)
              await_counter = analyze_async_statements!(arm.body, await_counter, arm_env, param_fields, local_fields, await_fields)
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
          when AST::BreakStmt, AST::ContinueStmt, AST::StaticAssert
              nil
          else
            raise LoweringError, "unsupported async statement #{statement.class.name}"
          end
        end

        {
          task_type: binding.type.return_type,
            result_type: binding.body_return_type,
          void_ptr:,
          wake_type:,
          param_fields:,
          local_fields:,
          await_fields:,
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
              local_fields[index_field_key] ||= { field_name: index_field_name, type: @types.fetch("ptr_uint"), storage_type: @types.fetch("ptr_uint"), mutable: true }
            end
            await_counter = analyze_async_statements!(statement.body, await_counter, env, param_fields, local_fields, await_fields)
          when AST::MatchStmt
            scrutinee_type = infer_expression_type(statement.expression, env:)
            statement.arms.each do |arm|
              arm_env = duplicate_env(env)
              bind_async_variant_match_arm_env!(arm_env, scrutinee_type, arm)
              await_counter = analyze_async_statements!(arm.body, await_counter, arm_env, param_fields, local_fields, await_fields)
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
        "__async_for_iterable_#{statement.object_id}_#{index}"
      end

      def async_collection_iterable_field_name(statement, index = 0)
        "for_iterable_#{statement.object_id}_#{index}"
      end

      def async_collection_index_field_key(statement)
        "__async_for_index_#{statement.object_id}"
      end

      def async_collection_index_field_name(statement)
        "for_index_#{statement.object_id}"
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
          "ready" => @types.fetch("bool"),
          "waiter_frame" => async_info[:void_ptr],
          "waiter" => async_info[:wake_type],
        }
        fields["state"] = @types.fetch("int") unless async_info[:await_fields].empty?
        unless async_info[:result_type] == @types.fetch("void")
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

      def build_async_constructor_function(binding, decl, frame_type, constructor_c_name, resume_c_name, ready_c_name, set_waiter_c_name, release_c_name, take_result_c_name, async_info)
        params = []
        body = []
        frame_pointer_type = pointer_to(frame_type)
        frame_expr = IR::Name.new(name: async_frame_local_name, type: frame_pointer_type, pointer: false)
        raw_frame_expr = IR::Cast.new(target_type: async_info[:void_ptr], expression: frame_expr, type: async_info[:void_ptr])

        body << IR::LocalDecl.new(
          name: async_frame_local_name,
          c_name: async_frame_local_name,
          type: frame_pointer_type,
          value: IR::Cast.new(
            target_type: frame_pointer_type,
            expression: IR::Call.new(
              callee: "mt_async_alloc",
              arguments: [IR::SizeofExpr.new(target_type: frame_type, type: @types.fetch("ptr_uint"))],
              type: async_info[:void_ptr],
            ),
            type: frame_pointer_type,
          ),
        )

        binding.body_params.each do |param_binding|
          field_info = async_info[:param_fields].fetch(param_binding.name)
          field_type = field_info[:type]
          param_type = field_info[:param_type]
          c_name = c_local_name(param_binding.name)
          input_c_name = array_type?(param_type) && !field_info[:pointer] ? "#{c_name}_input" : c_name
          params << IR::Param.new(name: param_binding.name, c_name: input_c_name, type: param_type, pointer: field_info[:pointer])
          frame_field_expr = async_frame_field_expression(frame_expr, field_info[:field_name], field_type)
          body << IR::Assignment.new(
            target: frame_field_expr,
            operator: "=",
            value: IR::Name.new(name: input_c_name, type: param_type, pointer: field_info[:pointer]),
          )
          # Retain proc-containing params: the frame outlives the constructor call stack,
          # so we must increment the env refcount so the caller releasing their copy is safe.
          if !field_info[:pointer] && contains_proc_storage_type?(param_type)
            body.concat(lower_proc_contained_retain_statements(frame_field_expr, param_type))
          end
        end

        body << IR::ExpressionStmt.new(
          expression: IR::Call.new(callee: resume_c_name, arguments: [raw_frame_expr], type: @types.fetch("void")),
        )
        body << IR::ReturnStmt.new(
          value: IR::AggregateLiteral.new(
            type: async_info[:task_type],
            fields: [
              IR::AggregateField.new(name: "frame", value: raw_frame_expr),
              IR::AggregateField.new(name: "ready", value: IR::Name.new(name: ready_c_name, type: async_info[:task_type].field("ready"), pointer: false)),
              IR::AggregateField.new(name: "set_waiter", value: IR::Name.new(name: set_waiter_c_name, type: async_info[:task_type].field("set_waiter"), pointer: false)),
              IR::AggregateField.new(name: "release", value: IR::Name.new(name: release_c_name, type: async_info[:task_type].field("release"), pointer: false)),
              IR::AggregateField.new(name: "take_result", value: IR::Name.new(name: take_result_c_name, type: async_info[:task_type].field("take_result"), pointer: false)),
            ],
          ),
        )

        IR::Function.new(
          name: decl.name,
          c_name: constructor_c_name,
          params:,
          return_type: async_info[:task_type],
          body:,
          entry_point: false,
          method_receiver_param: !binding.type.receiver_type.nil?,
        )
      end

      def build_async_resume_function(binding, statements, frame_type, resume_c_name, async_info)
        async_info = async_info.merge(resume_c_name:)
        frame_expr = IR::Name.new(name: async_frame_local_name, type: pointer_to(frame_type), pointer: false)
        raw_frame_expr = IR::Name.new(name: async_frame_raw_name, type: async_info[:void_ptr], pointer: false)
        body = [async_frame_cast_declaration(frame_type, async_info)]

        env = async_resume_env_for(async_info)
        if async_info[:await_fields].empty?
          body.concat(lower_async_non_await_statements(statements, env:, frame_expr:, raw_frame_expr:, async_info:, active_defers: []))
        else
          cases = (0..async_info[:await_fields].length).map do |state|
            IR::SwitchCase.new(
              value: IR::IntegerLiteral.new(value: state, type: @types.fetch("int")),
              body: [IR::GotoStmt.new(label: async_state_label(resume_c_name, state))],
            )
          end
          body << IR::SwitchStmt.new(expression: async_frame_field_expression(frame_expr, "state", @types.fetch("int")), cases:)
          body << IR::ReturnStmt.new(value: nil)
          body << IR::LabelStmt.new(name: async_state_label(resume_c_name, 0))
          body.concat(lower_async_cf_statements(statements, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers: []))
        end

        if async_info[:result_type] == @types.fetch("void") && !cfg_block_always_terminates?(statements)
          body.concat(async_complete_statements(frame_expr:, raw_frame_expr:, async_info:, value: nil, result_already_stored: true))
        end

        IR::Function.new(
          name: "#{binding.name}__resume",
          c_name: resume_c_name,
          params: [IR::Param.new(name: "frame", c_name: async_frame_raw_name, type: async_info[:void_ptr], pointer: false)],
          return_type: @types.fetch("void"),
          body:,
          entry_point: false,
        )
      end

      def build_async_ready_function(frame_type, ready_c_name, async_info)
        frame_expr = IR::Name.new(name: async_frame_local_name, type: pointer_to(frame_type), pointer: false)

        IR::Function.new(
          name: "#{ready_c_name}_fn",
          c_name: ready_c_name,
          params: [IR::Param.new(name: "frame", c_name: async_frame_raw_name, type: async_info[:void_ptr], pointer: false)],
          return_type: @types.fetch("bool"),
          body: [
            async_frame_cast_declaration(frame_type, async_info),
            IR::ReturnStmt.new(value: async_frame_field_expression(frame_expr, "ready", @types.fetch("bool"))),
          ],
          entry_point: false,
        )
      end

      def build_async_set_waiter_function(frame_type, set_waiter_c_name, async_info)
        frame_expr = IR::Name.new(name: async_frame_local_name, type: pointer_to(frame_type), pointer: false)
        waiter_frame_expr = IR::Name.new(name: "waiter_frame", type: async_info[:void_ptr], pointer: false)
        waiter_expr = IR::Name.new(name: "waiter", type: async_info[:wake_type], pointer: false)

        IR::Function.new(
          name: "#{set_waiter_c_name}_fn",
          c_name: set_waiter_c_name,
          params: [
            IR::Param.new(name: "frame", c_name: async_frame_raw_name, type: async_info[:void_ptr], pointer: false),
            IR::Param.new(name: "waiter_frame", c_name: "waiter_frame", type: async_info[:void_ptr], pointer: false),
            IR::Param.new(name: "waiter", c_name: "waiter", type: async_info[:wake_type], pointer: false),
          ],
          return_type: @types.fetch("void"),
          body: [
            async_frame_cast_declaration(frame_type, async_info),
            IR::IfStmt.new(
              condition: async_frame_field_expression(frame_expr, "ready", @types.fetch("bool")),
              then_body: [
                IR::ExpressionStmt.new(expression: IR::Call.new(callee: waiter_expr, arguments: [waiter_frame_expr], type: @types.fetch("void"))),
                IR::ReturnStmt.new(value: nil),
              ],
              else_body: nil,
            ),
            IR::Assignment.new(target: async_frame_field_expression(frame_expr, "waiter_frame", async_info[:void_ptr]), operator: "=", value: waiter_frame_expr),
            IR::Assignment.new(target: async_frame_field_expression(frame_expr, "waiter", async_info[:wake_type]), operator: "=", value: waiter_expr),
            IR::ReturnStmt.new(value: nil),
          ],
          entry_point: false,
        )
      end

      def build_async_release_function(frame_type, release_c_name, async_info)
        frame_expr = IR::Name.new(name: async_frame_local_name, type: pointer_to(frame_type), pointer: false)
        raw_frame_expr = IR::Name.new(name: async_frame_raw_name, type: async_info[:void_ptr], pointer: false)

        body = [
          async_frame_cast_declaration(frame_type, async_info),
          IR::IfStmt.new(
            condition: IR::Unary.new(operator: "not", operand: async_frame_field_expression(frame_expr, "ready", @types.fetch("bool")), type: @types.fetch("bool")),
            then_body: [IR::ReturnStmt.new(value: nil)],
            else_body: nil,
          ),
        ]

        # Release proc-containing params (always initialized by constructor, but null-guard is safe).
        async_info[:param_fields].each_value do |field_info|
          next if field_info[:pointer]
          next unless contains_proc_storage_type?(field_info[:type])

          field_expr = async_frame_field_expression(frame_expr, field_info[:field_name], field_info[:type])
          body.concat(lower_async_frame_proc_release_statements(field_expr, field_info[:type]))
        end

        # Release proc-containing locals (may not be initialized if function returned early via branch,
        # so always null-guard via invoke pointer check on each proc).
        async_info[:local_fields].each_value do |field_info|
          next unless contains_proc_storage_type?(field_info[:storage_type])

          field_expr = async_frame_field_expression(frame_expr, field_info[:field_name], field_info[:storage_type])
          body.concat(lower_async_frame_proc_release_statements(field_expr, field_info[:storage_type]))
        end

        body << IR::ExpressionStmt.new(expression: IR::Call.new(callee: "mt_async_free", arguments: [raw_frame_expr], type: @types.fetch("void")))
        body << IR::ReturnStmt.new(value: nil)

        IR::Function.new(
          name: "#{release_c_name}_fn",
          c_name: release_c_name,
          params: [IR::Param.new(name: "frame", c_name: async_frame_raw_name, type: async_info[:void_ptr], pointer: false)],
          return_type: @types.fetch("void"),
          body:,
          entry_point: false,
        )
      end

      def build_async_take_result_function(frame_type, take_result_c_name, async_info)
        frame_expr = IR::Name.new(name: async_frame_local_name, type: pointer_to(frame_type), pointer: false)
        body = [async_frame_cast_declaration(frame_type, async_info)]
        if async_info[:result_type] == @types.fetch("void")
          body << IR::ReturnStmt.new(value: nil)
        else
          body << IR::ReturnStmt.new(value: async_frame_field_expression(frame_expr, "result", async_info[:result_type]))
        end

        IR::Function.new(
          name: "#{take_result_c_name}_fn",
          c_name: take_result_c_name,
          params: [IR::Param.new(name: "frame", c_name: async_frame_raw_name, type: async_info[:void_ptr], pointer: false)],
          return_type: async_info[:result_type],
          body:,
          entry_point: false,
        )
      end

      def async_resume_env_for(async_info)
        env = empty_env
        async_info[:param_fields].each do |name, field_info|
          env[:scopes].last[name] = local_binding(
            type: field_info[:pointer] ? pointee_type(field_info[:type]) : field_info[:type],
            c_name: async_frame_field_c_name(field_info[:field_name]),
            mutable: field_info[:mutable],
            pointer: field_info[:pointer],
          )
        end
        env
      end

      def async_bind_local!(env, name, field_info)
        current_actual_scope(env[:scopes])[name] = local_binding(
          type: field_info[:type],
          storage_type: field_info[:storage_type],
          c_name: async_frame_field_c_name(field_info[:field_name]),
          mutable: field_info[:mutable],
          pointer: false,
        )
      end

      def async_frame_cast_declaration(frame_type, async_info)
        IR::LocalDecl.new(
          name: async_frame_local_name,
          c_name: async_frame_local_name,
          type: pointer_to(frame_type),
          value: IR::Cast.new(
            target_type: pointer_to(frame_type),
            expression: IR::Name.new(name: async_frame_raw_name, type: async_info[:void_ptr], pointer: false),
            type: pointer_to(frame_type),
          ),
        )
      end

      def async_frame_local_name
        "__mt_frame"
      end

      def async_frame_raw_name
        "__mt_frame_raw"
      end

      def async_frame_field_c_name(field_name)
        "#{async_frame_local_name}->#{field_name}"
      end

      def async_state_label(resume_c_name, state)
        "#{resume_c_name}_state_#{state}"
      end

      def async_frame_field_expression(frame_expr, field_name, field_type)
        IR::Member.new(receiver: frame_expr, member: field_name, type: field_type)
      end

      def async_task_frame_expression(task_expr, task_type)
        IR::Member.new(receiver: task_expr, member: "frame", type: task_type.field("frame"))
      end

      def async_task_call(task_expr, task_type, member, arguments, return_type)
        IR::Call.new(
          callee: IR::Member.new(receiver: task_expr, member:, type: task_type.field(member)),
          arguments:,
          type: return_type,
        )
      end

      def lower_async_local_decl_statement(statement, field_info:, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers: [], loop_flow: nil)
        lowered = []
        type = field_info[:type]
        storage_type = field_info[:storage_type]
        target = async_frame_field_expression(frame_expr, field_info[:field_name], storage_type)
        prepared_setup = []
        prepared_value = statement.value

        if statement.value
          prepared_setup, prepared_value = prepare_expression_for_inline_lowering(
            statement.value,
            env:,
            expected_type: storage_type,
            allow_root_statement_foreign: true,
          )
          lowered.concat(prepared_setup)
        end

        if prepared_value && (foreign_call = foreign_call_info(prepared_value, env))
          setup, value, call_type, release_assignments, cleanup_statements = lower_foreign_call_components(
            foreign_call,
            env:,
            expected_type: storage_type,
            statement_position: false,
          )
          lowered.concat(setup)
          raise LoweringError, "foreign call used to initialize #{statement.name} must return a value" if call_type == @types.fetch("void")
          raise LoweringError, "consuming foreign calls must return void" unless release_assignments.empty?

          lowered << IR::Assignment.new(target:, operator: "=", value:)
          lowered.concat(cleanup_statements)
        else
          value = if prepared_value
                    lower_contextual_expression(
                      prepared_value,
                      env:,
                      expected_type: storage_type,
                      contextual_int_to_float: statement.type && contextual_int_to_float_target?(type),
                    )
                  else
                    IR::ZeroInit.new(type: storage_type)
                  end
          lowered << IR::Assignment.new(target:, operator: "=", value:)
        end

        if statement.else_body
          else_env = duplicate_env(env)
          if statement.else_binding
            current_actual_scope(else_env[:scopes])[statement.else_binding.name] = local_binding(
              type: let_else_error_type(storage_type),
              storage_type:,
              c_name: async_frame_field_c_name(field_info[:field_name]),
              mutable: false,
              pointer: false,
              projection: :result_failure_error,
            )
          end
          else_body = if statements_contain_await?(statement.else_body, async_info)
            lower_async_cf_statements(
              statement.else_body,
              env: else_env,
              frame_expr:,
              raw_frame_expr:,
              resume_c_name:,
              async_info:,
              active_defers:,
              loop_flow:,
            )
          else
            lower_async_non_await_statements(
              statement.else_body,
              env: else_env,
              frame_expr:,
              raw_frame_expr:,
              async_info:,
              active_defers:,
              loop_flow:,
            )
          end
          lowered << IR::IfStmt.new(
            condition: let_else_failure_condition(target, storage_type),
            then_body: else_body,
            else_body: nil,
          )
        end

        lowered
      end

      def normalize_async_body(binding, statements)
        counter = { value: 0 }
        env = empty_env
        binding.body_params.each do |param_binding|
          env[:scopes].last[param_binding.name] = local_binding(
            type: param_binding.type,
            c_name: param_binding.name,
            mutable: param_binding.mutable,
            pointer: false,
          )
        end
        env[:return_context] = {
          return_type: binding.body_return_type,
          active_defers: [],
          local_defers: [],
          allow_return: true,
        }
        normalize_async_statements(statements, counter, env, return_type: binding.body_return_type)
      end

      def normalize_async_statements(statements, counter, env, return_type:)
        statements.flat_map { |statement| normalize_async_statement(statement, counter, env, return_type:) }
      end

      def normalize_async_statement(statement, counter, env, return_type:)
        case statement
        when AST::LocalDecl
          if statement.value
            local_type, storage_type = async_local_decl_types(statement, env:)
            expected_type = statement.else_body ? storage_type : (statement.type ? resolve_type_ref(statement.type) : nil)
            setup, value = if statement.value.is_a?(AST::AwaitExpr)
              [[], statement.value]
            else
              normalize_async_expression(statement.value, counter, env:, expected_type: expected_type)
            end
            else_body = if statement.else_body
              else_env = duplicate_env(env)
              normalize_async_statements(statement.else_body, counter, else_env, return_type:)
            end
            normalized = AST::LocalDecl.new(kind: statement.kind, name: statement.name, type: statement.type, value: value, else_binding: statement.else_binding, else_body:, line: statement.line)
            if bind_let_else_local?(statement)
              current_actual_scope(env[:scopes])[statement.name] = local_binding(
                type: local_type,
                storage_type:,
                c_name: statement.name,
                mutable: statement.kind == :var,
                pointer: false,
                projection: statement.else_body ? let_else_binding_projection(storage_type) : nil,
                const_value: statement.else_body ? nil : statement.kind == :let ? compile_time_const_value(statement.value, env:) : nil,
              )
            end
            return setup + [normalized]
          end

          local_type = resolve_type_ref(statement.type)
          current_actual_scope(env[:scopes])[statement.name] = local_binding(
            type: local_type,
            storage_type: local_type,
            c_name: statement.name,
            mutable: statement.kind == :var,
            pointer: false,
            const_value: nil,
          )
          [statement]
        when AST::Assignment
          target_setup, target = normalize_async_assignment_target(statement.target, counter, env:)
          return target_setup + [AST::Assignment.new(target:, operator: statement.operator, value: statement.value)] if statement.value.is_a?(AST::AwaitExpr)

          target_type = infer_expression_type(statement.target, env:)
          setup, value = normalize_async_expression(statement.value, counter, env:, expected_type: target_type)
          target_setup + setup + [AST::Assignment.new(target:, operator: statement.operator, value: value)]
        when AST::ExpressionStmt
          return [statement] if statement.expression.is_a?(AST::AwaitExpr)

          setup, expression = normalize_async_expression(statement.expression, counter, env:)
          setup + [AST::ExpressionStmt.new(expression: expression, line: statement.line)]
        when AST::ReturnStmt
          return [statement] unless statement.value
          return [statement] if statement.value.is_a?(AST::AwaitExpr)

          setup, value = normalize_async_expression(statement.value, counter, env:, expected_type: return_type)
          setup + [AST::ReturnStmt.new(value: value, line: statement.line)]
        when AST::IfStmt
          normalize_async_if_statement(statement, counter, env, return_type:)
        when AST::MatchStmt
          expr_setup, expression = normalize_async_expression(statement.expression, counter, env:)
          scrutinee_type = infer_expression_type(statement.expression, env:)
          arms = statement.arms.map do |arm|
            arm_env = duplicate_env(env)
            bind_async_variant_match_arm_env!(arm_env, scrutinee_type, arm)
            AST::MatchArm.new(pattern: arm.pattern, binding_name: arm.binding_name, body: normalize_async_statements(arm.body, counter, arm_env, return_type:))
          end
          expr_setup + [AST::MatchStmt.new(expression:, arms:)]
        when AST::WhileStmt
          condition_setup, condition = normalize_async_expression(statement.condition, counter, env:, expected_type: @types.fetch("bool"))
          body_env = duplicate_env(env)
          body = normalize_async_statements(statement.body, counter, body_env, return_type:)
          if condition_setup.empty?
            [AST::WhileStmt.new(condition:, body:)]
          else
            cond_name = fresh_async_temp_name(counter)
            condition_eval = condition_setup + [AST::LocalDecl.new(kind: :let, name: cond_name, type: ast_type_ref_for(@types.fetch("bool")), value: condition)]
            [
              AST::WhileStmt.new(
                condition: AST::BooleanLiteral.new(value: true),
                body: condition_eval + [
                  AST::IfStmt.new(
                    branches: [AST::IfBranch.new(condition: AST::UnaryOp.new(operator: "not", operand: AST::Identifier.new(name: cond_name)), body: [AST::BreakStmt.new])],
                    else_body: nil,
                  ),
                  *body,
                ],
              ),
            ]
          end
        when AST::ForStmt
          original_iterable = statement.iterable
          loop_type = if range_iterable?(original_iterable)
                        infer_range_loop_type(original_iterable, env:)
                      else
                        iterable_type = infer_expression_type(original_iterable, env:)
                        collection_loop_type(iterable_type)
                      end
          for_env = duplicate_env(env)
          if statement.parallel?
            iterable_setups = []
            normalized_iterables = statement.iterables.map do |iterable|
              setup, normalized_iterable = normalize_async_expression(iterable, counter, env:)
              iterable_setups.concat(setup)
              normalized_iterable
            end
            statement.bindings.each_with_index do |binding, index|
              iterable_type = infer_expression_type(statement.iterables[index], env:)
              element_type = collection_loop_type(iterable_type)
              binding_type = collection_loop_binding_type(iterable_type, element_type) || element_type
              current_actual_scope(for_env[:scopes])[binding.name] = local_binding(type: binding_type, c_name: binding.name, mutable: false, pointer: false)
            end
            body = normalize_async_statements(statement.body, counter, for_env, return_type:)
            return iterable_setups + [AST::ForStmt.new(bindings: statement.bindings, iterables: normalized_iterables, body:)]
          end

          iterable_setup, iterable = normalize_async_expression(statement.iterable, counter, env:)
          current_actual_scope(for_env[:scopes])[statement.name] = local_binding(type: loop_type, c_name: statement.name, mutable: false, pointer: false)
          body = normalize_async_statements(statement.body, counter, for_env, return_type:)
          iterable_setup + [AST::ForStmt.new(bindings: statement.bindings, iterables: [iterable], body:)]
        when AST::UnsafeStmt
          unsafe_env = duplicate_env(env)
          [AST::UnsafeStmt.new(body: normalize_async_statements(statement.body, counter, unsafe_env, return_type:))]
        when AST::DeferStmt
          cleanup_env = duplicate_env(env)
          cleanup_env[:return_context] = cleanup_env[:return_context]&.merge(allow_return: false)
          cleanup_body = if statement.body
                           normalize_async_statements(statement.body, counter, cleanup_env, return_type:)
                         else
                           expression_setup, expression = normalize_async_expression(statement.expression, counter, env: cleanup_env)
                           expression_setup + [AST::ExpressionStmt.new(expression:, line: statement.line)]
                         end
          [AST::DeferStmt.new(expression: nil, body: cleanup_body, line: statement.line, column: statement.column, length: statement.length)]
        when AST::BreakStmt, AST::ContinueStmt, AST::StaticAssert, AST::PassStmt
          [statement]
        else
          raise LoweringError, "unsupported async statement #{statement.class.name}"
        end
      end

      def normalize_async_if_statement(statement, counter, env, return_type:)
        else_body = if statement.else_body
                      else_env = duplicate_env(env)
                      normalize_async_statements(statement.else_body, counter, else_env, return_type:)
                    end
        normalize_async_if_branches(statement.branches, else_body, counter, env, return_type:)
      end

      def normalize_async_if_branches(branches, else_body, counter, env, return_type:)
        return else_body || [] if branches.empty?

        branch = branches.first
        condition_setup, condition = normalize_async_expression(branch.condition, counter, env:, expected_type: @types.fetch("bool"))
        then_env = duplicate_env(env)
        then_body = normalize_async_statements(branch.body, counter, then_env, return_type:)
        chained_else = normalize_async_if_branches(branches.drop(1), else_body, counter, env, return_type:)
        condition_setup + [AST::IfStmt.new(branches: [AST::IfBranch.new(condition:, body: then_body)], else_body: chained_else)]
      end

      def normalize_async_assignment_target(target, counter, env:)
        case target
        when AST::Identifier
          [[], target]
        when AST::MemberAccess
          receiver_setup, receiver = normalize_async_expression(target.receiver, counter, env:)
          [receiver_setup, AST::MemberAccess.new(receiver:, member: target.member)]
        when AST::IndexAccess
          receiver_setup, receiver = normalize_async_expression(target.receiver, counter, env:)
          index_setup, index = normalize_async_expression(target.index, counter, env:)
          [receiver_setup + index_setup, AST::IndexAccess.new(receiver:, index:)]
        else
          raise LoweringError, "unsupported assignment target #{target.class.name}"
        end
      end

      def normalize_async_expression(expression, counter, env:, expected_type: nil)
        case expression
        when AST::AwaitExpr
          temp_name = fresh_async_temp_name(counter)
          [
            [AST::LocalDecl.new(kind: :let, name: temp_name, type: nil, value: expression)],
            AST::Identifier.new(name: temp_name),
          ]
        when AST::Call
          setup = []
          callee_setup, callee = normalize_async_expression(expression.callee, counter, env:)
          setup.concat(callee_setup)
          arguments = expression.arguments.map do |argument|
            argument_setup, value = normalize_async_expression(argument.value, counter, env:)
            setup.concat(argument_setup)
            AST::Argument.new(name: argument.name, value: value)
          end
          [setup, AST::Call.new(callee: callee, arguments: arguments)]
        when AST::Specialization
          setup = []
          callee_setup, callee = normalize_async_expression(expression.callee, counter, env:)
          setup.concat(callee_setup)
          arguments = expression.arguments.map do |argument|
            argument_setup, value = normalize_async_expression(argument.value, counter, env:)
            setup.concat(argument_setup)
            AST::TypeArgument.new(value: value)
          end
          [setup, AST::Specialization.new(callee: callee, arguments: arguments)]
        when AST::UnaryOp
          setup, operand = normalize_async_expression(expression.operand, counter, env:, expected_type: expected_type)
          [setup, AST::UnaryOp.new(operator: expression.operator, operand: operand)]
        when AST::BinaryOp
          if %w[and or].include?(expression.operator)
            left_setup, left = normalize_async_expression(expression.left, counter, env:, expected_type: @types.fetch("bool"))
            right_setup, right = normalize_async_expression(expression.right, counter, env:, expected_type: @types.fetch("bool"))
            temp_name = fresh_async_temp_name(counter)

            temp_init = expression.operator == "and" ? AST::BooleanLiteral.new(value: false) : AST::BooleanLiteral.new(value: true)
            short_circuit_value = expression.operator == "and" ? AST::BooleanLiteral.new(value: false) : AST::BooleanLiteral.new(value: true)

            branch_body = right_setup + [AST::Assignment.new(target: AST::Identifier.new(name: temp_name), operator: "=", value: right)]
            else_body = [AST::Assignment.new(target: AST::Identifier.new(name: temp_name), operator: "=", value: short_circuit_value)]

            if expression.operator == "or"
              branch_body, else_body = else_body, branch_body
            end

            setup = [AST::LocalDecl.new(kind: :var, name: temp_name, type: nil, value: temp_init)]
            setup.concat(left_setup)
            setup << AST::IfStmt.new(branches: [AST::IfBranch.new(condition: left, body: branch_body)], else_body: else_body)
            return [setup, AST::Identifier.new(name: temp_name)]
          end

          left_setup, left = normalize_async_expression(expression.left, counter, env:)
          right_setup, right = normalize_async_expression(expression.right, counter, env:)
          [left_setup + right_setup, AST::BinaryOp.new(operator: expression.operator, left: left, right: right)]
        when AST::IfExpr
          condition_setup, condition = normalize_async_expression(expression.condition, counter, env:, expected_type: @types.fetch("bool"))
          result_type = infer_expression_type(expression, env:, expected_type:)
          then_setup, then_expression = normalize_async_expression(expression.then_expression, counter, env:, expected_type: result_type)
          else_setup, else_expression = normalize_async_expression(expression.else_expression, counter, env:, expected_type: result_type)

          return [[], AST::IfExpr.new(condition:, then_expression:, else_expression:)] if condition_setup.empty? && then_setup.empty? && else_setup.empty?

          temp_name = fresh_async_temp_name(counter)
          setup = condition_setup + [
            AST::LocalDecl.new(kind: :var, name: temp_name, type: ast_type_ref_for(result_type), value: nil),
            AST::IfStmt.new(
              branches: [AST::IfBranch.new(condition:, body: then_setup + [AST::Assignment.new(target: AST::Identifier.new(name: temp_name), operator: "=", value: then_expression)])],
              else_body: else_setup + [AST::Assignment.new(target: AST::Identifier.new(name: temp_name), operator: "=", value: else_expression)],
            ),
          ]
          [setup, AST::Identifier.new(name: temp_name)]
        when AST::MatchExpr
          expression_setup, normalized_expression = normalize_async_expression(expression.expression, counter, env:)
          result_type = infer_expression_type(expression, env:, expected_type:)
          scrutinee_type = infer_expression_type(expression.expression, env:)
          normalized_arms = expression.arms.map do |arm|
            arm_env = duplicate_env(env)
            bind_async_variant_match_arm_env!(arm_env, scrutinee_type, arm)
            pattern_setup, normalized_pattern = normalize_async_expression(arm.pattern, counter, env:)
            value_setup, normalized_value = normalize_async_expression(arm.value, counter, env: arm_env, expected_type: result_type)
            [pattern_setup, value_setup, AST::MatchExprArm.new(
              pattern: normalized_pattern,
              binding_name: arm.binding_name,
              binding_line: arm.binding_line,
              binding_column: arm.binding_column,
              value: normalized_value,
            )]
          end

          if expression_setup.empty? && normalized_arms.all? { |pattern_setup, value_setup, _arm| pattern_setup.empty? && value_setup.empty? }
            return [[], AST::MatchExpr.new(expression: normalized_expression, arms: normalized_arms.map(&:last), line: expression.line, column: expression.column, length: expression.length)]
          end

          temp_name = fresh_async_temp_name(counter)
          setup = expression_setup + [
            AST::LocalDecl.new(kind: :var, name: temp_name, type: ast_type_ref_for(result_type), value: nil),
            AST::MatchStmt.new(
              expression: normalized_expression,
              arms: normalized_arms.map do |pattern_setup, value_setup, arm|
                AST::MatchArm.new(
                  pattern: arm.pattern,
                  binding_name: arm.binding_name,
                  binding_line: arm.binding_line,
                  binding_column: arm.binding_column,
                  body: pattern_setup + value_setup + [AST::Assignment.new(target: AST::Identifier.new(name: temp_name), operator: "=", value: arm.value)],
                )
              end,
              line: expression.line,
              column: expression.column,
              length: expression.length,
            ),
          ]
          [setup, AST::Identifier.new(name: temp_name)]
        when AST::UnsafeExpr
          normalize_async_expression(expression.expression, counter, env:, expected_type:)
        when AST::MemberAccess
          setup, receiver = normalize_async_expression(expression.receiver, counter, env:)
          [setup, AST::MemberAccess.new(receiver: receiver, member: expression.member)]
        when AST::IndexAccess
          receiver_setup, receiver = normalize_async_expression(expression.receiver, counter, env:)
          index_setup, index = normalize_async_expression(expression.index, counter, env:)
          [receiver_setup + index_setup, AST::IndexAccess.new(receiver: receiver, index: index)]
        when AST::RangeExpr
          start_setup, start_expr = normalize_async_expression(expression.start_expr, counter, env:)
          end_setup, end_expr = normalize_async_expression(expression.end_expr, counter, env:)
          [start_setup + end_setup, AST::RangeExpr.new(start_expr:, end_expr:, line: expression.line, column: expression.column)]
        when AST::FormatString
          setup = []
          parts = expression.parts.map do |part|
            if part.is_a?(AST::FormatExprPart)
              expression_setup, inner_expression = normalize_async_expression(part.expression, counter, env:)
              setup.concat(expression_setup)
              AST::FormatExprPart.new(expression: inner_expression, format_spec: part.format_spec)
            else
              part
            end
          end
          [setup, AST::FormatString.new(parts: parts)]
        else
          [[], expression]
        end
      end

      def ast_type_ref_for(type)
        case type
        when Types::Primitive
          AST::TypeRef.new(name: AST::QualifiedName.new(parts: [type.name]), arguments: [], nullable: false)
        when Types::Nullable
          inner = ast_type_ref_for(type.base)
          raise LoweringError, "nullable annotation is only valid for named/generic types" unless inner.is_a?(AST::TypeRef)

          AST::TypeRef.new(name: inner.name, arguments: inner.arguments, nullable: true)
        when Types::GenericInstance
          AST::TypeRef.new(
            name: AST::QualifiedName.new(parts: type.name.split(".")),
            arguments: type.arguments.map do |argument|
              if argument.is_a?(Types::LiteralTypeArg)
                AST::TypeArgument.new(value: AST::IntegerLiteral.new(lexeme: argument.value.to_s, value: argument.value))
              else
                AST::TypeArgument.new(value: ast_type_ref_for(argument))
              end
            end,
            nullable: false,
          )
        when Types::Span
          AST::TypeRef.new(name: AST::QualifiedName.new(parts: ["span"]), arguments: [AST::TypeArgument.new(value: ast_type_ref_for(type.element_type))], nullable: false)
        when Types::Task
          AST::TypeRef.new(name: AST::QualifiedName.new(parts: ["Task"]), arguments: [AST::TypeArgument.new(value: ast_type_ref_for(type.result_type))], nullable: false)
        when Types::TypeVar
          AST::TypeRef.new(name: AST::QualifiedName.new(parts: [type.name]), arguments: [], nullable: false)
        when Types::StructInstance
          base_parts = type.module_name ? type.module_name.split(".") + [type.name] : [type.name]
          AST::TypeRef.new(
            name: AST::QualifiedName.new(parts: base_parts),
            arguments: type.arguments.map do |argument|
              if argument.is_a?(Types::LiteralTypeArg)
                AST::TypeArgument.new(value: AST::IntegerLiteral.new(lexeme: argument.value.to_s, value: argument.value))
              else
                AST::TypeArgument.new(value: ast_type_ref_for(argument))
              end
            end,
            nullable: false,
          )
        when Types::Struct, Types::Union, Types::Opaque, Types::Enum, Types::Flags
          parts = type.module_name ? type.module_name.split(".") + [type.name] : [type.name]
          AST::TypeRef.new(name: AST::QualifiedName.new(parts: parts), arguments: [], nullable: false)
        when Types::Function
          AST::FunctionType.new(
            params: type.params.each_with_index.map { |param, i| AST::Param.new(name: param.name || "p#{i}", type: ast_type_ref_for(param.type)) },
            return_type: ast_type_ref_for(type.return_type),
          )
        when Types::Proc
          AST::ProcType.new(
            params: type.params.each_with_index.map { |param, i| AST::Param.new(name: param.name || "p#{i}", type: ast_type_ref_for(param.type)) },
            return_type: ast_type_ref_for(type.return_type),
          )
        else
          raise LoweringError, "unsupported type for AST normalization #{type.class.name}"
        end
      end

      def async_expression_contains_await?(expression)
        case expression
        when AST::AwaitExpr
          true
        when AST::Call, AST::Specialization
          async_expression_contains_await?(expression.callee) || expression.arguments.any? { |argument| async_expression_contains_await?(argument.value) }
        when AST::UnaryOp
          async_expression_contains_await?(expression.operand)
        when AST::BinaryOp
          async_expression_contains_await?(expression.left) || async_expression_contains_await?(expression.right)
        when AST::IfExpr
          async_expression_contains_await?(expression.condition) || async_expression_contains_await?(expression.then_expression) || async_expression_contains_await?(expression.else_expression)
        when AST::MatchExpr
          async_expression_contains_await?(expression.expression) || expression.arms.any? { |arm| async_expression_contains_await?(arm.pattern) || async_expression_contains_await?(arm.value) }
        when AST::UnsafeExpr
          async_expression_contains_await?(expression.expression)
        when AST::MemberAccess
          async_expression_contains_await?(expression.receiver)
        when AST::IndexAccess
          async_expression_contains_await?(expression.receiver) || async_expression_contains_await?(expression.index)
        when AST::FormatString
          expression.parts.any? { |part| part.is_a?(AST::FormatExprPart) && async_expression_contains_await?(part.expression) }
        else
          false
        end
      end

      def fresh_async_temp_name(counter)
        counter[:value] += 1
        "__mt_async_tmp_#{counter[:value]}"
      end

      # Lowers a list of statements that contain no `await` anywhere, but live
      # inside an async resume function. Return statements are lowered as async
      # completions. All other control flow is lowered recursively.
      def statements_contain_await?(statements, async_info)
        statements.any? do |s|
          case s
          when AST::LocalDecl
            async_info[:await_fields].key?(s.value&.object_id) || async_expression_contains_await?(s.value) || (s.else_body && statements_contain_await?(s.else_body, async_info))
          when AST::Assignment
            async_info[:await_fields].key?(s.value&.object_id) || async_expression_contains_await?(s.target) || async_expression_contains_await?(s.value)
          when AST::ExpressionStmt
            async_info[:await_fields].key?(s.expression&.object_id) || async_expression_contains_await?(s.expression)
          when AST::ReturnStmt
            async_info[:await_fields].key?(s.value&.object_id) || async_expression_contains_await?(s.value)
          when AST::IfStmt
            s.branches.any? { |b| statements_contain_await?(b.body, async_info) } ||
              (s.else_body && statements_contain_await?(s.else_body, async_info))
          when AST::WhileStmt
            statements_contain_await?(s.body, async_info)
          when AST::ForStmt
            statements_contain_await?(s.body, async_info)
          when AST::MatchStmt
            s.arms.any? { |arm| statements_contain_await?(arm.body, async_info) }
          when AST::UnsafeStmt
            statements_contain_await?(s.body, async_info)
          when AST::DeferStmt
            (s.body && statements_contain_await?(s.body, async_info)) || (s.expression && async_expression_contains_await?(s.expression))
          else
            false
          end
        end
      end

      # Lower a list of statements that MAY contain await expressions inside nested control flow.
      # CPS-via-goto: labels placed inside if/while/match bodies, reachable from top-level switch dispatch.
      def lower_async_cf_statements(statements, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers: [], loop_flow: nil)
        lowered = []
        local_defers = []
        env[:return_context] = async_return_context(
          return_type: async_info[:result_type],
          active_defers:,
          local_defers:,
          frame_expr:,
          raw_frame_expr:,
          async_info:,
        )

        statements.each do |statement|
          case statement
          when AST::LocalDecl
            field_info = async_info[:local_fields].fetch(async_local_decl_field_key(statement))
            await_info = async_info[:await_fields][statement.value&.object_id]
            if await_info
              lowered.concat(lower_async_await_statement(statement, field_info:, await_info:, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers: active_defers + local_defers, loop_flow: nested_loop_flow(loop_flow, local_defers)))
            else
              lowered.concat(lower_async_local_decl_statement(statement, field_info:, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers: active_defers + local_defers, loop_flow: nested_loop_flow(loop_flow, local_defers)))
            end
            async_bind_local!(env, statement.name, field_info) if bind_let_else_local?(statement)
          when AST::Assignment
            await_info = async_info[:await_fields][statement.value&.object_id]
            if await_info
              lowered.concat(lower_async_await_statement(statement, await_info:, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:))
            else
              lowered.concat(lower_async_assignment_statement(statement, env:))
            end
          when AST::ExpressionStmt
            await_info = async_info[:await_fields][statement.expression&.object_id]
            if await_info
              lowered.concat(lower_async_await_statement(statement, await_info:, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:))
            else
              lowered.concat(lower_async_expression_statement(statement, env:))
            end
          when AST::ReturnStmt
            cleanup = lower_async_cleanup_entries(local_defers, active_defers, frame_expr:, raw_frame_expr:, async_info:)
            await_info = async_info[:await_fields][statement.value&.object_id]
            if await_info
              lowered.concat(lower_async_await_statement(statement, await_info:, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, cleanup:))
            else
              lowered.concat(lower_async_return_statement(statement, env:, frame_expr:, raw_frame_expr:, async_info:, cleanup:))
            end
          when AST::IfStmt
            lowered.concat(lower_async_cf_if_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers: active_defers + local_defers, loop_flow: nested_loop_flow(loop_flow, local_defers)))
          when AST::WhileStmt
            lowered.concat(lower_async_cf_while_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers: active_defers + local_defers, loop_flow: nested_loop_flow(loop_flow, local_defers)))
          when AST::ForStmt
            lowered.concat(lower_async_cf_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers: active_defers + local_defers))
          when AST::MatchStmt
            lowered.concat(lower_async_cf_match_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers: active_defers + local_defers, loop_flow: nested_loop_flow(loop_flow, local_defers)))
          when AST::UnsafeStmt
            lowered.concat(lower_async_cf_statements(statement.body, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers: active_defers + local_defers, loop_flow: nested_loop_flow(loop_flow, local_defers)))
          when AST::DeferStmt
            local_defers << lower_async_defer_cleanup(statement, env:, async_info:)
          when AST::PassStmt
            nil
          when AST::BreakStmt
            if loop_flow
              lowered.concat(lower_async_loop_exit(loop_flow[:break_target], local_defers, loop_flow[:break_defers], frame_expr:, raw_frame_expr:, async_info:))
            else
              lowered << IR::BreakStmt.new
            end
          when AST::ContinueStmt
            if loop_flow
              lowered.concat(lower_async_loop_exit(loop_flow[:continue_target], local_defers, loop_flow[:continue_defers], frame_expr:, raw_frame_expr:, async_info:))
            else
              lowered << IR::ContinueStmt.new
            end
          when AST::StaticAssert
            lowered.concat(lower_static_assert(statement))
          else
            raise LoweringError, "unsupported async cf statement #{statement.class.name}"
          end
        end

        unless cfg_block_always_terminates?(statements)
          lowered.concat(lower_async_cleanup_entries(local_defers, [], frame_expr:, raw_frame_expr:, async_info:))
        end
        lowered
      end

      def lower_async_cf_if_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:, loop_flow:)
        branch_entries = statement.branches.map do |branch|
          condition_setup, prepared_cond = prepare_expression_for_inline_lowering(branch.condition, env:)
          condition = lower_contextual_expression(prepared_cond, env:, expected_type: @types.fetch("bool"))
          body = if statements_contain_await?(branch.body, async_info)
            lower_async_cf_statements(branch.body, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:, loop_flow:)
          else
            lower_async_non_await_statements(branch.body, env:, frame_expr:, raw_frame_expr:, async_info:, active_defers:, loop_flow:)
          end
          { condition_setup:, condition:, body: }
        end

        else_body = if statement.else_body
          if statements_contain_await?(statement.else_body, async_info)
            lower_async_cf_statements(statement.else_body, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:, loop_flow:)
          else
            lower_async_non_await_statements(statement.else_body, env:, frame_expr:, raw_frame_expr:, async_info:, active_defers:, loop_flow:)
          end
        end

        nested_else = else_body
        branch_entries.reverse_each do |entry|
          nested_else = [
            *entry[:condition_setup],
            IR::IfStmt.new(condition: entry[:condition], then_body: entry[:body], else_body: nested_else),
          ]
        end
        nested_else || []
      end

      def lower_async_cf_while_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:, loop_flow:)
        continue_label = fresh_c_temp_name(env, "loop_continue")
        break_label = fresh_c_temp_name(env, "loop_break")
        condition_setup, prepared_cond = prepare_expression_for_inline_lowering(statement.condition, env:)
        condition = lower_contextual_expression(prepared_cond, env:, expected_type: @types.fetch("bool"))
        inner_loop_flow = loop_flow(break_target: loop_exit_break(break_label), continue_target: loop_exit_continue(continue_label))
        body = if statements_contain_await?(statement.body, async_info)
          lower_async_cf_statements(statement.body, env: duplicate_env(env), frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:, loop_flow: inner_loop_flow)
        else
          lower_async_non_await_statements(statement.body, env: duplicate_env(env), frame_expr:, raw_frame_expr:, async_info:, active_defers:, loop_flow: inner_loop_flow)
        end
        body << IR::LabelStmt.new(name: continue_label) if contains_label_target?(body, continue_label)

        if condition_setup.empty?
          stmts = [IR::WhileStmt.new(condition:, body:)]
          stmts << IR::LabelStmt.new(name: break_label) if contains_label_target?(body, break_label)
          return stmts
        end

        loop_body = [
          *condition_setup,
          IR::IfStmt.new(
            condition: IR::Unary.new(operator: "not", operand: condition, type: @types.fetch("bool")),
            then_body: [loop_exit_statement(loop_exit_break(break_label), local_defers: [], outer_defers: [])],
            else_body: nil,
          ),
          *body,
        ]
        stmts = [IR::WhileStmt.new(condition: IR::BooleanLiteral.new(value: true, type: @types.fetch("bool")), body: loop_body)]
        stmts << IR::LabelStmt.new(name: break_label) if contains_label_target?(loop_body, break_label)
        stmts
      end

      def lower_async_cf_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:)
        return lower_async_cf_parallel_collection_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:) if statement.parallel?

        if range_iterable?(statement.iterable)
          lower_async_cf_range_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:)
        else
          lower_async_cf_collection_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:)
        end
      end

      def lower_range_call(iterable, env:)
        loop_type = infer_range_loop_type(iterable, env:)
        start_expr_ast = range_start_of(iterable)
        stop_expr_ast = range_end_of(iterable)
        start_ir = lower_expression(start_expr_ast, env:, expected_type: loop_type)
        stop_ir = lower_expression(stop_expr_ast, env:, expected_type: loop_type)
        [start_ir, stop_ir, false]
      end

      def lower_async_cf_range_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:)
        loop_var_name = statement.name
        loop_var_type = infer_range_loop_type(statement.iterable, env:)
        loop_var_field = async_info[:local_fields].fetch(loop_var_name)
        loop_var_expr = async_frame_field_expression(frame_expr, loop_var_field[:field_name], loop_var_type)
        continue_label = fresh_c_temp_name(env, "loop_continue")
        break_label = fresh_c_temp_name(env, "loop_break")

        start_expr, stop_expr, inclusive = lower_range_call(statement.iterable, env:)

        # Store stop value in frame too so it survives suspension
        stop_field_name = "#{loop_var_field[:field_name]}_stop"
        async_info[:local_fields][stop_field_name] ||= { field_name: stop_field_name, type: loop_var_type, mutable: true }
        stop_field_expr = async_frame_field_expression(frame_expr, stop_field_name, loop_var_type)

        inner_env = duplicate_env(env)
        inner_env[:scopes].last[loop_var_name] = local_binding(
          type: loop_var_type,
          c_name: async_frame_field_c_name(loop_var_field[:field_name]),
          mutable: true, pointer: false
        )
        inner_loop_flow = loop_flow(break_target: loop_exit_break(break_label), continue_target: loop_exit_continue(continue_label))

        body = if statements_contain_await?(statement.body, async_info)
          lower_async_cf_statements(statement.body, env: inner_env, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:, loop_flow: inner_loop_flow)
        else
          lower_async_non_await_statements(statement.body, env: inner_env, frame_expr:, raw_frame_expr:, async_info:, active_defers:, loop_flow: inner_loop_flow)
        end
        body << IR::LabelStmt.new(name: continue_label) if contains_label_target?(body, continue_label)

        cmp_op = inclusive ? "<=" : "<"
        stmts = [
          IR::Assignment.new(target: loop_var_expr, operator: "=", value: start_expr),
          IR::Assignment.new(target: stop_field_expr, operator: "=", value: stop_expr),
          IR::WhileStmt.new(
            condition: IR::Binary.new(operator: cmp_op, left: loop_var_expr, right: stop_field_expr, type: @types.fetch("bool")),
            body: body + [IR::Assignment.new(target: loop_var_expr, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: loop_var_type))],
          ),
        ]
        stmts << IR::LabelStmt.new(name: break_label) if contains_label_target?(body, break_label)
        stmts
      end

      def lower_async_cf_collection_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:)
        iterable_type = infer_expression_type(statement.iterable, env:)
        element_type = collection_loop_type(iterable_type)
        raise LoweringError, "for loop expects start..stop, array[T, N], or span[T], got #{iterable_type}" unless element_type

        iterable_setup, prepared_iterable = prepare_expression_for_inline_lowering(statement.iterable, env:, expected_type: iterable_type)
        continue_label = fresh_c_temp_name(env, "loop_continue")
        break_label = fresh_c_temp_name(env, "loop_break")
        iterable_field = async_info[:local_fields].fetch(async_collection_iterable_field_key(statement))
        index_field = async_info[:local_fields].fetch(async_collection_index_field_key(statement))
        iterable_ref = async_frame_field_expression(frame_expr, iterable_field[:field_name], iterable_type)
        index_ref = async_frame_field_expression(frame_expr, index_field[:field_name], @types.fetch("ptr_uint"))

        # Loop variable stored in frame so it survives suspension
        loop_var_field = async_info[:local_fields].fetch(statement.name)
        loop_var_expr = async_frame_field_expression(frame_expr, loop_var_field[:field_name], element_type)

        item_value = if array_type?(iterable_type)
                       IR::Index.new(receiver: iterable_ref, index: index_ref, type: element_type)
                     else
                       data_ref = IR::Member.new(receiver: iterable_ref, member: "data", type: pointer_to(element_type))
                       IR::Index.new(receiver: data_ref, index: index_ref, type: element_type)
                     end
        stop_value = if array_type?(iterable_type)
                       IR::IntegerLiteral.new(value: array_length(iterable_type), type: @types.fetch("ptr_uint"))
                     else
                       IR::Member.new(receiver: iterable_ref, member: "len", type: @types.fetch("ptr_uint"))
                     end

        inner_env = duplicate_env(env)
        inner_env[:scopes].last[statement.name] = local_binding(
          type: element_type, c_name: async_frame_field_c_name(loop_var_field[:field_name]), mutable: true, pointer: false
        )
        inner_loop_flow = loop_flow(break_target: loop_exit_break(break_label), continue_target: loop_exit_continue(continue_label))

        assign_item = IR::Assignment.new(target: loop_var_expr, operator: "=", value: item_value)
        body_stmts = if statements_contain_await?(statement.body, async_info)
          lower_async_cf_statements(statement.body, env: inner_env, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:, loop_flow: inner_loop_flow)
        else
          lower_async_non_await_statements(statement.body, env: inner_env, frame_expr:, raw_frame_expr:, async_info:, active_defers:, loop_flow: inner_loop_flow)
        end
        body_stmts << IR::LabelStmt.new(name: continue_label) if contains_label_target?(body_stmts, continue_label)

        stmts = [
          *iterable_setup,
          IR::Assignment.new(target: iterable_ref, operator: "=", value: lower_expression(prepared_iterable, env:, expected_type: iterable_type)),
          IR::Assignment.new(target: index_ref, operator: "=", value: IR::IntegerLiteral.new(value: 0, type: @types.fetch("ptr_uint"))),
          IR::WhileStmt.new(
            condition: IR::Binary.new(operator: "<", left: index_ref, right: stop_value, type: @types.fetch("bool")),
            body: [assign_item] + body_stmts + [
              IR::Assignment.new(target: index_ref, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: @types.fetch("ptr_uint"))),
            ],
          ),
        ]
        stmts << IR::LabelStmt.new(name: break_label) if contains_label_target?(body_stmts, break_label)
        stmts
      end

      def lower_async_cf_parallel_collection_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:)
        infos = statement.bindings.each_with_index.map do |binding, index|
          iterable = statement.iterables[index]
          iterable_type = infer_expression_type(iterable, env:)
          element_type = collection_loop_type(iterable_type)
          raise LoweringError, "parallel for loops expect arrays or spans for each iterable, got #{iterable_type}" unless element_type

          {
            binding:,
            iterable:,
            iterable_type:,
            element_type:,
            binding_type: collection_loop_binding_type(iterable_type, element_type) || element_type,
            iterable_field: async_info[:local_fields].fetch(async_collection_iterable_field_key(statement, index)),
          }
        end

        iterable_entries = infos.map do |info|
          setup, prepared_iterable = prepare_expression_for_inline_lowering(info[:iterable], env:, expected_type: info[:iterable_type])
          info.merge(setup:, prepared_iterable:)
        end

        continue_label = fresh_c_temp_name(env, "loop_continue")
        break_label = fresh_c_temp_name(env, "loop_break")
        index_field = async_info[:local_fields].fetch(async_collection_index_field_key(statement))
        index_ref = async_frame_field_expression(frame_expr, index_field[:field_name], @types.fetch("ptr_uint"))
        iterable_refs = iterable_entries.map do |entry|
          async_frame_field_expression(frame_expr, entry[:iterable_field][:field_name], entry[:iterable_type])
        end
        stop_value = collection_loop_stop_value(iterable_refs.first, iterable_entries.first[:iterable_type])

        inner_env = duplicate_env(env)
        assign_items = iterable_entries.map.with_index do |entry, index|
          item_value = collection_loop_item_value(iterable_refs[index], entry[:iterable_type], index_ref, entry[:element_type])
          loop_item_value = if ref_type?(entry[:binding_type])
                              IR::AddressOf.new(expression: item_value, type: entry[:binding_type])
                            else
                              item_value
                            end
          binding_field = async_info[:local_fields].fetch(entry[:binding].name)
          binding_target = async_frame_field_expression(frame_expr, binding_field[:field_name], entry[:binding_type])
          inner_env[:scopes].last[entry[:binding].name] = local_binding(
            type: entry[:binding_type],
            c_name: async_frame_field_c_name(binding_field[:field_name]),
            mutable: true,
            pointer: false,
          )
          IR::Assignment.new(target: binding_target, operator: "=", value: loop_item_value)
        end
        inner_loop_flow = loop_flow(break_target: loop_exit_break(break_label), continue_target: loop_exit_continue(continue_label))
        body_stmts = if statements_contain_await?(statement.body, async_info)
          lower_async_cf_statements(statement.body, env: inner_env, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:, loop_flow: inner_loop_flow)
        else
          lower_async_non_await_statements(statement.body, env: inner_env, frame_expr:, raw_frame_expr:, async_info:, active_defers:, loop_flow: inner_loop_flow)
        end
        body_stmts << IR::LabelStmt.new(name: continue_label) if contains_label_target?(body_stmts, continue_label)

        length_checks = iterable_entries.drop(1).each_with_index.map do |entry, offset|
          IR::IfStmt.new(
            condition: IR::Binary.new(
              operator: "!=",
              left: collection_loop_stop_value(iterable_refs[offset + 1], entry[:iterable_type]),
              right: stop_value,
              type: @types.fetch("bool"),
            ),
            then_body: [lower_fatal_statement("parallel for iterables must have matching lengths", env:)],
            else_body: nil,
          )
        end

        stmts = [
          *iterable_entries.flat_map { |entry| entry[:setup] },
          *iterable_entries.each_with_index.map do |entry, index|
            IR::Assignment.new(
              target: iterable_refs[index],
              operator: "=",
              value: lower_expression(entry[:prepared_iterable], env:, expected_type: entry[:iterable_type]),
            )
          end,
          *length_checks,
          IR::Assignment.new(target: index_ref, operator: "=", value: IR::IntegerLiteral.new(value: 0, type: @types.fetch("ptr_uint"))),
          IR::WhileStmt.new(
            condition: IR::Binary.new(operator: "<", left: index_ref, right: stop_value, type: @types.fetch("bool")),
            body: assign_items + body_stmts + [
              IR::Assignment.new(target: index_ref, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: @types.fetch("ptr_uint"))),
            ],
          ),
        ]
        stmts << IR::LabelStmt.new(name: break_label) if contains_label_target?(body_stmts, break_label)
        stmts
      end

      def lower_async_cf_match_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:, loop_flow:)
        expr_setup, prepared_expr = prepare_expression_for_inline_lowering(statement.expression, env:)
        match_expr = lower_contextual_expression(prepared_expr, env:, expected_type: nil)
        match_type = infer_expression_type(statement.expression, env:)
        arm_loop_flow = switch_loop_flow(loop_flow, [])

        if match_type.is_a?(Types::Variant)
          if statement.arms.any? { |arm| arm.binding_name && !wildcard_arm_pattern?(arm.pattern) } &&
             !duplicable_foreign_argument_expression?(match_expr)
            scrutinee_c_name = fresh_c_temp_name(env, "match_value")
            expr_setup << IR::LocalDecl.new(name: scrutinee_c_name, c_name: scrutinee_c_name, type: match_type, value: match_expr)
            match_expr = IR::Name.new(name: scrutinee_c_name, type: match_type, pointer: false)
          end

          kind_type = @types.fetch("int")
          kind_expr = IR::Member.new(receiver: match_expr, member: "kind", type: kind_type)
          cases = statement.arms.map do |arm|
            arm_env, binding_decl = async_variant_match_arm_binding(arm, match_expr, match_type, env:)
            arm_body = if statements_contain_await?(arm.body, async_info)
                         lower_async_cf_statements(arm.body, env: arm_env, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:, loop_flow: arm_loop_flow)
                       else
                         lower_async_non_await_statements(arm.body, env: arm_env, frame_expr:, raw_frame_expr:, async_info:, active_defers:, loop_flow: arm_loop_flow)
                       end
            body = [binding_decl, *arm_body].compact + [IR::BreakStmt.new]
            if wildcard_arm_pattern?(arm.pattern)
              IR::SwitchDefaultCase.new(body: body)
            else
              arm_name = variant_match_arm_name_from_pattern(arm.pattern)
              IR::SwitchCase.new(value: IR::Name.new(name: enum_member_c_name(match_type, "kind_#{arm_name}"), type: kind_type, pointer: false), body: body)
            end
          end

          return expr_setup + [IR::SwitchStmt.new(expression: kind_expr, cases:, exhaustive: true)]
        end

        cases = statement.arms.map do |arm|
          arm_body = if statements_contain_await?(arm.body, async_info)
            lower_async_cf_statements(arm.body, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:, loop_flow: arm_loop_flow)
          else
            lower_async_non_await_statements(arm.body, env:, frame_expr:, raw_frame_expr:, async_info:, active_defers:, loop_flow: arm_loop_flow)
          end
          if wildcard_arm_pattern?(arm.pattern)
            IR::SwitchDefaultCase.new(body: arm_body + [IR::BreakStmt.new])
          else
            IR::SwitchCase.new(value: lower_expression(arm.pattern, env:, expected_type: match_type), body: arm_body + [IR::BreakStmt.new])
          end
        end

        expr_setup + [IR::SwitchStmt.new(expression: match_expr, cases:, exhaustive: true)]
      end

      def lower_async_non_await_statements(statements, env:, frame_expr:, raw_frame_expr:, async_info:, active_defers: [], loop_flow: nil)
        local_env = duplicate_env(env)
        lowered = []
        local_defers = []
        local_env[:return_context] = async_return_context(
          return_type: async_info[:result_type],
          active_defers:,
          local_defers:,
          frame_expr:,
          raw_frame_expr:,
          async_info:,
        )

        statements.each do |statement|
          case statement
          when AST::LocalDecl
            else_env = duplicate_env(local_env) if statement.else_body
            type, storage_type = async_local_decl_types(statement, env: local_env)
            c_name = c_local_name(statement.name)
            if statement.value
              prepared_setup, prepared_value = prepare_expression_for_inline_lowering(
                statement.value, env: local_env, expected_type: storage_type, allow_root_statement_foreign: true
              )
              lowered.concat(prepared_setup)
              value = lower_contextual_expression(
                prepared_value, env: local_env, expected_type: storage_type,
                contextual_int_to_float: statement.type && contextual_int_to_float_target?(type)
              )
            else
              value = IR::ZeroInit.new(type: storage_type)
            end
            lowered << IR::LocalDecl.new(name: statement.name, c_name:, type: storage_type, value:)
            current_actual_scope(local_env[:scopes])[statement.name] = local_binding(type:, storage_type:, c_name:, mutable: statement.kind == :var, pointer: false)
            if statement.else_body
              else_body = lower_async_non_await_statements(
                statement.else_body,
                env: else_env,
                frame_expr:,
                raw_frame_expr:,
                async_info:,
                active_defers: active_defers + local_defers,
                loop_flow: nested_loop_flow(loop_flow, local_defers),
              )
              lowered << IR::IfStmt.new(
                condition: IR::Binary.new(
                  operator: "==",
                  left: IR::Name.new(name: c_name, type: storage_type, pointer: false),
                  right: IR::NullLiteral.new(type: storage_type),
                  type: @types.fetch("bool"),
                ),
                then_body: else_body,
                else_body: nil,
              )
            end
          when AST::Assignment
            lowered.concat(lower_async_assignment_statement(statement, env: local_env))
          when AST::ExpressionStmt
            lowered.concat(lower_async_expression_statement(statement, env: local_env))
          when AST::ReturnStmt
            lowered.concat(lower_async_return_statement(statement, env: local_env, frame_expr:, raw_frame_expr:, async_info:, cleanup: lower_async_cleanup_entries(local_defers, active_defers, frame_expr:, raw_frame_expr:, async_info:)))
          when AST::IfStmt
            branch_entries = statement.branches.map do |branch|
              condition_setup, prepared_cond = prepare_expression_for_inline_lowering(
                branch.condition, env: local_env, expected_type: @types.fetch("bool")
              )
              then_body = lower_async_non_await_statements(
                branch.body, env: local_env, frame_expr:, raw_frame_expr:, async_info:, active_defers: active_defers + local_defers, loop_flow: nested_loop_flow(loop_flow, local_defers)
              )
              [condition_setup, lower_expression(prepared_cond, env: local_env, expected_type: @types.fetch("bool")), then_body]
            end
            else_body = statement.else_body ? lower_async_non_await_statements(
              statement.else_body, env: local_env, frame_expr:, raw_frame_expr:, async_info:, active_defers: active_defers + local_defers, loop_flow: nested_loop_flow(loop_flow, local_defers)
            ) : nil
            nested = else_body || []
            branch_entries.reverse_each do |cond_setup, cond, then_body|
              nested = [*cond_setup, IR::IfStmt.new(condition: cond, then_body:, else_body: nested.empty? ? nil : nested)]
            end
            lowered.concat(nested)
          when AST::MatchStmt
            scrutinee_type = infer_expression_type(statement.expression, env: local_env)
            expr_setup, prepared_expr = prepare_expression_for_inline_lowering(
              statement.expression, env: local_env, expected_type: scrutinee_type
            )
            lowered.concat(expr_setup)
            expr = lower_expression(prepared_expr, env: local_env, expected_type: scrutinee_type)
            arm_loop_flow = switch_loop_flow(loop_flow, local_defers)
            if scrutinee_type.is_a?(Types::Variant)
              if statement.arms.any? { |arm| arm.binding_name && !wildcard_arm_pattern?(arm.pattern) } &&
                 !duplicable_foreign_argument_expression?(expr)
                scrutinee_c_name = fresh_c_temp_name(local_env, "match_value")
                lowered << IR::LocalDecl.new(name: scrutinee_c_name, c_name: scrutinee_c_name, type: scrutinee_type, value: expr)
                expr = IR::Name.new(name: scrutinee_c_name, type: scrutinee_type, pointer: false)
              end

              kind_type = @types.fetch("int")
              kind_expr = IR::Member.new(receiver: expr, member: "kind", type: kind_type)
              cases = statement.arms.map do |arm|
                arm_env, binding_decl = async_variant_match_arm_binding(arm, expr, scrutinee_type, env: local_env)
                arm_body = lower_async_non_await_statements(
                  arm.body, env: arm_env, frame_expr:, raw_frame_expr:, async_info:, active_defers: active_defers + local_defers, loop_flow: arm_loop_flow
                )
                body = [binding_decl, *arm_body].compact
                if wildcard_arm_pattern?(arm.pattern)
                  IR::SwitchDefaultCase.new(body: body)
                else
                  arm_name = variant_match_arm_name_from_pattern(arm.pattern)
                  IR::SwitchCase.new(value: IR::Name.new(name: enum_member_c_name(scrutinee_type, "kind_#{arm_name}"), type: kind_type, pointer: false), body: body)
                end
              end
              lowered << IR::SwitchStmt.new(expression: kind_expr, cases:, exhaustive: true)
            else
              cases = statement.arms.map do |arm|
                arm_body = lower_async_non_await_statements(
                  arm.body, env: local_env, frame_expr:, raw_frame_expr:, async_info:, active_defers: active_defers + local_defers, loop_flow: arm_loop_flow
                )
                if wildcard_arm_pattern?(arm.pattern)
                  IR::SwitchDefaultCase.new(body: arm_body)
                else
                  value = lower_expression(arm.pattern, env: local_env, expected_type: scrutinee_type)
                  IR::SwitchCase.new(value:, body: arm_body)
                end
              end
              lowered << IR::SwitchStmt.new(expression: expr, cases:, exhaustive: true)
            end
          when AST::WhileStmt
            lowered << lower_async_while_stmt(statement, env: local_env, frame_expr:, raw_frame_expr:, async_info:, active_defers: active_defers + local_defers)
          when AST::ForStmt
            lowered << lower_async_for_stmt(statement, env: local_env, frame_expr:, raw_frame_expr:, async_info:, active_defers: active_defers + local_defers)
          when AST::DeferStmt
            local_defers << lower_async_defer_cleanup(statement, env: local_env, async_info:)
          when AST::PassStmt
            nil
          when AST::BreakStmt
            if loop_flow
              lowered.concat(lower_async_loop_exit(loop_flow[:break_target], local_defers, loop_flow[:break_defers], frame_expr:, raw_frame_expr:, async_info:))
            else
              lowered << IR::BreakStmt.new
            end
          when AST::ContinueStmt
            if loop_flow
              lowered.concat(lower_async_loop_exit(loop_flow[:continue_target], local_defers, loop_flow[:continue_defers], frame_expr:, raw_frame_expr:, async_info:))
            else
              lowered << IR::ContinueStmt.new
            end
          when AST::UnsafeStmt
            lowered.concat(lower_async_non_await_statements(
              statement.body, env: local_env, frame_expr:, raw_frame_expr:, async_info:, active_defers: active_defers + local_defers, loop_flow: nested_loop_flow(loop_flow, local_defers)
            ))
          when AST::StaticAssert
            lowered << lower_static_assert(statement, env: local_env)
          else
            raise LoweringError, "unsupported async non-await statement #{statement.class.name}"
          end
        end

        unless cfg_block_always_terminates?(statements)
          lowered.concat(lower_async_cleanup_entries(local_defers, [], frame_expr:, raw_frame_expr:, async_info:))
        end
        lowered
      end

      def lower_async_while_stmt(statement, env:, frame_expr:, raw_frame_expr:, async_info:, active_defers: [])
        continue_label = fresh_c_temp_name(env, "loop_continue")
        break_label = fresh_c_temp_name(env, "loop_break")
        condition_setup, prepared_cond = prepare_expression_for_inline_lowering(
          statement.condition, env:, expected_type: @types.fetch("bool")
        )
        body = lower_async_non_await_statements(
          statement.body,
          env: duplicate_env(env),
          frame_expr:,
          raw_frame_expr:,
          async_info:,
          active_defers:,
          loop_flow: loop_flow(break_target: loop_exit_break(break_label), continue_target: loop_exit_continue(continue_label)),
        )
        body << IR::LabelStmt.new(name: continue_label) if contains_label_target?(body, continue_label)
        cond = lower_expression(prepared_cond, env:, expected_type: @types.fetch("bool"))

        if condition_setup.empty?
          stmts = [IR::WhileStmt.new(condition: cond, body:)]
          stmts << IR::LabelStmt.new(name: break_label) if contains_label_target?(body, break_label)
          return IR::BlockStmt.new(body: stmts)
        end

        loop_body = [
          *condition_setup,
          IR::IfStmt.new(
            condition: IR::Unary.new(operator: "not", operand: cond, type: @types.fetch("bool")),
            then_body: [loop_exit_statement(loop_exit_break(break_label), local_defers: [], outer_defers: [])],
            else_body: nil,
          ),
          *body,
        ]
        stmts = [IR::WhileStmt.new(condition: IR::BooleanLiteral.new(value: true, type: @types.fetch("bool")), body: loop_body)]
        stmts << IR::LabelStmt.new(name: break_label) if contains_label_target?(loop_body, break_label)
        IR::BlockStmt.new(body: stmts)
      end

      def lower_async_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, async_info:, active_defers: [])
        return lower_async_parallel_collection_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, async_info:, active_defers:) if statement.parallel?

        return lower_async_range_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, async_info:, active_defers:) if range_iterable?(statement.iterable)

        lower_async_collection_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, async_info:, active_defers:)
      end

      def lower_async_range_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, async_info:, active_defers: [])
        loop_type = infer_range_loop_type(statement.iterable, env:)
        start_expr = range_start_of(statement.iterable)
        stop_expr = range_end_of(statement.iterable)
        start_setup, prepared_start = prepare_expression_for_inline_lowering(start_expr, env:, expected_type: loop_type)
        stop_setup, prepared_stop = prepare_expression_for_inline_lowering(stop_expr, env:, expected_type: loop_type)
        index_c_name = c_local_name(statement.name)
        stop_c_name = fresh_c_temp_name(env, "for_stop")
        continue_label = fresh_c_temp_name(env, "loop_continue")
        break_label = fresh_c_temp_name(env, "loop_break")
        index_ref = IR::Name.new(name: index_c_name, type: loop_type, pointer: false)
        inline_stop = stop_setup.empty? && compile_time_numeric_const_expression?(prepared_stop)
        stop_value = if inline_stop
                       lower_expression(prepared_stop, env:, expected_type: loop_type)
                     else
                       IR::Name.new(name: stop_c_name, type: loop_type, pointer: false)
                     end

        while_env = duplicate_env(env)
        current_actual_scope(while_env[:scopes])[statement.name] = local_binding(
          type: loop_type, c_name: index_c_name, mutable: false, pointer: false
        )
        body = lower_async_non_await_statements(
          statement.body,
          env: while_env,
          frame_expr:,
          raw_frame_expr:,
          async_info:,
          active_defers:,
          loop_flow: loop_flow(break_target: loop_exit_break(break_label), continue_target: loop_exit_continue(continue_label)),
        )
        body << IR::LabelStmt.new(name: continue_label) if contains_label_target?(body, continue_label)

        for_statement = IR::ForStmt.new(
          init: IR::LocalDecl.new(name: statement.name, c_name: index_c_name, type: loop_type, value: lower_expression(prepared_start, env:, expected_type: loop_type)),
          condition: IR::Binary.new(operator: "<", left: index_ref, right: stop_value, type: @types.fetch("bool")),
          post: IR::Assignment.new(target: index_ref, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: loop_type)),
          body:,
        )

        stmts = [
          *start_setup,
          *stop_setup,
          *(inline_stop ? [] : [IR::LocalDecl.new(name: stop_c_name, c_name: stop_c_name, type: loop_type, value: lower_expression(prepared_stop, env:, expected_type: loop_type))]),
          for_statement,
        ]
        stmts << IR::LabelStmt.new(name: break_label) if contains_label_target?(body, break_label)
        IR::BlockStmt.new(body: stmts)
      end

      def lower_async_collection_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, async_info:, active_defers: [])
        iterable_type = infer_expression_type(statement.iterable, env:)
        element_type = collection_loop_type(iterable_type)
        raise LoweringError, "for loop expects start..stop, array[T, N], or span[T], got #{iterable_type}" unless element_type

        iterable_setup, prepared_iterable = prepare_expression_for_inline_lowering(statement.iterable, env:, expected_type: iterable_type)
        iterable_c_name = fresh_c_temp_name(env, "for_items")
        index_c_name = fresh_c_temp_name(env, "for_index")
        continue_label = fresh_c_temp_name(env, "loop_continue")
        break_label = fresh_c_temp_name(env, "loop_break")
        iterable_ref = IR::Name.new(name: iterable_c_name, type: iterable_type, pointer: false)
        index_ref = IR::Name.new(name: index_c_name, type: @types.fetch("ptr_uint"), pointer: false)

        item_value = if array_type?(iterable_type)
                       IR::Index.new(receiver: iterable_ref, index: index_ref, type: element_type)
                     else
                       data_ref = IR::Member.new(receiver: iterable_ref, member: "data", type: pointer_to(element_type))
                       IR::Index.new(receiver: data_ref, index: index_ref, type: element_type)
                     end
        stop_value = if array_type?(iterable_type)
                       IR::IntegerLiteral.new(value: array_length(iterable_type), type: @types.fetch("ptr_uint"))
                     else
                       IR::Member.new(receiver: iterable_ref, member: "len", type: @types.fetch("ptr_uint"))
                     end

        while_env = duplicate_env(env)
        current_actual_scope(while_env[:scopes])[statement.name] = local_binding(
          type: element_type, c_name: c_local_name(statement.name), mutable: false, pointer: false
        )
        body = [IR::LocalDecl.new(name: statement.name, c_name: c_local_name(statement.name), type: element_type, value: item_value)]
        body.concat(lower_async_non_await_statements(
          statement.body,
          env: while_env,
          frame_expr:,
          raw_frame_expr:,
          async_info:,
          active_defers:,
          loop_flow: loop_flow(break_target: loop_exit_break(break_label), continue_target: loop_exit_continue(continue_label)),
        ))
        body << IR::LabelStmt.new(name: continue_label) if contains_label_target?(body, continue_label)

        for_statement = IR::ForStmt.new(
          init: IR::LocalDecl.new(name: index_c_name, c_name: index_c_name, type: @types.fetch("ptr_uint"), value: IR::IntegerLiteral.new(value: 0, type: @types.fetch("ptr_uint"))),
          condition: IR::Binary.new(operator: "<", left: index_ref, right: stop_value, type: @types.fetch("bool")),
          post: IR::Assignment.new(target: index_ref, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: @types.fetch("ptr_uint"))),
          body:,
        )

        stmts = [
          *iterable_setup,
          IR::LocalDecl.new(name: iterable_c_name, c_name: iterable_c_name, type: iterable_type, value: lower_expression(prepared_iterable, env:, expected_type: iterable_type)),
          for_statement,
        ]
        stmts << IR::LabelStmt.new(name: break_label) if contains_label_target?(body, break_label)
        IR::BlockStmt.new(body: stmts)
      end

      def lower_async_parallel_collection_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, async_info:, active_defers: [])
        infos = statement.bindings.each_with_index.map do |binding, index|
          iterable = statement.iterables[index]
          iterable_type = infer_expression_type(iterable, env:)
          element_type = collection_loop_type(iterable_type)
          raise LoweringError, "parallel for loops expect arrays or spans for each iterable, got #{iterable_type}" unless element_type

          {
            binding:,
            iterable:,
            iterable_type:,
            element_type:,
            binding_type: collection_loop_binding_type(iterable_type, element_type) || element_type,
          }
        end

        iterable_entries = infos.map do |info|
          setup, prepared_iterable = prepare_expression_for_inline_lowering(info[:iterable], env:, expected_type: info[:iterable_type])
          c_name = fresh_c_temp_name(env, "for_items")
          info.merge(
            setup:,
            prepared_iterable:,
            iterable_c_name: c_name,
            iterable_ref: IR::Name.new(name: c_name, type: info[:iterable_type], pointer: false),
          )
        end

        index_c_name = fresh_c_temp_name(env, "for_index")
        continue_label = fresh_c_temp_name(env, "loop_continue")
        break_label = fresh_c_temp_name(env, "loop_break")
        index_ref = IR::Name.new(name: index_c_name, type: @types.fetch("ptr_uint"), pointer: false)
        stop_value = collection_loop_stop_value(iterable_entries.first[:iterable_ref], iterable_entries.first[:iterable_type])

        while_env = duplicate_env(env)
        body = iterable_entries.map do |entry|
          item_value = collection_loop_item_value(entry[:iterable_ref], entry[:iterable_type], index_ref, entry[:element_type])
          loop_item_value = if ref_type?(entry[:binding_type])
                              IR::AddressOf.new(expression: item_value, type: entry[:binding_type])
                            else
                              item_value
                            end
          binding = entry[:binding]
          current_actual_scope(while_env[:scopes])[binding.name] = local_binding(type: entry[:binding_type], c_name: c_local_name(binding.name), mutable: false, pointer: false)
          IR::LocalDecl.new(name: binding.name, c_name: c_local_name(binding.name), type: entry[:binding_type], value: loop_item_value)
        end
        body.concat(lower_async_non_await_statements(
          statement.body,
          env: while_env,
          frame_expr:,
          raw_frame_expr:,
          async_info:,
          active_defers:,
          loop_flow: loop_flow(break_target: loop_exit_break(break_label), continue_target: loop_exit_continue(continue_label)),
        ))
        body << IR::LabelStmt.new(name: continue_label) if contains_label_target?(body, continue_label)

        length_checks = iterable_entries.drop(1).map do |entry|
          IR::IfStmt.new(
            condition: IR::Binary.new(
              operator: "!=",
              left: collection_loop_stop_value(entry[:iterable_ref], entry[:iterable_type]),
              right: stop_value,
              type: @types.fetch("bool"),
            ),
            then_body: [lower_fatal_statement("parallel for iterables must have matching lengths", env:)],
            else_body: nil,
          )
        end

        for_statement = IR::ForStmt.new(
          init: IR::LocalDecl.new(name: index_c_name, c_name: index_c_name, type: @types.fetch("ptr_uint"), value: IR::IntegerLiteral.new(value: 0, type: @types.fetch("ptr_uint"))),
          condition: IR::Binary.new(operator: "<", left: index_ref, right: stop_value, type: @types.fetch("bool")),
          post: IR::Assignment.new(target: index_ref, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: @types.fetch("ptr_uint"))),
          body:,
        )

        stmts = [
          *iterable_entries.flat_map { |entry| entry[:setup] },
          *iterable_entries.map do |entry|
            IR::LocalDecl.new(name: entry[:iterable_c_name], c_name: entry[:iterable_c_name], type: entry[:iterable_type], value: lower_expression(entry[:prepared_iterable], env:, expected_type: entry[:iterable_type]))
          end,
          *length_checks,
          for_statement,
        ]
        stmts << IR::LabelStmt.new(name: break_label) if contains_label_target?(body, break_label)
        IR::BlockStmt.new(body: stmts)
      end

      def lower_async_assignment_statement(statement, env:)
        lowered = []
        target = lower_assignment_target(statement.target, env:)
        prepared_setup, prepared_value = prepare_expression_for_inline_lowering(
          statement.value,
          env:,
          expected_type: target.type,
          allow_root_statement_foreign: true,
        )
        lowered.concat(prepared_setup)

        if (foreign_call = foreign_call_info(prepared_value, env))
          setup, value, call_type, release_assignments, cleanup_statements = lower_foreign_call_components(
            foreign_call,
            env:,
            expected_type: target.type,
            statement_position: false,
          )
          lowered.concat(setup)
          raise LoweringError, "foreign call used in assignment must return a value" if call_type == @types.fetch("void")
          raise LoweringError, "consuming foreign calls must return void" unless release_assignments.empty?

          lowered << IR::Assignment.new(target:, operator: statement.operator, value:)
          lowered.concat(cleanup_statements)
          update_cstr_metadata_for_assignment!(statement, prepared_value, env)
          return lowered
        end

        value = if statement.operator == "="
                  lower_contextual_expression(
                    prepared_value,
                    env:,
                    expected_type: target.type,
                    external_numeric: external_numeric_assignment_target?(statement.target, env:),
                    contextual_int_to_float: contextual_int_to_float_target?(target.type),
                  )
                elsif ["+=", "-=", "*=", "/="].include?(statement.operator)
                  lower_contextual_expression(
                    prepared_value,
                    env:,
                    expected_type: target.type,
                    contextual_int_to_float: contextual_int_to_float_target?(target.type),
                  )
                else
                  lower_expression(prepared_value, env:, expected_type: target.type)
                end
        update_cstr_metadata_for_assignment!(statement, prepared_value, env)
        if statement.operator == "=" && contains_proc_storage_type?(target.type)
          rhs_name = fresh_c_temp_name(env, "proc_assign")
          lowered << IR::LocalDecl.new(name: rhs_name, c_name: rhs_name, type: target.type, value:)
          rhs = IR::Name.new(name: rhs_name, type: target.type, pointer: false)
          lowered.concat(lower_proc_selective_retain_statements(rhs, statement.value, target.type))
          lowered.concat(lower_proc_contained_guarded_release_statements(target, target.type))
          lowered << IR::Assignment.new(target:, operator: "=", value: rhs)
        else
          lowered << IR::Assignment.new(target:, operator: statement.operator, value:)
        end
        lowered
      end

      def lower_async_expression_statement(statement, env:)
        lowered = []
        expression_expected_type = if statement.expression.is_a?(AST::UnaryOp) && statement.expression.operator == "?"
                                     nil
                                   else
                                     infer_expression_type(statement.expression, env:)
                                   end
        prepared_setup, prepared_expression = prepare_expression_for_inline_lowering(
          statement.expression,
          env:,
          expected_type: expression_expected_type,
          allow_root_statement_foreign: true,
          allow_void_propagation: true,
        )
        lowered.concat(prepared_setup)

        if prepared_expression && (foreign_call = foreign_call_info(prepared_expression, env))
          setup, = lower_foreign_call_statement(
            foreign_call,
            env:,
            expected_type: foreign_call[:binding].type.return_type,
            statement_position: true,
            discard_result: true,
          )
          lowered.concat(setup)
        elsif prepared_expression
          lowered << IR::ExpressionStmt.new(expression: lower_expression(prepared_expression, env:), line: statement.line, source_path: @current_analysis_path)
        end

        lowered
      end

      def lower_async_return_statement(statement, env:, frame_expr:, raw_frame_expr:, async_info:, cleanup: [])
        lowered = []
        value = nil
        prepared_setup = []
        prepared_value = statement.value

        if statement.value
          prepared_setup, prepared_value = prepare_expression_for_inline_lowering(
            statement.value,
            env:,
            expected_type: async_info[:result_type],
            allow_root_statement_foreign: true,
          )
          lowered.concat(prepared_setup)
        end

        if prepared_value && (foreign_call = foreign_call_info(prepared_value, env))
          setup, value = lower_foreign_call_statement(foreign_call, env:, expected_type: async_info[:result_type], statement_position: false)
          lowered.concat(setup)
        elsif prepared_value
          value = lower_contextual_expression(
            prepared_value,
            env:,
            expected_type: async_info[:result_type],
            contextual_int_to_float: contextual_int_to_float_target?(async_info[:result_type]),
          )
        end

        if async_info[:result_type] != @types.fetch("void") && value && cleanup.any? && !cleanup_safe_return_expression?(prepared_value)
          lowered << IR::Assignment.new(
            target: async_frame_field_expression(frame_expr, "result", async_info[:result_type]),
            operator: "=",
            value: value,
          )
          lowered.concat(cleanup)
          lowered.concat(async_complete_statements(frame_expr:, raw_frame_expr:, async_info:, value: nil, result_already_stored: true))
        else
          lowered.concat(cleanup)
          lowered.concat(async_complete_statements(frame_expr:, raw_frame_expr:, async_info:, value:))
        end
        lowered
      end

      def lower_async_await_statement(statement, await_info:, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, field_info: nil, cleanup: [], active_defers: [], loop_flow: nil)
        lowered = []
        await_expression = case statement
                           when AST::LocalDecl then statement.value
                           when AST::Assignment then statement.value
                           when AST::ExpressionStmt then statement.expression
                           when AST::ReturnStmt then statement.value
                           end
        prepared_setup, prepared_task = prepare_expression_for_inline_lowering(
          await_expression.expression,
          env:,
          expected_type: await_info[:task_type],
        )
        lowered.concat(prepared_setup)
        raise LoweringError, "await does not support foreign task expressions" if foreign_call_info(prepared_task, env)

        task_expr = async_frame_field_expression(frame_expr, await_info[:field_name], await_info[:task_type])
        task_frame_expr = async_task_frame_expression(task_expr, await_info[:task_type])
        ready_call = async_task_call(task_expr, await_info[:task_type], "ready", [task_frame_expr], @types.fetch("bool"))
        set_waiter_call = async_task_call(
          task_expr,
          await_info[:task_type],
          "set_waiter",
          [
            task_frame_expr,
            raw_frame_expr,
            IR::Name.new(name: resume_c_name, type: async_info[:wake_type], pointer: false),
          ],
          @types.fetch("void"),
        )
        take_result_call = async_task_call(task_expr, await_info[:task_type], "take_result", [task_frame_expr], await_info[:result_type])
        release_call = async_task_call(task_expr, await_info[:task_type], "release", [task_frame_expr], @types.fetch("void"))

        unless await_info[:reuse_existing_storage]
          lowered << IR::Assignment.new(
            target: task_expr,
            operator: "=",
            value: lower_contextual_expression(prepared_task, env:, expected_type: await_info[:task_type]),
          )
        end
        lowered << IR::IfStmt.new(
          condition: IR::Unary.new(operator: "not", operand: ready_call, type: @types.fetch("bool")),
          then_body: [
            IR::Assignment.new(
              target: async_frame_field_expression(frame_expr, "state", @types.fetch("int")),
              operator: "=",
              value: IR::IntegerLiteral.new(value: await_info[:state], type: @types.fetch("int")),
            ),
            IR::ExpressionStmt.new(expression: set_waiter_call),
            IR::ReturnStmt.new(value: nil),
          ],
          else_body: nil,
        )
        lowered << IR::LabelStmt.new(name: async_state_label(resume_c_name, await_info[:state]))

        case statement
        when AST::LocalDecl
          storage_type = field_info[:storage_type]
          target = async_frame_field_expression(frame_expr, field_info[:field_name], storage_type)
          lowered << IR::Assignment.new(target:, operator: "=", value: take_result_call)
          lowered << IR::ExpressionStmt.new(expression: release_call)
          if statement.else_body
            else_env = duplicate_env(env)
            if statement.else_binding
              current_actual_scope(else_env[:scopes])[statement.else_binding.name] = local_binding(
                type: let_else_error_type(storage_type),
                storage_type:,
                c_name: async_frame_field_c_name(field_info[:field_name]),
                mutable: false,
                pointer: false,
                projection: :result_failure_error,
              )
            end
            else_body = if statements_contain_await?(statement.else_body, async_info)
              lower_async_cf_statements(
                statement.else_body,
                env: else_env,
                frame_expr:,
                raw_frame_expr:,
                resume_c_name:,
                async_info:,
                active_defers:,
                loop_flow:,
              )
            else
              lower_async_non_await_statements(
                statement.else_body,
                env: else_env,
                frame_expr:,
                raw_frame_expr:,
                async_info:,
                active_defers:,
                loop_flow:,
              )
            end
            lowered << IR::IfStmt.new(
              condition: let_else_failure_condition(target, storage_type),
              then_body: else_body,
              else_body: nil,
            )
          end
        when AST::Assignment
          lowered << IR::Assignment.new(target: lower_assignment_target(statement.target, env:), operator: statement.operator, value: take_result_call)
          lowered << IR::ExpressionStmt.new(expression: release_call)
        when AST::ExpressionStmt
          lowered << IR::ExpressionStmt.new(expression: take_result_call)
          lowered << IR::ExpressionStmt.new(expression: release_call)
        when AST::ReturnStmt
          if await_info[:result_type] == @types.fetch("void")
            lowered << IR::ExpressionStmt.new(expression: take_result_call)
            lowered << IR::ExpressionStmt.new(expression: release_call)
            lowered.concat(cleanup)
            lowered.concat(async_complete_statements(frame_expr:, raw_frame_expr:, async_info:, value: nil, result_already_stored: true))
          else
            lowered << IR::Assignment.new(
              target: async_frame_field_expression(frame_expr, "result", async_info[:result_type]),
              operator: "=",
              value: take_result_call,
            )
            lowered << IR::ExpressionStmt.new(expression: release_call)
            lowered.concat(cleanup)
            lowered.concat(async_complete_statements(frame_expr:, raw_frame_expr:, async_info:, value: nil, result_already_stored: true))
          end
        end

        lowered
      end

      def lower_async_defer_cleanup(statement, env:, async_info:)
        body = if statement.body
                 statement.body
               elsif statement.expression
                 [AST::ExpressionStmt.new(expression: statement.expression, line: statement.line)]
               else
                 []
               end

        { body:, env: snapshot_env(env) }
      end

      def lower_async_cleanup_entries(local_defers, outer_defers, frame_expr:, raw_frame_expr:, async_info:)
        cleanup_entries = local_defers.reverse + outer_defers.reverse
        cleanup_entries.flat_map do |cleanup_entry|
          next [] if cleanup_entry[:body].empty?

          cleanup_env = duplicate_env(cleanup_entry[:env])
          if statements_contain_await?(cleanup_entry[:body], async_info)
            lower_async_cf_statements(
              cleanup_entry[:body],
              env: cleanup_env,
              frame_expr:,
              raw_frame_expr:,
              resume_c_name: async_info.fetch(:resume_c_name),
              async_info:,
              active_defers: [],
              loop_flow: nil,
            )
          else
            lower_async_non_await_statements(
              cleanup_entry[:body],
              env: cleanup_env,
              frame_expr:,
              raw_frame_expr:,
              async_info:,
              active_defers: [],
              loop_flow: nil,
            )
          end
        end
      end

      def async_return_context(return_type:, active_defers:, local_defers:, frame_expr:, raw_frame_expr:, async_info:, allow_return: true)
        {
          return_type:,
          active_defers:,
          local_defers:,
          allow_return:,
          frame_expr:,
          raw_frame_expr:,
          async_info:,
        }
      end

      def async_complete_statements(frame_expr:, raw_frame_expr:, async_info:, value:, result_already_stored: false)
        lowered = []

        if async_info[:result_type] != @types.fetch("void") && !result_already_stored
          lowered << IR::Assignment.new(
            target: async_frame_field_expression(frame_expr, "result", async_info[:result_type]),
            operator: "=",
            value: value,
          )
        end

        lowered << IR::Assignment.new(
          target: async_frame_field_expression(frame_expr, "ready", @types.fetch("bool")),
          operator: "=",
          value: IR::BooleanLiteral.new(value: true, type: @types.fetch("bool")),
        )

        waiter_frame_field = async_frame_field_expression(frame_expr, "waiter_frame", async_info[:void_ptr])
        lowered << IR::IfStmt.new(
          condition: IR::Binary.new(
            operator: "!=",
            left: waiter_frame_field,
            right: IR::NullLiteral.new(type: async_info[:void_ptr]),
            type: @types.fetch("bool"),
          ),
          then_body: [
            IR::LocalDecl.new(
              name: "waiter_frame",
              c_name: "__mt_waiter_frame",
              type: async_info[:void_ptr],
              value: waiter_frame_field,
            ),
            IR::Assignment.new(
              target: waiter_frame_field,
              operator: "=",
              value: IR::NullLiteral.new(type: async_info[:void_ptr]),
            ),
            IR::ExpressionStmt.new(
              expression: IR::Call.new(
                callee: async_frame_field_expression(frame_expr, "waiter", async_info[:wake_type]),
                arguments: [IR::Name.new(name: "__mt_waiter_frame", type: async_info[:void_ptr], pointer: false)],
                type: @types.fetch("void"),
              ),
            ),
            IR::ReturnStmt.new(value: nil),
          ],
          else_body: nil,
        )
        lowered << IR::ReturnStmt.new(value: nil)
        lowered
      end
  end
end

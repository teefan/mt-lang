# frozen_string_literal: true

module MilkTea
  module LowererAsync
    private
      def lower_contained_task_release_statements(value_expr, type)
        return [] unless contains_task_type?(type)

        void_type = @ctx.types.fetch("void")
        int_type = @ctx.types.fetch("int")

        case type
        when Types::Task
          task_frame_expr = IR::Member.new(receiver: value_expr, member: "frame", type: type.field("frame"))
          release_call = IR::ExpressionStmt.new(
            expression: IR::Call.new(
              callee: IR::Member.new(receiver: value_expr, member: "release", type: type.field("release")),
              arguments: [task_frame_expr],
              type: void_type,
            ),
          )
          [IR::IfStmt.new(condition: task_frame_expr, then_body: [release_call], else_body: nil)]

        when Types::Struct, Types::StructInstance, Types::Union, Types::GenericStructDefinition, Types::VariantArmPayload
          statements = []
          type.fields.each do |field_name, field_type|
            next unless contains_task_type?(field_type)

            field_expr = IR::Member.new(receiver: value_expr, member: field_name, type: field_type)
            statements.concat(lower_contained_task_release_statements(field_expr, field_type))
          end
          statements

        when Types::VariantInstance
          args_with_task = type.arguments.select { |a| contains_task_type?(a) }
          if args_with_task.any? && type.definition.name == "Option"
            kind_expr = IR::Member.new(receiver: value_expr, member: "kind", type: int_type)
            some_check = IR::Binary.new(
              operator: "==",
              left: kind_expr,
              right: IR::IntegerLiteral.new(value: 0, type: int_type),
              type: @ctx.types.fetch("bool"),
            )
            data_expr = IR::Member.new(receiver: value_expr, member: "data", type: nil)
            some_payload_expr = IR::Member.new(receiver: data_expr, member: "some", type: nil)
            task_type = args_with_task.first
            task_value_expr = IR::Member.new(receiver: some_payload_expr, member: "value", type: task_type)
            release_body = lower_contained_task_release_statements(task_value_expr, task_type)
            none_assignment = IR::Assignment.new(
              target: kind_expr,
              operator: "=",
              value: IR::IntegerLiteral.new(value: 1, type: int_type),
            )
            then_body = release_body + [none_assignment]
            [IR::IfStmt.new(condition: some_check, then_body:, else_body: nil)]
          else
            []
          end

        when Types::Variant, Types::GenericVariantDefinition
          statements = []
          type.arms.each do |arm_name, arm_fields|
            arm_fields.each do |field_name, field_type|
              next unless contains_task_type?(field_type)
              # For variant arms, the data is under .data.<arm_name>
              data_expr = IR::Member.new(receiver: value_expr, member: "data", type: nil)
              arm_expr = IR::Member.new(receiver: data_expr, member: arm_name, type: nil)
              field_expr = IR::Member.new(receiver: arm_expr, member: field_name, type: field_type)
              statements.concat(lower_contained_task_release_statements(field_expr, field_type))
            end
          end
          statements

        when Types::GenericInstance
          if type.name == "Option" && type.arguments.any? { |a| contains_task_type?(a) }
            kind_expr = IR::Member.new(receiver: value_expr, member: "kind", type: int_type)
            some_check = IR::Binary.new(
              operator: "==",
              left: kind_expr,
              right: IR::IntegerLiteral.new(value: 0, type: int_type),
              type: @ctx.types.fetch("bool"),
            )
            data_expr = IR::Member.new(receiver: value_expr, member: "data", type: nil)
            some_payload_expr = IR::Member.new(receiver: data_expr, member: "some", type: nil)
            task_type = type.arguments.first
            task_value_expr = IR::Member.new(receiver: some_payload_expr, member: "value", type: task_type)
            release_body = lower_contained_task_release_statements(task_value_expr, task_type)
            none_assignment = IR::Assignment.new(
              target: kind_expr,
              operator: "=",
              value: IR::IntegerLiteral.new(value: 1, type: int_type),
            )
            then_body = release_body + [none_assignment]
            [IR::IfStmt.new(condition: some_check, then_body:, else_body: nil)]
          else
            []
          end

        when Types::Nullable
          lower_contained_task_release_statements(value_expr, type.base)

        else
          []
        end
      end

      def lower_async_local_decl_statement(statement, field_info:, env:, frame_expr:, raw_frame_expr:, resume_linkage_name:, async_info:, active_defers: [], loop_flow: nil)
        lowered = []
        type = field_info[:type]
        storage_type = field_info[:storage_type]
        target = async_frame_field_expression(frame_expr, field_info[:field_name], storage_type)
        prepared_setup = []
        prepared_value = statement.value

        if statement.value
          cleanup_start = (env[:prepared_expression_cleanups] ||= []).length
          prepared_setup, prepared_value = prepare_expression_for_inline_lowering(
            statement.value,
            env:,
            expected_type: storage_type,
            allow_root_statement_foreign: true,
          )
          cleanup_count = (env[:prepared_expression_cleanups] || []).length - cleanup_start
          if cleanup_count.positive?
            async_info[:format_str_fields][field_info[:field_name]] = storage_type
            env[:prepared_expression_cleanups].slice!(cleanup_start, cleanup_count)
          end
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
          raise LoweringError, "foreign call used to initialize #{statement.name} must return a value" if call_type == @ctx.types.fetch("void")
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
              linkage_name: async_frame_field_c_name(field_info[:field_name]),
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
              resume_linkage_name:,
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
      def lower_async_cf_statements(statements, env:, frame_expr:, raw_frame_expr:, resume_linkage_name:, async_info:, active_defers: [], loop_flow: nil)
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
              lowered.concat(lower_async_await_statement(statement, field_info:, await_info:, env:, frame_expr:, raw_frame_expr:, resume_linkage_name:, async_info:, active_defers: active_defers + local_defers, loop_flow: nested_loop_flow(loop_flow, local_defers)))
            else
              lowered.concat(lower_async_local_decl_statement(statement, field_info:, env:, frame_expr:, raw_frame_expr:, resume_linkage_name:, async_info:, active_defers: active_defers + local_defers, loop_flow: nested_loop_flow(loop_flow, local_defers)))
            end
            async_bind_local!(env, statement.name, field_info) if bind_let_else_local?(statement)
          when AST::Assignment
            await_info = async_info[:await_fields][statement.value&.object_id]
            if await_info
              lowered.concat(lower_async_await_statement(statement, await_info:, env:, frame_expr:, raw_frame_expr:, resume_linkage_name:, async_info:))
            else
              lowered.concat(lower_async_assignment_statement(statement, env:))
            end
          when AST::ExpressionStmt
            await_info = async_info[:await_fields][statement.expression&.object_id]
            if await_info
              lowered.concat(lower_async_await_statement(statement, await_info:, env:, frame_expr:, raw_frame_expr:, resume_linkage_name:, async_info:))
            else
              lowered.concat(lower_async_expression_statement(statement, env:))
            end
          when AST::ReturnStmt
            cleanup = lower_async_cleanup_entries(local_defers, active_defers, frame_expr:, raw_frame_expr:, async_info:)
            await_info = async_info[:await_fields][statement.value&.object_id]
            if await_info
              lowered.concat(lower_async_await_statement(statement, await_info:, env:, frame_expr:, raw_frame_expr:, resume_linkage_name:, async_info:, cleanup:))
            else
              lowered.concat(lower_async_return_statement(statement, env:, frame_expr:, raw_frame_expr:, async_info:, cleanup:))
            end
          when AST::IfStmt
            lowered.concat(lower_async_cf_if_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_linkage_name:, async_info:, active_defers: active_defers + local_defers, loop_flow: nested_loop_flow(loop_flow, local_defers)))
          when AST::WhileStmt
            lowered.concat(lower_async_cf_while_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_linkage_name:, async_info:, active_defers: active_defers + local_defers, loop_flow: nested_loop_flow(loop_flow, local_defers)))
          when AST::ForStmt
            lowered.concat(lower_async_cf_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_linkage_name:, async_info:, active_defers: active_defers + local_defers))
          when AST::MatchStmt
            lowered.concat(lower_async_cf_match_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_linkage_name:, async_info:, active_defers: active_defers + local_defers, loop_flow: nested_loop_flow(loop_flow, local_defers)))
          when AST::UnsafeStmt
            lowered.concat(lower_async_cf_statements(statement.body, env:, frame_expr:, raw_frame_expr:, resume_linkage_name:, async_info:, active_defers: active_defers + local_defers, loop_flow: nested_loop_flow(loop_flow, local_defers)))
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

      def lower_async_cf_if_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_linkage_name:, async_info:, active_defers:, loop_flow:)
        branch_entries = statement.branches.map do |branch|
          condition_setup, prepared_cond = prepare_expression_for_inline_lowering(branch.condition, env:)
          condition = lower_contextual_expression(prepared_cond, env:, expected_type: @ctx.types.fetch("bool"))
          body = if statements_contain_await?(branch.body, async_info)
            lower_async_cf_statements(branch.body, env:, frame_expr:, raw_frame_expr:, resume_linkage_name:, async_info:, active_defers:, loop_flow:)
          else
            lower_async_non_await_statements(branch.body, env:, frame_expr:, raw_frame_expr:, async_info:, active_defers:, loop_flow:)
          end
          { condition_setup:, condition:, body: }
        end

        else_body = if statement.else_body
          if statements_contain_await?(statement.else_body, async_info)
            lower_async_cf_statements(statement.else_body, env:, frame_expr:, raw_frame_expr:, resume_linkage_name:, async_info:, active_defers:, loop_flow:)
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

      def lower_async_cf_while_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_linkage_name:, async_info:, active_defers:, loop_flow:)
        continue_label = fresh_c_temp_name(env, "loop_continue")
        break_label = fresh_c_temp_name(env, "loop_break")
        condition_setup, prepared_cond = prepare_expression_for_inline_lowering(statement.condition, env:)
        condition = lower_contextual_expression(prepared_cond, env:, expected_type: @ctx.types.fetch("bool"))
        inner_loop_flow = loop_flow(break_target: loop_exit_break(break_label), continue_target: loop_exit_continue(continue_label))
        body = if statements_contain_await?(statement.body, async_info)
          lower_async_cf_statements(statement.body, env: duplicate_env(env), frame_expr:, raw_frame_expr:, resume_linkage_name:, async_info:, active_defers:, loop_flow: inner_loop_flow)
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
            condition: IR::Unary.new(operator: "not", operand: condition, type: @ctx.types.fetch("bool")),
            then_body: [loop_exit_statement(loop_exit_break(break_label), local_defers: [], outer_defers: [])],
            else_body: nil,
          ),
          *body,
        ]
        stmts = [IR::WhileStmt.new(condition: IR::BooleanLiteral.new(value: true, type: @ctx.types.fetch("bool")), body: loop_body)]
        stmts << IR::LabelStmt.new(name: break_label) if contains_label_target?(loop_body, break_label)
        stmts
      end

      def lower_async_cf_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_linkage_name:, async_info:, active_defers:)
        return lower_async_cf_parallel_collection_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_linkage_name:, async_info:, active_defers:) if statement.parallel?

        if range_iterable?(statement.iterable)
          lower_async_cf_range_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_linkage_name:, async_info:, active_defers:)
        else
          lower_async_cf_collection_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_linkage_name:, async_info:, active_defers:)
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

      def lower_async_cf_range_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_linkage_name:, async_info:, active_defers:)
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
          linkage_name: async_frame_field_c_name(loop_var_field[:field_name]),
          mutable: true, pointer: false
        )
        inner_loop_flow = loop_flow(break_target: loop_exit_break(break_label), continue_target: loop_exit_continue(continue_label))

        body = if statements_contain_await?(statement.body, async_info)
          lower_async_cf_statements(statement.body, env: inner_env, frame_expr:, raw_frame_expr:, resume_linkage_name:, async_info:, active_defers:, loop_flow: inner_loop_flow)
        else
          lower_async_non_await_statements(statement.body, env: inner_env, frame_expr:, raw_frame_expr:, async_info:, active_defers:, loop_flow: inner_loop_flow)
        end
        body << IR::LabelStmt.new(name: continue_label) if contains_label_target?(body, continue_label)

        cmp_op = inclusive ? "<=" : "<"
        stmts = [
          IR::Assignment.new(target: loop_var_expr, operator: "=", value: start_expr),
          IR::Assignment.new(target: stop_field_expr, operator: "=", value: stop_expr),
          IR::WhileStmt.new(
            condition: IR::Binary.new(operator: cmp_op, left: loop_var_expr, right: stop_field_expr, type: @ctx.types.fetch("bool")),
            body: body + [IR::Assignment.new(target: loop_var_expr, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: loop_var_type))],
          ),
        ]
        stmts << IR::LabelStmt.new(name: break_label) if contains_label_target?(body, break_label)
        stmts
      end

      def lower_async_cf_collection_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_linkage_name:, async_info:, active_defers:)
        iterable_type = infer_expression_type(statement.iterable, env:)
        element_type = collection_loop_type(iterable_type)
        raise LoweringError, "for loop expects start..stop, array[T, N], or span[T], got #{iterable_type}" unless element_type

        iterable_setup, prepared_iterable = prepare_expression_for_inline_lowering(statement.iterable, env:, expected_type: iterable_type)
        continue_label = fresh_c_temp_name(env, "loop_continue")
        break_label = fresh_c_temp_name(env, "loop_break")
        iterable_field = async_info[:local_fields].fetch(async_collection_iterable_field_key(statement))
        index_field = async_info[:local_fields].fetch(async_collection_index_field_key(statement))
        iterable_ref = async_frame_field_expression(frame_expr, iterable_field[:field_name], iterable_type)
        index_ref = async_frame_field_expression(frame_expr, index_field[:field_name], @ctx.types.fetch("ptr_uint"))

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
                       IR::IntegerLiteral.new(value: array_length(iterable_type), type: @ctx.types.fetch("ptr_uint"))
                     else
                       IR::Member.new(receiver: iterable_ref, member: "len", type: @ctx.types.fetch("ptr_uint"))
                     end

        inner_env = duplicate_env(env)
        inner_env[:scopes].last[statement.name] = local_binding(
          type: element_type, linkage_name: async_frame_field_c_name(loop_var_field[:field_name]), mutable: true, pointer: false
        )
        inner_loop_flow = loop_flow(break_target: loop_exit_break(break_label), continue_target: loop_exit_continue(continue_label))

        assign_item = IR::Assignment.new(target: loop_var_expr, operator: "=", value: item_value)
        body_stmts = if statements_contain_await?(statement.body, async_info)
          lower_async_cf_statements(statement.body, env: inner_env, frame_expr:, raw_frame_expr:, resume_linkage_name:, async_info:, active_defers:, loop_flow: inner_loop_flow)
        else
          lower_async_non_await_statements(statement.body, env: inner_env, frame_expr:, raw_frame_expr:, async_info:, active_defers:, loop_flow: inner_loop_flow)
        end
        body_stmts << IR::LabelStmt.new(name: continue_label) if contains_label_target?(body_stmts, continue_label)

        stmts = [
          *iterable_setup,
          IR::Assignment.new(target: iterable_ref, operator: "=", value: lower_expression(prepared_iterable, env:, expected_type: iterable_type)),
          IR::Assignment.new(target: index_ref, operator: "=", value: IR::IntegerLiteral.new(value: 0, type: @ctx.types.fetch("ptr_uint"))),
          IR::WhileStmt.new(
            condition: IR::Binary.new(operator: "<", left: index_ref, right: stop_value, type: @ctx.types.fetch("bool")),
            body: [assign_item] + body_stmts + [
              IR::Assignment.new(target: index_ref, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: @ctx.types.fetch("ptr_uint"))),
            ],
          ),
        ]
        stmts << IR::LabelStmt.new(name: break_label) if contains_label_target?(body_stmts, break_label)
        stmts
      end

      def lower_async_cf_parallel_collection_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_linkage_name:, async_info:, active_defers:)
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
        index_ref = async_frame_field_expression(frame_expr, index_field[:field_name], @ctx.types.fetch("ptr_uint"))
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
            linkage_name: async_frame_field_c_name(binding_field[:field_name]),
            mutable: true,
            pointer: false,
          )
          IR::Assignment.new(target: binding_target, operator: "=", value: loop_item_value)
        end
        inner_loop_flow = loop_flow(break_target: loop_exit_break(break_label), continue_target: loop_exit_continue(continue_label))
        body_stmts = if statements_contain_await?(statement.body, async_info)
          lower_async_cf_statements(statement.body, env: inner_env, frame_expr:, raw_frame_expr:, resume_linkage_name:, async_info:, active_defers:, loop_flow: inner_loop_flow)
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
              type: @ctx.types.fetch("bool"),
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
          IR::Assignment.new(target: index_ref, operator: "=", value: IR::IntegerLiteral.new(value: 0, type: @ctx.types.fetch("ptr_uint"))),
          IR::WhileStmt.new(
            condition: IR::Binary.new(operator: "<", left: index_ref, right: stop_value, type: @ctx.types.fetch("bool")),
            body: assign_items + body_stmts + [
              IR::Assignment.new(target: index_ref, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: @ctx.types.fetch("ptr_uint"))),
            ],
          ),
        ]
        stmts << IR::LabelStmt.new(name: break_label) if contains_label_target?(body_stmts, break_label)
        stmts
      end

      def lower_async_cf_match_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_linkage_name:, async_info:, active_defers:, loop_flow:)
        expr_setup, prepared_expr = prepare_expression_for_inline_lowering(statement.expression, env:)
        match_expr = lower_contextual_expression(prepared_expr, env:, expected_type: nil)
        match_type = infer_expression_type(statement.expression, env:)
        arm_loop_flow = switch_loop_flow(loop_flow, [])

        if match_type.is_a?(Types::Variant)
          if statement.arms.any? { |arm| arm.binding_name && !wildcard_arm_pattern?(arm.pattern) } &&
             !duplicable_foreign_argument_expression?(match_expr)
            scrutinee_linkage_name = fresh_c_temp_name(env, "match_value")
            expr_setup << IR::LocalDecl.new(name: scrutinee_linkage_name, linkage_name: scrutinee_linkage_name, type: match_type, value: match_expr)
            match_expr = IR::Name.new(name: scrutinee_linkage_name, type: match_type, pointer: false)
          end

          kind_type = @ctx.types.fetch("int")
          kind_expr = IR::Member.new(receiver: match_expr, member: "kind", type: kind_type)
          cases = statement.arms.map do |arm|
            arm_env, binding_decl = async_variant_match_arm_binding(arm, match_expr, match_type, env:, frame_expr:, local_fields: async_info[:local_fields])
            arm_body = if statements_contain_await?(arm.body, async_info)
                         lower_async_cf_statements(arm.body, env: arm_env, frame_expr:, raw_frame_expr:, resume_linkage_name:, async_info:, active_defers:, loop_flow: arm_loop_flow)
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
            lower_async_cf_statements(arm.body, env:, frame_expr:, raw_frame_expr:, resume_linkage_name:, async_info:, active_defers:, loop_flow: arm_loop_flow)
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
            linkage_name = c_local_name(statement.name)
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
            lowered << IR::LocalDecl.new(name: statement.name, linkage_name:, type: storage_type, value:)
            current_actual_scope(local_env[:scopes])[statement.name] = local_binding(type:, storage_type:, linkage_name:, mutable: statement.kind == :var, pointer: false)
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
                  left: IR::Name.new(name: linkage_name, type: storage_type, pointer: false),
                  right: IR::NullLiteral.new(type: storage_type),
                  type: @ctx.types.fetch("bool"),
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
                branch.condition, env: local_env, expected_type: @ctx.types.fetch("bool")
              )
              then_body = lower_async_non_await_statements(
                branch.body, env: local_env, frame_expr:, raw_frame_expr:, async_info:, active_defers: active_defers + local_defers, loop_flow: nested_loop_flow(loop_flow, local_defers)
              )
              [condition_setup, lower_expression(prepared_cond, env: local_env, expected_type: @ctx.types.fetch("bool")), then_body]
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
                scrutinee_linkage_name = fresh_c_temp_name(local_env, "match_value")
                lowered << IR::LocalDecl.new(name: scrutinee_linkage_name, linkage_name: scrutinee_linkage_name, type: scrutinee_type, value: expr)
                expr = IR::Name.new(name: scrutinee_linkage_name, type: scrutinee_type, pointer: false)
              end

              kind_type = @ctx.types.fetch("int")
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
          statement.condition, env:, expected_type: @ctx.types.fetch("bool")
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
        cond = lower_expression(prepared_cond, env:, expected_type: @ctx.types.fetch("bool"))

        if condition_setup.empty?
          stmts = [IR::WhileStmt.new(condition: cond, body:)]
          stmts << IR::LabelStmt.new(name: break_label) if contains_label_target?(body, break_label)
          return IR::BlockStmt.new(body: stmts)
        end

        loop_body = [
          *condition_setup,
          IR::IfStmt.new(
            condition: IR::Unary.new(operator: "not", operand: cond, type: @ctx.types.fetch("bool")),
            then_body: [loop_exit_statement(loop_exit_break(break_label), local_defers: [], outer_defers: [])],
            else_body: nil,
          ),
          *body,
        ]
        stmts = [IR::WhileStmt.new(condition: IR::BooleanLiteral.new(value: true, type: @ctx.types.fetch("bool")), body: loop_body)]
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
        index_linkage_name = c_local_name(statement.name)
        stop_linkage_name = fresh_c_temp_name(env, "for_stop")
        continue_label = fresh_c_temp_name(env, "loop_continue")
        break_label = fresh_c_temp_name(env, "loop_break")
        index_ref = IR::Name.new(name: index_linkage_name, type: loop_type, pointer: false)
        inline_stop = stop_setup.empty? && compile_time_numeric_const_expression?(prepared_stop)
        stop_value = if inline_stop
                       lower_expression(prepared_stop, env:, expected_type: loop_type)
                     else
                       IR::Name.new(name: stop_linkage_name, type: loop_type, pointer: false)
                     end

        while_env = duplicate_env(env)
        current_actual_scope(while_env[:scopes])[statement.name] = local_binding(
          type: loop_type, linkage_name: index_linkage_name, mutable: false, pointer: false
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
          init: IR::LocalDecl.new(name: statement.name, linkage_name: index_linkage_name, type: loop_type, value: lower_expression(prepared_start, env:, expected_type: loop_type)),
          condition: IR::Binary.new(operator: "<", left: index_ref, right: stop_value, type: @ctx.types.fetch("bool")),
          post: IR::Assignment.new(target: index_ref, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: loop_type)),
          body:,
        )

        stmts = [
          *start_setup,
          *stop_setup,
          *(inline_stop ? [] : [IR::LocalDecl.new(name: stop_linkage_name, linkage_name: stop_linkage_name, type: loop_type, value: lower_expression(prepared_stop, env:, expected_type: loop_type))]),
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
        iterable_linkage_name = fresh_c_temp_name(env, "for_items")
        index_linkage_name = fresh_c_temp_name(env, "for_index")
        continue_label = fresh_c_temp_name(env, "loop_continue")
        break_label = fresh_c_temp_name(env, "loop_break")
        iterable_ref = IR::Name.new(name: iterable_linkage_name, type: iterable_type, pointer: false)
        index_ref = IR::Name.new(name: index_linkage_name, type: @ctx.types.fetch("ptr_uint"), pointer: false)

        item_value = if array_type?(iterable_type)
                       IR::Index.new(receiver: iterable_ref, index: index_ref, type: element_type)
                     else
                       data_ref = IR::Member.new(receiver: iterable_ref, member: "data", type: pointer_to(element_type))
                       IR::Index.new(receiver: data_ref, index: index_ref, type: element_type)
                     end
        stop_value = if array_type?(iterable_type)
                       IR::IntegerLiteral.new(value: array_length(iterable_type), type: @ctx.types.fetch("ptr_uint"))
                     else
                       IR::Member.new(receiver: iterable_ref, member: "len", type: @ctx.types.fetch("ptr_uint"))
                     end

        while_env = duplicate_env(env)
        current_actual_scope(while_env[:scopes])[statement.name] = local_binding(
          type: element_type, linkage_name: c_local_name(statement.name), mutable: false, pointer: false
        )
        body = [IR::LocalDecl.new(name: statement.name, linkage_name: c_local_name(statement.name), type: element_type, value: item_value)]
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
          init: IR::LocalDecl.new(name: index_linkage_name, linkage_name: index_linkage_name, type: @ctx.types.fetch("ptr_uint"), value: IR::IntegerLiteral.new(value: 0, type: @ctx.types.fetch("ptr_uint"))),
          condition: IR::Binary.new(operator: "<", left: index_ref, right: stop_value, type: @ctx.types.fetch("bool")),
          post: IR::Assignment.new(target: index_ref, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: @ctx.types.fetch("ptr_uint"))),
          body:,
        )

        stmts = [
          *iterable_setup,
          IR::LocalDecl.new(name: iterable_linkage_name, linkage_name: iterable_linkage_name, type: iterable_type, value: lower_expression(prepared_iterable, env:, expected_type: iterable_type)),
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
          linkage_name = fresh_c_temp_name(env, "for_items")
          info.merge(
            setup:,
            prepared_iterable:,
            iterable_linkage_name: linkage_name,
            iterable_ref: IR::Name.new(name: linkage_name, type: info[:iterable_type], pointer: false),
          )
        end

        index_linkage_name = fresh_c_temp_name(env, "for_index")
        continue_label = fresh_c_temp_name(env, "loop_continue")
        break_label = fresh_c_temp_name(env, "loop_break")
        index_ref = IR::Name.new(name: index_linkage_name, type: @ctx.types.fetch("ptr_uint"), pointer: false)
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
          current_actual_scope(while_env[:scopes])[binding.name] = local_binding(type: entry[:binding_type], linkage_name: c_local_name(binding.name), mutable: false, pointer: false)
          IR::LocalDecl.new(name: binding.name, linkage_name: c_local_name(binding.name), type: entry[:binding_type], value: loop_item_value)
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
              type: @ctx.types.fetch("bool"),
            ),
            then_body: [lower_fatal_statement("parallel for iterables must have matching lengths", env:)],
            else_body: nil,
          )
        end

        for_statement = IR::ForStmt.new(
          init: IR::LocalDecl.new(name: index_linkage_name, linkage_name: index_linkage_name, type: @ctx.types.fetch("ptr_uint"), value: IR::IntegerLiteral.new(value: 0, type: @ctx.types.fetch("ptr_uint"))),
          condition: IR::Binary.new(operator: "<", left: index_ref, right: stop_value, type: @ctx.types.fetch("bool")),
          post: IR::Assignment.new(target: index_ref, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: @ctx.types.fetch("ptr_uint"))),
          body:,
        )

        stmts = [
          *iterable_entries.flat_map { |entry| entry[:setup] },
          *iterable_entries.map do |entry|
            IR::LocalDecl.new(name: entry[:iterable_linkage_name], linkage_name: entry[:iterable_linkage_name], type: entry[:iterable_type], value: lower_expression(entry[:prepared_iterable], env:, expected_type: entry[:iterable_type]))
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
          raise LoweringError, "foreign call used in assignment must return a value" if call_type == @ctx.types.fetch("void")
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
          lowered << IR::LocalDecl.new(name: rhs_name, linkage_name: rhs_name, type: target.type, value:)
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
          lowered << IR::ExpressionStmt.new(expression: lower_expression(prepared_expression, env:), line: statement.line, source_path: @ctx.current_analysis_path)
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

        if async_info[:result_type] != @ctx.types.fetch("void") && value && cleanup.any? && !cleanup_safe_return_expression?(prepared_value)
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

      def lower_async_await_statement(statement, await_info:, env:, frame_expr:, raw_frame_expr:, resume_linkage_name:, async_info:, field_info: nil, cleanup: [], active_defers: [], loop_flow: nil)
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
        ready_call = async_task_call(task_expr, await_info[:task_type], "ready", [task_frame_expr], @ctx.types.fetch("bool"))
        set_waiter_call = async_task_call(
          task_expr,
          await_info[:task_type],
          "set_waiter",
          [
            task_frame_expr,
            raw_frame_expr,
            IR::Name.new(name: resume_linkage_name, type: async_info[:wake_type], pointer: false),
          ],
          @ctx.types.fetch("void"),
        )
        take_result_call = async_task_call(task_expr, await_info[:task_type], "take_result", [task_frame_expr], await_info[:result_type])
        release_call = async_task_call(task_expr, await_info[:task_type], "release", [task_frame_expr], @ctx.types.fetch("void"))

        unless await_info[:reuse_existing_storage]
          lowered << IR::Assignment.new(
            target: task_expr,
            operator: "=",
            value: lower_contextual_expression(prepared_task, env:, expected_type: await_info[:task_type]),
          )
        end
        lowered << IR::IfStmt.new(
          condition: IR::Unary.new(operator: "not", operand: ready_call, type: @ctx.types.fetch("bool")),
          then_body: [
            IR::Assignment.new(
              target: async_frame_field_expression(frame_expr, "state", @ctx.types.fetch("int")),
              operator: "=",
              value: IR::IntegerLiteral.new(value: await_info[:state], type: @ctx.types.fetch("int")),
            ),
            IR::ExpressionStmt.new(expression: set_waiter_call),
            IR::ReturnStmt.new(value: nil),
          ],
          else_body: nil,
        )
        lowered << IR::LabelStmt.new(name: async_state_label(resume_linkage_name, await_info[:state]))

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
                linkage_name: async_frame_field_c_name(field_info[:field_name]),
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
                resume_linkage_name:,
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
          if await_info[:result_type] == @ctx.types.fetch("void")
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
              resume_linkage_name: async_info.fetch(:resume_linkage_name),
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

        if async_info[:result_type] != @ctx.types.fetch("void") && !result_already_stored
          lowered << IR::Assignment.new(
            target: async_frame_field_expression(frame_expr, "result", async_info[:result_type]),
            operator: "=",
            value: value,
          )
        end

        lowered << IR::Assignment.new(
          target: async_frame_field_expression(frame_expr, "ready", @ctx.types.fetch("bool")),
          operator: "=",
          value: IR::BooleanLiteral.new(value: true, type: @ctx.types.fetch("bool")),
        )

        waiter_frame_field = async_frame_field_expression(frame_expr, "waiter_frame", async_info[:void_ptr])
        lowered << IR::IfStmt.new(
          condition: IR::Binary.new(
            operator: "!=",
            left: waiter_frame_field,
            right: IR::NullLiteral.new(type: async_info[:void_ptr]),
            type: @ctx.types.fetch("bool"),
          ),
          then_body: [
            IR::LocalDecl.new(
              name: "waiter_frame",
              linkage_name: "__mt_waiter_frame",
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
                type: @ctx.types.fetch("void"),
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

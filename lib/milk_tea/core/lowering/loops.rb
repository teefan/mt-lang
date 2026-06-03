# frozen_string_literal: true

module MilkTea
  module LowererLoops
    private


      def lower_for_stmt(statement, env:, active_defers:, return_type:, allow_return:)
        return lower_parallel_collection_for_stmt(statement, env:, active_defers:, return_type:, allow_return:) if statement.parallel?
        return lower_range_for_stmt(statement, env:, active_defers:, return_type:, allow_return:) if range_iterable?(statement.iterable)

        iterable_type = infer_expression_type(statement.iterable, env:)
        return lower_iterator_for_stmt(statement, env:, active_defers:, return_type:, allow_return:) if collection_loop_type(iterable_type).nil?

        lower_collection_for_stmt(statement, env:, active_defers:, return_type:, allow_return:)
      end

      def lower_while_stmt(statement, env:, active_defers:, return_type:, allow_return:)
        continue_label = fresh_c_temp_name(env, "loop_continue")
        break_label = fresh_c_temp_name(env, "loop_break")
        condition_setup, prepared_condition, condition_cleanups = prepare_expression_with_cleanups(
          statement.condition,
          env:,
          expected_type: @types.fetch("bool"),
        )

        body = lower_block(
          statement.body,
          env: env_with_refinements(duplicate_env(env), flow_refinements(statement.condition, truthy: true, env: env)),
          active_defers:,
          return_type:,
          loop_flow: loop_flow(break_target: loop_exit_break(break_label), continue_target: loop_exit_continue(continue_label)),
          allow_return:,
        )
        body << IR::LabelStmt.new(name: continue_label) if contains_label_target?(body, continue_label)

        condition = lower_expression(prepared_condition, env:, expected_type: @types.fetch("bool"))

        if condition_setup.empty? && condition_cleanups.empty?
          statements = [
            IR::WhileStmt.new(
              condition:,
              body:,
            ),
          ]
          statements << IR::LabelStmt.new(name: break_label) if contains_label_target?(body, break_label)
          return IR::BlockStmt.new(body: statements)
        end

        loop_body = [
          *condition_setup,
          IR::IfStmt.new(
            condition: IR::Unary.new(operator: "not", operand: condition, type: @types.fetch("bool")),
            then_body: condition_cleanups.flat_map(&:itself) + [loop_exit_statement(loop_exit_break(break_label), local_defers: [], outer_defers: [])],
            else_body: condition_cleanups.flat_map(&:itself),
          ),
          *body,
        ]

        statements = [
          IR::WhileStmt.new(
            condition: IR::BooleanLiteral.new(value: true, type: @types.fetch("bool")),
            body: loop_body,
          ),
        ]
        statements << IR::LabelStmt.new(name: break_label) if contains_label_target?(loop_body, break_label)

        IR::BlockStmt.new(body: statements)
      end

      def lower_range_for_stmt(statement, env:, active_defers:, return_type:, allow_return:)
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
        current_actual_scope(while_env[:scopes])[statement.name] = local_binding(type: loop_type, c_name: c_local_name(statement.name), mutable: false, pointer: false)

        body = []
        body.concat(
          lower_block(
            statement.body,
            env: while_env,
            active_defers:,
            return_type:,
            loop_flow: loop_flow(break_target: loop_exit_break(break_label), continue_target: loop_exit_continue(continue_label)),
            allow_return:,
          ),
        )
        body << IR::LabelStmt.new(name: continue_label) if contains_label_target?(body, continue_label)

        for_statement = IR::ForStmt.new(
          init: IR::LocalDecl.new(name: statement.name, c_name: index_c_name, type: loop_type, value: lower_expression(prepared_start, env:, expected_type: loop_type)),
          condition: IR::Binary.new(operator: "<", left: index_ref, right: stop_value, type: @types.fetch("bool")),
          post: IR::Assignment.new(
            target: index_ref,
            operator: "+=",
            value: IR::IntegerLiteral.new(value: 1, type: loop_type),
          ),
          body:,
        )

        statements = [
          *start_setup,
          *stop_setup,
          for_statement,
        ]
        unless inline_stop
          statements.insert(
            statements.length - 1,
            IR::LocalDecl.new(name: stop_c_name, c_name: stop_c_name, type: loop_type, value: lower_expression(prepared_stop, env:, expected_type: loop_type)),
          )
        end
        statements << IR::LabelStmt.new(name: break_label) if contains_label_target?(body, break_label)

        IR::BlockStmt.new(body: statements)
      end

      def lower_collection_for_stmt(statement, env:, active_defers:, return_type:, allow_return:)
        iterable_type = infer_expression_type(statement.iterable, env:)
        element_type = collection_loop_type(iterable_type)
        raise LoweringError, "for loop expects start..stop, array[T, N], span[T], or an iterable with iter()/next(), got #{iterable_type}" unless element_type
        iterable_setup, prepared_iterable = prepare_expression_for_inline_lowering(statement.iterable, env:, expected_type: iterable_type)
        binding_type = collection_loop_binding_type(iterable_type, element_type) || element_type

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

        loop_item_value = if ref_type?(binding_type)
                            IR::AddressOf.new(expression: item_value, type: binding_type)
                          else
                            item_value
                          end

        while_env = duplicate_env(env)
        current_actual_scope(while_env[:scopes])[statement.name] = local_binding(type: binding_type, c_name: c_local_name(statement.name), mutable: false, pointer: false)

        body = [
          IR::LocalDecl.new(name: statement.name, c_name: c_local_name(statement.name), type: binding_type, value: loop_item_value),
        ]
        body.concat(
          lower_block(
            statement.body,
            env: while_env,
            active_defers:,
            return_type:,
            loop_flow: loop_flow(break_target: loop_exit_break(break_label), continue_target: loop_exit_continue(continue_label)),
            allow_return:,
          ),
        )
        body << IR::LabelStmt.new(name: continue_label) if contains_label_target?(body, continue_label)

        for_statement = IR::ForStmt.new(
          init: IR::LocalDecl.new(name: index_c_name, c_name: index_c_name, type: @types.fetch("ptr_uint"), value: IR::IntegerLiteral.new(value: 0, type: @types.fetch("ptr_uint"))),
          condition: IR::Binary.new(operator: "<", left: index_ref, right: stop_value, type: @types.fetch("bool")),
          post: IR::Assignment.new(
            target: index_ref,
            operator: "+=",
            value: IR::IntegerLiteral.new(value: 1, type: @types.fetch("ptr_uint")),
          ),
          body:,
        )

        statements = [
          *iterable_setup,
          IR::LocalDecl.new(name: iterable_c_name, c_name: iterable_c_name, type: iterable_type, value: lower_expression(prepared_iterable, env:, expected_type: iterable_type)),
          for_statement,
        ]
        statements << IR::LabelStmt.new(name: break_label) if contains_label_target?(body, break_label)

        IR::BlockStmt.new(body: statements)
      end

      def lower_parallel_collection_for_stmt(statement, env:, active_defers:, return_type:, allow_return:)
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
        body.concat(
          lower_block(
            statement.body,
            env: while_env,
            active_defers:,
            return_type:,
            loop_flow: loop_flow(break_target: loop_exit_break(break_label), continue_target: loop_exit_continue(continue_label)),
            allow_return:,
          ),
        )
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
          post: IR::Assignment.new(
            target: index_ref,
            operator: "+=",
            value: IR::IntegerLiteral.new(value: 1, type: @types.fetch("ptr_uint")),
          ),
          body:,
        )

        statements = [
          *iterable_entries.flat_map { |entry| entry[:setup] },
          *iterable_entries.map do |entry|
            IR::LocalDecl.new(
              name: entry[:iterable_c_name],
              c_name: entry[:iterable_c_name],
              type: entry[:iterable_type],
              value: lower_expression(entry[:prepared_iterable], env:, expected_type: entry[:iterable_type]),
            )
          end,
          *length_checks,
          for_statement,
        ]
        statements << IR::LabelStmt.new(name: break_label) if contains_label_target?(body, break_label)

        IR::BlockStmt.new(body: statements)
      end

      def lower_iterator_for_stmt(statement, env:, active_defers:, return_type:, allow_return:)
        iterable_type = infer_expression_type(statement.iterable, env:)
        iterator_info = iterator_loop_info(iterable_type, env:)
        raise LoweringError, "for loop expects start..stop, array[T, N], span[T], or an iterable with iter()/next(), got #{iterable_type}" unless iterator_info

        iterable_setup, prepared_iterable = prepare_expression_for_inline_lowering(statement.iterable, env:, expected_type: iterable_type)
        iterator_c_name = fresh_c_temp_name(env, "for_iterator")
        iterator_name = iterator_c_name
        continue_label = fresh_c_temp_name(env, "loop_continue")
        break_label = fresh_c_temp_name(env, "loop_break")

        iter_call = AST::Call.new(
          callee: AST::MemberAccess.new(receiver: prepared_iterable, member: "iter"),
          arguments: [],
        )

        iterator_env = duplicate_env(env)
        current_actual_scope(iterator_env[:scopes])[iterator_name] = local_binding(
          type: iterator_info[:iterator_type],
          c_name: iterator_c_name,
          mutable: true,
          pointer: false,
        )

        loop_env = duplicate_env(iterator_env)
        current_actual_scope(loop_env[:scopes])[statement.name] = local_binding(
          type: iterator_info[:item_type],
          storage_type: iterator_info[:item_storage_type],
          c_name: c_local_name(statement.name),
          mutable: false,
          pointer: false,
        )

        next_call = AST::Call.new(
          callee: AST::MemberAccess.new(receiver: AST::Identifier.new(name: iterator_name), member: "next"),
          arguments: [],
        )

        body = if iterator_info[:kind] == :nullable_item
                 item_ref = IR::Name.new(name: c_local_name(statement.name), type: iterator_info[:item_storage_type], pointer: false)
                 [
                   IR::LocalDecl.new(
                     name: statement.name,
                     c_name: c_local_name(statement.name),
                     type: iterator_info[:item_storage_type],
                     value: lower_expression(next_call, env: iterator_env, expected_type: iterator_info[:item_storage_type]),
                   ),
                   IR::IfStmt.new(
                     condition: IR::Binary.new(
                       operator: "==",
                       left: item_ref,
                       right: IR::NullLiteral.new(type: iterator_info[:item_storage_type]),
                       type: @types.fetch("bool"),
                     ),
                     then_body: [loop_exit_statement(loop_exit_break(break_label), local_defers: [], outer_defers: [])],
                     else_body: nil,
                   ),
                 ]
               else
                 ready_c_name = fresh_c_temp_name(env, "for_ready")
                 ready_ref = IR::Name.new(name: ready_c_name, type: @types.fetch("bool"), pointer: false)
                 current_call = AST::Call.new(
                   callee: AST::MemberAccess.new(receiver: AST::Identifier.new(name: iterator_name), member: "current"),
                   arguments: [],
                 )
                 [
                   IR::LocalDecl.new(
                     name: ready_c_name,
                     c_name: ready_c_name,
                     type: @types.fetch("bool"),
                     value: lower_expression(next_call, env: iterator_env, expected_type: @types.fetch("bool")),
                   ),
                   IR::IfStmt.new(
                     condition: IR::Unary.new(operator: "not", operand: ready_ref, type: @types.fetch("bool")),
                     then_body: [loop_exit_statement(loop_exit_break(break_label), local_defers: [], outer_defers: [])],
                     else_body: nil,
                   ),
                   IR::LocalDecl.new(
                     name: statement.name,
                     c_name: c_local_name(statement.name),
                     type: iterator_info[:item_storage_type],
                     value: lower_expression(current_call, env: iterator_env, expected_type: iterator_info[:item_storage_type]),
                   ),
                 ]
               end
        body.concat(
          lower_block(
            statement.body,
            env: loop_env,
            active_defers:,
            return_type:,
            loop_flow: loop_flow(break_target: loop_exit_break(break_label), continue_target: loop_exit_continue(continue_label)),
            allow_return:,
          ),
        )
        body << IR::LabelStmt.new(name: continue_label) if contains_label_target?(body, continue_label)

        statements = [
          *iterable_setup,
          IR::LocalDecl.new(
            name: iterator_name,
            c_name: iterator_c_name,
            type: iterator_info[:iterator_type],
            value: lower_expression(iter_call, env:, expected_type: iterator_info[:iterator_type]),
          ),
          IR::WhileStmt.new(
            condition: IR::BooleanLiteral.new(value: true, type: @types.fetch("bool")),
            body:,
          ),
        ]
        statements << IR::LabelStmt.new(name: break_label) if contains_label_target?(body, break_label)

        IR::BlockStmt.new(body: statements)
      end

      def lower_range_index_assignment(statement, env:)
        range = statement.target.index
        start_val = range.start_expr.value
        receiver_type = infer_expression_type(statement.target.receiver, env:)
        element_type = infer_index_result_type(receiver_type, @types.fetch("ptr_uint"))

        receiver_setup, prepared_receiver = prepare_expression_for_inline_lowering(statement.target.receiver, env:, expected_type: receiver_type)
        statements = receiver_setup.dup

        statement.value.elements.each_with_index do |elem, i|
          index_ir = IR::IntegerLiteral.new(value: start_val + i, type: @types.fetch("ptr_uint"))
          target_ir = IR::Index.new(
            receiver: lower_expression(prepared_receiver, env:, expected_type: receiver_type),
            index: index_ir,
            type: element_type,
          )
          value_ir = lower_contextual_expression(
            elem,
            env:,
            expected_type: element_type,
            contextual_int_to_float: contextual_int_to_float_target?(element_type),
          )
          statements << IR::Assignment.new(target: target_ir, operator: "=", value: value_ir)
        end

        statements
      end

  end
end

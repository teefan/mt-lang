# frozen_string_literal: true

module MilkTea
  module LowererLoops
    private


      def lower_for_stmt(statement, env:, active_defers:, return_type:, allow_return:)
        return lower_threaded_for_stmt(statement, env:, active_defers:) if statement.threaded
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
          expected_type: @ctx.types.fetch("bool"),
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

        condition = lower_expression(prepared_condition, env:, expected_type: @ctx.types.fetch("bool"))

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
            condition: IR::Unary.new(operator: "not", operand: condition, type: @ctx.types.fetch("bool")),
            then_body: condition_cleanups.flat_map(&:itself) + [loop_exit_statement(loop_exit_break(break_label), local_defers: [], outer_defers: [])],
            else_body: condition_cleanups.flat_map(&:itself),
          ),
          *body,
        ]

        statements = [
          IR::WhileStmt.new(
            condition: IR::BooleanLiteral.new(value: true, type: @ctx.types.fetch("bool")),
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
        current_actual_scope(while_env[:scopes])[statement.name] = local_binding(type: loop_type, linkage_name: c_local_name(statement.name), mutable: false, pointer: false)

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
          init: IR::LocalDecl.new(name: statement.name, linkage_name: index_linkage_name, type: loop_type, value: lower_expression(prepared_start, env:, expected_type: loop_type)),
          condition: IR::Binary.new(operator: "<", left: index_ref, right: stop_value, type: @ctx.types.fetch("bool")),
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
            IR::LocalDecl.new(name: stop_linkage_name, linkage_name: stop_linkage_name, type: loop_type, value: lower_expression(prepared_stop, env:, expected_type: loop_type)),
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

        loop_item_value = if ref_type?(binding_type)
                            IR::AddressOf.new(expression: item_value, type: binding_type)
                          else
                            item_value
                          end

        while_env = duplicate_env(env)
        current_actual_scope(while_env[:scopes])[statement.name] = local_binding(type: binding_type, linkage_name: c_local_name(statement.name), mutable: false, pointer: false)

        body = [
          IR::LocalDecl.new(name: statement.name, linkage_name: c_local_name(statement.name), type: binding_type, value: loop_item_value),
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
          init: IR::LocalDecl.new(name: index_linkage_name, linkage_name: index_linkage_name, type: @ctx.types.fetch("ptr_uint"), value: IR::IntegerLiteral.new(value: 0, type: @ctx.types.fetch("ptr_uint"))),
          condition: IR::Binary.new(operator: "<", left: index_ref, right: stop_value, type: @ctx.types.fetch("bool")),
          post: IR::Assignment.new(
            target: index_ref,
            operator: "+=",
            value: IR::IntegerLiteral.new(value: 1, type: @ctx.types.fetch("ptr_uint")),
          ),
          body:,
        )

        statements = [
          *iterable_setup,
          IR::LocalDecl.new(name: iterable_linkage_name, linkage_name: iterable_linkage_name, type: iterable_type, value: lower_expression(prepared_iterable, env:, expected_type: iterable_type)),
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
              type: @ctx.types.fetch("bool"),
            ),
            then_body: [lower_fatal_statement("parallel for iterables must have matching lengths", env:)],
            else_body: nil,
          )
        end

        for_statement = IR::ForStmt.new(
          init: IR::LocalDecl.new(name: index_linkage_name, linkage_name: index_linkage_name, type: @ctx.types.fetch("ptr_uint"), value: IR::IntegerLiteral.new(value: 0, type: @ctx.types.fetch("ptr_uint"))),
          condition: IR::Binary.new(operator: "<", left: index_ref, right: stop_value, type: @ctx.types.fetch("bool")),
          post: IR::Assignment.new(
            target: index_ref,
            operator: "+=",
            value: IR::IntegerLiteral.new(value: 1, type: @ctx.types.fetch("ptr_uint")),
          ),
          body:,
        )

        statements = [
          *iterable_entries.flat_map { |entry| entry[:setup] },
          *iterable_entries.map do |entry|
            IR::LocalDecl.new(
              name: entry[:iterable_linkage_name],
              linkage_name: entry[:iterable_linkage_name],
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
          linkage_name: iterator_c_name,
          mutable: true,
          pointer: false,
        )

        loop_env = duplicate_env(iterator_env)
        current_actual_scope(loop_env[:scopes])[statement.name] = local_binding(
          type: iterator_info[:item_type],
          storage_type: iterator_info[:item_storage_type],
          linkage_name: c_local_name(statement.name),
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
                     linkage_name: c_local_name(statement.name),
                     type: iterator_info[:item_storage_type],
                     value: lower_expression(next_call, env: iterator_env, expected_type: iterator_info[:item_storage_type]),
                   ),
                   IR::IfStmt.new(
                     condition: IR::Binary.new(
                       operator: "==",
                       left: item_ref,
                       right: IR::NullLiteral.new(type: iterator_info[:item_storage_type]),
                       type: @ctx.types.fetch("bool"),
                     ),
                     then_body: [loop_exit_statement(loop_exit_break(break_label), local_defers: [], outer_defers: [])],
                     else_body: nil,
                   ),
                 ]
               else
                 ready_linkage_name = fresh_c_temp_name(env, "for_ready")
                 ready_ref = IR::Name.new(name: ready_linkage_name, type: @ctx.types.fetch("bool"), pointer: false)
                 current_call = AST::Call.new(
                   callee: AST::MemberAccess.new(receiver: AST::Identifier.new(name: iterator_name), member: "current"),
                   arguments: [],
                 )
                 [
                   IR::LocalDecl.new(
                     name: ready_linkage_name,
                     linkage_name: ready_linkage_name,
                     type: @ctx.types.fetch("bool"),
                     value: lower_expression(next_call, env: iterator_env, expected_type: @ctx.types.fetch("bool")),
                   ),
                   IR::IfStmt.new(
                     condition: IR::Unary.new(operator: "not", operand: ready_ref, type: @ctx.types.fetch("bool")),
                     then_body: [loop_exit_statement(loop_exit_break(break_label), local_defers: [], outer_defers: [])],
                     else_body: nil,
                   ),
                   IR::LocalDecl.new(
                     name: statement.name,
                     linkage_name: c_local_name(statement.name),
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
            linkage_name: iterator_c_name,
            type: iterator_info[:iterator_type],
            value: lower_expression(iter_call, env:, expected_type: iterator_info[:iterator_type]),
          ),
          IR::WhileStmt.new(
            condition: IR::BooleanLiteral.new(value: true, type: @ctx.types.fetch("bool")),
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
        element_type = infer_index_result_type(receiver_type, @ctx.types.fetch("ptr_uint"))

        receiver_setup, prepared_receiver = prepare_expression_for_inline_lowering(statement.target.receiver, env:, expected_type: receiver_type)
        statements = receiver_setup.dup

        statement.value.elements.each_with_index do |elem, i|
          index_ir = IR::IntegerLiteral.new(value: start_val + i, type: @ctx.types.fetch("ptr_uint"))
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

      def lower_threaded_for_stmt(statement, env:, active_defers:)
        loop_type = infer_range_loop_type(statement.iterable, env:)
        start_expr_ast = range_start_of(statement.iterable)
        stop_expr_ast = range_end_of(statement.iterable)
        start_setup, _ = prepare_expression_for_inline_lowering(start_expr_ast, env:, expected_type: loop_type)
        stop_setup, prepared_stop = prepare_expression_for_inline_lowering(stop_expr_ast, env:, expected_type: loop_type)

        lowered_stop = lower_expression(prepared_stop, env:, expected_type: loop_type)
        index_linkage_name = c_local_name(statement.name)

        body_env = duplicate_env(env)
        current_actual_scope(body_env[:scopes])[statement.name] = local_binding(
          type: loop_type, linkage_name: index_linkage_name, mutable: false, pointer: false,
        )

        body = lower_block(
          statement.body,
          env: body_env,
          active_defers:,
          return_type: @ctx.types.fetch("void"),
          loop_flow: nil,
          allow_return: false,
        )

        @parallel_for_counter += 1
        uid = "#{@ctx.module_prefix}_pfor_#{@parallel_for_counter}".gsub(/[^A-Za-z0-9_]/, "_")
        cap_struct_c_name = "mt_pfor_cap_#{uid}"
        worker_c_name = "mt_pfor_work_#{uid}"

        all_names = {}
        body.each { |s| collect_pfor_ir_names_stmt(s, all_names) }
        local_decls = Set.new
        body.each { |s| collect_pfor_local_decls(s, local_decls) }
        excluded = Set.new(local_decls.to_a + [index_linkage_name])
        captures = all_names.values.reject { |n| excluded.include?(n.name) }

        validate_pfor_no_ref_captures!(captures)

        void_type = @ctx.types.fetch("void")
        void_ptr_type = Types::GenericInstance.new("ptr", [void_type])
        long_type = @ctx.types.fetch("long")

        array_capture_names = Set.new
        cap_fields = captures.map do |c|
          if array_type?(c.type)
            array_capture_names << c.name
            elem = array_element_type(c.type)
            IR::Field.new(name: c.name, type: Types::GenericInstance.new("ptr", [elem]))
          else
            IR::Field.new(name: c.name, type: c.type)
          end
        end
        @artifacts.synthetic_structs << IR::StructDecl.new(
          name: cap_struct_c_name, linkage_name: cap_struct_c_name,
          fields: cap_fields, packed: false, alignment: nil,
        )

        cap_ptr_type = Types::GenericInstance.new("ptr", [Types::Struct.new(cap_struct_c_name)])
        cap_name_ir = IR::Name.new(name: "mt_cap", type: cap_ptr_type, pointer: true)
        worker_body = [
          IR::LocalDecl.new(
            name: "mt_cap", linkage_name: "mt_cap", type: cap_ptr_type,
            value: IR::Cast.new(
              target_type: cap_ptr_type,
              expression: IR::Name.new(name: "mt_pfor_data", type: void_ptr_type, pointer: false),
              type: cap_ptr_type,
            ),
          ),
        ]
        captures.each do |c|
          alias_type = if array_capture_names.include?(c.name)
                         Types::GenericInstance.new("ptr", [array_element_type(c.type)])
                       else
                         c.type
                       end
          worker_body << IR::LocalDecl.new(
            name: c.name, linkage_name: c.name, type: alias_type,
            value: IR::Member.new(receiver: cap_name_ir, member: c.name, type: alias_type),
          )
        end

        body = rewrite_pfor_array_captures(body, array_capture_names) unless array_capture_names.empty?

        loop_var_ref = IR::Name.new(name: index_linkage_name, type: loop_type, pointer: false)
        worker_body << IR::ForStmt.new(
          init: IR::LocalDecl.new(
            name: index_linkage_name, linkage_name: index_linkage_name, type: loop_type,
            value: IR::Name.new(name: "mt_pfor_start", type: long_type, pointer: false),
          ),
          condition: IR::Binary.new(
            operator: "<",
            left: loop_var_ref,
            right: IR::Name.new(name: "mt_pfor_end", type: long_type, pointer: false),
            type: @ctx.types.fetch("bool"),
          ),
          post: IR::Assignment.new(
            target: loop_var_ref,
            operator: "+=",
            value: IR::IntegerLiteral.new(value: 1, type: loop_type),
          ),
          body:,
        )

        @artifacts.synthetic_functions << IR::Function.new(
          name: worker_c_name, linkage_name: worker_c_name,
          params: [
            IR::Param.new(name: "mt_pfor_data", linkage_name: "mt_pfor_data", type: void_ptr_type, pointer: false),
            IR::Param.new(name: "mt_pfor_start", linkage_name: "mt_pfor_start", type: long_type, pointer: false),
            IR::Param.new(name: "mt_pfor_end", linkage_name: "mt_pfor_end", type: long_type, pointer: false),
          ],
          return_type: void_type,
          body: worker_body,
          entry_point: false,
        )

        cap_struct_type = Types::Struct.new(cap_struct_c_name, linkage_name: cap_struct_c_name).tap do |s|
          s.define_fields(captures.each_with_object({}) do |c, h|
            h[c.name] = if array_capture_names.include?(c.name)
                          Types::GenericInstance.new("ptr", [array_element_type(c.type)])
                        else
                          c.type
                        end
          end)
        end
        cap_local_name = "mt_pfor_cap"
        cap_init = IR::AggregateLiteral.new(
          type: cap_struct_type,
          fields: captures.map do |c|
            if array_capture_names.include?(c.name)
              elem = array_element_type(c.type)
              ptr_type = Types::GenericInstance.new("ptr", [elem])
              IR::AggregateField.new(name: c.name, value: IR::Name.new(name: c.name, type: ptr_type, pointer: false))
            else
              IR::AggregateField.new(name: c.name, value: c)
            end
          end,
        )

        worker_fn_type = Types::Function.new(nil, params: [], return_type: void_type)
        call_site = [
          IR::LocalDecl.new(name: cap_local_name, linkage_name: cap_local_name, type: cap_struct_type, value: cap_init),
          IR::ExpressionStmt.new(expression: IR::Call.new(
            callee: "mt_parallel_for",
            arguments: [
              IR::Name.new(name: worker_c_name, type: worker_fn_type, pointer: false),
              IR::AddressOf.new(
                expression: IR::Name.new(name: cap_local_name, type: cap_struct_type, pointer: false),
                type: void_ptr_type,
              ),
              lowered_stop,
            ],
            type: void_type,
          )),
        ]

        IR::BlockStmt.new(body: [*start_setup, *stop_setup, *call_site])
      end

      def lower_parallel_block_stmt(statement, env:, active_defers:)
        void_type = @ctx.types.fetch("void")
        void_ptr_type = Types::GenericInstance.new("ptr", [void_type])

        @parallel_for_counter += 1
        uid_base = "#{@ctx.module_prefix}_spawn_#{@parallel_for_counter}".gsub(/[^A-Za-z0-9_]/, "_")

        block_infos = statement.bodies.each_with_index.map do |body, idx|
          block_body = lower_block(
            body,
            env: duplicate_env(env),
            active_defers:,
            return_type: void_type,
            loop_flow: nil,
            allow_return: false,
          )

          all_names = {}
          block_body.each { |s| collect_pfor_ir_names_stmt(s, all_names) }
          local_decls = Set.new
          block_body.each { |s| collect_pfor_local_decls(s, local_decls) }
          captures = all_names.values.reject { |n| local_decls.include?(n.name) }

          validate_pfor_no_ref_captures!(captures)
          written_names = collect_pfor_written_names(block_body, captures)
          captureless = captures.empty?

          cap_struct_c_name = "mt_spawn_cap_#{uid_base}_#{idx}"
          worker_c_name = "mt_spawn_work_#{uid_base}_#{idx}"

          if captureless
            worker_body = block_body.dup
          else
            array_capture_names = Set.new
            cap_fields = captures.map do |c|
              if array_type?(c.type)
                array_capture_names << c.name
                IR::Field.new(name: c.name, type: Types::GenericInstance.new("ptr", [array_element_type(c.type)]))
              else
                IR::Field.new(name: c.name, type: c.type)
              end
            end

            @artifacts.synthetic_structs << IR::StructDecl.new(
              name: cap_struct_c_name, linkage_name: cap_struct_c_name,
              fields: cap_fields, packed: false, alignment: nil,
            )

            cap_ptr_type = Types::GenericInstance.new("ptr", [Types::Struct.new(cap_struct_c_name)])
            cap_name_ir = IR::Name.new(name: "mt_cap", type: cap_ptr_type, pointer: true)
            worker_body = [
              IR::LocalDecl.new(
                name: "mt_cap", linkage_name: "mt_cap", type: cap_ptr_type,
                value: IR::Cast.new(
                  target_type: cap_ptr_type,
                  expression: IR::Name.new(name: "mt_pfor_data", type: void_ptr_type, pointer: false),
                  type: cap_ptr_type,
                ),
              ),
            ]
            captures.each do |c|
              alias_type = if array_capture_names.include?(c.name)
                             Types::GenericInstance.new("ptr", [array_element_type(c.type)])
                           else
                             c.type
                           end
              worker_body << IR::LocalDecl.new(
                name: c.name, linkage_name: c.name, type: alias_type,
                value: IR::Member.new(receiver: cap_name_ir, member: c.name, type: alias_type),
              )
            end

            rewritten_body = array_capture_names.empty? ? block_body : rewrite_pfor_array_captures(block_body, array_capture_names)
            worker_body.concat(rewritten_body)
          end

          @artifacts.synthetic_functions << IR::Function.new(
            name: worker_c_name, linkage_name: worker_c_name,
            params: [IR::Param.new(name: "mt_pfor_data", linkage_name: "mt_pfor_data", type: void_ptr_type, pointer: false)],
            return_type: void_type,
            body: worker_body,
            entry_point: false,
          )

          cap_struct_type = if captureless
                              void_ptr_type
                            else
                              Types::Struct.new(cap_struct_c_name, linkage_name: cap_struct_c_name).tap do |s|
                                s.define_fields(captures.each_with_object({}) do |c, h|
                                  h[c.name] = if array_capture_names.include?(c.name)
                                                Types::GenericInstance.new("ptr", [array_element_type(c.type)])
                                              else
                                                c.type
                                              end
                                end)
                              end
                            end
          cap_local_name = "mt_spawn_cap_#{idx}"
          cap_init = if captureless
                       IR::IntegerLiteral.new(value: 0, type: void_ptr_type)
                     else
                       IR::AggregateLiteral.new(
                         type: cap_struct_type,
                         fields: captures.map do |c|
                           if array_capture_names.include?(c.name)
                             elem = array_element_type(c.type)
                             ptr_type = Types::GenericInstance.new("ptr", [elem])
                             IR::AggregateField.new(name: c.name, value: IR::Name.new(name: c.name, type: ptr_type, pointer: false))
                           else
                             IR::AggregateField.new(name: c.name, value: c)
                           end
                         end,
                       )
                     end

          { worker_c_name:, cap_local_name:, cap_struct_type:, cap_init:, capture_names: Set.new(captures.map(&:name)), written_names:, captureless: }
        end

        validate_pfor_write_conflicts!(block_infos)

        fn_type = Types::Function.new(nil, params: [], return_type: void_type)
        spawn_item_type = Types::Struct.new("mt_spawn_item", linkage_name: "mt_spawn_item").tap do |s|
          s.define_fields({ "work" => fn_type, "data" => void_ptr_type })
        end

        call_site = []
        block_infos.each do |info|
          unless info[:captureless]
            call_site << IR::LocalDecl.new(
              name: info[:cap_local_name], linkage_name: info[:cap_local_name],
              type: info[:cap_struct_type], value: info[:cap_init],
            )
          end
        end

        tasks_local = "mt_spawn_tasks"
        tasks_count = block_infos.length
        tasks_array_type = Types::GenericInstance.new("array", [spawn_item_type, Types::LiteralTypeArg.new(tasks_count)])
        tasks_init = IR::ArrayLiteral.new(
          type: tasks_array_type,
          elements: block_infos.map { |info|
            data_expr = if info[:captureless]
                          IR::IntegerLiteral.new(value: 0, type: void_ptr_type)
                        else
                          IR::AddressOf.new(
                            expression: IR::Name.new(name: info[:cap_local_name], type: info[:cap_struct_type], pointer: false),
                            type: void_ptr_type,
                          )
                        end
            IR::AggregateLiteral.new(
              type: spawn_item_type,
              fields: [
                IR::AggregateField.new(name: "work", value: IR::Name.new(name: info[:worker_c_name], type: fn_type, pointer: false)),
                IR::AggregateField.new(name: "data", value: data_expr),
              ],
            )
          },
        )
        call_site << IR::LocalDecl.new(name: tasks_local, linkage_name: tasks_local, type: tasks_array_type, value: tasks_init)
        call_site << IR::ExpressionStmt.new(expression: IR::Call.new(
          callee: "mt_spawn_all",
          arguments: [
            IR::Name.new(name: tasks_local, type: tasks_array_type, pointer: false),
            IR::IntegerLiteral.new(value: tasks_count, type: @ctx.types.fetch("int")),
          ],
          type: void_type,
        ))

        IR::BlockStmt.new(body: call_site)
      end

      def lower_gather_stmt(statement, env:)
        call_site = statement.handles.map do |handle_expr|
          handle_ir = lower_expression(handle_expr, env:)
          IR::ExpressionStmt.new(expression: IR::Call.new(
            callee: "mt_detach_join",
            arguments: [handle_ir],
            type: @ctx.types.fetch("void"),
          ))
        end
        IR::BlockStmt.new(body: call_site)
      end

      def lower_detach_expr(expression, env:)
        @parallel_for_counter += 1
        uid = "#{@ctx.module_prefix}_detach_#{@parallel_for_counter}".gsub(/[^A-Za-z0-9_]/, "_")
        worker_c_name = "mt_detach_work_#{uid}"

        block_body = lower_block(
          expression.body,
          env: duplicate_env(env),
          active_defers: nil,
          return_type: @ctx.types.fetch("void"),
          loop_flow: nil,
          allow_return: false,
        )

        all_names = {}
        block_body.each { |s| collect_pfor_ir_names_stmt(s, all_names) }
        local_decls = Set.new
        block_body.each { |s| collect_pfor_local_decls(s, local_decls) }
        captures = all_names.values.reject { |n| local_decls.include?(n.name) }
        validate_pfor_no_ref_captures!(captures)

        if captures.empty?
          worker_body = block_body.dup
        else
          raise LoweringError, "detach with captured variables is not yet supported; use a global function call or module-level variables"
        end

        @artifacts.synthetic_functions << IR::Function.new(
          name: worker_c_name, linkage_name: worker_c_name,
          params: [IR::Param.new(name: "mt_pfor_data", linkage_name: "mt_pfor_data", type: @ctx.types.fetch("void").then { |v| Types::GenericInstance.new("ptr", [v]) }, pointer: false)],
          return_type: @ctx.types.fetch("void"),
          body: worker_body,
          entry_point: false,
        )

        void_ptr_type = Types::GenericInstance.new("ptr", [@ctx.types.fetch("void")])
        IR::Call.new(
          callee: "mt_detach_run",
          arguments: [
            IR::Name.new(name: worker_c_name, type: Types::Function.new(nil, params: [], return_type: @ctx.types.fetch("void")), pointer: false),
            IR::IntegerLiteral.new(value: 0, type: void_ptr_type),
          ],
          type: void_ptr_type,
        )
      end

      def validate_pfor_no_ref_captures!(captures)
        captures.each do |c|
          raise LoweringError, "cannot capture '#{c.name}' of type ref across thread boundary — ref values are not safe to share across threads" if ref_type?(c.type)
        end
      end

      def validate_pfor_write_conflicts!(block_infos)
        block_infos.each_with_index do |info, idx|
          info[:written_names].each do |name|
            block_infos.each_with_index do |other, other_idx|
              next if idx == other_idx
              next unless other[:capture_names].include?(name)

              raise LoweringError, "write conflict in parallel block: '#{name}' is written in spawn block #{idx + 1} and accessed in spawn block #{other_idx + 1}"
            end
          end
        end
      end

      def collect_pfor_written_names(stmts, captures)
        capture_names = Set.new(captures.map(&:name))
        written = Set.new
        stmts.each { |s| collect_pfor_written_stmt(s, capture_names, written) }
        written
      end

      def collect_pfor_written_stmt(stmt, capture_names, written)
        case stmt
        when IR::Assignment
          base = pfor_assignment_base_name(stmt.target)
          written << base if base && capture_names.include?(base)
        when IR::IfStmt
          stmt.then_body.each { |s| collect_pfor_written_stmt(s, capture_names, written) }
          stmt.else_body&.each { |s| collect_pfor_written_stmt(s, capture_names, written) }
        when IR::WhileStmt
          stmt.body.each { |s| collect_pfor_written_stmt(s, capture_names, written) }
        when IR::ForStmt
          stmt.body.each { |s| collect_pfor_written_stmt(s, capture_names, written) }
        when IR::BlockStmt
          stmt.body.each { |s| collect_pfor_written_stmt(s, capture_names, written) }
        when IR::SwitchStmt
          stmt.cases.each { |c| c.body.each { |s| collect_pfor_written_stmt(s, capture_names, written) } }
        end
      end

      def pfor_assignment_base_name(expr)
        case expr
        when IR::Name
          expr.name
        when IR::Member
          pfor_assignment_base_name(expr.receiver)
        when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex, IR::NullableIndex, IR::NullableSpanIndex
          pfor_assignment_base_name(expr.receiver)
        when IR::AddressOf
          pfor_assignment_base_name(expr.expression)
        else
          nil
        end
      end

      def rewrite_pfor_array_captures(stmts, array_names)
        stmts.map { |s| rewrite_pfor_stmt(s, array_names) }
      end

      def rewrite_pfor_stmt(stmt, array_names)
        case stmt
        when IR::Assignment
          IR::Assignment.new(
            target: rewrite_pfor_expr(stmt.target, array_names),
            operator: stmt.operator,
            value: rewrite_pfor_expr(stmt.value, array_names),
          )
        when IR::LocalDecl
          stmt.value ? IR::LocalDecl.new(name: stmt.name, linkage_name: stmt.linkage_name, type: stmt.type, value: rewrite_pfor_expr(stmt.value, array_names), line: stmt.line, source_path: stmt.source_path) : stmt
        when IR::ExpressionStmt
          IR::ExpressionStmt.new(expression: rewrite_pfor_expr(stmt.expression, array_names), line: stmt.line, source_path: stmt.source_path)
        when IR::IfStmt
          IR::IfStmt.new(
            condition: rewrite_pfor_expr(stmt.condition, array_names),
            then_body: rewrite_pfor_array_captures(stmt.then_body, array_names),
            else_body: stmt.else_body ? rewrite_pfor_array_captures(stmt.else_body, array_names) : nil,
          )
        when IR::ForStmt
          IR::ForStmt.new(
            init: stmt.init ? rewrite_pfor_stmt(stmt.init, array_names) : nil,
            condition: stmt.condition ? rewrite_pfor_expr(stmt.condition, array_names) : nil,
            post: stmt.post ? rewrite_pfor_stmt(stmt.post, array_names) : nil,
            body: rewrite_pfor_array_captures(stmt.body, array_names),
          )
        when IR::WhileStmt
          IR::WhileStmt.new(
            condition: rewrite_pfor_expr(stmt.condition, array_names),
            body: rewrite_pfor_array_captures(stmt.body, array_names),
          )
        when IR::BlockStmt
          IR::BlockStmt.new(body: rewrite_pfor_array_captures(stmt.body, array_names))
        when IR::SwitchStmt
          IR::SwitchStmt.new(
            expression: rewrite_pfor_expr(stmt.expression, array_names),
            cases: stmt.cases.map { |c| IR::SwitchCase.new(value: c.value, body: rewrite_pfor_array_captures(c.body, array_names)) },
            exhaustive: stmt.exhaustive,
          )
        when IR::ReturnStmt
          stmt.value ? IR::ReturnStmt.new(value: rewrite_pfor_expr(stmt.value, array_names), line: stmt.line, source_path: stmt.source_path) : stmt
        else
          stmt
        end
      end

      def rewrite_pfor_expr(expr, array_names)
        case expr
        when IR::CheckedIndex
          if expr.receiver.is_a?(IR::AddressOf) &&
             expr.receiver.expression.is_a?(IR::Name) &&
             array_names.include?(expr.receiver.expression.name)
            name_node = expr.receiver.expression
            elem = array_element_type(name_node.type) if array_type?(name_node.type)
            ptr_type = elem ? Types::GenericInstance.new("ptr", [elem]) : name_node.type
            IR::Index.new(
              receiver: IR::Name.new(name: name_node.name, type: ptr_type, pointer: false),
              index: rewrite_pfor_expr(expr.index, array_names),
              type: expr.type,
            )
          else
            expr
          end
        when IR::Binary
          IR::Binary.new(operator: expr.operator, left: rewrite_pfor_expr(expr.left, array_names), right: rewrite_pfor_expr(expr.right, array_names), type: expr.type)
        when IR::Unary
          IR::Unary.new(operator: expr.operator, operand: rewrite_pfor_expr(expr.operand, array_names), type: expr.type)
        when IR::Cast
          IR::Cast.new(target_type: expr.target_type, expression: rewrite_pfor_expr(expr.expression, array_names), type: expr.type)
        when IR::Call
          IR::Call.new(
            callee: expr.callee.is_a?(String) ? expr.callee : rewrite_pfor_expr(expr.callee, array_names),
            arguments: expr.arguments.map { |a| rewrite_pfor_expr(a, array_names) },
            type: expr.type,
          )
        when IR::AddressOf
          IR::AddressOf.new(expression: rewrite_pfor_expr(expr.expression, array_names), type: expr.type)
        when IR::Conditional
          IR::Conditional.new(
            condition: rewrite_pfor_expr(expr.condition, array_names),
            then_expression: rewrite_pfor_expr(expr.then_expression, array_names),
            else_expression: rewrite_pfor_expr(expr.else_expression, array_names),
            type: expr.type,
          )
        when IR::Member
          IR::Member.new(receiver: rewrite_pfor_expr(expr.receiver, array_names), member: expr.member, type: expr.type)
        when IR::Index
          IR::Index.new(receiver: rewrite_pfor_expr(expr.receiver, array_names), index: rewrite_pfor_expr(expr.index, array_names), type: expr.type)
        when IR::AggregateLiteral
          IR::AggregateLiteral.new(type: expr.type, fields: expr.fields.map { |f| IR::AggregateField.new(name: f.name, value: rewrite_pfor_expr(f.value, array_names)) })
        else
          expr
        end
      end

      def collect_pfor_ir_names_stmt(stmt, result)
        case stmt
        when IR::LocalDecl
          collect_pfor_ir_names_expr(stmt.value, result) if stmt.value
        when IR::Assignment
          collect_pfor_ir_names_expr(stmt.target, result)
          collect_pfor_ir_names_expr(stmt.value, result)
        when IR::ExpressionStmt
          collect_pfor_ir_names_expr(stmt.expression, result)
        when IR::ReturnStmt
          collect_pfor_ir_names_expr(stmt.value, result) if stmt.value
        when IR::IfStmt
          collect_pfor_ir_names_expr(stmt.condition, result)
          stmt.then_body.each { |s| collect_pfor_ir_names_stmt(s, result) }
          stmt.else_body&.each { |s| collect_pfor_ir_names_stmt(s, result) }
        when IR::WhileStmt
          collect_pfor_ir_names_expr(stmt.condition, result)
          stmt.body.each { |s| collect_pfor_ir_names_stmt(s, result) }
        when IR::ForStmt
          collect_pfor_ir_names_stmt(stmt.init, result) if stmt.init
          collect_pfor_ir_names_expr(stmt.condition, result) if stmt.condition
          collect_pfor_ir_names_stmt(stmt.post, result) if stmt.post.is_a?(IR::Assignment) || stmt.post.is_a?(IR::ExpressionStmt)
          stmt.body.each { |s| collect_pfor_ir_names_stmt(s, result) }
        when IR::BlockStmt
          stmt.body.each { |s| collect_pfor_ir_names_stmt(s, result) }
        when IR::SwitchStmt
          collect_pfor_ir_names_expr(stmt.expression, result)
          stmt.cases.each { |c| c.body.each { |s| collect_pfor_ir_names_stmt(s, result) } }
        end
      end

      def collect_pfor_ir_names_expr(expr, result)
        case expr
        when IR::Name
          result[expr.name] = expr unless result.key?(expr.name)
        when IR::Member
          collect_pfor_ir_names_expr(expr.receiver, result)
        when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex, IR::NullableIndex, IR::NullableSpanIndex
          collect_pfor_ir_names_expr(expr.receiver, result)
          collect_pfor_ir_names_expr(expr.index, result)
        when IR::Call
          collect_pfor_ir_names_expr(expr.callee, result)
          expr.arguments.each { |a| collect_pfor_ir_names_expr(a, result) }
        when IR::Binary
          collect_pfor_ir_names_expr(expr.left, result)
          collect_pfor_ir_names_expr(expr.right, result)
        when IR::Unary
          collect_pfor_ir_names_expr(expr.operand, result)
        when IR::Cast
          collect_pfor_ir_names_expr(expr.expression, result)
        when IR::AddressOf
          collect_pfor_ir_names_expr(expr.expression, result)
        when IR::Conditional
          collect_pfor_ir_names_expr(expr.condition, result)
          collect_pfor_ir_names_expr(expr.then_expression, result)
          collect_pfor_ir_names_expr(expr.else_expression, result)
        when IR::AggregateLiteral
          expr.fields.each { |f| collect_pfor_ir_names_expr(f.value, result) }
        when IR::ArrayLiteral
          expr.elements.each { |e| collect_pfor_ir_names_expr(e, result) }
        when IR::ReinterpretExpr
          collect_pfor_ir_names_expr(expr.expression, result)
        end
      end

      def collect_pfor_local_decls(stmt, decls)
        case stmt
        when IR::LocalDecl
          decls << stmt.linkage_name
        when IR::ForStmt
          decls << stmt.init.linkage_name if stmt.init.is_a?(IR::LocalDecl)
          stmt.body.each { |s| collect_pfor_local_decls(s, decls) }
        when IR::BlockStmt
          stmt.body.each { |s| collect_pfor_local_decls(s, decls) }
        when IR::IfStmt
          stmt.then_body.each { |s| collect_pfor_local_decls(s, decls) }
          stmt.else_body&.each { |s| collect_pfor_local_decls(s, decls) }
        when IR::WhileStmt
          stmt.body.each { |s| collect_pfor_local_decls(s, decls) }
        when IR::SwitchStmt
          stmt.cases.each { |c| c.body.each { |s| collect_pfor_local_decls(s, decls) } }
        end
      end

  end
end

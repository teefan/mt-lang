# frozen_string_literal: true

module MilkTea
  module LowererBlock
    private


      def lower_block(statements, env:, active_defers:, return_type:, loop_flow:, allow_return: true)
        local_env = duplicate_env(env)
        lowered = []
        local_defers = []
        local_env[:return_context] = {
          return_type:,
          active_defers:,
          local_defers:,
          allow_return:,
        }

        statements.each do |statement|
          case statement
          when AST::DeferStmt
            local_defers << if statement.body
                              lower_defer_cleanup_body(statement.body, env: local_env, return_type:)
                            else
                              lower_defer_cleanup_expression(statement.expression, env: local_env)
                            end
          when AST::UnsafeStmt
            body = lower_block(
              statement.body,
              env: local_env,
              active_defers: active_defers + local_defers,
              return_type:,
              loop_flow: nested_loop_flow(loop_flow, local_defers),
              allow_return:,
            )
            lowered << IR::BlockStmt.new(body:)
          when AST::LocalDecl
            if statement.destructure_bindings
              lower_destructure_decl(statement, env: local_env, lowered:, local_defers:, active_defers:, return_type:, loop_flow:, allow_return:)
              next
            end

            storage_type = if statement.else_body
                              infer_expression_type(statement.value, env: local_env)
                            elsif statement.type
                              resolve_type_ref(statement.type)
                            else
                              infer_expression_type(statement.value, env: local_env)
                            end
            type = if statement.else_body
                     statement.type ? resolve_type_ref(statement.type) : let_else_success_type(storage_type)
                   else
                     storage_type
                   end
            c_name = let_else_storage_c_name(statement, local_env)
            decl_name = bind_let_else_local?(statement) ? statement.name : c_name
            prepared_setup = []
            prepared_value = statement.value
            prepared_cleanups = []
            emitted_decl = false
            if statement.value
              local_env[:current_local_name] = c_name
              prepared_setup, prepared_value, prepared_cleanups = prepare_expression_with_cleanups(
                statement.value,
                env: local_env,
                expected_type: storage_type,
                allow_root_statement_foreign: true,
                materialize_array_calls: !array_type?(storage_type),
              )
              lowered.concat(prepared_setup)
            end
            if prepared_value && (foreign_call = foreign_call_info(prepared_value, local_env))
              setup, value, call_type, release_assignments, cleanup_statements = lower_foreign_call_components(
                foreign_call,
                env: local_env,
                expected_type: storage_type,
                statement_position: false,
              )
              lowered.concat(setup)
              raise LoweringError, "foreign call used to initialize #{statement.name} must return a value" if call_type == @ctx.types.fetch("void")
              raise LoweringError, "consuming foreign calls must return void" unless release_assignments.empty?

              lowered << IR::LocalDecl.new(name: decl_name, c_name:, type: storage_type, value:, line: statement.line, source_path: @ctx.current_analysis_path)
              lowered.concat(cleanup_statements)
              emitted_decl = true
            elsif prepared_value.is_a?(AST::ProcExpr)
              setup, value = lower_proc_expression_for_local(prepared_value, env: local_env, local_name: statement.name, proc_type: storage_type)
              lowered.concat(setup)
            elsif prepared_value
              value = lower_contextual_expression(
                prepared_value,
                env: local_env,
                expected_type: storage_type,
                contextual_int_to_float: statement.type && contextual_int_to_float_target?(type),
              )
            else
              value = IR::ZeroInit.new(type: storage_type)
            end
            if bind_let_else_local?(statement)
              current_actual_scope(local_env[:scopes])[statement.name] = local_binding(
                type:,
                storage_type:,
                c_name:,
                mutable: statement.kind == :var,
                pointer: false,
                projection: statement.else_body ? let_else_binding_projection(storage_type) : nil,
                cstr_backed: cstr_backed_storage_value?(storage_type, prepared_value, local_env),
                cstr_list_backed: cstr_list_backed_storage_value?(storage_type, prepared_value, local_env),
                const_value: statement.else_body ? nil : statement.kind == :let && prepared_value ? compile_time_const_value(prepared_value, env: local_env) : nil,
              )
            end
            lowered << IR::LocalDecl.new(name: decl_name, c_name:, type: storage_type, value:, line: statement.line, source_path: @ctx.current_analysis_path) unless emitted_decl
            if statement.else_body
              else_env = if statement.else_binding
                           duplicate_env(local_env).tap do |env_with_error|
                             current_actual_scope(env_with_error[:scopes])[statement.else_binding.name] = local_binding(
                               type: let_else_error_type(storage_type),
                               storage_type:,
                               c_name:,
                               mutable: false,
                               pointer: false,
                               projection: :result_failure_error,
                             )
                           end
                         else
                           local_env
                         end
              else_body = lower_block(
                statement.else_body,
                env: else_env,
                active_defers: active_defers + local_defers + prepared_cleanups,
                return_type:,
                loop_flow: nested_loop_flow(loop_flow, local_defers),
                allow_return:,
              )
              local_ref = IR::Name.new(name: c_name, type: storage_type, pointer: false)
              lowered << IR::IfStmt.new(
                condition: let_else_failure_condition(local_ref, storage_type),
                then_body: else_body,
                else_body: nil,
              )
            end
            local_defers.concat(prepared_cleanups)
            if contains_proc_storage_type?(storage_type)
              local_value = IR::Name.new(name: c_name, type: storage_type, pointer: false)
              # Use guarded release so zero-initialized var locals are safe (invoke == NULL guard).
              local_defers << lower_proc_contained_guarded_release_statements(local_value, storage_type)
              if statement.value && !expression_contains_proc_expr?(statement.value)
                lowered.concat(lower_proc_contained_retain_statements(local_value, storage_type))
              end
            end
          when AST::Assignment
            if statement.operator == "=" &&
               statement.target.is_a?(AST::IndexAccess) &&
               statement.target.index.is_a?(AST::RangeExpr) &&
               statement.value.is_a?(AST::ExpressionList)
              lowered.concat(lower_range_index_assignment(statement, env: local_env))
              next
            end
            target = lower_assignment_target(statement.target, env: local_env)
            prepared_cleanups = []
            prepared_setup, prepared_value, prepared_cleanups = prepare_expression_with_cleanups(
              statement.value,
              env: local_env,
              expected_type: target.type,
              allow_root_statement_foreign: true,
              materialize_array_calls: !array_type?(target.type),
            )
            lowered.concat(prepared_setup)
            if (foreign_call = foreign_call_info(prepared_value, local_env))
              setup, value, call_type, release_assignments, cleanup_statements = lower_foreign_call_components(
                foreign_call,
                env: local_env,
                expected_type: target.type,
                statement_position: false,
              )
              lowered.concat(setup)
              raise LoweringError, "foreign call used in assignment must return a value" if call_type == @ctx.types.fetch("void")
              raise LoweringError, "consuming foreign calls must return void" unless release_assignments.empty?

              lowered << IR::Assignment.new(target:, operator: statement.operator, value:)
              lowered.concat(cleanup_statements)
              update_cstr_metadata_for_assignment!(statement, prepared_value, local_env)
              local_defers.concat(prepared_cleanups)
              next
            else
              value = if statement.operator == "="
                        lower_contextual_expression(
                          prepared_value,
                          env: local_env,
                          expected_type: target.type,
                          external_numeric: external_numeric_assignment_target?(statement.target, env: local_env),
                          contextual_int_to_float: contextual_int_to_float_target?(target.type),
                        )
                      elsif ["+=", "-=", "*=", "/="].include?(statement.operator)
                        lower_contextual_expression(
                          prepared_value,
                          env: local_env,
                          expected_type: target.type,
                          contextual_int_to_float: contextual_int_to_float_target?(target.type),
                        )
                      else
                        lower_expression(prepared_value, env: local_env, expected_type: target.type)
                      end
            end
            update_cstr_metadata_for_assignment!(statement, prepared_value, local_env)
            local_defers.concat(prepared_cleanups)
            if statement.operator == "=" && contains_proc_storage_type?(target.type)
              # Materialize the RHS to a C temp to avoid evaluating aggregate literals multiple times
              # and to ensure retain/release operate on a stable struct value throughout the sequence.
              rhs_name = fresh_c_temp_name(local_env, "proc_assign")
              lowered << IR::LocalDecl.new(name: rhs_name, c_name: rhs_name, type: target.type, value:)
              rhs = IR::Name.new(name: rhs_name, type: target.type, pointer: false)
              # Retain proc fields in the incoming value that are NOT from fresh proc expressions
              # (fresh proc exprs carry refcount=1 and transfer ownership; existing procs need +1).
              lowered.concat(lower_proc_selective_retain_statements(rhs, statement.value, target.type))
              # Release old proc fields in the target (guarded: target may be zero-initialized).
              lowered.concat(lower_proc_contained_guarded_release_statements(target, target.type))
              lowered << IR::Assignment.new(target:, operator: "=", value: rhs)
            else
              lowered << IR::Assignment.new(target:, operator: statement.operator, value:)
            end
          when AST::IfStmt
            if statement.inline
              lowered.concat(lower_inline_if_stmt(statement, env: local_env, active_defers:, return_type:, allow_return:))
              next
            end

            false_refinements = {}
            branch_entries = []

            statement.branches.each do |branch|
              branch_env = env_with_refinements(local_env, false_refinements)
              condition_setup, prepared_condition, condition_cleanups = prepare_expression_with_cleanups(
                branch.condition,
                env: branch_env,
                expected_type: @ctx.types.fetch("bool"),
              )
              true_refinements = merge_refinements(false_refinements, flow_refinements(branch.condition, truthy: true, env: branch_env))

              branch_entries << [
                condition_setup,
                condition_cleanups,
                lower_expression(prepared_condition, env: branch_env, expected_type: @ctx.types.fetch("bool")),
                lower_block(
                  branch.body,
                  env: env_with_refinements(local_env, true_refinements),
                  active_defers: active_defers + local_defers,
                  return_type:,
                  loop_flow: nested_loop_flow(loop_flow, local_defers),
                  allow_return:,
                ),
              ]

              false_refinements = merge_refinements(false_refinements, flow_refinements(branch.condition, truthy: false, env: branch_env))
            end

            nested_else_body = statement.else_body ? lower_block(
              statement.else_body,
              env: env_with_refinements(local_env, false_refinements),
              active_defers: active_defers + local_defers,
              return_type:,
              loop_flow: nested_loop_flow(loop_flow, local_defers),
              allow_return:,
            ) : []

            nested_if = nested_else_body
            branch_entries.reverse_each do |condition_setup, condition_cleanups, condition, then_body|
              condition_cleanup_statements = condition_cleanups.flat_map(&:itself)
              nested_if = [
                *condition_setup,
                IR::IfStmt.new(
                  condition:,
                  then_body: condition_cleanup_statements + then_body,
                  else_body: condition_cleanup_statements + nested_if,
                ),
              ]
            end
            lowered.concat(nested_if)

            merge_cstr_metadata_after_if_statement!(statement, local_env)

            if statement.else_body.nil? && statement.branches.all? { |branch| cfg_block_always_terminates?(branch.body) }
              local_env[:scopes] = scopes_with_refinements(local_env[:scopes], false_refinements)
            end
          when AST::MatchStmt
            if statement.inline
              lowered.concat(lower_inline_match_stmt(statement, env: local_env, active_defers:, return_type:, allow_return:))
            else
            scrutinee_type = infer_expression_type(statement.expression, env: local_env)
            expression_setup, prepared_expression, expression_cleanups = prepare_expression_with_cleanups(
              statement.expression,
              env: local_env,
              expected_type: scrutinee_type,
            )
            lowered.concat(expression_setup)
            expression = lower_expression(prepared_expression, env: local_env, expected_type: scrutinee_type)

            if scrutinee_type.is_a?(Types::Variant) &&
               statement.arms.any? { |arm| arm.binding_name && !wildcard_arm_pattern?(arm.pattern) } &&
               !duplicable_foreign_argument_expression?(expression)
              scrutinee_c_name = fresh_c_temp_name(local_env, "match_value")
              lowered << IR::LocalDecl.new(name: scrutinee_c_name, c_name: scrutinee_c_name, type: scrutinee_type, value: expression)
              expression = IR::Name.new(name: scrutinee_c_name, type: scrutinee_type, pointer: false)
            end

            if scrutinee_type.is_a?(Types::Variant)
              if statement.arms.any? { |arm| arm.pattern.is_a?(AST::Call) }
                kind_type = @ctx.types.fetch("int")
                arm_loop_flow = switch_loop_flow(loop_flow, local_defers)
                @match_label_counter ||= 0
                @match_label_counter += 1
                m = @match_label_counter
                match_end_label = "__mt_match_#{m}_end"
                arm_next_label = "__mt_match_#{m}_arm_next"

                statement.arms.each_with_index do |arm, arm_index|
                  arm_local_env = duplicate_env(local_env)
                  arm_name = variant_match_arm_name_from_pattern(arm.pattern) unless wildcard_arm_pattern?(arm.pattern)

                  # Emit label for all arms except the first (catches previous arm's goto)
                  if arm_index > 0
                    lowered << IR::LabelStmt.new(name: "__mt_match_#{m}_arm_#{arm_index}")
                  end

                  if arm_name && !wildcard_arm_pattern?(arm.pattern)
                    tag_value = IR::Name.new(name: enum_member_c_name(scrutinee_type, "kind_#{arm_name}"), type: kind_type, pointer: false)
                    tag_expr = IR::Member.new(receiver: expression, member: "kind", type: kind_type)
                    goto_label = if arm_index < statement.arms.length - 1
                                   "__mt_match_#{m}_arm_#{arm_index + 1}"
                                 else
                                   arm_next_label
                                 end
                    tag_check = IR::Binary.new(operator: "!=", left: tag_expr, right: tag_value, type: @ctx.types.fetch("bool"))
                    lowered << IR::IfStmt.new(condition: tag_check, then_body: [IR::GotoStmt.new(label: goto_label)], else_body: [])
                  end

                  if arm_name && !wildcard_arm_pattern?(arm.pattern) && scrutinee_type.has_payload?(arm_name)
                    fields = scrutinee_type.arm(arm_name)
                    payload_type = Types::VariantArmPayload.new(scrutinee_type, arm_name, fields)
                    data_expr = IR::Member.new(receiver: expression, member: "data", type: nil)
                    arm_expr = IR::Member.new(receiver: data_expr, member: arm_name, type: payload_type)
                    payload_c_name = fresh_c_temp_name(arm_local_env, "match_payload")
                    arm_local_env[:scopes].last["__mt_payload"] = local_binding(type: payload_type, c_name: payload_c_name, mutable: true, pointer: false)

                    arm_body_ir = []
                    arm_body_ir << IR::LocalDecl.new(name: payload_c_name, c_name: payload_c_name, type: payload_type, value: arm_expr)

                    nested_struct_fields = nil
                    nested_struct_c_name = nil
                    nested_struct_type = nil
                    if fields.size == 1 && fields.values.first.is_a?(Types::Struct)
                      nested_struct_type = fields.values.first
                      nested_struct_fields = nested_struct_type.fields
                      single_field_name = fields.keys.first
                      nested_struct_c_name = fresh_c_temp_name(arm_local_env, "match_struct")
                      struct_expr = IR::Member.new(
                        receiver: IR::Name.new(name: payload_c_name, type: payload_type, pointer: false),
                        member: single_field_name,
                        type: nested_struct_type,
                      )
                      arm_body_ir << IR::LocalDecl.new(name: nested_struct_c_name, c_name: nested_struct_c_name, type: nested_struct_type, value: struct_expr)
                    end

                    if arm.pattern.is_a?(AST::Call) && !arm.pattern.arguments.empty?
                      pattern_fields = nested_struct_fields || fields
                      pattern_receiver_name = nested_struct_c_name || payload_c_name
                      pattern_receiver_type = nested_struct_type || payload_type

                      # Phase 1: Emit guard / equality checks (goto next arm on failure)
                      arm.pattern.arguments.each do |arg|
                        # Guard: hp > 0
                        if !arg.name && arg.value.is_a?(AST::BinaryOp) && arg.value.left.is_a?(AST::Identifier)
                          field_name = arg.value.left.name
                          next unless pattern_fields.key?(field_name)

                          field_type = pattern_fields[field_name]
                          field_expr = IR::Member.new(receiver: IR::Name.new(name: pattern_receiver_name, type: pattern_receiver_type, pointer: false), member: field_name, type: field_type)
                          rhs_expr = lower_expression(arg.value.right, env: arm_local_env, expected_type: field_type)
                          guard_condition = IR::Binary.new(operator: arg.value.operator, left: field_expr, right: rhs_expr, type: @ctx.types.fetch("bool"))
                          arm_body_ir << IR::IfStmt.new(condition: guard_condition, then_body: [], else_body: [IR::GotoStmt.new(label: goto_label)])
                        end

                        # Equality: kind = Kind.boss
                        if arg.name
                          field_name = arg.name
                          next unless pattern_fields.key?(field_name)

                          field_type = pattern_fields[field_name]
                          field_expr = IR::Member.new(receiver: IR::Name.new(name: pattern_receiver_name, type: pattern_receiver_type, pointer: false), member: field_name, type: field_type)
                          value_expr = lower_expression(arg.value, env: arm_local_env, expected_type: field_type)
                          eq_check = IR::Binary.new(operator: "!=", left: field_expr, right: value_expr, type: @ctx.types.fetch("bool"))
                          arm_body_ir << IR::IfStmt.new(condition: eq_check, then_body: [IR::GotoStmt.new(label: goto_label)], else_body: [])
                        end
                      end

                      # Phase 2: Emit bindings (bare identifiers)
                      arm.pattern.arguments.each do |arg|
                        next if arg.name
                        next unless arg.value.is_a?(AST::Identifier)

                        field_name = arg.value.name
                        next unless pattern_fields.key?(field_name)

                        field_type = pattern_fields[field_name]
                        binding_c = c_local_name(field_name)
                        field_expr = IR::Member.new(receiver: IR::Name.new(name: pattern_receiver_name, type: pattern_receiver_type, pointer: false), member: field_name, type: field_type)
                        arm_body_ir << IR::LocalDecl.new(name: binding_c, c_name: binding_c, type: field_type, value: field_expr)
                        arm_local_env[:scopes].last[field_name] = local_binding(type: field_type, c_name: binding_c, mutable: false, pointer: false)
                      end
                    end

                    # Handle as-binding
                    if arm.binding_name && !wildcard_arm_pattern?(arm.pattern)
                      binding_c = c_local_name(arm.binding_name)
                      if arm_name && scrutinee_type.has_payload?(arm_name)
                        payload_key = "__mt_payload"
                        if arm_local_env[:scopes].last.key?(payload_key)
                          payload_binding = arm_local_env[:scopes].last[payload_key]
                          arm_local_env[:scopes].last[arm.binding_name] = local_binding(type: payload_binding[:type], c_name: binding_c, mutable: true, pointer: false)
                          payload_ref = IR::Name.new(name: payload_binding[:c_name], type: payload_binding[:type], pointer: false)
                          arm_body_ir << IR::LocalDecl.new(name: arm.binding_name, c_name: binding_c, type: payload_binding[:type], value: payload_ref)
                        end
                      end
                    end

                    body = lower_block(
                      arm.body,
                      env: arm_local_env,
                      active_defers: active_defers + local_defers,
                      return_type:,
                      loop_flow: arm_loop_flow,
                      allow_return:,
                    )
                    arm_body_ir.concat(body)
                    arm_body_ir << IR::GotoStmt.new(label: match_end_label)

                    lowered << IR::BlockStmt.new(body: arm_body_ir)
                  else
                    body = lower_block(
                      arm.body,
                      env: arm_local_env,
                      active_defers: active_defers + local_defers,
                      return_type:,
                      loop_flow: arm_loop_flow,
                      allow_return:,
                    )
                    lowered << IR::BlockStmt.new(body: body + [IR::GotoStmt.new(label: match_end_label)])
                  end
                end

                lowered << IR::LabelStmt.new(name: arm_next_label)
                lowered << IR::LabelStmt.new(name: match_end_label)
              else
              kind_type = @ctx.types.fetch("int")
              kind_expr = IR::Member.new(receiver: expression, member: "kind", type: kind_type)
              arm_loop_flow = switch_loop_flow(loop_flow, local_defers)
              cases = statement.arms.map do |arm|
                arm_local_env = duplicate_env(local_env)
                binding_decl = if arm.binding_name && !wildcard_arm_pattern?(arm.pattern)
                                 arm_name = variant_match_arm_name_from_pattern(arm.pattern)
                                 if arm_name && scrutinee_type.has_payload?(arm_name)
                                   fields = scrutinee_type.arm(arm_name)
                                   payload_type = Types::VariantArmPayload.new(scrutinee_type, arm_name, fields)
                                   data_expr = IR::Member.new(receiver: expression, member: "data", type: nil)
                                   arm_expr = IR::Member.new(receiver: data_expr, member: arm_name, type: payload_type)
                                   binding_c = c_local_name(arm.binding_name)
                                    arm_local_env[:scopes].last[arm.binding_name] = local_binding(type: payload_type, c_name: binding_c, mutable: true, pointer: false)
                                   IR::LocalDecl.new(name: arm.binding_name, c_name: binding_c, type: payload_type, value: arm_expr)
                                 end
                               end
                body = lower_block(
                  arm.body,
                  env: arm_local_env,
                  active_defers: active_defers + local_defers,
                  return_type:,
                  loop_flow: arm_loop_flow,
                  allow_return:,
                )
                body = [binding_decl, *body].compact if binding_decl
                if wildcard_arm_pattern?(arm.pattern)
                  IR::SwitchDefaultCase.new(body:)
                else
                  arm_name = variant_match_arm_name_from_pattern(arm.pattern)
                  IR::SwitchCase.new(value: IR::Name.new(name: enum_member_c_name(scrutinee_type, "kind_#{arm_name}"), type: kind_type, pointer: false), body:)
                end
              end
              lowered << IR::SwitchStmt.new(expression: kind_expr, cases:, exhaustive: true)
              end  # inner if/else for struct patterns
            else
              arm_loop_flow = switch_loop_flow(loop_flow, local_defers)
              cases = statement.arms.map do |arm|
                body = lower_block(
                  arm.body,
                  env: local_env,
                  active_defers: active_defers + local_defers,
                  return_type:,
                  loop_flow: arm_loop_flow,
                  allow_return:,
                )
                if wildcard_arm_pattern?(arm.pattern)
                  IR::SwitchDefaultCase.new(body:)
                else
                  value = lower_expression(arm.pattern, env: local_env, expected_type: scrutinee_type)
                  IR::SwitchCase.new(value:, body:)
                end
              end
              lowered << IR::SwitchStmt.new(expression:, cases:, exhaustive: true)
            end
            lowered.concat(expression_cleanups.flat_map(&:itself))
            end
          when AST::StaticAssert
            lowered << lower_static_assert(statement, env: local_env)
          when AST::ForStmt
            if statement.inline
              lowered.concat(lower_inline_for_stmt(statement, env: local_env, active_defers:, return_type:, allow_return:))
            else
              lowered << lower_for_stmt(statement, env: local_env, active_defers: active_defers + local_defers, return_type:, allow_return:)
            end
          when AST::ParallelBlockStmt
            lowered << lower_parallel_block_stmt(statement, env: local_env, active_defers: active_defers + local_defers)
          when AST::GatherStmt
            lowered << lower_gather_stmt(statement, env: local_env)
          when AST::WhileStmt
            if statement.inline
              lowered.concat(lower_inline_while_stmt(statement, env: local_env, active_defers:, return_type:, allow_return:))
            else
              lowered << lower_while_stmt(statement, env: local_env, active_defers: active_defers + local_defers, return_type:, allow_return:)
            end
          when AST::PassStmt
            nil
          when AST::BreakStmt
            raise LoweringError, "break must be inside a loop" unless loop_flow

            lowered.concat(lower_loop_exit(loop_flow[:break_target], local_defers, loop_flow[:break_defers]))
          when AST::ContinueStmt
            raise LoweringError, "continue must be inside a loop" unless loop_flow

            lowered.concat(lower_loop_exit(loop_flow[:continue_target], local_defers, loop_flow[:continue_defers]))
          when AST::ReturnStmt
            raise LoweringError, "return is not allowed inside defer blocks" unless allow_return

            value = nil
            prepared_setup = []
            prepared_value = statement.value
            prepared_cleanups = []
            if statement.value
              local_env[:current_local_name] = c_name
              prepared_setup, prepared_value, prepared_cleanups = prepare_expression_with_cleanups(
                statement.value,
                env: local_env,
                expected_type: return_type,
                allow_root_statement_foreign: true,
                materialize_array_calls: !array_type?(return_type),
              )
              lowered.concat(prepared_setup)
            end
            if prepared_value && (foreign_call = foreign_call_info(prepared_value, local_env))
              setup, value = lower_foreign_call_statement(foreign_call, env: local_env, expected_type: return_type, statement_position: false)
              lowered.concat(setup)
            end
            value ||= prepared_value ? lower_contextual_expression(
              prepared_value,
              env: local_env,
              expected_type: return_type,
              contextual_int_to_float: contextual_int_to_float_target?(return_type),
            ) : nil
            if prepared_cleanups.any? && cstr_trackable_type?(return_type)
              raise LoweringError, "formatted string temporaries cannot be returned as borrowed text; use std.fmt.format(f\"...\") when ownership must escape"
            end

            cleanup = prepared_cleanups.flat_map(&:itself) + cleanup_statements(local_defers, active_defers)
            needs_proc_retain = value && contains_proc_storage_type?(return_type) && !local_defers.empty? && !expression_contains_proc_expr?(prepared_value)
            if value && (!cleanup.empty? && !cleanup_safe_return_expression?(prepared_value) || needs_proc_retain)
              return_value_name = fresh_c_temp_name(local_env, "return_value")
              lowered << IR::LocalDecl.new(name: return_value_name, c_name: return_value_name, type: return_type, value:)
              value = IR::Name.new(name: return_value_name, type: return_type, pointer: false)
            end
            lowered.concat(lower_proc_contained_retain_statements(value, return_type)) if needs_proc_retain
            lowered.concat(cleanup)
            lowered << IR::ReturnStmt.new(value:, line: statement.line, source_path: @ctx.current_analysis_path)
          when AST::ExpressionStmt
            if (format_sink_statements = lower_explicit_format_sink_expression_statement(statement.expression, env: local_env, line: statement.line))
              lowered.concat(format_sink_statements)
              next
            end

            expression_expected_type = if statement.expression.is_a?(AST::UnaryOp) && statement.expression.operator == "?"
                                         nil
                                       else
                                         infer_expression_type(statement.expression, env: local_env)
                                       end
            prepared_setup, prepared_expression, prepared_cleanups = prepare_expression_with_cleanups(
              statement.expression,
              env: local_env,
              expected_type: expression_expected_type,
              allow_root_statement_foreign: true,
              allow_void_propagation: true,
            )
            lowered.concat(prepared_setup)
            if prepared_expression && (foreign_call = foreign_call_info(prepared_expression, local_env))
              setup, value = lower_foreign_call_statement(
                foreign_call,
                env: local_env,
                expected_type: foreign_call[:binding].type.return_type,
                statement_position: true,
                discard_result: true,
              )
              lowered.concat(setup)
              lowered.concat(prepared_cleanups.flat_map(&:itself))
              local_env[:scopes] = scopes_with_refinements(local_env[:scopes], consuming_foreign_call_refinements(foreign_call, local_env))
            elsif prepared_expression
              lowered << IR::ExpressionStmt.new(expression: lower_expression(prepared_expression, env: local_env), line: statement.line, source_path: @ctx.current_analysis_path)
              lowered.concat(prepared_cleanups.flat_map(&:itself))
            else
              lowered.concat(prepared_cleanups.flat_map(&:itself))
            end
          when AST::EmitStmt
            lowered.concat(lower_emit_stmt(statement, env: local_env))
          when AST::WhenStmt
            discriminant = compile_time_const_value(statement.discriminant)
            chosen_branch = statement.branches.find do |branch|
              discriminant == compile_time_const_value(branch.pattern)
            end

            if chosen_branch
              lowered.concat(lower_block(
                chosen_branch.body,
                env: local_env,
                active_defers:,
                return_type:,
                loop_flow:,
                allow_return:,
              ))
            elsif statement.else_body
              lowered.concat(lower_block(
                statement.else_body,
                env: local_env,
                active_defers:,
                return_type:,
                loop_flow:,
                allow_return:,
              ))
            end
          else
            raise LoweringError, "unsupported statement #{statement.class.name}"
          end
        end

        unless terminating_ir_statement?(lowered.last)
          lowered.concat(cleanup_statements(local_defers, []))
        end
        lowered
      end

      def lower_proc_expression_for_local(expression, env:, local_name:, proc_type:)
        captures = proc_capture_entries(expression, env)
        captures.each do |capture|
          if ref_type?(capture[:type]) || contains_ref_type?(capture[:type])
            raise LoweringError, "proc capture #{capture[:name]} cannot use ref types"
          end
        end

        proc_id = fresh_proc_symbol
        invoke_c_name = "#{@ctx.module_prefix}__proc_#{proc_id}__invoke"
        release_c_name = "#{@ctx.module_prefix}__proc_#{proc_id}__release"
        retain_c_name = "#{@ctx.module_prefix}__proc_#{proc_id}__retain"
        env_struct_type = nil
        setup = []

        env_value = if captures.empty?
                      IR::NullLiteral.new(type: proc_env_pointer_type)
                    else
                      env_struct_type = Types::Struct.new("#{@ctx.module_prefix}__proc_#{proc_id}__env").define_fields(
                        { "__mt_ref_count" => @ctx.types.fetch("ptr_uint") }.merge(captures.each_with_object({}) { |capture, fields| fields[capture[:field_name]] = capture[:type] }),
                      )
                      @artifacts.synthetic_structs << IR::StructDecl.new(
                        name: env_struct_type.name,
                        c_name: env_struct_type.name,
                        fields: [IR::Field.new(name: "__mt_ref_count", type: @ctx.types.fetch("ptr_uint")), *captures.map { |capture| IR::Field.new(name: capture[:field_name], type: capture[:type]) }],
                        packed: false,
                        alignment: nil,
                      )

                      env_pointer_type = pointer_to(env_struct_type)
                      env_name = fresh_c_temp_name(env, "#{local_name}_env")
                      raw_allocation = IR::Call.new(
                        callee: "mt_async_alloc",
                        arguments: [IR::SizeofExpr.new(target_type: env_struct_type, type: @ctx.types.fetch("ptr_uint"))],
                        type: proc_env_pointer_type,
                      )
                      setup << IR::LocalDecl.new(
                        name: env_name,
                        c_name: env_name,
                        type: env_pointer_type,
                        value: IR::Cast.new(target_type: env_pointer_type, expression: raw_allocation, type: env_pointer_type),
                      )
                      env_pointer = IR::Name.new(name: env_name, type: env_pointer_type, pointer: false)
                      setup << IR::Assignment.new(
                        target: IR::Member.new(receiver: env_pointer, member: "__mt_ref_count", type: @ctx.types.fetch("ptr_uint")),
                        operator: "=",
                        value: IR::IntegerLiteral.new(value: 1, type: @ctx.types.fetch("ptr_uint")),
                      )
                      captures.each do |capture|
                        setup << IR::Assignment.new(
                          target: IR::Member.new(receiver: env_pointer, member: capture[:field_name], type: capture[:type]),
                          operator: "=",
                          value: lower_expression(AST::Identifier.new(name: capture[:name]), env:, expected_type: capture[:type]),
                        )
                      end
                      captures.each do |capture|
                        next unless contains_proc_storage_type?(capture[:type])

                        member = IR::Member.new(receiver: env_pointer, member: capture[:field_name], type: capture[:type])
                        setup.concat(lower_proc_contained_retain_statements(member, capture[:type]))
                      end
                      IR::Cast.new(target_type: proc_env_pointer_type, expression: env_pointer, type: proc_env_pointer_type)
                    end

        @artifacts.synthetic_functions << build_proc_invoke_function(expression, proc_type, captures, env_struct_type, invoke_c_name)
        @artifacts.synthetic_functions << build_proc_release_function(release_c_name, env_struct_type)
        @artifacts.synthetic_functions << build_proc_retain_function(retain_c_name, env_struct_type)

        [
          setup,
          IR::AggregateLiteral.new(
            type: proc_type,
            fields: [
              IR::AggregateField.new(name: "env", value: env_value),
              IR::AggregateField.new(name: "invoke", value: IR::Name.new(name: invoke_c_name, type: proc_invoke_function_type(proc_type), pointer: false)),
              IR::AggregateField.new(name: "release", value: IR::Name.new(name: release_c_name, type: proc_release_function_type, pointer: false)),
              IR::AggregateField.new(name: "retain", value: IR::Name.new(name: retain_c_name, type: proc_retain_function_type, pointer: false)),
            ],
          ),
        ]
      end

      def lower_inline_for_stmt(statement, env:, active_defers:, return_type:, allow_return:)
        iterable = compile_time_const_value(statement.iterables.first, env:)
        return [] unless iterable.is_a?(Array) && !iterable.empty?

        loop_var_name = statement.bindings.first.name
        loop_var_type = inline_loop_element_type(iterable.first)
        lowered = []

        iterable.each do |element|
          iter_env = duplicate_env(env)
          current_actual_scope(iter_env[:scopes])[loop_var_name] = local_binding(
            type: loop_var_type,
            c_name: c_local_name(loop_var_name),
            mutable: false,
            pointer: false,
            const_value: element,
          )
          begin
            body = lower_block(statement.body, env: iter_env, active_defers:, return_type:, loop_flow: nil, allow_return:)
            lowered << IR::BlockStmt.new(body:) unless body.empty?
          rescue LoweringError
            # compile-time expression in body cannot be lowered — skip
          end
        end

        lowered
      end

      def lower_inline_while_stmt(statement, env:, active_defers:, return_type:, allow_return:)
        condition = compile_time_const_value(statement.condition, env:)
        return [] unless condition

        iterations = 0
        max_iterations = 10_000
        lowered = []

        while compile_time_const_value(statement.condition, env:) && iterations < max_iterations
          body = lower_block(statement.body, env:, active_defers:, return_type:, loop_flow: nil, allow_return:)
          lowered << IR::BlockStmt.new(body:) unless body.empty?
          iterations += 1
        end

        lowered
      end

      def lower_inline_if_stmt(statement, env:, active_defers:, return_type:, allow_return:)
        chosen_branch = statement.branches.find do |branch|
          ct_value = compile_time_const_value(branch.condition, env:)
          ct_value == true
        end

        if chosen_branch
          lower_block(chosen_branch.body, env:, active_defers:, return_type:, loop_flow: nil, allow_return:)
        elsif statement.else_body
          lower_block(statement.else_body, env:, active_defers:, return_type:, loop_flow: nil, allow_return:)
        else
          []
        end
      end

      def lower_inline_match_stmt(statement, env:, active_defers:, return_type:, allow_return:)
        scrutinee = compile_time_const_value(statement.expression, env:)
        return [] unless scrutinee

        chosen_arm = statement.arms.find do |arm|
          scrutinee == compile_time_const_value(arm.pattern, env:)
        end

        return [] unless chosen_arm

        lower_block(chosen_arm.body, env:, active_defers:, return_type:, loop_flow: nil, allow_return:)
      end

      def inline_loop_element_type(element)
        if element.is_a?(Types::FieldHandle)
          @ctx.types.fetch("field_handle")
        elsif element.is_a?(Types::CallableHandle)
          @ctx.types.fetch("callable_handle")
        elsif element.is_a?(Types::AttributeHandle)
          @ctx.types.fetch("attribute_handle")
        elsif element.is_a?(Types::MemberHandle)
          @ctx.types.fetch("member_handle")
        elsif element.is_a?(Types::StructHandle)
          @ctx.types.fetch("struct_handle")
        else
          @ctx.types.fetch("int")
        end
      end

      def lower_emit_stmt(statement, env:)
        decl = statement.declaration
        case decl
        when AST::FunctionDef
          lower_emitted_function(decl, env:)
        when AST::StructDecl
          lower_emitted_struct(decl)
        when AST::ConstDecl
          lower_emitted_const(decl, env:)
        else
          raise LoweringError, "emit is not supported for #{decl.class.name}"
        end
      end

      def lower_emitted_function(decl, env:)
        params = []
        param_setup = []
        return_type = decl.return_type ? resolve_type_ref(decl.return_type) : @ctx.types.fetch("void")
        c_name = "#{@ctx.module_prefix}#{decl.name}"

        decl.params.each do |param|
          param_type = param.type ? resolve_type_ref(param.type) : @ctx.types.fetch("int")
          param_c_name = c_local_name(param.name)
          params << IR::Param.new(name: param.name, c_name: param_c_name, type: param_type, pointer: false)
          env[:scopes].last[param.name] = local_binding(type: param_type, c_name: param_c_name, mutable: false, pointer: false)
        end

        body = lower_block(decl.body, env:, active_defers: [], return_type:, loop_flow: nil, allow_return: true)
        body = param_setup + body
        func = IR::Function.new(name: decl.name, c_name:, params:, return_type:, body:, entry_point: false, method_receiver_param: false)
        @artifacts.emitted_declarations << func
        []
      end

      def lower_emitted_struct(decl)
        fields = decl.fields.map do |field|
          field_type = field.type ? resolve_type_ref(field.type) : @ctx.types.fetch("int")
          IR::Field.new(name: field.name, type: field_type)
        end
        c_name = "#{@ctx.module_prefix}#{decl.name}"
        struct_decl = IR::StructDecl.new(name: decl.name, c_name:, fields:, packed: decl.respond_to?(:packed) ? decl.packed : false, alignment: nil)
        @artifacts.emitted_declarations << struct_decl
        []
      end

      def lower_destructure_decl(statement, env:, lowered:, local_defers:, active_defers:, return_type:, loop_flow:, allow_return:)
        value_type = infer_expression_type(statement.value, env:)
        setup, prepared_value, _cleanups = prepare_expression_with_cleanups(statement.value, env:, expected_type: value_type)
        lowered.concat(setup)
        value = lower_contextual_expression(prepared_value, env:, expected_type: value_type)

        temp_name = fresh_c_temp_name(env, "destructure_val")
        lowered << IR::LocalDecl.new(name: temp_name, c_name: temp_name, type: value_type, value:)

        if statement.destructure_type_name
          # Struct destructure: find fields by name in the struct type
          destructure_type = value_type
          fields = destructure_type.fields
          statement.destructure_bindings.each do |name|
            field_type = fields[name]
            field_expr = IR::Member.new(receiver: IR::Name.new(name: temp_name, type: destructure_type, pointer: false), member: name, type: field_type)
            decl_c_name = c_local_name(name)
            lowered << IR::LocalDecl.new(name: decl_c_name, c_name: decl_c_name, type: field_type, value: field_expr)
            env[:scopes].last[name] = local_binding(type: field_type, c_name: decl_c_name, mutable: false, pointer: false)
          end
        else
          # Tuple destructure: index by position
          statement.destructure_bindings.each_with_index do |name, index|
            field_name = value_type.field_names[index]
            field_type = value_type.element_types[index]
            field_expr = IR::Member.new(receiver: IR::Name.new(name: temp_name, type: value_type, pointer: false), member: field_name, type: field_type)
            decl_c_name = c_local_name(name)
            lowered << IR::LocalDecl.new(name: decl_c_name, c_name: decl_c_name, type: field_type, value: field_expr)
            env[:scopes].last[name] = local_binding(type: field_type, c_name: decl_c_name, mutable: false, pointer: false)
          end
        end
      end

      def lower_emitted_const(decl, env:)
        value = lower_static_storage_initializer(decl.value, env:, expected_type: decl.type ? resolve_type_ref(decl.type) : nil)
        type = decl.type ? resolve_type_ref(decl.type) : infer_expression_type(decl.value, env:)
        c_name = value_c_name(decl.name)
        constant = IR::Constant.new(name: decl.name, c_name:, type:, value:)
        @artifacts.emitted_declarations << constant
        []
      end
  end
end

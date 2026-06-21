# frozen_string_literal: true

module MilkTea
  module LowererCalls
    private


      def lower_call(expression, env:, type:)
        ct_value = compile_time_const_value(expression, env:)
        if ct_value && (literal = lower_compile_time_literal(ct_value, type))
          if expression.callee.is_a?(AST::Identifier)
            binding = @ctx.functions[expression.callee.name]
            return literal unless binding&.ast&.respond_to?(:const) && binding.ast.const
          else
            return literal
          end
        end

        kind, callee_name, receiver, callee_type, callee_binding = resolve_callee(expression.callee, env, arguments: expression.arguments)

        case kind
        when :function
          if callee_binding && foreign_function_binding?(callee_binding)
            raise LoweringError, "consuming foreign calls must be top-level expression statements" if foreign_call_consumes_binding?(callee_binding)

            return lower_foreign_call_inline(expression, callee_binding, env:, type:)
          end

          arguments = lower_call_arguments(expression.arguments, callee_type, env:)
          IR::Call.new(callee: callee_name, arguments:, type:)
        when :callable_value
          callee_expression = lower_expression(expression.callee, env:, expected_type: callee_type)
          if proc_type?(callee_type)
            arguments = [
              IR::Member.new(receiver: callee_expression, member: "env", type: proc_env_pointer_type),
              *lower_call_arguments(expression.arguments, callee_type, env:),
            ]
            IR::Call.new(
              callee: IR::Member.new(receiver: callee_expression, member: "invoke", type: proc_invoke_function_type(callee_type)),
              arguments:,
              type:,
            )
          else
            arguments = lower_call_arguments(expression.arguments, callee_type, env:)
            IR::Call.new(callee: callee_expression, arguments:, type:)
          end
        when :method
          receiver_arg = lower_method_receiver_argument(receiver, callee_type, callee_binding, env:)
          arguments = [receiver_arg, *lower_call_arguments(expression.arguments, callee_type, env:)]
          IR::Call.new(callee: callee_name, arguments:, type:)
        when :str_buffer_clear
          receiver_type = infer_expression_type(receiver, env:)
          IR::Call.new(
            callee: "mt_str_buffer_clear",
            arguments: [
              lower_str_buffer_data_pointer(receiver, env:),
              IR::IntegerLiteral.new(value: str_buffer_capacity(receiver_type), type: @ctx.types.fetch("ptr_uint")),
              lower_str_buffer_len_pointer(receiver, env:),
              lower_str_buffer_dirty_pointer(receiver, env:),
            ],
            type:,
          )
        when :str_buffer_assign, :str_buffer_assign_format
          receiver_type = infer_expression_type(receiver, env:)
          IR::Call.new(
            callee: "mt_str_buffer_assign",
            arguments: [
              lower_contextual_expression(expression.arguments.fetch(0).value, env:, expected_type: @ctx.types.fetch("str")),
              lower_str_buffer_data_pointer(receiver, env:),
              IR::IntegerLiteral.new(value: str_buffer_capacity(receiver_type), type: @ctx.types.fetch("ptr_uint")),
              lower_str_buffer_len_pointer(receiver, env:),
              lower_str_buffer_dirty_pointer(receiver, env:),
            ],
            type:,
          )
        when :str_buffer_append, :str_buffer_append_format
          receiver_type = infer_expression_type(receiver, env:)
          IR::Call.new(
            callee: "mt_str_buffer_append",
            arguments: [
              lower_contextual_expression(expression.arguments.fetch(0).value, env:, expected_type: @ctx.types.fetch("str")),
              lower_str_buffer_data_pointer(receiver, env:),
              IR::IntegerLiteral.new(value: str_buffer_capacity(receiver_type), type: @ctx.types.fetch("ptr_uint")),
              lower_str_buffer_len_pointer(receiver, env:),
              lower_str_buffer_dirty_pointer(receiver, env:),
            ],
            type:,
          )
        when :str_buffer_len
          receiver_type = infer_expression_type(receiver, env:)
          IR::Call.new(
            callee: "mt_str_buffer_len",
            arguments: [
              lower_str_buffer_data_pointer(receiver, env:),
              IR::IntegerLiteral.new(value: str_buffer_capacity(receiver_type), type: @ctx.types.fetch("ptr_uint")),
              lower_str_buffer_len_pointer(receiver, env:),
              lower_str_buffer_dirty_pointer(receiver, env:),
            ],
            type:,
          )
        when :str_buffer_capacity
          receiver_type = infer_expression_type(receiver, env:)
          IR::IntegerLiteral.new(value: str_buffer_capacity(receiver_type), type: type)
        when :str_buffer_as_str
          receiver_type = infer_expression_type(receiver, env:)
          data_pointer = lower_str_buffer_data_pointer(receiver, env:)
          IR::AggregateLiteral.new(
            type:,
            fields: [
              IR::AggregateField.new(name: "data", value: data_pointer),
              IR::AggregateField.new(
                name: "len",
                value: IR::Call.new(
                  callee: "mt_str_buffer_len",
                  arguments: [
                    data_pointer,
                    IR::IntegerLiteral.new(value: str_buffer_capacity(receiver_type), type: @ctx.types.fetch("ptr_uint")),
                    lower_str_buffer_len_pointer(receiver, env:),
                    lower_str_buffer_dirty_pointer(receiver, env:),
                  ],
                  type: @ctx.types.fetch("ptr_uint"),
                ),
              ),
            ],
          )
        when :str_buffer_as_cstr
          receiver_type = infer_expression_type(receiver, env:)
          IR::Call.new(
            callee: "mt_str_buffer_as_cstr",
            arguments: [
              lower_str_buffer_data_pointer(receiver, env:),
              IR::IntegerLiteral.new(value: str_buffer_capacity(receiver_type), type: @ctx.types.fetch("ptr_uint")),
              lower_str_buffer_len_pointer(receiver, env:),
              lower_str_buffer_dirty_pointer(receiver, env:),
            ],
            type:,
          )
        when :array_as_span
          receiver_type = infer_expression_type(receiver, env:)
          lower_array_to_span_expression(lower_expression(receiver, env:), type)
        when :event_subscribe, :event_subscribe_once, :event_unsubscribe, :event_emit, :event_wait
          event_type = infer_expression_type(receiver, env:)
          runtime = ensure_event_runtime(event_type)
          event_pointer = lower_event_storage_pointer(receiver, env:)

          case kind
          when :event_subscribe
            if expression.arguments.length == 2
              IR::Call.new(
                callee: runtime.fetch(:subscribe_stateful_linkage_name),
                arguments: [
                  event_pointer,
                  lower_contextual_expression(expression.arguments.fetch(0).value, env:, expected_type: runtime.fetch(:void_ptr)),
                  lower_contextual_expression(expression.arguments.fetch(1).value, env:, expected_type: runtime.fetch(:void_ptr)),
                ],
                type:,
              )
            else
              IR::Call.new(
                callee: runtime.fetch(:subscribe_linkage_name),
                arguments: [
                  event_pointer,
                  lower_contextual_expression(expression.arguments.fetch(0).value, env:, expected_type: runtime.fetch(:listener_type)),
                ],
                type:,
              )
            end
          when :event_subscribe_once
            if expression.arguments.length == 2
              IR::Call.new(
                callee: runtime.fetch(:subscribe_once_stateful_linkage_name),
                arguments: [
                  event_pointer,
                  lower_contextual_expression(expression.arguments.fetch(0).value, env:, expected_type: runtime.fetch(:void_ptr)),
                  lower_contextual_expression(expression.arguments.fetch(1).value, env:, expected_type: runtime.fetch(:void_ptr)),
                ],
                type:,
              )
            else
              IR::Call.new(
                callee: runtime.fetch(:subscribe_once_linkage_name),
                arguments: [
                  event_pointer,
                  lower_contextual_expression(expression.arguments.fetch(0).value, env:, expected_type: runtime.fetch(:listener_type)),
                ],
                type:,
              )
            end
          when :event_unsubscribe
            IR::Call.new(
              callee: runtime.fetch(:unsubscribe_linkage_name),
              arguments: [
                event_pointer,
                lower_contextual_expression(expression.arguments.fetch(0).value, env:, expected_type: @ctx.types.fetch("Subscription")),
              ],
              type:,
            )
          when :event_emit
            arguments = [event_pointer]
            if event_type.payload_type
              arguments << lower_contextual_expression(expression.arguments.fetch(0).value, env:, expected_type: event_type.payload_type)
            end
            IR::Call.new(callee: runtime.fetch(:emit_linkage_name), arguments:, type:)
          when :event_wait
            IR::Call.new(callee: runtime.fetch(:wait_linkage_name), arguments: [event_pointer], type:)
          end
        when :atomic_load, :atomic_store, :atomic_add, :atomic_sub, :atomic_exchange, :atomic_compare_exchange
          lower_atomic_method_call(kind, receiver, expression, env:, type:)
        when :associated_method
          arguments = lower_call_arguments(expression.arguments, callee_type, env:)
          IR::Call.new(callee: callee_name, arguments:, type:)
        when :struct_literal
          fields = expression.arguments.map do |argument|
            field_type = type.field(argument.name)
            lowered_value = lower_contextual_expression(
              argument.value,
              env:,
              expected_type: field_type,
              external_numeric: type.respond_to?(:external) && type.external,
              contextual_int_to_float: contextual_int_to_float_target?(field_type),
            )
            lowered_value = wrap_nullable_field_value(field_type, lowered_value, env)
            IR::AggregateField.new(
              name: argument.name,
              value: lowered_value,
            )
          end
          IR::AggregateLiteral.new(type:, fields:)
        when :struct_with
          explicit_names = expression.arguments.each_with_object({}) { |a, h| h[a.name] = a }
          lowered_receiver = lower_expression(receiver, env:)
          field_hash = callee_type.respond_to?(:fields) ? callee_type.fields : {}
          fields = field_hash.map do |field_name, field_type|
            if (explicit_arg = explicit_names[field_name])
              IR::AggregateField.new(
                name: field_name,
                value: lower_contextual_expression(
                  explicit_arg.value,
                  env:,
                  expected_type: field_type,
                  contextual_int_to_float: contextual_int_to_float_target?(field_type),
                ),
              )
            else
              IR::AggregateField.new(
                name: field_name,
                value: IR::Member.new(
                  receiver: lowered_receiver,
                  member: field_name,
                  type: field_type,
                ),
              )
            end
          end
          IR::AggregateLiteral.new(type: callee_type, fields:)
        when :variant_arm_ctor
          _, _, _, variant_type, (_, arm_name) = resolve_callee(expression.callee, env, arguments: expression.arguments)
          arm_fields = variant_type.arm(arm_name)
          provided_names = expression.arguments.map(&:name).to_set
          payload_fields = expression.arguments.map do |argument|
            field_type = arm_fields.fetch(argument.name)
            lowered_value = lower_contextual_expression(
              argument.value,
              env:,
              expected_type: field_type,
              contextual_int_to_float: contextual_int_to_float_target?(field_type),
            )
            lowered_value = IR::AddressOf.new(expression: lowered_value, type: lowered_value.type) if field_type == variant_type
            lowered_value = wrap_nullable_field_value(field_type, lowered_value, env) unless field_type == variant_type
            IR::AggregateField.new(
              name: argument.name,
              value: lowered_value,
            )
          end
          arm_fields.each do |field_name, field_type|
            next if provided_names.include?(field_name)
            next unless field_type.void?

            payload_fields << IR::AggregateField.new(
              name: field_name,
              value: IR::IntegerLiteral.new(type: @ctx.types.fetch("ubyte"), value: 0),
            )
          end
          IR::VariantLiteral.new(type: variant_type, arm_name:, fields: payload_fields)
        when :array
          element_type = array_element_type(type)
          elements = expression.arguments.map do |argument|
            lower_contextual_expression(argument.value, env:, expected_type: element_type)
          end
          IR::ArrayLiteral.new(type:, elements:)
        when :reinterpret
          argument = expression.arguments.fetch(0)
          source_type = infer_expression_type(argument.value, env:)
          IR::ReinterpretExpr.new(
            target_type: type,
            source_type:,
            expression: lower_expression(argument.value, env:, expected_type: source_type),
            type:,
          )
        when :hash
          resolution = resolve_hash_specialization(expression.callee, env:)
          argument = expression.arguments.fetch(0)
          IR::Call.new(
            callee: resolution.callee_name,
            arguments: [lower_hash_operation_argument(argument.value, env:, target_type: resolution.target_type)],
            type:,
          )
        when :equal
          resolution = resolve_equal_specialization(expression.callee, env:)
          left = expression.arguments.fetch(0)
          right = expression.arguments.fetch(1)
          IR::Call.new(
            callee: resolution.callee_name,
            arguments: [
              lower_hash_operation_argument(left.value, env:, target_type: resolution.target_type),
              lower_hash_operation_argument(right.value, env:, target_type: resolution.target_type),
            ],
            type:,
          )
        when :order
          resolution = resolve_order_specialization(expression.callee, env:)
          left = expression.arguments.fetch(0)
          right = expression.arguments.fetch(1)
          IR::Call.new(
            callee: resolution.callee_name,
            arguments: [
              lower_hash_operation_argument(left.value, env:, target_type: resolution.target_type),
              lower_hash_operation_argument(right.value, env:, target_type: resolution.target_type),
            ],
            type:,
          )
        when :zero
          IR::ZeroInit.new(type:)
        when :fatal
          argument = expression.arguments.fetch(0)
          message_type = infer_expression_type(argument.value, env:)
          callee = message_type == @ctx.types.fetch("cstr") ? "mt_fatal" : "mt_fatal_str"
          IR::Call.new(callee:, arguments: [lower_expression(argument.value, env:, expected_type: message_type)], type:)
        when :get
          receiver_arg = expression.arguments.fetch(0)
          index_arg = expression.arguments.fetch(1)
          receiver_type = infer_expression_type(receiver_arg.value, env:)
          receiver = lower_expression(receiver_arg.value, env:)
          index = lower_expression(index_arg.value, env:)
          if array_type?(receiver_type)
            IR::NullableIndex.new(receiver:, index:, receiver_type:, type:)
          elsif receiver_type.is_a?(Types::Span)
            IR::NullableSpanIndex.new(receiver:, index:, receiver_type:, type:)
          else
            raise LoweringError, "get expects an array or span, got #{receiver_type}"
          end
        when :ref_of
          argument = expression.arguments.fetch(0)
          lower_addr_expression(argument.value, env:, target_type: type)
        when :const_ptr_of
          argument = expression.arguments.fetch(0)
          lower_addr_expression(argument.value, env:, target_type: type)
        when :read
          argument = expression.arguments.fetch(0)
          IR::Unary.new(operator: "*", operand: lower_expression(argument.value, env:), type:)
        when :ptr_of
          argument = expression.arguments.fetch(0)
          argument_type = infer_expression_type(argument.value, env:)
          if ref_type?(argument_type)
            IR::Cast.new(target_type: type, expression: lower_expression(argument.value, env:), type:)
          else
            lower_addr_expression(argument.value, env:, target_type: type)
          end
        when :adapt
          lower_adapt_call(expression, env:, type:, interface: callee_binding)
        when :dyn_method
          lower_dyn_method_call(expression, receiver, callee_type, env:, type:)
        else
          raise LoweringError, "unsupported call kind #{kind}"
        end
      end

      def lower_method_receiver_argument(receiver, callee_type, callee_binding, env:)
        lowered_receiver = lower_expression(receiver, env:)
        declared_receiver_type = callee_type.receiver_type

        if pointer_lowered_method_receiver?(callee_type, callee_binding)
          return lowered_receiver if ref_type?(lowered_receiver.type)
          return lowered_receiver if pointer_type?(lowered_receiver.type)

          if lowered_receiver.is_a?(IR::Name) && lowered_receiver.pointer
            return lowered_receiver
          end

          if lowered_receiver.is_a?(IR::Unary) && lowered_receiver.operator == "*"
            return lowered_receiver.operand
          end

          return IR::AddressOf.new(expression: lowered_receiver, type: lowered_receiver.type)
        end

        return lowered_receiver if declared_receiver_type && pointer_type?(declared_receiver_type)

        if ref_type?(lowered_receiver.type)
          return IR::Unary.new(operator: "*", operand: lowered_receiver, type: referenced_type(lowered_receiver.type))
        end

        if lowered_receiver.is_a?(IR::Name) && lowered_receiver.pointer
          return IR::Unary.new(operator: "*", operand: lowered_receiver, type: lowered_receiver.type)
        end

        if pointer_type?(lowered_receiver.type)
          return IR::Unary.new(operator: "*", operand: lowered_receiver, type: pointee_type(lowered_receiver.type))
        end

        lowered_receiver
      end

      def lower_addr_expression(expression, env:, target_type:)
        lowered_expression = lower_expression(expression, env:)
        return cast_expression(lowered_expression, target_type) if lowered_expression.is_a?(IR::Name) && lowered_expression.pointer

        if lowered_expression.is_a?(IR::Unary) && lowered_expression.operator == "*"
          return cast_expression(lowered_expression.operand, target_type)
        end

        IR::AddressOf.new(expression: lowered_expression, type: target_type)
      end

      def lower_hash_operation_argument(expression, env:, target_type:)
        actual_type = infer_expression_type(expression, env:)
        lowered_expression = lower_expression(expression, env:)
        pointer_type = const_pointer_to(target_type)

        if pointer_type?(actual_type) || ref_type?(actual_type)
          return cast_expression(lowered_expression, pointer_type)
        end

        return cast_expression(lowered_expression.operand, pointer_type) if lowered_expression.is_a?(IR::Unary) && lowered_expression.operator == "*"

        IR::AddressOf.new(expression: lowered_expression, type: pointer_type)
      end

      def lower_call_arguments(arguments, callee_type, env:)
        arguments.map.with_index do |argument, index|
          parameter = index < callee_type.params.length ? callee_type.params[index] : nil
          expected_type = parameter&.type
          external_call = callee_type.respond_to?(:external) && callee_type.external && !expected_type.nil?
          if external_call && parameter && %i[out inout].include?(parameter.passing_mode)
            next lower_foreign_pointer_argument_value(parameter, argument, env:)
          end

          lower_contextual_expression(
            argument.value,
            env:,
            expected_type:,
            external_numeric: external_call,
            contextual_int_to_float: expected_type && contextual_int_to_float_target?(expected_type) && !external_call,
          )
        end
      end

      def implicit_ref_argument_bridge?(expression, expected_type, env:)
        return false unless ref_type?(expected_type)

        actual_type = infer_expression_type(expression, env:)
        actual_type == referenced_type(expected_type) && addressable_storage_expression?(expression)
      end

      def task_expression_root_proc_bridge?(expression, expected_type, env:)
        return false unless task_root_proc_type?(expected_type)

        actual_type = infer_expression_type(expression, env:)
        actual_type.is_a?(Types::Task) && actual_type == expected_type.return_type
      end

      def wrap_task_expression_in_root_proc(expression, env:)
        task_type = infer_expression_type(expression, env:)
        AST::ProcExpr.new(
          params: [],
          return_type: ast_type_ref_for(task_type),
          body: [AST::ReturnStmt.new(value: expression)],
        )
      end

      def wrap_expression_in_ref_of(expression)
        AST::Call.new(
          callee: AST::Identifier.new(name: "ref_of"),
          arguments: [AST::Argument.new(name: nil, value: expression)],
        )
      end

      def foreign_call_info(expression, env)
        call = expression if expression.is_a?(AST::Call)
        return unless call

        kind, _, _, _, binding = resolve_callee(call.callee, env, arguments: call.arguments)
        return unless kind == :function && binding && foreign_function_binding?(binding)

        {
          call:,
          binding:,
        }
      end

      def foreign_call_consumes_binding?(binding)
        binding.type.params.any? { |parameter| parameter.passing_mode == :consuming }
      end

      def lower_foreign_call_components(foreign_call, env:, expected_type:, statement_position:)
        call = foreign_call.fetch(:call)
        binding = foreign_call.fetch(:binding)
        raise LoweringError, "consuming foreign calls must be top-level expression statements" if foreign_call_consumes_binding?(binding) && !statement_position

        previous_type_substitutions = @ctx.current_type_substitutions
        @ctx.current_type_substitutions = binding.type_substitutions

        owner_analysis = analysis_for_module(binding.owner.module_name)
        mapping_expression = foreign_mapping_expression(binding.ast)
        reference_counts = foreign_mapping_reference_counts(mapping_expression)
        mapping_env = duplicate_env(env)
        lowered = []
        release_assignments = consuming_foreign_release_assignments(foreign_call, env:)
        cleanup_statements = []

        replacements = bind_foreign_mapping_arguments(binding, call.arguments, mapping_env, lowered, env:, reference_counts:, cleanup: cleanup_statements)

        call_type = binding.type.return_type
        lowered_call = lower_inline_foreign_mapping_expression(
          mapping_expression,
          mapping_env:,
          replacements:,
          owner_analysis:,
          expected_type: expected_type || call_type,
        )
        lowered_call = append_variadic_foreign_call_arguments(
          lowered_call,
          call.arguments,
          binding.type,
          env:,
          lowered:,
          cleanup: cleanup_statements,
        )

        [lowered, lowered_call, call_type, release_assignments, cleanup_statements]
      ensure
        @ctx.current_type_substitutions = previous_type_substitutions
      end

      def lower_foreign_call_statement(foreign_call, env:, expected_type:, statement_position:, discard_result: false)
        lowered, lowered_call, call_type, release_assignments, cleanup_statements = lower_foreign_call_components(
          foreign_call,
          env:,
          expected_type:,
          statement_position:,
        )

        if call_type == @ctx.types.fetch("void")
          lowered << IR::ExpressionStmt.new(expression: lowered_call)
          lowered.concat(release_assignments)
          lowered.concat(cleanup_statements)
          return [lowered, nil]
        end

        raise LoweringError, "consuming foreign calls must return void" unless release_assignments.empty?

        if discard_result
          lowered << IR::ExpressionStmt.new(expression: lowered_call)
          lowered.concat(cleanup_statements)
          return [lowered, nil]
        end

        unless cleanup_statements.empty?
          result_name = fresh_c_temp_name(env, "foreign_result")
          lowered << IR::LocalDecl.new(name: result_name, linkage_name: result_name, type: call_type, value: lowered_call)
          lowered.concat(cleanup_statements)
          return [lowered, IR::Name.new(name: result_name, type: call_type, pointer: false)]
        end

        [lowered, lowered_call]
      end

      def consuming_foreign_release_assignments(foreign_call, env:)
        consuming_foreign_release_bindings(foreign_call, env:).map do |binding|
          IR::Assignment.new(
            target: IR::Name.new(name: binding[:linkage_name], type: binding[:storage_type], pointer: binding[:pointer]),
            operator: "=",
            value: IR::NullLiteral.new(type: binding[:storage_type]),
          )
        end
      end

      def consuming_foreign_call_refinements(foreign_call, env)
        consuming_foreign_release_bindings(foreign_call, env:).each_with_object({}) do |binding, refinements|
          refinements[binding[:name]] = null_type
        end
      end

      def consuming_foreign_release_bindings(foreign_call, env:)
        binding = foreign_call.fetch(:binding)
        call = foreign_call.fetch(:call)

        binding.type.params.each_with_index.filter_map do |parameter, index|
          next unless parameter.passing_mode == :consuming

          argument = call.arguments.fetch(index)
          unless argument.value.is_a?(AST::Identifier)
            raise LoweringError, "consuming foreign calls require bare nullable local or parameter bindings"
          end

          lowered_binding = lookup_value(argument.value.name, env)
          unless lowered_binding && lowered_binding[:storage_type].is_a?(Types::Nullable) && lowered_binding[:storage_type].base == parameter.type
            raise LoweringError, "consuming foreign calls require bare nullable local or parameter bindings"
          end

          lowered_binding.merge(name: argument.value.name)
        end
      end

      def bind_foreign_mapping_arguments(binding, arguments, mapping_env, lowered, env:, reference_counts:, cleanup:)
        replacements = {}
        entries = binding.ast.params.each_with_index.map do |param_ast, index|
          parameter = binding.type.params.fetch(index)
          public_alias = param_ast.boundary_type ? foreign_mapping_public_alias_name(param_ast.name) : nil
          {
            argument: arguments.fetch(index),
            param_ast:,
            parameter:,
            temp_type: parameter.boundary_type || parameter.type,
            public_alias:,
            public_reference_count: public_alias ? reference_counts.fetch(public_alias, 0) : 0,
            reference_count: reference_counts.fetch(param_ast.name, 0),
            lowered_value: nil,
          }
        end

        entries.each do |entry|
          next unless entry[:public_reference_count].positive?

          public_value = lower_contextual_expression(entry[:argument].value, env:, expected_type: entry[:parameter].type)
          if public_value.is_a?(IR::Name)
            current_actual_scope(mapping_env[:scopes])[entry[:public_alias]] = local_binding(
              type: entry[:parameter].type,
              linkage_name: public_value.name,
              mutable: false,
              pointer: public_value.pointer,
            )
            replacements[entry[:public_alias]] = public_value
            next
          end

          public_temp_name = fresh_c_temp_name(env, "foreign_arg_public")
          lowered << IR::LocalDecl.new(
            name: public_temp_name,
            linkage_name: public_temp_name,
            type: entry[:parameter].type,
            value: public_value,
          )
          current_actual_scope(mapping_env[:scopes])[entry[:public_alias]] = local_binding(
            type: entry[:parameter].type,
            linkage_name: public_temp_name,
            mutable: false,
            pointer: false,
          )
          replacements[entry[:public_alias]] = IR::Name.new(name: public_temp_name, type: entry[:parameter].type, pointer: false)
        end

        entries.each do |entry|
          next unless entry[:reference_count].positive?

          source_argument = if entry[:public_reference_count].positive?
                              AST::Argument.new(name: nil, value: AST::Identifier.new(name: entry[:public_alias]))
                            else
                              entry[:argument]
                            end
          source_env = entry[:public_reference_count].positive? ? mapping_env : env
          source_argument = prepare_foreign_in_argument(entry[:parameter], source_argument, source_env:, lowered:, env:)
          entry[:lowered_value] = if automatic_foreign_cstr_list_temp_needed?(entry[:parameter], source_argument.value, env: source_env)
                                    lower_foreign_cstr_list_argument_value(entry[:parameter], source_argument.value, env: source_env, lowered:, cleanup:)
                                  else
                                    lower_foreign_argument_value(entry[:parameter], source_argument, env: source_env)
                                  end
        end

        inline_direct_call_names = inlineable_single_direct_call_names(entries)

        entries.each do |entry|
          next unless entry[:reference_count].positive?

          param_ast = entry[:param_ast]
          temp_type = entry[:temp_type]
          lowered_value = entry[:lowered_value]

          if !inline_direct_call_names.include?(param_ast.name) && foreign_argument_needs_temporary_binding?(lowered_value, reference_count: entry[:reference_count])
            temp_name = fresh_c_temp_name(env, "foreign_arg")
            lowered << IR::LocalDecl.new(
              name: temp_name,
              linkage_name: temp_name,
              type: temp_type,
              value: lowered_value,
            )
            current_actual_scope(mapping_env[:scopes])[param_ast.name] = local_binding(type: temp_type, linkage_name: temp_name, mutable: false, pointer: false)
            replacements[param_ast.name] = IR::Name.new(name: temp_name, type: temp_type, pointer: false)
            if temporary_foreign_cstr_expression?(lowered_value)
              cleanup << IR::ExpressionStmt.new(
                expression: IR::Call.new(
                  callee: "mt_free_foreign_cstr_temp",
                  arguments: [IR::Name.new(name: temp_name, type: temp_type, pointer: false)],
                  type: @ctx.types.fetch("void"),
                ),
              )
            end
          else
            current_actual_scope(mapping_env[:scopes])[param_ast.name] = local_binding(type: temp_type, linkage_name: param_ast.name, mutable: false, pointer: false)
            replacements[param_ast.name] = lowered_value
          end
        end

        replacements
      end

      def inlineable_single_direct_call_names(entries)
        blocked_entries = entries.select do |entry|
          next false unless entry[:reference_count].positive?

          entry[:reference_count] > 1 || !inlineable_foreign_argument_expression?(entry[:lowered_value])
        end
        return [] unless blocked_entries.length == 1

        blocked_entry = blocked_entries.first
        return [] unless blocked_entry[:reference_count] == 1 && blocked_entry[:lowered_value].is_a?(IR::Call)
        return [] if temporary_foreign_cstr_expression?(blocked_entry[:lowered_value])

        [blocked_entry[:param_ast].name]
      end

      def foreign_argument_expression(argument)
        if argument.value.is_a?(AST::UnaryOp) && ["out", "in", "inout"].include?(argument.value.operator)
          argument.value.operand
        else
          argument.value
        end
      end

      def lower_foreign_argument_value(parameter, argument, env:)
        case parameter.passing_mode
        when :plain, :consuming
          if parameter.boundary_type.nil? || parameter.boundary_type == parameter.type
            expected = parameter.passing_mode == :consuming ? Types::Nullable.new(parameter.type) : parameter.type
            lower_contextual_expression(argument.value, env:, expected_type: expected)
          elsif parameter.boundary_type == @ctx.types.fetch("cstr") && parameter.type == @ctx.types.fetch("str")
            if argument.value.is_a?(AST::StringLiteral) && !argument.value.cstring
              return IR::StringLiteral.new(value: argument.value.value, type: parameter.boundary_type, cstring: true)
            end

            actual_type = infer_expression_type(argument.value, env:)
            if actual_type == @ctx.types.fetch("cstr")
              return lower_expression(argument.value, env:, expected_type: parameter.boundary_type)
            end

            if cstr_backed_expression?(argument.value, env)
              lowered_value = lower_contextual_expression(argument.value, env:, expected_type: parameter.type)
              data_expression = IR::Member.new(receiver: lowered_value, member: "data", type: pointer_to(@ctx.types.fetch("char")))
              converted = foreign_identity_projection_expression(data_expression, parameter.boundary_type)
              return converted if converted
            end

            IR::Call.new(
              callee: "mt_foreign_str_to_cstr_temp",
              arguments: [lower_contextual_expression(argument.value, env:, expected_type: parameter.type)],
              type: parameter.boundary_type,
            )
          elsif foreign_span_boundary_compatible?(parameter.type, parameter.boundary_type)
            lower_foreign_span_argument_value(parameter, argument, env:)
          elsif foreign_char_pointer_buffer_boundary_compatible?(parameter.type, parameter.boundary_type)
            lower_foreign_char_pointer_buffer_argument_value(parameter, argument, env:)
          else
            lowered_value = lower_contextual_expression(argument.value, env:, expected_type: parameter.type)
            converted = foreign_identity_projection_expression(lowered_value, parameter.boundary_type)
            return converted if converted

            raise LoweringError, "unsupported foreign boundary mapping #{parameter.type} as #{parameter.boundary_type}"
          end
        when :in
          lower_foreign_in_argument_value(parameter, argument, env:)
        when :out, :inout
          lower_foreign_pointer_argument_value(parameter, argument, env:)
        else
          raise LoweringError, "unsupported foreign passing mode #{parameter.passing_mode}"
        end
      end

      def lower_foreign_span_argument_value(parameter, argument, env:)
        public_type = parameter.type
        boundary_type = parameter.boundary_type
        lowered_value = lower_contextual_expression(argument.value, env:, expected_type: public_type)
        return lowered_value if public_type == boundary_type

        public_element_type = public_type.element_type
        boundary_element_type = boundary_type.element_type

        data_expression = IR::Member.new(receiver: lowered_value, member: "data", type: pointer_to(public_element_type))
        converted_data = foreign_identity_projection_expression(data_expression, pointer_to(boundary_element_type))
        raise LoweringError, "unsupported foreign boundary mapping #{public_type} as #{boundary_type}" unless converted_data

        len_expression = IR::Member.new(receiver: lowered_value, member: "len", type: @ctx.types.fetch("ptr_uint"))
        IR::AggregateLiteral.new(
          type: boundary_type,
          fields: [
            IR::AggregateField.new(name: "data", value: converted_data),
            IR::AggregateField.new(name: "len", value: len_expression),
          ],
        )
      end

      def lower_foreign_pointer_argument_value(parameter, argument, env:)
        slot_type = foreign_slot_boundary_value_type(parameter.type)
        operand = foreign_argument_expression(argument)
        address = lower_addr_expression(operand, env:, target_type: pointer_to(slot_type))

        converted = foreign_identity_projection_expression(address, parameter.boundary_type)
        return converted if converted

        raise LoweringError, "unsupported foreign pointer boundary mapping #{parameter.type} as #{parameter.boundary_type}"
      end

      def foreign_slot_boundary_value_type(type)
        if type.is_a?(Types::Nullable) && pointer_like_type?(type.base)
          return type.base
        end

        type
      end

      def prepare_foreign_in_argument(parameter, argument, source_env:, lowered:, env:)
        return argument unless parameter.passing_mode == :in

        operand = foreign_argument_expression(argument)
        return argument if addressable_storage_expression?(operand)

        temp_name = fresh_c_temp_name(env, "foreign_in")
        lowered << IR::LocalDecl.new(
          name: temp_name,
          linkage_name: temp_name,
          type: parameter.type,
          value: lower_contextual_expression(operand, env: source_env, expected_type: parameter.type),
        )
        current_actual_scope(source_env[:scopes])[temp_name] = local_binding(type: parameter.type, linkage_name: temp_name, mutable: false, pointer: false)

        AST::Argument.new(
          name: argument.name,
          value: AST::Identifier.new(name: temp_name),
        )
      end

      def lower_foreign_in_argument_value(parameter, argument, env:)
        address = lower_addr_expression(
          foreign_argument_expression(argument),
          env:,
          target_type: const_pointer_to(parameter.type),
        )

        converted = foreign_identity_projection_expression(address, parameter.boundary_type)
        return converted if converted

        raise LoweringError, "unsupported foreign in boundary mapping #{parameter.type} as #{parameter.boundary_type}"
      end

      def lower_foreign_char_pointer_buffer_argument_value(parameter, argument, env:)
        public_type = parameter.type

        if char_array_text_type?(public_type)
          return lower_char_array_data_pointer(argument.value, env:)
        end

        if str_buffer_type?(public_type)
          return IR::Call.new(
            callee: "mt_str_buffer_prepare_write",
            arguments: [
              lower_str_buffer_data_pointer(argument.value, env:),
              IR::IntegerLiteral.new(value: str_buffer_capacity(public_type), type: @ctx.types.fetch("ptr_uint")),
              lower_str_buffer_dirty_pointer(argument.value, env:),
            ],
            type: parameter.boundary_type,
          )
        end

        lowered_value = lower_contextual_expression(argument.value, env:, expected_type: public_type)
        return IR::Member.new(receiver: lowered_value, member: "data", type: parameter.boundary_type) if public_type.is_a?(Types::Span) && public_type.element_type == @ctx.types.fetch("char")

        converted = foreign_identity_projection_expression(lowered_value, parameter.boundary_type)
        return converted if converted

        raise LoweringError, "unsupported foreign boundary mapping #{public_type} as #{parameter.boundary_type}"
      end

      def lower_foreign_call_inline(expression, binding, env:, type:)
        previous_type_substitutions = @ctx.current_type_substitutions
        @ctx.current_type_substitutions = binding.type_substitutions

        owner_analysis = analysis_for_module(binding.owner.module_name)
        mapping_expression = foreign_mapping_expression(binding.ast)
        reference_counts = foreign_mapping_reference_counts(mapping_expression)
        mapping_env = duplicate_env(env)

        binding.ast.params.each_with_index do |param_ast, index|
          public_alias = param_ast.boundary_type ? foreign_mapping_public_alias_name(param_ast.name) : nil
          total_references = reference_counts.fetch(param_ast.name, 0)
          total_references += reference_counts.fetch(public_alias, 0) if public_alias
          next unless total_references > 1
          next if duplicable_foreign_argument_expression?(expression.arguments.fetch(index).value)

          raise LoweringError, "foreign call #{binding.name} cannot be used inline because #{param_ast.name} is referenced multiple times in its mapping; use it as a statement, local initializer, assignment, or return expression"
        end

        binding.ast.params.each_with_index do |param_ast, index|
          parameter = binding.type.params.fetch(index)
          next unless automatic_foreign_cstr_temp_needed?(parameter, expression.arguments.fetch(index).value, env:) ||
                      automatic_foreign_cstr_list_temp_needed?(parameter, expression.arguments.fetch(index).value, env:)

          raise LoweringError, "foreign call #{binding.name} cannot be used inline because #{param_ast.name} needs temporary foreign text storage; use it as a statement, local initializer, assignment, or return expression"
        end

        expression.arguments.drop(binding.type.params.length).each do |argument|
          next unless automatic_variadic_foreign_cstr_temp_needed?(argument.value, env:)

          raise LoweringError, "foreign call #{binding.name} cannot be used inline because a variadic argument needs temporary foreign text storage; use it as a statement, local initializer, assignment, or return expression"
        end

        binding.ast.params.each_with_index do |param_ast, index|
          parameter = binding.type.params.fetch(index)
          argument = expression.arguments.fetch(index)
          next unless parameter.passing_mode == :in
          next if addressable_storage_expression?(foreign_argument_expression(argument))

          raise LoweringError, "foreign call #{binding.name} cannot be used inline because #{param_ast.name} needs temporary in storage; use it as a statement, local initializer, assignment, or return expression"
        end

        replacements = {}
        binding.ast.params.each_with_index do |param_ast, index|
          parameter = binding.type.params.fetch(index)
          temp_type = parameter.boundary_type || parameter.type
          public_alias = param_ast.boundary_type ? foreign_mapping_public_alias_name(param_ast.name) : nil

          if reference_counts.fetch(param_ast.name, 0).positive?
            current_actual_scope(mapping_env[:scopes])[param_ast.name] = local_binding(type: temp_type, linkage_name: param_ast.name, mutable: false, pointer: false)
            replacements[param_ast.name] = lower_foreign_argument_value(parameter, expression.arguments.fetch(index), env:)
          end

          next unless public_alias && reference_counts.fetch(public_alias, 0).positive?

          current_actual_scope(mapping_env[:scopes])[public_alias] = local_binding(type: parameter.type, linkage_name: public_alias, mutable: false, pointer: false)
          replacements[public_alias] = lower_contextual_expression(expression.arguments.fetch(index).value, env:, expected_type: parameter.type)
        end

        lowered_expression = lower_inline_foreign_mapping_expression(
          mapping_expression,
          mapping_env:,
          replacements:,
          owner_analysis:,
          expected_type: type,
        )
        lowered_expression = append_variadic_foreign_call_arguments(
          lowered_expression,
          expression.arguments,
          binding.type,
          env:,
        )

        converted = foreign_identity_projection_expression(lowered_expression, type)
        return converted if converted

        lowered_expression
      ensure
        @ctx.current_type_substitutions = previous_type_substitutions
      end

      def append_variadic_foreign_call_arguments(lowered_expression, arguments, function_type, env:, lowered: nil, cleanup: nil)
        return lowered_expression unless function_type.variadic

        extra_arguments = arguments.drop(function_type.params.length)
        return lowered_expression if extra_arguments.empty?
        return lowered_expression unless lowered_expression.is_a?(IR::Call)

        IR::Call.new(
          callee: lowered_expression.callee,
          arguments: lowered_expression.arguments + extra_arguments.map { |argument| lower_variadic_foreign_argument(argument, env:, lowered:, cleanup:) },
          type: lowered_expression.type,
        )
      end

      def lower_variadic_foreign_argument(argument, env:, lowered:, cleanup:)
        actual_type = infer_expression_type(argument.value, env:)
        return lower_contextual_expression(argument.value, env:, expected_type: nil) unless actual_type == @ctx.types.fetch("str")

        lowered_argument = lower_foreign_argument_value(
          Types::Parameter.new("__mt_variadic", actual_type, passing_mode: :plain, boundary_type: @ctx.types.fetch("cstr")),
          argument,
          env:,
        )
        return lowered_argument unless temporary_foreign_cstr_expression?(lowered_argument)

        raise LoweringError, "foreign variadic call cannot be used inline because an extra argument needs temporary foreign text storage; use it as a statement, local initializer, assignment, or return expression" unless lowered && cleanup

        temp_name = fresh_c_temp_name(env, "foreign_arg")
        lowered << IR::LocalDecl.new(
          name: temp_name,
          linkage_name: temp_name,
          type: @ctx.types.fetch("cstr"),
          value: lowered_argument,
        )
        cleanup << IR::ExpressionStmt.new(
          expression: IR::Call.new(
            callee: "mt_free_foreign_cstr_temp",
            arguments: [IR::Name.new(name: temp_name, type: @ctx.types.fetch("cstr"), pointer: false)],
            type: @ctx.types.fetch("void"),
          ),
        )
        IR::Name.new(name: temp_name, type: @ctx.types.fetch("cstr"), pointer: false)
      end

      def lower_inline_foreign_mapping_expression(expression, mapping_env:, replacements:, owner_analysis:, expected_type: nil)
        unless foreign_mapping_uses_inline_replacement?(expression, replacements)
          return with_analysis_context(owner_analysis) do
            lower_expression(expression, env: mapping_env, expected_type:)
          end
        end

        type = with_analysis_context(owner_analysis) do
          infer_expression_type(expression, env: mapping_env, expected_type:)
        end

        case expression
        when AST::Identifier
          replacements.fetch(expression.name)
        when AST::MemberAccess
          receiver_type = with_analysis_context(owner_analysis) do
            infer_expression_type(expression.receiver, env: mapping_env)
          end
          receiver = lower_inline_foreign_mapping_expression(
            expression.receiver,
            mapping_env:,
            replacements:,
            owner_analysis:,
          )
          IR::Member.new(receiver:, member: member_c_name(receiver_type, expression.member), type:)
        when AST::IndexAccess
          receiver_type = with_analysis_context(owner_analysis) do
            infer_expression_type(expression.receiver, env: mapping_env)
          end
          receiver = lower_inline_foreign_mapping_expression(
            expression.receiver,
            mapping_env:,
            replacements:,
            owner_analysis:,
          )
          index = lower_inline_foreign_mapping_expression(
            expression.index,
            mapping_env:,
            replacements:,
            owner_analysis:,
          )
          if array_type?(receiver_type) && addressable_storage_expression?(expression.receiver)
            IR::CheckedIndex.new(receiver:, index:, receiver_type:, type:)
          elsif receiver_type.is_a?(Types::Span)
            IR::CheckedSpanIndex.new(receiver:, index:, receiver_type:, type:)
          else
            IR::Index.new(receiver:, index:, type:)
          end
        when AST::Call
          lower_inline_foreign_mapping_call(expression, mapping_env:, replacements:, owner_analysis:, type:)
        when AST::UnaryOp
          IR::Unary.new(
            operator: expression.operator,
            operand: lower_inline_foreign_mapping_expression(
              expression.operand,
              mapping_env:,
              replacements:,
              owner_analysis:,
              expected_type: type,
            ),
            type:,
          )
        when AST::BinaryOp
          left_type, right_type = with_analysis_context(owner_analysis) do
            infer_binary_operand_types(expression, env: mapping_env, expected_type: type)
          end
          operand_type = promoted_binary_operand_type(expression.operator, left_type, right_type)
          left = lower_inline_foreign_mapping_expression(
            expression.left,
            mapping_env:,
            replacements:,
            owner_analysis:,
            expected_type: operand_type || type,
          )
          right = lower_inline_foreign_mapping_expression(
            expression.right,
            mapping_env:,
            replacements:,
            owner_analysis:,
            expected_type: operand_type || left.type,
          )
          left = cast_expression(left, operand_type) if operand_type
          right = cast_expression(right, operand_type) if operand_type
          IR::Binary.new(operator: expression.operator, left:, right:, type:)
        when AST::IfExpr
          IR::Conditional.new(
            condition: lower_inline_foreign_mapping_expression(
              expression.condition,
              mapping_env:,
              replacements:,
              owner_analysis:,
              expected_type: @ctx.types.fetch("bool"),
            ),
            then_expression: lower_inline_foreign_mapping_expression(
              expression.then_expression,
              mapping_env:,
              replacements:,
              owner_analysis:,
              expected_type: type,
            ),
            else_expression: lower_inline_foreign_mapping_expression(
              expression.else_expression,
              mapping_env:,
              replacements:,
              owner_analysis:,
              expected_type: type,
            ),
            type:,
          )
        when AST::PrefixCast
          lowered_expr = lower_inline_foreign_mapping_expression(
            expression.expression,
            mapping_env:,
            replacements:,
            owner_analysis:,
          )
          IR::Cast.new(target_type: type, expression: lowered_expr, type:)
        else
          with_analysis_context(owner_analysis) do
            lower_expression(expression, env: mapping_env, expected_type:)
          end
        end
      end

      def lower_inline_foreign_mapping_call(expression, mapping_env:, replacements:, owner_analysis:, type:)
        kind, callee_name, receiver, callee_type, callee_binding = with_analysis_context(owner_analysis) do
          resolve_callee(expression.callee, mapping_env, arguments: expression.arguments)
        end

        case kind
        when :function
          raise LoweringError, "consuming foreign calls must be top-level expression statements" if callee_binding && foreign_function_binding?(callee_binding) && foreign_call_consumes_binding?(callee_binding)

          arguments = expression.arguments.map.with_index do |argument, index|
            expected_arg_type = index < callee_type.params.length ? callee_type.params[index].type : nil
            lower_inline_foreign_mapping_expression(
              argument.value,
              mapping_env:,
              replacements:,
              owner_analysis:,
              expected_type: expected_arg_type,
            )
          end
          IR::Call.new(callee: callee_name, arguments:, type:)
        when :reinterpret
          argument = expression.arguments.fetch(0)
          source_type = with_analysis_context(owner_analysis) do
            infer_expression_type(argument.value, env: mapping_env)
          end
          IR::ReinterpretExpr.new(
            target_type: type,
            source_type:,
            expression: lower_inline_foreign_mapping_expression(
              argument.value,
              mapping_env:,
              replacements:,
              owner_analysis:,
              expected_type: source_type,
            ),
            type:,
          )
        when :hash
          resolution = with_analysis_context(owner_analysis) do
            resolve_hash_specialization(expression.callee, env: mapping_env)
          end
          argument = expression.arguments.fetch(0)
          IR::Call.new(
            callee: resolution.callee_name,
            arguments: [
              lower_inline_hash_operation_argument(
                argument.value,
                mapping_env:,
                replacements:,
                owner_analysis:,
                target_type: resolution.target_type,
              ),
            ],
            type:,
          )
        when :equal
          resolution = with_analysis_context(owner_analysis) do
            resolve_equal_specialization(expression.callee, env: mapping_env)
          end
          left = expression.arguments.fetch(0)
          right = expression.arguments.fetch(1)
          IR::Call.new(
            callee: resolution.callee_name,
            arguments: [
              lower_inline_hash_operation_argument(
                left.value,
                mapping_env:,
                replacements:,
                owner_analysis:,
                target_type: resolution.target_type,
              ),
              lower_inline_hash_operation_argument(
                right.value,
                mapping_env:,
                replacements:,
                owner_analysis:,
                target_type: resolution.target_type,
              ),
            ],
            type:,
          )
        when :order
          resolution = with_analysis_context(owner_analysis) do
            resolve_order_specialization(expression.callee, env: mapping_env)
          end
          left = expression.arguments.fetch(0)
          right = expression.arguments.fetch(1)
          IR::Call.new(
            callee: resolution.callee_name,
            arguments: [
              lower_inline_hash_operation_argument(
                left.value,
                mapping_env:,
                replacements:,
                owner_analysis:,
                target_type: resolution.target_type,
              ),
              lower_inline_hash_operation_argument(
                right.value,
                mapping_env:,
                replacements:,
                owner_analysis:,
                target_type: resolution.target_type,
              ),
            ],
            type:,
          )
        when :zero
          IR::ZeroInit.new(type:)
        when :ref_of
          argument = expression.arguments.fetch(0)
          lowered_argument = lower_inline_foreign_mapping_expression(
            argument.value,
            mapping_env:,
            replacements:,
            owner_analysis:,
          )
          if lowered_argument.is_a?(IR::Name) && lowered_argument.pointer
            cast_expression(lowered_argument, type)
          elsif lowered_argument.is_a?(IR::Unary) && lowered_argument.operator == "*"
            cast_expression(lowered_argument.operand, type)
          else
            IR::AddressOf.new(expression: lowered_argument, type:)
          end
        when :const_ptr_of
          argument = expression.arguments.fetch(0)
          lowered_argument = lower_inline_foreign_mapping_expression(
            argument.value,
            mapping_env:,
            replacements:,
            owner_analysis:,
          )
          if lowered_argument.is_a?(IR::Name) && lowered_argument.pointer
            cast_expression(lowered_argument, type)
          elsif lowered_argument.is_a?(IR::Unary) && lowered_argument.operator == "*"
            cast_expression(lowered_argument.operand, type)
          else
            IR::AddressOf.new(expression: lowered_argument, type:)
          end
        when :read
          argument = expression.arguments.fetch(0)
          IR::Unary.new(
            operator: "*",
            operand: lower_inline_foreign_mapping_expression(
              argument.value,
              mapping_env:,
              replacements:,
              owner_analysis:,
            ),
            type:,
          )
        when :str_buffer_capacity
          receiver_type = with_analysis_context(owner_analysis) do
            infer_expression_type(receiver, env: mapping_env)
          end
          IR::IntegerLiteral.new(value: str_buffer_capacity(receiver_type), type:)
        when :ptr_of
          argument = expression.arguments.fetch(0)
          argument_type = with_analysis_context(owner_analysis) do
            infer_expression_type(argument.value, env: mapping_env)
          end
          if ref_type?(argument_type)
            IR::Cast.new(
              target_type: type,
              expression: lower_inline_foreign_mapping_expression(
                argument.value,
                mapping_env:,
                replacements:,
                owner_analysis:,
              ),
              type:,
            )
          else
            lower_addr_expression(
              argument.value,
              env: mapping_env,
              target_type: type,
            )
          end
        else
          raise LoweringError, "unsupported inline foreign mapping call kind #{kind}"
        end
      end

      def lower_inline_hash_operation_argument(expression, mapping_env:, replacements:, owner_analysis:, target_type:)
        actual_type = with_analysis_context(owner_analysis) do
          infer_expression_type(expression, env: mapping_env)
        end
        lowered_expression = lower_inline_foreign_mapping_expression(
          expression,
          mapping_env:,
          replacements:,
          owner_analysis:,
        )
        pointer_type = const_pointer_to(target_type)

        if pointer_type?(actual_type) || ref_type?(actual_type)
          return cast_expression(lowered_expression, pointer_type)
        end

        return cast_expression(lowered_expression.operand, pointer_type) if lowered_expression.is_a?(IR::Unary) && lowered_expression.operator == "*"

        IR::AddressOf.new(expression: lowered_expression, type: pointer_type)
      end

      def foreign_mapping_uses_inline_replacement?(expression, replacements)
        case expression
        when AST::Identifier
          replacements.key?(expression.name)
        when AST::MemberAccess
          foreign_mapping_uses_inline_replacement?(expression.receiver, replacements)
        when AST::IndexAccess
          foreign_mapping_uses_inline_replacement?(expression.receiver, replacements) ||
            foreign_mapping_uses_inline_replacement?(expression.index, replacements)
        when AST::Specialization, AST::Call
          foreign_mapping_uses_inline_replacement?(expression.callee, replacements) ||
            expression.arguments.any? { |argument| foreign_mapping_uses_inline_replacement?(argument.value, replacements) }
        when AST::UnaryOp
          foreign_mapping_uses_inline_replacement?(expression.operand, replacements)
        when AST::BinaryOp
          foreign_mapping_uses_inline_replacement?(expression.left, replacements) ||
            foreign_mapping_uses_inline_replacement?(expression.right, replacements)
        when AST::IfExpr
          foreign_mapping_uses_inline_replacement?(expression.condition, replacements) ||
            foreign_mapping_uses_inline_replacement?(expression.then_expression, replacements) ||
            foreign_mapping_uses_inline_replacement?(expression.else_expression, replacements)
        when AST::UnsafeExpr
          foreign_mapping_uses_inline_replacement?(expression.expression, replacements)
        when AST::PrefixCast
          foreign_mapping_uses_inline_replacement?(expression.expression, replacements)
        else
          false
        end
      end

      def raw_pointer_argument_expression(operand)
        AST::Call.new(
          callee: AST::Identifier.new(name: "ptr_of"),
          arguments: [AST::Argument.new(name: nil, value: operand)],
        )
      end

      def foreign_function_binding?(binding)
        binding.ast.is_a?(AST::ForeignFunctionDecl)
      end

      def foreign_mapping_expression(decl)
        return decl.mapping unless foreign_mapping_auto_call_shorthand?(decl.mapping)

        AST::Call.new(
          callee: decl.mapping,
          arguments: decl.params.map { |param| AST::Argument.new(name: nil, value: AST::Identifier.new(name: param.name)) },
        )
      end

      def foreign_mapping_auto_call_shorthand?(expression)
        case expression
        when AST::Identifier
          true
        when AST::MemberAccess
          foreign_mapping_auto_call_shorthand?(expression.receiver)
        when AST::Specialization
          foreign_mapping_auto_call_shorthand?(expression.callee)
        else
          false
        end
      end

      def foreign_mapping_public_alias_name(name)
        "#{name}_public"
      end

      def substitute_foreign_mapping_expression(expression, replacements)
        case expression
        when AST::Identifier
          replacements.fetch(expression.name, expression)
        when AST::MemberAccess
          AST::MemberAccess.new(receiver: substitute_foreign_mapping_expression(expression.receiver, replacements), member: expression.member)
        when AST::IndexAccess
          AST::IndexAccess.new(
            receiver: substitute_foreign_mapping_expression(expression.receiver, replacements),
            index: substitute_foreign_mapping_expression(expression.index, replacements),
          )
        when AST::Specialization
          AST::Specialization.new(
            callee: substitute_foreign_mapping_expression(expression.callee, replacements),
            arguments: expression.arguments.map do |argument|
              AST::Argument.new(name: argument.name, value: substitute_foreign_mapping_expression(argument.value, replacements))
            end,
          )
        when AST::Call
          AST::Call.new(
            callee: substitute_foreign_mapping_expression(expression.callee, replacements),
            arguments: expression.arguments.map do |argument|
              AST::Argument.new(name: argument.name, value: substitute_foreign_mapping_expression(argument.value, replacements))
            end,
          )
        when AST::UnaryOp
          AST::UnaryOp.new(operator: expression.operator, operand: substitute_foreign_mapping_expression(expression.operand, replacements))
        when AST::BinaryOp
          AST::BinaryOp.new(
            operator: expression.operator,
            left: substitute_foreign_mapping_expression(expression.left, replacements),
            right: substitute_foreign_mapping_expression(expression.right, replacements),
          )
        when AST::IfExpr
          AST::IfExpr.new(
            condition: substitute_foreign_mapping_expression(expression.condition, replacements),
            then_expression: substitute_foreign_mapping_expression(expression.then_expression, replacements),
            else_expression: substitute_foreign_mapping_expression(expression.else_expression, replacements),
          )
        when AST::UnsafeExpr
          AST::UnsafeExpr.new(expression: substitute_foreign_mapping_expression(expression.expression, replacements))
        when AST::PrefixCast
          AST::PrefixCast.new(target_type: expression.target_type, expression: substitute_foreign_mapping_expression(expression.expression, replacements))
        else
          expression
        end
      end

      def foreign_mapping_reference_counts(expression, counts = Hash.new(0))
        case expression
        when AST::Identifier
          counts[expression.name] += 1
        when AST::MemberAccess
          foreign_mapping_reference_counts(expression.receiver, counts)
        when AST::IndexAccess
          foreign_mapping_reference_counts(expression.receiver, counts)
          foreign_mapping_reference_counts(expression.index, counts)
        when AST::Specialization, AST::Call
          foreign_mapping_reference_counts(expression.callee, counts)
          expression.arguments.each { |argument| foreign_mapping_reference_counts(argument.value, counts) }
        when AST::UnaryOp
          foreign_mapping_reference_counts(expression.operand, counts)
        when AST::BinaryOp
          foreign_mapping_reference_counts(expression.left, counts)
          foreign_mapping_reference_counts(expression.right, counts)
        when AST::IfExpr
          foreign_mapping_reference_counts(expression.condition, counts)
          foreign_mapping_reference_counts(expression.then_expression, counts)
          foreign_mapping_reference_counts(expression.else_expression, counts)
        when AST::UnsafeExpr
          foreign_mapping_reference_counts(expression.expression, counts)
        when AST::PrefixCast
          foreign_mapping_reference_counts(expression.expression, counts)
        end

        counts
      end

      def duplicable_foreign_argument_expression?(expression)
        case expression
        when AST::Identifier, AST::IntegerLiteral, AST::FloatLiteral, AST::StringLiteral, AST::BooleanLiteral, AST::NullLiteral,
             IR::Name, IR::IntegerLiteral, IR::FloatLiteral, IR::StringLiteral, IR::BooleanLiteral, IR::NullLiteral
          true
        when AST::MemberAccess
          duplicable_foreign_argument_expression?(expression.receiver)
        when IR::Member
          duplicable_foreign_argument_expression?(expression.receiver)
        when AST::UnaryOp
          duplicable_foreign_argument_expression?(expression.operand)
        when IR::Unary
          duplicable_foreign_argument_expression?(expression.operand)
        when AST::BinaryOp
          duplicable_foreign_argument_expression?(expression.left) && duplicable_foreign_argument_expression?(expression.right)
        when IR::Binary
          duplicable_foreign_argument_expression?(expression.left) && duplicable_foreign_argument_expression?(expression.right)
        else
          false
        end
      end

      def foreign_argument_needs_temporary_binding?(expression, reference_count:)
        return true if reference_count > 1 && !duplicable_foreign_argument_expression?(expression)

        !inlineable_foreign_argument_expression?(expression)
      end

      def automatic_foreign_cstr_list_temp_needed?(parameter, _expression, env: nil)
        return false unless parameter.type.is_a?(Types::Span) && parameter.type.element_type == @ctx.types.fetch("str")
        return false unless parameter.boundary_type.is_a?(Types::Span)

        boundary_element_type = parameter.boundary_type.element_type
        boundary_element_type == @ctx.types.fetch("cstr") || char_pointer_type?(boundary_element_type)
      end

      def automatic_foreign_cstr_temp_needed?(parameter, expression, env:)
        return false unless parameter.boundary_type == @ctx.types.fetch("cstr") && parameter.type == @ctx.types.fetch("str")
        return false if expression.is_a?(AST::StringLiteral) && !expression.cstring
        return false if cstr_backed_expression?(expression, env)

        infer_expression_type(expression, env:) != @ctx.types.fetch("cstr")
      end

      def automatic_variadic_foreign_cstr_temp_needed?(expression, env:)
        return false if expression.is_a?(AST::StringLiteral) && !expression.cstring
        return false if cstr_backed_expression?(expression, env)

        infer_expression_type(expression, env:) == @ctx.types.fetch("str")
      end

      def temporary_foreign_cstr_expression?(expression)
        expression.is_a?(IR::Call) && expression.callee == "mt_foreign_str_to_cstr_temp"
      end

      def lower_specialization(expression, env:, type:)
        if expression.callee.is_a?(AST::Identifier) && expression.callee.name == "zero"
          return IR::ZeroInit.new(type:)
        end

        if expression.callee.is_a?(AST::Identifier) && expression.callee.name == "default"
          resolution = resolve_default_specialization(expression, env:)
          return IR::Call.new(callee: resolution.callee_name, arguments: [], type:) if resolution.binding

          return IR::ZeroInit.new(type:)
        end

        if (literal = lower_compile_time_literal(compile_time_const_value(expression, env:), type))
          return literal
        end

        if (callable_resolution = resolve_specialized_callable_binding(expression, env:))
          callable_kind, function_binding, = callable_resolution
          raise LoweringError, "specialized method must be called" if callable_kind == :method

          raise LoweringError, "foreign function #{function_binding.name} cannot be used as a value" if foreign_function_binding?(function_binding)

          if function_binding.external
            return IR::Name.new(name: external_function_c_name(function_binding), type:, pointer: false)
          end

          return IR::Name.new(
            name: function_binding_c_name(function_binding, module_name: function_binding.owner.module_name),
            type:,
            pointer: false,
          )
        end

        raise LoweringError, "specialization #{expression.callee.name} must be called" if expression.callee.is_a?(AST::Identifier)

        raise LoweringError, "unsupported specialization #{expression.class.name}"
      end

      def atomic_method_kind(receiver_type, name)
        return unless atomic_type?(receiver_type)

        case name
        when "load" then :atomic_load
        when "store" then :atomic_store
        when "add" then :atomic_add
        when "sub" then :atomic_sub
        when "exchange" then :atomic_exchange
        when "compare_exchange" then :atomic_compare_exchange
        end
      end

      def lower_atomic_method_call(kind, receiver, expression, env:, type:)
        receiver_type = infer_expression_type(receiver, env:)
        elem_type = atomic_element_type(receiver_type)
        ptr_type = Types::GenericInstance.new("ptr", [elem_type])
        receiver_ir = lower_expression(receiver, env:)
        addr = IR::AddressOf.new(expression: receiver_ir, type: ptr_type)
        seq_cst = IR::IntegerLiteral.new(value: 5, type: @ctx.types.fetch("int"))

        case kind
        when :atomic_load
          IR::Call.new(callee: "__atomic_load_n", arguments: [addr, seq_cst], type: elem_type)
        when :atomic_store
          arg = lower_contextual_expression(expression.arguments.first.value, env:, expected_type: elem_type)
          IR::Call.new(callee: "__atomic_store_n", arguments: [addr, arg, seq_cst], type:)
        when :atomic_add
          arg = lower_contextual_expression(expression.arguments.first.value, env:, expected_type: elem_type)
          IR::Call.new(callee: "__atomic_fetch_add", arguments: [addr, arg, seq_cst], type: elem_type)
        when :atomic_sub
          arg = lower_contextual_expression(expression.arguments.first.value, env:, expected_type: elem_type)
          IR::Call.new(callee: "__atomic_fetch_sub", arguments: [addr, arg, seq_cst], type: elem_type)
        when :atomic_exchange
          arg = lower_contextual_expression(expression.arguments.first.value, env:, expected_type: elem_type)
          IR::Call.new(callee: "__atomic_exchange_n", arguments: [addr, arg, seq_cst], type: elem_type)
        when :atomic_compare_exchange
          raise LoweringError, "atomic compare_exchange is not yet implemented in the built-in surface; use std.sync.AtomicUint for compare-exchange operations"
        end
      end
  end
end

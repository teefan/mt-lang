# frozen_string_literal: true

module MilkTea
  module LowererExpressions
    private


      def prepare_expression_with_cleanups(expression, env:, expected_type: nil, allow_root_statement_foreign: false, materialize_array_calls: true, allow_void_propagation: false)
        env[:prepared_expression_cleanups] ||= []
        start_index = env[:prepared_expression_cleanups].length
        setup, prepared_expression = prepare_expression_for_inline_lowering(
          expression,
          env:,
          expected_type:,
          allow_root_statement_foreign:,
          materialize_array_calls:,
          allow_void_propagation:,
        )
        cleanup_count = env[:prepared_expression_cleanups].length - start_index
        cleanups = cleanup_count.positive? ? env[:prepared_expression_cleanups].slice!(start_index, cleanup_count) : []
        [setup, prepared_expression, cleanups || []]
      end

      def prepare_expression_for_inline_lowering(expression, env:, expected_type: nil, allow_root_statement_foreign: false, materialize_array_calls: true, allow_void_propagation: false)
        return [[], expression] unless expression

        if expression.is_a?(AST::Call) &&
            (foreign_call = foreign_call_info(expression, env)) && !allow_root_statement_foreign &&
            foreign_call_requires_statement_lowering?(expression, foreign_call[:binding], env:)
          type = infer_expression_type(expression, env:, expected_type:)
          setup, value = lower_foreign_call_statement(foreign_call, env:, expected_type: type, statement_position: false)
          return materialize_prepared_expression(setup, value, env:, type:, prefix: "foreign_expr")
        end

        case expression
        when AST::FormatString
          prepare_format_string_expression_for_inline_lowering(expression, env:)
        when AST::MemberAccess
          receiver_setup, receiver = prepare_expression_for_inline_lowering(expression.receiver, env:)
          [receiver_setup, AST::MemberAccess.new(receiver:, member: expression.member)]
        when AST::IndexAccess
          receiver_setup, receiver = prepare_expression_for_inline_lowering(expression.receiver, env:)
          index_setup, index = prepare_expression_for_inline_lowering(expression.index, env:)
          [receiver_setup + index_setup, AST::IndexAccess.new(receiver:, index:)]
        when AST::UnaryOp
          return prepare_result_propagation_for_inline_lowering(expression, env:, allow_void_success: allow_void_propagation) if expression.operator == "?"

          operand_setup, operand = prepare_expression_for_inline_lowering(expression.operand, env:, expected_type:)
          [operand_setup, AST::UnaryOp.new(operator: expression.operator, operand:)]
        when AST::BinaryOp
          prepare_binary_expression_for_inline_lowering(expression, env:, expected_type:)
        when AST::IfExpr
          prepare_if_expression_for_inline_lowering(expression, env:, expected_type:)
        when AST::MatchExpr
          prepare_match_expression_for_inline_lowering(expression, env:, expected_type:)
        when AST::UnsafeExpr
          prepare_expression_for_inline_lowering(expression.expression, env:, expected_type:)
        when AST::Call
          prepare_call_expression_for_inline_lowering(
            expression,
            env:,
            expected_type:,
            allow_root_statement_foreign:,
            materialize_array_calls:,
          )
        when AST::ProcExpr
          proc_type = infer_expression_type(expression, env:, expected_type:)
          setup, value = lower_proc_expression_for_local(expression, env:, local_name: fresh_c_temp_name(env, "proc_expr"), proc_type: proc_type)
          materialize_prepared_expression(setup, value, env:, type: proc_type, prefix: "proc_expr")
        when AST::PrefixCast
          setup, prepared_expr = prepare_expression_for_inline_lowering(expression.expression, env:, expected_type:)
          [setup, AST::PrefixCast.new(target_type: expression.target_type, expression: prepared_expr)]
        else
          [[], expression]
        end
      end

      def prepare_call_expression_for_inline_lowering(expression, env:, expected_type: nil, allow_root_statement_foreign: false, materialize_array_calls: true)
        kind, _callee_name, _receiver, callee_type, binding = resolve_callee(expression.callee, env, arguments: expression.arguments)

        if binding && binding.respond_to?(:ast) && kind != :variant_arm_ctor && foreign_function_binding?(binding) && !allow_root_statement_foreign && foreign_call_requires_statement_lowering?(expression, binding, env:)
          type = infer_expression_type(expression, env:, expected_type:)
          setup, value = lower_foreign_call_statement({ call: expression, binding: binding }, env:, expected_type: type, statement_position: false)
          return materialize_prepared_expression(setup, value, env:, type:, prefix: "foreign_expr")
        end

        callee_setup, callee = prepare_expression_for_inline_lowering(expression.callee, env:)
        argument_setup = []
        arguments = expression.arguments.map.with_index do |argument, index|
          expected_arg_type = kind == :function || kind == :method || kind == :associated_method || kind == :callable_value ?
            (index < callee_type.params.length ? callee_type.params[index].type : nil) : nil
          argument_value = argument.value
          argument_value = wrap_task_expression_in_root_proc(argument_value, env:) if task_expression_root_proc_bridge?(argument_value, expected_arg_type, env:)
          argument_value = wrap_expression_in_ref_of(argument_value) if implicit_ref_argument_bridge?(argument_value, expected_arg_type, env:)
          setup, prepared_value = prepare_expression_for_inline_lowering(argument_value, env:, expected_type: expected_arg_type)
          argument_setup.concat(setup)
          AST::Argument.new(name: argument.name, value: prepared_value)
        end

        prepared_call = AST::Call.new(callee:, arguments:)
        return [callee_setup + argument_setup, prepared_call] unless materialize_array_calls && callee_type.respond_to?(:return_type) && array_type?(callee_type.return_type)

        call_type = infer_expression_type(prepared_call, env:, expected_type:)
        materialize_prepared_expression(
          callee_setup + argument_setup,
          lower_expression(prepared_call, env:, expected_type: call_type),
          env:,
          type: call_type,
          prefix: "array_call",
        )
      end

      def prepare_format_string_expression_for_inline_lowering(format_string, env:)
        unless format_string_has_dynamic_parts?(format_string)
          return [[], AST::StringLiteral.new(lexeme: "", value: format_string_static_text(format_string), cstring: false)]
        end

        setup, temp_name = build_dynamic_format_string_temp_setup(format_string, env:)
        temp_value = IR::Name.new(name: temp_name, type: @ctx.types.fetch("str"), pointer: false)
        (env[:prepared_expression_cleanups] ||= []) << [
          IR::ExpressionStmt.new(
            expression: IR::Call.new(
              callee: "mt_format_str_release",
              arguments: [temp_value],
              type: @ctx.types.fetch("void"),
            ),
          ),
        ]

        [setup, AST::Identifier.new(name: temp_name)]
      end

      def build_dynamic_format_string_temp_setup(format_string, env:)
        string_type = @ctx.types.fetch("str")
        dest_name = env[:current_local_name] || env[:lowering_target_name]
        if dest_name
          env[:fmt_counter] ||= {}
          env[:fmt_counter][dest_name] = (env[:fmt_counter][dest_name] || 0) + 1
          suffix = env[:fmt_counter][dest_name] > 1 ? "_#{env[:fmt_counter][dest_name]}" : ""
          base = "__fmt_#{dest_name}#{suffix}"
        else
          base = fresh_c_temp_name(env, "fmt_str")
        end
        temp_name = base
        cap_name = "#{base}_cap"
        off_name = "#{base}_off"
        register_prepared_temp!(env, temp_name, string_type, cstr_backed: true)
        total_cap_value = IR::Name.new(name: cap_name, type: @ctx.types.fetch("ptr_uint"), pointer: false)
        result_value = IR::Name.new(name: temp_name, type: string_type, pointer: false)
        offset_value = IR::Name.new(name: off_name, type: @ctx.types.fetch("ptr_uint"), pointer: false)

        setup, format_parts = build_dynamic_format_string_parts(format_string, env:)
        literal_capacity = format_parts.sum { |part| part[:kind] == :text ? part[:value].bytesize : 0 }

        setup << IR::LocalDecl.new(
          name: cap_name, linkage_name: cap_name, type: @ctx.types.fetch("ptr_uint"),
          value: IR::IntegerLiteral.new(value: literal_capacity, type: @ctx.types.fetch("ptr_uint")),
        )

        format_parts.each do |part|
          next if part[:kind] == :text
          part_len = format_string_part_length_expression(part, env:)
          setup << IR::Assignment.new(
            target: total_cap_value, operator: "=",
            value: IR::Binary.new(operator: "+", left: total_cap_value, right: part_len, type: @ctx.types.fetch("ptr_uint")),
          )
        end

        setup << IR::LocalDecl.new(
          name: temp_name, linkage_name: temp_name, type: string_type,
          value: IR::Call.new(callee: "mt_format_str_make", arguments: [total_cap_value], type: string_type),
        )
        setup << IR::LocalDecl.new(
          name: off_name, linkage_name: off_name, type: @ctx.types.fetch("ptr_uint"),
          value: IR::IntegerLiteral.new(value: 0, type: @ctx.types.fetch("ptr_uint")),
        )

        format_parts.each do |part|
          setup.concat(format_string_part_append_statements(part, result_value, offset_value, env:))
        end

        [setup, temp_name]
      end

      def format_string_static_text(format_string)
        format_string.parts.filter_map do |part|
          next unless part.is_a?(AST::FormatTextPart)

          part.value
        end.join
      end

      def build_dynamic_format_string_parts(format_string, env:)
        format_parts = []
        setup = []

        format_string.parts.each do |part|
          if part.is_a?(AST::FormatTextPart)
            next if part.value.empty?

            format_parts << { kind: :text, value: part.value }
            next
          end

          expression_setup, prepared_expression = prepare_expression_for_inline_lowering(part.expression, env:)
          setup.concat(expression_setup)
          value_type = infer_expression_type(prepared_expression, env:)

          if part.format_spec
            case part.format_spec[:kind]
            when :precision
              precision = part.format_spec[:value]
              append_argument_type = @ctx.types.fetch("double")
              parameter_linkage_name = fresh_c_temp_name(env, "fmt_part")
              setup << IR::LocalDecl.new(
                name: parameter_linkage_name,
                linkage_name: parameter_linkage_name,
                type: append_argument_type,
                value: cast_expression(
                  lower_contextual_expression(prepared_expression, env:, expected_type: value_type),
                  append_argument_type,
                ),
              )
              format_parts << {
                kind: :precision_expression,
                append_function_name: "append_double_precision",
                parameter_linkage_name: parameter_linkage_name,
                parameter_type: append_argument_type,
                precision: precision,
              }
            when :hex
              append_function_name, append_argument_type = format_string_hex_append_plan(value_type, uppercase: part.format_spec[:uppercase])
              parameter_linkage_name = fresh_c_temp_name(env, "fmt_part")
              setup << IR::LocalDecl.new(
                name: parameter_linkage_name,
                linkage_name: parameter_linkage_name,
                type: append_argument_type,
                value: cast_expression(
                  lower_contextual_expression(prepared_expression, env:, expected_type: value_type),
                  append_argument_type,
                ),
              )
              format_parts << {
                kind: :expression,
                append_function_name: append_function_name,
                parameter_linkage_name: parameter_linkage_name,
                parameter_type: append_argument_type,
              }
            when :oct
              append_function_name, append_argument_type = format_string_oct_append_plan(value_type, uppercase: part.format_spec[:uppercase])
              parameter_linkage_name = fresh_c_temp_name(env, "fmt_part")
              setup << IR::LocalDecl.new(
                name: parameter_linkage_name,
                linkage_name: parameter_linkage_name,
                type: append_argument_type,
                value: cast_expression(
                  lower_contextual_expression(prepared_expression, env:, expected_type: value_type),
                  append_argument_type,
                ),
              )
              format_parts << {
                kind: :expression,
                append_function_name: append_function_name,
                parameter_linkage_name: parameter_linkage_name,
                parameter_type: append_argument_type,
              }
            when :bin
              append_function_name, append_argument_type = format_string_bin_append_plan(value_type, uppercase: part.format_spec[:uppercase])
              parameter_linkage_name = fresh_c_temp_name(env, "fmt_part")
              setup << IR::LocalDecl.new(
                name: parameter_linkage_name,
                linkage_name: parameter_linkage_name,
                type: append_argument_type,
                value: cast_expression(
                  lower_contextual_expression(prepared_expression, env:, expected_type: value_type),
                  append_argument_type,
                ),
              )
              format_parts << {
                kind: :expression,
                append_function_name: append_function_name,
                parameter_linkage_name: parameter_linkage_name,
                parameter_type: append_argument_type,
              }
            else
              raise LoweringError, "unsupported format spec #{part.format_spec.inspect}"
            end
          else
            append_plan = format_string_append_plan(value_type, context: "formatted string interpolation of #{value_type}")
            parameter_linkage_name = fresh_c_temp_name(env, "fmt_part")
            setup << IR::LocalDecl.new(
              name: parameter_linkage_name,
              linkage_name: parameter_linkage_name,
              type: append_plan[:append_argument_type],
              value: cast_expression(
                lower_contextual_expression(prepared_expression, env:, expected_type: value_type),
                append_plan[:append_argument_type],
              ),
            )

            if append_plan[:kind] == :custom
              register_prepared_temp!(env, parameter_linkage_name, append_plan[:append_argument_type])
              part_info = {
                kind: :custom_expression,
                parameter_linkage_name: parameter_linkage_name,
                parameter_type: append_plan[:append_argument_type],
                format_binding: append_plan[:binding],
                append_output_type: append_plan[:append_output_type],
              }
              expected_length_linkage_name = fresh_c_temp_name(env, "fmt_part_len")
              setup << IR::LocalDecl.new(
                name: expected_length_linkage_name,
                linkage_name: expected_length_linkage_name,
                type: @ctx.types.fetch("ptr_uint"),
                value: IR::Call.new(
                  callee: append_plan[:binding].length_callee_name,
                  arguments: [format_string_custom_receiver_argument(part_info, hook: :length, env:)],
                  type: @ctx.types.fetch("ptr_uint"),
                ),
              )
              format_parts << part_info.merge(expected_length_linkage_name:)
            else
              format_parts << {
                kind: :expression,
                append_function_name: append_plan[:append_function_name],
                parameter_linkage_name: parameter_linkage_name,
                parameter_type: append_plan[:append_argument_type],
              }
            end
          end
        end

        [setup, format_parts]
      end

      def format_string_has_dynamic_parts?(format_string)
        format_string.parts.any? { |part| part.is_a?(AST::FormatExprPart) }
      end

      def explicit_format_sink_call_info(expression, env)
        return unless expression.is_a?(AST::Call)

        kind, _callee_name, receiver, callee_type, callee_binding = resolve_callee(expression.callee, env, arguments: expression.arguments)

        case kind
        when :function
          return unless callee_binding&.owner&.module_name == "std.fmt"
          return unless expression.arguments.length == 2

          operation = case callee_binding.name
                      when "append_format"
                        :append
                      when "assign_format"
                        :assign
                      end
          return unless operation

          format_string = expression.arguments.fetch(1).value
          return unless format_string.is_a?(AST::FormatString)

          {
            operation:,
            sink_expression: expression.arguments.fetch(0).value,
            sink_expected_type: callee_type.params.fetch(0).type,
            format_string:,
            sink_kind: :string,
            method_call: false,
            callee_type:,
            callee_binding:,
          }
        when :method
          return unless callee_binding&.owner&.module_name == "std.string"
          return unless string_builder_type?(callee_type.receiver_type)
          return unless expression.arguments.length == 1

          operation = case callee_binding.name
                      when "append_format"
                        :append
                      when "assign_format"
                        :assign
                      end
          return unless operation

          format_string = expression.arguments.fetch(0).value
          return unless format_string.is_a?(AST::FormatString)

          {
            operation:,
            sink_expression: receiver,
            sink_expected_type: callee_type.receiver_type,
            format_string:,
            sink_kind: :string,
            method_call: true,
            callee_type:,
            callee_binding:,
          }
        when :str_buffer_append_format, :str_buffer_assign_format
          return unless expression.arguments.length == 1

          format_string = expression.arguments.fetch(0).value
          return unless format_string.is_a?(AST::FormatString)

          {
            operation: kind == :str_buffer_assign_format ? :assign : :append,
            sink_expression: receiver,
            sink_expected_type: callee_type.receiver_type,
            format_string:,
            sink_kind: :str_buffer,
            method_call: false,
            callee_type:,
            callee_binding: nil,
          }
        end
      end

      def explicit_format_sink_target(info, prepared_sink_expression, env:)
        case info[:sink_kind]
        when :string
          sink_value = if info[:method_call]
                         lower_method_receiver_argument(prepared_sink_expression, info[:callee_type], info[:callee_binding], env:)
                       else
                         lower_contextual_expression(prepared_sink_expression, env:, expected_type: info[:sink_expected_type])
                       end

          { kind: :string, value: sink_value }
        when :str_buffer
          lowered_receiver = lower_expression(prepared_sink_expression, env:)
          {
            kind: :str_buffer,
            receiver: lowered_receiver,
            data_pointer: lower_str_buffer_data_pointer_from_lowered(lowered_receiver),
            len_pointer: lower_str_buffer_len_pointer_from_lowered(lowered_receiver),
            dirty_pointer: lower_str_buffer_dirty_pointer_from_lowered(lowered_receiver),
            capacity: IR::IntegerLiteral.new(value: str_buffer_capacity(lowered_receiver.type), type: @ctx.types.fetch("ptr_uint")),
          }
        else
          raise LoweringError, "unsupported explicit format sink #{info[:sink_kind]}"
        end
      end

      def explicit_format_sink_target_buffer_view(sink_target)
        case sink_target[:kind]
        when :string
          sink_target[:value]
        when :str_buffer
          IR::AggregateLiteral.new(
            type: @ctx.types.fetch("str"),
            fields: [
              IR::AggregateField.new(name: "data", value: sink_target[:data_pointer]),
              IR::AggregateField.new(name: "len", value: sink_target[:capacity]),
            ],
          )
        else
          raise LoweringError, "unsupported explicit format sink #{sink_target[:kind]}"
        end
      end

      def lower_explicit_format_sink_expression_statement(expression, env:, line:)
        info = explicit_format_sink_call_info(expression, env)
        return unless info

        sink_setup, prepared_sink_expression, sink_cleanups = prepare_expression_with_cleanups(
          info[:sink_expression],
          env:,
          expected_type: info[:sink_expected_type],
          allow_root_statement_foreign: true,
        )
        sink_target = explicit_format_sink_target(info, prepared_sink_expression, env:)

        unless format_string_has_dynamic_parts?(info[:format_string])
          return sink_setup + [
            IR::ExpressionStmt.new(
              expression: explicit_format_sink_runtime_call(
                operation: info[:operation],
                sink_target:,
                text_value: IR::StringLiteral.new(
                  value: format_string_static_text(info[:format_string]),
                  type: @ctx.types.fetch("str"),
                  cstring: false,
                ),
              ),
              line:,
              source_path: @ctx.current_analysis_path,
            ),
            *sink_cleanups.flat_map(&:itself),
          ]
        end

        format_cleanup_start = (env[:prepared_expression_cleanups] ||= []).length
        format_setup, format_parts = build_dynamic_format_string_parts(info[:format_string], env:)
        format_cleanup_count = env[:prepared_expression_cleanups].length - format_cleanup_start
        format_cleanups = format_cleanup_count.positive? ? env[:prepared_expression_cleanups].slice!(format_cleanup_start, format_cleanup_count) : []
        copied_part_setup, copied_parts, copied_part_cleanups = copy_explicit_format_sink_str_parts(
          format_parts,
          env:,
          sink_kind: info[:sink_kind],
        )

        sink_statements = sink_setup + format_setup + copied_part_setup
        case sink_target[:kind]
        when :string
          if info[:operation] == :assign
            sink_statements << IR::ExpressionStmt.new(
              expression: IR::Call.new(callee: "std_string_String_clear", arguments: [sink_target[:value]], type: @ctx.types.fetch("void")),
              line:,
              source_path: @ctx.current_analysis_path,
            )
          end

          copied_parts.each do |part|
            sink_statements << IR::ExpressionStmt.new(
              expression: explicit_format_sink_append_call(part, sink_value: sink_target[:value], env:),
              line:,
              source_path: @ctx.current_analysis_path,
            )
          end
        when :str_buffer
          if info[:operation] == :assign
            sink_statements << IR::ExpressionStmt.new(
              expression: IR::Call.new(
                callee: "mt_str_buffer_clear",
                arguments: [
                  sink_target[:data_pointer],
                  sink_target[:capacity],
                  sink_target[:len_pointer],
                  sink_target[:dirty_pointer],
                ],
                type: @ctx.types.fetch("void"),
              ),
              line:,
              source_path: @ctx.current_analysis_path,
            )
          end

          offset_name = fresh_c_temp_name(env, "fmt_sink_offset")
          offset_value = IR::Name.new(name: offset_name, type: @ctx.types.fetch("ptr_uint"), pointer: false)
          offset_init = if info[:operation] == :assign
                          IR::IntegerLiteral.new(value: 0, type: @ctx.types.fetch("ptr_uint"))
                        else
                          IR::Call.new(
                            callee: "mt_str_buffer_len",
                            arguments: [
                              sink_target[:data_pointer],
                              sink_target[:capacity],
                              sink_target[:len_pointer],
                              sink_target[:dirty_pointer],
                            ],
                            type: @ctx.types.fetch("ptr_uint"),
                          )
                        end
          sink_statements << IR::LocalDecl.new(name: offset_name, linkage_name: offset_name, type: @ctx.types.fetch("ptr_uint"), value: offset_init)

          target_value = explicit_format_sink_target_buffer_view(sink_target)
          copied_parts.each do |part|
            sink_statements.concat(format_string_part_append_statements(part, target_value, offset_value, env:))
          end
          sink_statements << IR::Assignment.new(
            target: IR::Unary.new(operator: "*", operand: sink_target[:len_pointer], type: @ctx.types.fetch("ptr_uint")),
            operator: "=",
            value: offset_value,
          )
        else
          raise LoweringError, "unsupported explicit format sink #{sink_target[:kind]}"
        end

        sink_statements.concat(copied_part_cleanups)
        sink_statements.concat(sink_cleanups.flat_map(&:itself))
        sink_statements.concat(format_cleanups.flat_map(&:itself))
        sink_statements
      end

      def explicit_format_sink_runtime_call(operation:, sink_target:, text_value:)
        case sink_target[:kind]
        when :string
          callee = operation == :assign ? "std_string_String_assign" : "std_string_String_append"
          IR::Call.new(callee:, arguments: [sink_target[:value], text_value], type: @ctx.types.fetch("void"))
        when :str_buffer
          callee = operation == :assign ? "mt_str_buffer_assign" : "mt_str_buffer_append"
          IR::Call.new(
            callee:,
            arguments: [
              text_value,
              sink_target[:data_pointer],
              sink_target[:capacity],
              sink_target[:len_pointer],
              sink_target[:dirty_pointer],
            ],
            type: @ctx.types.fetch("void"),
          )
        else
          raise LoweringError, "unsupported explicit format sink #{sink_target[:kind]}"
        end
      end

      def copy_explicit_format_sink_str_parts(format_parts, env:, sink_kind:)
        setup = []
        cleanup = []

        copied_parts = format_parts.map do |part|
          next part unless part[:kind] == :expression

          should_copy = part[:append_function_name] == "append" ||
            (sink_kind == :str_buffer && part[:append_function_name] == "append_cstr")
          next part unless should_copy

          parameter = format_string_part_parameter_expression(part)
          copy_name = fresh_c_temp_name(env, "fmt_sink_str")
          copy_value = IR::Name.new(name: copy_name, type: @ctx.types.fetch("str"), pointer: false)
          register_prepared_temp!(env, copy_name, @ctx.types.fetch("str"), cstr_backed: true)

          length_value = if part[:append_function_name] == "append"
                           IR::Member.new(receiver: parameter, member: "len", type: @ctx.types.fetch("ptr_uint"))
                         else
                           IR::Call.new(callee: "mt_format_cstr_len", arguments: [parameter], type: @ctx.types.fetch("ptr_uint"))
                         end
          append_callee = part[:append_function_name] == "append" ? "mt_format_append_str" : "mt_format_append_cstr"

          setup << IR::LocalDecl.new(
            name: copy_name,
            linkage_name: copy_name,
            type: @ctx.types.fetch("str"),
            value: IR::Call.new(
              callee: "mt_format_str_make",
              arguments: [length_value],
              type: @ctx.types.fetch("str"),
            ),
          )
          setup << IR::ExpressionStmt.new(
            expression: IR::Call.new(
              callee: append_callee,
              arguments: [copy_value, IR::IntegerLiteral.new(value: 0, type: @ctx.types.fetch("ptr_uint")), parameter],
              type: @ctx.types.fetch("ptr_uint"),
            ),
          )
          cleanup << IR::ExpressionStmt.new(
            expression: IR::Call.new(callee: "mt_format_str_release", arguments: [copy_value], type: @ctx.types.fetch("void")),
          )

          part.merge(parameter_linkage_name: copy_name, parameter_type: @ctx.types.fetch("str"), append_function_name: "append")
        end

        [setup, copied_parts, cleanup]
      end

      def explicit_format_sink_append_call(part, sink_value:, env:)
        if part[:kind] == :text
          return IR::Call.new(
            callee: "std_string_String_append",
            arguments: [sink_value, IR::StringLiteral.new(value: part[:value], type: @ctx.types.fetch("str"), cstring: false)],
            type: @ctx.types.fetch("void"),
          )
        end

        parameter = format_string_part_parameter_expression(part)

        if part[:kind] == :precision_expression
          return IR::Call.new(
            callee: "std_fmt_append_double_precision",
            arguments: [sink_value, parameter, IR::IntegerLiteral.new(value: part[:precision], type: @ctx.types.fetch("int"))],
            type: @ctx.types.fetch("void"),
          )
        end

        if part[:kind] == :custom_expression
          return IR::Call.new(
            callee: part[:format_binding].append_callee_name,
            arguments: [
              format_string_custom_receiver_argument(part, hook: :append, env:),
              sink_value,
            ],
            type: @ctx.types.fetch("void"),
          )
        end

        callee = case part[:append_function_name]
                 when "append"
                   "std_string_String_append"
                 when "append_cstr"
                   "std_fmt_append_cstr"
                 else
                   "std_fmt_#{part[:append_function_name]}"
                 end

        IR::Call.new(callee:, arguments: [sink_value, parameter], type: @ctx.types.fetch("void"))
      end

      def format_string_part_length_expression(part, env:)
        parameter = format_string_part_parameter_expression(part)

        if part[:kind] == :precision_expression
          return IR::Call.new(
            callee: "mt_format_double_precision_len",
            arguments: [parameter, IR::IntegerLiteral.new(value: part[:precision], type: @ctx.types.fetch("int"))],
            type: @ctx.types.fetch("ptr_uint"),
          )
        end

        if part[:kind] == :custom_expression
          return IR::Name.new(name: part[:expected_length_linkage_name], type: @ctx.types.fetch("ptr_uint"), pointer: false)
        end

        case part[:append_function_name]
        when "append"
          IR::Member.new(receiver: parameter, member: "len", type: @ctx.types.fetch("ptr_uint"))
        when "append_cstr"
          IR::Call.new(callee: "mt_format_cstr_len", arguments: [parameter], type: @ctx.types.fetch("ptr_uint"))
        else
          IR::Call.new(callee: mt_format_length_c_name(part[:append_function_name]), arguments: [parameter], type: @ctx.types.fetch("ptr_uint"))
        end
      end

      def format_string_part_append_statements(part, result_value, offset_value, env:)
        if part[:kind] == :custom_expression
          output_type = part[:append_output_type]
          output_ref_type = Types::GenericInstance.new("ref", [output_type])
          output_value_name = fresh_c_temp_name(env, "fmt_part_output")
          output_value = IR::Name.new(name: output_value_name, type: output_type, pointer: false)
          output_len = IR::Member.new(receiver: output_value, member: "len", type: @ctx.types.fetch("ptr_uint"))
          expected_length = IR::Name.new(name: part[:expected_length_linkage_name], type: @ctx.types.fetch("ptr_uint"), pointer: false)
          data_pointer = format_string_result_data_pointer(result_value)
          slice_data_pointer = cast_expression(
            IR::Binary.new(operator: "+", left: data_pointer, right: offset_value, type: pointer_to(@ctx.types.fetch("char"))),
            output_type.field("data"),
          )

          return [
            IR::LocalDecl.new(
              name: output_value_name,
              linkage_name: output_value_name,
              type: output_type,
              value: IR::AggregateLiteral.new(
                type: output_type,
                fields: [
                  IR::AggregateField.new(name: "data", value: slice_data_pointer),
                  IR::AggregateField.new(
                    name: "len",
                    value: IR::IntegerLiteral.new(value: 0, type: output_type.field("len")),
                  ),
                  IR::AggregateField.new(name: "capacity", value: expected_length),
                  IR::AggregateField.new(
                    name: "owns_storage",
                    value: IR::BooleanLiteral.new(value: false, type: output_type.field("owns_storage")),
                  ),
                ],
              ),
            ),
            IR::ExpressionStmt.new(
              expression: IR::Call.new(
                callee: part[:format_binding].append_callee_name,
                arguments: [
                  format_string_custom_receiver_argument(part, hook: :append, env:),
                  IR::AddressOf.new(expression: output_value, type: output_ref_type),
                ],
                type: @ctx.types.fetch("void"),
              ),
            ),
            IR::IfStmt.new(
              condition: IR::Binary.new(operator: "!=", left: output_len, right: expected_length, type: @ctx.types.fetch("bool")),
              then_body: [
                IR::ExpressionStmt.new(
                  expression: IR::Call.new(
                    callee: "mt_fatal",
                    arguments: [
                      IR::StringLiteral.new(
                        value: "custom format hook length mismatch",
                        type: @ctx.types.fetch("cstr"),
                        cstring: true,
                      ),
                    ],
                    type: @ctx.types.fetch("void"),
                  ),
                ),
              ],
              else_body: nil,
            ),
            IR::Assignment.new(
              target: offset_value,
              operator: "=",
              value: IR::Binary.new(
                operator: "+",
                left: offset_value,
                right: output_len,
                type: @ctx.types.fetch("ptr_uint"),
              ),
            ),
            IR::Assignment.new(
              target: IR::Index.new(receiver: data_pointer, index: offset_value, type: @ctx.types.fetch("char")),
              operator: "=",
              value: IR::IntegerLiteral.new(value: 0, type: @ctx.types.fetch("char")),
            ),
          ]
        end

        [
          IR::Assignment.new(
            target: offset_value,
            operator: "=",
            value: format_string_part_append_expression(part, result_value, offset_value),
          ),
        ]
      end

      def format_string_part_append_expression(part, result_value, offset_value)
        if part[:kind] == :text
          return IR::Call.new(
            callee: "mt_format_append_str",
            arguments: [result_value, offset_value, IR::StringLiteral.new(value: part[:value], type: @ctx.types.fetch("str"), cstring: false)],
            type: @ctx.types.fetch("ptr_uint"),
          )
        end

        parameter = format_string_part_parameter_expression(part)

        if part[:kind] == :precision_expression
          return IR::Call.new(
            callee: "mt_format_append_double_precision",
            arguments: [result_value, offset_value, parameter, IR::IntegerLiteral.new(value: part[:precision], type: @ctx.types.fetch("int"))],
            type: @ctx.types.fetch("ptr_uint"),
          )
        end

        if part[:kind] == :custom_expression
          raise LoweringError, "custom format parts require statement lowering"
        end

        IR::Call.new(
          callee: mt_format_append_c_name(part[:append_function_name]),
          arguments: [result_value, offset_value, parameter],
          type: @ctx.types.fetch("ptr_uint"),
        )
      end

      def format_string_custom_receiver_argument(part, hook:, env:)
        binding = case hook
                  when :length
                    part[:format_binding].length_binding
                  when :append
                    part[:format_binding].append_binding
                  else
                    raise LoweringError, "unsupported custom format hook #{hook}"
                  end

        if env
          return lower_method_receiver_argument(AST::Identifier.new(name: part[:parameter_linkage_name]), binding.type, binding, env:)
        end

        IR::Name.new(name: part[:parameter_linkage_name], type: part[:parameter_type], pointer: false)
      end

      def format_string_result_data_pointer(result_value)
        IR::Member.new(receiver: result_value, member: "data", type: pointer_to(@ctx.types.fetch("char")))
      end

      def format_string_part_parameter_expression(part)
        IR::Name.new(name: part[:parameter_linkage_name], type: part[:parameter_type], pointer: false)
      end

      def format_string_append_plan(type, context:)
        return { kind: :builtin, append_function_name: "append", append_argument_type: @ctx.types.fetch("str") } if type == @ctx.types.fetch("str")
        return { kind: :builtin, append_function_name: "append_cstr", append_argument_type: @ctx.types.fetch("cstr") } if type == @ctx.types.fetch("cstr")
        return { kind: :builtin, append_function_name: "append_bool", append_argument_type: @ctx.types.fetch("bool") } if type == @ctx.types.fetch("bool")
        return { kind: :builtin, append_function_name: "append_float", append_argument_type: @ctx.types.fetch("float") } if type == @ctx.types.fetch("float")
        return { kind: :builtin, append_function_name: "append_double", append_argument_type: @ctx.types.fetch("double") } if type == @ctx.types.fetch("double")

        if type.is_a?(Types::Primitive) && type.integer?
          return { kind: :builtin, append_function_name: "append_int", append_argument_type: @ctx.types.fetch("int") } if %w[byte short int].include?(type.name)
          return { kind: :builtin, append_function_name: "append_uint", append_argument_type: @ctx.types.fetch("uint") } if %w[ubyte ushort uint].include?(type.name)
          return { kind: :builtin, append_function_name: "append_ptr_uint", append_argument_type: @ctx.types.fetch("ptr_uint") } if type.name == "ptr_uint"
          return { kind: :builtin, append_function_name: "append_long", append_argument_type: @ctx.types.fetch("long") } if %w[long ptr_int].include?(type.name)
          return { kind: :builtin, append_function_name: "append_ulong", append_argument_type: @ctx.types.fetch("ulong") } if type.name == "ulong"
        end

        if type.is_a?(Types::EnumBase) && type.backing_type.is_a?(Types::Primitive) && type.backing_type.integer?
          return format_string_append_plan(type.backing_type, context:)
        end

        if (custom_binding = resolve_explicit_format_binding(type, context:))
          return {
            kind: :custom,
            append_argument_type: type,
            binding: custom_binding,
            append_output_type: referenced_type(custom_binding.append_binding.type.params.first.type),
          }
        end

        raise LoweringError, "formatted string interpolation supports str, cstr, bool, numeric primitives, integer-backed enums/flags, and types implementing format_len()/append_format(output: ref[std.string.String]), got #{type}"
      end

      def format_string_hex_append_plan(type, uppercase:)
        if type.is_a?(Types::EnumBase) && type.backing_type.is_a?(Types::Primitive) && type.backing_type.integer?
          return format_string_hex_append_plan(type.backing_type, uppercase:)
        end

        unless type.is_a?(Types::Primitive) && type.integer?
          raise LoweringError, "format spec ':x' and ':X' require integer interpolation, got #{type}"
        end

        if %w[byte short int long ptr_int].include?(type.name)
          return [uppercase ? "append_long_hex_upper" : "append_long_hex", @ctx.types.fetch("long")]
        end

        if %w[ubyte ushort uint ulong ptr_uint].include?(type.name)
          return [uppercase ? "append_ulong_hex_upper" : "append_ulong_hex", @ctx.types.fetch("ulong")]
        end

        raise LoweringError, "format spec ':x' and ':X' require integer interpolation, got #{type}"
      end

      def format_string_oct_append_plan(type, uppercase:)
        _ = uppercase
        if type.is_a?(Types::EnumBase) && type.backing_type.is_a?(Types::Primitive) && type.backing_type.integer?
          return format_string_oct_append_plan(type.backing_type, uppercase:)
        end

        unless type.is_a?(Types::Primitive) && type.integer?
          raise LoweringError, "format spec ':o' and ':O' require integer interpolation, got #{type}"
        end

        if %w[byte short int long ptr_int].include?(type.name)
          return ["append_long_oct", @ctx.types.fetch("long")]
        end

        if %w[ubyte ushort uint ulong ptr_uint].include?(type.name)
          return ["append_ulong_oct", @ctx.types.fetch("ulong")]
        end

        raise LoweringError, "format spec ':o' and ':O' require integer interpolation, got #{type}"
      end

      def format_string_bin_append_plan(type, uppercase:)
        _ = uppercase
        if type.is_a?(Types::EnumBase) && type.backing_type.is_a?(Types::Primitive) && type.backing_type.integer?
          return format_string_bin_append_plan(type.backing_type, uppercase:)
        end

        unless type.is_a?(Types::Primitive) && type.integer?
          raise LoweringError, "format spec ':b' and ':B' require integer interpolation, got #{type}"
        end

        if %w[byte short int long ptr_int].include?(type.name)
          return ["append_long_bin", @ctx.types.fetch("long")]
        end

        if %w[ubyte ushort uint ulong ptr_uint].include?(type.name)
          return ["append_ulong_bin", @ctx.types.fetch("ulong")]
        end

        raise LoweringError, "format spec ':b' and ':B' require integer interpolation, got #{type}"
      end

      def mt_format_length_c_name(name)
        {
          "append_bool" => "mt_format_bool_len",
          "append_float" => "mt_format_float_len",
          "append_double" => "mt_format_double_len",
          "append_ulong_hex" => "mt_format_ulong_hex_len",
          "append_ulong_hex_upper" => "mt_format_ulong_hex_len",
          "append_long_hex" => "mt_format_long_hex_len",
          "append_long_hex_upper" => "mt_format_long_hex_len",
          "append_ulong_oct" => "mt_format_ulong_oct_len",
          "append_long_oct" => "mt_format_long_oct_len",
          "append_ulong_bin" => "mt_format_ulong_bin_len",
          "append_long_bin" => "mt_format_long_bin_len",
          "append_int" => "mt_format_int_len",
          "append_uint" => "mt_format_uint_len",
          "append_ptr_uint" => "mt_format_ptr_uint_len",
          "append_long" => "mt_format_long_len",
          "append_ulong" => "mt_format_ulong_len",
        }.fetch(name)
      end

      def mt_format_append_c_name(name)
        {
          "append" => "mt_format_append_str",
          "append_cstr" => "mt_format_append_cstr",
          "append_bool" => "mt_format_append_bool",
          "append_float" => "mt_format_append_float",
          "append_double" => "mt_format_append_double",
          "append_ulong_hex" => "mt_format_append_ulong_hex",
          "append_ulong_hex_upper" => "mt_format_append_ulong_hex_upper",
          "append_long_hex" => "mt_format_append_long_hex",
          "append_long_hex_upper" => "mt_format_append_long_hex_upper",
          "append_ulong_oct" => "mt_format_append_ulong_oct",
          "append_long_oct" => "mt_format_append_long_oct",
          "append_ulong_bin" => "mt_format_append_ulong_bin",
          "append_long_bin" => "mt_format_append_long_bin",
          "append_int" => "mt_format_append_int",
          "append_uint" => "mt_format_append_uint",
          "append_ptr_uint" => "mt_format_append_ptr_uint",
          "append_long" => "mt_format_append_long",
          "append_ulong" => "mt_format_append_ulong",
        }.fetch(name)
      end

      def prepare_binary_expression_for_inline_lowering(expression, env:, expected_type: nil)
        propagated_type = propagating_expected_type(expression.operator, expected_type)
        left_type, right_type = infer_binary_operand_types(expression, env:, expected_type:)
        operand_type = promoted_binary_operand_type(expression.operator, left_type, right_type)
        left_setup, left = prepare_expression_for_inline_lowering(expression.left, env:, expected_type: operand_type || propagated_type || left_type)
        right_env = binary_right_env(expression, env)
        right_setup, right = prepare_expression_for_inline_lowering(expression.right, env: right_env, expected_type: operand_type || left_type)

        unless %w[and or].include?(expression.operator)
          return [
            left_setup + right_setup,
            AST::BinaryOp.new(operator: expression.operator, left:, right:),
          ]
        end

        return [[], expression] if left_setup.empty? && right_setup.empty?

        result_type = infer_expression_type(expression, env:, expected_type:)
        result_name = fresh_c_temp_name(env, expression.operator)
        register_prepared_temp!(env, result_name, result_type)
        result_ref = IR::Name.new(name: result_name, type: result_type, pointer: false)
        left_value = lower_contextual_expression(left, env:, expected_type: result_type)
        right_value = lower_contextual_expression(right, env: right_env, expected_type: result_type)
        branch_condition = expression.operator == "and" ? result_ref : IR::Unary.new(operator: "not", operand: result_ref, type: @ctx.types.fetch("bool"))

        [
          left_setup + [
            IR::LocalDecl.new(name: result_name, linkage_name: result_name, type: result_type, value: left_value),
            IR::IfStmt.new(
              condition: branch_condition,
              then_body: right_setup + [IR::Assignment.new(target: result_ref, operator: "=", value: right_value)],
              else_body: nil,
            ),
          ],
          AST::Identifier.new(name: result_name),
        ]
      end

      private def ensure_tuple_struct(tuple_type)
        return unless tuple_type.is_a?(Types::Tuple)

        @registered_tuple_types ||= {}
        return if @registered_tuple_types[tuple_type]

        linkage_name = tuple_type_name(tuple_type)
        return if @artifacts.synthetic_structs.any? { |s| s.linkage_name == linkage_name }

        fields = tuple_type.element_types.each_with_index.map do |et, i|
          IR::Field.new(name: tuple_type.field_names[i], type: et)
        end
        @artifacts.synthetic_structs << IR::StructDecl.new(
          name: tuple_type.to_s,
          linkage_name: linkage_name,
          fields: fields,
          packed: false,
          alignment: nil,
        )
        @registered_tuple_types[tuple_type] = true
      end

      private def tuple_type_name(type)
        sanitized = type.element_types.map { |et| sanitize_type_name_for_tuple(et) }.join("_")
        base = "mt_tuple_#{sanitized}"
        default_names = type.element_types.each_with_index.map { |_, i| "_#{i}" }
        if type.field_names != default_names
          base << "_" << type.field_names.map { |n| sanitize_type_name_for_tuple(n) }.join("_")
        end
        base
      end

      private def sanitize_type_name_for_tuple(type)
        type.to_s.gsub(/[^a-zA-Z0-9]/, "_").gsub(/_+/, "_").gsub(/^_|_$/, "")
      end

      def prepare_if_expression_for_inline_lowering(expression, env:, expected_type: nil)
        condition_setup, condition = prepare_expression_for_inline_lowering(expression.condition, env:, expected_type: @ctx.types.fetch("bool"))
        then_env = env_with_refinements(env, flow_refinements(expression.condition, truthy: true, env:))
        else_env = env_with_refinements(env, flow_refinements(expression.condition, truthy: false, env:))
        result_type = infer_expression_type(expression, env:, expected_type:)
        then_setup, then_expression = prepare_expression_for_inline_lowering(expression.then_expression, env: then_env, expected_type: result_type)
        else_setup, else_expression = prepare_expression_for_inline_lowering(expression.else_expression, env: else_env, expected_type: result_type)

        return [[], expression] if condition_setup.empty? && then_setup.empty? && else_setup.empty?

        result_name = fresh_c_temp_name(env, "if_expr")
        register_prepared_temp!(env, result_name, result_type)
        result_ref = IR::Name.new(name: result_name, type: result_type, pointer: false)

        [
          condition_setup + [
            IR::LocalDecl.new(name: result_name, linkage_name: result_name, type: result_type, value: IR::ZeroInit.new(type: result_type)),
            IR::IfStmt.new(
              condition: lower_expression(condition, env:, expected_type: @ctx.types.fetch("bool")),
              then_body: then_setup + [
                IR::Assignment.new(
                  target: result_ref,
                  operator: "=",
                  value: lower_contextual_expression(then_expression, env: then_env, expected_type: result_type),
                ),
              ],
              else_body: else_setup + [
                IR::Assignment.new(
                  target: result_ref,
                  operator: "=",
                  value: lower_contextual_expression(else_expression, env: else_env, expected_type: result_type),
                ),
              ],
            ),
          ],
          AST::Identifier.new(name: result_name),
        ]
      end

      def prepare_match_expression_for_inline_lowering(expression, env:, expected_type: nil)
        scrutinee_type = infer_expression_type(expression.expression, env:)
        expression_setup, prepared_expression = prepare_expression_for_inline_lowering(expression.expression, env:, expected_type: scrutinee_type)
        result_type = infer_expression_type(expression, env:, expected_type:)
        result_name = fresh_c_temp_name(env, "match_expr")
        register_prepared_temp!(env, result_name, result_type)
        result_ref = IR::Name.new(name: result_name, type: result_type, pointer: false)
        setup = expression_setup + [IR::LocalDecl.new(name: result_name, linkage_name: result_name, type: result_type, value: IR::ZeroInit.new(type: result_type))]
        lowered_expression = lower_expression(prepared_expression, env:, expected_type: scrutinee_type)

        if scrutinee_type.is_a?(Types::Variant) &&
           expression.arms.any? { |arm| arm.binding_name && !wildcard_arm_pattern?(arm.pattern) } &&
           !duplicable_foreign_argument_expression?(lowered_expression)
          scrutinee_name = fresh_c_temp_name(env, "match_value")
          setup << IR::LocalDecl.new(name: scrutinee_name, linkage_name: scrutinee_name, type: scrutinee_type, value: lowered_expression)
          lowered_expression = IR::Name.new(name: scrutinee_name, type: scrutinee_type, pointer: false)
        end

        switch_expression = lowered_expression
        cases = if scrutinee_type.is_a?(Types::Variant)
                  kind_type = @ctx.types.fetch("int")
                  switch_expression = IR::Member.new(receiver: lowered_expression, member: "kind", type: kind_type)
                  expression.arms.map do |arm|
                    arm_env = duplicate_env(env)
                    binding_decl = if arm.binding_name && !wildcard_arm_pattern?(arm.pattern)
                                     arm_name = variant_match_arm_name_from_pattern(arm.pattern)
                                     if arm_name && scrutinee_type.has_payload?(arm_name)
                                       fields = scrutinee_type.arm(arm_name)
                                       payload_type = Types::VariantArmPayload.new(scrutinee_type, arm_name, fields)
                                       data_expr = IR::Member.new(receiver: lowered_expression, member: "data", type: nil)
                                       arm_expr = IR::Member.new(receiver: data_expr, member: arm_name, type: payload_type)
                                       binding_c = c_local_name(arm.binding_name)
                                       arm_env[:scopes].last[arm.binding_name] = local_binding(type: payload_type, linkage_name: binding_c, mutable: false, pointer: false)
                                       IR::LocalDecl.new(name: arm.binding_name, linkage_name: binding_c, type: payload_type, value: arm_expr)
                                     end
                                   end
                    value_setup, prepared_value = prepare_expression_for_inline_lowering(arm.value, env: arm_env, expected_type: result_type)
                    body = [binding_decl, *value_setup].compact
                    body << IR::Assignment.new(target: result_ref, operator: "=", value: lower_contextual_expression(prepared_value, env: arm_env, expected_type: result_type))
                    if wildcard_arm_pattern?(arm.pattern)
                      IR::SwitchDefaultCase.new(body: body)
                    else
                      arm_name = variant_match_arm_name_from_pattern(arm.pattern)
                      IR::SwitchCase.new(value: IR::Name.new(name: enum_member_c_name(scrutinee_type, "kind_#{arm_name}"), type: kind_type, pointer: false), body: body)
                    end
                  end
                else
                  expression.arms.map do |arm|
                    arm_env = duplicate_env(env)
                    value_setup, prepared_value = prepare_expression_for_inline_lowering(arm.value, env: arm_env, expected_type: result_type)
                    body = value_setup + [IR::Assignment.new(target: result_ref, operator: "=", value: lower_contextual_expression(prepared_value, env: arm_env, expected_type: result_type))]
                    if wildcard_arm_pattern?(arm.pattern)
                      IR::SwitchDefaultCase.new(body: body)
                    else
                      IR::SwitchCase.new(value: lower_expression(arm.pattern, env: arm_env, expected_type: scrutinee_type), body: body)
                    end
                  end
                end

        [setup + [IR::SwitchStmt.new(expression: switch_expression, cases: cases, exhaustive: true)], AST::Identifier.new(name: result_name)]
      end

      def materialize_prepared_expression(setup, value, env:, type:, prefix:)
        raise LoweringError, "cannot use void expression inline" unless value

        if value.is_a?(IR::Name)
          register_prepared_temp!(env, value.name, value.type, pointer: value.pointer)
          return [setup, AST::Identifier.new(name: value.name)]
        end

        temp_name = fresh_c_temp_name(env, prefix)
        register_prepared_temp!(env, temp_name, type)
        [
          setup + [IR::LocalDecl.new(name: temp_name, linkage_name: temp_name, type:, value:)],
          AST::Identifier.new(name: temp_name),
        ]
      end

      def register_prepared_temp!(env, name, type, pointer: false, storage_type: nil, projection: nil, cstr_backed: false, cstr_list_backed: false)
        current_actual_scope(env[:scopes])[name] = local_binding(type:, storage_type:, linkage_name: name, mutable: false, pointer:, projection:, cstr_backed:, cstr_list_backed:)
      end

      def foreign_call_requires_statement_lowering?(expression, binding, env:)
        return true if foreign_call_consumes_binding?(binding)

        mapping_expression = foreign_mapping_expression(binding.ast)
        reference_counts = foreign_mapping_reference_counts(mapping_expression)

        binding.ast.params.each_with_index do |param_ast, index|
          public_alias = param_ast.boundary_type ? foreign_mapping_public_alias_name(param_ast.name) : nil
          total_references = reference_counts.fetch(param_ast.name, 0)
          total_references += reference_counts.fetch(public_alias, 0) if public_alias
          next unless total_references > 1
          next if duplicable_foreign_argument_expression?(expression.arguments.fetch(index).value)

          return true
        end

        binding.ast.params.each_with_index do |param_ast, index|
          parameter = binding.type.params.fetch(index)
          next unless automatic_foreign_cstr_temp_needed?(parameter, expression.arguments.fetch(index).value, env:) ||
                      automatic_foreign_cstr_list_temp_needed?(parameter, expression.arguments.fetch(index).value, env:)

          return true
        end

        expression.arguments.drop(binding.type.params.length).each do |argument|
          return true if automatic_variadic_foreign_cstr_temp_needed?(argument.value, env:)
        end

        false
      end

      def lower_expression(expression, env:, expected_type: nil)
        type = infer_expression_type(expression, env:, expected_type:)

        case expression
        when AST::AwaitExpr
          raise LoweringError, "await expressions must be lowered in async statement context"
        when AST::IntegerLiteral
          IR::IntegerLiteral.new(value: expression.value, type:)
        when AST::CharLiteral
          IR::IntegerLiteral.new(value: expression.value, type:)
        when AST::FloatLiteral
          IR::FloatLiteral.new(value: expression.value, type:)
        when AST::SizeofExpr
          target_type = resolve_type_ref_with_fallback(expression.type, env:)
          target_type ? IR::SizeofExpr.new(target_type:, type:) : raise(LoweringError, "size_of argument is not a concrete type")
        when AST::AlignofExpr
          target_type = resolve_type_ref_with_fallback(expression.type, env:)
          target_type ? IR::AlignofExpr.new(target_type:, type:) : raise(LoweringError, "align_of argument is not a concrete type")
        when AST::OffsetofExpr
          target_type = resolve_type_ref(expression.type)
          if (precomputed = @ctx.const_values[@ctx.ast.node_ids[expression.object_id]])
            IR::IntegerLiteral.new(value: precomputed, type:)
          elsif (binding = lookup_value(expression.field, env)) && binding[:const_value].is_a?(Types::FieldHandle)
            IR::OffsetofExpr.new(target_type:, field: binding[:const_value].field_name, type:)
          else
            IR::OffsetofExpr.new(target_type:, field: expression.field, type:)
          end
        when AST::StringLiteral
          IR::StringLiteral.new(value: expression.value, type:, cstring: expression.cstring)
        when AST::FormatString
          raise LoweringError, "unprepared format string reached raw lowering; format strings should be materialized before direct lowering"
        when AST::BooleanLiteral
          IR::BooleanLiteral.new(value: expression.value, type:)
        when AST::NullLiteral
          IR::NullLiteral.new(type:)
        when AST::Identifier
          binding = lookup_value(expression.name, env)
          if binding
            lower_bound_identifier(binding, expected_type:)
          elsif @ctx.functions.key?(expression.name)
            function_binding = @ctx.functions.fetch(expression.name)
            raise LoweringError, "generic function #{expression.name} cannot be used as a value" if function_binding.type_params.any?
            raise LoweringError, "foreign function #{expression.name} cannot be used as a value" if foreign_function_binding?(function_binding)

            IR::Name.new(name: function_binding_c_name(function_binding, module_name: @ctx.module_name), type: type, pointer: false)
          else
            raise LoweringError, "unsupported identifier #{expression.name}"
          end
        when AST::MemberAccess
          lower_member_access(expression, env:, type:)
        when AST::IndexAccess
          receiver_type = infer_expression_type(expression.receiver, env:)
          receiver = lower_expression(expression.receiver, env:)
          index = lower_expression(expression.index, env:)
          if array_type?(receiver_type) && addressable_storage_expression?(expression.receiver)
            IR::CheckedIndex.new(receiver:, index:, receiver_type:, type:)
          elsif receiver_type.is_a?(Types::Span)
            IR::CheckedSpanIndex.new(receiver:, index:, receiver_type:, type:)
          else
            IR::Index.new(receiver:, index:, type:)
          end
        when AST::UnaryOp
          raise LoweringError, "propagation expressions must be prepared before direct lowering" if expression.operator == "?"

          operand = lower_expression(expression.operand, env:, expected_type: type)
          expanded = lower_vector_unary_op(expression.operator, operand, type)
          return expanded if expanded

          IR::Unary.new(operator: expression.operator, operand:, type:)
        when AST::BinaryOp
          right_env = binary_right_env(expression, env)
          left_type, right_type = infer_binary_operand_types(expression, env:, expected_type: type)
          operand_type = promoted_binary_operand_type(expression.operator, left_type, right_type)
          left = lower_expression(expression.left, env:, expected_type: operand_type || type)
          right = lower_expression(expression.right, env: right_env, expected_type: operand_type || left.type)
          left = cast_expression(left, operand_type) if operand_type
          right = cast_expression(right, operand_type) if operand_type

          expanded = lower_vector_binary_op(expression.operator, left, left_type, right, right_type, type)
          return expanded if expanded

          IR::Binary.new(operator: expression.operator, left:, right:, type:)
        when AST::IfExpr
          then_env = env_with_refinements(env, flow_refinements(expression.condition, truthy: true, env:))
          else_env = env_with_refinements(env, flow_refinements(expression.condition, truthy: false, env:))
          IR::Conditional.new(
            condition: lower_expression(expression.condition, env:, expected_type: @ctx.types.fetch("bool")),
            then_expression: lower_contextual_expression(expression.then_expression, env: then_env, expected_type: type),
            else_expression: lower_contextual_expression(expression.else_expression, env: else_env, expected_type: type),
            type:,
          )
        when AST::MatchExpr
          raise LoweringError, "match expressions must be prepared before direct lowering"
        when AST::UnsafeExpr
          lower_expression(expression.expression, env:, expected_type: type)
        when AST::ProcExpr
          proc_type = type.is_a?(Types::Proc) ? type : infer_expression_type(expression, env:, expected_type: type)
          _setup, value = lower_proc_expression_for_local(expression, env:, local_name: fresh_c_temp_name(env, "proc_expr"), proc_type: proc_type)
          value
        when AST::DetachExpr
          lower_detach_expr(expression, env:)
        when AST::Call
          lower_call(expression, env:, type:)
        when AST::PrefixCast
          lowered_arg = lower_expression(expression.expression, env:)
          IR::Cast.new(target_type: type, expression: lowered_arg, type:)
        when AST::Specialization
          lower_specialization(expression, env:, type:)
        when AST::ExpressionList
          ensure_tuple_struct(type)
          fields = expression.elements.each_with_index.map do |element, index|
            if element.is_a?(AST::Argument)
              element_type = type.element_types[index]
              field_name = element.name
              IR::AggregateField.new(name: field_name, value: lower_expression(element.value, env:, expected_type: element_type))
            else
              element_type = type.element_types[index]
              IR::AggregateField.new(name: "_#{index}", value: lower_expression(element, env:, expected_type: element_type))
            end
          end
          IR::AggregateLiteral.new(type:, fields:)
        else
          raise LoweringError, "unsupported expression #{expression.class.name}"
        end
      end

      def lower_member_access(expression, env:, type:)
        if (type_expr = resolve_type_expression(expression.receiver))
          if type_expr.is_a?(Types::Variant)
            return IR::VariantLiteral.new(type: type_expr, arm_name: expression.member, fields: [])
          end

          member_name = if (type_expr.is_a?(Types::Enum) || type_expr.is_a?(Types::Flags)) && !type_expr.external
                          enum_member_c_name(type_expr, expression.member)
                        else
                          expression.member
                        end
          return IR::Name.new(name: member_name, type:, pointer: false)
        end

        if expression.receiver.is_a?(AST::Identifier) && @ctx.imports.key?(expression.receiver.name)
          imported_module = @ctx.imports.fetch(expression.receiver.name)
          if imported_module.functions.key?(expression.member)
            function_binding = imported_module.functions.fetch(expression.member)
            raise LoweringError, "generic function #{expression.receiver.name}.#{expression.member} cannot be used as a value" if function_binding.type_params.any?
            raise LoweringError, "foreign function #{expression.receiver.name}.#{expression.member} cannot be used as a value" if foreign_function_binding?(function_binding)

            return IR::Name.new(name: function_binding_c_name(function_binding, module_name: imported_module.name), type:, pointer: false)
          end

          return IR::Name.new(name: imported_value_c_name(imported_module, expression.member), type:, pointer: false)
        end

         receiver_type = infer_expression_type(expression.receiver, env:)

        if expression.receiver.is_a?(AST::IndexAccess)
          base_type = infer_expression_type(expression.receiver.receiver, env:)
          if base_type.is_a?(Types::SoA)
            return lower_soa_indexed_field_access(expression.receiver.receiver, expression.receiver.index, expression.member, base_type, env:, type:)
          end
        end

        if receiver_type == @ctx.types["field_handle"]
          handle = compile_time_const_value(expression.receiver, env:)
          return lower_compile_time_handle_member(handle, expression.member, type) if handle.is_a?(Types::FieldHandle)
        end
        if receiver_type == @ctx.types["member_handle"]
          handle = compile_time_const_value(expression.receiver, env:)
          return lower_compile_time_handle_member(handle, expression.member, type) if handle.is_a?(Types::MemberHandle)
        end

        if array_type?(receiver_type) && expression.member == "as_span"
          return lower_array_to_span_expression(lower_expression(expression.receiver, env:), type)
        end

        receiver = lower_expression(expression.receiver, env:)
        member_expr = IR::Member.new(receiver:, member: member_c_name(receiver_type, expression.member), type:)
        if self_referencing_variant_field_access?(receiver_type, expression.member, type)
          return IR::Unary.new(operator: "*", operand: member_expr, type:)
        end
        member_expr
      end

      def self_referencing_variant_field_access?(receiver_type, member, field_type)
        return false unless receiver_type.is_a?(Types::VariantArmPayload)

        outer = receiver_type.variant_type
        return field_type == outer if outer.is_a?(Types::Variant)
        return field_type == outer if outer.is_a?(Types::VariantInstance)

        false
      end

      def lower_compile_time_handle_member(handle, member, type)
        case handle
        when Types::FieldHandle
          case member
          when "name" then IR::StringLiteral.new(value: handle.field_name, type: @ctx.types["str"], cstring: false)
          when "type" then nil # handled via compile_time_const_value before lowering
          end
        when Types::MemberHandle
          case member
          when "name" then IR::StringLiteral.new(value: handle.member_name, type: @ctx.types["str"], cstring: false)
          when "value"
            value_type = @ctx.types["int"]
            IR::IntegerLiteral.new(value: handle.member_value || 0, type: value_type)
          end
        end
      end

      def lower_vector_binary_op(operator, left, left_type, right, right_type, result_type)
        return nil unless result_type.is_a?(Types::Vector) || result_type.is_a?(Types::Matrix) || result_type.is_a?(Types::Quaternion)

        if result_type.is_a?(Types::Vector)
          return lower_vector_binary_op_on_vectors(operator, left, left_type, right, right_type, result_type)
        end

        return lower_aggregate_binary_op(operator, left, right, result_type) if operator == "+" || operator == "-"

        return lower_aggregate_binary_op(operator, left, right, result_type) if result_type.is_a?(Types::Quaternion)

        scalar_is_left = !left_type.is_a?(Types::Matrix)
        aggregate_expr = scalar_is_left ? right : left
        scalar_expr = scalar_is_left ? left : right
        scalar_type = scalar_is_left ? left_type : right_type

        fields = result_type.fields.map do |fname, ftype|
          field_expr = IR::Member.new(receiver: aggregate_expr, member: fname, type: ftype)
          left_expr = scalar_is_left ? scalar_expr : field_expr
          right_expr = scalar_is_left ? field_expr : scalar_expr
          value = lower_vector_binary_op(operator, left_expr, ftype, right_expr, scalar_type, ftype) ||
                  IR::Binary.new(operator:, left: left_expr, right: right_expr, type: ftype)
          IR::AggregateField.new(name: fname, value:)
        end
        IR::AggregateLiteral.new(fields:, type: result_type)
      end

      def lower_vector_unary_op(operator, operand, result_type)
        return nil unless result_type.is_a?(Types::Vector) || result_type.is_a?(Types::Matrix) || result_type.is_a?(Types::Quaternion)
        return nil unless operator == "+" || operator == "-"

        fields = result_type.fields.map do |fname, ftype|
          field_expr = IR::Member.new(receiver: operand, member: fname, type: ftype)
          value = lower_vector_unary_op(operator, field_expr, ftype) || IR::Unary.new(operator:, operand: field_expr, type: ftype)
          IR::AggregateField.new(name: fname, value:)
        end
        IR::AggregateLiteral.new(fields:, type: result_type)
      end

    private

      def lower_vector_binary_op_on_vectors(operator, left, left_type, right, right_type, result_type)
        if left_type.is_a?(Types::Vector) && right_type.is_a?(Types::Vector)
          return lower_aggregate_binary_op(operator, left, right, result_type)
        end

        return nil unless operator == "*" || operator == "/"

        scalar_is_left = !left_type.is_a?(Types::Vector)
        vector_expr = scalar_is_left ? right : left
        scalar_expr = scalar_is_left ? left : right

        fields = result_type.fields.map do |fname, ftype|
          field_expr = IR::Member.new(receiver: vector_expr, member: fname, type: ftype)
          left_expr = scalar_is_left ? scalar_expr : field_expr
          right_expr = scalar_is_left ? field_expr : scalar_expr
          value = IR::Binary.new(operator:, left: left_expr, right: right_expr, type: ftype)
          IR::AggregateField.new(name: fname, value:)
        end
        IR::AggregateLiteral.new(fields:, type: result_type)
      end

      def lower_aggregate_binary_op(operator, left, right, result_type)
        fields = result_type.fields.map do |fname, ftype|
          left_field = IR::Member.new(receiver: left, member: fname, type: ftype)
          right_field = IR::Member.new(receiver: right, member: fname, type: ftype)
          value = lower_vector_binary_op(operator, left_field, ftype, right_field, ftype, ftype) || IR::Binary.new(
            operator:,
            left: left_field,
            right: right_field,
            type: ftype,
          )
          IR::AggregateField.new(name: fname, value:)
        end
        IR::AggregateLiteral.new(fields:, type: result_type)
      end

      def lower_soa_indexed_field_access(soa_base, index_expr, field_name, soa_type, env:, type:)
        field_type = soa_type.fields[field_name]
        raise LoweringError, "SoA type #{soa_type} has no field #{field_name}" unless field_type

        receiver = lower_expression(soa_base, env:)
        index = lower_expression(index_expr, env:)
        IR::Index.new(
          receiver: IR::Member.new(receiver:, member: field_name, type: field_type),
          index:,
          type:,
        )
      end

      def member_c_name(receiver_type, member)
        owner_type = receiver_type
        loop do
          case owner_type
          when Types::Nullable
            owner_type = owner_type.base
          when Types::GenericInstance
            if %w[ptr const_ptr ref].include?(owner_type.name) && owner_type.arguments.length == 1
              owner_type = owner_type.arguments.first
            else
              break
            end
          else
            break
          end
        end

        if (event_type = event_member_from_owner_type(owner_type, member))
          return event_type.hidden_field_name
        end

        owner_type.field_c_name(member)
      end

      def resolve_type_ref_with_fallback(type_ref, env:)
        resolve_type_ref(type_ref)
      rescue LoweringError
        return unless type_ref.name.parts.length >= 1

        expression = build_expression_from_qualified_name(type_ref.name)
        return unless expression

        ct_value = compile_time_const_value(expression, env:)
        if ct_value.is_a?(Types::Struct) || ct_value.is_a?(Types::Primitive) ||
           ct_value.is_a?(Types::Union) || ct_value.is_a?(Types::Nullable) ||
           ct_value.is_a?(Types::StructInstance)
          ct_value
        end
      end

      def build_expression_from_qualified_name(qualified_name)
        parts = qualified_name.parts
        return unless parts.length >= 1

        expr = AST::Identifier.new(name: parts.first)
        parts[1..].each do |part|
          expr = AST::MemberAccess.new(receiver: expr, member: part)
        end
        expr
      end
  end
end

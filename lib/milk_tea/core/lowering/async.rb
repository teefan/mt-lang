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

        body = [async_frame_cast_declaration(frame_type, async_info)]

        not_ready_expr = IR::Unary.new(operator: "not", operand: async_frame_field_expression(frame_expr, "ready", @types.fetch("bool")), type: @types.fetch("bool"))
        not_ready_return = [IR::ReturnStmt.new(value: nil)]

        if async_info[:await_fields].any?
          await_release_stmts = []
          async_info[:await_fields].each_value do |field_info|
            task_field_expr = async_frame_field_expression(frame_expr, field_info[:field_name], field_info[:task_type])
            task_frame_expr = async_task_frame_expression(task_field_expr, field_info[:task_type])
            release_call = IR::ExpressionStmt.new(
              expression: async_task_call(task_field_expr, field_info[:task_type], "release", [task_frame_expr], @types.fetch("void")),
            )
            await_release_stmts << IR::IfStmt.new(
              condition: task_frame_expr,
              then_body: [release_call],
              else_body: nil,
            )
          end
          body << IR::IfStmt.new(
            condition: not_ready_expr,
            then_body: await_release_stmts + not_ready_return,
            else_body: nil,
          )
        else
          body << IR::IfStmt.new(
            condition: not_ready_expr,
            then_body: not_ready_return,
            else_body: nil,
          )
        end

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

        (async_info[:format_str_fields] || {}).each_key do |field_name|
          field_expr = async_frame_field_expression(frame_expr, field_name, @types.fetch("str"))
          body << IR::ExpressionStmt.new(
            expression: IR::Call.new(
              callee: "mt_format_str_release",
              arguments: [field_expr],
              type: @types.fetch("void"),
            ),
          )
        end

        async_info[:param_fields].each_value do |field_info|
          next unless field_info[:pointer]

          param_expr = async_frame_field_expression(frame_expr, field_info[:field_name], field_info[:type])
          body << IR::ExpressionStmt.new(
            expression: IR::Call.new(callee: "mt_async_free", arguments: [param_expr], type: @types.fetch("void")),
          )
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
        body = if async_info[:result_type] == @types.fetch("void")
                 [IR::ReturnStmt.new(value: nil)]
               else
                 [async_frame_cast_declaration(frame_type, async_info),
                  IR::ReturnStmt.new(value: async_frame_field_expression(frame_expr, "result", async_info[:result_type]))]
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
  end
end

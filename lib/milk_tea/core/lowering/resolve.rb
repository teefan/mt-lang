# frozen_string_literal: true

module MilkTea
  module LowererResolve
    private


      def direct_function_to_proc_contextual_compatibility?(expression, actual_type, env:, expected_type:)
        return false unless actual_type.is_a?(Types::Function) && proc_type?(expected_type)
        return false unless direct_function_identity_expression?(expression, env)

        function_type_matches_proc_type?(actual_type, expected_type)
      end

      def direct_function_identity_expression?(expression, env)
        case expression
        when AST::Identifier
          return false if lookup_value(expression.name, env)
          return false unless @ctx.functions.key?(expression.name)

          binding = @ctx.functions.fetch(expression.name)
          !binding.type_params.any? && !foreign_function_binding?(binding)
        when AST::MemberAccess
          return false unless expression.receiver.is_a?(AST::Identifier) && @ctx.imports.key?(expression.receiver.name)

          imported_module = @ctx.imports.fetch(expression.receiver.name)
          return false unless imported_module.functions.key?(expression.member)

          binding = imported_module.functions.fetch(expression.member)
          !binding.type_params.any? && !foreign_function_binding?(binding)
        when AST::Specialization
          callable_resolution = resolve_specialized_callable_binding(expression, env:)
          return false unless callable_resolution

          callable_kind, binding, = callable_resolution
          callable_kind == :function && !foreign_function_binding?(binding)
        else
          false
        end
      end

      def lower_direct_function_to_proc_expression(source_expression, source_function, env:, expected_type:)
        raise LoweringError, "function-to-proc coercion requires a direct function name" unless source_function.is_a?(IR::Name)

        proc_id = fresh_proc_symbol
        invoke_c_name = "#{@ctx.module_prefix}__proc_#{proc_id}__invoke"
        release_c_name = "#{@ctx.module_prefix}__proc_#{proc_id}__release"
        retain_c_name = "#{@ctx.module_prefix}__proc_#{proc_id}__retain"

        @artifacts.synthetic_functions << build_direct_function_proc_invoke_function(source_expression, source_function.name, source_function.type, expected_type, invoke_c_name)
        @artifacts.synthetic_functions << build_proc_noop_release_function(release_c_name)
        @artifacts.synthetic_functions << build_proc_noop_retain_function(retain_c_name)

        IR::AggregateLiteral.new(
          type: expected_type,
          fields: [
            IR::AggregateField.new(name: "env", value: IR::NullLiteral.new(type: proc_env_pointer_type)),
            IR::AggregateField.new(name: "invoke", value: IR::Name.new(name: invoke_c_name, type: proc_invoke_function_type(expected_type), pointer: false)),
            IR::AggregateField.new(name: "release", value: IR::Name.new(name: release_c_name, type: proc_release_function_type, pointer: false)),
            IR::AggregateField.new(name: "retain", value: IR::Name.new(name: retain_c_name, type: proc_retain_function_type, pointer: false)),
          ],
        )
      end

      def build_direct_function_proc_invoke_function(source_expression, function_c_name, function_type, proc_type, invoke_c_name)
        env = empty_env
        params = [IR::Param.new(name: "env", c_name: "__mt_proc_env", type: proc_env_pointer_type, pointer: false)]
        parameter_setup = []
        call_arguments = []

        proc_type.params.each_with_index do |param, index|
          c_name = c_local_name(param.name || "arg#{index}")
          if array_type?(param.type)
            input_c_name = "#{c_name}_input"
            params << IR::Param.new(name: param.name || "arg#{index}", c_name: input_c_name, type: param.type, pointer: false)
            env[:scopes].last[param.name || "arg#{index}"] = local_binding(type: param.type, c_name:, mutable: param.mutable, pointer: false)
            parameter_setup << IR::LocalDecl.new(
              name: param.name || "arg#{index}",
              c_name:,
              type: param.type,
              value: IR::Name.new(name: input_c_name, type: param.type, pointer: false),
            )
            call_arguments << IR::Name.new(name: c_name, type: param.type, pointer: false)
          else
            env[:scopes].last[param.name || "arg#{index}"] = local_binding(type: param.type, c_name:, mutable: param.mutable, pointer: false)
            params << IR::Param.new(name: param.name || "arg#{index}", c_name:, type: param.type, pointer: false)
            call_arguments << IR::Name.new(name: c_name, type: param.type, pointer: false)
          end
        end

        call = IR::Call.new(callee: function_c_name, arguments: call_arguments, type: proc_type.return_type)
        body = if proc_type.return_type == @ctx.types.fetch("void")
                 parameter_setup + [IR::ExpressionStmt.new(expression: call), IR::ReturnStmt.new(value: nil)]
               else
                 parameter_setup + [IR::ReturnStmt.new(value: call)]
               end

        IR::Function.new(name: invoke_c_name, c_name: invoke_c_name, params:, return_type: proc_type.return_type, body:, entry_point: false)
      end

      def lower_array_to_span_expression(expression, target_type)
        IR::AggregateLiteral.new(
          type: target_type,
          fields: [
            IR::AggregateField.new(
              name: "data",
              value: IR::AddressOf.new(
                expression: IR::Index.new(
                  receiver: expression,
                  index: IR::IntegerLiteral.new(value: 0, type: @ctx.types.fetch("ptr_uint")),
                  type: target_type.element_type,
                ),
                type: pointer_to(target_type.element_type),
              ),
            ),
            IR::AggregateField.new(
              name: "len",
              value: IR::IntegerLiteral.new(value: array_length(expression.type), type: @ctx.types.fetch("ptr_uint")),
            ),
          ],
        )
      end

      def lower_str_buffer_to_span_expression(expression, target_type)
        IR::AggregateLiteral.new(
          type: target_type,
          fields: [
            IR::AggregateField.new(
              name: "data",
              value: IR::Call.new(
                callee: "mt_str_buffer_prepare_write",
                arguments: [
                  lower_str_buffer_data_pointer_from_lowered(expression),
                  IR::IntegerLiteral.new(value: str_buffer_capacity(expression.type), type: @ctx.types.fetch("ptr_uint")),
                  lower_str_buffer_dirty_pointer_from_lowered(expression),
                ],
                type: pointer_to(target_type.element_type),
              ),
            ),
            IR::AggregateField.new(
              name: "len",
              value: IR::IntegerLiteral.new(value: str_buffer_storage_capacity(expression.type), type: @ctx.types.fetch("ptr_uint")),
            ),
          ],
        )
      end

      def contextual_numeric_compatibility?(expression, actual_type, expected_type, env:, external_numeric: false, contextual_int_to_float: false)
        return true if exact_compile_time_numeric_compatibility?(actual_type, expression, expected_type, env:)
        return true if integer_to_char_compatibility?(actual_type, expected_type)
        return true if external_numeric && external_numeric_compatibility?(actual_type, expected_type)
        return true if contextual_int_to_float && contextual_int_to_float_compatibility?(actual_type, expected_type)

        false
      end

      def cstr_backed_expression?(expression, env)
        return true if infer_expression_type(expression, env:) == @ctx.types.fetch("cstr")

        case expression
        when AST::StringLiteral
          true
        when AST::Identifier
          binding_cstr_backed?(lookup_value(expression.name, env))
        when AST::IfExpr
          then_env = env_with_refinements(env, flow_refinements(expression.condition, truthy: true, env:))
          else_env = env_with_refinements(env, flow_refinements(expression.condition, truthy: false, env:))
          cstr_backed_expression?(expression.then_expression, then_env) &&
            cstr_backed_expression?(expression.else_expression, else_env)
        when AST::UnsafeExpr
          cstr_backed_expression?(expression.expression, env)
        else
          false
        end
      rescue LoweringError
        false
      end

      def cstr_list_backed_expression?(expression, env)
        actual_type = infer_expression_type(expression, env:)
        return false unless array_type?(actual_type)

        element_type = array_element_type(actual_type)
        return false unless element_type == @ctx.types.fetch("str") || element_type == @ctx.types.fetch("cstr")

        case expression
        when AST::Identifier
          binding_cstr_list_backed?(lookup_value(expression.name, env))
        when AST::Call
          expression.arguments.all? { |argument| cstr_backed_expression?(argument.value, env) }
        when AST::IfExpr
          then_env = env_with_refinements(env, flow_refinements(expression.condition, truthy: true, env:))
          else_env = env_with_refinements(env, flow_refinements(expression.condition, truthy: false, env:))
          cstr_list_backed_expression?(expression.then_expression, then_env) &&
            cstr_list_backed_expression?(expression.else_expression, else_env)
        when AST::UnsafeExpr
          cstr_list_backed_expression?(expression.expression, env)
        else
          false
        end
      rescue LoweringError
        false
      end

      def cstr_backed_storage_value?(type, expression, env)
        return false unless expression
        return true if type == @ctx.types.fetch("cstr")
        return false unless type == @ctx.types.fetch("str")

        cstr_backed_expression?(expression, env)
      end

      def cstr_list_backed_storage_value?(type, expression, env)
        return false unless expression
        return false unless cstr_list_trackable_type?(type)

        cstr_list_backed_expression?(expression, env)
      end

      def update_cstr_metadata_for_assignment!(statement, prepared_value, env)
        if statement.target.is_a?(AST::Identifier)
          binding = lookup_value(statement.target.name, env)
          return unless binding

          replace_binding_cstr_metadata!(
            statement.target.name,
            env,
            cstr_backed: statement.operator == "=" ? cstr_backed_storage_value?(binding[:type], prepared_value, env) : false,
            cstr_list_backed: statement.operator == "=" ? cstr_list_backed_storage_value?(binding[:type], prepared_value, env) : false,
          )
          return
        end

        return unless statement.target.is_a?(AST::IndexAccess) && statement.target.receiver.is_a?(AST::Identifier)

        binding = lookup_value(statement.target.receiver.name, env)
        return unless binding && cstr_list_trackable_type?(binding[:type])

        replace_binding_cstr_metadata!(statement.target.receiver.name, env, cstr_backed: binding_cstr_backed?(binding), cstr_list_backed: false)
      end

      def merge_cstr_metadata_after_if_statement!(statement, env)
        exit_envs = cstr_metadata_exit_envs_for_if_statement(statement, env)
        return if exit_envs.empty?

        trackable_binding_names(env).each do |name|
          binding = lookup_value(name, env)
          next unless binding

          replace_binding_cstr_metadata!(
            name,
            env,
            cstr_backed: cstr_trackable_type?(binding[:type]) && exit_envs.all? { |exit_env| binding_cstr_backed?(lookup_value(name, exit_env)) },
            cstr_list_backed: cstr_list_trackable_type?(binding[:type]) && exit_envs.all? { |exit_env| binding_cstr_list_backed?(lookup_value(name, exit_env)) },
          )
        end
      end

      def cstr_metadata_exit_envs_for_if_statement(statement, env)
        false_refinements = {}
        exit_envs = []

        statement.branches.each do |branch|
          branch_env = env_with_refinements(env, false_refinements)
          true_refinements = merge_refinements(false_refinements, flow_refinements(branch.condition, truthy: true, env: branch_env))
          simulated = simulate_cstr_metadata_block(branch.body, env: env_with_refinements(env, true_refinements))
          exit_envs << simulated if simulated
          false_refinements = merge_refinements(false_refinements, flow_refinements(branch.condition, truthy: false, env: branch_env))
        end

        if statement.else_body
          simulated = simulate_cstr_metadata_block(statement.else_body, env: env_with_refinements(env, false_refinements))
          exit_envs << simulated if simulated
        else
          exit_envs << env
        end

        exit_envs
      end

      def simulate_cstr_metadata_block(statements, env:)
        simulated_env = duplicate_env(env)

        statements.each do |statement|
          case statement
          when AST::LocalDecl
            storage_type = if statement.else_body
                             infer_expression_type(statement.value, env: simulated_env)
                           elsif statement.type
                             resolve_type_ref(statement.type)
                           else
                             infer_expression_type(statement.value, env: simulated_env)
                           end
            type = if statement.else_body
                     statement.type ? resolve_type_ref(statement.type) : let_else_success_type(storage_type)
                   else
                     storage_type
                   end
            unless let_else_discard_binding_syntax?(statement)
              current_actual_scope(simulated_env[:scopes])[statement.name] = local_binding(
                type:,
                storage_type:,
                c_name: c_local_name(statement.name),
                mutable: statement.kind == :var,
                pointer: false,
                projection: statement.else_body ? let_else_binding_projection(storage_type) : nil,
                cstr_backed: cstr_backed_storage_value?(storage_type, statement.value, simulated_env),
                cstr_list_backed: cstr_list_backed_storage_value?(storage_type, statement.value, simulated_env),
                const_value: statement.else_body ? nil : statement.kind == :let && statement.value ? compile_time_const_value(statement.value, env: simulated_env) : nil,
              )
            end
          when AST::Assignment
            update_cstr_metadata_for_assignment!(statement, statement.value, simulated_env)
          when AST::IfStmt
            merge_cstr_metadata_after_if_statement!(statement, simulated_env)
          when AST::UnsafeStmt
            nested_env = simulate_cstr_metadata_block(statement.body, env: simulated_env)
            return nil unless nested_env

            copy_cstr_metadata!(simulated_env, nested_env)
          when AST::ReturnStmt, AST::BreakStmt, AST::ContinueStmt
            return nil
          end
        end

        simulated_env
      end

      def copy_cstr_metadata!(target_env, source_env)
        trackable_binding_names(target_env).each do |name|
          binding = lookup_value(name, target_env)
          source_binding = lookup_value(name, source_env)
          next unless binding && source_binding

          replace_binding_cstr_metadata!(
            name,
            target_env,
            cstr_backed: binding_cstr_backed?(source_binding),
            cstr_list_backed: binding_cstr_list_backed?(source_binding),
          )
        end
      end

      def replace_binding_cstr_metadata!(name, env, cstr_backed:, cstr_list_backed:)
        env[:scopes].reverse_each do |scope|
          next if scope.is_a?(FlowScope)
          next unless scope.key?(name)

          scope[name] = scope.fetch(name).merge(cstr_backed:, cstr_list_backed:)
          return
        end
      end

      def trackable_binding_names(env)
        env[:scopes].each_with_object([]) do |scope, names|
          next if scope.is_a?(FlowScope)

          scope.each do |name, binding|
            next unless cstr_trackable_type?(binding[:type]) || cstr_list_trackable_type?(binding[:type])

            names << name unless names.include?(name)
          end
        end
      end

      def binding_cstr_backed?(binding)
        binding && binding[:cstr_backed]
      end

      def binding_cstr_list_backed?(binding)
        binding && binding[:cstr_list_backed]
      end

      def exact_compile_time_numeric_compatibility?(actual_type, expression, expected_type, env: nil)
        return false unless expected_type.is_a?(Types::Primitive) && expected_type.numeric?
        return false if actual_type.is_a?(Types::EnumBase)

        value = compile_time_const_value(expression, env:)
        return false unless value.is_a?(Numeric)

        numeric_constant_fits_type?(value, expected_type)
      end

      def external_numeric_assignment_target?(expression, env:)
        case expression
        when AST::MemberAccess
          receiver_type = infer_field_receiver_type(expression.receiver, env:)
          receiver_type.respond_to?(:external) && receiver_type.external
        else
          false
        end
      end

      def resolve_callee(callee, env, arguments: nil)
        case callee
        when AST::Identifier
          if (binding = lookup_value(callee.name, env))
            return [:callable_value, nil, nil, binding[:type], nil] if callable_type?(binding[:type])

            raise LoweringError, "#{callee.name} is not callable"
          end

          if @ctx.functions.key?(callee.name)
            binding = specialize_function_binding(@ctx.functions.fetch(callee.name), arguments, env)
            callee_name = if binding.external
                            external_function_c_name(binding)
                          else
                            function_binding_c_name(binding, module_name: @ctx.module_name)
                          end
            [ :function, callee_name, nil, binding.type, binding ]
          elsif callee.name == "fatal"
            [:fatal, nil, nil, nil]
          elsif callee.name == "ref_of"
            [:ref_of, nil, nil, nil]
          elsif callee.name == "const_ptr_of"
            [:const_ptr_of, nil, nil, nil]
          elsif callee.name == "read"
            [:read, nil, nil, nil]
          elsif callee.name == "ptr_of"
            [:ptr_of, nil, nil, nil]
          elsif callee.name == "field_of"
            [:compile_time_builtin, "field_of", nil, compile_time_builtin_function_type("field_of", arguments, env)]
          elsif callee.name == "callable_of"
            [:compile_time_builtin, "callable_of", nil, compile_time_builtin_function_type("callable_of", arguments, env)]
          elsif callee.name == "has_attribute"
            [:compile_time_builtin, "has_attribute", nil, compile_time_builtin_function_type("has_attribute", arguments, env)]
          elsif callee.name == "attribute_of"
            [:compile_time_builtin, "attribute_of", nil, compile_time_builtin_function_type("attribute_of", arguments, env)]
          elsif callee.name == "get"
            [:get, nil, nil, nil]
          elsif (type = @ctx.types[callee.name]).is_a?(Types::Struct) || type.is_a?(Types::StringView) || task_type?(type) || type.is_a?(Types::Vector) || type.is_a?(Types::Matrix) || type.is_a?(Types::Quaternion)
            [ :struct_literal, nil, nil, type ]
          else
            emit_fn = @artifacts.emitted_declarations.find { |d| d.is_a?(IR::Function) && d.name == callee.name }
            if emit_fn
              return [:function, emit_fn.c_name, nil, emit_fn.return_type, nil]
            end

            raise LoweringError, "unknown callee #{callee.name}"
          end
        when AST::MemberAccess
          if callee.receiver.is_a?(AST::Identifier) && @ctx.imports.key?(callee.receiver.name)
            imported_module = @ctx.imports.fetch(callee.receiver.name)

            if imported_module.functions.key?(callee.member)
              binding = specialize_function_binding(imported_module.functions.fetch(callee.member), arguments, env)
              return [:function, function_binding_c_name(binding, module_name: imported_module.name), nil, binding.type, binding] unless binding.external

              return [:function, external_function_c_name(binding), nil, binding.type, binding]
            end
            imported_type = imported_module.types[callee.member]
            if imported_type.is_a?(Types::Struct) || imported_type.is_a?(Types::StringView) || task_type?(imported_type) || imported_type.is_a?(Types::Vector) || imported_type.is_a?(Types::Matrix) || imported_type.is_a?(Types::Quaternion)
              return [:struct_literal, nil, nil, imported_module.types.fetch(callee.member)]
            end

            if imported_type.is_a?(Types::Variant) && imported_type.arm_names.include?(callee.member)
              arm_name = callee.member
              return [:variant_arm_ctor, nil, nil, imported_type, [imported_type, arm_name]]
            end
          end

          if (type_expr = resolve_type_expression(callee.receiver))
            if type_expr.is_a?(Types::Variant) && type_expr.arm_names.include?(callee.member)
              arm_name = callee.member
              return [:variant_arm_ctor, nil, nil, type_expr, [type_expr, arm_name]]
            end

            if type_expr.respond_to?(:nested_types) && type_expr.nested_types.key?(callee.member)
              return [:struct_literal, nil, nil, type_expr.nested_types[callee.member]]
            end

            dispatch_receiver_type = method_dispatch_receiver_type(type_expr)
            method_entry_receiver_type = type_expr
            method_entry = @method_definitions[[type_expr, callee.member]]
            method_entry ||= @method_definitions[[type_expr, "static:#{callee.member}"]]
            unless method_entry || dispatch_receiver_type == type_expr
              method_entry_receiver_type = dispatch_receiver_type
              method_entry = @method_definitions[[dispatch_receiver_type, callee.member]]
              method_entry ||= @method_definitions[[dispatch_receiver_type, "static:#{callee.member}"]]
            end
            if method_entry
              method_analysis, method_ast = method_entry
              method_binding = method_analysis.methods.fetch(method_entry_receiver_type).fetch(method_analysis_key(method_ast))
              if method_binding.type.receiver_type.nil?
                method_binding = specialize_function_binding(method_binding, arguments, env, receiver_type: type_expr) if method_binding.type_params.any?
                return [:associated_method, function_binding_c_name(method_binding, module_name: method_analysis.module_name, receiver_type: method_entry_receiver_type), nil, method_binding.type, method_binding]
              end
            end

            raise LoweringError, "unknown associated function #{type_expr}.#{callee.member}"
          end

          resolved_receiver_type = infer_method_receiver_type(callee.receiver, env:, member_name: callee.member)

          if dyn_type?(resolved_receiver_type)
            interface = resolved_receiver_type.interface_binding
            method_binding = interface.methods[callee.member]
            raise LoweringError, "no method '#{callee.member}' on interface #{interface.name}" unless method_binding
            return [:dyn_method, nil, callee.receiver, method_binding, nil]
          end

          dispatch_receiver_type = method_dispatch_receiver_type(resolved_receiver_type)
          method_entry_receiver_type = resolved_receiver_type
          method_entry = @method_definitions[[resolved_receiver_type, callee.member]]
          unless method_entry || dispatch_receiver_type == resolved_receiver_type
            method_entry_receiver_type = dispatch_receiver_type
            method_entry = @method_definitions[[dispatch_receiver_type, callee.member]]
          end
          if method_entry
        method_analysis, method_ast = method_entry
        method_analysis_key = method_ast.kind == :static ? "static:#{method_ast.name}" : method_ast.name
        method_binding = method_analysis.methods.fetch(method_entry_receiver_type).fetch(method_analysis_key)
            method_binding = specialize_function_binding(method_binding, arguments, env, receiver_type: resolved_receiver_type)
            return [
              :method,
              function_binding_c_name(method_binding, module_name: method_analysis.module_name, receiver_type: method_entry_receiver_type),
              callee.receiver,
              method_binding.type,
              method_binding,
            ]
          end

          if callee.member == "with" && struct_with_target_type?(resolved_receiver_type)
            return [:struct_with, nil, callee.receiver, resolved_receiver_type]
          end

          if (str_buffer_method = str_buffer_method_kind(resolved_receiver_type, callee.member))
            return [str_buffer_method, nil, callee.receiver, str_buffer_method_type(str_buffer_method, resolved_receiver_type)]
          end

          if (event_method = event_method_kind(resolved_receiver_type, callee.member))
            event_type = infer_expression_type(callee.receiver, env:)
            return [event_method, nil, callee.receiver, event_method_type(event_method, event_type)]
          end

          if (atomic_method = atomic_method_kind(resolved_receiver_type, callee.member))
            elem = atomic_element_type(resolved_receiver_type)
            ret = case atomic_method
                  when :atomic_load, :atomic_add, :atomic_sub, :atomic_exchange then elem
                  when :atomic_store then @ctx.types.fetch("void")
                  when :atomic_compare_exchange then @ctx.types.fetch("bool")
                  end
            return [atomic_method, nil, callee.receiver, Types::Function.new(nil, params: [], return_type: ret)]
          end

          field_receiver_type = infer_field_receiver_type(callee.receiver, env:)
          if array_type?(field_receiver_type) && callee.member == "as_span"
            return [:array_as_span, nil, callee.receiver, Types::Span.new(array_element_type(field_receiver_type))]
          end

          member_type = field_receiver_type.respond_to?(:field) ? field_receiver_type.field(callee.member) : nil
          member_type = field_receiver_type.respond_to?(:field) ? field_receiver_type.field(callee.member) : nil
          return [:callable_value, nil, nil, member_type, nil] if callable_type?(member_type)

          raise LoweringError, "unknown callee #{callee.receiver}.#{callee.member}"
        when AST::Specialization
          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "reinterpret"
            target_type = resolve_type_ref(callee.arguments.fetch(0).value)
            return [:reinterpret, nil, nil, Types::Function.new("reinterpret", params: [Types::Parameter.new("value", target_type)], return_type: target_type)]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "array"
            array_type = resolve_type_ref(AST::TypeRef.new(name: AST::QualifiedName.new(parts: ["array"]), arguments: callee.arguments, nullable: false))
            return [:array, nil, nil, array_type]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "span"
            span_type = resolve_type_ref(AST::TypeRef.new(name: AST::QualifiedName.new(parts: ["span"]), arguments: callee.arguments, nullable: false))
            return [:struct_literal, nil, nil, span_type]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "zero"
            target_type = resolve_type_ref(callee.arguments.fetch(0).value)
            return [:zero, nil, nil, Types::Function.new("zero", params: [], return_type: target_type)]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "hash"
            resolution = resolve_hash_specialization(callee, env:)
            return [:hash, resolution.callee_name, nil, Types::Function.new("hash", params: [Types::Parameter.new("value", resolution.target_type)], return_type: @ctx.types.fetch("uint")), resolution.binding]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "equal"
            resolution = resolve_equal_specialization(callee, env:)
            params = [
              Types::Parameter.new("left", resolution.target_type),
              Types::Parameter.new("right", resolution.target_type),
            ]
            return [:equal, resolution.callee_name, nil, Types::Function.new("equal", params:, return_type: @ctx.types.fetch("bool")), resolution.binding]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "order"
            resolution = resolve_order_specialization(callee, env:)
            params = [
              Types::Parameter.new("left", resolution.target_type),
              Types::Parameter.new("right", resolution.target_type),
            ]
            return [:order, resolution.callee_name, nil, Types::Function.new("order", params:, return_type: @ctx.types.fetch("int")), resolution.binding]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "attribute_arg"
            return [:compile_time_builtin, "attribute_arg", nil, compile_time_builtin_specialization_function_type(callee)]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "adapt"
            raise LoweringError, "adapt requires exactly one type argument" unless callee.arguments.length == 1

            type_arg = callee.arguments.first.value
            raise LoweringError, "adapt type argument must be a type" unless type_arg.is_a?(AST::TypeRef)

            parts = type_arg.name.parts
            type_args = type_arg.arguments.map { |a| a.value }
            interface = resolve_interface_ref(AST::QualifiedName.new(parts:, type_arguments: type_args))
            dyn_type = Types::Dyn.new(interface, interface.respond_to?(:type_arguments) ? (interface.type_arguments || []) : [])
            return [:adapt, nil, nil, dyn_type, interface]
          end

          if (callable_resolution = resolve_specialized_callable_binding(callee, env:))
            callable_kind, function_binding, receiver = callable_resolution
            if callable_kind == :method
              return [
                :method,
                function_binding_c_name(function_binding, module_name: function_binding.owner.module_name, receiver_type: function_binding.type.receiver_type),
                receiver,
                function_binding.type,
                function_binding,
              ]
            end

            if function_binding.external
              return [:function, external_function_c_name(function_binding), nil, function_binding.type, function_binding]
            end

            return [:function, function_binding_c_name(function_binding, module_name: function_binding.owner.module_name), nil, function_binding.type, function_binding]
          end

          if (type_ref = type_ref_from_specialization(callee))
            specialized_type = resolve_type_ref(type_ref)
            return [:struct_literal, nil, nil, specialized_type] if specialized_type.is_a?(Types::Struct) || task_type?(specialized_type) || specialized_type.is_a?(Types::Vector) || specialized_type.is_a?(Types::Matrix) || specialized_type.is_a?(Types::Quaternion)
          end

          raise LoweringError, "unsupported specialization callee"
        else
          callee_type = infer_expression_type(callee, env:)
          return [:callable_value, nil, nil, callee_type, nil] if callable_type?(callee_type)

          raise LoweringError, "unsupported callee #{callee.class.name}"
        end
      end

      def infer_expression_type(expression, env:, expected_type: nil)
        case expression
        when AST::AwaitExpr
          task_type = infer_expression_type(expression.expression, env:)
          raise LoweringError, "await requires a Task value, got #{task_type}" unless task_type.is_a?(Types::Task)

          task_type.result_type
        when AST::IntegerLiteral
          if expected_type.is_a?(Types::Primitive) && expected_type.integer?
            expected_type
          else
            @ctx.types.fetch("int")
          end
        when AST::FloatLiteral
          if expected_type.is_a?(Types::Primitive) && expected_type.float?
            expected_type
          else
            @ctx.types.fetch("double")
          end
        when AST::SizeofExpr, AST::AlignofExpr, AST::OffsetofExpr
          @ctx.types.fetch("ptr_uint")
        when AST::StringLiteral
          @ctx.types.fetch(expression.cstring ? "cstr" : "str")
        when AST::FormatString
          @ctx.types.fetch("str")
        when AST::BooleanLiteral
          @ctx.types.fetch("bool")
        when AST::NullLiteral
          infer_null_literal_type(expression, expected_type)
        when AST::Identifier
          binding = lookup_value(expression.name, env)
          return binding[:type] if binding
          return function_type_for_name(expression.name) if @ctx.functions.key?(expression.name)

          raise LoweringError, "unknown identifier #{expression.name}"
        when AST::MemberAccess
          if (type_expr = resolve_type_expression(expression.receiver))
            member_type = resolve_type_member(type_expr, expression.member)
            return member_type if member_type

            dispatch_receiver_type = method_dispatch_receiver_type(type_expr)
            method_entry_receiver_type = type_expr
            method_entry = @method_definitions[[type_expr, expression.member]]
            method_entry ||= @method_definitions[[type_expr, "static:#{expression.member}"]]
            unless method_entry || dispatch_receiver_type == type_expr
              method_entry_receiver_type = dispatch_receiver_type
              method_entry = @method_definitions[[dispatch_receiver_type, expression.member]]
              method_entry ||= @method_definitions[[dispatch_receiver_type, "static:#{expression.member}"]]
            end
            if method_entry
              method_analysis, method_ast = method_entry
              method_binding = method_analysis.methods.fetch(method_entry_receiver_type).fetch(method_analysis_key(method_ast))
              return method_binding.type if method_binding.type.receiver_type.nil?
            end
          end
          if expression.receiver.is_a?(AST::Identifier) && @ctx.imports.key?(expression.receiver.name)
            imported_module = @ctx.imports.fetch(expression.receiver.name)
            return imported_module.values.fetch(expression.member).type if imported_module.values.key?(expression.member)
            return imported_module.functions.fetch(expression.member).type if imported_module.functions.key?(expression.member)
          end
          receiver_type = infer_field_receiver_type(expression.receiver, env:)
          if (event_type = event_member_from_owner_type(receiver_type, expression.member))
            return event_type
          end

          if receiver_type == @ctx.types["field_handle"]
            return infer_field_handle_member_type(expression)
          end
          if receiver_type == @ctx.types["member_handle"]
            return infer_member_handle_member_type(expression)
          end

          return receiver_type.field(expression.member) if receiver_type.respond_to?(:field)
          raise LoweringError, "unknown member #{expression.member}"
        when AST::IndexAccess
          receiver_type = infer_expression_type(expression.receiver, env:)
          index_type = infer_expression_type(expression.index, env:)
          infer_index_result_type(receiver_type, index_type)
        when AST::UnaryOp
          return infer_result_propagation_type(expression, env:) if expression.operator == "?"

          operand_type = infer_expression_type(expression.operand, env:, expected_type:)
          case expression.operator
          when "not"
            @ctx.types.fetch("bool")
          else
            operand_type
          end
        when AST::BinaryOp
          left_type, right_type = infer_binary_operand_types(expression, env:, expected_type: expected_type)

          case expression.operator
          when "and", "or", "<", "<=", ">", ">=", "==", "!="
            @ctx.types.fetch("bool")
          when "+", "-", "*", "/"
            aggregate_arithmetic_result_type(expression.operator, left_type, right_type) || pointer_arithmetic_result_type(expression.operator, left_type, right_type) || common_numeric_type(left_type, right_type) || left_type
          when "%"
            common_integer_type(left_type, right_type) || left_type
          else
            left_type
          end
        when AST::IfExpr
          then_env = env_with_refinements(env, flow_refinements(expression.condition, truthy: true, env:))
          else_env = env_with_refinements(env, flow_refinements(expression.condition, truthy: false, env:))
          then_type = infer_expression_type(expression.then_expression, env: then_env, expected_type: expected_type)
          else_type = infer_expression_type(expression.else_expression, env: else_env, expected_type: expected_type)

          if expected_type &&
             if_expression_branch_compatible?(then_type, expected_type) &&
             if_expression_branch_compatible?(else_type, expected_type)
            return expected_type
          end

          conditional_common_type(then_type, else_type) || raise(LoweringError, "if expression branches require compatible types, got #{then_type} and #{else_type}")
        when AST::MatchExpr
          scrutinee_type = infer_expression_type(expression.expression, env:)
          arm_types = expression.arms.map do |arm|
            arm_env = duplicate_env(env)
            if scrutinee_type.is_a?(Types::Variant) && arm.binding_name && !wildcard_arm_pattern?(arm.pattern)
              arm_name = variant_match_arm_name_from_pattern(arm.pattern)
              if arm_name && scrutinee_type.has_payload?(arm_name)
                fields = scrutinee_type.arm(arm_name)
                payload_type = Types::VariantArmPayload.new(scrutinee_type, arm_name, fields)
                arm_env[:scopes].last[arm.binding_name] = local_binding(type: payload_type, c_name: c_local_name(arm.binding_name), mutable: false, pointer: false)
              end
            end
            infer_expression_type(arm.value, env: arm_env, expected_type: expected_type)
          end

          if expected_type && arm_types.all? { |arm_type| if_expression_branch_compatible?(arm_type, expected_type) }
            return expected_type
          end

          common_type = arm_types.first
          arm_types.drop(1).each do |arm_type|
            common_type = conditional_common_type(common_type, arm_type) || raise(LoweringError, "match expression arms require compatible types, got #{common_type} and #{arm_type}")
          end
          common_type
        when AST::UnsafeExpr
          infer_expression_type(expression.expression, env:, expected_type:)
        when AST::ProcExpr
          resolve_type_ref(AST::ProcType.new(params: expression.params, return_type: expression.return_type))
        when AST::Call
          kind, _callee_name, _receiver, callee_type = resolve_callee(expression.callee, env, arguments: expression.arguments)
          case kind
          when :function, :method, :associated_method, :callable_value,
            :str_buffer_clear, :str_buffer_assign, :str_buffer_append, :str_buffer_assign_format, :str_buffer_append_format,
            :str_buffer_len, :str_buffer_capacity, :str_buffer_as_str, :str_buffer_as_cstr,
            :event_subscribe, :event_subscribe_once, :event_unsubscribe, :event_emit, :event_wait,
            :compile_time_builtin,
            :reinterpret, :zero, :hash, :equal, :order,
            :dyn_method
            callee_type.return_type
          when :struct_literal, :struct_with, :array, :variant_arm_ctor, :adapt
            callee_type
          when :ref_of
            argument_type = infer_expression_type(expression.arguments.fetch(0).value, env:)
            Types::GenericInstance.new("ref", [argument_type])
          when :const_ptr_of
            argument_type = infer_expression_type(expression.arguments.fetch(0).value, env:)
            Types::GenericInstance.new("const_ptr", [argument_type])
          when :read
            infer_value_type(expression.arguments.fetch(0).value, env:)
          when :ptr_of
            argument_type = infer_expression_type(expression.arguments.fetch(0).value, env:)
            if ref_type?(argument_type)
              Types::GenericInstance.new("ptr", [referenced_type(argument_type)])
            else
              Types::GenericInstance.new("ptr", [infer_expression_type(expression.arguments.fetch(0).value, env:, expected_type: expected_type && pointer_type?(expected_type) ? pointee_type(expected_type) : nil)])
            end
          when :array_as_span
            callee_type
          when :fatal
            @ctx.types.fetch("void")
          when :get
            receiver_type = infer_expression_type(expression.arguments.fetch(0).value, env:)
            elem_type = if array_type?(receiver_type)
                          array_element_type(receiver_type)
                        else
                          receiver_type.element_type
                        end
            Types::Nullable.new(Types::GenericInstance.new("ptr", [elem_type]))
          when :atomic_load, :atomic_add, :atomic_sub, :atomic_exchange, :atomic_store, :atomic_compare_exchange
            callee_type.return_type
          else
            raise LoweringError, "unsupported call kind #{kind}"
          end
        when AST::PrefixCast
          resolve_type_ref(expression.target_type)
        when AST::Specialization
          if expression.callee.is_a?(AST::Identifier) && expression.callee.name == "zero"
            _, _, _, function_type = resolve_callee(expression, env, arguments: [])
            function_type.return_type
          elsif expression.callee.is_a?(AST::Identifier) && expression.callee.name == "default"
            resolve_default_specialization(expression, env:).target_type
          elsif (callable_resolution = resolve_specialized_callable_binding(expression, env:))
            callable_kind, function_binding, = callable_resolution
            raise LoweringError, "specialized method must be called" if callable_kind == :method

            function_binding.type
          else
            raise LoweringError, "unsupported specialization"
          end
        when AST::RangeExpr
          raise LoweringError, "range expression is not valid in this context; use it as a for-loop iterable"
        when AST::ExpressionList
          names = []
          element_types = []
          expression.elements.each do |element|
            if element.is_a?(AST::Argument)
              names << element.name
              element_types << infer_expression_type(element.value, env:)
            else
              names << nil
              element_types << infer_expression_type(element, env:)
            end
          end
          has_named = names.any?
          Types::Tuple.new(element_types, field_names: has_named ? names : nil)
        when AST::DetachExpr
          Types::Handle.new
        else
          raise LoweringError, "unsupported expression type #{expression.class.name}"
        end
      end

      def infer_binary_operand_types(expression, env:, expected_type: nil)
        propagated_type = propagating_expected_type(expression.operator, expected_type)
        left_type = infer_expression_type(expression.left, env:, expected_type: propagated_type)
        right_env = binary_right_env(expression, env)
        right_expected_type = case expression.operator
                              when "<<", ">>"
                                propagated_type || left_type
                              when "+", "-", "*", "/", "%"
                                propagated_type || left_type
                              when "|", "&", "^"
                                left_type
                              else
                                left_type
                              end
        right_type = infer_expression_type(expression.right, env: right_env, expected_type: right_expected_type)
        left_type, right_type = harmonize_binary_float_literal_types(expression.left, expression.right, left_type, right_type, env: right_env)
        harmonize_binary_integer_literal_types(expression.left, expression.right, left_type, right_type, env: right_env)
      end

      def binary_right_env(expression, env)
        case expression.operator
        when "and"
          env_with_refinements(env, flow_refinements(expression.left, truthy: true, env:))
        when "or"
          env_with_refinements(env, flow_refinements(expression.left, truthy: false, env:))
        else
          env
        end
      end

      def harmonize_binary_float_literal_types(left_expression, right_expression, left_type, right_type, env:)
        if float_literal_expression?(left_expression) && right_type.is_a?(Types::Primitive) && right_type.float?
          left_type = infer_expression_type(left_expression, env:, expected_type: right_type)
        end

        if float_literal_expression?(right_expression) && left_type.is_a?(Types::Primitive) && left_type.float?
          right_type = infer_expression_type(right_expression, env:, expected_type: left_type)
        end

        [left_type, right_type]
      end

      def float_literal_expression?(expression)
        expression.is_a?(AST::FloatLiteral) ||
          (expression.is_a?(AST::UnaryOp) && ["+", "-"].include?(expression.operator) && float_literal_expression?(expression.operand))
      end

      def harmonize_binary_integer_literal_types(left_expression, right_expression, left_type, right_type, env:)
        if integer_literal_expression?(left_expression) && right_type.is_a?(Types::Primitive) && right_type.integer?
          left_type = infer_expression_type(left_expression, env:, expected_type: right_type)
        end

        if integer_literal_expression?(right_expression) && left_type.is_a?(Types::Primitive) && left_type.integer?
          right_type = infer_expression_type(right_expression, env:, expected_type: left_type)
        end

        [left_type, right_type]
      end

      def integer_literal_expression?(expression)
        expression.is_a?(AST::IntegerLiteral)
      end

      def propagating_expected_type(operator, expected_type)
        case operator
        when "+", "-", "*", "/", "%", "<<", ">>"
          return expected_type if expected_type.is_a?(Types::Primitive) && expected_type.numeric?
        when "|", "&", "^"
          return expected_type if expected_type.is_a?(Types::Primitive) && expected_type.integer?
          return expected_type if expected_type.is_a?(Types::Flags)
        end

        nil
      end

      def promoted_binary_operand_type(operator, left_type, right_type)
        case operator
        when "+", "-", "*", "/", "<", "<=", ">", ">=", "==", "!="
          common_numeric_type(left_type, right_type)
        when "%"
          common_integer_type(left_type, right_type)
        end
      end

      def cast_expression(expression, target_type)
        return expression if expression.type == target_type

        IR::Cast.new(target_type:, expression:, type: target_type)
      end

      def pointer_lowered_sync_method_receiver?(binding)
        return false if binding.async

        pointer_lowered_method_receiver?(binding.type, binding)
      end

      def pointer_lowered_method_receiver?(callee_type, callee_binding)
        return true if callee_type.receiver_editable

        receiver_type_uses_pointer_lowering?(callee_type.receiver_type) && !callee_binding&.async
      end

      def receiver_type_uses_pointer_lowering?(type)
        case type
        when Types::Nullable
          receiver_type_uses_pointer_lowering?(type.base)
        when Types::Struct, Types::StructInstance
          type_contains_array_storage?(type)
        else
          false
        end
      end

      def type_contains_array_storage?(type)
        return true if array_type?(type)

        case type
        when Types::Struct, Types::StructInstance
          type.fields.each_value.any? { |field_type| type_contains_array_storage?(field_type) }
        when Types::Nullable
          type_contains_array_storage?(type.base)
        else
          false
        end
      end

      def reinterpret_expression(expression, target_type)
        return expression if expression.type == target_type

        IR::ReinterpretExpr.new(target_type:, source_type: expression.type, expression:, type: target_type)
      end

      def foreign_identity_projection_expression(expression, target_type)
        return expression if expression.type == target_type
        return cast_expression(expression, target_type) if foreign_identity_projection_cast_compatible?(expression.type, target_type)

        if foreign_identity_projection_reinterpret_compatible?(expression.type, target_type)
          record_external_layout_assertion(expression.type, target_type)
          return reinterpret_expression(expression, target_type)
        end

        nil
      end

      def record_external_layout_assertion(source_type, target_type)
        source_root = ffi_external_layout_root_type(source_type)
        target_root = ffi_external_layout_root_type(target_type)
        return unless source_root && target_root
        return unless source_root.external && target_root.external
        return if source_root.module_name == target_root.module_name

        pair_key = [[source_root.module_name, source_root.name], [target_root.module_name, target_root.name]].sort.freeze
        return if @artifacts.emitted_external_layout_pairs[pair_key]

        @artifacts.emitted_external_layout_pairs[pair_key] = true
        @artifacts.external_layout_assertions << IR::StaticAssert.new(
          condition: IR::Binary.new(
            operator: "==",
            left: IR::SizeofExpr.new(target_type: source_root, type: @ctx.types.fetch("ptr_uint")),
            right: IR::SizeofExpr.new(target_type: target_root, type: @ctx.types.fetch("ptr_uint")),
            type: @ctx.types.fetch("bool"),
          ),
          message: IR::StringLiteral.new(
            value: "FFI layout mismatch: #{source_root} vs #{target_root}",
            type: @ctx.types.fetch("str"),
            cstring: false,
          ),
        )
      end

      def ffi_external_layout_root_type(type)
        type = type.base while type.is_a?(Types::Nullable)
        return pointee_type(type) if pointer_type?(type)

        type
      end

      def infer_null_literal_type(expression, expected_type)
        return Types::Null.new(resolve_type_ref(expression.type)) if expression.type

        expected_type || null_type
      end

      def common_numeric_type(left_type, right_type)
        return left_type if left_type == right_type
        return unless left_type.is_a?(Types::Primitive) && right_type.is_a?(Types::Primitive)
        return unless left_type.numeric? && right_type.numeric?

        return common_integer_type(left_type, right_type) if left_type.integer? && right_type.integer?
        return wider_float_type(left_type, right_type) if left_type.float? && right_type.float?

        float_type, integer_type = left_type.float? ? [left_type, right_type] : [right_type, left_type]
        return unless integer_type.integer? && integer_type.fixed_width_integer?

        float_type
      end

      def common_integer_type(left_type, right_type)
        return left_type if left_type == right_type
        return unless left_type.is_a?(Types::Primitive) && right_type.is_a?(Types::Primitive)
        return unless left_type.integer? && right_type.integer?
        return unless left_type.fixed_width_integer? && right_type.fixed_width_integer?
        return unless left_type.signed_integer? == right_type.signed_integer?

        left_type.integer_width >= right_type.integer_width ? left_type : right_type
      end

      def wider_float_type(left_type, right_type)
        left_type.float_width >= right_type.float_width ? left_type : right_type
      end

      def aggregate_arithmetic_result_type(operator, left_type, right_type)
        if left_type.is_a?(Types::Vector) && right_type.is_a?(Types::Vector) && left_type.name == right_type.name
          return left_type
        end
        if left_type.is_a?(Types::Matrix) && right_type.is_a?(Types::Matrix) && left_type.name == right_type.name
          return left_type
        end
        if left_type.is_a?(Types::Quaternion) && right_type.is_a?(Types::Quaternion)
          return left_type
        end

        scalar_result = aggregate_scalar_result(left_type, right_type)
        return scalar_result if scalar_result

        case operator
        when "+", "-"
          nil
        when "*", "/"
          aggregate_scalar_result(right_type, left_type)
        else
          nil
        end
      end

      def aggregate_scalar_result(aggregate_type, scalar_type)
        return nil unless aggregate_type.is_a?(Types::Vector) || aggregate_type.is_a?(Types::Matrix)
        return nil unless scalar_type.is_a?(Types::Primitive) && scalar_type.numeric?

        aggregate_type
      end

      def pointer_arithmetic_result_type(operator, left_type, right_type)
        return left_type if pointer_type?(left_type) && integer_type?(right_type) && (operator == "+" || operator == "-")
        return right_type if operator == "+" && integer_type?(left_type) && pointer_type?(right_type)

        nil
      end

      def resolve_type_expression(expression)
        case expression
        when AST::Identifier
          return current_type_params[expression.name] if current_type_params.key?(expression.name)

          @ctx.types[expression.name]
        when AST::MemberAccess
          return nil unless expression.receiver.is_a?(AST::Identifier)

          if @ctx.imports.key?(expression.receiver.name)
            return @ctx.imports.fetch(expression.receiver.name).types[expression.member]
          end

          parent_type = @ctx.types[expression.receiver.name]
          return parent_type.nested_types[expression.member] if parent_type.respond_to?(:nested_types) && parent_type.nested_types.key?(expression.member)

          nil
        when AST::Specialization
          type_ref = type_ref_from_specialization(expression)
          return nil unless type_ref

          resolve_type_ref(type_ref)
        end
      end

      def resolve_type_member(type, name)
        case type
        when Types::Enum, Types::Flags
          type.member(name)
        when Types::Variant
          type if type.arm_names.include?(name)
        end
      end

      def function_type_for_name(name)
        binding = @ctx.functions.fetch(name)
        raise LoweringError, "generic function #{name} cannot be used as a value" if binding.type_params.any?
        raise LoweringError, "foreign function #{name} cannot be used as a value" if foreign_function_binding?(binding)

        binding.type
      end

      def resolve_specialized_callable_binding(expression, env:)
        callable_kind = :function
        receiver = nil
        receiver_type = nil
        binding = case expression.callee
                  when AST::Identifier
                    @ctx.functions[expression.callee.name]
                  when AST::MemberAccess
                    if expression.callee.receiver.is_a?(AST::Identifier) && @ctx.imports.key?(expression.callee.receiver.name)
                      @ctx.imports.fetch(expression.callee.receiver.name).functions[expression.callee.member]
                    elsif (type_expr = resolve_type_expression(expression.callee.receiver))
                      dispatch_receiver_type = method_dispatch_receiver_type(type_expr)
                      method_entry_receiver_type = type_expr
                      method_entry = @method_definitions[[type_expr, expression.callee.member]]
                      method_entry ||= @method_definitions[[type_expr, "static:#{expression.callee.member}"]]
                      unless method_entry || dispatch_receiver_type == type_expr
                        method_entry_receiver_type = dispatch_receiver_type
                        method_entry = @method_definitions[[dispatch_receiver_type, expression.callee.member]]
                        method_entry ||= @method_definitions[[dispatch_receiver_type, "static:#{expression.callee.member}"]]
                      end
                      if method_entry
                        method_analysis, method_ast = method_entry
                        method_binding = method_analysis.methods.fetch(method_entry_receiver_type).fetch(method_analysis_key(method_ast))
                        if method_binding.type.receiver_type.nil?
                          receiver_type = type_expr
                          method_binding
                        end
                      end
                    else
                      resolved_receiver_type = infer_method_receiver_type(expression.callee.receiver, env:, member_name: expression.callee.member)
                      dispatch_receiver_type = method_dispatch_receiver_type(resolved_receiver_type)
                      method_entry_receiver_type = resolved_receiver_type
                      method_entry = @method_definitions[[resolved_receiver_type, expression.callee.member]]
                      unless method_entry || dispatch_receiver_type == resolved_receiver_type
                        method_entry_receiver_type = dispatch_receiver_type
                        method_entry = @method_definitions[[dispatch_receiver_type, expression.callee.member]]
                      end
                      if method_entry
                        method_analysis, method_ast = method_entry
                        callable_kind = :method
                        receiver = expression.callee.receiver
                        receiver_type = resolved_receiver_type
                        method_analysis.methods.fetch(method_entry_receiver_type).fetch(method_analysis_key(method_ast))
                      end
                    end
                  end
        return nil unless binding

        type_arguments = resolve_specialization_type_arguments(expression)
        [callable_kind, instantiate_function_binding_with_receiver(binding, type_arguments, receiver_type:), receiver]
      end

      def resolve_default_specialization(expression, env:)
        target_type = resolve_type_ref(expression.arguments.fetch(0).value)

        explicit_default = resolve_explicit_default_binding(target_type, context: "default[#{target_type}]")
        raise LoweringError, "default[#{target_type}] requires associated function #{target_type}.default()" unless explicit_default

        DefaultResolution.new(target_type:, binding: explicit_default.binding, callee_name: explicit_default.callee_name)
      end

      def resolve_hash_specialization(expression, env:)
        target_type = resolve_type_ref(expression.arguments.fetch(0).value)
        explicit_hash = resolve_explicit_hash_binding(target_type, context: "hash[#{target_type}]")
        raise LoweringError, "hash[#{target_type}] requires associated function #{target_type}.hash(value: const_ptr[#{target_type}]) -> uint" unless explicit_hash

        HashResolution.new(target_type:, binding: explicit_hash.binding, callee_name: explicit_hash.callee_name)
      end

      def resolve_equal_specialization(expression, env:)
        target_type = resolve_type_ref(expression.arguments.fetch(0).value)
        explicit_equal = resolve_explicit_equal_binding(target_type, context: "equal[#{target_type}]")
        raise LoweringError, "equal[#{target_type}] requires associated function #{target_type}.equal(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> bool" unless explicit_equal

        EqualResolution.new(target_type:, binding: explicit_equal.binding, callee_name: explicit_equal.callee_name)
      end

      def resolve_order_specialization(expression, env:)
        target_type = resolve_type_ref(expression.arguments.fetch(0).value)
        explicit_order = resolve_explicit_order_binding(target_type, context: "order[#{target_type}]")
        raise LoweringError, "order[#{target_type}] requires associated function #{target_type}.order(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> int" unless explicit_order

        OrderResolution.new(target_type:, binding: explicit_order.binding, callee_name: explicit_order.callee_name)
      end

      def resolve_explicit_default_binding(target_type, context:)
        requirement_message = "#{context} requires associated function #{target_type}.default()"
        resolve_explicit_associated_binding(target_type, "default", requirement_message:) do |method_binding, _method_analysis, _method_entry_receiver_type|
          raise LoweringError, "#{context} requires #{target_type}.default() to take 0 arguments" unless method_binding.type.params.empty?
          unless method_binding.type.return_type == target_type
            raise LoweringError, "#{context} requires #{target_type}.default() to return #{target_type}, got #{method_binding.type.return_type}"
          end
        end
      end

      def resolve_explicit_hash_binding(target_type, context:)
        requirement_message = "#{context} requires associated function #{target_type}.hash(value: const_ptr[#{target_type}]) -> uint"
        resolve_explicit_associated_binding(target_type, "hash", requirement_message:) do |method_binding, _method_analysis, _method_entry_receiver_type|
          unless method_binding.type.params.map(&:type) == [const_pointer_to(target_type)]
            raise LoweringError, "#{context} requires #{target_type}.hash(value: const_ptr[#{target_type}]) -> uint"
          end
          unless method_binding.type.return_type == @ctx.types.fetch("uint")
            raise LoweringError, "#{context} requires #{target_type}.hash(value: const_ptr[#{target_type}]) -> uint, got #{method_binding.type.return_type}"
          end
        end
      end

      def resolve_explicit_equal_binding(target_type, context:)
        requirement_message = "#{context} requires associated function #{target_type}.equal(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> bool"
        resolve_explicit_associated_binding(target_type, "equal", requirement_message:) do |method_binding, _method_analysis, _method_entry_receiver_type|
          expected_param_types = [const_pointer_to(target_type), const_pointer_to(target_type)]
          unless method_binding.type.params.map(&:type) == expected_param_types
            raise LoweringError, "#{context} requires #{target_type}.equal(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> bool"
          end
          unless method_binding.type.return_type == @ctx.types.fetch("bool")
            raise LoweringError, "#{context} requires #{target_type}.equal(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> bool, got #{method_binding.type.return_type}"
          end
        end
      end

      def resolve_explicit_order_binding(target_type, context:)
        requirement_message = "#{context} requires associated function #{target_type}.order(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> int"
        resolve_explicit_associated_binding(target_type, "order", requirement_message:) do |method_binding, _method_analysis, _method_entry_receiver_type|
          expected_param_types = [const_pointer_to(target_type), const_pointer_to(target_type)]
          unless method_binding.type.params.map(&:type) == expected_param_types
            raise LoweringError, "#{context} requires #{target_type}.order(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> int"
          end
          unless method_binding.type.return_type == @ctx.types.fetch("int")
            raise LoweringError, "#{context} requires #{target_type}.order(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> int, got #{method_binding.type.return_type}"
          end
        end
      end

      def resolve_explicit_format_binding(target_type, context:)
        length_binding = resolve_explicit_format_len_binding(target_type, context:)
        append_binding = resolve_explicit_format_append_binding(target_type, context:)

        return ExplicitFormatBinding.new(
          length_binding: length_binding.fetch(:binding),
          length_callee_name: length_binding.fetch(:callee_name),
          append_binding: append_binding.fetch(:binding),
          append_callee_name: append_binding.fetch(:callee_name),
        ) if length_binding && append_binding

        if length_binding || append_binding
          raise LoweringError, "#{context} requires methods #{target_type}.format_len() -> ptr_uint and #{target_type}.append_format(output: ref[std.string.String]) -> void"
        end

        nil
      end

      def resolve_explicit_format_len_binding(target_type, context:)
        requirement_message = "#{context} requires method #{target_type}.format_len() -> ptr_uint"
        resolve_explicit_instance_binding(target_type, "format_len", requirement_message:) do |method_binding, _method_analysis, _method_entry_receiver_type|
          raise LoweringError, "#{context} requires #{target_type}.format_len() to take 0 arguments" unless method_binding.type.params.empty?
          raise LoweringError, "#{context} requires #{target_type}.format_len() to be non-editable" if method_binding.type.receiver_editable
          unless method_binding.type.return_type == @ctx.types.fetch("ptr_uint")
            raise LoweringError, "#{context} requires #{target_type}.format_len() -> ptr_uint, got #{method_binding.type.return_type}"
          end
        end
      end

      def resolve_explicit_format_append_binding(target_type, context:)
        requirement_message = "#{context} requires method #{target_type}.append_format(output: ref[std.string.String]) -> void"
        resolve_explicit_instance_binding(target_type, "append_format", requirement_message:) do |method_binding, _method_analysis, _method_entry_receiver_type|
          raise LoweringError, "#{context} requires #{target_type}.append_format() to be non-editable" if method_binding.type.receiver_editable
          unless method_binding.type.params.length == 1 && string_builder_ref_type?(method_binding.type.params.first.type)
            raise LoweringError, "#{context} requires #{target_type}.append_format(output: ref[std.string.String]) -> void"
          end
          unless method_binding.type.return_type == @ctx.types.fetch("void")
            raise LoweringError, "#{context} requires #{target_type}.append_format(output: ref[std.string.String]) -> void, got #{method_binding.type.return_type}"
          end
        end
      end

      def method_analysis_key(method_ast)
        method_ast.kind == :static ? "static:#{method_ast.name}" : method_ast.name
      end

      def resolve_explicit_associated_binding(target_type, method_name, requirement_message:)
        dispatch_receiver_type = method_dispatch_receiver_type(target_type)
        method_entry_receiver_type = target_type
        static_method_name = "static:#{method_name}"
        method_entry = @method_definitions[[target_type, static_method_name]]
        unless method_entry || dispatch_receiver_type == target_type
          method_entry_receiver_type = dispatch_receiver_type
          method_entry = @method_definitions[[dispatch_receiver_type, static_method_name]]
        end
        return nil unless method_entry

        method_analysis, method_ast = method_entry
        method_binding = method_analysis.methods.fetch(method_entry_receiver_type).fetch(method_analysis_key(method_ast))
        raise LoweringError, requirement_message unless method_binding.type.receiver_type.nil?

        method_binding = instantiate_function_binding_with_receiver(method_binding, [], receiver_type: target_type) if method_binding.type_params.any?
        yield method_binding, method_analysis, method_entry_receiver_type

        callee_name = if method_binding.external
                        external_function_c_name(method_binding)
                      else
                        function_binding_c_name(method_binding, module_name: method_analysis.module_name, receiver_type: method_entry_receiver_type)
                      end

        case method_name
        when "default"
          ExplicitDefaultBinding.new(binding: method_binding, callee_name:)
        when "hash"
          ExplicitHashBinding.new(binding: method_binding, callee_name:)
        when "equal"
          ExplicitEqualBinding.new(binding: method_binding, callee_name:)
        when "order"
          ExplicitOrderBinding.new(binding: method_binding, callee_name:)
        else
          raise LoweringError, "unsupported associated hook #{method_name}"
        end
      end

      def resolve_explicit_instance_binding(target_type, method_name, requirement_message:)
        dispatch_receiver_type = method_dispatch_receiver_type(target_type)
        method_entry_receiver_type = target_type
        method_entry = @method_definitions[[target_type, method_name]]
        unless method_entry || dispatch_receiver_type == target_type
          method_entry_receiver_type = dispatch_receiver_type
          method_entry = @method_definitions[[dispatch_receiver_type, method_name]]
        end
        return nil unless method_entry

        method_analysis, method_ast = method_entry
        method_binding = method_analysis.methods.fetch(method_entry_receiver_type).fetch(method_analysis_key(method_ast))
        raise LoweringError, requirement_message if method_binding.type.receiver_type.nil?

        method_binding = instantiate_function_binding_with_receiver(method_binding, [], receiver_type: target_type) if method_binding.type_params.any?
        yield method_binding, method_analysis, method_entry_receiver_type

        callee_name = if method_binding.external
                        external_function_c_name(method_binding)
                      else
                        function_binding_c_name(method_binding, module_name: method_analysis.module_name, receiver_type: method_entry_receiver_type)
                      end

        {
          binding: method_binding,
          callee_name: callee_name,
        }
      end

      def resolve_specialization_type_arguments(expression)
        expression.arguments.map do |argument|
          resolve_type_argument(argument.value)
        end
      end

      def resolve_type_argument(argument, type_params: current_type_params)
        case argument
        when AST::TypeRef
          resolve_type_argument_ref(argument, type_params:)
        when AST::FunctionType, AST::ProcType
          resolve_type_ref(argument, type_params:)
        when AST::IntegerLiteral, AST::FloatLiteral
          Types::LiteralTypeArg.new(argument.value)
        else
          raise LoweringError, "unsupported type argument #{argument.class.name}"
        end
      end

      def resolve_type_argument_ref(type_ref, type_params:)
        return resolve_type_ref(type_ref, type_params:) unless literal_type_argument_name_candidate?(type_ref)

        resolve_type_ref(type_ref, type_params:)
      rescue LoweringError => error
        literal_type_argument = resolve_named_literal_type_argument(type_ref)
        return literal_type_argument if literal_type_argument

        raise error
      end

      def literal_type_argument_name_candidate?(type_ref)
        type_ref.arguments.empty? && !type_ref.nullable
      end

      def resolve_named_literal_type_argument(type_ref)
        value = case type_ref.name.parts.length
                when 1
                  resolve_current_module_const_value(type_ref.name.parts.first)
                when 2
                  resolve_imported_module_const_value(type_ref.name.parts.first, type_ref.name.parts.last)
                end

        return unless value.is_a?(Integer) || value.is_a?(Float)

        Types::LiteralTypeArg.new(value)
      end

      def resolve_current_module_const_value(name)
        binding = @ctx.values[name]
        return unless binding&.kind == :const

        binding.const_value
      end

      def resolve_imported_module_const_value(import_name, value_name)
        imported_module = @ctx.imports[import_name]
        return unless imported_module
        if imported_module.private_value?(value_name)
          raise LoweringError, "#{import_name}.#{value_name} is private to module #{imported_module.name}"
        end

        binding = imported_module.values[value_name]
        return unless binding&.kind == :const

        binding.const_value
      end

      def resolve_type_member_const_value(expression)
        type = resolve_type_expression(expression.receiver)
        return unless type.is_a?(Types::EnumBase)

        type.member_value(expression.member)
      end

      def compile_time_numeric_const_expression?(expression, env: nil)
        value = compile_time_const_value(expression, env:)
        value.is_a?(Integer) || value.is_a?(Float)
      end

      def compile_time_const_value(expression, env: nil)
        CompileTime.evaluate(
          expression,
          resolve_identifier: lambda do |identifier_expression|
            if env
              binding = lookup_value(identifier_expression.name, env)
              return binding[:const_value] unless binding&.fetch(:const_value, nil).nil?
            end

            value = resolve_current_module_const_value(identifier_expression.name)
            return value if value

            @ctx.types[identifier_expression.name]
          end,
          resolve_member_access: lambda do |member_access_expression|
            if (receiver_value = CompileTime.evaluate(
                  member_access_expression.receiver,
                  resolve_identifier: lambda do |identifier_expression|
                    if env
                      binding = lookup_value(identifier_expression.name, env)
                      return binding[:const_value] unless binding&.fetch(:const_value, nil).nil?
                    end
                    resolve_current_module_const_value(identifier_expression.name)
                  end,
                  resolve_member_access: lambda { |ma| nil },
                  resolve_type_ref: lambda { |tr| resolve_type_ref(tr) },
                  resolve_call: lambda { |ce| evaluate_compile_time_call(ce, env:) },
                ))
              case receiver_value
              when Types::FieldHandle
                case member_access_expression.member
                when "name" then next receiver_value.field_name
                when "type" then next resolve_type_ref(receiver_value.field_declaration.type)
                end
              when Types::MemberHandle
                case member_access_expression.member
                when "name" then next receiver_value.member_name
                when "value" then next receiver_value.member_value
                end
              end
            end

            value = if member_access_expression.receiver.is_a?(AST::Identifier)
                      resolve_imported_module_const_value(member_access_expression.receiver.name, member_access_expression.member)
                    end
            next value unless value.nil?

            resolve_type_member_const_value(member_access_expression)
          end,
          resolve_type_ref: lambda do |type_ref|
            resolve_type_ref(type_ref)
          end,
          resolve_call: lambda do |call_expression|
            evaluate_compile_time_call(call_expression, env:)
          end,
        )
      end

      def evaluate_compile_time_call(expression, env:)
        case expression.callee
        when AST::Identifier
          case expression.callee.name
          when "field_of"
            evaluate_field_of_call(expression.arguments, env:)
          when "fields_of"
            evaluate_fields_of_call(expression.arguments, env:)
          when "callable_of"
            evaluate_callable_of_call(expression.arguments)
          when "has_attribute"
            evaluate_has_attribute_call(expression.arguments, env:)
          when "attribute_of"
            evaluate_attribute_of_call(expression.arguments, env:)
          when "members_of"
            evaluate_members_of_call(expression.arguments, env:)
          when "attributes_of"
            evaluate_attributes_of_call(expression.arguments, env:)
          else
            func = @ctx.functions[expression.callee.name]
            if func&.ast&.respond_to?(:const) && func.ast.const
              evaluate_const_function_body_lower(func, expression.arguments)
            else
              evaluate_type_returning_call(expression, env:)
            end
          end
        when AST::Specialization
          if expression.callee.callee.is_a?(AST::Identifier) && expression.callee.callee.name == "attribute_arg"
            evaluate_attribute_arg_call(expression.arguments, env:)
          else
            callee_name = expression.callee.callee.is_a?(AST::Identifier) ? expression.callee.callee.name : nil
            if callee_name
              func = @ctx.functions[callee_name]
              if func&.ast&.respond_to?(:const) && func.ast.const
                evaluate_const_function_body_lower(func, expression.arguments)
              else
                evaluate_type_returning_call(expression, env:)
              end
            else
              evaluate_type_returning_call(expression, env:)
            end
          end
        end
      end

      def evaluate_type_returning_call(expression, env:)
        callee_name, type_args = extract_type_callee_info(expression)
        return nil unless callee_name

        CompileTime::Reflection.core_evaluate_type_returning(
          callee_name, type_args,
          evaluate_value: ->(v) { compile_time_const_value(v, env:) },
          resolve_type_ref: ->(tr) { resolve_type_ref(tr) },
          pointer_to: ->(t) { pointer_to(t) },
          const_pointer_to: ->(t) { const_pointer_to(t) },
          top_level_functions: ->(name) { nil },
          evaluate_type_returning_function_body: nil,
        )
      end

      def extract_type_callee_info(expression)
        if expression.is_a?(AST::Call) && expression.callee.is_a?(AST::Identifier)
          [expression.callee.name, nil]
        elsif expression.is_a?(AST::Specialization)
          if expression.callee.is_a?(AST::Identifier)
            [expression.callee.name, expression.arguments]
          elsif expression.callee.is_a?(AST::Specialization) && expression.callee.callee.is_a?(AST::Identifier)
            [expression.callee.callee.name, expression.callee.arguments]
          end
        end
      end

      def evaluate_field_of_call(arguments, env:)
        return nil unless reflection_positional_arguments?(arguments, 2)

        struct_handle = resolve_struct_handle_argument(arguments.first.value, env:)
        return nil unless struct_handle

        field_name = reflection_identifier_name(arguments[1].value)
        return nil unless field_name

        CompileTime::Reflection.core_field_handle(struct_handle, field_name)
      end

      def evaluate_fields_of_call(arguments, env:)
        return nil unless reflection_positional_arguments?(arguments, 1)

        struct_handle = resolve_struct_handle_argument(arguments.first.value, env:)
        return nil unless struct_handle

        CompileTime::Reflection.core_field_handles(struct_handle)
      end

      def evaluate_members_of_call(arguments, env:)
        return nil unless reflection_positional_arguments?(arguments, 1)

        type = resolve_type_expression(arguments.first.value)
        return nil unless type

        return nil unless type.is_a?(Types::Enum) || type.is_a?(Types::Flags)

        CompileTime::Reflection.core_member_handles(type)
      end

      def evaluate_attributes_of_call(arguments, env:)
        return nil unless reflection_positional_arguments?(arguments, 1) || reflection_positional_arguments?(arguments, 2)

        target = evaluate_reflection_target_argument(arguments.first.value, env:)
        return nil unless target

        if arguments.length == 2
          attribute_binding = resolve_attribute_name_argument(arguments[1].value)
          application = find_attribute_application(target, attribute_binding)
          return [] unless application

          [Types::AttributeHandle.new(
            attribute_binding.name,
            attribute_binding.module_name,
            target,
            attribute_binding.params,
            application.argument_values,
          )]
        else
          resolved_attribute_applications_for_target(target).map do |application|
            Types::AttributeHandle.new(
              application.binding.name,
              application.binding.module_name,
              target,
              application.binding.params,
              application.argument_values,
            )
          end
        end
      end

      def evaluate_callable_of_call(arguments)
        return nil unless reflection_positional_arguments?(arguments, 1)

        resolve_callable_handle_argument(arguments.first.value)
      end

      def evaluate_has_attribute_call(arguments, env:)
        return nil unless reflection_positional_arguments?(arguments, 2)

        target = evaluate_reflection_target_argument(arguments.first.value, env:)
        binding = resolve_attribute_name_argument(arguments[1].value)
        return nil unless attribute_binding_supports_target?(binding, target)

        !find_attribute_application(target, binding).nil?
      end

      def evaluate_attribute_of_call(arguments, env:)
        return nil unless reflection_positional_arguments?(arguments, 2)

        target = evaluate_reflection_target_argument(arguments.first.value, env:)
        binding = resolve_attribute_name_argument(arguments[1].value)
        return nil unless attribute_binding_supports_target?(binding, target)

        application = find_attribute_application(target, binding)
        return nil unless application

        Types::AttributeHandle.new(
          binding.name,
          binding.module_name,
          target,
          binding.params,
          application.argument_values,
        )
      end

      def evaluate_attribute_arg_call(arguments, env:)
        return nil unless reflection_positional_arguments?(arguments, 2)

        attribute_handle = compile_time_const_value(arguments.first.value, env:)
        return nil unless attribute_handle.is_a?(Types::AttributeHandle)

        param_name = reflection_identifier_name(arguments[1].value)
        return nil unless param_name && attribute_handle.argument_values

        attribute_handle.argument_values[param_name]
      end

      def evaluate_const_function_body_lower(func, arguments)
        return nil unless func.ast.params.length == arguments.length

        initial_vars = {}
        func.ast.params.each_with_index do |param, idx|
          arg_expr = arguments[idx].value
          arg_value = compile_time_const_value(arg_expr, env: empty_env)
          return nil unless arg_value

          initial_vars[param.name] = arg_value
        end

        evaluator = ConstFnLowerEvaluator.new(self)
        ctx = CompileTime::BlockContext.new(evaluator, initial_variables: initial_vars)
        ctx.evaluate_block(func.ast.body, scopes: nil)
      rescue CompileTime::ReturnValue => e
        e.value
      end

      class ConstFnLowerEvaluator
        def initialize(lowerer)
          @lowerer = lowerer
        end

        def evaluate_compile_time_const_value(expression, scopes: nil)
          @lowerer.send(:compile_time_const_value, expression, env: @lowerer.send(:empty_env))
        end

        def top_level_function(name)
          @lowerer.instance_variable_get(:@ctx.functions)&.[](name)
        end

        def raise_sema_error(message)
          raise CompileTime::Error, message
        end
      end

      def evaluate_reflection_target_argument(expression, env:)
        struct_handle = resolve_struct_handle_argument(expression, env:)
        return struct_handle if struct_handle

        value = compile_time_const_value(expression, env:)
        return value if value.is_a?(Types::FieldHandle) || value.is_a?(Types::CallableHandle)

        nil
      end

      def reflection_positional_arguments?(arguments, expected_length)
        arguments.length == expected_length && arguments.none?(&:name)
      end

      def resolve_struct_handle_argument(expression, env:)
        type = reflection_type_from_expression(expression, env:)
        return nil unless type

        struct_handle_for_type(type)
      end

      def reflection_type_from_expression(expression, env:)
        case expression
        when AST::Identifier
          return nil if env && lookup_value(expression.name, env)

          current_type_params[expression.name] || @ctx.types[expression.name]
        when AST::MemberAccess
          return nil unless expression.receiver.is_a?(AST::Identifier)

          if @ctx.imports.key?(expression.receiver.name)
            imported_module = @ctx.imports[expression.receiver.name]
            return nil if imported_module.private_type?(expression.member)
            return imported_module.types[expression.member]
          end

          parent_type = @ctx.types[expression.receiver.name]
          return parent_type.nested_types[expression.member] if parent_type.respond_to?(:nested_types) && parent_type.nested_types.key?(expression.member)

          nil
        else
          nil
        end
      end

      def struct_handle_for_type(type)
        base_type = type.is_a?(Types::StructInstance) ? type.definition : type
        return nil unless base_type.is_a?(Types::Struct) || base_type.is_a?(Types::GenericStructDefinition)
        return nil unless base_type.respond_to?(:module_name)

        analysis = analysis_for_module(base_type.module_name)
        declaration = find_struct_decl_by_name(analysis.ast.declarations, base_type.name)
        return nil unless declaration

        Types::StructHandle.new(base_type, declaration)
      end

      def find_struct_decl_by_name(declarations, name)
        declarations.each do |decl|
          next unless decl.is_a?(AST::StructDecl)
          return decl if decl.name == name
          if decl.nested_types&.any?
            found = find_struct_decl_by_name(decl.nested_types, name)
            return found if found
          end
        end
        nil
      end

      def resolve_callable_handle_argument(expression)
        case expression
        when AST::Identifier
          binding = @ctx.functions[expression.name]
          return nil unless binding&.ast

          Types::CallableHandle.new(expression.name, binding.ast)
        when AST::MemberAccess
          return nil unless expression.receiver.is_a?(AST::Identifier)

          imported_module = @ctx.imports[expression.receiver.name]
          return nil unless imported_module
          return nil if imported_module.private_function?(expression.member)

          binding = imported_module.functions[expression.member]
          return nil unless binding&.ast

          Types::CallableHandle.new("#{expression.receiver.name}.#{expression.member}", binding.ast)
        else
          nil
        end
      end

      def resolve_attribute_name_argument(expression)
        case expression
        when AST::Identifier
          @ctx.attributes[expression.name] || builtin_attribute_binding(expression.name)
        when AST::MemberAccess
          return nil unless expression.receiver.is_a?(AST::Identifier)

          imported_module = @ctx.imports[expression.receiver.name]
          return nil unless imported_module
          return nil if imported_module.private_attribute?(expression.member)

          imported_module.attributes[expression.member]
        else
          nil
        end
      end

      def reflection_identifier_name(expression)
        expression.is_a?(AST::Identifier) ? expression.name : nil
      end

      def attribute_binding_supports_target?(binding, target)
        binding && target && binding.targets.include?(attribute_target_kind(target))
      end

      def attribute_target_kind(target)
        case target
        when Types::StructHandle then :struct
        when Types::FieldHandle then :field
        when Types::CallableHandle then :callable
        end
      end

      def resolved_attribute_applications_for_target(target)
        target_id = case target
        when Types::StructHandle then target.declaration.object_id
        when Types::FieldHandle then target.field_declaration.object_id
        when Types::CallableHandle then target.declaration.object_id
        end
        return [] unless target_id

        applications = @ctx.attribute_applications[target_id]
        return applications if applications

        @ctx.imports.each_value do |imported_module|
          applications = imported_module.attribute_applications[target_id]
          return applications if applications
        end

        []
      end

      def find_attribute_application(target, binding)
        resolved_attribute_applications_for_target(target).find do |application|
          same_attribute_binding?(application.binding, binding)
        end
      end

      def resolve_attribute_binding_for_name(name)
        case name.parts.length
        when 1
          @ctx.attributes[name.parts.first] || builtin_attribute_binding(name.parts.first)
        when 2
          imported_module = @ctx.imports[name.parts.first]
          return nil unless imported_module
          return nil if imported_module.private_attribute?(name.parts.last)

          imported_module.attributes[name.parts.last]
        else
          nil
        end
      end

      def same_attribute_binding?(left, right)
        left.name == right.name && left.module_name == right.module_name
      end

      def builtin_attribute_binding(name)
        MilkTea.builtin_attribute_binding(name, @ctx.types)
      end

      def attribute_argument_values(binding, application, env:)
        positional_index = 0

        application.arguments.each_with_object({}) do |argument, values|
          param_name = if argument.name
            argument.name
          else
            parameter = binding.params[positional_index]
            positional_index += 1
            parameter&.name
          end
          next unless param_name

          values[param_name] = compile_time_const_value(argument.value, env:)
        end
      end

      def specialize_function_binding(binding, arguments, env, receiver_type: nil)
        return binding if binding.type_params.empty?
        raise LoweringError, "generic function #{binding.name} must be called" unless arguments

        type_arguments = infer_function_type_arguments(binding, arguments, env, receiver_type:)
        instantiate_function_binding(binding, type_arguments)
      end

      def instantiate_function_binding_with_receiver(binding, explicit_type_arguments, receiver_type: nil)
        if binding.type_params.empty?
          raise LoweringError, "function #{binding.name} is not generic and cannot be specialized"
        end

        receiver_substitutions = infer_receiver_type_substitutions(binding, receiver_type)
        remaining_type_params = binding.type_params.reject { |name| receiver_substitutions.key?(name) }
        unless remaining_type_params.length == explicit_type_arguments.length
          raise LoweringError, "function #{binding.name} expects #{remaining_type_params.length} type arguments, got #{explicit_type_arguments.length}"
        end

        substitutions = receiver_substitutions.dup
        remaining_type_params.zip(explicit_type_arguments).each do |name, type_argument|
          raise LoweringError, "generic function #{binding.name} cannot be instantiated with ref types" if contains_ref_type?(type_argument)

          substitutions[name] = type_argument
        end

        type_arguments = binding.type_params.map do |name|
          inferred = substitutions[name]
          raise LoweringError, "cannot infer type argument #{name} for function #{binding.name}" unless inferred

          inferred
        end

        instantiate_function_binding(binding, type_arguments)
      end

      def instantiate_function_binding(binding, type_arguments)
        if binding.type_params.empty?
          raise LoweringError, "function #{binding.name} is not generic and cannot be specialized"
        end

        unless binding.type_params.length == type_arguments.length
          raise LoweringError, "function #{binding.name} expects #{binding.type_params.length} type arguments, got #{type_arguments.length}"
        end

        if type_arguments.any? { |type_argument| contains_ref_type?(type_argument) }
          raise LoweringError, "generic function #{binding.name} cannot be instantiated with ref types"
        end

        key = type_arguments.freeze
        return binding.instances.fetch(key) if binding.instances.key?(key)

        substitutions = binding.type_params.zip(type_arguments).to_h
        validate_function_type_param_constraints!(binding, substitutions)
        instance = FunctionBinding.new(
          name: binding.name,
          type: substitute_type(binding.type, substitutions),
          body_params: binding.body_params.map { |param| substitute_value_binding(param, substitutions) },
          body_return_type: substitute_type(binding.body_return_type, substitutions),
          ast: binding.ast,
          external: binding.external,
          async: binding.async,
          type_params: [].freeze,
          type_param_constraints: {}.freeze,
          instances: {},
          type_arguments: key,
          owner: binding.owner,
          specialization_owner: nil,
          type_substitutions: substitutions.freeze,
          declared_receiver_type: binding.declared_receiver_type ? substitute_type(binding.declared_receiver_type, substitutions) : nil,
        )
        binding.instances[key] = instance
      end

      def validate_function_type_param_constraints!(binding, substitutions)
        binding.type_param_constraints.each do |name, constraints|
          actual_type = substitutions[name]
          raise LoweringError, "cannot infer type argument #{name} for function #{binding.name}" unless actual_type

          constraints.interfaces.each do |interface|
            next if type_implements_interface?(actual_type, interface)

            raise LoweringError, "type #{actual_type} does not implement interface #{interface.name} for function #{binding.name}"
          end
        end
      end

      def interface_implementation_key(type)
        return type.definition if type.is_a?(Types::StructInstance)

        type
      end

      def type_implements_interface?(type, interface)
        key = interface_implementation_key(type)
        return true if @ctx.implemented_interfaces.fetch(key, []).include?(interface)

        @ctx.imports.each_value do |module_binding|
          return true if module_binding.implemented_interfaces.fetch(key, []).include?(interface)
        end

        false
      end

      def infer_function_type_arguments(binding, arguments, env, receiver_type: nil)
        expected_params = binding.type.params
        unless call_arity_matches?(binding.type, arguments.length)
          raise LoweringError, arity_error_message(binding.type, binding.name, arguments.length)
        end

        substitutions = infer_receiver_type_substitutions(binding, receiver_type)
        expected_params.each_with_index do |parameter, index|
          argument = arguments.fetch(index)
          candidate_type = substitute_type(parameter.type, substitutions)
          expected_argument_type = if callable_type?(candidate_type)
                                     candidate_type
                                   elsif contains_type_var?(candidate_type)
                                     nil
                                   else
                                     candidate_type
                                   end
          actual_type = infer_expression_type(argument.value, env:, expected_type: expected_argument_type)
          collect_type_substitutions(parameter.type, actual_type, substitutions, binding.name)
        end

        binding.type_params.map do |name|
          inferred = substitutions[name]
          raise LoweringError, "cannot infer type argument #{name} for function #{binding.name}" unless inferred

          inferred
        end
      end

      def method_dispatch_receiver_type(receiver_type)
        return receiver_type.definition if receiver_type.is_a?(Types::StructInstance)
        if receiver_type.is_a?(Types::Nullable)
          dispatch_base_type = method_dispatch_receiver_type(receiver_type.base)
          return receiver_type if dispatch_base_type == receiver_type.base

          return Types::Nullable.new(dispatch_base_type)
        end
        return receiver_type unless receiver_type.is_a?(Types::GenericInstance)

        dispatch_receiver_type = Types::GenericInstance.new(
          receiver_type.name,
          receiver_type.arguments.each_with_index.map do |argument, index|
            argument.is_a?(Types::LiteralTypeArg) ? argument : Types::TypeVar.new("__receiver_arg#{index}")
          end,
        )
        dispatch_receiver_type == receiver_type ? receiver_type : dispatch_receiver_type
      end

      def resolve_named_generic_type_for_analysis(analysis, parts)
        if parts.length == 1
          type = analysis.types[parts.first]
          return type if type.is_a?(Types::GenericStructDefinition) || type.is_a?(Types::GenericVariantDefinition)
        elsif parts.length == 2 && analysis.imports.key?(parts.first)
          type = analysis.imports.fetch(parts.first).types[parts.last]
          return type if type.is_a?(Types::GenericStructDefinition) || type.is_a?(Types::GenericVariantDefinition)
        end

        nil
      end

      def validate_methods_receiver_type_arguments!(type_ref, generic_type)
        names = type_ref.arguments.map do |argument|
          value = argument.value
          next unless value.is_a?(AST::TypeRef)
          next unless value.arguments.empty? && !value.nullable && value.name.parts.length == 1

          value.name.parts.first
        end

        expected_names = generic_type.type_params
        unless names == expected_names
          raise LoweringError, "extending target #{type_ref} must use the receiver type parameters directly"
        end

        expected_names
      end

      def methods_receiver_type_argument_names!(type_ref)
        names = type_ref.arguments.map do |argument|
          value = argument.value
          next unless value.is_a?(AST::TypeRef)
          next unless value.arguments.empty? && !value.nullable && value.name.parts.length == 1

          value.name.parts.first
        end

        raise LoweringError, "extending target #{type_ref} must use the receiver type parameters directly" if names.any?(&:nil?)

        names
      end

      def infer_receiver_type_substitutions(binding, receiver_type)
        declared_receiver_type = binding.declared_receiver_type
        return {} unless declared_receiver_type
        case declared_receiver_type
        when Types::Nullable
          unless receiver_type.is_a?(Types::Nullable)
            raise LoweringError, "cannot use method #{binding.name} with receiver #{receiver_type}"
          end

          infer_receiver_type_substitutions(
            binding.with(declared_receiver_type: declared_receiver_type.base),
            receiver_type.base,
          )
        when Types::StructInstance
          return {} unless declared_receiver_type.definition.is_a?(Types::GenericStructDefinition)

          unless receiver_type.is_a?(Types::StructInstance) && receiver_type.definition == declared_receiver_type.definition
            raise LoweringError, "cannot use method #{binding.name} with receiver #{receiver_type}"
          end

          declared_receiver_type.definition.type_params.zip(receiver_type.arguments).to_h
        when Types::GenericInstance
          unless receiver_type.is_a?(Types::GenericInstance) && receiver_type.name == declared_receiver_type.name && receiver_type.arguments.length == declared_receiver_type.arguments.length
            raise LoweringError, "cannot use method #{binding.name} with receiver #{receiver_type}"
          end

          declared_receiver_type.arguments.zip(receiver_type.arguments).each_with_object({}) do |(declared_argument, actual_argument), substitutions|
            if declared_argument.is_a?(Types::TypeVar)
              substitutions[declared_argument.name] = actual_argument
            elsif declared_argument != actual_argument
              raise LoweringError, "cannot use method #{binding.name} with receiver #{receiver_type}"
            end
          end
        else
          {}
        end
      end

      def collect_type_substitutions(pattern_type, actual_type, substitutions, function_name)
        case pattern_type
        when Types::TypeVar
          existing = substitutions[pattern_type.name]
          if existing && existing != actual_type
            raise LoweringError, "conflicting type argument #{pattern_type.name} for function #{function_name}: got #{existing} and #{actual_type}"
          end

          substitutions[pattern_type.name] ||= actual_type
        when Types::Nullable
          candidate = actual_type.is_a?(Types::Nullable) ? actual_type.base : actual_type
          collect_type_substitutions(pattern_type.base, candidate, substitutions, function_name)
        when Types::GenericInstance
          if ref_type?(pattern_type) && !ref_type?(actual_type)
            collect_type_substitutions(referenced_type(pattern_type), actual_type, substitutions, function_name)
            return
          end

          return unless actual_type.is_a?(Types::GenericInstance)
          return unless actual_type.name == pattern_type.name && actual_type.arguments.length == pattern_type.arguments.length

          pattern_type.arguments.zip(actual_type.arguments).each do |expected_argument, actual_argument|
            next if expected_argument.is_a?(Types::LiteralTypeArg)

            collect_type_substitutions(expected_argument, actual_argument, substitutions, function_name)
          end
        when Types::Span
          return unless actual_type.is_a?(Types::Span)

          collect_type_substitutions(pattern_type.element_type, actual_type.element_type, substitutions, function_name)
        when Types::Task
          return unless actual_type.is_a?(Types::Task)

          collect_type_substitutions(pattern_type.result_type, actual_type.result_type, substitutions, function_name)
        when Types::Proc
          if task_root_proc_type?(pattern_type) && actual_type.is_a?(Types::Task)
            collect_type_substitutions(pattern_type.return_type, actual_type, substitutions, function_name)
            return
          end

          actual_params = case actual_type
                          when Types::Proc
                            return unless actual_type.params.length == pattern_type.params.length

                            actual_type.params
                          when Types::Function
                            return if actual_type.receiver_type || actual_type.variadic
                            return unless actual_type.params.length == pattern_type.params.length
                            return unless actual_type.params.zip(pattern_type.params).all? { |actual_param, expected_param| actual_param.mutable == expected_param.mutable }

                            actual_type.params
                          else
                            return
                          end

          pattern_type.params.zip(actual_params).each do |expected_param, actual_param|
            collect_type_substitutions(expected_param.type, actual_param.type, substitutions, function_name)
          end
          collect_type_substitutions(pattern_type.return_type, actual_type.return_type, substitutions, function_name)
        when Types::StructInstance
          return unless actual_type.is_a?(Types::StructInstance)
          return unless actual_type.definition == pattern_type.definition && actual_type.arguments.length == pattern_type.arguments.length

          pattern_type.arguments.zip(actual_type.arguments).each do |expected_argument, actual_argument|
            collect_type_substitutions(expected_argument, actual_argument, substitutions, function_name)
          end
        when Types::VariantInstance
          return unless actual_type.is_a?(Types::VariantInstance)
          return unless actual_type.definition == pattern_type.definition && actual_type.arguments.length == pattern_type.arguments.length

          pattern_type.arguments.zip(actual_type.arguments).each do |expected_argument, actual_argument|
            collect_type_substitutions(expected_argument, actual_argument, substitutions, function_name)
          end
        when Types::Function
          return unless actual_type.is_a?(Types::Function)
          return unless actual_type.params.length == pattern_type.params.length

          pattern_type.params.zip(actual_type.params).each do |expected_param, actual_param|
            collect_type_substitutions(expected_param.type, actual_param.type, substitutions, function_name)
          end
          collect_type_substitutions(pattern_type.return_type, actual_type.return_type, substitutions, function_name)
        end
      end

      def substitute_value_binding(binding, substitutions)
        ValueBinding.new(
          id: binding.id,
          name: binding.name,
          storage_type: substitute_type(binding.storage_type, substitutions),
          flow_type: binding.flow_type ? substitute_type(binding.flow_type, substitutions) : nil,
          mutable: binding.mutable,
          kind: binding.kind,
          const_value: binding.const_value,
        )
      end

      def substitute_type(type, substitutions)
        case type
        when Types::TypeVar
          substitutions.fetch(type.name, type)
        when Types::Nullable
          Types::Nullable.new(substitute_type(type.base, substitutions))
        when Types::GenericInstance
          Types::GenericInstance.new(
            type.name,
            type.arguments.map { |argument| argument.is_a?(Types::LiteralTypeArg) ? argument : substitute_type(argument, substitutions) },
          )
        when Types::Span
          Types::Span.new(substitute_type(type.element_type, substitutions))
        when Types::Task
          Types::Task.new(substitute_type(type.result_type, substitutions))
        when Types::Proc
          Types::Proc.new(
            params: type.params.map do |param|
              Types::Parameter.new(
                param.name,
                substitute_type(param.type, substitutions),
                mutable: param.mutable,
                passing_mode: param.passing_mode,
                boundary_type: param.boundary_type ? substitute_type(param.boundary_type, substitutions) : nil,
              )
            end,
            return_type: substitute_type(type.return_type, substitutions),
          )
        when Types::StructInstance
          type.definition.instantiate(type.arguments.map { |argument| substitute_type(argument, substitutions) })
        when Types::Function
          Types::Function.new(
            type.name,
            params: type.params.map do |param|
              Types::Parameter.new(
                param.name,
                substitute_type(param.type, substitutions),
                mutable: param.mutable,
                passing_mode: param.passing_mode,
                boundary_type: param.boundary_type ? substitute_type(param.boundary_type, substitutions) : nil,
              )
            end,
            return_type: substitute_type(type.return_type, substitutions),
            receiver_type: type.receiver_type ? substitute_type(type.receiver_type, substitutions) : nil,
            receiver_editable: type.receiver_editable,
            variadic: type.variadic,
            external: type.external,
          )
        else
          type
        end
      end

      def analysis_for_module(module_name)
        @program.analyses_by_module_name.fetch(module_name)
      end

      def resolve_type_ref_for_analysis(type_ref, analysis, type_params: current_type_params)
        saved = @ctx.save
        @ctx.install(analysis)
        @ctx.module_prefix = module_c_prefix(@ctx.module_name)
        resolve_type_ref(type_ref, type_params:)
      ensure
        @ctx.restore(saved)
      end

      def current_type_params
        @ctx.current_type_substitutions || {}
      end

      def resolve_type_ref(type_ref, type_params: current_type_params)
        if type_ref.is_a?(AST::FunctionType)
          params = type_ref.params.map do |param|
            Types::Parameter.new(param.name, resolve_type_ref(param.type, type_params:))
          end
          return Types::Function.new(nil, params:, return_type: resolve_type_ref(type_ref.return_type, type_params:))
        end

        if type_ref.is_a?(AST::ProcType)
          params = type_ref.params.map do |param|
            Types::Parameter.new(param.name, resolve_type_ref(param.type, type_params:))
          end
          return Types::Proc.new(params:, return_type: resolve_type_ref(type_ref.return_type, type_params:))
        end

        if type_ref.is_a?(AST::DynType)
          interface = resolve_interface_ref(type_ref.interface)
          raise LoweringError, "generic interface requires type arguments" if interface.respond_to?(:instantiate)
          type_arguments = interface.respond_to?(:type_arguments) ? (interface.type_arguments || []) : []
          return Types::Dyn.new(interface, type_arguments)
        end

        if type_ref.is_a?(AST::TupleType)
          names = []
          element_types = []
          type_ref.element_types.each do |et|
            if et.is_a?(AST::Argument)
              names << et.name
              element_types << resolve_type_ref(et.value, type_params:)
            else
              names << nil
              element_types << resolve_type_ref(et, type_params:)
            end
          end
          has_named = names.any?
          return Types::Tuple.new(element_types, field_names: has_named ? names : nil)
        end

        parts = type_ref.name.parts
        base = if type_ref.arguments.any?
                 name = parts.join(".")
                 args = type_ref.arguments.map { |argument| resolve_type_argument(argument.value, type_params:) }
                 if name != "ref" && args.any? { |argument| contains_ref_type?(argument) && !stored_ref_supported_type?(argument) }
                   raise LoweringError, "ref types cannot be nested inside #{name}"
                 end
                 if name == "Task"
                   validate_generic_type!(name, args)
                   Types::Task.new(args.fetch(0))
                 elsif (generic_type = resolve_named_generic_type(parts))
                   generic_type.instantiate(args)
                 elsif name == "span"
                   Types::Span.new(args.fetch(0))
                 elsif name == "SoA"
                   validate_generic_type!(name, args)
                   Types::SoA.new(args.fetch(0), count: args.fetch(1).value)
                 else
                   validate_generic_type!(name, args)
                   args = [type_ref.lifetime] + args if name == "ref" && type_ref.lifetime
                   Types::GenericInstance.new(name, args)
                 end
               elsif parts.length == 1 && type_params.key?(parts.first)
                 type_params.fetch(parts.first)
               elsif parts.length == 1
                 type = @ctx.types[parts.first]
                 raise LoweringError, "unknown type #{parts.first}" unless type
                 raise LoweringError, "generic type #{parts.first} requires type arguments" if type.is_a?(Types::GenericStructDefinition) || type.is_a?(Types::GenericVariantDefinition)

                 type
         elsif parts.length >= 2
           type = resolve_nested_type_ref(parts)

           unless type
             if @ctx.imports.key?(parts.first)
               imported_module = @ctx.imports.fetch(parts.first)
               if imported_module.private_type?(parts.last)
                 raise LoweringError, "#{parts.first}.#{parts.last} is private to module #{imported_module.name}"
               end

               type = imported_module.types[parts.last]
               raise LoweringError, "unknown type #{type_ref.name}" unless type
               raise LoweringError, "generic type #{type_ref.name} requires type arguments" if type.is_a?(Types::GenericStructDefinition) || type.is_a?(Types::GenericVariantDefinition)
             else
               raise LoweringError, "unknown type #{type_ref.name}"
             end
           end

           type
         else
           raise LoweringError, "unknown type #{type_ref.name}"
         end

         raise LoweringError, "ref types are non-null and cannot be nullable" if type_ref.nullable && ref_type?(base)

         type_ref.nullable ? Types::Nullable.new(base) : base
      end

      def resolve_nested_type_ref(parts)
        current = @ctx.types[parts.first]
        return nil unless current.is_a?(Types::Struct) || current.is_a?(Types::GenericStructDefinition)

        parts[1..].each do |part|
          nested = current.respond_to?(:nested_types) ? current.nested_types[part] : nil
          return nil unless nested
          current = nested
        end
        current
      end

      def resolve_named_generic_type(parts)
        if parts.length == 1
          type = @ctx.types[parts.first]
          return type if type.is_a?(Types::GenericStructDefinition) || type.is_a?(Types::GenericVariantDefinition)
        elsif parts.length >= 2
          type = resolve_nested_type_ref(parts)
          return type if type.is_a?(Types::GenericStructDefinition) || type.is_a?(Types::GenericVariantDefinition)
          if @ctx.imports.key?(parts.first)
            type = @ctx.imports.fetch(parts.first).types[parts.last]
            return type if type.is_a?(Types::GenericStructDefinition) || type.is_a?(Types::GenericVariantDefinition)
          end
        end

        nil
      end

      def infer_field_handle_member_type(expression)
        case expression.member
        when "name" then @ctx.types["str"]
        when "type"
          handle = compile_time_const_value(expression.receiver, env: nil)
          return @error_type unless handle.is_a?(Types::FieldHandle)

          resolve_type_ref(handle.field_declaration.type)
        else
          @error_type
        end
      end

      def infer_member_handle_member_type(expression)
        case expression.member
        when "name" then @ctx.types["str"]
        when "value" then @ctx.types["int"]
        else @error_type
        end
      end

      def resolve_interface_ref(interface_ref)
        parts = interface_ref.parts
        interface = if parts.length == 1
                      @ctx.interfaces[parts.first]
                    elsif parts.length == 2 && @ctx.imports.key?(parts.first)
                      @ctx.imports.fetch(parts.first).interfaces[parts.last]
                    end
        raise LoweringError, "unknown interface #{interface_ref}" unless interface

        if interface_ref.type_arguments.any?
          raise LoweringError, "interface #{interface.name} is not generic" unless interface.respond_to?(:instantiate)
          type_args = interface_ref.type_arguments.map { |arg| resolve_type_ref(arg) }
          interface.instantiate(type_args)
        else
          interface
        end
      end
  end
end

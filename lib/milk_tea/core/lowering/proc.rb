# frozen_string_literal: true

module MilkTea
  module LowererProc
    private


      def build_proc_invoke_function(expression, proc_type, captures, env_struct_type, invoke_c_name)
        env = empty_env
        params = [IR::Param.new(name: "env", c_name: "__mt_proc_env", type: proc_env_pointer_type, pointer: false)]
        parameter_setup = []

        if env_struct_type
          env_pointer_type = pointer_to(env_struct_type)
          env_pointer_name = "__mt_proc_env_ptr"
          env[:scopes].last[env_pointer_name] = local_binding(type: env_pointer_type, c_name: env_pointer_name, mutable: false, pointer: false)
          parameter_setup << IR::LocalDecl.new(
            name: env_pointer_name,
            c_name: env_pointer_name,
            type: env_pointer_type,
            value: IR::Cast.new(
              target_type: env_pointer_type,
              expression: IR::Name.new(name: "__mt_proc_env", type: proc_env_pointer_type, pointer: false),
              type: env_pointer_type,
            ),
          )

          env_pointer = IR::Name.new(name: env_pointer_name, type: env_pointer_type, pointer: false)
          captures.each do |capture|
            capture_c_name = "__mt_capture_#{capture[:name]}"
            env[:scopes].last[capture[:name]] = local_binding(type: capture[:type], c_name: capture_c_name, mutable: false, pointer: false)
            parameter_setup << IR::LocalDecl.new(
              name: capture[:name],
              c_name: capture_c_name,
              type: capture[:type],
              value: IR::Member.new(receiver: env_pointer, member: capture[:field_name], type: capture[:type]),
            )
          end
        end

        expression.params.each_with_index do |param, index|
          type = proc_type.params.fetch(index).type
          c_name = c_local_name(param.name)
          if array_type?(type)
            input_c_name = "#{c_name}_input"
            params << IR::Param.new(name: param.name, c_name: input_c_name, type:, pointer: false)
            env[:scopes].last[param.name] = local_binding(type:, c_name:, mutable: false, pointer: false)
            parameter_setup << IR::LocalDecl.new(
              name: param.name,
              c_name:,
              type:,
              value: IR::Name.new(name: input_c_name, type:, pointer: false),
            )
          else
            env[:scopes].last[param.name] = local_binding(type:, c_name:, mutable: false, pointer: false)
            params << IR::Param.new(name: param.name, c_name:, type:, pointer: false)
          end
        end

        body = parameter_setup + lower_block(expression.body, env:, active_defers: [], return_type: proc_type.return_type, loop_flow: nil, allow_return: true)
        IR::Function.new(name: invoke_c_name, c_name: invoke_c_name, params:, return_type: proc_type.return_type, body:, entry_point: false)
      end

      def build_proc_release_function(release_c_name, env_struct_type)
        return build_proc_noop_release_function(release_c_name) unless env_struct_type

        env_pointer_type = pointer_to(env_struct_type)
        env_pointer = IR::Name.new(name: "__mt_proc_env_ptr", type: env_pointer_type, pointer: false)
        ref_count = IR::Member.new(receiver: env_pointer, member: "__mt_ref_count", type: @types.fetch("ptr_uint"))
        IR::Function.new(
          name: release_c_name,
          c_name: release_c_name,
          params: [IR::Param.new(name: "env", c_name: "__mt_proc_env", type: proc_env_pointer_type, pointer: false)],
          return_type: @types.fetch("void"),
          body: [
            IR::LocalDecl.new(
              name: "__mt_proc_env_ptr",
              c_name: "__mt_proc_env_ptr",
              type: env_pointer_type,
              value: IR::Cast.new(target_type: env_pointer_type, expression: IR::Name.new(name: "__mt_proc_env", type: proc_env_pointer_type, pointer: false), type: env_pointer_type),
            ),
            IR::Assignment.new(target: ref_count, operator: "-=", value: IR::IntegerLiteral.new(value: 1, type: @types.fetch("ptr_uint"))),
            IR::IfStmt.new(
              condition: IR::Binary.new(operator: "==", left: ref_count, right: IR::IntegerLiteral.new(value: 0, type: @types.fetch("ptr_uint")), type: @types.fetch("bool")),
              then_body: [
                IR::ExpressionStmt.new(
                  expression: IR::Call.new(
                    callee: "mt_async_free",
                    arguments: [IR::Name.new(name: "__mt_proc_env", type: proc_env_pointer_type, pointer: false)],
                    type: @types.fetch("void"),
                  ),
                ),
              ],
              else_body: nil,
            ),
            IR::ReturnStmt.new(value: nil),
          ],
          entry_point: false,
        )
      end

      def build_proc_retain_function(retain_c_name, env_struct_type)
        return build_proc_noop_retain_function(retain_c_name) unless env_struct_type

        env_pointer_type = pointer_to(env_struct_type)
        env_pointer = IR::Name.new(name: "__mt_proc_env_ptr", type: env_pointer_type, pointer: false)
        ref_count = IR::Member.new(receiver: env_pointer, member: "__mt_ref_count", type: @types.fetch("ptr_uint"))
        IR::Function.new(
          name: retain_c_name,
          c_name: retain_c_name,
          params: [IR::Param.new(name: "env", c_name: "__mt_proc_env", type: proc_env_pointer_type, pointer: false)],
          return_type: @types.fetch("void"),
          body: [
            IR::LocalDecl.new(
              name: "__mt_proc_env_ptr",
              c_name: "__mt_proc_env_ptr",
              type: env_pointer_type,
              value: IR::Cast.new(target_type: env_pointer_type, expression: IR::Name.new(name: "__mt_proc_env", type: proc_env_pointer_type, pointer: false), type: env_pointer_type),
            ),
            IR::Assignment.new(target: ref_count, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: @types.fetch("ptr_uint"))),
            IR::ReturnStmt.new(value: nil),
          ],
          entry_point: false,
        )
      end

      def proc_capture_entries(expression, env)
        local_scopes = [expression.params.each_with_object({}) { |param, names| names[param.name] = true }]
        captures = {}
        collect_proc_captures_from_statements(expression.body, env, local_scopes, captures)
        captures.values
      end

      def collect_proc_captures_from_statements(statements, env, local_scopes, captures)
        statements.each do |statement|
          collect_proc_captures_from_statement(statement, env, local_scopes, captures)
        end
      end

      def collect_proc_captures_from_statement(statement, env, local_scopes, captures)
        case statement
        when AST::LocalDecl
          collect_proc_captures_from_expression(statement.value, env, local_scopes, captures) if statement.value
          local_scopes.last[statement.name] = true
        when AST::Assignment
          collect_proc_captures_from_expression(statement.target, env, local_scopes, captures)
          collect_proc_captures_from_expression(statement.value, env, local_scopes, captures)
        when AST::IfStmt
          statement.branches.each do |branch|
            collect_proc_captures_from_expression(branch.condition, env, local_scopes, captures)
            collect_proc_captures_from_statements(branch.body, env, local_scopes + [{}], captures)
          end
          collect_proc_captures_from_statements(statement.else_body, env, local_scopes + [{}], captures) if statement.else_body
        when AST::MatchStmt
          collect_proc_captures_from_expression(statement.expression, env, local_scopes, captures)
          statement.arms.each do |arm|
            collect_proc_captures_from_expression(arm.pattern, env, local_scopes, captures)
            collect_proc_captures_from_statements(arm.body, env, local_scopes + [{}], captures)
          end
        when AST::UnsafeStmt
          collect_proc_captures_from_statements(statement.body, env, local_scopes + [{}], captures)
        when AST::StaticAssert
          collect_proc_captures_from_expression(statement.condition, env, local_scopes, captures)
          collect_proc_captures_from_expression(statement.message, env, local_scopes, captures)
        when AST::ForStmt
          statement.iterables.each { |iterable| collect_proc_captures_from_expression(iterable, env, local_scopes, captures) }
          collect_proc_captures_from_statements(statement.body, env, local_scopes + [statement.names.each_with_object({}) { |name, scope| scope[name] = true }], captures)
        when AST::WhileStmt
          collect_proc_captures_from_expression(statement.condition, env, local_scopes, captures)
          collect_proc_captures_from_statements(statement.body, env, local_scopes + [{}], captures)
        when AST::ReturnStmt
          collect_proc_captures_from_expression(statement.value, env, local_scopes, captures) if statement.value
        when AST::DeferStmt
          if statement.body
            collect_proc_captures_from_statements(statement.body, env, local_scopes + [{}], captures)
          else
            collect_proc_captures_from_expression(statement.expression, env, local_scopes, captures)
          end
        when AST::ExpressionStmt
          collect_proc_captures_from_expression(statement.expression, env, local_scopes, captures)
        when AST::BreakStmt, AST::ContinueStmt
          nil
        else
          raise LoweringError, "unsupported proc capture statement #{statement.class.name}"
        end
      end

      def collect_proc_captures_from_expression(expression, env, local_scopes, captures)
        return unless expression

        case expression
        when AST::Identifier
          return if local_scopes.any? { |scope| scope.key?(expression.name) }

          if (binding = proc_capture_binding(expression.name, env))
            captures[expression.name] ||= { name: expression.name, field_name: expression.name, type: binding[:type] }
          end
        when AST::MemberAccess
          collect_proc_captures_from_expression(expression.receiver, env, local_scopes, captures)
        when AST::IndexAccess
          collect_proc_captures_from_expression(expression.receiver, env, local_scopes, captures)
          collect_proc_captures_from_expression(expression.index, env, local_scopes, captures)
        when AST::Specialization
          collect_proc_captures_from_expression(expression.callee, env, local_scopes, captures)
          expression.arguments.each { |argument| collect_proc_captures_from_expression(argument.value, env, local_scopes, captures) }
        when AST::Call
          collect_proc_captures_from_expression(expression.callee, env, local_scopes, captures)
          expression.arguments.each { |argument| collect_proc_captures_from_expression(argument.value, env, local_scopes, captures) }
        when AST::UnaryOp
          collect_proc_captures_from_expression(expression.operand, env, local_scopes, captures)
        when AST::BinaryOp
          collect_proc_captures_from_expression(expression.left, env, local_scopes, captures)
          collect_proc_captures_from_expression(expression.right, env, local_scopes, captures)
        when AST::IfExpr
          collect_proc_captures_from_expression(expression.condition, env, local_scopes, captures)
          collect_proc_captures_from_expression(expression.then_expression, env, local_scopes, captures)
          collect_proc_captures_from_expression(expression.else_expression, env, local_scopes, captures)
        when AST::MatchExpr
          collect_proc_captures_from_expression(expression.expression, env, local_scopes, captures)
          expression.arms.each do |arm|
            collect_proc_captures_from_expression(arm.pattern, env, local_scopes, captures)
            arm_scopes = arm.binding_name ? local_scopes + [{ arm.binding_name => true }] : local_scopes
            collect_proc_captures_from_expression(arm.value, env, arm_scopes, captures)
          end
        when AST::UnsafeExpr
          collect_proc_captures_from_expression(expression.expression, env, local_scopes, captures)
        when AST::AwaitExpr
          collect_proc_captures_from_expression(expression.expression, env, local_scopes, captures)
        when AST::FormatString
          expression.parts.each do |part|
            collect_proc_captures_from_expression(part.expression, env, local_scopes, captures) if part.is_a?(AST::FormatExprPart)
          end
        when AST::ProcExpr, AST::TypeRef, AST::FunctionType, AST::ProcType,
             AST::SizeofExpr, AST::AlignofExpr, AST::OffsetofExpr,
             AST::IntegerLiteral, AST::FloatLiteral, AST::StringLiteral,
             AST::BooleanLiteral, AST::NullLiteral
          nil
        else
          raise LoweringError, "unsupported proc capture expression #{expression.class.name}"
        end
      end

      def proc_capture_binding(name, env)
        env[:scopes].reverse_each do |scope|
          return scope[name] if scope.key?(name)
        end

        nil
      end

      def lower_proc_release_expression(proc_expression, _proc_type)
        IR::Call.new(
          callee: IR::Member.new(receiver: proc_expression, member: "release", type: proc_release_function_type),
          arguments: [IR::Member.new(receiver: proc_expression, member: "env", type: proc_env_pointer_type)],
          type: @types.fetch("void"),
        )
      end

      def lower_proc_retain_expression(proc_expression, _proc_type)
        IR::Call.new(
          callee: IR::Member.new(receiver: proc_expression, member: "retain", type: proc_retain_function_type),
          arguments: [IR::Member.new(receiver: proc_expression, member: "env", type: proc_env_pointer_type)],
          type: @types.fetch("void"),
        )
      end

      def lower_proc_contained_release_statements(value_expression, type)
        lower_proc_contained_lifecycle_statements(value_expression, type, :release)
      end

      # Null-guarded release: safe when value may be zero-initialized (var locals, async frame fields).
      # Wraps each proc release in `if (proc.invoke) { proc.release(proc.env); }`.
      def lower_proc_contained_guarded_release_statements(value_expression, type)
        lower_proc_contained_lifecycle_statements(value_expression, type, :release, guarded: true)
      end

      # Alias used for async frame fields (always guarded).
      def lower_async_frame_proc_release_statements(value_expression, type)
        lower_proc_contained_lifecycle_statements(value_expression, type, :release, guarded: true)
      end

      def lower_proc_contained_retain_statements(value_expression, type)
        lower_proc_contained_lifecycle_statements(value_expression, type, :retain)
      end

      def lower_proc_contained_lifecycle_statements(value_expression, type, mode, guarded: false)
        return [] unless contains_proc_storage_type?(type)

        if proc_type?(type)
          if mode == :release && guarded
            invoke_member = IR::Member.new(receiver: value_expression, member: "invoke", type: proc_invoke_function_type(type))
            release_stmt = IR::ExpressionStmt.new(expression: lower_proc_release_expression(value_expression, type))
            return [IR::IfStmt.new(condition: invoke_member, then_body: [release_stmt], else_body: nil)]
          end
          expression = mode == :retain ? lower_proc_retain_expression(value_expression, type) : lower_proc_release_expression(value_expression, type)
          return [IR::ExpressionStmt.new(expression:)]
        end

        case type
        when Types::Struct, Types::StructInstance
          statements = []
          type.fields.each do |field_name, field_type|
            next unless contains_proc_storage_type?(field_type)

            member = IR::Member.new(receiver: value_expression, member: field_name, type: field_type)
            statements.concat(lower_proc_contained_lifecycle_statements(member, field_type, mode, guarded:))
          end
          statements
        when Types::Nullable
          []
        else
          raise LoweringError, "unsupported proc lifecycle container #{type.class.name}"
        end
      end

      # Retain only proc fields that did NOT originate from a fresh proc expression in `original_ast`.
      # Fresh proc expressions already carry refcount=1; retaining them would over-count.
      # For existing proc values (variables, member accesses, return values), we retain to share ownership.
      # When `original_ast` is a struct aggregate literal (AST::Call), fields are matched by name.
      def lower_proc_selective_retain_statements(ir_value, original_ast, type)
        return [] unless contains_proc_storage_type?(type)

        if proc_type?(type)
          # If the direct expression is a fresh proc, ownership transfers — no retain needed.
          return [] if expression_contains_proc_expr?(original_ast)

          return [IR::ExpressionStmt.new(expression: lower_proc_retain_expression(ir_value, type))]
        end

        case type
        when Types::Struct, Types::StructInstance
          statements = []
          type.fields.each do |field_name, field_type|
            next unless contains_proc_storage_type?(field_type)

            # Try to extract the AST sub-expression for this specific field when the source
            # is a struct aggregate literal (struct-name(field = value, ...)).
            ast_field_source = if original_ast.is_a?(AST::Call)
                                 original_ast.arguments.find { |arg| arg.name == field_name }&.value
                               end
            # Fall back to the whole RHS expression (conservative — treats as existing proc → retains).
            ast_field_source ||= original_ast

            member = IR::Member.new(receiver: ir_value, member: field_name, type: field_type)
            statements.concat(lower_proc_selective_retain_statements(member, ast_field_source, field_type))
          end
          statements
        when Types::Nullable
          []
        else
          []
        end
      end

      def expression_contains_proc_expr?(expression)
        return false unless expression

        case expression
        when AST::ProcExpr
          true
        when AST::MemberAccess
          expression_contains_proc_expr?(expression.receiver)
        when AST::IndexAccess
          expression_contains_proc_expr?(expression.receiver) || expression_contains_proc_expr?(expression.index)
        when AST::UnaryOp
          expression_contains_proc_expr?(expression.operand)
        when AST::BinaryOp
          expression_contains_proc_expr?(expression.left) || expression_contains_proc_expr?(expression.right)
        when AST::IfExpr
          expression_contains_proc_expr?(expression.condition) ||
            expression_contains_proc_expr?(expression.then_expression) ||
            expression_contains_proc_expr?(expression.else_expression)
        when AST::UnsafeExpr
          expression_contains_proc_expr?(expression.expression)
        when AST::AwaitExpr
          expression_contains_proc_expr?(expression.expression)
        when AST::Call
          expression_contains_proc_expr?(expression.callee) || expression.arguments.any? { |argument| expression_contains_proc_expr?(argument.value) }
        when AST::Specialization
          expression_contains_proc_expr?(expression.callee)
        else
          false
        end
      end
  end
end

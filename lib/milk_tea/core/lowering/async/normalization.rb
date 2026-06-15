# frozen_string_literal: true

module MilkTea
  module LowererAsync
    private

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
          return iterable_setups + [AST::ForStmt.new(bindings: statement.bindings, iterables: normalized_iterables, body:, line: statement.line, column: statement.column)]
        end

        iterable_setup, iterable = normalize_async_expression(statement.iterable, counter, env:)
        current_actual_scope(for_env[:scopes])[statement.name] = local_binding(type: loop_type, c_name: statement.name, mutable: false, pointer: false)
        body = normalize_async_statements(statement.body, counter, for_env, return_type:)
        iterable_setup + [AST::ForStmt.new(bindings: statement.bindings, iterables: [iterable], body:, line: statement.line, column: statement.column)]
      when AST::UnsafeStmt
        unsafe_env = duplicate_env(env)
        [AST::UnsafeStmt.new(body: normalize_async_statements(statement.body, counter, unsafe_env, return_type:), line: statement.line, column: statement.column, length: statement.length)]
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
      when AST::Call
        if read_call?(target)
          setup = []
          normalized_args = target.arguments.map do |arg|
            arg_setup, value = normalize_async_expression(arg.value, counter, env:)
            setup.concat(arg_setup)
            AST::Argument.new(name: arg.name, value:)
          end
          [setup, AST::Call.new(callee: target.callee, arguments: normalized_args)]
        else
          raise LoweringError, "unsupported assignment target #{target.class.name}"
        end
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
      when AST::PrefixCast
        setup, expr = normalize_async_expression(expression.expression, counter, env:)
        [setup, AST::PrefixCast.new(target_type: expression.target_type, expression: expr)]
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
  end
end

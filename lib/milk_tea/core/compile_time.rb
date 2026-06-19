# frozen_string_literal: true

require_relative "compiler/const_eval"

module MilkTea
  module CompileTime
    Layout = ::MilkTea::Layout

    class ReturnValue < StandardError
      attr_reader :value

      def initialize(value)
        @value = value
        super("return #{value.inspect}")
      end
    end

    class Error < StandardError; end

    class BlockContext
      attr_reader :checker

      def initialize(checker, initial_variables: nil)
        @checker = checker
        @variables = initial_variables || {}
      end

      def evaluate_block(statements, scopes: nil)
        result = nil

        statements.each do |statement|
          case statement
          when AST::LocalDecl
            result = evaluate_local_decl(statement, scopes:)
          when AST::ReturnStmt
            value = statement.value ? evaluate_expression(statement.value, scopes:) : nil
            raise ReturnValue.new(value)
          when AST::WhileStmt
            result = evaluate_while(statement, scopes:)
          when AST::ForStmt
            result = evaluate_for(statement, scopes:)
          when AST::Assignment
            result = evaluate_assignment(statement, scopes:)
          when AST::IfStmt
            result = evaluate_if(statement, scopes:)
          when AST::ExpressionStmt
            evaluate_expression(statement.expression, scopes:)
          when AST::PassStmt, AST::BreakStmt, AST::ContinueStmt
            # no-op at compile time
          when AST::EmitStmt
            # evaluated during lowering
            result = nil
          else
            result = nil
          end
        end

        result
      end

      private

      def evaluate_expression(expression, scopes:)
        case expression
        when AST::Identifier
          return @variables[expression.name] if @variables.key?(expression.name)
          @checker.send(:evaluate_compile_time_const_value, expression, scopes:)
        else
          CompileTime.evaluate(
            expression,
            resolve_identifier: ->(id_expr) {
              return @variables[id_expr.name] if @variables.key?(id_expr.name)
              @checker.send(:evaluate_compile_time_const_value, id_expr, scopes:)
            },
            resolve_member_access: ->(ma_expr) {
              @checker.send(:evaluate_compile_time_const_value, ma_expr, scopes:)
            },
            resolve_call: ->(call_expr) {
              if call_expr.callee.is_a?(AST::Identifier)
                func = @checker.send(:top_level_function, call_expr.callee.name)
                if func&.ast&.respond_to?(:const) && func.ast.const
                  begin
                    initial_vars = {}
                    func.ast.params.each_with_index do |param, idx|
                      return nil if idx >= call_expr.arguments.length

                      arg_expr = call_expr.arguments[idx].value
                      arg_value = case arg_expr
                                  when AST::Identifier
                                    @variables[arg_expr.name] || @checker.send(:evaluate_compile_time_const_value, arg_expr, scopes:)
                                  else
                                    CompileTime.evaluate(
                                      arg_expr,
                                      resolve_identifier: ->(id) { @variables[id.name] || @checker.send(:evaluate_compile_time_const_value, id, scopes:) },
                                      resolve_member_access: ->(ma) { @checker.send(:evaluate_compile_time_const_value, ma, scopes:) },
                                      resolve_type_ref: nil,
                                      resolve_call: nil,
                                    )
                                  end
                      return nil unless arg_value

                      initial_vars[param.name] = arg_value
                    end
                    ctx = CompileTime::BlockContext.new(@checker, initial_variables: initial_vars)
                    next ctx.evaluate_block(func.ast.body, scopes:)
                  rescue CompileTime::ReturnValue => e
                    next e.value
                  end
                end
              end
              @checker.send(:evaluate_compile_time_const_value, call_expr, scopes:)
            },
          )
        end
      end

      def evaluate_local_decl(decl, scopes:)
        return nil unless decl.value

        value = evaluate_expression(decl.value, scopes:)
        @variables[decl.name] = value
        value
      end

      def evaluate_assignment(assignment, scopes:)
        value = evaluate_expression(assignment.value, scopes:)
        case assignment.target
        when AST::Identifier
          @variables[assignment.target.name] = value
        end
        value
      end

      def evaluate_while(statement, scopes:)
        result = nil
        iterations = 0
        max_iterations = 10_000

        while iterations < max_iterations
          condition = evaluate_expression(statement.condition, scopes:)
          break unless condition
          break unless CompileTime.boolean_value?(condition)

          statement.body.each do |body_stmt|
            case body_stmt
            when AST::ReturnStmt
              value = body_stmt.value ? evaluate_expression(body_stmt.value, scopes:) : nil
              raise ReturnValue.new(value)
            when AST::Assignment
              evaluate_assignment(body_stmt, scopes:)
            when AST::ExpressionStmt
              evaluate_expression(body_stmt.expression, scopes:)
            end
          end
          iterations += 1
        end

        raise Error, "compile-time while loop exceeded iteration limit" if iterations >= max_iterations

        result
      end

      def evaluate_for(statement, scopes:)
        iterable = evaluate_expression(statement.iterable, scopes:)
        return nil unless iterable.is_a?(Array)

        result = nil
        loop_var_name = statement.binding.name

        iterable.each do |element|
          @variables[loop_var_name] = element
          statement.body.each do |body_stmt|
            case body_stmt
            when AST::ReturnStmt
              value = body_stmt.value ? evaluate_expression(body_stmt.value, scopes:) : nil
              raise ReturnValue.new(value)
            when AST::Assignment
              evaluate_assignment(body_stmt, scopes:)
            when AST::ExpressionStmt
              evaluate_expression(body_stmt.expression, scopes:)
            when AST::IfStmt
              result = evaluate_if(body_stmt, scopes:)
            when AST::WhileStmt
              result = evaluate_while(body_stmt, scopes:)
            end
          end
        end

        result
      end

      def evaluate_if(statement, scopes:)
        statement.branches.each do |branch|
          condition = evaluate_expression(branch.condition, scopes:)
          if condition && (condition == true || condition.is_a?(Numeric) && condition != 0)
            branch.body.each do |body_stmt|
              case body_stmt
              when AST::ReturnStmt
                value = body_stmt.value ? evaluate_expression(body_stmt.value, scopes:) : nil
                raise ReturnValue.new(value)
              when AST::Assignment
                evaluate_assignment(body_stmt, scopes:)
              when AST::ExpressionStmt
                evaluate_expression(body_stmt.expression, scopes:)
              end
            end
            return condition
          end
        end

        if statement.else_body
          statement.else_body.each do |body_stmt|
            case body_stmt
            when AST::ReturnStmt
              value = body_stmt.value ? evaluate_expression(body_stmt.value, scopes:) : nil
              raise ReturnValue.new(value)
            when AST::Assignment
              evaluate_assignment(body_stmt, scopes:)
            when AST::ExpressionStmt
              evaluate_expression(body_stmt.expression, scopes:)
            end
          end
        end

        nil
      end
    end

    class Evaluator < ConstEval::Evaluator
      private

      def resolve_layout_type(type_ref)
        super
      rescue
        return unless type_ref.respond_to?(:name) && type_ref.name.parts.length >= 1

        expression = ::MilkTea::AST.build_chain_from_parts(type_ref.name.parts)
        return unless expression

        value = evaluate(expression)
        return value if value.is_a?(Types::Struct) || value.is_a?(Types::Primitive) ||
                       value.is_a?(Types::Union) || value.is_a?(Types::Nullable) ||
                       value.is_a?(Types::StructInstance)

        nil
      end


    end

    module_function

    def evaluate(expression, resolve_identifier:, resolve_member_access:, resolve_type_ref: nil, resolve_call: nil)
      Evaluator.new(
        resolve_identifier:,
        resolve_member_access:,
        resolve_type_ref:,
        resolve_call:,
      ).evaluate(expression)
    end

    def equality_result(left, right)
      ConstEval.equality_result(left, right)
    end

    def boolean_value?(value)
      ConstEval.boolean_value?(value)
    end

    module Reflection
      def self.core_field_handle(struct_handle, field_name)
        field_decl = struct_handle.declaration.fields.find { |f| f.name == field_name }
        return nil unless field_decl

        Types::FieldHandle.new(struct_handle, field_name, field_decl)
      end

      def self.core_field_handles(struct_handle)
        struct_handle.declaration.fields.map { |f| Types::FieldHandle.new(struct_handle, f.name, f) }
      end

      def self.core_member_handles(type)
        type.members.map { |name, value| Types::MemberHandle.new(nil, name, value) }
      end

      def self.core_evaluate_type_returning(
        callee_name, type_args,
        evaluate_value:,
        resolve_type_ref:,
        pointer_to:,
        const_pointer_to:,
        top_level_functions:,
        evaluate_type_returning_function_body: nil
      )
        case callee_name
        when "ptr", "const_ptr", "span", "array", "str_buffer", "Task"
          evaluated_args = (type_args || []).map do |arg|
            value = arg.value
            if value.is_a?(AST::Identifier)
              evaluate_value.call(value)
            elsif value.is_a?(AST::TypeRef)
              resolve_type_ref.call(value)
            elsif value.is_a?(AST::IntegerLiteral)
              Types::LiteralTypeArg.new(value.value)
            end
          end
          return nil if evaluated_args.any?(&:nil?)

          case callee_name
          when "ptr" then pointer_to.call(evaluated_args.first)
          when "const_ptr" then const_pointer_to.call(evaluated_args.first)
          when "span" then Types::Span.new(evaluated_args.first)
          when "array" then Types::GenericInstance.new("array", evaluated_args)
          when "str_buffer" then Types::GenericInstance.new("str_buffer", evaluated_args)
          when "Task" then Types::Task.new(evaluated_args.first)
          end
        else
          func = top_level_functions.call(callee_name)
          return nil unless func
          return nil unless func.body_return_type == Types::BUILTIN_TYPE_META_TYPE

          if type_args && func.ast && evaluate_type_returning_function_body
            value = evaluate_type_returning_function_body.call(func, type_args)
            return value if value
          end

          Types::BUILTIN_TYPE_META_TYPE
        end
      end

      def self.core_evaluate_const_function_body(func, arguments, evaluate_arg:, block_evaluator:)
        return nil unless func.ast.params.length == arguments.length

        initial_vars = {}
        func.ast.params.each_with_index do |param, idx|
          arg_value = evaluate_arg.call(arguments[idx].value)
          return nil unless arg_value

          initial_vars[param.name] = arg_value
        end

        block_evaluator.call(func.ast.body, initial_vars)
      end
    end
  end
end

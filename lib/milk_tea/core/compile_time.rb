# frozen_string_literal: true

require_relative "types/layout"

module MilkTea
  module CompileTime
    Layout = ::MilkTea::Types::Layout

    # Carries the value of a `return` statement out of the block evaluator as
    # an ordinary value instead of an exception; callers unwrap it when present.
    ReturnOutcome = Data.define(:value)
    # Signals that a `break` was executed inside a compile-time loop body.
    BreakOutcome = Data.define(:value)
    # Signals that a `continue` was executed inside a compile-time loop body.
    ContinueOutcome = Data.define(:value)

    class Error < StandardError
      def code
        "compile_time/error"
      end

      def to_diagnostic(path: nil)
        Diagnostic.new(
          path: path,
          line: nil,
          column: nil,
          length: nil,
          code: code,
          message: message,
          severity: :error,
        )
      end
    end

    def self.evaluate(expression, resolve_identifier:, resolve_member_access:, resolve_type_ref: nil, resolve_call: nil)
      Evaluator.new(
        resolve_identifier:,
        resolve_member_access:,
        resolve_type_ref:,
        resolve_call:,
      ).evaluate(expression)
    end

    def self.equality_result(left, right)
      return left == right if left.is_a?(Numeric) && right.is_a?(Numeric)
      return left == right if left.is_a?(String) && right.is_a?(String)
      return left == right if boolean_value?(left) && boolean_value?(right)
      return left == right if left.is_a?(Types::Base) && right.is_a?(Types::Base)
      return struct_equality_result(left, right) if left.is_a?(Hash) && right.is_a?(Hash)
      return variant_equality_result(left, right) if left.is_a?(VariantValue) && right.is_a?(VariantValue)

      nil
    end

    # Const-time struct values are represented as {field_name => value} hashes;
    # compare them field by field, mirroring the runtime struct == semantics.
    def self.struct_equality_result(left, right)
      return nil unless left.is_a?(Hash) && right.is_a?(Hash)
      return nil unless left.keys.sort == right.keys.sort

      left.each do |name, value|
        field_result = equality_result(value, right[name])
        return nil if field_result.nil?
        return false if field_result == false
      end
      true
    end

    # Const-time variant values; fields mirror the runtime arm payload layout.
    VariantValue = Data.define(:arm, :fields)

    def self.variant_equality_result(left, right)
      return false unless left.arm == right.arm

      struct_equality_result(left.fields, right.fields)
    end

    def self.boolean_value?(value)
      value == true || value == false
    end

    class Evaluator
      def initialize(resolve_identifier:, resolve_member_access:, resolve_type_ref: nil, resolve_call: nil)
        @resolve_identifier = resolve_identifier
        @resolve_member_access = resolve_member_access
        @resolve_type_ref = resolve_type_ref
        @resolve_call = resolve_call
      end

      def evaluate(expression)
        case expression
        when AST::ErrorExpr
          nil
        when AST::ExpressionList
          expression.elements.filter_map { |element| evaluate(element) }
        when AST::RangeExpr
          start_val = evaluate(expression.start_expr)
          end_val = evaluate(expression.end_expr)
          start_val.is_a?(Integer) && end_val.is_a?(Integer) ? (start_val...end_val).to_a : nil
        when AST::IntegerLiteral, AST::FloatLiteral, AST::BooleanLiteral, AST::CharLiteral
          expression.value
        when AST::StringLiteral
          expression.value
        when AST::Identifier
          @resolve_identifier&.call(expression)
        when AST::MemberAccess
          @resolve_member_access&.call(expression)
        when AST::Call
          @resolve_call&.call(expression)
        when AST::Specialization
          @resolve_call&.call(expression)
        when AST::SizeofExpr
          type = resolve_layout_type(expression.type)
          type && Layout.size_of(type)
        when AST::AlignofExpr
          type = resolve_layout_type(expression.type)
          type && Layout.alignment_of(type)
        when AST::OffsetofExpr
          type = resolve_layout_type(expression.type)
          if type
            result = Layout.offset_of(type, expression.field)
            return result if result

            id_expr = AST::Identifier.new(name: expression.field)
            value = @resolve_identifier&.call(id_expr)
            if value.is_a?(Types::FieldHandle)
              return Layout.offset_of(type, value.field_name)
            end
          end
          nil
        when AST::UnaryOp
          evaluate_unary(expression)
        when AST::BinaryOp
          evaluate_binary(expression)
        when AST::IfExpr
          condition = evaluate(expression.condition)
          return unless CompileTime.boolean_value?(condition)

          evaluate(condition ? expression.then_expression : expression.else_expression)
        when AST::MatchExpr
          evaluate_match_expression(expression)
        when AST::IndexAccess
          evaluate_index_access(expression)
        when AST::PrefixCast
          evaluate_prefix_cast(expression)
        else
          nil
        end
      end

      def evaluate_prefix_cast(expression)
        operand = evaluate(expression.expression)
        operand = 1 if operand == true
        operand = 0 if operand == false
        return nil unless operand.is_a?(Numeric)

        target_type = begin
          @resolve_type_ref&.call(expression.target_type)
        rescue SemanticError
          nil
        end
        return nil unless target_type.is_a?(Types::Primitive)

        if target_type.boolean?
          return operand != 0
        end

        if target_type.integer?
          return nil unless target_type.integer_width

          value = operand.is_a?(Float) ? operand.truncate : operand
          return nil unless value.is_a?(Integer)

          return wrap_integer(value, target_type.integer_width, target_type.signed_integer?)
        end

        return nil unless target_type.float?

        value = operand.to_f
        target_type.name == "float" ? float32_round(value) : value
      end

      def wrap_integer(value, width, signed)
        mask = (1 << width) - 1
        wrapped = value & mask
        return wrapped unless signed

        half = 1 << (width - 1)
        wrapped >= half ? wrapped - (1 << width) : wrapped
      end

      def float32_round(value)
        [value].pack("f").unpack1("f")
      end

      def evaluate_index_access(expression)
        receiver = evaluate(expression.receiver)
        return nil if receiver.nil?

        if expression.index.is_a?(AST::RangeExpr)
          start_val = evaluate(expression.index.start_expr)
          end_val = evaluate(expression.index.end_expr)
          return nil unless start_val.is_a?(Integer) && end_val.is_a?(Integer)

          return receiver[start_val...end_val] if receiver.is_a?(Array) || receiver.is_a?(String)

          return nil
        end

        index = evaluate(expression.index)
        return nil unless index.is_a?(Integer)
        return receiver[index] if receiver.is_a?(Array)
        return receiver.getbyte(index) if receiver.is_a?(String)

        nil
      end

      def evaluate_match_expression(expression)
        scrutinee = evaluate(expression.expression)
        return nil unless scrutinee

        expression.arms.each do |arm|
          wildcard = arm.pattern.is_a?(AST::Identifier) && arm.pattern.name == "_"
          if wildcard || CompileTime.equality_result(scrutinee, evaluate(arm.pattern)) == true
            return evaluate(arm.value)
          end
        end

        nil
      end

      def resolve_layout_type(type_ref)
        result = begin
          @resolve_type_ref&.call(type_ref)
        rescue SemanticError
          nil
        end
        return result if result

        return unless type_ref.respond_to?(:name) && type_ref.name.parts.length >= 1

        expression = ::MilkTea::AST.build_chain_from_parts(type_ref.name.parts)
        return unless expression

        value = evaluate(expression)
        return value if value.is_a?(Types::Struct) || value.is_a?(Types::Primitive) ||
          value.is_a?(Types::Union) || value.is_a?(Types::Nullable) ||
          value.is_a?(Types::StructInstance)

        nil
      end

      def evaluate_unary(expression)
        operand = evaluate(expression.operand)

        case expression.operator
        when "+"
          operand.is_a?(Numeric) ? operand : nil
        when "-"
          operand.is_a?(Numeric) ? -operand : nil
        when "~"
          operand.is_a?(Integer) ? ~operand : nil
        when "not"
          CompileTime.boolean_value?(operand) ? !operand : nil
        end
      end

      def evaluate_binary(expression)
        left = evaluate(expression.left)

        case expression.operator
        when "and"
          return unless CompileTime.boolean_value?(left)
          return false if left == false

          right = evaluate(expression.right)
          return right if CompileTime.boolean_value?(right)

          return nil
        when "or"
          return unless CompileTime.boolean_value?(left)
          return true if left == true

          right = evaluate(expression.right)
          return right if CompileTime.boolean_value?(right)

          return nil
        end

        right = evaluate(expression.right)

        case expression.operator
        when ".."
          left.is_a?(Integer) && right.is_a?(Integer) ? (left...right).to_a : nil
        when "=="
          CompileTime.equality_result(left, right)
        when "!="
          result = CompileTime.equality_result(left, right)
          result.nil? ? nil : !result
        when "+"
          if left.is_a?(String) && right.is_a?(String)
            left + right
          elsif left.is_a?(Numeric) && right.is_a?(Numeric)
            left + right
          else
            nil
          end
        when "-"
          left.is_a?(Numeric) && right.is_a?(Numeric) ? left - right : nil
        when "*"
          left.is_a?(Numeric) && right.is_a?(Numeric) ? left * right : nil
        when "/"
          return unless left.is_a?(Numeric) && right.is_a?(Numeric)
          raise Error, "division by zero" if zero_numeric?(right)

          left / right
        when "%"
          return unless left.is_a?(Integer) && right.is_a?(Integer)
          raise Error, "modulo by zero" if right.zero?

          left % right
        when "<<"
          left.is_a?(Integer) && right.is_a?(Integer) ? left << right : nil
        when ">>"
          left.is_a?(Integer) && right.is_a?(Integer) ? left >> right : nil
        when "&"
          left.is_a?(Integer) && right.is_a?(Integer) ? left & right : nil
        when "|"
          left.is_a?(Integer) && right.is_a?(Integer) ? left | right : nil
        when "^"
          left.is_a?(Integer) && right.is_a?(Integer) ? left ^ right : nil
        when "<"
          left.is_a?(Numeric) && right.is_a?(Numeric) ? left < right : nil
        when "<="
          left.is_a?(Numeric) && right.is_a?(Numeric) ? left <= right : nil
        when ">"
          left.is_a?(Numeric) && right.is_a?(Numeric) ? left > right : nil
        when ">="
          left.is_a?(Numeric) && right.is_a?(Numeric) ? left >= right : nil
        end
      end

      def zero_numeric?(value)
        (value.is_a?(Integer) && value.zero?) || (value.is_a?(Float) && value.zero?)
      end
    end

    class BlockContext
      attr_reader :checker

      def initialize(checker, initial_variables: nil, variable_types: nil)
        @checker = checker
        @variables = initial_variables || {}
        @variable_types = variable_types || {}
      end

      def evaluate_block(statements, scopes: nil)
        result = nil

        statements.each do |statement|
          outcome = evaluate_statement(statement, scopes:)
          return outcome if control_outcome?(outcome)

          result = outcome
        end

        result
      end

      def control_outcome?(outcome)
        outcome.is_a?(ReturnOutcome) || outcome.is_a?(BreakOutcome) || outcome.is_a?(ContinueOutcome)
      end

      def evaluate_statement(statement, scopes:)
        case statement
        when AST::LocalDecl
          evaluate_local_decl(statement, scopes:)
        when AST::ReturnStmt
          value = statement.value ? evaluate_expression(statement.value, scopes:) : nil
          ReturnOutcome.new(value)
        when AST::WhileStmt
          evaluate_while(statement, scopes:)
        when AST::ForStmt
          evaluate_for(statement, scopes:)
        when AST::MatchStmt
          evaluate_match(statement, scopes:)
        when AST::Assignment
          evaluate_assignment(statement, scopes:)
        when AST::IfStmt
          evaluate_if(statement, scopes:)
        when AST::ExpressionStmt
          evaluate_expression(statement.expression, scopes:)
        when AST::PassStmt
          # no-op at compile time
          nil
        when AST::BreakStmt
          BreakOutcome.new(nil)
        when AST::ContinueStmt
          ContinueOutcome.new(nil)
        when AST::EmitStmt
          # emitted declarations are collected during lowering
          nil
        else
          nil
        end
      end

      def evaluate_expression(expression, scopes:)
        case expression
        when AST::Identifier
          return @variables[expression.name] if @variables.key?(expression.name)
          @checker.evaluate_compile_time_const_value(expression, scopes:)
        else
          CompileTime.evaluate(
            expression,
            resolve_identifier: ->(id_expr) {
              return @variables[id_expr.name] if @variables.key?(id_expr.name)
              @checker.evaluate_compile_time_const_value(id_expr, scopes:)
            },
            resolve_member_access: ->(ma_expr) {
              if ma_expr.receiver.is_a?(AST::Identifier) && @variables.key?(ma_expr.receiver.name)
                value = @variables[ma_expr.receiver.name]
                case value
                when Hash
                  return value[ma_expr.member] if value.key?(ma_expr.member)
                when Array
                  if ma_expr.member =~ /\A_(\d+)\z/
                    return value[Regexp.last_match(1).to_i]
                  end
                  return value.length if ma_expr.member == "len"
                when String
                  return value.length if ma_expr.member == "len"
                end
              end

              @checker.evaluate_compile_time_const_value(ma_expr, scopes:)
            },
            resolve_call: ->(call_expr) { resolve_compile_time_call(call_expr, scopes:) },
            resolve_type_ref: ->(type_ref) { @checker.resolve_type_ref(type_ref) },
          )
        end
      end

      def evaluate_local_decl(decl, scopes:)
        return nil unless decl.value

        value = evaluate_expression(decl.value, scopes:)
        return value unless value

        if decl.destructure_bindings&.any?
          return evaluate_destructure_local_decl(decl, value)
        end

        @variables[decl.name] = value
        @variable_types[decl.name] = compile_time_decl_type(decl.value, scopes:) unless @variable_types.key?(decl.name)
        value
      end

      def evaluate_destructure_local_decl(decl, value)
        if value.is_a?(Array)
          decl.destructure_bindings.each_with_index do |name, idx|
            next if name == "_"

            @variables[name] = value[idx]
          end
          return value
        end

        if value.is_a?(Hash)
          field_names = destructure_field_names(decl.destructure_type_name)
          decl.destructure_bindings.each_with_index do |name, idx|
            next if name == "_"

            field_name = field_names&.[](idx) || name
            @variables[name] = value[field_name]
          end
          return value
        end

        nil
      end

      def destructure_field_names(type_name)
        return nil unless type_name
        return nil unless @checker.respond_to?(:compile_time_struct_field_names)

        @checker.compile_time_struct_field_names(type_name)
      rescue StandardError
        nil
      end

      def compile_time_decl_type(expression, scopes:)
        return nil unless @checker.respond_to?(:compile_time_expression_type)

        @checker.compile_time_expression_type(expression, scopes:)
      rescue StandardError
        nil
      end

      def evaluate_assignment(assignment, scopes:)
        value = evaluate_expression(assignment.value, scopes:)
        return nil unless value

        case assignment.target
        when AST::Identifier
          return nil unless @variables.key?(assignment.target.name)

          if assignment.operator != "="
            current = @variables[assignment.target.name]
            value = apply_compile_time_binary(assignment.operator.chomp("="), current, value)
          end
          @variables[assignment.target.name] = value
        when AST::MemberAccess
          return nil unless evaluate_member_assignment(assignment, value, scopes:)
        when AST::IndexAccess
          return nil unless evaluate_index_assignment(assignment, value, scopes:)
        end
        value
      end

      def evaluate_member_assignment(assignment, value, scopes:)
        target = assignment.target
        return nil unless target.receiver.is_a?(AST::Identifier)
        return nil unless @variables.key?(target.receiver.name)

        receiver = @variables[target.receiver.name]
        return nil unless receiver.is_a?(Hash)

        if assignment.operator != "="
          current = receiver[target.member]
          value = apply_compile_time_binary(assignment.operator.chomp("="), current, value)
          return nil unless value
        end

        updated = receiver.dup
        updated[target.member] = value
        @variables[target.receiver.name] = updated
      end

      def evaluate_index_assignment(assignment, value, scopes:)
        target = assignment.target
        return nil unless target.receiver.is_a?(AST::Identifier)
        return nil unless @variables.key?(target.receiver.name)

        receiver = @variables[target.receiver.name]
        return nil unless receiver.is_a?(Array)

        index = evaluate_expression(target.index, scopes:)
        return nil unless index.is_a?(Integer)

        if assignment.operator != "="
          current = receiver[index]
          value = apply_compile_time_binary(assignment.operator.chomp("="), current, value)
          return nil unless value
        end

        updated = receiver.dup
        updated[index] = value
        @variables[target.receiver.name] = updated
      end

      def apply_compile_time_binary(operator, left, right)
        case operator
        when "+"
          if left.is_a?(String) && right.is_a?(String)
            left + right
          elsif left.is_a?(Numeric) && right.is_a?(Numeric)
            left + right
          else
            nil
          end
        when "-" then left.is_a?(Numeric) && right.is_a?(Numeric) ? left - right : nil
        when "*" then left.is_a?(Numeric) && right.is_a?(Numeric) ? left * right : nil
        when "/" then left.is_a?(Numeric) && right.is_a?(Numeric) && !zero_numeric?(right) ? left / right : nil
        when "%" then left.is_a?(Integer) && right.is_a?(Integer) && !right.zero? ? left % right : nil
        when "&" then left.is_a?(Integer) && right.is_a?(Integer) ? left & right : nil
        when "|" then left.is_a?(Integer) && right.is_a?(Integer) ? left | right : nil
        when "^" then left.is_a?(Integer) && right.is_a?(Integer) ? left ^ right : nil
        when "<<" then left.is_a?(Integer) && right.is_a?(Integer) ? left << right : nil
        when ">>" then left.is_a?(Integer) && right.is_a?(Integer) ? left >> right : nil
        end
      end

      def zero_numeric?(value)
        (value.is_a?(Integer) && value.zero?) || (value.is_a?(Float) && value.zero?)
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
            outcome = evaluate_statement(body_stmt, scopes:)
            case outcome
            when ReturnOutcome then return outcome
            when BreakOutcome then return result
            when ContinueOutcome then break
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
            outcome = evaluate_statement(body_stmt, scopes:)
            case outcome
            when ReturnOutcome then return outcome
            when BreakOutcome then return result
            when ContinueOutcome then break
            end
          end
        end

        result
      end

      def run_body(body, scopes:, fallback: nil)
        body.each do |body_stmt|
          outcome = evaluate_statement(body_stmt, scopes:)
          return outcome if control_outcome?(outcome)
        end
        fallback
      end

      def evaluate_if(statement, scopes:)
        statement.branches.each do |branch|
          condition = evaluate_expression(branch.condition, scopes:)
          next unless CompileTime.boolean_value?(condition) && condition

          return run_body(branch.body, scopes:, fallback: condition)
        end

        return run_body(statement.else_body, scopes:) if statement.else_body

        nil
      end

      def evaluate_match(statement, scopes:)
        scrutinee = evaluate_expression(statement.expression, scopes:)
        return nil unless scrutinee

        statement.arms.each do |arm|
          wildcard = arm.pattern.is_a?(AST::Identifier) && arm.pattern.name == "_"
          if wildcard || CompileTime.equality_result(scrutinee, evaluate_expression(arm.pattern, scopes:)) == true
            return run_body(arm.body, scopes:, fallback: scrutinee)
          end
        end

        nil
      end

      def resolve_compile_time_call(call_expr, scopes:)
        result = try_const_function_call(call_expr, scopes:)
        return result if result

        result = try_const_method_call(call_expr, scopes:)
        return result if result

        result = try_struct_constructor_call(call_expr, scopes:)
        return result if result

        result = try_array_constructor_call(call_expr, scopes:)
        return result if result

        @checker.evaluate_compile_time_const_value(call_expr, scopes:)
      end

      def try_const_method_call(call_expr, scopes:)
        return unless call_expr.callee.is_a?(AST::MemberAccess)
        return unless @checker.respond_to?(:const_method_binding_for_receiver)
        return unless @checker.respond_to?(:evaluate_const_method_body)

        receiver = call_expr.callee.receiver
        return unless receiver.is_a?(AST::Identifier)
        return unless @variables.key?(receiver.name)

        receiver_value = @variables[receiver.name]
        return nil if receiver_value.nil? || receiver_value.is_a?(Types::Base)

        receiver_type = @variable_types[receiver.name]
        return nil unless receiver_type

        binding = @checker.const_method_binding_for_receiver(receiver_type, call_expr.callee.member)
        return nil unless binding

        @checker.evaluate_const_method_body(binding, call_expr.arguments, scopes:, receiver_value:)
      end

      def try_const_function_call(call_expr, scopes:)
        return unless call_expr.callee.is_a?(AST::Identifier)

        func = @checker.top_level_function(call_expr.callee.name)
        return unless func&.ast&.respond_to?(:const) && func.ast.const

        begin
          initial_vars = {}
          func.ast.params.each_with_index do |param, idx|
            return nil if idx >= call_expr.arguments.length

            arg_expr = call_expr.arguments[idx].value
            arg_value = case arg_expr
            when AST::Identifier
              @variables[arg_expr.name] || @checker.evaluate_compile_time_const_value(arg_expr, scopes:)
            else
              CompileTime.evaluate(
                arg_expr,
                resolve_identifier: ->(id) { @variables[id.name] || @checker.evaluate_compile_time_const_value(id, scopes:) },
                resolve_member_access: ->(ma) { @checker.evaluate_compile_time_const_value(ma, scopes:) },
                resolve_type_ref: nil,
                resolve_call: ->(call_expr) { resolve_compile_time_call(call_expr, scopes:) },
              )
            end
            return nil unless arg_value

            initial_vars[param.name] = arg_value
          end
          ctx = BlockContext.new(@checker, initial_variables: initial_vars)
          result = ctx.evaluate_block(func.ast.body, scopes:)
          result.is_a?(ReturnOutcome) ? result.value : result
        end
      end

      def try_struct_constructor_call(call_expr, scopes:)
        types = if @checker.respond_to?(:types)
          @checker.types
        else
          @checker.instance_variable_get(:@ctx).types
        end
        callee_name = if call_expr.callee.is_a?(AST::Specialization) && call_expr.callee.callee.respond_to?(:name)
          call_expr.callee.callee.name
        elsif call_expr.callee.respond_to?(:name)
          call_expr.callee.name
        end
        return unless callee_name

        type = types[callee_name]
        return unless type.is_a?(Types::Struct)

        fields = {}
        call_expr.arguments.each do |argument|
          val = evaluate_expression(argument.value, scopes:)
          return nil unless val
          fields[argument.name] = val
        end
        fields
      end

      def try_array_constructor_call(call_expr, scopes:)
        return unless call_expr.callee.is_a?(AST::Specialization)
        return unless @checker.respond_to?(:resolve_type_expression)

        resolved = @checker.resolve_type_expression(call_expr.callee)
        return unless resolved && @checker.respond_to?(:array_type?) && @checker.array_type?(resolved)

        values = []
        call_expr.arguments.each do |argument|
          val = evaluate_expression(argument.value, scopes:)
          return nil unless val
          values << val
        end
        values
      end
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
        type.members.map { |name| Types::MemberHandle.new(nil, name, type.member_value(name)) }
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
          when "span" then Types::Registry.span(evaluated_args.first)
          when "array" then Types::Registry.generic_instance("array", evaluated_args)
          when "str_buffer" then Types::Registry.generic_instance("str_buffer", evaluated_args)
          when "Task" then Types::Registry.task(evaluated_args.first)
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
    end
  end
end

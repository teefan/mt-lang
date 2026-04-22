# frozen_string_literal: true

module MilkTea
  class LoweringError < StandardError; end

  class Lowering
    def self.lower(program)
      Lowerer.new(program).lower
    end

    class Lowerer
      def initialize(program)
        @program = program
        @analysis = program.root_analysis
        @module_name = @analysis.module_name
        @module_prefix = @module_name.tr(".", "_")
        @imports = @analysis.imports
        @types = @analysis.types
        @values = @analysis.values
        @functions = @analysis.functions
        @struct_types = {}
        @union_types = {}
        @method_definitions = {}
      end

      def lower
        if @analysis.module_kind == :extern_module
          raise LoweringError, "cannot emit C for extern module #{@module_name}"
        end

        collect_structs
        collect_methods

        includes = collect_includes
        constants = lower_constants
        structs = lower_structs
        unions = lower_unions
        enums = lower_enums
        functions = lower_functions

        IR::Program.new(
          module_name: @module_name,
          includes:,
          constants:,
          structs:,
          unions:,
          enums:,
          functions:,
        )
      end

      private

      def collect_structs
        @analysis.ast.declarations.each do |decl|
          case decl
          when AST::StructDecl
            @struct_types[decl.name] = @types.fetch(decl.name)
          when AST::UnionDecl
            @union_types[decl.name] = @types.fetch(decl.name)
          end
        end
      end

      def collect_methods
        @analysis.ast.declarations.grep(AST::ImplBlock).each do |impl|
          receiver_type = @types.fetch(impl.type_name.to_s)
          impl.methods.each do |method|
            @method_definitions[[receiver_type, method.name]] = method
          end
        end
      end

      def collect_includes
        headers = ["<stdbool.h>", "<stdint.h>"]

        @program.analyses_by_module_name.each_value do |analysis|
          next unless analysis.module_kind == :extern_module

          analysis.directives.grep(AST::IncludeDirective).each do |directive|
            headers << %("#{directive.value}")
          end
        end

        headers.uniq.map { |header| IR::Include.new(header:) }
      end

      def lower_constants
        @analysis.ast.declarations.grep(AST::ConstDecl).map do |decl|
          type = @values.fetch(decl.name).type
          value = lower_expression(decl.value, env: empty_env, expected_type: type)
          IR::Constant.new(name: decl.name, c_name: constant_c_name(decl.name), type:, value:)
        end
      end

      def lower_structs
        @analysis.ast.declarations.grep(AST::StructDecl).map do |decl|
          struct_type = @struct_types.fetch(decl.name)
          fields = decl.fields.map do |field|
            IR::Field.new(name: field.name, type: struct_type.field(field.name))
          end
          IR::StructDecl.new(name: decl.name, c_name: c_type_name(struct_type), fields:)
        end
      end

      def lower_unions
        @analysis.ast.declarations.grep(AST::UnionDecl).map do |decl|
          union_type = @union_types.fetch(decl.name)
          fields = decl.fields.map do |field|
            IR::Field.new(name: field.name, type: union_type.field(field.name))
          end
          IR::UnionDecl.new(name: decl.name, c_name: c_type_name(union_type), fields:)
        end
      end

      def lower_enums
        @analysis.ast.declarations.filter_map do |decl|
          case decl
          when AST::EnumDecl, AST::FlagsDecl
            enum_type = @types.fetch(decl.name)
            backing_type = enum_type.backing_type
            members = decl.members.map do |member|
              value = lower_expression(member.value, env: empty_env, expected_type: backing_type)
              IR::EnumMember.new(name: member.name, c_name: enum_member_c_name(enum_type, member.name), value:)
            end

            IR::EnumDecl.new(
              name: decl.name,
              c_name: c_type_name(enum_type),
              backing_type:,
              members:,
              flags: decl.is_a?(AST::FlagsDecl),
            )
          end
        end
      end

      def lower_functions
        lowered = []

        @analysis.ast.declarations.each do |decl|
          case decl
          when AST::FunctionDef
            lowered << lower_function_decl(decl)
          when AST::ImplBlock
            receiver_type = @types.fetch(decl.type_name.to_s)
            decl.methods.each do |method|
              lowered << lower_function_decl(method, receiver_type:)
            end
          end
        end

        lowered
      end

      def lower_function_decl(decl, receiver_type: nil)
        params = []
        env = empty_env

        decl.params.each_with_index do |param, index|
          pointer = receiver_type && index.zero? && param.name == "self" && param.mutable
          type = if receiver_type && index.zero? && param.name == "self"
                   receiver_type
                 else
                   resolve_type_ref(param.type)
                 end

          c_name = c_local_name(param.name)
          env[:scopes].last[param.name] = local_binding(type:, c_name:, mutable: param.mutable, pointer:)
          params << IR::Param.new(name: param.name, c_name:, type:, pointer:)
        end

        return_type = decl.return_type ? resolve_type_ref(decl.return_type) : @types.fetch("void")
        body = lower_block(decl.body, env:, active_defers: [], return_type:)

        IR::Function.new(
          name: decl.name,
          c_name: function_c_name(decl.name, receiver_type:),
          params:,
          return_type:,
          body:,
          entry_point: receiver_type.nil? && decl.name == "main",
        )
      end

      def lower_block(statements, env:, active_defers:, return_type:)
        local_env = duplicate_env(env)
        lowered = []
        local_defers = []

        statements.each do |statement|
          case statement
          when AST::DeferStmt
            local_defers << lower_expression(statement.expression, env: local_env)
          when AST::LocalDecl
            type = statement.type ? resolve_type_ref(statement.type) : infer_expression_type(statement.value, env: local_env)
            c_name = c_local_name(statement.name)
            value = lower_expression(statement.value, env: local_env, expected_type: type)
            local_env[:scopes].last[statement.name] = local_binding(type:, c_name:, mutable: statement.kind == :var, pointer: false)
            lowered << IR::LocalDecl.new(name: statement.name, c_name:, type:, value:)
          when AST::Assignment
            target = lower_assignment_target(statement.target, env: local_env)
            value = lower_expression(statement.value, env: local_env, expected_type: target.type)
            lowered << IR::Assignment.new(target:, operator: statement.operator, value:)
          when AST::IfStmt
            branches = statement.branches.reverse_each.reduce(statement.else_body ? lower_block(statement.else_body, env: local_env, active_defers: active_defers + local_defers, return_type:) : []) do |else_body, branch|
              condition = lower_expression(branch.condition, env: local_env, expected_type: @types.fetch("bool"))
              then_body = lower_block(branch.body, env: local_env, active_defers: active_defers + local_defers, return_type:)
              [IR::IfStmt.new(condition:, then_body:, else_body:)]
            end
            lowered.concat(branches)
          when AST::WhileStmt
            condition = lower_expression(statement.condition, env: local_env, expected_type: @types.fetch("bool"))
            body = lower_block(statement.body, env: local_env, active_defers: active_defers + local_defers, return_type:)
            lowered << IR::WhileStmt.new(condition:, body:)
          when AST::ReturnStmt
            cleanup = (local_defers + active_defers).reverse.map { |expression| IR::ExpressionStmt.new(expression:) }
            lowered.concat(cleanup)
            value = statement.value ? lower_expression(statement.value, env: local_env, expected_type: return_type) : nil
            lowered << IR::ReturnStmt.new(value:)
          when AST::ExpressionStmt
            lowered << IR::ExpressionStmt.new(expression: lower_expression(statement.expression, env: local_env))
          else
            raise LoweringError, "unsupported statement #{statement.class.name}"
          end
        end

        unless lowered.last.is_a?(IR::ReturnStmt)
          lowered.concat(local_defers.reverse.map { |expression| IR::ExpressionStmt.new(expression:) })
        end
        lowered
      end

      def lower_assignment_target(expression, env:)
        case expression
        when AST::Identifier
          binding = lookup_value(expression.name, env)
          IR::Name.new(name: binding[:c_name], type: binding[:type], pointer: binding[:pointer])
        when AST::MemberAccess
          receiver = lower_expression(expression.receiver, env:)
          type = infer_expression_type(expression, env:)
          IR::Member.new(receiver:, member: expression.member, type:)
        else
          raise LoweringError, "unsupported assignment target #{expression.class.name}"
        end
      end

      def lower_expression(expression, env:, expected_type: nil)
        type = infer_expression_type(expression, env:, expected_type:)

        case expression
        when AST::IntegerLiteral
          IR::IntegerLiteral.new(value: expression.value, type:)
        when AST::FloatLiteral
          IR::FloatLiteral.new(value: expression.value, type:)
        when AST::StringLiteral
          IR::StringLiteral.new(value: expression.value, type:, cstring: expression.cstring)
        when AST::BooleanLiteral
          IR::BooleanLiteral.new(value: expression.value, type:)
        when AST::NullLiteral
          IR::NullLiteral.new(type:)
        when AST::Identifier
          binding = lookup_value(expression.name, env)
          if binding
            IR::Name.new(name: binding[:c_name], type: binding[:type], pointer: binding[:pointer])
          elsif @functions.key?(expression.name)
            IR::Name.new(name: function_c_name(expression.name), type: type, pointer: false)
          else
            raise LoweringError, "unsupported identifier #{expression.name}"
          end
        when AST::MemberAccess
          lower_member_access(expression, env:, type:)
        when AST::UnaryOp
          IR::Unary.new(operator: expression.operator, operand: lower_expression(expression.operand, env:, expected_type: type), type:)
        when AST::BinaryOp
          left = lower_expression(expression.left, env:, expected_type: type)
          right = lower_expression(expression.right, env:, expected_type: left.type)
          IR::Binary.new(operator: expression.operator, left:, right:, type:)
        when AST::Call
          lower_call(expression, env:, type:)
        when AST::Specialization
          lower_specialization(expression, env:, type:)
        else
          raise LoweringError, "unsupported expression #{expression.class.name}"
        end
      end

      def lower_member_access(expression, env:, type:)
        if (type_expr = resolve_type_expression(expression.receiver))
          member_name = if local_named_type?(type_expr) && (type_expr.is_a?(Types::Enum) || type_expr.is_a?(Types::Flags))
                          enum_member_c_name(type_expr, expression.member)
                        else
                          expression.member
                        end
          return IR::Name.new(name: member_name, type:, pointer: false)
        end

        if expression.receiver.is_a?(AST::Identifier) && @imports.key?(expression.receiver.name)
          return IR::Name.new(name: expression.member, type:, pointer: false)
        end

        receiver = lower_expression(expression.receiver, env:)
        IR::Member.new(receiver:, member: expression.member, type:)
      end

      def lower_call(expression, env:, type:)
        kind, callee_name, receiver, callee_type = resolve_callee(expression.callee, env)

        case kind
        when :function
          arguments = expression.arguments.map.with_index do |argument, index|
            expected_type = callee_type.params[index].type
            lower_expression(argument.value, env:, expected_type: expected_type)
          end
          IR::Call.new(callee: callee_name, arguments:, type:)
        when :method
          receiver_arg = lower_expression(receiver, env:)
          receiver_arg = IR::AddressOf.new(expression: receiver_arg, type: receiver_arg.type) if callee_type.receiver_mutable
          arguments = [receiver_arg]
          expression.arguments.each_with_index do |argument, index|
            expected_type = callee_type.params[index].type
            arguments << lower_expression(argument.value, env:, expected_type: expected_type)
          end
          IR::Call.new(callee: callee_name, arguments:, type:)
        when :struct_literal
          fields = expression.arguments.map do |argument|
            field_type = type.field(argument.name)
            IR::AggregateField.new(name: argument.name, value: lower_expression(argument.value, env:, expected_type: field_type))
          end
          IR::AggregateLiteral.new(type:, fields:)
        when :cast
          argument = expression.arguments.fetch(0)
          lowered_arg = lower_expression(argument.value, env:)
          IR::Cast.new(target_type: type, expression: lowered_arg, type:)
        else
          raise LoweringError, "unsupported call kind #{kind}"
        end
      end

      def lower_specialization(expression, env:, type:)
        raise LoweringError, "specialization #{expression.callee.name} must be called" if expression.callee.is_a?(AST::Identifier)

        raise LoweringError, "unsupported specialization #{expression.class.name}"
      end

      def resolve_callee(callee, env)
        case callee
        when AST::Identifier
          if @functions.key?(callee.name)
            [ :function, function_c_name(callee.name), nil, function_type_for_name(callee.name) ]
          elsif (type = @types[callee.name]).is_a?(Types::Struct)
            [ :struct_literal, nil, nil, type ]
          else
            raise LoweringError, "unknown callee #{callee.name}"
          end
        when AST::MemberAccess
          if callee.receiver.is_a?(AST::Identifier) && @imports.key?(callee.receiver.name)
            imported_module = @imports.fetch(callee.receiver.name)
            if imported_module.functions.key?(callee.member)
              function_type = imported_module.functions.fetch(callee.member).type
              return [:function, callee.member, nil, function_type]
            end
            if imported_module.types[callee.member].is_a?(Types::Struct)
              return [:struct_literal, nil, nil, imported_module.types.fetch(callee.member)]
            end
          end

          receiver_type = infer_expression_type(callee.receiver, env:)
          method_ast = @method_definitions[[receiver_type, callee.member]]
          if method_ast
            function_type = function_type_for_method(receiver_type, method_ast.name)
            return [:method, function_c_name(method_ast.name, receiver_type:), callee.receiver, function_type]
          end

          raise LoweringError, "unknown callee #{callee.receiver}.#{callee.member}"
        when AST::Specialization
          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "cast"
            target_type = resolve_type_ref(callee.arguments.fetch(0).value)
            return [:cast, nil, nil, Types::Function.new("cast", params: [Types::Parameter.new("value", @types.fetch("i32"))], return_type: target_type)]
          end

          raise LoweringError, "unsupported specialization callee"
        else
          raise LoweringError, "unsupported callee #{callee.class.name}"
        end
      end

      def infer_expression_type(expression, env:, expected_type: nil)
        case expression
        when AST::IntegerLiteral
          if expected_type.is_a?(Types::Primitive) && expected_type.integer?
            expected_type
          else
            @types.fetch("i32")
          end
        when AST::FloatLiteral
          if expected_type.is_a?(Types::Primitive) && expected_type.float?
            expected_type
          else
            @types.fetch("f64")
          end
        when AST::StringLiteral
          @types.fetch(expression.cstring ? "cstr" : "str")
        when AST::BooleanLiteral
          @types.fetch("bool")
        when AST::NullLiteral
          expected_type || Types::Nullable.new(@types.fetch("void"))
        when AST::Identifier
          binding = lookup_value(expression.name, env)
          return binding[:type] if binding
          return function_type_for_name(expression.name) if @functions.key?(expression.name)

          raise LoweringError, "unknown identifier #{expression.name}"
        when AST::MemberAccess
          if (type_expr = resolve_type_expression(expression.receiver))
            member_type = resolve_type_member(type_expr, expression.member)
            return member_type if member_type
          end
          if expression.receiver.is_a?(AST::Identifier) && @imports.key?(expression.receiver.name)
            imported_module = @imports.fetch(expression.receiver.name)
            return imported_module.values.fetch(expression.member).type if imported_module.values.key?(expression.member)
          end
          receiver_type = infer_expression_type(expression.receiver, env:)
          return receiver_type.field(expression.member) if receiver_type.respond_to?(:field)

          raise LoweringError, "unknown member #{expression.member}"
        when AST::UnaryOp
          operand_type = infer_expression_type(expression.operand, env:, expected_type:)
          expression.operator == "not" ? @types.fetch("bool") : operand_type
        when AST::BinaryOp
          case expression.operator
          when "and", "or", "<", "<=", ">", ">=", "==", "!="
            @types.fetch("bool")
          else
            infer_expression_type(expression.left, env:, expected_type:)
          end
        when AST::Call
          kind, = resolve_callee(expression.callee, env)
          case kind
          when :function, :method
            _, _, _, function_type = resolve_callee(expression.callee, env)
            function_type.return_type
          when :struct_literal
            _, _, _, struct_type = resolve_callee(expression.callee, env)
            struct_type
          when :cast
            _, _, _, function_type = resolve_callee(expression.callee, env)
            function_type.return_type
          else
            raise LoweringError, "unsupported call kind #{kind}"
          end
        when AST::Specialization
          if expression.callee.is_a?(AST::Identifier) && expression.callee.name == "cast"
            resolve_type_ref(expression.arguments.fetch(0).value)
          else
            raise LoweringError, "unsupported specialization"
          end
        else
          raise LoweringError, "unsupported expression type #{expression.class.name}"
        end
      end

      def resolve_type_expression(expression)
        case expression
        when AST::Identifier
          @types[expression.name]
        when AST::MemberAccess
          return nil unless expression.receiver.is_a?(AST::Identifier)
          return nil unless @imports.key?(expression.receiver.name)

          @imports.fetch(expression.receiver.name).types[expression.member]
        end
      end

      def resolve_type_member(type, name)
        case type
        when Types::Enum, Types::Flags
          type.member(name)
        end
      end

      def function_type_for_name(name)
        @functions.fetch(name).type
      end

      def function_type_for_method(receiver_type, name)
        method_ast = @method_definitions.fetch([receiver_type, name])
        params = method_ast.params.drop(1).map do |param|
          Types::Parameter.new(param.name, resolve_type_ref(param.type), mutable: param.mutable)
        end
        Types::Function.new(name, params:, return_type: method_ast.return_type ? resolve_type_ref(method_ast.return_type) : @types.fetch("void"), receiver_type:, receiver_mutable: method_ast.params.first.mutable)
      end

      def resolve_type_ref(type_ref)
        if type_ref.is_a?(AST::FunctionType)
          params = type_ref.params.map do |param|
            Types::Parameter.new(param.name, resolve_type_ref(param.type), mutable: param.mutable)
          end
          return Types::Function.new(nil, params:, return_type: resolve_type_ref(type_ref.return_type))
        end

        parts = type_ref.name.parts
        base = if type_ref.arguments.any?
                 name = parts.join(".")
                 args = type_ref.arguments.map do |argument|
                   if argument.value.is_a?(AST::TypeRef)
                     resolve_type_ref(argument.value)
                   else
                     Types::LiteralTypeArg.new(argument.value.value)
                   end
                 end
                 Types::GenericInstance.new(name, args)
               elsif parts.length == 1
                 @types.fetch(parts.first)
               elsif parts.length == 2 && @imports.key?(parts.first)
                 @imports.fetch(parts.first).types.fetch(parts.last)
               else
                 raise LoweringError, "unknown type #{type_ref.name}"
               end

        type_ref.nullable ? Types::Nullable.new(base) : base
      end

      def lookup_value(name, env)
        env[:scopes].reverse_each do |scope|
          return scope[name] if scope.key?(name)
        end

        if @values.key?(name)
          { type: @values.fetch(name).type, c_name: constant_c_name(name), mutable: false, pointer: false }
        end
      end

      def local_binding(type:, c_name:, mutable:, pointer:)
        { type:, c_name:, mutable:, pointer: }
      end

      def empty_env
        { scopes: [{}], counter: 0 }
      end

      def duplicate_env(env)
        { scopes: env[:scopes].map(&:dup) + [{}], counter: env[:counter] }
      end

      def c_type_name(type)
        if type.module_name == @module_name || type.module_name.nil?
          "#{@module_prefix}_#{type.name}"
        else
          type.name
        end
      end

      def enum_member_c_name(type, member_name)
        "#{c_type_name(type)}_#{member_name}"
      end

      def local_named_type?(type)
        type.respond_to?(:module_name) && (type.module_name == @module_name || type.module_name.nil?)
      end

      def function_c_name(name, receiver_type: nil)
        return "main" if receiver_type.nil? && name == "main"
        return "#{c_type_name(receiver_type)}_#{name}" if receiver_type

        "#{@module_prefix}_#{name}"
      end

      def constant_c_name(name)
        "#{@module_prefix}_#{name}"
      end

      def c_local_name(name)
        name
      end
    end
  end
end

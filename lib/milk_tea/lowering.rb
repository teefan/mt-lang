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
        @analysis = nil
        @module_name = nil
        @module_prefix = nil
        @imports = {}
        @types = {}
        @values = {}
        @functions = {}
        @struct_types = {}
        @union_types = {}
        @method_definitions = build_method_definitions
      end

      def lower
        if @program.root_analysis.module_kind == :extern_module
          raise LoweringError, "cannot emit C for extern module #{@program.root_analysis.module_name}"
        end

        includes = collect_includes

        constants = []
        structs = []
        unions = []
        enums = []
        functions = []

        lowered_analyses.each do |analysis|
          next if analysis.module_kind == :extern_module

          prepare_analysis(analysis)
          collect_structs

          constants.concat(lower_constants)
          structs.concat(lower_structs)
          unions.concat(lower_unions)
          enums.concat(lower_enums)
          functions.concat(lower_functions)
        end

        IR::Program.new(
          module_name: @program.root_analysis.module_name,
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

      def collect_includes
        headers = ["<stdbool.h>", "<stdint.h>", "<string.h>"]

        @program.analyses_by_module_name.each_value do |analysis|
          next unless analysis.module_kind == :extern_module

          analysis.directives.grep(AST::IncludeDirective).each do |directive|
            headers << %("#{directive.value}")
          end
        end

        headers.uniq.map { |header| IR::Include.new(header:) }
      end

      def lowered_analyses
        @program.analyses_by_path.values
      end

      def prepare_analysis(analysis)
        @analysis = analysis
        @module_name = analysis.module_name
        @module_prefix = @module_name.tr(".", "_")
        @imports = analysis.imports
        @types = analysis.types
        @values = analysis.values
        @functions = analysis.functions
        @struct_types = {}
        @union_types = {}
      end

      def build_method_definitions
        @program.analyses_by_path.values.each_with_object({}) do |analysis, definitions|
          analysis.ast.declarations.grep(AST::ImplBlock).each do |impl|
            receiver_type = analysis.types.fetch(impl.type_name.to_s)
            impl.methods.each do |method|
              definitions[[receiver_type, method.name]] = [analysis, method]
            end
          end
        end
      end

      def lower_constants
        @analysis.ast.declarations.grep(AST::ConstDecl).map do |decl|
          type = @values.fetch(decl.name).type
          value = lower_expression(decl.value, env: empty_env, expected_type: type)
          IR::Constant.new(name: decl.name, c_name: constant_c_name(decl.name), type:, value:)
        end
      end

      def lower_structs
        @analysis.ast.declarations.grep(AST::StructDecl).filter_map do |decl|
          next unless decl.type_params.empty?

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
            binding = @functions.fetch(decl.name)
            if binding.type_params.any?
              binding.instances.values.sort_by { |instance| instance.type_arguments.map(&:to_s).join(",") }.each do |instance|
                lowered << lower_function_decl(instance)
              end
            else
              lowered << lower_function_decl(binding)
            end
          when AST::ImplBlock
            receiver_type = @types.fetch(decl.type_name.to_s)
            decl.methods.each do |method|
              lowered << lower_function_decl(@analysis.methods.fetch(receiver_type).fetch(method.name), receiver_type:)
            end
          end
        end

        lowered
      end

      def lower_function_decl(binding, receiver_type: nil)
        decl = binding.ast
        params = []
        env = empty_env
        parameter_setup = []

        binding.body_params.each_with_index do |param_binding, index|
          param = decl.params[index]
          pointer = receiver_type && index.zero? && param.name == "self" && param.mutable
          type = param_binding.type

          c_name = c_local_name(param_binding.name)
          if array_type?(type)
            input_c_name = "#{c_name}_input"
            params << IR::Param.new(name: param_binding.name, c_name: input_c_name, type:, pointer: false)
            env[:scopes].last[param_binding.name] = local_binding(type:, c_name:, mutable: param.mutable, pointer: false)
            parameter_setup << IR::LocalDecl.new(
              name: param_binding.name,
              c_name:,
              type:,
              value: IR::Name.new(name: input_c_name, type:, pointer: false),
            )
          else
            env[:scopes].last[param_binding.name] = local_binding(type:, c_name:, mutable: param.mutable, pointer:)
            params << IR::Param.new(name: param_binding.name, c_name:, type:, pointer:)
          end
        end

        return_type = binding.type.return_type
        body = lower_block(decl.body, env:, active_defers: [], return_type:)
        body = parameter_setup + body

        IR::Function.new(
          name: decl.name,
          c_name: function_binding_c_name(binding, module_name: @module_name, receiver_type:),
          params:,
          return_type:,
          body:,
          entry_point: receiver_type.nil? && decl.name == "main" && binding.type_arguments.empty?,
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
          when AST::UnsafeStmt
            body = lower_block(statement.body, env: local_env, active_defers: active_defers + local_defers, return_type:)
            lowered << IR::BlockStmt.new(body:)
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
        when AST::IndexAccess
          receiver = lower_expression(expression.receiver, env:)
          index = lower_expression(expression.index, env:, expected_type: @types.fetch("usize"))
          type = infer_expression_type(expression, env:)
          IR::Index.new(receiver:, index:, type:)
        when AST::UnaryOp
          if expression.operator == "*"
            type = infer_expression_type(expression, env:)
            operand = lower_expression(expression.operand, env:)
            return IR::Unary.new(operator: "*", operand:, type:)
          end

          raise LoweringError, "unsupported assignment target #{expression.class.name}"
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
            function_binding = @functions.fetch(expression.name)
            raise LoweringError, "generic function #{expression.name} cannot be used as a value" if function_binding.type_params.any?

            IR::Name.new(name: function_binding_c_name(function_binding, module_name: @module_name), type: type, pointer: false)
          else
            raise LoweringError, "unsupported identifier #{expression.name}"
          end
        when AST::MemberAccess
          lower_member_access(expression, env:, type:)
        when AST::IndexAccess
          receiver = lower_expression(expression.receiver, env:)
          index = lower_expression(expression.index, env:, expected_type: @types.fetch("usize"))
          IR::Index.new(receiver:, index:, type:)
        when AST::UnaryOp
          if expression.operator == "&"
            IR::AddressOf.new(expression: lower_expression(expression.operand, env:), type:)
          else
            IR::Unary.new(operator: expression.operator, operand: lower_expression(expression.operand, env:), type:)
          end
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
          imported_module = @imports.fetch(expression.receiver.name)
          return IR::Name.new(name: imported_value_c_name(imported_module, expression.member), type:, pointer: false)
        end

        receiver = lower_expression(expression.receiver, env:)
        IR::Member.new(receiver:, member: expression.member, type:)
      end

      def lower_call(expression, env:, type:)
        kind, callee_name, receiver, callee_type = resolve_callee(expression.callee, env, arguments: expression.arguments)

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
        when :array
          element_type = array_element_type(type)
          elements = expression.arguments.map do |argument|
            lower_expression(argument.value, env:, expected_type: element_type)
          end
          IR::ArrayLiteral.new(type:, elements:)
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

      def resolve_callee(callee, env, arguments: nil)
        case callee
        when AST::Identifier
          if @functions.key?(callee.name)
            binding = specialize_function_binding(@functions.fetch(callee.name), arguments, env)
            [ :function, function_binding_c_name(binding, module_name: @module_name), nil, binding.type ]
          elsif (type = @types[callee.name]).is_a?(Types::Struct)
            [ :struct_literal, nil, nil, type ]
          else
            raise LoweringError, "unknown callee #{callee.name}"
          end
        when AST::MemberAccess
          if callee.receiver.is_a?(AST::Identifier) && @imports.key?(callee.receiver.name)
            imported_module = @imports.fetch(callee.receiver.name)
            if imported_module.functions.key?(callee.member)
              binding = specialize_function_binding(imported_module.functions.fetch(callee.member), arguments, env)
              return [:function, function_binding_c_name(binding, module_name: imported_module.name), nil, binding.type] unless binding.external

              return [:function, binding.name, nil, binding.type]
            end
            if imported_module.types[callee.member].is_a?(Types::Struct)
              return [:struct_literal, nil, nil, imported_module.types.fetch(callee.member)]
            end
          end

          receiver_type = infer_expression_type(callee.receiver, env:)
          method_entry = @method_definitions[[receiver_type, callee.member]]
          if method_entry
            method_analysis, method_ast = method_entry
            function_type = function_type_for_method(receiver_type, method_ast.name, analysis: method_analysis)
            method_binding = method_analysis.methods.fetch(receiver_type).fetch(method_ast.name)
            return [:method, function_binding_c_name(method_binding, module_name: method_analysis.module_name, receiver_type:), callee.receiver, function_type]
          end

          raise LoweringError, "unknown callee #{callee.receiver}.#{callee.member}"
        when AST::Specialization
          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "cast"
            target_type = resolve_type_ref(callee.arguments.fetch(0).value)
            return [:cast, nil, nil, Types::Function.new("cast", params: [Types::Parameter.new("value", @types.fetch("i32"))], return_type: target_type)]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "array"
            array_type = resolve_type_ref(AST::TypeRef.new(name: AST::QualifiedName.new(parts: ["array"]), arguments: callee.arguments, nullable: false))
            return [:array, nil, nil, array_type]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "span"
            span_type = resolve_type_ref(AST::TypeRef.new(name: AST::QualifiedName.new(parts: ["span"]), arguments: callee.arguments, nullable: false))
            return [:struct_literal, nil, nil, span_type]
          end

          if (type_ref = type_ref_from_specialization(callee))
            specialized_type = resolve_type_ref(type_ref)
            return [:struct_literal, nil, nil, specialized_type] if specialized_type.is_a?(Types::Struct)
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
        when AST::IndexAccess
          receiver_type = infer_expression_type(expression.receiver, env:)
          index_type = infer_expression_type(expression.index, env:, expected_type: @types.fetch("usize"))
          infer_index_result_type(receiver_type, index_type)
        when AST::UnaryOp
          operand_type = infer_expression_type(expression.operand, env:, expected_type:)
          case expression.operator
          when "not"
            @types.fetch("bool")
          when "&"
            pointer_to(operand_type)
          when "*"
            pointee_type = pointee_type(operand_type)
            raise LoweringError, "operator * requires a pointer operand, got #{operand_type}" unless pointee_type

            pointee_type
          else
            operand_type
          end
        when AST::BinaryOp
          case expression.operator
          when "and", "or", "<", "<=", ">", ">=", "==", "!="
            @types.fetch("bool")
          else
            infer_expression_type(expression.left, env:, expected_type:)
          end
        when AST::Call
          kind, = resolve_callee(expression.callee, env, arguments: expression.arguments)
          case kind
          when :function, :method
            _, _, _, function_type = resolve_callee(expression.callee, env, arguments: expression.arguments)
            function_type.return_type
          when :struct_literal, :array
            _, _, _, struct_type = resolve_callee(expression.callee, env, arguments: expression.arguments)
            struct_type
          when :cast
            _, _, _, function_type = resolve_callee(expression.callee, env, arguments: expression.arguments)
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
        binding = @functions.fetch(name)
        raise LoweringError, "generic function #{name} cannot be used as a value" if binding.type_params.any?

        binding.type
      end

      def specialize_function_binding(binding, arguments, env)
        return binding if binding.type_params.empty?
        raise LoweringError, "generic function #{binding.name} must be called" unless arguments

        type_arguments = infer_function_type_arguments(binding, arguments, env)
        key = type_arguments.freeze
        return binding.instances.fetch(key) if binding.instances.key?(key)

        substitutions = binding.type_params.zip(type_arguments).to_h
        instance = Sema::FunctionBinding.new(
          name: binding.name,
          type: substitute_type(binding.type, substitutions),
          body_params: binding.body_params.map { |param| substitute_value_binding(param, substitutions) },
          ast: binding.ast,
          external: binding.external,
          type_params: [].freeze,
          instances: {},
          type_arguments: key,
          owner: binding.owner,
        )
        binding.instances[key] = instance
      end

      def infer_function_type_arguments(binding, arguments, env)
        expected_params = binding.type.params
        raise LoweringError, "function #{binding.name} expects #{expected_params.length} arguments, got #{arguments.length}" unless expected_params.length == arguments.length

        substitutions = {}
        arguments.zip(expected_params).each do |argument, parameter|
          actual_type = infer_expression_type(argument.value, env:)
          collect_type_substitutions(parameter.type, actual_type, substitutions, binding.name)
        end

        binding.type_params.map do |name|
          inferred = substitutions[name]
          raise LoweringError, "cannot infer type argument #{name} for function #{binding.name}" unless inferred

          inferred
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
          return unless actual_type.is_a?(Types::GenericInstance)
          return unless actual_type.name == pattern_type.name && actual_type.arguments.length == pattern_type.arguments.length

          pattern_type.arguments.zip(actual_type.arguments).each do |expected_argument, actual_argument|
            next if expected_argument.is_a?(Types::LiteralTypeArg)

            collect_type_substitutions(expected_argument, actual_argument, substitutions, function_name)
          end
        when Types::Span
          return unless actual_type.is_a?(Types::Span)

          collect_type_substitutions(pattern_type.element_type, actual_type.element_type, substitutions, function_name)
        when Types::StructInstance
          return unless actual_type.is_a?(Types::StructInstance)
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
        Sema::ValueBinding.new(
          name: binding.name,
          type: substitute_type(binding.type, substitutions),
          mutable: binding.mutable,
          kind: binding.kind,
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
        when Types::StructInstance
          type.definition.instantiate(type.arguments.map { |argument| substitute_type(argument, substitutions) })
        when Types::Function
          Types::Function.new(
            type.name,
            params: type.params.map { |param| Types::Parameter.new(param.name, substitute_type(param.type, substitutions), mutable: param.mutable) },
            return_type: substitute_type(type.return_type, substitutions),
            receiver_type: type.receiver_type ? substitute_type(type.receiver_type, substitutions) : nil,
            receiver_mutable: type.receiver_mutable,
            external: type.external,
          )
        else
          type
        end
      end

      def pointer_type?(type)
        type.is_a?(Types::GenericInstance) && type.name == "ptr" && type.arguments.length == 1
      end

      def array_type?(type)
        type.is_a?(Types::GenericInstance) && type.name == "array" && type.arguments.length == 2 &&
          type.arguments[1].is_a?(Types::LiteralTypeArg)
      end

      def array_element_type(type)
        return unless array_type?(type)

        type.arguments.first
      end

      def integer_type?(type)
        type.is_a?(Types::Primitive) && type.integer?
      end

      def infer_index_result_type(receiver_type, index_type)
        raise LoweringError, "index must be an integer type, got #{index_type}" unless integer_type?(index_type)

        if array_type?(receiver_type)
          return array_element_type(receiver_type)
        end

        if pointer_type?(receiver_type)
          return pointee_type(receiver_type)
        end

        raise LoweringError, "cannot index #{receiver_type}"
      end

      def pointee_type(type)
        return unless pointer_type?(type)

        type.arguments.first
      end

      def pointer_to(type)
        Types::GenericInstance.new("ptr", [type])
      end

      def analysis_for_module(module_name)
        @program.analyses_by_module_name.fetch(module_name)
      end

      def function_type_for_method(receiver_type, name, analysis: @analysis)
        _, method_ast = @method_definitions.fetch([receiver_type, name])
        params = method_ast.params.drop(1).map do |param|
          Types::Parameter.new(param.name, resolve_type_ref_for_analysis(param.type, analysis), mutable: param.mutable)
        end
        return_type = if method_ast.return_type
                        resolve_type_ref_for_analysis(method_ast.return_type, analysis)
                      else
                        analysis.types.fetch("void")
                      end
        Types::Function.new(name, params:, return_type:, receiver_type:, receiver_mutable: method_ast.params.first.mutable)
      end

      def resolve_type_ref_for_analysis(type_ref, analysis)
        saved_analysis = @analysis
        saved_module_name = @module_name
        saved_module_prefix = @module_prefix
        saved_imports = @imports
        saved_types = @types
        saved_values = @values
        saved_functions = @functions

        @analysis = analysis
        @module_name = analysis.module_name
        @module_prefix = @module_name.tr(".", "_")
        @imports = analysis.imports
        @types = analysis.types
        @values = analysis.values
        @functions = analysis.functions
        resolve_type_ref(type_ref)
      ensure
        @analysis = saved_analysis
        @module_name = saved_module_name
        @module_prefix = saved_module_prefix
        @imports = saved_imports
        @types = saved_types
        @values = saved_values
        @functions = saved_functions
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
                 if (generic_type = resolve_named_generic_type(parts))
                   generic_type.instantiate(args)
                 elsif name == "span"
                   Types::Span.new(args.fetch(0))
                 else
                   validate_generic_type!(name, args)
                   Types::GenericInstance.new(name, args)
                 end
               elsif parts.length == 1
                 type = @types.fetch(parts.first)
                 raise LoweringError, "generic type #{parts.first} requires type arguments" if type.is_a?(Types::GenericStructDefinition)

                 type
               elsif parts.length == 2 && @imports.key?(parts.first)
                 type = @imports.fetch(parts.first).types.fetch(parts.last)
                 raise LoweringError, "generic type #{type_ref.name} requires type arguments" if type.is_a?(Types::GenericStructDefinition)

                 type
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
        return type.name if type.module_name&.start_with?("std.c.")
        return type.name if type.module_name.nil?

        "#{type.module_name.tr('.', '_')}_#{type.name}"
      end

      def resolve_named_generic_type(parts)
        if parts.length == 1
          type = @types[parts.first]
          return type if type.is_a?(Types::GenericStructDefinition)
        elsif parts.length == 2 && @imports.key?(parts.first)
          type = @imports.fetch(parts.first).types[parts.last]
          return type if type.is_a?(Types::GenericStructDefinition)
        end

        nil
      end

      def type_ref_from_specialization(expression)
        case expression.callee
        when AST::Identifier
          AST::TypeRef.new(name: AST::QualifiedName.new(parts: [expression.callee.name]), arguments: expression.arguments, nullable: false)
        when AST::MemberAccess
          return nil unless expression.callee.receiver.is_a?(AST::Identifier)

          AST::TypeRef.new(
            name: AST::QualifiedName.new(parts: [expression.callee.receiver.name, expression.callee.member]),
            arguments: expression.arguments,
            nullable: false,
          )
        end
      end

      def validate_generic_type!(name, arguments)
        case name
        when "ptr"
          raise LoweringError, "ptr requires exactly one type argument" unless arguments.length == 1
          raise LoweringError, "ptr type argument must be a type" if arguments.first.is_a?(Types::LiteralTypeArg)
        when "span"
          raise LoweringError, "span requires exactly one type argument" unless arguments.length == 1
          raise LoweringError, "span element type must be a type" if arguments.first.is_a?(Types::LiteralTypeArg)
        when "array"
          raise LoweringError, "array requires exactly two type arguments" unless arguments.length == 2
          raise LoweringError, "array element type must be a type" if arguments.first.is_a?(Types::LiteralTypeArg)
          raise LoweringError, "array length must be an integer literal" unless arguments[1].is_a?(Types::LiteralTypeArg) && arguments[1].value.is_a?(Integer)
          raise LoweringError, "array length must be positive" unless arguments[1].value.positive?
        else
          raise LoweringError, "unknown generic type #{name}"
        end
      end

      def enum_member_c_name(type, member_name)
        "#{c_type_name(type)}_#{member_name}"
      end

      def local_named_type?(type)
        type.respond_to?(:module_name) && (type.module_name == @module_name || type.module_name.nil?)
      end

      def function_binding_c_name(binding, module_name:, receiver_type: nil)
        return "main" if receiver_type.nil? && binding.name == "main" && binding.type_arguments.empty?
        return "#{c_type_name(receiver_type)}_#{binding.name}" if receiver_type

        module_function_c_name(module_name, binding.name, type_arguments: binding.type_arguments)
      end

      def constant_c_name(name)
        module_constant_c_name(@module_name, name)
      end

      def imported_value_c_name(imported_module, name)
        imported_analysis = analysis_for_module(imported_module.name)
        return name if imported_analysis.module_kind == :extern_module

        module_constant_c_name(imported_module.name, name)
      end

      def module_function_c_name(module_name, name, type_arguments: [])
        base = "#{module_name.tr('.', '_')}_#{name}"
        return base if type_arguments.empty?

        "#{base}_#{sanitize_identifier(type_arguments.join('_'))}"
      end

      def module_constant_c_name(module_name, name)
        "#{module_name.tr('.', '_')}_#{name}"
      end

      def c_local_name(name)
        name
      end

      def sanitize_identifier(text)
        identifier = text.gsub(/[^A-Za-z0-9_]+/, "_").gsub(/_+/, "_").sub(/^_+/, "").sub(/_+$/, "")
        identifier.empty? ? "value" : identifier
      end
    end
  end
end

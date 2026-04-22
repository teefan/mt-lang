# frozen_string_literal: true

module MilkTea
  class SemaError < StandardError; end

  class Sema
    Analysis = Data.define(:ast, :module_name, :module_kind, :directives, :imports, :types, :values, :functions, :methods)
    ValueBinding = Data.define(:name, :type, :mutable, :kind)
    FunctionBinding = Data.define(:name, :type, :body_params, :ast, :external, :type_params, :instances, :type_arguments, :owner)
    ModuleBinding = Data.define(:name, :types, :values, :functions, :methods)

    BUILTIN_TYPE_NAMES = %w[
      bool byte char i8 i16 i32 i64 u8 u16 u32 u64 isize usize f32 f64 void str cstr
    ].freeze

    def self.check(ast, imported_modules: {})
      Checker.new(ast, imported_modules:).check
    end

    class Checker
      def initialize(ast, imported_modules: {})
        @ast = ast
        @imported_modules = imported_modules
        @module_name = ast.module_name&.to_s
        @module_kind = ast.module_kind
        @types = {}
        @top_level_values = {}
        @top_level_functions = {}
        @imports = {}
        @methods = Hash.new { |hash, key| hash[key] = {} }
        @null_type = Types::Null.new
        @unsafe_depth = 0
        @checked_function_bindings = {}
        @checking_function_bindings = {}
      end

      def check
        install_builtin_types
        install_imports
        declare_named_types
        resolve_type_aliases
        resolve_aggregate_fields
        resolve_enum_members
        declare_top_level_values
        declare_functions
        check_top_level_values
        check_functions

        Analysis.new(
          ast: @ast,
          module_name: @module_name,
          module_kind: @module_kind,
          directives: @ast.directives,
          imports: @imports,
          types: @types,
          values: @top_level_values,
          functions: @top_level_functions,
          methods: @methods,
        )
      end

      private

      def install_builtin_types
        BUILTIN_TYPE_NAMES.each do |name|
          @types[name] = Types::Primitive.new(name)
        end
      end

      def install_imports
        @ast.imports.each do |import|
          alias_name = import.alias_name || import.path.parts.last
          raise SemaError, "duplicate import alias #{alias_name}" if @imports.key?(alias_name)

          module_binding = @imported_modules[import.path.to_s]
          raise SemaError, "unknown import #{import.path}" unless module_binding

          @imports[alias_name] = module_binding
        end
      end

      def declare_named_types
        @ast.declarations.each do |decl|
          case decl
          when AST::StructDecl
            ensure_available_type_name!(decl.name)
            @types[decl.name] = if decl.type_params.empty?
                                  Types::Struct.new(decl.name, module_name: @module_name, external: external_module?)
                                else
                                  Types::GenericStructDefinition.new(decl.name, decl.type_params.map(&:name), module_name: @module_name, external: external_module?)
                                end
          when AST::UnionDecl
            ensure_available_type_name!(decl.name)
            @types[decl.name] = Types::Union.new(decl.name, module_name: @module_name, external: external_module?)
          when AST::EnumDecl
            ensure_available_type_name!(decl.name)
            @types[decl.name] = Types::Enum.new(decl.name, module_name: @module_name, external: external_module?)
          when AST::FlagsDecl
            ensure_available_type_name!(decl.name)
            @types[decl.name] = Types::Flags.new(decl.name, module_name: @module_name, external: external_module?)
          when AST::OpaqueDecl
            ensure_available_type_name!(decl.name)
            @types[decl.name] = Types::Opaque.new(decl.name, module_name: @module_name, external: external_module?)
          end
        end
      end

      def resolve_type_aliases
        @ast.declarations.grep(AST::TypeAliasDecl).each do |decl|
          ensure_available_type_name!(decl.name)
          @types[decl.name] = resolve_type_ref(decl.target)
        end
      end

      def resolve_aggregate_fields
        @ast.declarations.each do |decl|
          next unless decl.is_a?(AST::StructDecl) || decl.is_a?(AST::UnionDecl)

          struct_type = @types.fetch(decl.name)
          type_params = if struct_type.is_a?(Types::GenericStructDefinition)
                          seen = {}
                          struct_type.type_params.each_with_object({}) do |name, params|
                            raise SemaError, "duplicate type parameter #{decl.name}[#{name}]" if seen.key?(name)

                            seen[name] = true
                            params[name] = Types::TypeVar.new(name)
                          end
                        else
                          {}
                        end
          fields = {}

          decl.fields.each do |field|
            raise SemaError, "duplicate field #{decl.name}.#{field.name}" if fields.key?(field.name)

            fields[field.name] = resolve_type_ref(field.type, type_params:)
          end

          struct_type.define_fields(fields)
        end
      end

      def resolve_enum_members
        @ast.declarations.each do |decl|
          next unless decl.is_a?(AST::EnumDecl) || decl.is_a?(AST::FlagsDecl)

          enum_type = @types.fetch(decl.name)
          backing_type = resolve_type_ref(decl.backing_type)
          unless backing_type.is_a?(Types::Primitive) && backing_type.integer?
            raise SemaError, "#{decl.name} backing type must be an integer primitive, got #{backing_type}"
          end

          member_names = []
          decl.members.each do |member|
            raise SemaError, "duplicate member #{decl.name}.#{member.name}" if member_names.include?(member.name)

            member_names << member.name
          end

          enum_type.define_members(backing_type, member_names)

          decl.members.each do |member|
            actual_type = infer_expression(member.value, scopes: [], expected_type: backing_type)
            ensure_assignable!(actual_type, backing_type, "member #{decl.name}.#{member.name} expects #{backing_type}, got #{actual_type}")
          end
        end
      end

      def declare_top_level_values
        @ast.declarations.grep(AST::ConstDecl).each do |decl|
          ensure_available_value_name!(decl.name)
          @top_level_values[decl.name] = ValueBinding.new(
            name: decl.name,
            type: resolve_type_ref(decl.type),
            mutable: false,
            kind: :const,
          )
        end
      end

      def declare_functions
        @ast.declarations.each do |decl|
          case decl
          when AST::FunctionDef
            ensure_available_value_name!(decl.name)
            @top_level_functions[decl.name] = declare_function_binding(decl)
          when AST::ExternFunctionDecl
            ensure_available_value_name!(decl.name)
            @top_level_functions[decl.name] = declare_function_binding(decl, external: true)
          when AST::ImplBlock
            receiver_type = resolve_type_ref(AST::TypeRef.new(name: decl.type_name, arguments: [], nullable: false))
            raise SemaError, "impl target #{decl.type_name} must be a local struct" unless receiver_type.is_a?(Types::Struct)

            decl.methods.each do |method|
              binding = declare_function_binding(method, receiver_type:)
              raise SemaError, "duplicate method #{receiver_type.name}.#{binding.name}" if @methods[receiver_type].key?(binding.name)

              @methods[receiver_type][binding.name] = binding
            end
          end
        end
      end

      def declare_function_binding(decl, receiver_type: nil, external: false)
        type_param_names = decl.type_params.map(&:name)
        raise SemaError, "extern function #{decl.name} cannot be generic" if external && type_param_names.any?
        raise SemaError, "generic methods are not supported yet in #{decl.name}" if receiver_type && type_param_names.any?
        raise SemaError, "main cannot be generic" if decl.name == "main" && type_param_names.any?

        type_params = {}
        type_param_names.each do |name|
          raise SemaError, "duplicate type parameter #{decl.name}[#{name}]" if type_params.key?(name)

          type_params[name] = Types::TypeVar.new(name)
        end

        body_params = decl.params.map.with_index do |param, index|
          type = if receiver_type && index.zero? && param.name == "self"
                   receiver_type
                 else
                   raise SemaError, "parameter #{param.name} requires a type" unless param.type

                   resolve_type_ref(param.type, type_params:)
                 end

          if external && array_type?(type)
            raise SemaError, "extern function #{decl.name} cannot take array parameters"
          end

          ValueBinding.new(name: param.name, type:, mutable: param.mutable, kind: :param)
        end

        receiver_mutable = false
        call_params = body_params
        if receiver_type
          self_param = decl.params.first
          unless self_param && self_param.name == "self"
            raise SemaError, "method #{decl.name} must declare self as the first parameter"
          end

          receiver_mutable = self_param.mutable
          call_params = body_params.drop(1)
        end

        seen = {}
        body_params.each do |param|
          raise SemaError, "duplicate parameter #{param.name} in #{decl.name}" if seen.key?(param.name)

          seen[param.name] = true
        end

        return_type = decl.return_type ? resolve_type_ref(decl.return_type, type_params:) : @types.fetch("void")
        if external && array_type?(return_type)
          raise SemaError, "extern function #{decl.name} cannot return arrays"
        end

        function_type = Types::Function.new(
          decl.name,
          params: call_params.map { |param| Types::Parameter.new(param.name, param.type, mutable: param.mutable) },
          return_type:,
          receiver_type:,
          receiver_mutable:,
          external:,
        )

        FunctionBinding.new(
          name: decl.name,
          type: function_type,
          body_params:,
          ast: decl,
          external:,
          type_params: type_param_names.freeze,
          instances: {},
          type_arguments: [].freeze,
          owner: self,
        )
      end

      def check_top_level_values
        @ast.declarations.grep(AST::ConstDecl).each do |decl|
          binding = @top_level_values.fetch(decl.name)
          actual_type = infer_expression(decl.value, scopes: [], expected_type: binding.type)
          ensure_assignable!(actual_type, binding.type, "cannot assign #{actual_type} to constant #{decl.name}: expected #{binding.type}")
        end
      end

      def check_functions
        @top_level_functions.each_value do |binding|
          check_function(binding)
        end

        @methods.each_value do |method_map|
          method_map.each_value do |binding|
            check_function(binding)
          end
        end
      end

      def check_function(binding)
        return if binding.external || binding.type_params.any?
        return if @checked_function_bindings[binding.object_id]
        return if @checking_function_bindings[binding.object_id]

        @checking_function_bindings[binding.object_id] = true
        with_scope(binding.body_params) do |scopes|
          check_block(binding.ast.body, scopes:, return_type: binding.type.return_type)
        end
        @checked_function_bindings[binding.object_id] = true
      ensure
        @checking_function_bindings.delete(binding.object_id)
      end

      def check_block(statements, scopes:, return_type:)
        with_nested_scope(scopes) do |nested_scopes|
          statements.each do |statement|
            check_statement(statement, scopes: nested_scopes, return_type:)
          end
        end
      end

      def check_statement(statement, scopes:, return_type:)
        case statement
        when AST::LocalDecl
          check_local_decl(statement, scopes:)
        when AST::Assignment
          check_assignment(statement, scopes:)
        when AST::IfStmt
          statement.branches.each do |branch|
            condition_type = infer_expression(branch.condition, scopes:)
            ensure_assignable!(condition_type, @types.fetch("bool"), "if condition must be bool, got #{condition_type}")
            check_block(branch.body, scopes:, return_type:)
          end
          check_block(statement.else_body, scopes:, return_type:) if statement.else_body
        when AST::UnsafeStmt
          with_unsafe do
            check_block(statement.body, scopes:, return_type:)
          end
        when AST::WhileStmt
          condition_type = infer_expression(statement.condition, scopes:)
          ensure_assignable!(condition_type, @types.fetch("bool"), "while condition must be bool, got #{condition_type}")
          check_block(statement.body, scopes:, return_type:)
        when AST::ReturnStmt
          value_type = statement.value ? infer_expression(statement.value, scopes:, expected_type: return_type) : @types.fetch("void")
          ensure_assignable!(value_type, return_type, "return type mismatch: expected #{return_type}, got #{value_type}")
        when AST::DeferStmt
          infer_expression(statement.expression, scopes:)
        when AST::ExpressionStmt
          infer_expression(statement.expression, scopes:)
        else
          raise SemaError, "unsupported statement #{statement.class.name}"
        end
      end

      def check_local_decl(statement, scopes:)
        current_scope = scopes.last
        raise SemaError, "duplicate local #{statement.name}" if current_scope.key?(statement.name)

        declared_type = statement.type ? resolve_type_ref(statement.type) : nil
        inferred_type = infer_expression(statement.value, scopes:, expected_type: declared_type)

        if declared_type
          ensure_assignable!(inferred_type, declared_type, "cannot assign #{inferred_type} to #{statement.name}: expected #{declared_type}")
          final_type = declared_type
        else
          raise SemaError, "cannot infer type for #{statement.name} from null" if inferred_type == @null_type
          raise SemaError, "cannot bind void result to #{statement.name}" if inferred_type.void?

          final_type = inferred_type
        end

        current_scope[statement.name] = ValueBinding.new(
          name: statement.name,
          type: final_type,
          mutable: statement.kind == :var,
          kind: statement.kind,
        )
      end

      def check_assignment(statement, scopes:)
        target_type = infer_lvalue(statement.target, scopes:)

        value_type = infer_expression(statement.value, scopes:, expected_type: target_type)

        case statement.operator
        when "="
          ensure_assignable!(value_type, target_type, "cannot assign #{value_type} to #{target_type}")
        when "+=", "-=", "*=", "/="
          unless target_type.numeric? && value_type.numeric? && target_type == value_type
            raise SemaError, "operator #{statement.operator} requires matching numeric types, got #{target_type} and #{value_type}"
          end
        else
          raise SemaError, "unsupported assignment operator #{statement.operator}"
        end
      end

      def infer_lvalue(expression, scopes:)
        case expression
        when AST::Identifier
          binding = lookup_value(expression.name, scopes)
          raise SemaError, "unknown name #{expression.name}" unless binding
          raise SemaError, "cannot assign to immutable #{expression.name}" unless binding.mutable

          binding.type
        when AST::MemberAccess
          receiver_type = infer_lvalue_receiver(expression.receiver, scopes:)
          unless aggregate_type?(receiver_type)
            raise SemaError, "cannot assign to member #{expression.member} of #{receiver_type}"
          end

          field_type = receiver_type.field(expression.member)
          raise SemaError, "unknown field #{receiver_type}.#{expression.member}" unless field_type

          field_type
        when AST::IndexAccess
          receiver_type = infer_lvalue_receiver(expression.receiver, scopes:)
          index_type = infer_expression(expression.index, scopes:, expected_type: @types.fetch("usize"))
          infer_index_result_type(receiver_type, index_type)
        when AST::UnaryOp
          if expression.operator == "*"
            pointer_type = infer_expression(expression.operand, scopes:)
            pointee_type = pointee_type(pointer_type)
            raise SemaError, "operator * requires a pointer operand, got #{pointer_type}" unless pointee_type

            return pointee_type
          end

          raise SemaError, "invalid assignment target"
        else
          raise SemaError, "invalid assignment target"
        end
      end

      def infer_lvalue_receiver(expression, scopes:)
        case expression
        when AST::Identifier
          binding = lookup_value(expression.name, scopes)
          raise SemaError, "unknown name #{expression.name}" unless binding
          raise SemaError, "cannot assign through immutable #{expression.name}" unless binding.mutable

          binding.type
        when AST::MemberAccess
          receiver_type = infer_lvalue_receiver(expression.receiver, scopes:)
          unless aggregate_type?(receiver_type)
            raise SemaError, "cannot access member #{expression.member} of #{receiver_type}"
          end

          field_type = receiver_type.field(expression.member)
          raise SemaError, "unknown field #{receiver_type}.#{expression.member}" unless field_type

          field_type
        when AST::IndexAccess
          receiver_type = infer_lvalue_receiver(expression.receiver, scopes:)
          index_type = infer_expression(expression.index, scopes:, expected_type: @types.fetch("usize"))
          infer_index_result_type(receiver_type, index_type)
        when AST::UnaryOp
          if expression.operator == "*"
            pointer_type = infer_expression(expression.operand, scopes:)
            pointee_type = pointee_type(pointer_type)
            raise SemaError, "operator * requires a pointer operand, got #{pointer_type}" unless pointee_type

            return pointee_type
          end

          raise SemaError, "invalid assignment target"
        else
          raise SemaError, "invalid assignment target"
        end
      end

      def infer_expression(expression, scopes:, expected_type: nil)
        case expression
        when AST::IntegerLiteral
          infer_integer_literal(expected_type)
        when AST::FloatLiteral
          infer_float_literal(expected_type)
        when AST::StringLiteral
          @types.fetch(expression.cstring ? "cstr" : "str")
        when AST::BooleanLiteral
          @types.fetch("bool")
        when AST::NullLiteral
          @null_type
        when AST::Identifier
          infer_identifier(expression, scopes:, expected_type:)
        when AST::MemberAccess
          infer_member_access(expression, scopes:)
        when AST::IndexAccess
          infer_index_access(expression, scopes:)
        when AST::UnaryOp
          infer_unary(expression, scopes:, expected_type:)
        when AST::BinaryOp
          infer_binary(expression, scopes:, expected_type:)
        when AST::Call
          infer_call(expression, scopes:)
        when AST::Specialization
          raise SemaError, "specialized name #{describe_expression(expression)} must be called"
        else
          raise SemaError, "unsupported expression #{expression.class.name}"
        end
      end

      def infer_integer_literal(expected_type)
        if expected_type.is_a?(Types::Primitive) && expected_type.integer?
          expected_type
        else
          @types.fetch("i32")
        end
      end

      def infer_float_literal(expected_type)
        if expected_type.is_a?(Types::Primitive) && expected_type.float?
          expected_type
        else
          @types.fetch("f64")
        end
      end

      def infer_identifier(expression, scopes:, expected_type: nil)
        binding = lookup_value(expression.name, scopes)
        return binding.type if binding

        if @top_level_functions.key?(expression.name)
          raise SemaError, "generic function #{expression.name} must be called" if @top_level_functions.fetch(expression.name).type_params.any?

          function_type = function_type_for_name(expression.name)
          return function_type if expected_type

          raise SemaError, "function #{expression.name} must be called"
        end

        raise SemaError, "module #{expression.name} cannot be used as a value" if @imports.key?(expression.name)
        raise SemaError, "type #{expression.name} cannot be used as a value" if @types.key?(expression.name)

        raise SemaError, "unknown name #{expression.name}"
      end

      def infer_member_access(expression, scopes:)
        type = resolve_type_expression(expression.receiver)
        if type
          member_type = resolve_type_member(type, expression.member)
          return member_type if member_type

          raise SemaError, "unknown member #{type}.#{expression.member}"
        end

        if expression.receiver.is_a?(AST::Identifier) && @imports.key?(expression.receiver.name)
          imported_module = @imports.fetch(expression.receiver.name)
          value = imported_module.values[expression.member]
          return value.type if value

          if imported_module.functions.key?(expression.member)
            raise SemaError, "function #{expression.receiver.name}.#{expression.member} must be called"
          end

          if imported_module.types.key?(expression.member)
            raise SemaError, "type #{expression.receiver.name}.#{expression.member} cannot be used as a value"
          end

          raise SemaError, "unknown member #{expression.receiver.name}.#{expression.member}"
        end

        receiver_type = infer_expression(expression.receiver, scopes:)
        unless aggregate_type?(receiver_type)
          raise SemaError, "cannot access member #{expression.member} of #{receiver_type}"
        end

        field_type = receiver_type.field(expression.member)
        return field_type if field_type

        if lookup_method(receiver_type, expression.member)
          raise SemaError, "method #{receiver_type.name}.#{expression.member} must be called"
        end

        raise SemaError, "unknown field #{receiver_type}.#{expression.member}"
      end

      def infer_index_access(expression, scopes:)
        receiver_type = infer_expression(expression.receiver, scopes:)
        index_type = infer_expression(expression.index, scopes:, expected_type: @types.fetch("usize"))
        infer_index_result_type(receiver_type, index_type)
      end

      def infer_unary(expression, scopes:, expected_type: nil)
        operand_type = infer_expression(expression.operand, scopes:, expected_type:)

        case expression.operator
        when "not"
          ensure_assignable!(operand_type, @types.fetch("bool"), "operator not requires bool, got #{operand_type}")
          @types.fetch("bool")
        when "+", "-"
          raise SemaError, "operator #{expression.operator} requires a numeric operand, got #{operand_type}" unless operand_type.numeric?

          operand_type
        when "~"
          raise SemaError, "operator ~ requires an integer or flags operand, got #{operand_type}" unless bitwise_type?(operand_type)

          operand_type
        when "&"
          pointee_type = infer_lvalue(expression.operand, scopes:)
          pointer_to(pointee_type)
        when "*"
          pointee_type = pointee_type(operand_type)
          raise SemaError, "operator * requires a pointer operand, got #{operand_type}" unless pointee_type

          pointee_type
        else
          raise SemaError, "unsupported unary operator #{expression.operator}"
        end
      end

      def infer_binary(expression, scopes:, expected_type: nil)
        propagated_type = propagating_expected_type(expression.operator, expected_type)
        left_type = infer_expression(expression.left, scopes:, expected_type: propagated_type)

        right_expected_type = case expression.operator
                              when "<<", ">>"
                                propagated_type || left_type
                              when "+", "-", "*", "/", "%", "|", "&", "^"
                                left_type
                              else
                                left_type
                              end

        right_type = infer_expression(expression.right, scopes:, expected_type: right_expected_type)

        case expression.operator
        when "and", "or"
          ensure_assignable!(left_type, @types.fetch("bool"), "operator #{expression.operator} requires bool operands")
          ensure_assignable!(right_type, @types.fetch("bool"), "operator #{expression.operator} requires bool operands")
          @types.fetch("bool")
        when "|", "&", "^"
          unless left_type == right_type && bitwise_type?(left_type)
            raise SemaError, "operator #{expression.operator} requires matching integer or flags types, got #{left_type} and #{right_type}"
          end

          left_type
        when "+", "-", "*", "/"
          pointer_result = pointer_arithmetic_result(expression.operator, left_type, right_type)
          return pointer_result if pointer_result

          unless left_type.numeric? && right_type.numeric? && left_type == right_type
            raise SemaError, "operator #{expression.operator} requires matching numeric types, got #{left_type} and #{right_type}"
          end

          left_type
        when "%"
          unless left_type.integer? && right_type.integer? && left_type == right_type
            raise SemaError, "operator % requires matching integer types, got #{left_type} and #{right_type}"
          end

          left_type
        when "<<", ">>"
          unless left_type.is_a?(Types::Primitive) && left_type.integer? && right_type.is_a?(Types::Primitive) && right_type.integer?
            raise SemaError, "operator #{expression.operator} requires integer operands, got #{left_type} and #{right_type}"
          end

          left_type
        when "<", "<=", ">", ">="
          unless left_type.numeric? && right_type.numeric? && left_type == right_type
            raise SemaError, "operator #{expression.operator} requires matching numeric types, got #{left_type} and #{right_type}"
          end

          @types.fetch("bool")
        when "==", "!="
          unless types_compatible?(left_type, right_type) || types_compatible?(right_type, left_type)
            raise SemaError, "operator #{expression.operator} requires comparable types, got #{left_type} and #{right_type}"
          end

          @types.fetch("bool")
        else
          raise SemaError, "unsupported binary operator #{expression.operator}"
        end
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

      def infer_call(expression, scopes:)
        callable_kind, callable, receiver = resolve_callable(expression.callee, scopes:)

        case callable_kind
        when :function
          callable = specialize_function_binding(callable, expression.arguments, scopes:)
          check_function_call(callable, expression.arguments, scopes:)
          callable.owner.send(:check_function, callable) unless callable.type_arguments.empty?
          callable.type.return_type
        when :method
          raise SemaError, "cannot call mut method #{callable.name} on an immutable receiver" if callable.type.receiver_mutable && !assignable_receiver?(receiver, scopes)

          check_function_call(callable, expression.arguments, scopes:)
          callable.type.return_type
        when :struct
          check_aggregate_construction(callable, expression.arguments, scopes:)
        when :array
          check_array_construction(callable, expression.arguments, scopes:)
        when :cast
          check_cast_call(callable, expression.arguments, scopes:)
        else
          raise SemaError, "#{describe_expression(expression.callee)} is not callable"
        end
      end

      def resolve_callable(callee, scopes:)
        case callee
        when AST::Identifier
          return [:function, @top_level_functions.fetch(callee.name), nil] if @top_level_functions.key?(callee.name)

          type = @types[callee.name]
          return [:struct, type, nil] if type.is_a?(Types::Struct)

          raise SemaError, "unknown callable #{callee.name}"
        when AST::MemberAccess
          if callee.receiver.is_a?(AST::Identifier) && @imports.key?(callee.receiver.name)
            imported_module = @imports.fetch(callee.receiver.name)
            return [:function, imported_module.functions.fetch(callee.member), nil] if imported_module.functions.key?(callee.member)
            return [:struct, imported_module.types.fetch(callee.member), nil] if imported_module.types[callee.member].is_a?(Types::Struct)

            raise SemaError, "unknown callable #{callee.receiver.name}.#{callee.member}"
          end

          receiver_type = infer_expression(callee.receiver, scopes:)
          method = lookup_method(receiver_type, callee.member)
          return [:method, method, callee.receiver] if method

          raise SemaError, "unknown method #{receiver_type}.#{callee.member}"
        when AST::Specialization
          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "cast"
            raise SemaError, "cast requires exactly one type argument" unless callee.arguments.length == 1

            type_arg = callee.arguments.first.value
            raise SemaError, "cast type argument must be a type" unless type_arg.is_a?(AST::TypeRef)

            return [:cast, resolve_type_ref(type_arg), nil]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "array"
            raise SemaError, "array requires exactly two type arguments" unless callee.arguments.length == 2

            array_type = resolve_type_ref(AST::TypeRef.new(name: AST::QualifiedName.new(parts: ["array"]), arguments: callee.arguments, nullable: false))
            raise SemaError, "array specialization must be array[T, N]" unless array_type?(array_type)

            return [:array, array_type, nil]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "span"
            raise SemaError, "span requires exactly one type argument" unless callee.arguments.length == 1

            span_type = resolve_type_ref(AST::TypeRef.new(name: AST::QualifiedName.new(parts: ["span"]), arguments: callee.arguments, nullable: false))
            raise SemaError, "span specialization must be span[T]" unless span_type?(span_type)

            return [:struct, span_type, nil]
          end

          if (type_ref = type_ref_from_specialization(callee))
            specialized_type = resolve_type_ref(type_ref)
            return [:struct, specialized_type, nil] if specialized_type.is_a?(Types::Struct)
          end

          raise SemaError, "unsupported callable specialization #{describe_expression(callee)}"
        else
          raise SemaError, "unsupported callee #{describe_expression(callee)}"
        end
      end

      def check_function_call(binding, arguments, scopes:)
        if arguments.any?(&:name)
          raise SemaError, "function #{binding.name} does not support named arguments"
        end

        expected_params = binding.type.params
        raise SemaError, "function #{binding.name} expects #{expected_params.length} arguments, got #{arguments.length}" unless expected_params.length == arguments.length

        arguments.zip(expected_params).each do |argument, parameter|
          actual_type = infer_expression(argument.value, scopes:, expected_type: parameter.type)
          ensure_assignable!(actual_type, parameter.type, "argument #{parameter.name} to #{binding.name} expects #{parameter.type}, got #{actual_type}")
        end
      end

      def check_aggregate_construction(struct_type, arguments, scopes:)
        display_name = aggregate_display_name(struct_type)

        raise SemaError, "aggregate construction for #{display_name} requires named arguments" unless arguments.all?(&:name)

        provided = {}
        arguments.each do |argument|
          field_type = struct_type.field(argument.name)
          raise SemaError, "unknown field #{display_name}.#{argument.name}" unless field_type
          raise SemaError, "duplicate field #{display_name}.#{argument.name}" if provided.key?(argument.name)

          actual_type = infer_expression(argument.value, scopes:, expected_type: field_type)
          ensure_assignable!(actual_type, field_type, "field #{display_name}.#{argument.name} expects #{field_type}, got #{actual_type}")
          provided[argument.name] = true
        end

        missing_fields = struct_type.fields.keys - provided.keys
        raise SemaError, "missing fields for #{display_name}: #{missing_fields.join(', ')}" unless missing_fields.empty?

        struct_type
      end

      def check_array_construction(array_type, arguments, scopes:)
        raise SemaError, "array construction does not support named arguments" if arguments.any?(&:name)

        element_type = array_element_type(array_type)
        length = array_length(array_type)
        raise SemaError, "array expects #{length} elements, got #{arguments.length}" unless arguments.length == length

        arguments.each do |argument|
          actual_type = infer_expression(argument.value, scopes:, expected_type: element_type)
          ensure_assignable!(actual_type, element_type, "array element expects #{element_type}, got #{actual_type}")
        end

        array_type
      end

      def check_cast_call(target_type, arguments, scopes:)
        raise SemaError, "cast requires exactly one argument" unless arguments.length == 1
        raise SemaError, "cast does not support named arguments" if arguments.first.name

        source_type = infer_expression(arguments.first.value, scopes:)
        if source_type == target_type
          return target_type
        end

        if pointer_cast?(source_type, target_type)
          raise SemaError, "pointer cast requires unsafe" unless unsafe_context?

          return target_type
        end

        unless source_type.is_a?(Types::Primitive) && source_type.numeric? && target_type.is_a?(Types::Primitive) && target_type.numeric?
          raise SemaError, "cast currently only supports numeric primitive types, got #{source_type} -> #{target_type}"
        end

        target_type
      end

      def lookup_value(name, scopes)
        scopes.reverse_each do |scope|
          return scope[name] if scope.key?(name)
        end

        @top_level_values[name]
      end

      def lookup_method(receiver_type, name)
        method = @methods.fetch(receiver_type, {})[name]
        return method if method

        @imports.each_value do |module_binding|
          next unless module_binding.methods.key?(receiver_type)

          imported_method = module_binding.methods.fetch(receiver_type)[name]
          return imported_method if imported_method
        end

        nil
      end

      def ensure_available_type_name!(name)
        raise SemaError, "duplicate type #{name}" if @types.key?(name)
      end

      def ensure_available_value_name!(name)
        raise SemaError, "duplicate value #{name}" if @top_level_values.key?(name) || @top_level_functions.key?(name)
      end

      def resolve_type_ref(type_ref, type_params: {})
        base = resolve_non_nullable_type(type_ref, type_params:)
        return base if type_ref.is_a?(AST::FunctionType)

        type_ref.nullable ? Types::Nullable.new(base) : base
      end

      def resolve_non_nullable_type(type_ref, type_params: {})
        if type_ref.is_a?(AST::FunctionType)
          params = type_ref.params.map do |param|
            Types::Parameter.new(param.name, resolve_type_ref(param.type, type_params:), mutable: param.mutable)
          end
          return Types::Function.new(nil, params:, return_type: resolve_type_ref(type_ref.return_type, type_params:))
        end

        parts = type_ref.name.parts

        if type_ref.arguments.any?
          name = parts.join(".")
          arguments = type_ref.arguments.map do |argument|
            case argument.value
            when AST::TypeRef
              resolve_type_ref(argument.value, type_params:)
            when AST::IntegerLiteral
              Types::LiteralTypeArg.new(argument.value.value)
            when AST::FloatLiteral
              Types::LiteralTypeArg.new(argument.value.value)
            else
              raise SemaError, "unsupported type argument #{argument.value.class.name}"
            end
          end

          if (generic_type = resolve_named_generic_type(parts))
            begin
              return generic_type.instantiate(arguments)
            rescue ArgumentError => error
              raise SemaError, error.message
            end
          end

          validate_generic_type!(name, arguments)
          return Types::Span.new(arguments.first) if name == "span"

          return Types::GenericInstance.new(name, arguments)
        end

        if parts.length == 1
          return type_params.fetch(parts.first) if type_params.key?(parts.first)

          type = @types[parts.first]
          raise SemaError, "unknown type #{parts.first}" unless type
          raise SemaError, "generic type #{parts.first} requires type arguments" if type.is_a?(Types::GenericStructDefinition)

          return type
        end

        if parts.length == 2 && @imports.key?(parts.first)
          imported_module = @imports.fetch(parts.first)
          type = imported_module.types[parts.last]
          raise SemaError, "unknown type #{type_ref.name}" unless type
          raise SemaError, "generic type #{type_ref.name} requires type arguments" if type.is_a?(Types::GenericStructDefinition)

          return type
        end

        raise SemaError, "unknown type #{type_ref.name}"
      end

      def ensure_assignable!(actual_type, expected_type, message)
        raise SemaError, message unless types_compatible?(actual_type, expected_type)
      end

      def types_compatible?(actual_type, expected_type)
        return true if actual_type == expected_type
        return true if actual_type == @null_type && expected_type.is_a?(Types::Nullable)
        return true if expected_type.is_a?(Types::Nullable) && actual_type == expected_type.base

        false
      end

      def with_unsafe
        @unsafe_depth += 1
        yield
      ensure
        @unsafe_depth -= 1
      end

      def unsafe_context?
        @unsafe_depth.positive?
      end

      def pointer_arithmetic_result(operator, left_type, right_type)
        if pointer_type?(left_type) && integer_type?(right_type)
          raise SemaError, "pointer arithmetic requires unsafe" unless unsafe_context?

          return left_type if operator == "+" || operator == "-"
        end

        if operator == "+" && integer_type?(left_type) && pointer_type?(right_type)
          raise SemaError, "pointer arithmetic requires unsafe" unless unsafe_context?

          return right_type
        end

        nil
      end

      def pointer_cast?(source_type, target_type)
        pointer_type?(source_type) && pointer_type?(target_type)
      end

      def pointer_type?(type)
        type.is_a?(Types::GenericInstance) && type.name == "ptr" && type.arguments.length == 1
      end

      def span_type?(type)
        type.is_a?(Types::Span)
      end

      def aggregate_type?(type)
        type.is_a?(Types::Struct) || span_type?(type)
      end

      def array_type?(type)
        type.is_a?(Types::GenericInstance) && type.name == "array" && type.arguments.length == 2 &&
          !type.arguments.first.is_a?(Types::LiteralTypeArg) && type.arguments[1].is_a?(Types::LiteralTypeArg)
      end

      def array_element_type(type)
        return unless array_type?(type)

        type.arguments.first
      end

      def array_length(type)
        return unless array_type?(type)

        type.arguments[1].value
      end

      def pointee_type(type)
        return unless pointer_type?(type)

        type.arguments.first
      end

      def pointer_to(type)
        Types::GenericInstance.new("ptr", [type])
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

      def aggregate_display_name(type)
        type.is_a?(Types::StructInstance) ? type.to_s : type.name
      end

      def validate_generic_type!(name, arguments)
        case name
        when "ptr"
          raise SemaError, "ptr requires exactly one type argument" unless arguments.length == 1
          raise SemaError, "ptr type argument must be a type" if arguments.first.is_a?(Types::LiteralTypeArg)
        when "span"
          raise SemaError, "span requires exactly one type argument" unless arguments.length == 1
          raise SemaError, "span element type must be a type" if arguments.first.is_a?(Types::LiteralTypeArg)
        when "array"
          raise SemaError, "array requires exactly two type arguments" unless arguments.length == 2
          raise SemaError, "array element type must be a type" if arguments.first.is_a?(Types::LiteralTypeArg)
          raise SemaError, "array length must be an integer literal" unless arguments[1].is_a?(Types::LiteralTypeArg) && arguments[1].value.is_a?(Integer)
          raise SemaError, "array length must be positive" unless arguments[1].value.positive?
        else
          raise SemaError, "unknown generic type #{name}"
        end
      end

      def integer_type?(type)
        type.is_a?(Types::Primitive) && type.integer?
      end

      def infer_index_result_type(receiver_type, index_type)
        raise SemaError, "indexing requires unsafe" unless unsafe_context?
        raise SemaError, "index must be an integer type, got #{index_type}" unless integer_type?(index_type)

        if array_type?(receiver_type)
          return array_element_type(receiver_type)
        end

        if pointer_type?(receiver_type)
          return pointee_type(receiver_type)
        end

        raise SemaError, "cannot index #{receiver_type}"
      end

      def resolve_type_expression(expression)
        case expression
        when AST::Identifier
          @types[expression.name]
        when AST::MemberAccess
          return nil unless expression.receiver.is_a?(AST::Identifier)
          return nil unless @imports.key?(expression.receiver.name)

          imported_module = @imports.fetch(expression.receiver.name)
          imported_module.types[expression.member]
        end
      end

      def resolve_type_member(type, name)
        case type
        when Types::Enum, Types::Flags
          type.member(name)
        end
      end

      def function_type_for_name(name)
        @top_level_functions.fetch(name).type
      end

      def specialize_function_binding(binding, arguments, scopes:)
        return binding if binding.type_params.empty?

        type_arguments = infer_function_type_arguments(binding, arguments, scopes:)
        key = type_arguments.freeze
        return binding.instances.fetch(key) if binding.instances.key?(key)

        substitutions = binding.type_params.zip(type_arguments).to_h
        instance = FunctionBinding.new(
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

      def infer_function_type_arguments(binding, arguments, scopes:)
        expected_params = binding.type.params
        raise SemaError, "function #{binding.name} expects #{expected_params.length} arguments, got #{arguments.length}" unless expected_params.length == arguments.length

        substitutions = {}
        arguments.zip(expected_params).each do |argument, parameter|
          actual_type = infer_expression(argument.value, scopes:)
          collect_type_substitutions(parameter.type, actual_type, substitutions, binding.name)
        end

        binding.type_params.map do |name|
          inferred = substitutions[name]
          raise SemaError, "cannot infer type argument #{name} for function #{binding.name}" unless inferred

          inferred
        end
      end

      def collect_type_substitutions(pattern_type, actual_type, substitutions, function_name)
        case pattern_type
        when Types::TypeVar
          existing = substitutions[pattern_type.name]
          if existing && existing != actual_type
            raise SemaError, "conflicting type argument #{pattern_type.name} for function #{function_name}: got #{existing} and #{actual_type}"
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
        ValueBinding.new(
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

      def bitwise_type?(type)
        type.respond_to?(:bitwise?) && type.bitwise?
      end

      def external_module?
        @module_kind == :extern_module
      end

      def assignable_receiver?(receiver_expression, scopes)
        infer_lvalue(receiver_expression, scopes:)
        true
      rescue SemaError
        false
      end

      def with_scope(bindings)
        scope = {}
        bindings.each do |binding|
          raise SemaError, "duplicate local #{binding.name}" if scope.key?(binding.name)

          scope[binding.name] = binding
        end

        yield([scope])
      end

      def with_nested_scope(scopes)
        nested_scopes = scopes + [{}]
        yield(nested_scopes)
      end

      def describe_expression(expression)
        case expression
        when AST::Identifier
          expression.name
        when AST::MemberAccess
          "#{describe_expression(expression.receiver)}.#{expression.member}"
        when AST::IndexAccess
          "#{describe_expression(expression.receiver)}[...]"
        when AST::Specialization
          "#{describe_expression(expression.callee)}[...]"
        else
          expression.class.name.split("::").last
        end
      end

    end
  end
end

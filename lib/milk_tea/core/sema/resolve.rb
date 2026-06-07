# frozen_string_literal: true

module MilkTea
  class Sema
    class Checker
      private

      def current_type_params
        @current_type_substitutions || {}
      end

      def current_type_param_constraints
        @current_type_param_constraints || {}
      end

      def lookup_value(name, scopes)
        scopes.reverse_each do |scope|
          return scope[name] if scope.key?(name)
        end

        @top_level_values[name]
      end

      def lookup_method(receiver_type, name)
        method = lookup_method_local_or_imported(receiver_type, name)
        return method if method

        fallback_owner = specialization_lookup_owner
        return nil unless fallback_owner

        fallback_owner.send(:lookup_method_local_or_imported, receiver_type, name)
      end

      def lookup_static_method(receiver_type, name)
        static_name = "static:#{name}"
        method = lookup_method_local_or_imported(receiver_type, static_name)
        return method if method

        fallback_owner = specialization_lookup_owner
        return nil unless fallback_owner

        fallback_owner.send(:lookup_method_local_or_imported, receiver_type, static_name)
      end

      def lookup_method_local_or_imported(receiver_type, name)
        dispatch_receiver_type = method_dispatch_receiver_type(receiver_type)

        method = @methods.fetch(receiver_type, {})[name]
        method ||= @methods.fetch(dispatch_receiver_type, {})[name] unless dispatch_receiver_type == receiver_type
        return method if method

        imported_candidates = []

        @imports.each_value do |module_binding|
          imported_method = module_binding.methods.fetch(receiver_type, {})[name]
          if imported_method.nil? && dispatch_receiver_type != receiver_type
            imported_method = module_binding.methods.fetch(dispatch_receiver_type, {})[name]
          end

          imported_candidates << [module_binding, imported_method] if imported_method
        end

        if imported_candidates.empty?
          owner_module = reachable_module_binding_for_type(receiver_type)
          return nil unless owner_module

          return module_binding_method(owner_module, receiver_type, dispatch_receiver_type, name)
        end

        if imported_candidates.length > 1
          modules = imported_candidates.map { |module_binding, _binding| module_binding.name }.join(", ")
          display_name = name.delete_prefix("static:")
          raise_sema_error("ambiguous imported method #{receiver_type}.#{display_name}; found in modules #{modules}")
        end

        imported_candidates.first.last
      end

      def module_binding_method(module_binding, receiver_type, dispatch_receiver_type, name)
        method = module_binding.methods.fetch(receiver_type, {})[name]
        method ||= module_binding.methods.fetch(dispatch_receiver_type, {})[name] unless dispatch_receiver_type == receiver_type
        method
      end

      def reachable_module_binding_for_type(receiver_type)
        module_name = receiver_type_module_name(receiver_type)
        return nil unless module_name
        return nil if module_name == @module_name

        find_reachable_imported_module(module_name)
      end

      def receiver_type_module_name(receiver_type)
        return receiver_type_module_name(receiver_type.base) if receiver_type.is_a?(Types::Nullable)
        return receiver_type.module_name if receiver_type.respond_to?(:module_name)

        nil
      end

      def find_reachable_imported_module(module_name)
        visited = {}

        @imports.each_value do |module_binding|
          found = find_reachable_imported_module_from(module_binding, module_name, visited)
          return found if found
        end

        nil
      end

      def find_reachable_imported_module_from(module_binding, module_name, visited)
        return nil unless module_binding
        return module_binding if module_binding.name == module_name
        return nil if visited[module_binding.name]

        visited[module_binding.name] = true
        module_binding.imports.each_value do |imported_module|
          found = find_reachable_imported_module_from(imported_module, module_name, visited)
          return found if found
        end

        nil
      end

      def specialization_lookup_owner
        return nil if @current_specialization_owner.nil?
        return nil if @current_specialization_owner.equal?(self)

        @current_specialization_owner
      end

      def resolve_interface_ref(interface_ref)
        parts = interface_ref.parts

        if parts.length == 1
          interface = @interfaces[parts.first]
          raise_sema_error("unknown interface #{parts.first}") unless interface

          return interface
        end

        if parts.length == 2 && @imports.key?(parts.first)
          imported_module = @imports.fetch(parts.first)
          interface = imported_module.interfaces[parts.last]
          if imported_module.private_interface?(parts.last)
            raise_sema_error("#{parts.first}.#{parts.last} is private to module #{imported_module.name}")
          end
          raise_sema_error("unknown interface #{interface_ref}") unless interface

          return interface
        end

        raise_sema_error("unknown interface #{interface_ref}")
      end

      def interface_implementation_key(type)
        return type.definition if type.is_a?(Types::StructInstance)

        type
      end

      def type_implements_interface?(type, interface)
        key = interface_implementation_key(type)
        return true if @implemented_interfaces.fetch(key, []).include?(interface)

        @imports.each_value do |module_binding|
          return true if module_binding.implemented_interfaces.fetch(key, []).include?(interface)
        end

        false
      end

      def type_satisfies_interface_constraint?(type, interface, available_type_param_constraints: current_type_param_constraints)
        if type.is_a?(Types::TypeVar)
          constraint = available_type_param_constraints[type.name]
          return constraint && constraint.interfaces.include?(interface)
        end

        type_implements_interface?(type, interface)
      end

      def validate_type_param_constraint_binding!(constraints, actual_type, context:, available_type_param_constraints: current_type_param_constraints)
        constraints.interfaces.each do |interface|
          next if type_satisfies_interface_constraint?(actual_type, interface, available_type_param_constraints:)

          raise_sema_error("type #{actual_type} does not implement interface #{interface.name} for #{context}")
        end
      end

      def validate_generic_type_param_constraints!(generic_type, arguments, context:, available_type_param_constraints: current_type_param_constraints)
        return if generic_type.type_param_constraints.empty?

        generic_type.type_params.zip(arguments).each do |name, actual_type|
          constraints = generic_type.type_param_constraints[name]
          next unless constraints

          validate_type_param_constraint_binding!(constraints, actual_type, context:, available_type_param_constraints:)
        end
      end

      def resolve_type_ref(type_ref, type_params: current_type_params, type_param_constraints: current_type_param_constraints)
        base = resolve_non_nullable_type(type_ref, type_params:, type_param_constraints:)
        return base if type_ref.is_a?(AST::FunctionType) || type_ref.is_a?(AST::ProcType)

        raise_sema_error("ref types are non-null and cannot be nullable", type_ref) if type_ref.nullable && ref_type?(base)

        type_ref.nullable ? Types::Nullable.new(base) : base
      end

      def resolve_non_nullable_type(type_ref, type_params: {}, type_param_constraints: {})
        if type_ref.is_a?(AST::FunctionType)
          params = type_ref.params.map do |param|
            Types::Parameter.new(param.name, resolve_type_ref(param.type, type_params:, type_param_constraints:))
          end
          return Types::Function.new(nil, params:, return_type: resolve_type_ref(type_ref.return_type, type_params:, type_param_constraints:))
        end

        if type_ref.is_a?(AST::ProcType)
          params = type_ref.params.map do |param|
            Types::Parameter.new(param.name, resolve_type_ref(param.type, type_params:, type_param_constraints:))
          end
          return Types::Proc.new(params:, return_type: resolve_type_ref(type_ref.return_type, type_params:, type_param_constraints:))
        end

        parts = type_ref.name.parts

        if type_ref.arguments.any?
          name = parts.join(".")
          arguments = type_ref.arguments.map { |argument| resolve_type_argument(argument.value, type_params:, type_param_constraints:) }

          if name != "ref" && arguments.any? { |argument| contains_ref_type?(argument) && !stored_ref_supported_type?(argument) }
            raise_sema_error("ref types cannot be nested inside #{name}", type_ref)
          end

          if name == "Task"
            validate_generic_type!(name, arguments)
            return Types::Task.new(arguments[0])
          end

          if (generic_type = resolve_named_generic_type(parts))
            begin
              validate_generic_type_param_constraints!(generic_type, arguments, context: "type #{generic_type}", available_type_param_constraints: type_param_constraints)
              return generic_type.instantiate(arguments)
            rescue ArgumentError => error
              raise_sema_error(error.message)
            end
          end

          validate_generic_type!(name, arguments)
          return Types::Span.new(arguments.first) if name == "span"

          return Types::SoA.new(arguments[0], count: arguments[1].value) if name == "SoA"

          return Types::GenericInstance.new(name, arguments)
        end

        if parts.length == 1
          return type_params.fetch(parts.first) if type_params.key?(parts.first)

          type = @types[parts.first]
          raise_sema_error("unknown type #{parts.first}", type_ref) unless type
          raise_sema_error("generic type #{parts.first} requires type arguments", type_ref) if type.is_a?(Types::GenericStructDefinition) || type.is_a?(Types::GenericVariantDefinition)

          return type
        end

        if parts.length == 2 && @imports.key?(parts.first)
          imported_module = @imports.fetch(parts.first)
          type = imported_module.types[parts.last]
          if imported_module.private_type?(parts.last)
            raise_sema_error("#{parts.first}.#{parts.last} is private to module #{imported_module.name}", type_ref)
          end
          raise_sema_error("unknown type #{type_ref.name}", type_ref) unless type
          raise_sema_error("generic type #{type_ref.name} requires type arguments", type_ref) if type.is_a?(Types::GenericStructDefinition) || type.is_a?(Types::GenericVariantDefinition)

          return type
        end

        raise_sema_error("unknown type #{type_ref.name}", type_ref)
      end

      def resolve_type_argument(argument, type_params: current_type_params, type_param_constraints: current_type_param_constraints)
        case argument
        when AST::TypeRef
          resolve_type_argument_ref(argument, type_params:, type_param_constraints:)
        when AST::FunctionType, AST::ProcType
          resolve_type_ref(argument, type_params:, type_param_constraints:)
        when AST::IntegerLiteral, AST::FloatLiteral
          Types::LiteralTypeArg.new(argument.value)
        else
          raise_sema_error("unsupported type argument #{argument.class.name}")
        end
      end

      def resolve_type_argument_ref(type_ref, type_params:, type_param_constraints:)
        return resolve_type_ref(type_ref, type_params:, type_param_constraints:) unless literal_type_argument_name_candidate?(type_ref)

        resolve_type_ref(type_ref, type_params:, type_param_constraints:)
      rescue SemaError => error
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
        binding = @top_level_values[name]
        return unless binding&.kind == :const

        evaluate_top_level_const_value(name)
      end

      def resolve_imported_module_const_value(import_name, value_name)
        imported_module = @imports[import_name]
        return unless imported_module
        if imported_module.private_value?(value_name)
          raise_sema_error("#{import_name}.#{value_name} is private to module #{imported_module.name}")
        end

        binding = imported_module.values[value_name]
        return unless binding&.kind == :const

        binding.const_value
      end

      def resolve_enum_member_const_value(receiver_type, member_name, local_enum_type: nil, local_member_values: nil)
        return unless receiver_type.is_a?(Types::EnumBase)
        return unless receiver_type.member(member_name)

        if local_enum_type && receiver_type == local_enum_type && local_member_values&.key?(member_name)
          return local_member_values[member_name]
        end

        receiver_type.member_value(member_name)
      end

      def ensure_assignable!(actual_type, expected_type, message, expression: nil, scopes: nil, external_numeric: false, external_pointer_null: false, contextual_int_to_float: false, line: nil, column: nil)
        line ||= source_line(expression)
        column ||= source_column(expression)

        raise SemaError.new(message, line:, column:, path: @path) unless types_compatible?(actual_type, expected_type, expression:, scopes:, external_numeric:, external_pointer_null:, contextual_int_to_float:)
      end

      def ensure_argument_assignable!(actual_type, expected_type, external:, message:, expression: nil, scopes: nil)
        line = source_line(expression)
        column = source_column(expression)
        raise SemaError.new(message, line:, column:, path: @path) unless argument_types_compatible?(actual_type, expected_type, external:, expression:, scopes:)
      end

      def with_error_node(node)
        @error_node_stack << node
        yield
      ensure
        @error_node_stack.pop
      end

      def with_return_context(return_type, allow_return:)
        @return_context_stack << { return_type:, allow_return: }
        yield
      ensure
        @return_context_stack.pop
      end

      def current_return_context
        @return_context_stack.last
      end

      def current_error_node
        @error_node_stack.reverse_each.find { |node| !node.nil? }
      end

      def raise_sema_error(message, node = nil, line: nil, column: nil, length: nil)
        target = node || current_error_node
        line ||= source_line(target)
        column ||= source_column(target)
        length ||= source_length(target)
        raise SemaError.new(message, line:, column:, length:, path: @path)
      end

      def source_line(node)
        return nil unless node
        return node.line if node.respond_to?(:line) && node.line

        case node
        when AST::MemberAccess then source_line(node.receiver)
        when AST::IndexAccess then source_line(node.receiver) || source_line(node.index)
        when AST::Specialization then source_line(node.callee)
        when AST::Call then source_line(node.callee) || node.arguments.filter_map { |argument| source_line(argument.value) }.first
        when AST::Argument then source_line(node.value)
        when AST::UnaryOp then source_line(node.operand)
        when AST::BinaryOp then source_line(node.left) || source_line(node.right)
        when AST::IfExpr then source_line(node.condition) || source_line(node.then_expression) || source_line(node.else_expression)
        when AST::MatchExpr then source_line(node.expression) || node.arms.filter_map { |arm| source_line(arm.pattern) || source_line(arm.value) }.first
        when AST::AwaitExpr then source_line(node.expression)
        when AST::FormatExprPart then source_line(node.expression)
        else nil
        end
      end

      def source_length(node)
        return nil unless node
        return node.length if node.respond_to?(:length) && node.length
        return node.name.to_s.length if node.respond_to?(:name) && node.name

        case node
        when AST::Identifier then node.name.to_s.length
        when AST::MemberAccess then node.member.to_s.length
        when AST::Assignment then source_length(node.target) || source_length(node.value)
        when AST::ExpressionStmt then source_length(node.expression)
        when AST::StaticAssert then source_length(node.condition)
        when AST::IfStmt
          node.branches.filter_map { |branch| branch.length || source_length(branch.condition) }.first
        else
          nil
        end
      end

      def source_column(node)
        return nil unless node
        return node.column if node.respond_to?(:column) && node.column

        case node
        when AST::MemberAccess then source_column(node.receiver)
        when AST::IndexAccess then source_column(node.receiver) || source_column(node.index)
        when AST::Specialization then source_column(node.callee)
        when AST::Call then source_column(node.callee) || node.arguments.filter_map { |argument| source_column(argument.value) }.first
        when AST::Argument then source_column(node.value)
        when AST::UnaryOp then source_column(node.operand)
        when AST::BinaryOp then source_column(node.left) || source_column(node.right)
        when AST::IfExpr then source_column(node.condition) || source_column(node.then_expression) || source_column(node.else_expression)
        when AST::MatchExpr then source_column(node.expression) || node.arms.filter_map { |arm| source_column(arm.pattern) || source_column(arm.value) }.first
        when AST::AwaitExpr then source_column(node.expression)
        when AST::FormatExprPart then source_column(node.expression)
        when AST::Assignment then source_column(node.target) || source_column(node.value)
        when AST::ExpressionStmt then source_column(node.expression)
        when AST::StaticAssert then source_column(node.condition)
        when AST::IfStmt then node.branches.filter_map { |branch| branch.column || source_column(branch.condition) }.first || node.else_column
        else nil
        end
      end


      def span_type?(type)
        type.is_a?(Types::Span)
      end

      def string_view_type?(type)
        type.is_a?(Types::StringView)
      end

      def infer_layout_query_type(type_ref, context:)
        type = resolve_type_ref(type_ref)
        return type if sized_layout_type?(type)

        raise_sema_error("#{context} requires a concrete sized type, got #{type}")
      end

      def infer_offsetof_type(type_ref, field_name)
        type = resolve_type_ref(type_ref)
        unless layout_aggregate_type?(type)
          raise_sema_error("offset_of requires a struct, union, span, or str type, got #{type}")
        end

        field_type = type.field(field_name)
        raise_sema_error("unknown field #{type}.#{field_name}") unless field_type

        type
      end

      def sized_layout_type?(type)
        case type
        when Types::Primitive, Types::Struct, Types::StructInstance, Types::Union, Types::Enum, Types::Flags, Types::Variant, Types::Span, Types::StringView, Types::Task, Types::Event, Types::Subscription
          true
        when Types::Nullable
          true
        when Types::GenericInstance
          pointer_type?(type) || array_type?(type) || str_buffer_type?(type)
        else
          false
        end
      end

      def reinterpretable_type?(type)
        return false if array_type?(type)
        return false if type.is_a?(Types::Primitive) && type.void?

        sized_layout_type?(type)
      end

      def zero_initializable_type?(type, operation: "zero")
        return true if type.is_a?(Types::Primitive) && !type.void?
        return true if type.is_a?(Types::Nullable)
        return true if type.is_a?(Types::EnumBase)
        return true if span_type?(type)
        return true if string_view_type?(type)
        return true if task_type?(type)
        return true if event_type?(type)
        return true if subscription_type?(type)
        return true if type.is_a?(Types::Struct)
        return true if type.is_a?(Types::Variant)
        return true if pointer_type?(type)
        return true if type.is_a?(Types::Opaque) && !type.external
        return true if array_type?(type)
        return true if str_buffer_type?(type)
        return true if vector_type?(type)
        return true if matrix_type?(type)
        return true if quaternion_type?(type)
        return true if soa_type?(type)

        raise_sema_error("#{operation} does not support type #{type}")
      end

      def layout_aggregate_type?(type)
        type.respond_to?(:field) && !type.is_a?(Types::Opaque) && !type.is_a?(Types::EnumBase)
      end

      def power_of_two?(value)
        (value & (value - 1)).zero?
      end

      def aggregate_type?(type)
        type.is_a?(Types::Struct) || span_type?(type) || string_view_type?(type) || task_type?(type) || vector_type?(type) || matrix_type?(type) || quaternion_type?(type)
      end

      def vector_type?(type)
        type.is_a?(Types::Vector)
      end

      def matrix_type?(type)
        type.is_a?(Types::Matrix)
      end

      def quaternion_type?(type)
        type.is_a?(Types::Quaternion)
      end

      def soa_type?(type)
        type.is_a?(Types::SoA)
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

      def char_array_text_type?(type)
        array_type?(type) && array_element_type(type) == @types.fetch("char")
      end

      def str_buffer_type?(type)
        type.is_a?(Types::GenericInstance) && type.name == "str_buffer" && type.arguments.length == 1 &&
          generic_integer_type_argument?(type.arguments.first)
      end

      def event_type?(type)
        type.is_a?(Types::Event)
      end

      def subscription_type?(type)
        type.is_a?(Types::Subscription)
      end

      def event_carrier_type?(type)
        case type
        when Types::StructInstance
          type.definition.respond_to?(:has_events?) && type.definition.has_events?
        when Types::Struct
          type.respond_to?(:has_events?) && type.has_events?
        else
          false
        end
      end

      def noncopyable_event_storage_type?(type)
        event_type?(type) || event_carrier_type?(type)
      end

      def str_buffer_capacity(type)
        type.arguments.first.value
      end

      def integer_type_argument?(argument)
        argument.is_a?(Types::LiteralTypeArg) && argument.value.is_a?(Integer)
      end

      def generic_integer_type_argument?(argument)
        integer_type_argument?(argument) || argument.is_a?(Types::TypeVar)
      end

      def pointer_to(type)
        Types::GenericInstance.new("ptr", [type])
      end

      def contains_type_var?(type)
        case type
        when Types::TypeVar
          true
        when Types::Nullable
          contains_type_var?(type.base)
        when Types::GenericInstance
          type.arguments.any? { |argument| !argument.is_a?(Types::LiteralTypeArg) && contains_type_var?(argument) }
        when Types::Span
          contains_type_var?(type.element_type)
        when Types::Task
          contains_type_var?(type.result_type)
        when Types::StructInstance
          type.arguments.any? { |argument| contains_type_var?(argument) }
        when Types::VariantInstance
          type.arguments.any? { |argument| contains_type_var?(argument) }
        when Types::Proc
          type.params.any? { |param| contains_type_var?(param.type) } || contains_type_var?(type.return_type)
        when Types::Function
          type.params.any? { |param| contains_type_var?(param.type) } ||
            contains_type_var?(type.return_type) ||
            (type.receiver_type && contains_type_var?(type.receiver_type))
        else
          false
        end
      end

      def resolve_named_generic_type(parts)
        if parts.length == 1
          type = @types[parts.first]
          return type if type.is_a?(Types::GenericStructDefinition) || type.is_a?(Types::GenericVariantDefinition)
        elsif parts.length == 2 && @imports.key?(parts.first)
          type = @imports.fetch(parts.first).types[parts.last]
          return type if type.is_a?(Types::GenericStructDefinition) || type.is_a?(Types::GenericVariantDefinition)
        end

        nil
      end

      BUILTIN_VALUE_SPECIALIZATIONS = %w[zero default reinterpret cast].freeze

      def type_ref_from_specialization(expression)
        case expression.callee
        when AST::Identifier
          return nil if BUILTIN_VALUE_SPECIALIZATIONS.include?(expression.callee.name)

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
          raise_sema_error("ptr requires exactly one type argument") unless arguments.length == 1
          raise_sema_error("ptr type argument must be a type") if arguments.first.is_a?(Types::LiteralTypeArg)
        when "const_ptr"
          raise_sema_error("const_ptr requires exactly one type argument") unless arguments.length == 1
          raise_sema_error("const_ptr type argument must be a type") if arguments.first.is_a?(Types::LiteralTypeArg)
          raise_sema_error("const_ptr cannot target ref types") if contains_ref_type?(arguments.first)
        when "ref"
          raise_sema_error("ref requires exactly one type argument") unless arguments.length == 1
          raise_sema_error("ref type argument must be a type") if arguments.first.is_a?(Types::LiteralTypeArg)
          raise_sema_error("ref cannot target void") if arguments.first.is_a?(Types::Primitive) && arguments.first.void?
          raise_sema_error("ref cannot target another ref type") if contains_ref_type?(arguments.first)
        when "span"
          raise_sema_error("span requires exactly one type argument") unless arguments.length == 1
          raise_sema_error("span element type must be a type") if arguments.first.is_a?(Types::LiteralTypeArg)
        when "array"
          raise_sema_error("array requires exactly two type arguments") unless arguments.length == 2
          raise_sema_error("array element type must be a type") if arguments.first.is_a?(Types::LiteralTypeArg)
          raise_sema_error("array length must be an integer literal, named const, or type parameter") unless generic_integer_type_argument?(arguments[1])
          raise_sema_error("array length must be positive") if integer_type_argument?(arguments[1]) && !arguments[1].value.positive?
        when "SoA"
          raise_sema_error("SoA requires exactly two type arguments") unless arguments.length == 2
          raise_sema_error("SoA element type must be a type") if arguments.first.is_a?(Types::LiteralTypeArg)
          raise_sema_error("SoA element type must be a struct with fields") unless arguments.first.respond_to?(:fields) && arguments.first.fields.any?
          raise_sema_error("SoA length must be an integer literal, named const, or type parameter") unless generic_integer_type_argument?(arguments[1])
          raise_sema_error("SoA length must be positive") if integer_type_argument?(arguments[1]) && !arguments[1].value.positive?
        when "str_buffer"
          raise_sema_error("str_buffer requires exactly one type argument") unless arguments.length == 1
          raise_sema_error("str_buffer capacity must be an integer literal, named const, or type parameter") unless generic_integer_type_argument?(arguments.first)
          raise_sema_error("str_buffer capacity must be positive") if integer_type_argument?(arguments.first) && !arguments.first.value.positive?
        when "Task"
          raise_sema_error("Task requires exactly one type argument") unless arguments.length == 1
          raise_sema_error("Task result type must be a type") if arguments.first.is_a?(Types::LiteralTypeArg)
        else
          raise_sema_error("unknown generic type #{name}")
        end
      end

      def integer_type?(type)
        type.is_a?(Types::Primitive) && type.integer?
      end

      def collection_loop_type(type)
        return array_element_type(type) if array_type?(type)
        return type.element_type if span_type?(type)

        nil
      end

      def collection_loop_binding_type(iterable_type, element_type)
        return nil unless array_type?(iterable_type) || span_type?(iterable_type)
        return nil unless collection_loop_ref_element_type?(element_type)

        Types::GenericInstance.new("ref", [element_type])
      end

      def collection_loop_ref_element_type?(type)
        type.is_a?(Types::Struct)
      end

      def iterator_loop_type(type)
        type = referenced_type(type) if ref_type?(type)
        iter_method = lookup_method(type, "iter")
        return nil unless iter_method

        iter_method = instantiate_function_binding_with_receiver(iter_method, [], receiver_type: type) if iter_method.type_params.any?

        unless iter_method.type.params.empty?
          raise_sema_error("for iterator #{type}.iter expects 0 arguments")
        end
        if iter_method.type.receiver_editable
          raise_sema_error("for iterator #{type}.iter cannot be an editable method")
        end

        iterator_type = iter_method.type.return_type
        next_method = lookup_method(iterator_type, "next")
        raise_sema_error("for iterator #{iterator_type} must define next()") unless next_method
        next_method = instantiate_function_binding_with_receiver(next_method, [], receiver_type: iterator_type) if next_method.type_params.any?
        unless next_method.type.params.empty?
          raise_sema_error("for iterator #{iterator_type}.next expects 0 arguments")
        end

        next_type = next_method.type.return_type
        if next_type.is_a?(Types::Nullable) && typed_null_target_type?(next_type.base)
          return next_type.base
        end

        if next_type == @types.fetch("bool")
          current_method = lookup_method(iterator_type, "current")
          raise_sema_error("for iterator #{iterator_type} must define current() when next() returns bool") unless current_method
          current_method = instantiate_function_binding_with_receiver(current_method, [], receiver_type: iterator_type) if current_method.type_params.any?
          unless current_method.type.params.empty?
            raise_sema_error("for iterator #{iterator_type}.current expects 0 arguments")
          end
          raise_sema_error("for iterator #{iterator_type}.current cannot return void") if current_method.type.return_type == @types.fetch("void")

          return current_method.type.return_type
        end

        raise_sema_error("for iterator #{iterator_type}.next must return bool or a nullable pointer-like item, got #{next_type}")
      end

      def string_like_type?(type)
        type == @types.fetch("str") || type == @types.fetch("cstr")
      end

      def infer_index_result_type(receiver_type, index_type)
        raise_sema_error("index must be an integer type, got #{index_type}") unless integer_type?(index_type)

        if array_type?(receiver_type)
          return array_element_type(receiver_type)
        end

        if span_type?(receiver_type)
          return receiver_type.element_type
        end

        if soa_type?(receiver_type)
          return receiver_type.element_type
        end

        if pointer_type?(receiver_type)
          require_unsafe!("pointer indexing requires unsafe")

          return pointee_type(receiver_type)
        end

        raise_sema_error("cannot index #{receiver_type}")
      end

      def addressable_storage_expression?(expression, scopes:)
        case expression
        when AST::Identifier
          true
        when AST::MemberAccess, AST::IndexAccess
          addressable_storage_expression?(expression.receiver, scopes:)
        when AST::Call
          return false unless expression.arguments.length == 1 && expression.arguments.first.name.nil?

          read_call?(expression) && ref_type?(infer_expression(expression.arguments.first.value, scopes:))
        else
          false
        end
      end

      def match_member_name(expression, enum_type)
        return unless expression.is_a?(AST::MemberAccess)

        receiver_type = resolve_type_expression(expression.receiver)
        return unless receiver_type == enum_type
        return expression.member if enum_type.member(expression.member)

        nil
      end

      def resolve_type_expression(expression)
        case expression
        when AST::Identifier
          return current_type_params[expression.name] if current_type_params.key?(expression.name)

          @types[expression.name]
        when AST::MemberAccess
          return nil unless expression.receiver.is_a?(AST::Identifier)
          return nil unless @imports.key?(expression.receiver.name)

          imported_module = @imports.fetch(expression.receiver.name)
          if imported_module.private_type?(expression.member)
            raise_sema_error("#{expression.receiver.name}.#{expression.member} is private to module #{imported_module.name}")
          end

          imported_module.types[expression.member]
        when AST::Specialization
          type_ref = type_ref_from_specialization(expression)
          return nil unless type_ref

          resolve_type_ref(type_ref)
        end
      end

      def imported_module_with_private_method(receiver_type, method_name)
        imported_module = imported_module_with_private_method_local(receiver_type, method_name)
        return imported_module if imported_module

        fallback_owner = specialization_lookup_owner
        return nil unless fallback_owner

        fallback_owner.send(:imported_module_with_private_method_local, receiver_type, method_name)
      end

      def imported_module_with_private_method_local(receiver_type, method_name)
        @imports.each_value do |module_binding|
          return module_binding if module_binding.private_method?(receiver_type, method_name)
        end

        nil
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

      def resolve_methods_receiver_target(type_ref)
        if type_ref.is_a?(AST::TypeRef)
          generic_type = resolve_named_generic_type(type_ref.name.parts)
          if generic_type.is_a?(Types::GenericStructDefinition)
            receiver_type_param_names = validate_methods_receiver_type_arguments!(type_ref, generic_type)
            receiver_type_params = receiver_type_param_names.to_h { |name| [name, Types::TypeVar.new(name)] }
            receiver_type_param_constraints = generic_type.type_param_constraints
            receiver_type = resolve_type_ref(type_ref, type_params: receiver_type_params, type_param_constraints: receiver_type_param_constraints)
            return [generic_type, receiver_type, receiver_type_param_names, receiver_type_param_constraints]
          end

          begin
            receiver_type = resolve_type_ref(type_ref)
            unless receiver_type.is_a?(Types::Struct) || receiver_type.is_a?(Types::StructInstance) || receiver_type.is_a?(Types::Opaque) || receiver_type.is_a?(Types::GenericInstance) || receiver_type.is_a?(Types::Nullable) || receiver_type.is_a?(Types::StringView) || vector_type?(receiver_type) || matrix_type?(receiver_type) || quaternion_type?(receiver_type)
              raise_sema_error("extending target #{type_ref} must be a struct, opaque, nullable/generic receiver, or str")
            end

            return [receiver_type, receiver_type, [], {}]
          rescue MilkTea::SemaError => error
            receiver_type_param_names = methods_receiver_type_argument_names!(type_ref)
            raise error if receiver_type_param_names.empty?

            receiver_type_params = receiver_type_param_names.to_h { |name| [name, Types::TypeVar.new(name)] }
            receiver_type = resolve_type_ref(type_ref, type_params: receiver_type_params)
            return [method_dispatch_receiver_type(receiver_type), receiver_type, receiver_type_param_names, {}]
          end
        end

        receiver_type = resolve_type_ref(type_ref)
        unless receiver_type.is_a?(Types::Struct) || receiver_type.is_a?(Types::StructInstance) || receiver_type.is_a?(Types::Opaque) || receiver_type.is_a?(Types::GenericInstance) || receiver_type.is_a?(Types::Nullable) || receiver_type.is_a?(Types::StringView) || vector_type?(receiver_type) || matrix_type?(receiver_type) || quaternion_type?(receiver_type)
          raise_sema_error("extending target #{type_ref} must be a struct, opaque, nullable/generic receiver, or str")
        end

        [receiver_type, receiver_type, [], {}]
      end

      def methods_receiver_type_argument_names!(type_ref)
        names = type_ref.arguments.map do |argument|
          value = argument.value
          next unless value.is_a?(AST::TypeRef)
          next unless value.arguments.empty? && !value.nullable && value.name.parts.length == 1

          value.name.parts.first
        end

        raise_sema_error("extending target #{type_ref} must use the receiver type parameters directly") if names.any?(&:nil?)

        names
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
          raise_sema_error("extending target #{type_ref} must use the receiver type parameters directly")
        end

        expected_names
      end

      def infer_receiver_type_substitutions(binding, receiver_type)
        declared_receiver_type = binding.declared_receiver_type
        return {} unless declared_receiver_type
        case declared_receiver_type
        when Types::Nullable
          unless receiver_type.is_a?(Types::Nullable)
            raise_sema_error("cannot use method #{binding.name} with receiver #{receiver_type}")
          end

          infer_receiver_type_substitutions(
            binding.with(declared_receiver_type: declared_receiver_type.base),
            receiver_type.base,
          )
        when Types::StructInstance
          return {} unless declared_receiver_type.definition.is_a?(Types::GenericStructDefinition)

          unless receiver_type.is_a?(Types::StructInstance) && receiver_type.definition == declared_receiver_type.definition
            raise_sema_error("cannot use method #{binding.name} with receiver #{receiver_type}")
          end

          declared_receiver_type.definition.type_params.zip(receiver_type.arguments).to_h
        when Types::GenericInstance
          unless receiver_type.is_a?(Types::GenericInstance) && receiver_type.name == declared_receiver_type.name && receiver_type.arguments.length == declared_receiver_type.arguments.length
            raise_sema_error("cannot use method #{binding.name} with receiver #{receiver_type}")
          end

          declared_receiver_type.arguments.zip(receiver_type.arguments).each_with_object({}) do |(declared_argument, actual_argument), substitutions|
            if declared_argument.is_a?(Types::TypeVar)
              substitutions[declared_argument.name] = actual_argument
            elsif declared_argument != actual_argument
              raise_sema_error("cannot use method #{binding.name} with receiver #{receiver_type}")
            end
          end
        else
          {}
        end
      end

      def callable_receiver_type_for_specialization(callee, scopes:)
        return unless callee.is_a?(AST::MemberAccess)

        resolve_type_expression(callee.receiver)
      end

      def resolve_type_member(type, name)
        case type
        when Types::Enum, Types::Flags
          type.member(name)
        when Types::Variant
          # No-payload arms: return the variant type so they can be used as expressions
          # Payload arms: return nil here — callers use resolve_callable(:variant_arm_ctor) instead
          return type if type.arm_names.include?(name) && !type.has_payload?(name)

          nil
        end
      end

      def function_type_for_name(name)
        @top_level_functions.fetch(name).type
      end

      def resolve_specialized_callable_binding(expression, scopes:)
        callable_kind = :function
        receiver = nil
        receiver_type = nil
        binding = case expression.callee
                  when AST::Identifier
                    @top_level_functions[expression.callee.name]
                  when AST::MemberAccess
                    if expression.callee.receiver.is_a?(AST::Identifier) && @imports.key?(expression.callee.receiver.name)
                      imported_module = @imports.fetch(expression.callee.receiver.name)
                      imported_function = imported_module.functions[expression.callee.member]
                      if imported_function.nil? && imported_module.private_function?(expression.callee.member)
                        raise_sema_error("#{expression.callee.receiver.name}.#{expression.callee.member} is private to module #{imported_module.name}")
                      end

                      imported_function
                    elsif (type_expr = resolve_type_expression(expression.callee.receiver))
                      associated_function = lookup_method(type_expr, expression.callee.member)
                      if associated_function&.type&.receiver_type.nil?
                        receiver_type = type_expr
                        associated_function
                      else
                        if (imported_module = imported_module_with_private_method(type_expr, expression.callee.member))
                          raise_sema_error("#{type_expr}.#{expression.callee.member} is private to module #{imported_module.name}")
                        end

                        nil
                      end
                    else
                      receiver_type = infer_method_receiver_type(expression.callee.receiver, scopes:, member_name: expression.callee.member)
                      method = lookup_method(receiver_type, expression.callee.member)
                      if method
                        callable_kind = :method
                        receiver = expression.callee.receiver
                        method
                      else
                        if (imported_module = imported_module_with_private_method(receiver_type, expression.callee.member))
                          raise_sema_error("#{receiver_type}.#{expression.callee.member} is private to module #{imported_module.name}")
                        end

                        nil
                      end
                    end
                  end
        return nil unless binding

        type_arguments = resolve_specialization_type_arguments(expression)
        [callable_kind, instantiate_function_binding_with_receiver(binding, type_arguments, receiver_type:), receiver]
      end

      def resolve_specialization_type_arguments(expression)
        expression.arguments.map do |argument|
          resolve_type_argument(argument.value, type_params: current_type_params)
        end
      end

      def specialize_function_binding(binding, arguments, scopes:, receiver_type: nil)
        return binding if binding.type_params.empty?

        type_arguments = infer_function_type_arguments(binding, arguments, scopes:, receiver_type:)
        instantiate_function_binding(binding, type_arguments)
      end

      def instantiate_function_binding_with_receiver(binding, explicit_type_arguments, receiver_type: nil)
        if binding.type_params.empty?
          raise_sema_error("function #{binding.name} is not generic and cannot be specialized")
        end

        receiver_substitutions = infer_receiver_type_substitutions(binding, receiver_type)
        remaining_type_params = binding.type_params.reject { |name| receiver_substitutions.key?(name) }
        unless remaining_type_params.length == explicit_type_arguments.length
          raise_sema_error("function #{binding.name} expects #{remaining_type_params.length} type arguments, got #{explicit_type_arguments.length}")
        end

        substitutions = receiver_substitutions.dup
        remaining_type_params.zip(explicit_type_arguments).each do |name, type_argument|
          raise_sema_error("generic function #{binding.name} cannot be instantiated with ref types") if contains_ref_type?(type_argument)

          substitutions[name] = type_argument
        end

        type_arguments = binding.type_params.map do |name|
          inferred = substitutions[name]
          raise_sema_error("cannot infer type argument #{name} for function #{binding.name}") unless inferred

          inferred
        end

        instantiate_function_binding(binding, type_arguments)
      end

      def instantiate_function_binding(binding, type_arguments)
        if binding.type_params.empty?
          raise_sema_error("function #{binding.name} is not generic and cannot be specialized")
        end

        unless binding.type_params.length == type_arguments.length
          raise_sema_error("function #{binding.name} expects #{binding.type_params.length} type arguments, got #{type_arguments.length}")
        end

        if type_arguments.any? { |type_argument| contains_ref_type?(type_argument) }
          raise_sema_error("generic function #{binding.name} cannot be instantiated with ref types")
        end

        key = type_arguments.freeze
        return binding.instances.fetch(key) if binding.instances.key?(key)

        substitutions = binding.type_params.zip(type_arguments).to_h
        validate_function_type_param_constraints!(binding, substitutions)
        type = substitute_type(binding.type, substitutions)
        body_params = binding.body_params.map { |param| substitute_value_binding(param, substitutions) }
        validate_specialized_function_binding!(binding.name, type, body_params)

        instance = FunctionBinding.new(
          name: binding.name,
          type:,
          body_params:,
          body_return_type: substitute_type(binding.body_return_type, substitutions),
          ast: binding.ast,
          external: binding.external,
          async: binding.async,
          type_params: [].freeze,
          type_param_constraints: {}.freeze,
          instances: {},
          type_arguments: key,
          owner: binding.owner,
          specialization_owner: @current_specialization_owner || (binding.owner == self ? nil : self),
          type_substitutions: substitutions.freeze,
          declared_receiver_type: binding.declared_receiver_type ? substitute_type(binding.declared_receiver_type, substitutions) : nil,
        )
        binding.instances[key] = instance
      end

      def validate_function_type_param_constraints!(binding, substitutions)
        binding.type_param_constraints.each do |name, constraints|
          actual_type = substitutions[name]
          raise_sema_error("cannot infer type argument #{name} for function #{binding.name}") unless actual_type

          validate_type_param_constraint_binding!(constraints, actual_type, context: "function #{binding.name}")
        end
      end

      def infer_function_type_arguments(binding, arguments, scopes:, receiver_type: nil)
        expected_params = binding.type.params
        unless call_arity_matches?(binding.type, arguments.length)
          raise_sema_error(arity_error_message(binding.type, binding.name, arguments.length))
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
          actual_type = foreign_argument_actual_type(parameter, argument, scopes:, function_name: binding.name, expected_type: expected_argument_type)
          collect_type_substitutions(parameter.type, actual_type, substitutions, binding.name)
        end

        binding.type_params.map do |name|
          inferred = substitutions[name]
          raise_sema_error("cannot infer type argument #{name} for function #{binding.name}") unless inferred

          raise_sema_error("generic function #{binding.name} cannot be instantiated with ref types") if contains_ref_type?(inferred)

          inferred
        end
      end

      def collect_type_substitutions(pattern_type, actual_type, substitutions, function_name)
        case pattern_type
        when Types::TypeVar
          existing = substitutions[pattern_type.name]
          if existing && existing != actual_type
            raise_sema_error("conflicting type argument #{pattern_type.name} for function #{function_name}: got #{existing} and #{actual_type}")
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

      def validate_specialized_function_binding!(function_name, function_type, body_params)
        function_type.params.each do |param|
          validate_specialized_function_type!(param.type, function_name:, context: "parameter #{param.name}")
          validate_specialized_function_type!(param.boundary_type, function_name:, context: "boundary parameter #{param.name}") if param.boundary_type
        end
        validate_specialized_function_type!(function_type.return_type, function_name:, context: "return type")
        validate_specialized_function_type!(function_type.receiver_type, function_name:, context: "receiver type") if function_type.receiver_type

        body_params.each do |param|
          validate_specialized_function_type!(param.type, function_name:, context: "body parameter #{param.name}")
        end
      end

      def validate_specialized_function_type!(type, function_name:, context:)
        case type
        when nil, Types::Primitive, Types::Enum, Types::Flags, Types::Opaque, Types::Struct
          nil
        when Types::LiteralTypeArg
          raise_sema_error("#{context} of function #{function_name} must be a type, got #{type}")
        when Types::TypeVar
          raise_sema_error("cannot infer type argument #{type.name} for function #{function_name}")
        when Types::Nullable
          validate_specialized_function_type!(type.base, function_name:, context:)
        when Types::GenericInstance
          validate_generic_type!(type.name, type.arguments)
          type.arguments.each do |argument|
            next if argument.is_a?(Types::LiteralTypeArg)

            validate_specialized_function_type!(argument, function_name:, context:)
          end
        when Types::Span
          validate_specialized_function_type!(type.element_type, function_name:, context:)
        when Types::Task
          validate_specialized_function_type!(type.result_type, function_name:, context:)
        when Types::Proc
          type.params.each do |param|
            validate_specialized_function_type!(param.type, function_name:, context: "#{context} parameter #{param.name}")
          end
          validate_specialized_function_type!(type.return_type, function_name:, context: "#{context} return type")
        when Types::StructInstance
          type.arguments.each do |argument|
            next if argument.is_a?(Types::LiteralTypeArg)

            validate_specialized_function_type!(argument, function_name:, context:)
          end
        when Types::Function
          type.params.each do |param|
            validate_specialized_function_type!(param.type, function_name:, context: "#{context} parameter #{param.name}")
            validate_specialized_function_type!(param.boundary_type, function_name:, context: "#{context} boundary parameter #{param.name}") if param.boundary_type
          end
          validate_specialized_function_type!(type.return_type, function_name:, context: "#{context} return type")
          validate_specialized_function_type!(type.receiver_type, function_name:, context: "#{context} receiver type") if type.receiver_type
        end
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
        when Types::VariantInstance
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

      def bitwise_type?(type)
        type.respond_to?(:bitwise?) && type.bitwise?
      end

      def callable_type?(type)
        type.is_a?(Types::Function) || type.is_a?(Types::Proc)
      end

      def proc_type_compatible?(actual_type, expected_type)
        return true unless expected_type
        return actual_type == expected_type if proc_type?(expected_type)

        false
      end

      def proc_expression_allowed?
        @proc_expression_depth.positive?
      end

      def with_proc_expression
        @proc_expression_depth += 1
        yield
      ensure
        @proc_expression_depth -= 1
      end

      def freeze_scope_bindings(scope)
        frozen_scope = scope.is_a?(FlowScope) ? FlowScope.new : {}
        scope.each do |name, binding|
          frozen_scope[name] = ValueBinding.new(
            id: binding.id,
            name: binding.name,
            storage_type: binding.storage_type,
            flow_type: binding.flow_type,
            mutable: false,
            kind: binding.kind,
            const_value: binding.const_value,
          )
        end
        frozen_scope
      end

      def validate_stored_ref_type!(type, context)
        return unless contains_ref_type?(type)
        return if stored_ref_supported_type?(type)

        if callable_type?(type) || contains_callable_ref_type?(type)
          raise_sema_error("#{context} cannot store ref types outside callable parameter positions")
        end

        raise_sema_error("#{context} cannot store ref types")
      end

      def stored_ref_supported_type?(type, visited = {})
        return true unless type

        visit_key = [type.class, type.object_id]
        return true if visited[visit_key]

        visited[visit_key] = true
        case type
        when Types::Nullable
          stored_ref_supported_type?(type.base, visited)
        when Types::GenericInstance
          return false if ref_type?(type)

          type.arguments.all? { |argument| argument.is_a?(Types::LiteralTypeArg) || stored_ref_supported_type?(argument, visited) }
        when Types::Span
          stored_ref_supported_type?(type.element_type, visited)
        when Types::Task
          stored_ref_supported_type?(type.result_type, visited)
        when Types::Struct, Types::Union
          type.fields.each_value.all? { |field_type| stored_ref_supported_type?(field_type, visited) }
        when Types::StructInstance, Types::VariantInstance
          type.arguments.all? { |argument| stored_ref_supported_type?(argument, visited) }
        when Types::Variant
          type.arm_names.all? { |arm_name| type.arm(arm_name).each_value.all? { |field_type| stored_ref_supported_type?(field_type, visited) } }
        when Types::Proc, Types::Function
          callable_param_ref_supported?(type)
        else
          !contains_ref_type?(type)
        end
      end

      def contains_callable_ref_type?(type, visited = {})
        return false unless type

        visit_key = [type.class, type.object_id]
        return false if visited[visit_key]

        visited[visit_key] = true
        case type
        when Types::Nullable
          contains_callable_ref_type?(type.base, visited)
        when Types::GenericInstance
          type.arguments.any? { |argument| !argument.is_a?(Types::LiteralTypeArg) && contains_callable_ref_type?(argument, visited) }
        when Types::Span
          contains_callable_ref_type?(type.element_type, visited)
        when Types::Task
          contains_callable_ref_type?(type.result_type, visited)
        when Types::Struct, Types::Union
          type.fields.each_value.any? { |field_type| contains_callable_ref_type?(field_type, visited) }
        when Types::StructInstance, Types::VariantInstance
          type.arguments.any? { |argument| contains_callable_ref_type?(argument, visited) }
        when Types::Variant
          type.arm_names.any? { |arm_name| type.arm(arm_name).each_value.any? { |field_type| contains_callable_ref_type?(field_type, visited) } }
        when Types::Proc, Types::Function
          contains_ref_type?(type)
        else
          false
        end
      end

      def contains_proc_type?(type, visited = {})
        return false unless type

        visit_key = [type.class, type.object_id]
        return false if visited[visit_key]

        visited[visit_key] = true
        case type
        when Types::Nullable
          contains_proc_type?(type.base, visited)
        when Types::GenericInstance
          if type.name == "array" && type.arguments.first && !type.arguments.first.is_a?(Types::LiteralTypeArg)
            contains_proc_type?(type.arguments.first, visited)
          else
            false
          end
        when Types::Span
          contains_proc_type?(type.element_type, visited)
        when Types::Task
          contains_proc_type?(type.result_type, visited)
        when Types::StructInstance
          type.arguments.any? { |argument| contains_proc_type?(argument, visited) }
        when Types::Struct, Types::Union
          type.fields.each_value.any? { |field_type| contains_proc_type?(field_type, visited) }
        when Types::Variant
          type.arm_names.any? { |arm_name| type.arm(arm_name).each_value.any? { |field_type| contains_proc_type?(field_type, visited) } }
        when Types::Proc
          true
        when Types::Function
          type.params.any? { |param| contains_proc_type?(param.type, visited) } ||
            contains_proc_type?(type.return_type, visited) ||
            (type.receiver_type && contains_proc_type?(type.receiver_type, visited))
        else
          false
        end
      end

      def proc_storage_supported_type?(type, visited = {})
        return true unless contains_proc_type?(type)

        visit_key = [type.class, type.object_id]
        return true if visited[visit_key]

        visited[visit_key] = true
        case type
        when Types::Proc
          true
        when Types::GenericInstance
          type.arguments.all? { |argument| argument.is_a?(Types::LiteralTypeArg) || proc_storage_supported_type?(argument, visited) }
        when Types::Struct
          type.fields.each_value.all? { |field_type| proc_storage_supported_type?(field_type, visited) }
        when Types::StructInstance, Types::VariantInstance
          type.arguments.all? { |argument| argument.is_a?(Types::LiteralTypeArg) || proc_storage_supported_type?(argument, visited) }
        when Types::Variant
          type.arm_names.all? { |arm_name| type.arm(arm_name).each_value.all? { |field_type| proc_storage_supported_type?(field_type, visited) } }
        when Types::Nullable
          proc_storage_supported_type?(type.base, visited)
        else
          false
        end
      end

      def validate_stored_proc_type!(type, context)
        if contains_proc_type?(type)
          raise_sema_error("#{context} cannot store proc values") unless proc_storage_supported_type?(type)
        end
      end

      def validate_parameter_ref_type!(type, function_name:, parameter_name:, external:)
        if ref_type?(type)
          raise_sema_error("external function #{function_name} cannot take ref parameters") if external

          return
        end

        return if callable_param_ref_supported?(type)

        raise_sema_error("parameter #{parameter_name} of #{function_name} cannot nest ref types") if contains_ref_type?(type)
      end

      def validate_parameter_proc_type!(type, function_name:, parameter_name:, external:, foreign:)
        if contains_proc_type?(type)
          raise_sema_error("external function #{function_name} cannot take proc parameters") if external
          raise_sema_error("foreign function #{function_name} cannot take proc parameters") if foreign
          raise_sema_error("parameter #{parameter_name} of #{function_name} uses unsupported proc nesting") unless proc_storage_supported_type?(type)
        end
      end

      def validate_return_ref_type!(type, function_name:)
        raise_sema_error("function #{function_name} cannot return ref types") if contains_ref_type?(type)
      end

      def validate_return_proc_type!(type, function_name:)
        if contains_proc_type?(type)
          raise_sema_error("function #{function_name} uses unsupported proc nesting in return type") unless proc_storage_supported_type?(type)
        end
      end

      def validate_local_ref_type!(type, local_name)
        return if ref_type?(type)
        return if stored_ref_supported_type?(type)

        if contains_ref_type?(type)
          if callable_type?(type) || contains_callable_ref_type?(type)
            raise_sema_error("local #{local_name} cannot store ref types outside callable parameter positions")
          end

          raise_sema_error("local #{local_name} cannot store nested ref types")
        end
      end

      def validate_local_proc_type!(type, local_name, initializer:)
        return unless contains_proc_type?(type)

        raise_sema_error("local #{local_name} uses unsupported proc nesting") unless proc_storage_supported_type?(type)
      end

      def preassigned_local_binding_id_for(node)
        @preassigned_local_binding_ids[node.object_id] ||= allocate_binding_id
      end

      def error_type?(type)
        type.is_a?(Types::Error)
      end

      def validate_consuming_foreign_parameter!(type, function_name:, parameter_name:)
        if type.is_a?(Types::Nullable) || !(opaque_type?(type) || pointer_type?(type))
          raise_sema_error("consuming parameter #{parameter_name} of #{function_name} must use a non-null opaque or ptr[...] type")
        end
      end

      def foreign_cstr_boundary_parameter?(parameter)
        parameter.boundary_type == @types.fetch("cstr") && parameter.type == @types.fetch("str")
      end

      def foreign_cstr_argument_compatible?(actual_type, parameter, expression:)
        types_compatible?(actual_type, parameter.type, expression:) || actual_type == @types.fetch("cstr")
      end

      def array_to_span_call_argument_compatible?(actual_type, expected_type, expression:, scopes:)
        return false unless expected_type.is_a?(Types::Span)

        if array_type?(actual_type)
          return false unless array_element_type(actual_type) == expected_type.element_type

          infer_addr_source_type(expression, scopes:)
          record_mutable_lvalue_argument_identifier(expression)
          return true
        end

        if str_buffer_type?(actual_type)
          return false unless expected_type.element_type == @types.fetch("char")

          infer_addr_source_type(expression, scopes:)
          record_mutable_lvalue_argument_identifier(expression)
          return true
        end

        false
      rescue SemaError
        false
      end

      def foreign_parameter_boundary_type(param, public_type, type_params:, type_param_constraints: current_type_param_constraints)
        return resolve_type_ref(param.boundary_type, type_params:, type_param_constraints:) if param.boundary_type
        return const_pointer_to(public_type) if param.mode == :in
        return pointer_to(foreign_slot_boundary_value_type(public_type)) if [:out, :inout].include?(param.mode)

        nil
      end

      def foreign_slot_boundary_value_type(public_type)
        if public_type.is_a?(Types::Nullable) && pointer_type?(public_type.base)
          return public_type.base
        end

        public_type
      end

      def validate_in_foreign_parameter!(public_type, boundary_type, function_name:, parameter_name:)
        unless const_pointer_type?(boundary_type)
          raise_sema_error("in parameter #{parameter_name} of #{function_name} must lower to const_ptr[...], got #{boundary_type || public_type}")
        end

        expected_public_type = pointee_type(boundary_type)
        return if expected_public_type == public_type
        return if expected_public_type == @types.fetch("void")
        return if foreign_identity_projection_compatible?(public_type, expected_public_type)

        raise_sema_error("in parameter #{parameter_name} of #{function_name} cannot map #{public_type} as #{boundary_type}")
      end

      def foreign_mapping_public_alias_name(name)
        "#{name}_public"
      end

      def validate_foreign_boundary_type!(public_type, boundary_type, function_name:, parameter_name:)
        return if boundary_type == public_type
        return if boundary_type == @types.fetch("cstr") && public_type == @types.fetch("str")
        return if foreign_span_boundary_compatible?(public_type, boundary_type)
        return if foreign_char_pointer_buffer_boundary_compatible?(public_type, boundary_type)
        return if foreign_identity_projection_compatible?(public_type, boundary_type)

        raise_sema_error("foreign parameter #{parameter_name} of #{function_name} cannot map #{public_type} as #{boundary_type}")
      end

      def foreign_function_binding?(binding)
        binding.ast.is_a?(AST::ForeignFunctionDecl)
      end

      def foreign_mapping_expression(decl)
        return decl.mapping unless foreign_mapping_auto_call_shorthand?(decl.mapping)

        AST::Call.new(
          callee: decl.mapping,
          arguments: decl.params.map { |param| AST::Argument.new(name: nil, value: AST::Identifier.new(name: param.name)) },
        )
      end

      def foreign_mapping_auto_call_shorthand?(expression)
        case expression
        when AST::Identifier
          true
        when AST::MemberAccess
          foreign_mapping_auto_call_shorthand?(expression.receiver)
        when AST::Specialization
          foreign_mapping_auto_call_shorthand?(expression.callee)
        else
          false
        end
      end

      def foreign_argument_expression(argument)
        if argument.value.is_a?(AST::UnaryOp) && ["out", "in", "inout"].include?(argument.value.operator)
          argument.value.operand
        else
          argument.value
        end
      end

      def foreign_argument_legacy_passing_mode(argument)
        return nil unless argument.value.is_a?(AST::UnaryOp) && ["out", "in", "inout"].include?(argument.value.operator)

        argument.value.operator
      end

      def foreign_argument_actual_type(parameter, argument, scopes:, function_name:, expected_type: parameter.type)
        case parameter.passing_mode
        when :plain
          infer_expression(argument.value, scopes:, expected_type:)
        when :consuming
          foreign_consuming_argument_binding(parameter, argument, scopes:, function_name:)
          parameter.type
        when :in, :out, :inout
          if (legacy_passing_mode = foreign_argument_legacy_passing_mode(argument))
            raise_sema_error("argument #{parameter.name} to #{function_name} must not use #{legacy_passing_mode}; directional passing is declared on #{function_name}")
          end

          if parameter.passing_mode == :in
            infer_expression(argument.value, scopes:, expected_type: expected_type)
          else
            infer_lvalue(argument.value, scopes:)
          end
        else
          raise_sema_error("unsupported foreign passing mode #{parameter.passing_mode}")
        end
      end

      def foreign_consuming_argument_binding(parameter, argument, scopes:, function_name:)
        unless argument.value.is_a?(AST::Identifier)
          raise_sema_error("consuming argument #{parameter.name} to #{function_name} must be a bare nullable local or parameter binding")
        end

        binding = lookup_value(argument.value.name, scopes)
        unless binding && %i[let var param].include?(binding.kind) && binding.storage_type.is_a?(Types::Nullable) && binding.storage_type.base == parameter.type
          raise_sema_error("consuming argument #{parameter.name} to #{function_name} must be a bare nullable local or parameter binding")
        end

        binding
      end

      def safe_reference_source_expression?(expression, scopes:)
        case expression
        when AST::Identifier
          true
        when AST::MemberAccess, AST::IndexAccess
          safe_reference_source_expression?(expression.receiver, scopes:)
        when AST::BinaryOp
          unsafe_context?
        when AST::Call
          return false unless expression.arguments.length == 1 && expression.arguments.first.name.nil?

          if read_call?(expression)
            argument_type = infer_expression(expression.arguments.first.value, scopes:)
            ref_type?(argument_type) || pointer_type?(argument_type)
          else
            false
          end
        else
          false
        end
      end

      def infer_ro_addr_source_type(expression, scopes:)
        raise_sema_error("const_ptr_of requires a safe lvalue source") unless safe_reference_source_expression?(expression, scopes:)

        source_type = infer_expression(expression, scopes:)
        raise_sema_error("const_ptr_of cannot target ref values") if contains_ref_type?(source_type)

        source_type
      end

      def infer_addr_source_type(expression, scopes:)
        raise_sema_error("ref_of requires a mutable safe lvalue source") unless safe_reference_source_expression?(expression, scopes:)

        source_type = infer_lvalue(expression, scopes:)
        raise_sema_error("ref_of cannot target ref values") if contains_ref_type?(source_type)

        source_type
      end

      def validate_read_call_arguments!(arguments)
        raise_sema_error("read does not support named arguments") if arguments.any?(&:name)
        raise_sema_error("read expects 1 argument, got #{arguments.length}") unless arguments.length == 1
      end

      def infer_reference_value_type(handle_expression, scopes:)
        handle_type = infer_expression(handle_expression, scopes:)
        return referenced_type(handle_type) if ref_type?(handle_type)

        pointee = pointee_type(handle_type)
        if pointee
          require_unsafe!("raw pointer dereference requires unsafe")

          return pointee
        end

        raise_sema_error("read expects ref[...] or ptr[...], got #{handle_type}")
      end

      def infer_method_receiver_type(receiver_expression, scopes:, member_name: nil)
        receiver_type = infer_expression(receiver_expression, scopes:)
        project_method_receiver_type(receiver_type, member_name:)
      end

      def infer_field_receiver_type(receiver_expression, scopes:, require_mutable_pointer: false)
        receiver_type = infer_expression(receiver_expression, scopes:)
        project_field_receiver_type(receiver_type, require_mutable_pointer:)
      end

      def project_field_receiver_type(receiver_type, require_mutable_pointer: false)
        return referenced_type(receiver_type) if ref_type?(receiver_type)
        return receiver_type unless pointer_type?(receiver_type)

        require_unsafe!("raw pointer dereference requires unsafe")
        if require_mutable_pointer && const_pointer_type?(receiver_type)
          raise_sema_error("cannot assign through read-only raw pointer #{receiver_type}")
        end

        pointee_type(receiver_type)
      end

      def project_method_receiver_type(receiver_type, member_name: nil)
        receiver_type = referenced_type(receiver_type) if ref_type?(receiver_type)
        return receiver_type unless pointer_type?(receiver_type)

        return receiver_type if member_name && lookup_method(receiver_type, member_name)

        require_unsafe!("raw pointer dereference requires unsafe")

        pointee_type(receiver_type)
      end

      def read_call?(expression)
        expression.is_a?(AST::Call) && expression.callee.is_a?(AST::Identifier) && expression.callee.name == "read"
      end

      def raw_module?
        @module_kind == :raw_module
      end

      def assignable_receiver?(receiver_expression, scopes)
        infer_lvalue_receiver(receiver_expression, scopes:, allow_ref_identifier: true, allow_pointer_identifier: true, require_mutable_pointer: true)
        true
      rescue SemaError
        false
      end

      def with_scope(bindings)
        scope = {}
        bindings.each do |binding|
          raise_sema_error("duplicate local #{binding.name}") if scope.key?(binding.name)

          scope[binding.name] = binding
        end

        yield([scope])
      end

      def with_nested_scope(scopes)
        nested_scopes = scopes + [{}]
        yield(nested_scopes)
      end

      def value_binding(name:, type:, mutable:, kind:, flow_type: nil, const_value: nil, id: nil)
        id ||= allocate_binding_id
        @binding_name_by_id[id] = name
        @binding_type_by_id[id] = flow_type == type ? type : (flow_type || type)
        ValueBinding.new(id:, name:, storage_type: type, flow_type: flow_type == type ? nil : flow_type, mutable:, kind:, const_value:)
      end

      def binding_resolution_snapshot
        BindingResolution.new(
          identifier_binding_ids: @identifier_binding_ids.dup.freeze,
          declaration_binding_ids: @declaration_binding_ids.dup.freeze,
          mutating_argument_identifier_ids: @mutating_argument_identifier_ids.dup.freeze,
          editable_receiver_expression_ids: @editable_receiver_expression_ids.dup.freeze,
          mutable_lvalue_argument_identifier_ids: @mutable_lvalue_argument_identifier_ids.dup.freeze,
          binding_types: @binding_type_by_id.dup.freeze,
        )
      end

      def allocate_binding_id
        id = @next_binding_id
        @next_binding_id += 1
        id
      end

      def record_identifier_binding(expression, binding)
        return unless expression.is_a?(AST::Identifier)
        return unless binding&.id

        @identifier_binding_ids[expression.object_id] = binding.id
      end

      def record_callable_value_identifier_site(expression)
        return unless expression.is_a?(AST::Identifier)
        return unless expression.line && expression.column

        @callable_value_identifier_sites[[expression.line, expression.column]] = true
      end

      def record_callable_value_expression_site(expression)
        case expression
        when AST::Identifier
          record_callable_value_identifier_site(expression)
        when AST::MemberAccess
          record_callable_value_member_access_site(expression)
        end
      end

      def record_callable_value_member_access_site(expression)
        return unless expression.is_a?(AST::MemberAccess)
        return unless expression.receiver.is_a?(AST::Identifier)
        return unless expression.receiver.line && expression.receiver.column

        @callable_value_member_access_sites[
          [expression.receiver.name, expression.receiver.line, expression.receiver.column, expression.member]
        ] = true
      end

      def record_declaration_binding(node, binding)
        return unless node
        return unless binding&.id

        @declaration_binding_ids[node.object_id] = binding.id
      end



    end
  end
end

# frozen_string_literal: true

module MilkTea
  class SemanticAnalyzer
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

        @ctx.top_level_values[name]
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

        method = @ctx.methods.fetch(receiver_type, {})[name]
        method ||= @ctx.methods.fetch(dispatch_receiver_type, {})[name] unless dispatch_receiver_type == receiver_type
        return method if method

        imported_candidates = []

        @ctx.imports.each_value do |module_binding|
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
        return nil if module_name == @ctx.module_name

        find_reachable_imported_module(module_name)
      end

      def receiver_type_module_name(receiver_type)
        return receiver_type_module_name(receiver_type.base) if receiver_type.is_a?(Types::Nullable)
        return receiver_type.module_name if receiver_type.respond_to?(:module_name)

        nil
      end

      def find_reachable_imported_module(module_name)
        visited = {}

        @ctx.imports.each_value do |module_binding|
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

        interface = if parts.length == 1
                      @ctx.interfaces[parts.first]
                    elsif parts.length == 2 && @ctx.imports.key?(parts.first)
                      imported_module = @ctx.imports.fetch(parts.first)
                      raw = imported_module.interfaces[parts.last]
                      if imported_module.private_interface?(parts.last)
                        raise_sema_error("#{parts.first}.#{parts.last} is private to module #{imported_module.name}")
                      end
                      raw
                    end

        raise_sema_error("unknown interface #{interface_ref}", interface_ref) unless interface

        if interface_ref.type_arguments.any?
          raise_sema_error("interface #{interface.name} is not generic") unless interface.is_a?(GenericInterfaceBinding)

          arguments = interface_ref.type_arguments.map { |arg| resolve_type_ref(arg) }
          interface.instantiate(arguments)
        else
          raise_sema_error("generic interface #{interface.name} requires type arguments") if interface.is_a?(GenericInterfaceBinding)

          interface
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

      def resolve_type_ref(type_ref, type_params: current_type_params, type_param_constraints: current_type_param_constraints, nested_types: nil)
        base = resolve_non_nullable_type(type_ref, type_params:, type_param_constraints:, nested_types:)
        return base if type_ref.is_a?(AST::FunctionType) || type_ref.is_a?(AST::ProcType) || type_ref.is_a?(AST::TupleType)

        raise_sema_error("ref types are non-null and cannot be nullable", type_ref) if type_ref.nullable && ref_type?(base)

        type_ref.nullable ? Types::Registry.nullable(base) : base
      end

      def resolve_non_nullable_type(type_ref, type_params: {}, type_param_constraints: {}, nested_types: nil)
        if type_ref.is_a?(AST::FunctionType)
          params = type_ref.params.map do |param|
            Types::Registry.parameter(param.name, resolve_type_ref(param.type, type_params:, type_param_constraints:))
          end
          return Types::Registry.function(nil, params:, return_type: resolve_type_ref(type_ref.return_type, type_params:, type_param_constraints:))
        end

        if type_ref.is_a?(AST::ProcType)
          params = type_ref.params.map do |param|
            Types::Registry.parameter(param.name, resolve_type_ref(param.type, type_params:, type_param_constraints:))
          end
          return Types::Registry.proc(params:, return_type: resolve_type_ref(type_ref.return_type, type_params:, type_param_constraints:))
        end

        if type_ref.is_a?(AST::DynType)
          interface = resolve_interface_ref(type_ref.interface)
          raise_sema_error("generic interface #{interface.name} requires type arguments") if interface.is_a?(GenericInterfaceBinding)
          type_arguments = interface.type_arguments || []
          type = Types::Dyn.new(interface, type_arguments)
          type = Types::Registry.nullable(type) if type_ref.nullable
          return type
        end

        if type_ref.is_a?(AST::TupleType)
          names = []
          element_types = []
          type_ref.element_types.each do |et|
            if et.is_a?(AST::Argument)
              names << et.name
              element_types << resolve_type_ref(et.value, type_params:, type_param_constraints:)
            else
              names << nil
              element_types << resolve_type_ref(et, type_params:, type_param_constraints:)
            end
          end
          has_named = names.any?
          return Types::Registry.tuple(element_types, field_names: has_named ? names : nil)
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
            return Types::Registry.task(arguments[0])
          end

          if (generic_type = resolve_named_generic_type(parts))
            begin
              validate_generic_type_param_constraints!(generic_type, arguments, context: "type #{generic_type}", available_type_param_constraints: type_param_constraints)
              return generic_type.instantiate(arguments)
            rescue ArgumentError => error
              raise_sema_error(error.message)
            end
          end

          # Handle types with lifetime params only (no type params)
          if arguments.all? { |a| a.is_a?(Types::LifetimeRef) }
            type = @ctx.types[name]
            if type.is_a?(Types::Struct) && type.lifetime_params&.any?
              lifetime_args = arguments.select { |a| a.is_a?(Types::LifetimeRef) }.map(&:name)
              if lifetime_args.to_set == type.lifetime_params.to_set
                return type
              end
            end
          end

          validate_generic_type!(name, arguments)
          return Types::Registry.span(arguments.first) if name == "span"

          return Types::Registry.soa(arguments[0], count: arguments[1].value) if name == "SoA"

          arguments = [type_ref.lifetime] + arguments if name == "ref" && type_ref.lifetime
          return Types::Registry.generic_instance(name, arguments)
        end

        if parts.length == 1 && type_ref.lifetime
          raise_sema_error("lifetime annotations are only valid on ref types, got #{type_ref.name}", type_ref)
        end

        if parts.length == 1
          return type_params.fetch(parts.first) if type_params.key?(parts.first)

          if nested_types && (type = nested_types[parts.first])
            return type
          end

          if parts.first.start_with?("@")
            raise_sema_error("unknown lifetime #{parts.first}", type_ref)
          end

          type = @ctx.types[parts.first]
          unless type
            type_names = @ctx.types.keys
            suggestion = suggest_name(parts.first, type_names)
            unless suggestion
              suggestion = import_suggestion_for_type(parts.first)
            end
            raise_sema_error("unknown type #{parts.first}", type_ref, suggestion: suggestion ? "did you mean '#{suggestion}'?" : nil)
          end
          raise_sema_error("generic type #{parts.first} requires type arguments", type_ref) if type.is_a?(Types::GenericStructDefinition) || type.is_a?(Types::GenericVariantDefinition)

          return type
        end

        if parts.length >= 2
          type = resolve_nested_type_ref(parts)
          return type if type
        end

        if parts.length == 2 && @ctx.imports.key?(parts.first)
          imported_module = @ctx.imports.fetch(parts.first)
          type = imported_module.types[parts.last]
          if imported_module.private_type?(parts.last)
            raise_sema_error("#{parts.first}.#{parts.last} is private to module #{imported_module.name}", type_ref)
          end
          raise_sema_error("unknown type #{type_ref.name}", type_ref) unless type
          raise_sema_error("generic type #{type_ref.name} requires type arguments", type_ref) if type.is_a?(Types::GenericStructDefinition) || type.is_a?(Types::GenericVariantDefinition)

          return type
        end

        if @compile_time_depth&.positive? && (ct_type = resolve_compile_time_type_ref(type_ref))
          return ct_type
        end

        raise_sema_error("unknown type #{type_ref.name}", type_ref, suggestion: import_suggestion_for_type(type_ref.name))
      end

      # Resolves a bare dotted reflection type expression such as `field.type`
      # (where `field` is a compile-time `field_handle` bound in scope) to the
      # concrete `Types::Base` it denotes. Returns nil when the type_ref is not a
      # compile-time type expression resolvable in the current scopes. Only the
      # plain `<local>.member` form is supported (no calls/indexing/type args).
      def resolve_compile_time_type_ref(type_ref)
        return nil unless @type_resolution_scopes
        return nil if type_ref.arguments.any? || type_ref.nullable

        parts = type_ref.name.parts
        return nil unless parts.length >= 2

        binding = lookup_value(parts.first, @type_resolution_scopes)
        return nil unless binding && !binding.const_value.nil?

        expression = AST.build_chain_from_parts(parts)
        return nil unless expression

        value = evaluate_compile_time_const_value(expression, scopes: @type_resolution_scopes)
        value.is_a?(Types::Base) ? value : nil
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
      rescue SemanticError => error
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
        binding = @ctx.top_level_values[name]
        return unless binding&.kind == :const

        evaluate_top_level_const_value(name)
      end

      def top_level_function(name)
        @ctx.top_level_functions[name]
      end

      def resolve_imported_module_const_value(import_name, value_name)
        imported_module = @ctx.imports[import_name]
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

        unless types_compatible?(actual_type, expected_type, expression:, scopes:, external_numeric:, external_pointer_null:, contextual_int_to_float:)
          suggestion = explicit_cast_suggestion(actual_type, expected_type)
          raise SemanticError.new(message, line:, column:, path: @path, suggestion:)
        end
      end

      def explicit_cast_suggestion(actual_type, expected_type)
        if castable_primitive?(actual_type) && castable_primitive?(expected_type)
          return nil if actual_type == expected_type
          "use an explicit cast: `#{expected_type}<-(value)`"
        end

        if actual_type.is_a?(Types::Nullable) && expected_type.is_a?(Types::Nullable)
          explicit_cast_suggestion(actual_type.base, expected_type.base)
        else
          nil
        end
      end

      def castable_primitive?(type)
        return castable_primitive?(type.base) if type.is_a?(Types::Nullable)

        type.is_a?(Types::Primitive) || type.is_a?(Types::Enum) || type.is_a?(Types::Flags)
      end

      def ensure_argument_assignable!(actual_type, expected_type, external:, message:, expression: nil, scopes: nil)
        line = source_line(expression)
        column = source_column(expression)
        unless argument_types_compatible?(actual_type, expected_type, external:, expression:, scopes:)
          suggestion = explicit_cast_suggestion(actual_type, expected_type)
          raise SemanticError.new(message, line:, column:, path: @path, suggestion:)
        end
      end

      def with_error_node(node)
        @error_node_stack << node
        yield
      ensure
        @error_node_stack.pop
      end

      def current_error_node
        @error_node_stack.reverse_each.find { |node| !node.nil? }
      end

      def raise_sema_error(message, node = nil, line: nil, column: nil, length: nil, suggestion: nil)
        target = node || current_error_node
        line ||= source_line(target)
        column ||= source_column(target)
        length ||= source_length(target)
        raise SemanticError.new(message, line:, column:, length:, path: @path, suggestion:)
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
        when AST::PrefixCast then source_line(node.target_type)
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
        when AST::PrefixCast then source_column(node.target_type)
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

        raise_sema_error("#{context} requires a concrete sized type, got #{type_ref}")
      end

      def check_layout_type_via_ct(type_ref, context:, scopes:)
        return false unless scopes && type_ref.name.parts.length >= 1

        first_part = type_ref.name.parts.first
        binding = lookup_value(first_part, scopes)
        return false unless binding && !binding.const_value.nil?

        expression = AST.build_chain_from_parts(type_ref.name.parts)
        return false unless expression

        ct_value = evaluate_compile_time_const_value(expression, scopes:)
        if ct_value.is_a?(Types::Struct) || ct_value.is_a?(Types::Primitive) ||
           ct_value.is_a?(Types::Union) || ct_value.is_a?(Types::Nullable) ||
           ct_value.is_a?(Types::StructInstance)
          if sized_layout_type?(ct_value)
            return true
          end
        end

        false
      end




      def resolve_and_store_offset(expression, scopes:)
        type = resolve_type_ref(expression.type)
        return unless layout_aggregate_type?(type)

        binding = lookup_value(expression.field, scopes)
        return unless binding && binding.const_value.is_a?(Types::FieldHandle)

        offset = CompileTime::Layout.offset_of(type, binding.const_value.field_name)
        return unless offset

        @const_values[@ctx.ast.node_ids[expression.object_id]] = offset
      end

      def infer_offsetof_type(type_ref, field_name, scopes: nil)
        type = resolve_type_ref(type_ref)
        unless layout_aggregate_type?(type)
          raise_sema_error("offset_of requires a struct, union, span, or str type, got #{type}")
        end

        field_type = type.field(field_name)
        return type if field_type

        if scopes
          binding = lookup_value(field_name, scopes)
          if binding && binding.storage_type.is_a?(Types::ReflectionHandleType) && binding.storage_type.name == "field_handle"
            return type
          end
        end

        raise_sema_error("unknown field #{type}.#{field_name}")
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
        return true if atomic_type?(type)

        raise_sema_error("#{operation} does not support type #{type}")
      end

      def layout_aggregate_type?(type)
        type.respond_to?(:field) && !type.is_a?(Types::Opaque) && !type.is_a?(Types::EnumBase)
      end

      def power_of_two?(value)
        (value & (value - 1)).zero?
      end

      def aggregate_type?(type)
        type.is_a?(Types::Struct) || type.is_a?(Types::Tuple) || span_type?(type) || string_view_type?(type) || task_type?(type) || vector_type?(type) || matrix_type?(type) || quaternion_type?(type)
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
        array_type?(type) && array_element_type(type) == @ctx.types.fetch("char")
      end

      def str_buffer_type?(type)
        type.is_a?(Types::GenericInstance) && type.name == "str_buffer" && type.arguments.length == 1 &&
          generic_integer_type_argument?(type.arguments.first)
      end

      def event_type?(type)
        type.is_a?(Types::Event)
      end

      def atomic_type?(type)
        type.is_a?(Types::GenericInstance) && type.name == "atomic" && type.arguments.length == 1
      end

      def atomic_element_type(type)
        type.arguments.first
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
        Types.pointer_to(type)
      end

      def contains_type_var?(type)
        super
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



      def aggregate_display_name(type)
        type.is_a?(Types::StructInstance) ? type.to_s : type.name
      end

      def validate_generic_type!(name, arguments)
        super(name, arguments) { |msg| raise_sema_error(msg) }
      end

      def integer_type?(type)
        type.is_a?(Types::Primitive) && type.integer?
      end

      def struct_instance_type?(type)
        type.is_a?(Types::Struct) || type.is_a?(Types::Variant)
      end

      def c_natively_equality_comparable_type?(type)
        return true if type.is_a?(Types::Primitive)
        return true if type.is_a?(Types::EnumBase)
        return true if type.is_a?(Types::Opaque)
        return true if type.is_a?(Types::Nullable)
        return true if type.is_a?(Types::Null)
        return true if type.is_a?(Types::Function)
        return true if type.is_a?(Types::Error)
        return true if type.is_a?(Types::StringView)
        return true if pointer_type?(type)
        return true if ref_type?(type)
        return true if type.is_a?(Types::Variant)
        return true if type.is_a?(Types::VariantArmPayload)

        false
      end

      def collection_loop_type(type)
        super
      end

      def collection_loop_binding_type(iterable_type, element_type)
        super
      end

      def collection_loop_ref_element_type?(type)
        super
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

        if next_type == @ctx.types.fetch("bool")
          current_method = lookup_method(iterator_type, "current")
          raise_sema_error("for iterator #{iterator_type} must define current() when next() returns bool") unless current_method
          current_method = instantiate_function_binding_with_receiver(current_method, [], receiver_type: iterator_type) if current_method.type_params.any?
          unless current_method.type.params.empty?
            raise_sema_error("for iterator #{iterator_type}.current expects 0 arguments")
          end
          raise_sema_error("for iterator #{iterator_type}.current cannot return void") if current_method.type.return_type == @ctx.types.fetch("void")

          return current_method.type.return_type
        end

        raise_sema_error("for iterator #{iterator_type}.next must return bool or a nullable pointer-like item, got #{next_type}")
      end

      def string_like_type?(type)
        type == @ctx.types.fetch("str") || type == @ctx.types.fetch("cstr")
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

          @ctx.types[expression.name]
        when AST::MemberAccess
          return nil unless expression.receiver.is_a?(AST::Identifier)

          if @ctx.imports.key?(expression.receiver.name)
            imported_module = @ctx.imports.fetch(expression.receiver.name)
            if imported_module.private_type?(expression.member)
              raise_sema_error("#{expression.receiver.name}.#{expression.member} is private to module #{imported_module.name}")
            end

            return imported_module.types[expression.member]
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

      def imported_module_with_private_method(receiver_type, method_name)
        imported_module = imported_module_with_private_method_local(receiver_type, method_name)
        return imported_module if imported_module

        fallback_owner = specialization_lookup_owner
        return nil unless fallback_owner

        fallback_owner.send(:imported_module_with_private_method_local, receiver_type, method_name)
      end

      def imported_module_with_private_method_local(receiver_type, method_name)
        @ctx.imports.each_value do |module_binding|
          return module_binding if module_binding.private_method?(receiver_type, method_name)
        end

        nil
      end



      def resolve_methods_receiver_target(type_ref)
        if type_ref.is_a?(AST::TypeRef)
          generic_type = resolve_named_generic_type(type_ref.name.parts)
          if generic_type.is_a?(Types::GenericStructDefinition) || generic_type.is_a?(Types::GenericVariantDefinition)
            receiver_type_param_names = validate_methods_receiver_type_arguments!(type_ref, generic_type)
            receiver_type_params = receiver_type_param_names.to_h { |name| [name, Types::TypeVar.new(name)] }
            receiver_type_param_constraints = generic_type.respond_to?(:type_param_constraints) ? generic_type.type_param_constraints : {}
            receiver_type = resolve_type_ref(type_ref, type_params: receiver_type_params, type_param_constraints: receiver_type_param_constraints)
            return [generic_type, receiver_type, receiver_type_param_names, receiver_type_param_constraints]
          end

          begin
            receiver_type = resolve_type_ref(type_ref)
            unless receiver_type.is_a?(Types::Struct) || receiver_type.is_a?(Types::StructInstance) || receiver_type.is_a?(Types::Opaque) || receiver_type.is_a?(Types::GenericInstance) || receiver_type.is_a?(Types::Nullable) || receiver_type.is_a?(Types::StringView) || receiver_type.is_a?(Types::Primitive) || receiver_type.is_a?(Types::Variant) || receiver_type.is_a?(Types::VariantInstance) || vector_type?(receiver_type) || matrix_type?(receiver_type) || quaternion_type?(receiver_type)
              raise_sema_error("extending target #{type_ref} must be a struct, opaque, nullable/generic receiver, variant, or str")
            end

            return [receiver_type, receiver_type, [], {}]
          rescue MilkTea::SemanticError => error
            receiver_type_param_names = methods_receiver_type_argument_names!(type_ref)
            raise error if receiver_type_param_names.empty?

            receiver_type_params = receiver_type_param_names.to_h { |name| [name, Types::TypeVar.new(name)] }
            receiver_type = resolve_type_ref(type_ref, type_params: receiver_type_params)
            return [method_dispatch_receiver_type(receiver_type), receiver_type, receiver_type_param_names, {}]
          end
        end

        receiver_type = resolve_type_ref(type_ref)
        unless receiver_type.is_a?(Types::Struct) || receiver_type.is_a?(Types::StructInstance) || receiver_type.is_a?(Types::Opaque) || receiver_type.is_a?(Types::GenericInstance) || receiver_type.is_a?(Types::Nullable) || receiver_type.is_a?(Types::StringView) || receiver_type.is_a?(Types::Primitive) || receiver_type.is_a?(Types::Variant) || receiver_type.is_a?(Types::VariantInstance) || vector_type?(receiver_type) || matrix_type?(receiver_type) || quaternion_type?(receiver_type)
          raise_sema_error("extending target #{type_ref} must be a struct, opaque, nullable/generic receiver, variant, or str")
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

      def proc_type_compatible?(actual_type, expected_type)
        return true unless expected_type
        if proc_type?(expected_type)
          return true if expected_type.is_a?(Types::Proc) && actual_type.is_a?(Types::Proc) &&
            contains_type_var?(expected_type)
          return actual_type == expected_type
        end

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

      def validate_stored_ref_type!(type, context, allow_lifetimes: [])
        return unless contains_ref_type?(type, allow_lifetimes:)
        return if stored_ref_supported_type?(type, allow_lifetimes:)

        if callable_type?(type) || contains_callable_ref_type?(type)
          raise_sema_error("#{context} cannot store ref types outside callable parameter positions")
        end

        if context.start_with?("field ")
          raise_sema_error("#{context} cannot store ref types; declare a lifetime on the struct and use ref[@lt, T] (e.g. struct MyStruct[@a]: field: ref[@a, SomeType])")
        end

        raise_sema_error("#{context} cannot store ref types")
      end

      def stored_ref_supported_type?(type, visited = {}, allow_lifetimes: [])
        visitor = StoredRefSupportedVisitor.new(allow_lifetimes:)
        visitor.visit(type)
        visitor.result?
      end

      def contains_callable_ref_type?(type, visited = {})
        visitor = ContainsCallableRefTypeVisitor.new
        visitor.visit(type)
        visitor.found?
      end

      def contains_proc_type?(type, visited = {})
        visitor = ContainsProcTypeVisitor.new
        visitor.visit(type)
        visitor.found?
      end

      def proc_storage_supported_type?(type, visited = {})
        return true unless contains_proc_type?(type)
        visitor = ProcStorageSupportedVisitor.new
        visitor.visit(type)
        visitor.result?
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
        if contains_ref_type?(type)
          if (type.is_a?(Types::Struct) || type.is_a?(Types::StructInstance)) && type.fields.any?
            raise_sema_error("function #{function_name} cannot return non-owning struct #{type.name} (contains borrowed ref)")
          end
          raise_sema_error("function #{function_name} cannot return ref types")
        end
      end

      def validate_return_proc_type!(type, function_name:)
        if contains_proc_type?(type)
          raise_sema_error("function #{function_name} uses unsupported proc nesting in return type") unless proc_storage_supported_type?(type)
        end
      end

      def validate_local_ref_type!(type, local_name)
        return if ref_type?(type)
        return if (type.is_a?(Types::Struct) || type.is_a?(Types::StructInstance)) && type.fields.any? && contains_ref_type?(type)
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

      def array_to_span_call_argument_compatible?(actual_type, expected_type, expression:, scopes:)
        return false unless expected_type.is_a?(Types::Span)

        if array_type?(actual_type)
          return false unless array_element_type(actual_type) == expected_type.element_type

          infer_addr_source_type(expression, scopes:)
          record_mutable_lvalue_argument_identifier(expression)
          return true
        end

        if str_buffer_type?(actual_type)
          return false unless expected_type.element_type == @ctx.types.fetch("char")

          infer_addr_source_type(expression, scopes:)
          record_mutable_lvalue_argument_identifier(expression)
          return true
        end

        false
      rescue SemanticError
        false
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
        if contains_ref_type?(source_type)
          unless (source_type.is_a?(Types::Struct) || source_type.is_a?(Types::StructInstance)) && source_type.lifetime_params&.any?
            raise_sema_error("const_ptr_of cannot target ref values")
          end
        end

        source_type
      end

      def infer_addr_source_type(expression, scopes:)
        raise_sema_error("ref_of requires a mutable safe lvalue source") unless safe_reference_source_expression?(expression, scopes:)

        source_type = infer_lvalue(expression, scopes:)
        if contains_ref_type?(source_type)
          unless (source_type.is_a?(Types::Struct) || source_type.is_a?(Types::StructInstance)) && source_type.lifetime_params&.any?
            raise_sema_error("ref_of cannot target ref values")
          end
        end

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
        @ctx.module_kind == :raw_module
      end

      def assignable_receiver?(receiver_expression, scopes)
        infer_lvalue_receiver(receiver_expression, scopes:, allow_ref_identifier: true, allow_pointer_identifier: true, require_mutable_pointer: true)
        true
      rescue SemanticError
        false
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

      def import_suggestion_for_type(type_name)
        return nil if @ctx.global_import_index.nil? || @ctx.global_import_index.empty?

        type_str = type_name.to_s
        return nil if type_str.empty?

        if @ctx.global_import_index.key?(type_str)
          entry = @ctx.global_import_index[type_str]
          return nil if entry.nil?
          module_path = entry.is_a?(Array) ? entry.first : entry
          if module_path && !@ctx.imports.key?(module_path.to_s.split(".").first) && !@ctx.imports.key?(module_path.to_s)
            return "type '#{type_str}' is available via 'import #{module_path}'"
          end
        end

        nil
      end


    end
  end
end

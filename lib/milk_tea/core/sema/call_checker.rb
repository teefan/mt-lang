# frozen_string_literal: true

module MilkTea
  class Sema
    class Checker
      private

      def resolved_attribute_applications_for_target(target)
        target_id = case target
        when Types::StructHandle then target.declaration.object_id
        when Types::FieldHandle then target.field_declaration.object_id
        when Types::CallableHandle then target.declaration.object_id
        end
        return [] unless target_id

        applications = @resolved_attribute_applications[target_id]
        return applications if applications

        @imports.each_value do |imported_module|
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

      def same_attribute_binding?(left, right)
        left.name == right.name && left.module_name == right.module_name
      end

      def qualified_attribute_name(binding)
        binding.module_name ? "#{binding.module_name}.#{binding.name}" : binding.name
      end

      def attribute_presence_refinement_key(target, binding)
        AttributePresenceKey.new(target, binding.module_name, binding.name)
      end

      def attribute_presence_guard_active?(scopes, key)
        scopes.any? { |scope| scope.key?(key) }
      end

      def check_aggregate_construction(struct_type, arguments, scopes:)
        display_name = aggregate_display_name(struct_type)

        if struct_type.is_a?(Types::StringView)
          require_unsafe!("str construction requires unsafe")
        end

        raise_sema_error("aggregate construction for #{display_name} requires named arguments") unless arguments.all?(&:name)

        provided = {}
        arguments.each do |argument|
          field_type = struct_type.field(argument.name)
          raise_sema_error("unknown field #{display_name}.#{argument.name}") unless field_type
          raise_sema_error("duplicate field #{display_name}.#{argument.name}") if provided.key?(argument.name)

          actual_type = infer_expression(argument.value, scopes:, expected_type: field_type)
          ensure_assignable!(
            actual_type,
            field_type,
            "field #{display_name}.#{argument.name} expects #{field_type}, got #{actual_type}",
            expression: argument.value,
            external_numeric: struct_type.respond_to?(:external) && struct_type.external,
            external_pointer_null: struct_type.respond_to?(:external) && struct_type.external,
            contextual_int_to_float: contextual_int_to_float_target?(field_type),
          )
          provided[argument.name] = true
        end

        struct_type
      end

      def check_struct_with_call(struct_type, _receiver_expression, arguments, scopes:)
        display_name = aggregate_display_name(struct_type)

        raise_sema_error("struct.with() requires named arguments") unless arguments.all?(&:name)

        provided = {}
        arguments.each do |argument|
          field_type = struct_type.field(argument.name)
          raise_sema_error("unknown field #{display_name}.#{argument.name}") unless field_type
          raise_sema_error("duplicate field #{display_name}.#{argument.name}") if provided.key?(argument.name)

          actual_type = infer_expression(argument.value, scopes:, expected_type: field_type)
          ensure_assignable!(
            actual_type,
            field_type,
            "field #{display_name}.#{argument.name} expects #{field_type}, got #{actual_type}",
            expression: argument.value,
            external_numeric: struct_type.respond_to?(:external) && struct_type.external,
            external_pointer_null: struct_type.respond_to?(:external) && struct_type.external,
            contextual_int_to_float: contextual_int_to_float_target?(field_type),
          )
          provided[argument.name] = true
        end

        struct_type
      end

      def check_variant_arm_construction(callable, arguments, scopes:)
        variant_type, arm_name = callable
        fields = variant_type.arm(arm_name)

        if fields.nil? || fields.empty?
          raise_sema_error("variant arm #{variant_type}.#{arm_name} has no payload; construct it without arguments") unless arguments.empty?

          return variant_type
        end

        raise_sema_error("variant arm construction requires named arguments") unless arguments.all?(&:name)

        provided = {}
        arguments.each do |argument|
          field_type = fields[argument.name]
          raise_sema_error("unknown field #{variant_type}.#{arm_name}.#{argument.name}") unless field_type
          raise_sema_error("duplicate field #{variant_type}.#{arm_name}.#{argument.name}") if provided.key?(argument.name)

          actual_type = infer_expression(argument.value, scopes:, expected_type: field_type)
          ensure_assignable!(
            actual_type,
            field_type,
            "field #{variant_type}.#{arm_name}.#{argument.name} expects #{field_type}, got #{actual_type}",
            expression: argument.value,
            contextual_int_to_float: contextual_int_to_float_target?(field_type),
          )
          provided[argument.name] = true
        end

        missing = fields.keys - provided.keys
        raise_sema_error("variant arm #{variant_type}.#{arm_name} is missing fields: #{missing.join(', ')}") unless missing.empty?

        variant_type
      end

      def check_array_construction(array_type, arguments, scopes:)
        raise_sema_error("array construction does not support named arguments") if arguments.any?(&:name)

        element_type = array_element_type(array_type)
        length = array_length(array_type)
        raise_sema_error("array expects at most #{length} elements, got #{arguments.length}") if arguments.length > length

        arguments.each do |argument|
          actual_type = infer_expression(argument.value, scopes:, expected_type: element_type)
          ensure_assignable!(
            actual_type,
            element_type,
            "array element expects #{element_type}, got #{actual_type}",
            expression: argument.value,
          )
        end

        array_type
      end

      def check_cast_call(target_type, arguments, scopes:)
        raise_sema_error("cast requires exactly one argument") unless arguments.length == 1
        raise_sema_error("cast does not support named arguments") if arguments.first.name

        source_type = infer_expression(arguments.first.value, scopes:)
        if source_type == target_type
          return target_type
        end

        if pointer_cast?(source_type, target_type)
          expression = arguments.first.value
          require_unsafe!("pointer cast requires unsafe", line: source_line(expression), column: source_column(expression))

          return target_type
        end

        if ref_to_pointer_cast?(source_type, target_type)
          expression = arguments.first.value
          require_unsafe!("ref to pointer cast requires unsafe", line: source_line(expression), column: source_column(expression))

          return target_type
        end

        source_numeric_type = cast_numeric_type(source_type)
        target_numeric_type = cast_numeric_type(target_type)

        unless source_numeric_type && target_numeric_type
          raise_sema_error("cast currently only supports numeric primitive types, got #{source_type} -> #{target_type}")
        end

        target_type
      end

      def cast_numeric_type(type)
        return type if type.is_a?(Types::Primitive) && (type.numeric? || type.name == "bool")
        return type.backing_type if type.is_a?(Types::EnumBase) && type.backing_type.numeric?
        return type if char_type?(type)
        return type.backing_type if type.is_a?(Types::EnumBase) && char_type?(type.backing_type)

        nil
      end

      def infer_null_literal(expression)
        return @null_type unless expression.type

        target_type = resolve_type_ref(expression.type)
        unless typed_null_target_type?(target_type)
          raise_sema_error("typed null requires pointer-like type, got #{target_type}")
        end

        Types::Null.new(target_type)
      end

      def check_reinterpret_call(target_type, arguments, scopes:)
        raise_sema_error("reinterpret requires exactly one argument") unless arguments.length == 1
        raise_sema_error("reinterpret does not support named arguments") if arguments.first.name
        require_unsafe!("reinterpret requires unsafe")

        source_type = infer_expression(arguments.first.value, scopes:)
        unless reinterpretable_type?(source_type) && reinterpretable_type?(target_type)
          raise_sema_error("reinterpret requires non-array concrete sized types, got #{source_type} -> #{target_type}")
        end

        target_type
      end

      def check_zero_call(target_type, arguments, expected_type: nil, operation: "zero")
        raise_sema_error("#{operation} expects 0 arguments, got #{arguments.length}") unless arguments.empty?

        zero_initializable_type?(target_type, operation:)
        if expected_type.is_a?(Types::Nullable) && typed_null_target_type?(expected_type.base) && types_compatible?(target_type, expected_type.base)
          raise_sema_error("use null instead of #{operation}[#{target_type}] in nullable pointer-like context #{expected_type}")
        end

        target_type
      end

      def resolve_default_specialization(callee)
        raise_sema_error("default requires exactly one type argument") unless callee.arguments.length == 1

        type_arg = callee.arguments.first.value
        raise_sema_error("default type argument must be a type") unless type_arg.is_a?(AST::TypeRef)

        target_type = resolve_type_ref(type_arg)
        binding = resolve_explicit_default_binding(target_type, context: "default[#{target_type}]")
        raise_sema_error("default[#{target_type}] requires associated function #{target_type}.default()") unless binding

        DefaultResolution.new(
          target_type:,
          binding:,
        )
      end

      def resolve_hash_specialization(callee)
        raise_sema_error("hash requires exactly one type argument") unless callee.arguments.length == 1

        type_arg = callee.arguments.first.value
        raise_sema_error("hash type argument must be a type") unless type_arg.is_a?(AST::TypeRef)

        target_type = resolve_type_ref(type_arg)
        binding = resolve_explicit_hash_binding(target_type, context: "hash[#{target_type}]")
        raise_sema_error("hash[#{target_type}] requires associated function #{target_type}.hash(value: const_ptr[#{target_type}]) -> uint") unless binding

        HashResolution.new(
          target_type:,
          binding:,
        )
      end

      def resolve_equal_specialization(callee)
        raise_sema_error("equal requires exactly one type argument") unless callee.arguments.length == 1

        type_arg = callee.arguments.first.value
        raise_sema_error("equal type argument must be a type") unless type_arg.is_a?(AST::TypeRef)

        target_type = resolve_type_ref(type_arg)
        binding = resolve_explicit_equal_binding(target_type, context: "equal[#{target_type}]")
        raise_sema_error("equal[#{target_type}] requires associated function #{target_type}.equal(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> bool") unless binding

        EqualResolution.new(
          target_type:,
          binding:,
        )
      end

      def resolve_order_specialization(callee)
        raise_sema_error("order requires exactly one type argument") unless callee.arguments.length == 1

        type_arg = callee.arguments.first.value
        raise_sema_error("order type argument must be a type") unless type_arg.is_a?(AST::TypeRef)

        target_type = resolve_type_ref(type_arg)
        binding = resolve_explicit_order_binding(target_type, context: "order[#{target_type}]")
        raise_sema_error("order[#{target_type}] requires associated function #{target_type}.order(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> int") unless binding

        OrderResolution.new(
          target_type:,
          binding:,
        )
      end

      def resolve_explicit_default_binding(target_type, context:)
        requirement_message = "#{context} requires associated function #{target_type}.default()"
        resolve_explicit_associated_binding(target_type, "default", requirement_message:) do |method|
          raise_sema_error("#{context} requires #{target_type}.default() to take 0 arguments") unless method.type.params.empty?
          unless types_compatible?(method.type.return_type, target_type)
            raise_sema_error("#{context} requires #{target_type}.default() to return #{target_type}, got #{method.type.return_type}")
          end
        end
      end

      def resolve_explicit_hash_binding(target_type, context:)
        requirement_message = "#{context} requires associated function #{target_type}.hash(value: const_ptr[#{target_type}]) -> uint"
        resolve_explicit_associated_binding(target_type, "hash", requirement_message:) do |method|
          unless method.type.params.map(&:type) == [const_pointer_to(target_type)]
            raise_sema_error("#{context} requires #{target_type}.hash(value: const_ptr[#{target_type}]) -> uint")
          end
          unless method.type.return_type == @types.fetch("uint")
            raise_sema_error("#{context} requires #{target_type}.hash(value: const_ptr[#{target_type}]) -> uint, got #{method.type.return_type}")
          end
        end
      end

      def resolve_explicit_equal_binding(target_type, context:)
        requirement_message = "#{context} requires associated function #{target_type}.equal(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> bool"
        resolve_explicit_associated_binding(target_type, "equal", requirement_message:) do |method|
          expected_param_types = [const_pointer_to(target_type), const_pointer_to(target_type)]
          unless method.type.params.map(&:type) == expected_param_types
            raise_sema_error("#{context} requires #{target_type}.equal(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> bool")
          end
          unless method.type.return_type == @types.fetch("bool")
            raise_sema_error("#{context} requires #{target_type}.equal(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> bool, got #{method.type.return_type}")
          end
        end
      end

      def resolve_explicit_order_binding(target_type, context:)
        requirement_message = "#{context} requires associated function #{target_type}.order(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> int"
        resolve_explicit_associated_binding(target_type, "order", requirement_message:) do |method|
          expected_param_types = [const_pointer_to(target_type), const_pointer_to(target_type)]
          unless method.type.params.map(&:type) == expected_param_types
            raise_sema_error("#{context} requires #{target_type}.order(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> int")
          end
          unless method.type.return_type == @types.fetch("int")
            raise_sema_error("#{context} requires #{target_type}.order(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> int, got #{method.type.return_type}")
          end
        end
      end

      def resolve_explicit_format_binding(target_type, context:)
        length_binding = resolve_explicit_format_len_binding(target_type, context:)
        append_binding = resolve_explicit_format_append_binding(target_type, context:)

        return [length_binding, append_binding] if length_binding && append_binding

        if length_binding || append_binding
          raise_sema_error("#{context} requires methods #{target_type}.format_len() -> ptr_uint and #{target_type}.append_format(output: ref[std.string.String]) -> void")
        end

        nil
      end

      def resolve_explicit_format_len_binding(target_type, context:)
        requirement_message = "#{context} requires method #{target_type}.format_len() -> ptr_uint"
        resolve_explicit_instance_binding(target_type, "format_len", requirement_message:) do |method|
          raise_sema_error("#{context} requires #{target_type}.format_len() to take 0 arguments") unless method.type.params.empty?
          raise_sema_error("#{context} requires #{target_type}.format_len() to be non-editable") if method.type.receiver_editable
          unless method.type.return_type == @types.fetch("ptr_uint")
            raise_sema_error("#{context} requires #{target_type}.format_len() -> ptr_uint, got #{method.type.return_type}")
          end
        end
      end

      def resolve_explicit_format_append_binding(target_type, context:)
        requirement_message = "#{context} requires method #{target_type}.append_format(output: ref[std.string.String]) -> void"
        resolve_explicit_instance_binding(target_type, "append_format", requirement_message:) do |method|
          raise_sema_error("#{context} requires #{target_type}.append_format() to be non-editable") if method.type.receiver_editable
          unless method.type.params.length == 1 && string_builder_ref_type?(method.type.params.first.type)
            raise_sema_error("#{context} requires #{target_type}.append_format(output: ref[std.string.String]) -> void")
          end
          unless method.type.return_type == @types.fetch("void")
            raise_sema_error("#{context} requires #{target_type}.append_format(output: ref[std.string.String]) -> void, got #{method.type.return_type}")
          end
        end
      end

      def resolve_explicit_associated_binding(target_type, method_name, requirement_message:)
        method = lookup_static_method(target_type, method_name)
        if method
          raise_sema_error(requirement_message) unless method.type.receiver_type.nil?

          method = instantiate_function_binding_with_receiver(method, [], receiver_type: target_type) if method.type_params.any?
          yield method

          return method
        end

        if (imported_module = imported_module_with_private_method(target_type, method_name))
          raise_sema_error("#{target_type}.#{method_name} is private to module #{imported_module.name}")
        end

        nil
      end

      def resolve_explicit_instance_binding(target_type, method_name, requirement_message:)
        method = lookup_method(target_type, method_name)
        if method
          raise_sema_error(requirement_message) if method.type.receiver_type.nil?

          method = instantiate_function_binding_with_receiver(method, [], receiver_type: target_type) if method.type_params.any?
          yield method

          return method
        end

        if (imported_module = imported_module_with_private_method(target_type, method_name))
          raise_sema_error("#{target_type}.#{method_name} is private to module #{imported_module.name}")
        end

        nil
      end

      def check_hash_call(resolution, arguments, scopes:)
        raise_sema_error("hash does not support named arguments") if arguments.any?(&:name)
        raise_sema_error("hash expects 1 argument, got #{arguments.length}") unless arguments.length == 1

        validate_hash_operation_argument!(arguments.first.value, resolution.target_type, scopes:, operation: "hash")
        @types.fetch("uint")
      end

      def check_equal_call(resolution, arguments, scopes:)
        raise_sema_error("equal does not support named arguments") if arguments.any?(&:name)
        raise_sema_error("equal expects 2 arguments, got #{arguments.length}") unless arguments.length == 2

        arguments.each do |argument|
          validate_hash_operation_argument!(argument.value, resolution.target_type, scopes:, operation: "equal")
        end

        @types.fetch("bool")
      end

      def check_order_call(resolution, arguments, scopes:)
        raise_sema_error("order does not support named arguments") if arguments.any?(&:name)
        raise_sema_error("order expects 2 arguments, got #{arguments.length}") unless arguments.length == 2

        arguments.each do |argument|
          validate_hash_operation_argument!(argument.value, resolution.target_type, scopes:, operation: "order")
        end

        @types.fetch("int")
      end

      def validate_hash_operation_argument!(expression, target_type, scopes:, operation:)
        actual_type = infer_expression(expression, scopes:)
        expected_pointer_type = const_pointer_to(target_type)
        return if argument_types_compatible?(actual_type, expected_pointer_type, external: false, expression:, scopes:)
        return if ref_type?(actual_type) && types_compatible?(referenced_type(actual_type), target_type, expression:, scopes:)
        return if safe_reference_source_expression?(expression, scopes:) && types_compatible?(actual_type, target_type, expression:, scopes:)

        raise_sema_error("#{operation}[#{target_type}] expects a safe #{target_type} lvalue, ref[#{target_type}], ptr[#{target_type}], or const_ptr[#{target_type}], got #{actual_type}")
      end

      def check_str_buffer_method_call(kind, receiver, arguments, scopes:)
        method_name = str_buffer_method_name(kind)
        receiver_type = infer_expression(receiver, scopes:)
        raise_sema_error("unknown method #{receiver_type}.#{method_name}") unless str_buffer_type?(receiver_type)

        case kind
        when :str_buffer_clear, :str_buffer_len, :str_buffer_capacity, :str_buffer_as_str, :str_buffer_as_cstr
          raise_sema_error("#{method_name} does not support named arguments") if arguments.any?(&:name)
          raise_sema_error("#{method_name} expects 0 arguments, got #{arguments.length}") unless arguments.empty?
        when :str_buffer_assign, :str_buffer_append, :str_buffer_assign_format, :str_buffer_append_format
          raise_sema_error("#{method_name} does not support named arguments") if arguments.any?(&:name)
          raise_sema_error("#{method_name} expects 1 argument, got #{arguments.length}") unless arguments.length == 1
        else
          raise_sema_error("unsupported str_buffer method #{kind}")
        end

        case kind
        when :str_buffer_clear
          record_editable_receiver_expression(receiver)
          raise_sema_error("cannot call editable method #{receiver_type}.clear on an immutable receiver") unless assignable_receiver?(receiver, scopes)

          @types.fetch("void")
        when :str_buffer_assign, :str_buffer_append, :str_buffer_assign_format, :str_buffer_append_format
          record_editable_receiver_expression(receiver)
          raise_sema_error("cannot call editable method #{receiver_type}.#{method_name} on an immutable receiver") unless assignable_receiver?(receiver, scopes)

          actual_type = infer_expression(arguments.first.value, scopes:, expected_type: @types.fetch("str"))
          ensure_argument_assignable!(
            actual_type,
            @types.fetch("str"),
            external: false,
            message: "argument value to #{receiver_type}.#{method_name} expects str, got #{actual_type}",
            expression: arguments.first.value,
          )

          @types.fetch("void")
        when :str_buffer_len, :str_buffer_capacity
          @types.fetch("ptr_uint")
        when :str_buffer_as_str
          raise_sema_error("#{receiver_type}.as_str requires a safe stored receiver") unless safe_reference_source_expression?(receiver, scopes:)

          @types.fetch("str")
        when :str_buffer_as_cstr
          raise_sema_error("#{receiver_type}.as_cstr requires a safe stored receiver") unless safe_reference_source_expression?(receiver, scopes:)

          @types.fetch("cstr")
        else
          raise_sema_error("unsupported str_buffer method #{kind}")
        end
      end

      def check_event_method_call(kind, receiver, arguments, scopes:)
        method_name = event_method_name(kind)
        receiver_type = infer_expression(receiver, scopes:)
        raise_sema_error("unknown method #{receiver_type}.#{method_name}") unless event_type?(receiver_type)

        raise_sema_error("#{method_name} does not support named arguments") if arguments.any?(&:name)
        raise_sema_error("cannot call editable method #{receiver_type}.#{method_name} on an immutable receiver") unless event_receiver_mutable?(receiver, scopes:)
        if kind == :event_emit
          raise_sema_error("#{receiver_type}.emit is only available inside module #{receiver_type.module_name}") unless receiver_type.module_name == @module_name
        end

        case kind
        when :event_subscribe, :event_subscribe_once
          if arguments.length == 2 && arguments.none?(&:name)
            state_type = infer_expression(arguments[0].value, scopes:)
            unless pointer_type?(state_type)
              raise_sema_error("first argument to #{receiver_type}.#{method_name} stateful overload must be a non-null pointer, got #{state_type}")
            end

            state_pointed_type = state_type.arguments.first
            expected_listener_type = event_stateful_listener_type(receiver_type, state_pointed_type)
            actual_listener_type = infer_expression(arguments[1].value, scopes:, expected_type: expected_listener_type)
            ensure_argument_assignable!(
              actual_listener_type,
              expected_listener_type,
              external: false,
              message: "listener argument to #{receiver_type}.#{method_name} expects #{expected_listener_type}, got #{actual_listener_type}",
              expression: arguments[1].value,
            )
          elsif arguments.length == 1
            listener_type = event_listener_type(receiver_type)
            actual_type = infer_expression(arguments.first.value, scopes:, expected_type: listener_type)
            ensure_argument_assignable!(
              actual_type,
              listener_type,
              external: false,
              message: "argument listener to #{receiver_type}.#{method_name} expects #{listener_type}, got #{actual_type}",
              expression: arguments.first.value,
            )
          else
            raise_sema_error("#{method_name} expects 1 or 2 arguments, got #{arguments.length}")
          end

          event_subscription_result_type
        when :event_unsubscribe
          raise_sema_error("unsubscribe expects 1 argument, got #{arguments.length}") unless arguments.length == 1

          actual_type = infer_expression(arguments.first.value, scopes:, expected_type: @types.fetch("Subscription"))
          ensure_argument_assignable!(
            actual_type,
            @types.fetch("Subscription"),
            external: false,
            message: "argument subscription to #{receiver_type}.unsubscribe expects Subscription, got #{actual_type}",
            expression: arguments.first.value,
          )

          @types.fetch("bool")
        when :event_emit
          if receiver_type.payload_type.nil?
            raise_sema_error("emit expects 0 arguments, got #{arguments.length}") unless arguments.empty?
          else
            raise_sema_error("emit expects 1 argument, got #{arguments.length}") unless arguments.length == 1

            actual_type = infer_expression(arguments.first.value, scopes:, expected_type: receiver_type.payload_type)
            ensure_argument_assignable!(
              actual_type,
              receiver_type.payload_type,
              external: false,
              message: "argument value to #{receiver_type}.emit expects #{receiver_type.payload_type}, got #{actual_type}",
              expression: arguments.first.value,
            )
          end

          @types.fetch("void")
        when :event_wait
          raise_sema_error("wait expects 0 arguments, got #{arguments.length}") unless arguments.empty?

          Types::Task.new(event_wait_result_type(receiver_type))
        else
          raise_sema_error("unsupported event method #{kind}")
        end
      end

      def event_listener_type(event_type)
        params = []
        params << Types::Parameter.new("value", event_type.payload_type) if event_type.payload_type

        Types::Function.new(
          nil,
          params:,
          return_type: @types.fetch("void"),
          external: false,
        )
      end

      def event_stateful_listener_type(event_type, state_type)
        params = [Types::Parameter.new("state", Types::GenericInstance.new("ptr", [state_type]))]
        params << Types::Parameter.new("value", event_type.payload_type) if event_type.payload_type

        Types::Function.new(
          nil,
          params:,
          return_type: @types.fetch("void"),
          external: false,
        )
      end

      def event_subscription_result_type
        @types.fetch("Result").instantiate([@types.fetch("Subscription"), @types.fetch("EventError")])
      end

      def event_wait_result_type(event_type)
        payload_type = event_type.payload_type || @types.fetch("void")
        @types.fetch("Result").instantiate([payload_type, @types.fetch("EventError")])
      end

      def event_method_kind(receiver_type, name)
        return unless event_type?(receiver_type)

        case name
        when "subscribe"
          :event_subscribe
        when "subscribe_once"
          :event_subscribe_once
        when "unsubscribe"
          :event_unsubscribe
        when "emit"
          :event_emit
        when "wait"
          :event_wait
        end
      end

      def event_method_name(kind)
        {
          event_subscribe: "subscribe",
          event_subscribe_once: "subscribe_once",
          event_unsubscribe: "unsubscribe",
          event_emit: "emit",
          event_wait: "wait",
        }.fetch(kind)
      end

      def event_visible_from_current_module?(event_type)
        event_type.module_name == @module_name || event_type.visibility == :public
      end

      def event_receiver_mutable?(receiver_expression, scopes:)
        return true if top_level_event_receiver?(receiver_expression, scopes:)
        return false unless receiver_expression.is_a?(AST::MemberAccess)

        receiver_type = infer_lvalue_receiver(
          receiver_expression.receiver,
          scopes:,
          allow_ref_identifier: true,
          allow_pointer_identifier: true,
          require_mutable_pointer: true,
          allow_span_param_identifier: true,
        )
        receiver_type = project_field_receiver_type(receiver_type, require_mutable_pointer: true)
        !event_member_type(receiver_type, receiver_expression.member).nil?
      rescue SemaError
        false
      end

      def top_level_event_receiver?(receiver_expression, scopes:)
        case receiver_expression
        when AST::Identifier
          binding = lookup_value(receiver_expression.name, scopes)
          binding&.kind == :event
        when AST::MemberAccess
          return false unless receiver_expression.receiver.is_a?(AST::Identifier) && @imports.key?(receiver_expression.receiver.name)

          imported_module = @imports.fetch(receiver_expression.receiver.name)
          binding = imported_module.values[receiver_expression.member]
          binding && binding.kind == :event
        else
          false
        end
      end

      def event_member_type(receiver_type, name)
        owner_type = receiver_type
        owner_type = owner_type.definition if owner_type.is_a?(Types::StructInstance)
        return unless owner_type.respond_to?(:event)

        owner_type.event(name)
      end

      def fresh_noncopyable_event_initializer?(expression, target_type, scopes:)
        return true unless expression

        case expression
        when AST::Call
          callable_kind, callable, _receiver = resolve_callable(expression.callee, scopes:)
          callable_kind == :struct && callable == target_type
        when AST::Specialization
          return false unless expression.callee.is_a?(AST::Identifier)
          return false unless %w[zero default].include?(expression.callee.name)
          return false unless expression.arguments.length == 1

          type_arg = expression.arguments.first.value
          type_arg.is_a?(AST::TypeRef) && resolve_type_ref(type_arg) == target_type
        else
          false
        end
      rescue SemaError
        false
      end

      def char_array_removed_text_method?(receiver_type, name)
        return unless char_array_text_type?(receiver_type)

        name == "as_str" || name == "as_cstr"
      end

      def str_buffer_method_kind(receiver_type, name)
        return unless str_buffer_type?(receiver_type)

        case name
        when "clear"
          :str_buffer_clear
        when "assign"
          :str_buffer_assign
        when "append"
          :str_buffer_append
        when "assign_format"
          :str_buffer_assign_format
        when "append_format"
          :str_buffer_append_format
        when "len"
          :str_buffer_len
        when "capacity"
          :str_buffer_capacity
        when "as_str"
          :str_buffer_as_str
        when "as_cstr"
          :str_buffer_as_cstr
        end
      end

      def str_buffer_method_name(kind)
        {
          str_buffer_clear: "clear",
          str_buffer_assign: "assign",
          str_buffer_append: "append",
          str_buffer_assign_format: "assign_format",
          str_buffer_append_format: "append_format",
          str_buffer_len: "len",
          str_buffer_capacity: "capacity",
          str_buffer_as_str: "as_str",
          str_buffer_as_cstr: "as_cstr",
        }.fetch(kind)
      end

      def check_function_call(binding, arguments, scopes:)
        if arguments.any?(&:name)
          raise_sema_error("function #{binding.name} does not support named arguments")
        end

        expected_params = binding.type.params
        unless call_arity_matches?(binding.type, arguments.length)
          raise_sema_error(arity_error_message(binding.type, binding.name, arguments.length))
        end

        expected_params.each_with_index do |parameter, index|
          argument = arguments.fetch(index)
          actual_type = foreign_argument_actual_type(parameter, argument, scopes:, function_name: binding.name, expected_type: parameter.type)
          record_mutating_argument_identifier(argument, parameter)
          if foreign_cstr_boundary_parameter?(parameter)
            unless foreign_cstr_argument_compatible?(actual_type, parameter, expression: foreign_argument_expression(argument))
              raise_sema_error("argument #{parameter.name} to #{binding.name} expects #{parameter.type}, got #{actual_type}")
            end
          else
            unless call_argument_compatible?(actual_type, parameter.type, scopes:, external: binding.external, expression: foreign_argument_expression(argument))
              suggestion = explicit_cast_suggestion(actual_type, parameter.type)
              raise_sema_error("argument #{parameter.name} to #{binding.name} expects #{parameter.type}, got #{actual_type}", suggestion:)
            end
          end
        end

        arguments.drop(expected_params.length).each do |argument|
          infer_expression(argument.value, scopes:)
        end
      end

      def record_mutating_argument_identifier(argument, parameter)
        return unless %i[out inout].include?(parameter.passing_mode)
        return unless argument.value.is_a?(AST::Identifier)

        @mutating_argument_identifier_ids[argument.value.object_id] = true
      end
      def check_callable_value_call(function_type, arguments, scopes:, callee_expression:)
        if arguments.any?(&:name)
          raise_sema_error("#{describe_expression(callee_expression)} does not support named arguments")
        end

        unless call_arity_matches?(function_type, arguments.length)
          raise_sema_error(arity_error_message(function_type, describe_expression(callee_expression), arguments.length))
        end

        function_type.params.each_with_index do |parameter, index|
          argument = arguments.fetch(index)
          actual_type = infer_expression(argument.value, scopes:, expected_type: parameter.type)
          unless call_argument_compatible?(actual_type, parameter.type, scopes:, external: false, expression: argument.value)
            suggestion = explicit_cast_suggestion(actual_type, parameter.type)
            raise_sema_error("argument #{parameter.name || index} to #{describe_expression(callee_expression)} expects #{parameter.type}, got #{actual_type}", argument, suggestion:)
          end
        end

        arguments.drop(function_type.params.length).each do |argument|
          infer_expression(argument.value, scopes:)
        end
      end
      def check_fatal_call(arguments, scopes:)
        raise_sema_error("fatal does not support named arguments") if arguments.any?(&:name)
        raise_sema_error("fatal expects 1 argument, got #{arguments.length}") unless arguments.length == 1

        message_type = infer_expression(arguments.first.value, scopes:, expected_type: @types.fetch("str"))
        return @types.fetch("void") if string_like_type?(message_type)

        raise_sema_error("fatal expects str or cstr, got #{message_type}")
      end
      def check_get_call(arguments, scopes:)
        raise_sema_error("get does not support named arguments") if arguments.any?(&:name)
        raise_sema_error("get expects 2 arguments, got #{arguments.length}") unless arguments.length == 2

        source_expr = arguments.first.value
        index_expr = arguments[1].value
        source_type = infer_expression(source_expr, scopes:)
        index_type = infer_expression(index_expr, scopes:)
        raise_sema_error("get index must be an integer type, got #{index_type}") unless integer_type?(index_type)

        if array_type?(source_type)
          raise_sema_error("get requires an addressable array value") unless addressable_storage_expression?(source_expr, scopes:)

          Types::Nullable.new(pointer_to(array_element_type(source_type)))
        elsif source_type.is_a?(Types::Span)
          Types::Nullable.new(pointer_to(source_type.element_type))
        else
          raise_sema_error("get expects an array or span, got #{source_type}")
        end
      end
      def check_ref_of_call(arguments, scopes:)
        raise_sema_error("ref_of does not support named arguments") if arguments.any?(&:name)
        raise_sema_error("ref_of expects 1 argument, got #{arguments.length}") unless arguments.length == 1

        source_type = infer_addr_source_type(arguments.first.value, scopes:)
        Types::GenericInstance.new("ref", [source_type])
      end
      def check_const_ptr_of_call(arguments, scopes:)
        raise_sema_error("const_ptr_of does not support named arguments") if arguments.any?(&:name)
        raise_sema_error("const_ptr_of expects 1 argument, got #{arguments.length}") unless arguments.length == 1

        source_type = infer_ro_addr_source_type(arguments.first.value, scopes:)
        const_pointer_to(source_type)
      end
      def check_read_call(arguments, scopes:)
        validate_read_call_arguments!(arguments)

        infer_reference_value_type(arguments.first.value, scopes:)
      end
      def check_ptr_of_call(arguments, scopes:)
        raise_sema_error("ptr_of does not support named arguments") if arguments.any?(&:name)
        raise_sema_error("ptr_of expects 1 argument, got #{arguments.length}") unless arguments.length == 1

        source_expression = arguments.first.value
        source_type = infer_expression(source_expression, scopes:)
        return pointer_to(referenced_type(source_type)) if ref_type?(source_type)

        pointer_to(infer_addr_source_type(source_expression, scopes:))
      end
      def check_field_of_call(arguments, scopes:)
        raise_sema_error("field_of does not support named arguments") if arguments.any?(&:name)
        raise_sema_error("field_of expects 2 arguments, got #{arguments.length}") unless arguments.length == 2

        evaluate_field_of_call(arguments, scopes:)
        builtin_field_handle_type
      end
      def check_callable_of_call(arguments, scopes:)
        raise_sema_error("callable_of does not support named arguments") if arguments.any?(&:name)
        raise_sema_error("callable_of expects 1 argument, got #{arguments.length}") unless arguments.length == 1

        evaluate_callable_of_call(arguments, scopes:)
        builtin_callable_handle_type
      end
      def check_has_attribute_call(arguments, scopes:)
        raise_sema_error("has_attribute does not support named arguments") if arguments.any?(&:name)
        raise_sema_error("has_attribute expects 2 arguments, got #{arguments.length}") unless arguments.length == 2

        target = resolve_reflection_target_argument(arguments.first.value, scopes:)
        binding = resolve_attribute_name_argument(arguments[1].value)
        validate_attribute_target_compatibility!(target, binding)

        @types.fetch("bool")
      end
      def check_attribute_of_call(arguments, scopes:)
        raise_sema_error("attribute_of does not support named arguments") if arguments.any?(&:name)
        raise_sema_error("attribute_of expects 2 arguments, got #{arguments.length}") unless arguments.length == 2

        target = resolve_reflection_target_argument(arguments.first.value, scopes:)
        binding = resolve_attribute_name_argument(arguments[1].value)
        validate_attribute_target_compatibility!(target, binding)

        application = find_attribute_application(target, binding)
        unless application || attribute_presence_guard_active?(scopes, attribute_presence_refinement_key(target, binding))
          raise_sema_error("attribute #{qualified_attribute_name(binding)} is not applied to #{target}")
        end

        builtin_attribute_handle_type
      end
      def check_attribute_arg_call(expected_type, arguments, scopes:)
        raise_sema_error("attribute_arg does not support named arguments") if arguments.any?(&:name)
        raise_sema_error("attribute_arg expects 2 arguments, got #{arguments.length}") unless arguments.length == 2

        handle_value = evaluate_compile_time_const_value(arguments.first.value, scopes:)
        parameter_source = if handle_value.is_a?(Types::AttributeHandle)
          [handle_value.attribute_name, handle_value.params]
        else
          handle_type = infer_expression(arguments.first.value, scopes:)
          raise_sema_error("attribute_arg expects an attribute handle") unless handle_type == builtin_attribute_handle_type

          binding = attribute_binding_for_handle_expression(arguments.first.value)
          raise_sema_error("attribute_arg expects an attribute handle") unless binding

          [binding.name, binding.params]
        end

        param_name = reflection_identifier_name(arguments[1].value, context: "attribute_arg")
        attribute_name, params = parameter_source
        parameter = params.find { |candidate| candidate.name == param_name }
        raise_sema_error("attribute #{attribute_name} has no parameter #{param_name}") unless parameter
        raise_sema_error("attribute_arg[#{expected_type}] does not match declared type #{parameter.type} for #{attribute_name}.#{param_name}") unless parameter.type == expected_type

        expected_type
      end

      def attribute_binding_for_handle_expression(expression)
        return unless expression.is_a?(AST::Call)
        return unless expression.callee.is_a?(AST::Identifier) && expression.callee.name == "attribute_of"
        return unless expression.arguments.length == 2 && expression.arguments.none?(&:name)

        resolve_attribute_name_argument(expression.arguments[1].value)
      end

      def check_adapt_call(interface, arguments, scopes:)
        raise_sema_error("adapt does not support named arguments") if arguments.any?(&:name)
        raise_sema_error("adapt expects 1 argument, got #{arguments.length}") unless arguments.length == 1

        argument = arguments.first
        concrete_type = infer_expression(argument.value, scopes:)
        concrete_type = referenced_type(concrete_type) if ref_type?(concrete_type)
        unless concrete_type.is_a?(Types::Struct) || concrete_type.is_a?(Types::Opaque) || concrete_type.is_a?(Types::StructInstance)
          raise_sema_error("adapt requires a struct or opaque type, got #{concrete_type}")
        end

        unless type_implements_interface?(concrete_type, interface)
          raise_sema_error("#{concrete_type} does not implement #{interface.name}")
        end

        Types::Dyn.new(interface, interface.type_arguments || [])
      end

      def resolve_adapt_interface(type_arg)
        parts = type_arg.name.parts
        type_args = type_arg.arguments.map { |a| a.value }
        interface_ref = AST::QualifiedName.new(parts:, type_arguments: type_args)
        resolve_interface_ref(interface_ref)
      end

      def check_dyn_method_call(method_binding, _receiver, arguments, scopes:)
        raise_sema_error("method call on dyn value does not support named arguments") if arguments.any?(&:name)
        raise_sema_error("#{method_binding.name} expects #{method_binding.params.length} arguments, got #{arguments.length}") unless arguments.length == method_binding.params.length

        method_binding.params.each_with_index do |param, index|
          actual_type = infer_expression(arguments[index].value, scopes:, expected_type: param.type)
          ensure_assignable!(
            actual_type,
            param.type,
            "argument #{index + 1} of #{method_binding.name} expects #{param.type}, got #{actual_type}",
            expression: arguments[index].value,
          )
        end
      end
    end
  end
end

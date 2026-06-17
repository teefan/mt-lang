# frozen_string_literal: true

require "fiddle"

module MilkTea
  module Types
    BUILTIN_PRIMITIVE_NAMES = %w[
      bool byte ubyte char short ushort int uint long ulong ptr_int ptr_uint float double void str cstr
      vec2 vec3 vec4 ivec2 ivec3 ivec4 mat3 mat4 quat
    ].freeze
    RESERVED_VALUE_TYPE_NAMES = (BUILTIN_PRIMITIVE_NAMES + %w[
      Option Result
    ]).freeze
    RESERVED_IMPORT_ALIAS_NAMES = %w[
      Option Result
    ].freeze
    BUILTIN_TYPE_NAMES = (BUILTIN_PRIMITIVE_NAMES + %w[
      ptr const_ptr ref span array str_buffer atomic Task Option Result SoA
      struct_handle field_handle callable_handle attribute_handle member_handle type
      EventError Subscription
    ]).freeze
    RESERVED_TYPE_BINDING_NAMES = BUILTIN_TYPE_NAMES

    def self.substitute_type_variables(type, substitutions)
      case type
      when TypeVar
        substitutions.fetch(type.name, type)
      when LifetimeRef
        substitutions.fetch(type.name, type)
      when Nullable
        Nullable.new(substitute_type_variables(type.base, substitutions))
      when GenericInstance
        GenericInstance.new(type.name, type.arguments.map { |argument| argument.is_a?(LiteralTypeArg) ? argument : substitute_type_variables(argument, substitutions) })
      when Span
        Span.new(substitute_type_variables(type.element_type, substitutions))
      when Task
        Task.new(substitute_type_variables(type.result_type, substitutions))
      when Proc
        Proc.new(
          params: type.params.map do |param|
            Parameter.new(
              param.name,
              substitute_type_variables(param.type, substitutions),
              mutable: param.mutable,
              passing_mode: param.passing_mode,
              boundary_type: param.boundary_type ? substitute_type_variables(param.boundary_type, substitutions) : nil,
            )
          end,
          return_type: substitute_type_variables(type.return_type, substitutions),
        )
      when Function
        Function.new(
          type.name,
          params: type.params.map do |param|
            Parameter.new(
              param.name,
              substitute_type_variables(param.type, substitutions),
              mutable: param.mutable,
              passing_mode: param.passing_mode,
              boundary_type: param.boundary_type ? substitute_type_variables(param.boundary_type, substitutions) : nil,
            )
          end,
          return_type: substitute_type_variables(type.return_type, substitutions),
          receiver_type: type.receiver_type ? substitute_type_variables(type.receiver_type, substitutions) : nil,
          receiver_editable: type.receiver_editable,
          external: type.external,
        )
      when Event
        Event.new(
          type.name,
          capacity: type.capacity,
          payload_type: type.payload_type ? substitute_type_variables(type.payload_type, substitutions) : nil,
          module_name: type.module_name,
          visibility: type.visibility,
          owner_type_name: type.owner_type_name,
        )
      when StructInstance
        type.definition.instantiate(type.arguments.map { |argument| substitute_type_variables(argument, substitutions) })
      when VariantInstance
        type.definition.instantiate(type.arguments.map { |argument| substitute_type_variables(argument, substitutions) })
      else
        type
      end
    end

    class Base
      def bitwise?
        false
      end

      def numeric?
        false
      end

      def integer?
        false
      end

      def float?
        false
      end

      def boolean?
        false
      end

      def void?
        false
      end

      def nullable?
        false
      end

      def sendable?
        false
      end

      def field_c_name(name)
        name
      end
    end

    class ReflectionHandleType < Base
      attr_reader :name

      def initialize(name)
        @name = name
        freeze
      end

      def eql?(other)
        other.is_a?(ReflectionHandleType) && other.name == name
      end

      alias == eql?

      def hash
        [self.class, name].hash
      end

      def sendable?
        true
      end

      def to_s
        name
      end
    end

    BUILTIN_STRUCT_HANDLE_TYPE = ReflectionHandleType.new("struct_handle")
    BUILTIN_FIELD_HANDLE_TYPE = ReflectionHandleType.new("field_handle")
    BUILTIN_CALLABLE_HANDLE_TYPE = ReflectionHandleType.new("callable_handle")
    BUILTIN_ATTRIBUTE_HANDLE_TYPE = ReflectionHandleType.new("attribute_handle")
    BUILTIN_MEMBER_HANDLE_TYPE = ReflectionHandleType.new("member_handle")

    class TypeType < Base
      def initialize
        freeze
      end

      def eql?(other)
        other.is_a?(TypeType)
      end

      alias == eql?

      def hash
        self.class.hash
      end

      def sendable?
        true
      end

      def to_s
        "type"
      end
    end

    BUILTIN_TYPE_META_TYPE = TypeType.new

    class Primitive < Base
      POINTER_INTEGER_WIDTH = Fiddle::SIZEOF_VOIDP * 8

      INTEGER_NAMES = %w[byte short int long ubyte ushort uint ulong ptr_int ptr_uint].freeze
      FLOAT_NAMES = %w[float double].freeze
      FIXED_SIGNED_INTEGER_WIDTHS = {
        "byte" => 8,
        "short" => 16,
        "int" => 32,
        "long" => 64,
      }.freeze
      FIXED_UNSIGNED_INTEGER_WIDTHS = {
        "ubyte" => 8,
        "ushort" => 16,
        "uint" => 32,
        "ulong" => 64,
      }.freeze
      FLOAT_WIDTHS = {
        "float" => 32,
        "double" => 64,
      }.freeze

      attr_reader :name

      def initialize(name)
        @name = name
        freeze
      end

      def eql?(other)
        other.is_a?(Primitive) && other.name == name
      end

      alias == eql?

      def hash
        [self.class, name].hash
      end

      def numeric?
        integer? || float?
      end

      def bitwise?
        integer?
      end

      def integer?
        INTEGER_NAMES.include?(name)
      end

      def float?
        FLOAT_NAMES.include?(name)
      end

      def signed_integer?
        FIXED_SIGNED_INTEGER_WIDTHS.key?(name) || name == "ptr_int"
      end

      def unsigned_integer?
        FIXED_UNSIGNED_INTEGER_WIDTHS.key?(name) || name == "ptr_uint"
      end

      def fixed_width_integer?
        FIXED_SIGNED_INTEGER_WIDTHS.key?(name) || FIXED_UNSIGNED_INTEGER_WIDTHS.key?(name) || pointer_sized_integer?
      end

      def pointer_sized_integer?
        name == "ptr_int" || name == "ptr_uint"
      end

      def integer_width
        FIXED_SIGNED_INTEGER_WIDTHS[name] || FIXED_UNSIGNED_INTEGER_WIDTHS[name] || (pointer_sized_integer? ? POINTER_INTEGER_WIDTH : nil)
      end

      def float_width
        FLOAT_WIDTHS[name]
      end

      def boolean?
        name == "bool"
      end

      def void?
        name == "void"
      end

      def sendable?
        name != "str"
      end

      def to_s
        name
      end
    end

    class Null < Base
      attr_reader :target_type

      def initialize(target_type = nil)
        @target_type = target_type
        freeze
      end

      def eql?(other)
        other.is_a?(Null) && other.target_type == target_type
      end

      alias == eql?

      def hash
        [self.class, target_type].hash
      end

      def sendable?
        true
      end

      def to_s
        target_type ? "null[#{target_type}]" : "null"
      end
    end

    class Error < Base
      def eql?(other)
        other.is_a?(Error)
      end

      alias == eql?

      def hash
        self.class.hash
      end

      def to_s
        "<error>"
      end
    end

    class StructHandle < Base
      attr_reader :struct_type, :declaration

      def initialize(struct_type, declaration)
        @struct_type = struct_type
        @declaration = declaration
        freeze
      end

      def eql?(other)
        other.is_a?(StructHandle) && other.struct_type == struct_type
      end

      alias == eql?

      def hash
        [self.class, struct_type].hash
      end

      def sendable?
        true
      end

      def to_s
        "field target #{struct_type}"
      end
    end

    class FieldHandle < Base
      attr_reader :struct_handle, :field_name, :field_declaration

      def initialize(struct_handle, field_name, field_declaration)
        @struct_handle = struct_handle
        @field_name = field_name
        @field_declaration = field_declaration
        freeze
      end

      def eql?(other)
        other.is_a?(FieldHandle) && other.struct_handle == struct_handle && other.field_name == field_name
      end

      alias == eql?

      def hash
        [self.class, struct_handle, field_name].hash
      end

      def sendable?
        true
      end

      def to_s
        "field_of(#{struct_handle.struct_type}, #{field_name})"
      end
    end

    class CallableHandle < Base
      attr_reader :display_name, :declaration

      def initialize(display_name, declaration)
        @display_name = display_name
        @declaration = declaration
        freeze
      end

      def eql?(other)
        other.is_a?(CallableHandle) && other.display_name == display_name
      end

      alias == eql?

      def hash
        [self.class, display_name].hash
      end

      def sendable?
        true
      end

      def to_s
        "callable_of(#{display_name})"
      end
    end

    class AttributeHandle < Base
      attr_reader :attribute_name, :attribute_module_name, :target, :params, :argument_values

      def initialize(attribute_name, attribute_module_name, target, params, argument_values)
        @attribute_name = attribute_name
        @attribute_module_name = attribute_module_name
        @target = target
        @params = params.freeze
        @argument_values = argument_values&.freeze
        freeze
      end

      def eql?(other)
        other.is_a?(AttributeHandle) &&
          other.attribute_name == attribute_name &&
          other.attribute_module_name == attribute_module_name &&
          other.target == target
      end

      alias == eql?

      def hash
        [self.class, attribute_module_name, attribute_name, target].hash
      end

      def sendable?
        true
      end

      def to_s
        qualifier = attribute_module_name ? "#{attribute_module_name}." : ""
        "attribute_of(#{target}, #{qualifier}#{attribute_name})"
      end
    end

    class MemberHandle < Base
      attr_reader :enum_handle, :member_name, :member_value

      def initialize(enum_handle, member_name, member_value)
        @enum_handle = enum_handle
        @member_name = member_name
        @member_value = member_value
        freeze
      end

      def name
        member_name
      end

      def value
        member_value
      end

      def eql?(other)
        other.is_a?(MemberHandle) && other.member_name == member_name && other.enum_handle == enum_handle
      end

      alias == eql?

      def hash
        [self.class, enum_handle, member_name].hash
      end

      def sendable?
        true
      end

      def to_s
        "member_of(#{enum_handle}, #{member_name})"
      end
    end

    class Nullable < Base
      attr_reader :base

      def initialize(base)
        @base = base
        freeze
      end

      def eql?(other)
        other.is_a?(Nullable) && other.base == base
      end

      alias == eql?

      def hash
        [self.class, base].hash
      end

      def nullable?
        true
      end

      def sendable?
        base.sendable?
      end

      def to_s
        "#{base}?"
      end
    end

    class LiteralTypeArg
      attr_reader :value

      def initialize(value)
        @value = value
        freeze
      end

      def eql?(other)
        other.is_a?(LiteralTypeArg) && other.value == value
      end

      alias == eql?

      def hash
        [self.class, value].hash
      end

      def to_s
        value.to_s
      end
    end

    class GenericInstance < Base
      attr_reader :name, :arguments

      def initialize(name, arguments)
        @name = name
        @arguments = arguments.freeze
        freeze
      end

      def eql?(other)
        other.is_a?(GenericInstance) && other.name == name && other.arguments == arguments
      end

      alias == eql?

      def hash
        [self.class, name, arguments].hash
      end

      def sendable?
        case name
        when "ptr", "const_ptr", "ref"
          false
        when "array"
          el = arguments.first
          el.is_a?(LiteralTypeArg) ? true : el.sendable?
        when "str_buffer"
          true
        when "atomic"
          true
        else
          false
        end
      end

      def to_s
        "#{name}[#{arguments.join(', ')}]"
      end
    end

    class TypeVar < Base
      attr_reader :name

      def initialize(name)
        @name = name
        freeze
      end

      def eql?(other)
        other.is_a?(TypeVar) && other.name == name
      end

      alias == eql?

      def hash

        @name.hash
      end

      def sendable?
        true
      end

      def to_s
        name
      end
    end

    class LifetimeRef < Base
      attr_reader :name

      def initialize(name)
        @name = name
        freeze
      end

      def eql?(other)
        other.is_a?(LifetimeRef) && other.name == name
      end

      alias == eql?

      def hash
        @name.hash
      end

      def sendable?
        true
      end

      def to_s
        name
      end
    end

    class Span < Base
      attr_reader :element_type

      def initialize(element_type)
        @element_type = element_type
        @fields = {
          "data" => GenericInstance.new("ptr", [element_type]),
          "len" => Primitive.new("ptr_uint"),
        }.freeze
        freeze
      end

      def eql?(other)
        other.is_a?(Span) && other.element_type == element_type
      end

      alias == eql?

      def hash
        [self.class, element_type].hash
      end

      def name
        to_s
      end

      def fields
        @fields
      end

      def field(name)
        @fields[name]
      end

      def to_s
        "span[#{element_type}]"
      end
    end

    class StringView < Base
      attr_reader :name, :module_name

      def initialize
        @name = "str"
        @module_name = nil
        @fields = {
          "data" => GenericInstance.new("ptr", [Primitive.new("char")]),
          "len" => Primitive.new("ptr_uint"),
        }.freeze
        freeze
      end

      def eql?(other)
        other.is_a?(StringView)
      end

      alias == eql?

      def hash
        self.class.hash
      end

      def fields
        @fields
      end

      def field(name)
        @fields[name]
      end

      def to_s
        "str"
      end
    end

    class Task < Base
      attr_reader :result_type

      def initialize(result_type)
        @result_type = result_type
        void_ptr = GenericInstance.new("ptr", [Primitive.new("void")])
        wake_fn = Function.new(
          nil,
          params: [Parameter.new("frame", void_ptr)],
          return_type: Primitive.new("void"),
        )
        @fields = {
          "frame" => void_ptr,
          "ready" => Function.new(
            nil,
            params: [Parameter.new("frame", void_ptr)],
            return_type: Primitive.new("bool"),
          ),
          "set_waiter" => Function.new(
            nil,
            params: [
              Parameter.new("frame", void_ptr),
              Parameter.new("waiter_frame", void_ptr),
              Parameter.new("waiter", wake_fn),
            ],
            return_type: Primitive.new("void"),
          ),
          "release" => Function.new(
            nil,
            params: [Parameter.new("frame", void_ptr)],
            return_type: Primitive.new("void"),
          ),
          "take_result" => Function.new(
            nil,
            params: [Parameter.new("frame", void_ptr)],
            return_type: result_type,
          ),
          "cancel" => Function.new(
            nil,
            params: [Parameter.new("frame", void_ptr)],
            return_type: Primitive.new("void"),
          ),
        }.freeze
        freeze
      end

      def eql?(other)
        other.is_a?(Task) && other.result_type == result_type
      end

      alias == eql?

      def hash
        [self.class, result_type].hash
      end

      def name
        to_s
      end

      def fields
        @fields
      end

      def field(name)
        @fields[name]
      end

      def sendable?
        result_type.sendable?
      end

      def to_s
        "Task[#{result_type}]"
      end
    end

    class Subscription < Base
      def field(name)
        {
          "slot" => Primitive.new("ptr_uint"),
          "generation" => Primitive.new("ptr_uint"),
        }.fetch(name)
      end

      def fields
        {
          "slot" => Primitive.new("ptr_uint"),
          "generation" => Primitive.new("ptr_uint"),
        }.freeze
      end

      def name
        "Subscription"
      end

      def module_name
        nil
      end

      def c_name
        "mt_subscription"
      end

      def eql?(other)
        other.is_a?(Subscription)
      end

      alias == eql?

      def hash
        self.class.hash
      end

      def sendable?
        true
      end

      def to_s
        "Subscription"
      end
    end

    class Event < Base
      attr_reader :name, :capacity, :payload_type, :module_name, :visibility, :owner_type_name, :c_name

      def initialize(name, capacity:, payload_type: nil, module_name: nil, visibility: :private, owner_type_name: nil)
        @name = name
        @capacity = capacity
        @payload_type = payload_type
        @module_name = module_name
        @visibility = visibility
        @owner_type_name = owner_type_name
        @c_name = begin
          parts = ["mt_event"]
          parts << module_name&.gsub(/[^A-Za-z0-9_]+/, "_")
          parts << owner_type_name&.gsub(/[^A-Za-z0-9_]+/, "_")
          parts << name.gsub(/[^A-Za-z0-9_]+/, "_")
          parts << payload_type.to_s.gsub(/[^A-Za-z0-9_]+/, "_") if payload_type
          parts << capacity.to_s
          parts.compact.reject(&:empty?).join("_")
        end
        freeze
      end

      def eql?(other)
        other.is_a?(Event) &&
          other.name == name &&
          other.capacity == capacity &&
          other.payload_type == payload_type &&
          other.module_name == module_name &&
          other.visibility == visibility &&
          other.owner_type_name == owner_type_name
      end

      alias == eql?

      def hash
        [self.class, name, capacity, payload_type, module_name, visibility, owner_type_name].hash
      end

      def hidden_field_name
        "__event_#{name}"
      end

      def to_s
        label = owner_type_name ? "#{owner_type_name}.#{name}" : name
        payload = payload_type ? "(#{payload_type})" : ""
        "event #{label}[#{capacity}]#{payload}"
      end
    end

    class GenericStructDefinition < Base
      attr_reader :name, :type_params, :type_param_constraints, :module_name, :external, :packed, :alignment, :c_name, :lifetime_params
      attr_accessor :ast_declaration

      def initialize(name, type_params, module_name: nil, external: false, packed: false, alignment: nil, c_name: nil, lifetime_params: [])
        @name = name
        @type_params = type_params.freeze
        @type_param_constraints = {}.freeze
        @module_name = module_name
        @external = external
        @packed = packed
        @alignment = alignment
        @c_name = c_name
        @lifetime_params = lifetime_params.freeze
        @fields = {}
        @events = {}
        @instances = {}
        @ast_declaration = nil
      end

      def define_fields(fields)
        @fields = fields.freeze
        self
      end

      def define_events(events)
        @events = events.freeze
        self
      end

      def define_type_param_constraints(type_param_constraints)
        @type_param_constraints = type_param_constraints.freeze
        self
      end

      def set_layout(packed:, alignment:)
        @packed = packed
        @alignment = alignment
        @instances.each_value { |instance| instance.set_layout(packed:, alignment:) }
        self
      end

      def fields
        @fields
      end

      def field(name)
        @fields[name]
      end

      def events
        @events
      end

      def event(name)
        @events[name]
      end

      def has_events?
        !@events.empty?
      end

      def sendable?
        return false if has_events?

        fields.each_value.all?(&:sendable?)
      end

      def field_c_name(name)
        stripped = name.delete_suffix("_")
        return stripped if stripped != name && Token::KEYWORDS.key?(stripped)

        name
      end

      def eql?(other)
        other.class == self.class &&
          other.name == name &&
          other.type_params == type_params &&
          other.module_name == module_name &&
          other.external == external &&
          other.packed == packed &&
          other.alignment == alignment &&
          other.c_name == c_name
      end

      alias == eql?

      def hash
        [self.class, name, type_params, module_name, external, packed, alignment, c_name].hash
      end

      def instantiate(arguments)
        raise ArgumentError, "#{name} expects #{type_params.length} type arguments, got #{arguments.length}" unless arguments.length == type_params.length

        key = arguments.dup.freeze
        return @instances[key] if @instances.key?(key)

        substitutions = type_params.zip(arguments).to_h
        lifetime_params.each do |lt|
          substitutions[lt] = arguments.find { |a| a.is_a?(LifetimeRef) && a.name == lt } || LifetimeRef.new(lt)
        end
        instance = StructInstance.new(self, arguments)
        @instances[key] = instance
        instance.define_fields(
          @fields.transform_values { |type| Types.substitute_type_variables(type, substitutions) },
        ).define_events(
          @events.transform_values { |type| Types.substitute_type_variables(type, substitutions) },
        )
      end

      def to_s
        module_name ? "#{module_name}.#{name}" : name
      end
    end

    class Struct < Base
      attr_reader :name, :module_name, :external, :packed, :alignment, :c_name, :lifetime_params, :nested_types
      attr_accessor :ast_declaration

      def initialize(name, module_name: nil, external: false, packed: false, alignment: nil, c_name: nil, lifetime_params: [])
        @name = name
        @module_name = module_name
        @external = external
        @packed = packed
        @alignment = alignment
        @c_name = c_name
        @lifetime_params = lifetime_params.freeze
        @fields = {}
        @events = {}
        @nested_types = {}
        @ast_declaration = nil
      end

      def define_fields(fields)
        @fields = fields.freeze
        self
      end

      def define_events(events)
        @events = events.freeze
        self
      end

      def define_nested_type(name, type)
        @nested_types[name] = type
        self
      end

      def define_nested_types(nested)
        @nested_types = nested.freeze
        self
      end

      def set_layout(packed:, alignment:)
        @packed = packed
        @alignment = alignment
        self
      end

      def fields
        @fields
      end

      def field(name)
        @fields[name]
      end

      def events
        @events
      end

      def event(name)
        @events[name]
      end

      def has_events?
        !@events.empty?
      end

      def sendable?
        return false if has_events?

        fields.each_value.all?(&:sendable?)
      end

      def field_c_name(name)
        stripped = name.delete_suffix("_")
        return stripped if stripped != name && Token::KEYWORDS.key?(stripped)

        name
      end

      def eql?(other)
        other.class == self.class &&
          other.name == name &&
          other.module_name == module_name &&
          other.external == external &&
          other.packed == packed &&
          other.alignment == alignment &&
          other.c_name == c_name
      end

      alias == eql?

      def hash
        [self.class, name, module_name, external, packed, alignment, c_name].hash
      end

      def to_s
        module_name ? "#{module_name}.#{name}" : name
      end
    end

    class StructInstance < Struct
      attr_reader :definition, :arguments

      def initialize(definition, arguments)
        super(
          definition.name,
          module_name: definition.module_name,
          external: definition.external,
          packed: definition.packed,
          alignment: definition.alignment,
          c_name: definition.c_name,
          lifetime_params: definition.lifetime_params,
        )
        @definition = definition
        @arguments = arguments.freeze
        @nested_types = definition.respond_to?(:nested_types) ? definition.nested_types.dup : {}
      end

      def eql?(other)
        other.is_a?(StructInstance) && other.definition == definition && other.arguments == arguments
      end

      alias == eql?

      def hash
        [self.class, definition, arguments].hash
      end

      def to_s
        base = module_name ? "#{module_name}.#{name}" : name
        "#{base}[#{arguments.join(', ')}]"
      end
    end

    class Union < Struct
    end

    # A user-defined tagged union (discriminated union). Each arm may carry zero
    # or more named payload fields. Arms with no fields carry only the discriminant.
    class Variant < Base
      attr_reader :name, :module_name

      def initialize(name, module_name: nil)
        @name = name
        @module_name = module_name
        @arms = {}       # arm_name => { field_name => type }
        @arm_names = []
      end

      def define_arms(arms_hash)
        @arms = arms_hash.freeze
        @arm_names = arms_hash.keys.freeze
        self
      end

      def arm(name)
        @arms[name]
      end

      def arm_names
        @arm_names
      end

      def has_payload?(arm_name)
        fields = @arms[arm_name]
        fields && !fields.empty?
      end

      def sendable?
        @arm_names.all? { |arm_name| @arms[arm_name].each_value.all?(&:sendable?) }
      end

      def eql?(other)
        other.class == self.class && other.name == name && other.module_name == module_name
      end

      alias == eql?

      def hash
        [self.class, name, module_name].hash
      end

      def to_s
        module_name ? "#{module_name}.#{name}" : name
      end
    end

    class GenericVariantDefinition < Base
      attr_reader :name, :type_params, :type_param_constraints, :module_name

      def initialize(name, type_params, module_name: nil)
        @name = name
        @type_params = type_params.freeze
        @type_param_constraints = {}.freeze
        @module_name = module_name
        @arms = {}
        @instances = {}
      end

      def define_arms(arms_hash)
        @arms = arms_hash.freeze
        self
      end

      def arms
        @arms
      end

      def define_type_param_constraints(type_param_constraints)
        @type_param_constraints = type_param_constraints.freeze
        self
      end

      def sendable?
        @arms.each_value.all? { |fields| fields.each_value.all?(&:sendable?) }
      end

      def eql?(other)
        other.class == self.class &&
          other.name == name &&
          other.type_params == type_params &&
          other.module_name == module_name
      end

      alias == eql?

      def hash
        [self.class, name, type_params, module_name].hash
      end

      def instantiate(arguments)
        raise ArgumentError, "#{name} expects #{type_params.length} type arguments, got #{arguments.length}" unless arguments.length == type_params.length

        key = arguments.dup.freeze
        return @instances[key] if @instances.key?(key)

        substitutions = type_params.zip(arguments).to_h
        instance = VariantInstance.new(self, arguments)
        @instances[key] = instance
        instance.define_arms(
          @arms.transform_values do |fields|
            fields.transform_values { |type| Types.substitute_type_variables(type, substitutions) }
          end,
        )
      end

      def to_s
        module_name ? "#{module_name}.#{name}" : name
      end
    end

    class VariantInstance < Variant
      attr_reader :definition, :arguments

      def initialize(definition, arguments)
        super(definition.name, module_name: definition.module_name)
        @definition = definition
        @arguments = arguments.freeze
      end

      def eql?(other)
        other.is_a?(VariantInstance) && other.definition == definition && other.arguments == arguments
      end

      alias == eql?

      def hash
        [self.class, definition, arguments].hash
      end

      def to_s
        base = module_name ? "#{module_name}.#{name}" : name
        "#{base}[#{arguments.join(', ')}]"
      end
    end

    # Synthetic struct-like type used only as the binding type for `as name` in
    # variant match arms.  Never declared as a named type; lives only in scopes.
    class VariantArmPayload < Struct
      attr_reader :variant_type, :arm_name

      def initialize(variant_type, arm_name, fields)
        super("#{variant_type.name}_#{arm_name}", module_name: variant_type.module_name)
        @variant_type = variant_type
        @arm_name = arm_name
        define_fields(fields)
      end

      def to_s
        "#{variant_type}.#{arm_name} payload"
      end
    end

    class Opaque < Base
      attr_reader :name, :module_name, :external, :c_name

      def initialize(name, module_name: nil, external: false, c_name: nil)
        @name = name
        @module_name = module_name
        @external = external
        @c_name = c_name
      end

      def eql?(other)
        other.class == self.class &&
          other.name == name &&
          other.module_name == module_name &&
          other.external == external &&
          other.c_name == c_name
      end

      alias == eql?

      def hash
        [self.class, name, module_name, external, c_name].hash
      end

      def to_s
        module_name ? "#{module_name}.#{name}" : name
      end
    end

    class EnumBase < Base
      attr_reader :name, :module_name, :backing_type, :external

      def initialize(name, module_name: nil, external: false)
        @name = name
        @module_name = module_name
        @external = external
        @backing_type = nil
        @members = {}
        @member_values = {}
      end

      def define_members(backing_type, member_names)
        @backing_type = backing_type
        @members = member_names.each_with_object({}) do |member_name, members|
          members[member_name] = self
        end.freeze
        @member_values = {}
        self
      end

      def define_member_values(member_values)
        @member_values = member_values.freeze
        self
      end

      def member(name)
        @members[name]
      end

      def member_value(name)
        @member_values[name]
      end

      def members
        @members.keys
      end

      def sendable?
        true
      end

      def eql?(other)
        other.class == self.class &&
          other.name == name &&
          other.module_name == module_name &&
          other.external == external
      end

      alias == eql?

      def hash
        [self.class, name, module_name, external].hash
      end

      def to_s
        module_name ? "#{module_name}.#{name}" : name
      end
    end

    class Enum < EnumBase
    end

    class Flags < EnumBase
      def bitwise?
        true
      end
    end

    class Parameter
      attr_reader :name, :type, :mutable, :passing_mode, :boundary_type

      def initialize(name, type, mutable: false, passing_mode: :plain, boundary_type: nil)
        @name = name
        @type = type
        @mutable = mutable
        @passing_mode = passing_mode
        @boundary_type = boundary_type
        freeze
      end

      def to_s
        "#{name}: #{type}"
      end

      def eql?(other)
        other.is_a?(Parameter) &&
          other.type == type &&
          other.mutable == mutable &&
          other.passing_mode == passing_mode &&
          other.boundary_type == boundary_type
      end

      alias == eql?

      def hash
        [self.class, type, mutable, passing_mode, boundary_type].hash
      end
    end

    class Function < Base
      attr_reader :name, :params, :return_type, :receiver_type, :receiver_editable, :variadic, :external

      def initialize(name, params:, return_type:, receiver_type: nil, receiver_editable: false, variadic: false, external: false)
        @name = name
        @params = params.freeze
        @return_type = return_type
        @receiver_type = receiver_type
        @receiver_editable = receiver_editable
        @variadic = variadic
        @external = external
        freeze
      end

      def eql?(other)
        other.is_a?(Function) &&
          other.params == params &&
          other.return_type == return_type &&
          other.receiver_type == receiver_type &&
          other.receiver_editable == receiver_editable &&
          other.variadic == variadic
      end

      alias == eql?

      def hash
        [self.class, params, return_type, receiver_type, receiver_editable, variadic].hash
      end

      def sendable?
        true
      end

      def to_s
        pieces = []
        pieces << receiver_type.to_s if receiver_type
        pieces << name if name
        "fn #{pieces.join('.')}"
      end
    end

    class Proc < Base
      attr_reader :params, :return_type

      def initialize(params:, return_type:)
        @params = params.freeze
        @return_type = return_type
        freeze
      end

      def eql?(other)
        other.is_a?(Proc) && other.params == params && other.return_type == return_type
      end

      alias == eql?

      def hash
        [self.class, params, return_type].hash
      end

      def to_s
        "proc(#{params.map(&:type).join(', ')}) -> #{return_type}"
      end
    end

    BUILTIN_VECTOR_ELEMENT = Primitive.new("float")
    BUILTIN_IVECTOR_ELEMENT = Primitive.new("int")

    class Vector < Base
      attr_reader :name, :element_type, :width, :module_name

      FIELD_NAMES = %w[x y z w].freeze

      def initialize(name, element_type:, width:)
        @name = name
        @element_type = element_type
        @width = width
        @module_name = nil
        @fields = FIELD_NAMES.first(width).each_with_object({}) do |fname, h|
          h[fname] = element_type
        end.freeze
        freeze
      end

      def eql?(other)
        other.is_a?(Vector) && other.name == name && other.element_type == element_type
      end

      alias == eql?

      def hash
        [self.class, name, element_type].hash
      end

      def fields
        @fields
      end

      def field(name)
        @fields[name]
      end

      def numeric?
        true
      end

      def sendable?
        true
      end

      def to_s
        name
      end
    end

    class Matrix < Base
      attr_reader :name, :dim, :module_name

      def initialize(name, dim:)
        @name = name
        @dim = dim
        @module_name = nil
        col_type = Vector.new("vec#{dim}", element_type: BUILTIN_VECTOR_ELEMENT, width: dim)
        @fields = (0...dim).each_with_object({}) do |i, h|
          h["col#{i}"] = col_type
        end.freeze
        freeze
      end

      def eql?(other)
        other.is_a?(Matrix) && other.name == name
      end

      alias == eql?

      def hash
        [self.class, name].hash
      end

      def fields
        @fields
      end

      def field(name)
        @fields[name]
      end

      def numeric?
        true
      end

      def sendable?
        true
      end

      def to_s
        name
      end
    end

    class Quaternion < Base
      attr_reader :name, :module_name

      FIELD_NAMES = %w[x y z w].freeze

      def initialize(name)
        @name = name
        @module_name = nil
        @fields = FIELD_NAMES.each_with_object({}) do |fname, h|
          h[fname] = BUILTIN_VECTOR_ELEMENT
        end.freeze
        freeze
      end

      def eql?(other)
        other.is_a?(Quaternion) && other.name == name
      end

      alias == eql?

      def hash
        [self.class, name].hash
      end

      def fields
        @fields
      end

      def field(name)
        @fields[name]
      end

      def numeric?
        true
      end

      def sendable?
        true
      end

      def to_s
        name
      end
    end

    class SoA < Base
      attr_reader :name, :element_type, :count, :module_name

      def initialize(element_type, count:)
        @name = "SoA[#{element_type}, #{count}]"
        @element_type = element_type
        @count = count
        @module_name = nil
        @fields = if element_type.respond_to?(:fields) && element_type.fields
                     element_type.fields.each_with_object({}) do |(fname, ftype), h|
                       h[fname] = GenericInstance.new("array", [ftype, LiteralTypeArg.new(count)])
                     end
                   else
                     {}.freeze
                   end.freeze
        freeze
      end

      def eql?(other)
        other.is_a?(SoA) && other.element_type == element_type && other.count == count
      end

      alias == eql?

      def hash
        [self.class, element_type, count].hash
      end

      def fields
        @fields
      end

      def field(name)
        @fields[name]
      end

      def sendable?
        fields.each_value.all?(&:sendable?)
      end

      def to_s
        @name
      end
    end

    class Tuple < Base
      attr_reader :element_types, :field_names

      def initialize(element_types, field_names: nil)
        @element_types = element_types.freeze
        @field_names = (field_names || element_types.each_with_index.map { |_, i| "_#{i}" }).freeze
        @fields = @field_names.each_with_index.each_with_object({}) do |(name, index), h|
          h[name] = element_types[index]
        end.freeze
        freeze
      end

      def eql?(other)
        other.is_a?(Tuple) && other.element_types == element_types && other.field_names == field_names
      end

      alias == eql?

      def hash
        [self.class, element_types, field_names].hash
      end

      def fields
        @fields
      end

      def field(name)
        @fields[name]
      end

      def sendable?
        element_types.all?(&:sendable?)
      end

      def to_s
        if field_names == element_types.each_with_index.map { |_, i| "_#{i}" }
          "(#{element_types.map(&:to_s).join(', ')})"
        else
          fields_parts = field_names.each_with_index.map { |n, i| "#{n}: #{element_types[i]}" }
          "(#{fields_parts.join(', ')})"
        end
      end
    end

    class Dyn < Base
      attr_reader :interface_binding, :type_arguments

      def initialize(interface_binding, type_arguments = [])
        @interface_binding = interface_binding
        @type_arguments = type_arguments
        freeze
      end

      def eql?(other)
        other.is_a?(Dyn) && other.interface_binding == interface_binding && other.type_arguments == type_arguments
      end

      alias == eql?

      def hash
        [self.class, interface_binding, type_arguments].hash
      end

      def to_s
        if type_arguments.any?
          "dyn[#{interface_binding.name}[#{type_arguments.map(&:to_s).join(', ')}]]"
        else
          "dyn[#{interface_binding.name}]"
        end
      end

      def field(name)
        void_ptr = GenericInstance.new("ptr", [Primitive.new("void")])
        { "data" => void_ptr, "vtable" => void_ptr }[name]
      end
    end

    class DynVtable < Base
      attr_reader :c_name, :interface_name, :fields

      def initialize(interface_name, fields = {})
        @interface_name = interface_name
        @c_name = "mt_vtable_#{interface_name}"
        @fields = fields
        freeze
      end

      def eql?(other)
        other.is_a?(DynVtable) && other.c_name == c_name
      end

      alias == eql?

      def hash
        [self.class, c_name].hash
      end

      def to_s
        c_name
      end

      def field(name)
        @fields[name]
      end
    end

    BUILTIN_OPTION_TYPE = GenericVariantDefinition.new("Option", ["T"]).define_arms(
      "some" => { "value" => TypeVar.new("T") },
      "none" => {},
    )

    BUILTIN_RESULT_TYPE = GenericVariantDefinition.new("Result", ["T", "E"]).define_arms(
      "success" => { "value" => TypeVar.new("T") },
      "failure" => { "error" => TypeVar.new("E") },
    )

    def self.pointer_to(type)
      GenericInstance.new("ptr", [type])
    end

    def self.integer_type?(type)
      type.is_a?(Primitive) && %w[int ptr_uint i8 i16 i32 i64 u8 u16 u32 u64].include?(type.name)
    end

    def self.array_type?(type)
      type.is_a?(GenericInstance) && type.name == "array" && type.arguments.length == 2
    end

    def self.dynamic_array_type?(type)
      array_type?(type) && !type.arguments.first.is_a?(LiteralTypeArg)
    end

    def self.fixed_array_type?(type)
      array_type?(type) && type.arguments.last.is_a?(LiteralTypeArg) && type.arguments.last.value.is_a?(Integer)
    end

    def self.str_buffer_type?(type)
      type.is_a?(GenericInstance) && type.name == "str_buffer" && type.arguments.length == 1
    end

    def self.str_buffer_struct_type?(type)
      type.is_a?(GenericStructDefinition) && type.name == "str_buffer"
    end
  end
end

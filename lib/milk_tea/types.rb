# frozen_string_literal: true

module MilkTea
  module Types
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
    end

    class Primitive < Base
      INTEGER_NAMES = %w[i8 i16 i32 i64 u8 u16 u32 u64 isize usize].freeze
      FLOAT_NAMES = %w[f32 f64].freeze
      FIXED_SIGNED_INTEGER_WIDTHS = {
        "i8" => 8,
        "i16" => 16,
        "i32" => 32,
        "i64" => 64,
      }.freeze
      FIXED_UNSIGNED_INTEGER_WIDTHS = {
        "u8" => 8,
        "u16" => 16,
        "u32" => 32,
        "u64" => 64,
      }.freeze
      FLOAT_WIDTHS = {
        "f32" => 32,
        "f64" => 64,
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
        FIXED_SIGNED_INTEGER_WIDTHS.key?(name) || name == "isize"
      end

      def unsigned_integer?
        FIXED_UNSIGNED_INTEGER_WIDTHS.key?(name) || name == "usize"
      end

      def fixed_width_integer?
        FIXED_SIGNED_INTEGER_WIDTHS.key?(name) || FIXED_UNSIGNED_INTEGER_WIDTHS.key?(name)
      end

      def pointer_sized_integer?
        name == "isize" || name == "usize"
      end

      def integer_width
        FIXED_SIGNED_INTEGER_WIDTHS[name] || FIXED_UNSIGNED_INTEGER_WIDTHS[name]
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

      def to_s
        name
      end
    end

    class Null < Base
      def eql?(other)
        other.is_a?(Null)
      end

      alias == eql?

      def hash
        self.class.hash
      end

      def to_s
        "null"
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
        [self.class, name].hash
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
          "len" => Primitive.new("usize"),
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

    class Result < Base
      attr_reader :ok_type, :error_type

      def initialize(ok_type, error_type)
        @ok_type = ok_type
        @error_type = error_type
        @fields = {
          "is_ok" => Primitive.new("bool"),
          "value" => ok_type,
          "error" => error_type,
        }.freeze
        freeze
      end

      def eql?(other)
        other.is_a?(Result) && other.ok_type == ok_type && other.error_type == error_type
      end

      alias == eql?

      def hash
        [self.class, ok_type, error_type].hash
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
        "Result[#{ok_type}, #{error_type}]"
      end
    end

    class GenericStructDefinition < Base
      attr_reader :name, :type_params, :module_name, :external, :packed, :alignment

      def initialize(name, type_params, module_name: nil, external: false, packed: false, alignment: nil)
        @name = name
        @type_params = type_params.freeze
        @module_name = module_name
        @external = external
        @packed = packed
        @alignment = alignment
        @fields = {}
        @instances = {}
      end

      def define_fields(fields)
        @fields = fields.freeze
        self
      end

      def fields
        @fields
      end

      def field(name)
        @fields[name]
      end

      def instantiate(arguments)
        raise ArgumentError, "#{name} expects #{type_params.length} type arguments, got #{arguments.length}" unless arguments.length == type_params.length

        key = arguments.dup.freeze
        return @instances[key] if @instances.key?(key)

        substitutions = type_params.zip(arguments).to_h
        instance = StructInstance.new(self, arguments)
        @instances[key] = instance
        instance.define_fields(@fields.transform_values { |type| substitute_type(type, substitutions) })
      end

      def to_s
        module_name ? "#{module_name}.#{name}" : name
      end

      private

      def substitute_type(type, substitutions)
        case type
        when TypeVar
          substitutions.fetch(type.name, type)
        when Nullable
          Nullable.new(substitute_type(type.base, substitutions))
        when GenericInstance
          GenericInstance.new(type.name, type.arguments.map { |argument| argument.is_a?(LiteralTypeArg) ? argument : substitute_type(argument, substitutions) })
        when Span
          Span.new(substitute_type(type.element_type, substitutions))
        when Result
          Result.new(substitute_type(type.ok_type, substitutions), substitute_type(type.error_type, substitutions))
        when Function
          Function.new(
            type.name,
            params: type.params.map { |param| Parameter.new(param.name, substitute_type(param.type, substitutions), mutable: param.mutable) },
            return_type: substitute_type(type.return_type, substitutions),
            receiver_type: type.receiver_type ? substitute_type(type.receiver_type, substitutions) : nil,
            receiver_mutable: type.receiver_mutable,
            external: type.external,
          )
        when StructInstance
          type.definition.instantiate(type.arguments.map { |argument| substitute_type(argument, substitutions) })
        else
          type
        end
      end
    end

    class Struct < Base
      attr_reader :name, :module_name, :external, :packed, :alignment

      def initialize(name, module_name: nil, external: false, packed: false, alignment: nil)
        @name = name
        @module_name = module_name
        @external = external
        @packed = packed
        @alignment = alignment
        @fields = {}
      end

      def define_fields(fields)
        @fields = fields.freeze
        self
      end

      def fields
        @fields
      end

      def field(name)
        @fields[name]
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
        )
        @definition = definition
        @arguments = arguments.freeze
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

    class Opaque < Base
      attr_reader :name, :module_name, :external

      def initialize(name, module_name: nil, external: false)
        @name = name
        @module_name = module_name
        @external = external
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
      end

      def define_members(backing_type, member_names)
        @backing_type = backing_type
        @members = member_names.each_with_object({}) do |member_name, members|
          members[member_name] = self
        end.freeze
        self
      end

      def member(name)
        @members[name]
      end

      def members
        @members.keys
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
      attr_reader :name, :type, :mutable

      def initialize(name, type, mutable: false)
        @name = name
        @type = type
        @mutable = mutable
        freeze
      end

      def to_s
        "#{name}: #{type}"
      end

      def eql?(other)
        other.is_a?(Parameter) && other.type == type && other.mutable == mutable
      end

      alias == eql?

      def hash
        [self.class, type, mutable].hash
      end
    end

    class Function < Base
      attr_reader :name, :params, :return_type, :receiver_type, :receiver_mutable, :variadic, :external

      def initialize(name, params:, return_type:, receiver_type: nil, receiver_mutable: false, variadic: false, external: false)
        @name = name
        @params = params.freeze
        @return_type = return_type
        @receiver_type = receiver_type
        @receiver_mutable = receiver_mutable
        @variadic = variadic
        @external = external
        freeze
      end

      def eql?(other)
        other.is_a?(Function) &&
          other.params == params &&
          other.return_type == return_type &&
          other.receiver_type == receiver_type &&
          other.receiver_mutable == receiver_mutable &&
          other.variadic == variadic
      end

      alias == eql?

      def hash
        [self.class, params, return_type, receiver_type, receiver_mutable, variadic].hash
      end

      def to_s
        pieces = []
        pieces << receiver_type.to_s if receiver_type
        pieces << name if name
        "fn #{pieces.join('.')}"
      end
    end
  end
end

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

    class Struct < Base
      attr_reader :name, :module_name, :external

      def initialize(name, module_name: nil, external: false)
        @name = name
        @module_name = module_name
        @external = external
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
      attr_reader :name, :params, :return_type, :receiver_type, :receiver_mutable, :external

      def initialize(name, params:, return_type:, receiver_type: nil, receiver_mutable: false, external: false)
        @name = name
        @params = params.freeze
        @return_type = return_type
        @receiver_type = receiver_type
        @receiver_mutable = receiver_mutable
        @external = external
        freeze
      end

      def eql?(other)
        other.is_a?(Function) &&
          other.params == params &&
          other.return_type == return_type &&
          other.receiver_type == receiver_type &&
          other.receiver_mutable == receiver_mutable
      end

      alias == eql?

      def hash
        [self.class, params, return_type, receiver_type, receiver_mutable].hash
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

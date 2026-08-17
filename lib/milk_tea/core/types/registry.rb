# frozen_string_literal: true

module MilkTea
  module Types
    module Registry
      @pool = {}
      @mutex = Mutex.new

      def self.reset!
        @mutex.synchronize { @pool.clear }
      end

      def self._intern(key, &construct)
        @mutex.synchronize do
          @pool[key] ||= construct.call
        end
      end

      def self.primitive(name)
        _intern([:primitive, name]) { Primitive.new(name) }
      end

      def self.nullable(base)
        _intern([:nullable, base]) { Nullable.new(base) }
      end

      def self.generic_instance(name, arguments)
        args = arguments.freeze
        _intern([:generic, name, args]) { GenericInstance.new(name, args) }
      end

      def self.span(element_type)
        _intern([:span, element_type]) { Span.new(element_type) }
      end

      def self.task(result_type)
        _intern([:task, result_type]) { Task.new(result_type) }
      end

      def self.string_view
        _intern([:string_view]) { StringView.new }
      end

      # Param signature for intern keys. Parameter#eql? is name-insensitive
      # (assignability must not depend on parameter names), so arrays of
      # Parameter objects would conflate fn(value: int) with fn(arg0: int) in
      # the intern pool. Embedding names here keeps distinct signatures
      # distinct across independent programs sharing a long-lived pool (the LSP
      # never resets the registry between checks).
      def self.param_signature(params)
        params.map { |p| [p.name, p.type, p.mutable, p.passing_mode, p.boundary_type] }
      end

      def self.function(name, params:, return_type:, receiver_type: nil, receiver_editable: false, variadic: false, external: false)
        params_frozen = params.freeze
        param_key = param_signature(params_frozen)
        _intern([:function, name, param_key, return_type, receiver_type, receiver_editable, variadic, external]) {
          Function.new(name, params: params_frozen, return_type: return_type, receiver_type: receiver_type, receiver_editable: receiver_editable, variadic: variadic, external: external)
        }
      end

      def self.proc(params:, return_type:)
        params_frozen = params.freeze
        param_key = param_signature(params_frozen)
        _intern([:proc, param_key, return_type]) { Proc.new(params: params_frozen, return_type: return_type) }
      end

      def self.parameter(name, type, mutable: false, passing_mode: :plain, boundary_type: nil)
        _intern([:parameter, name, type, mutable, passing_mode, boundary_type]) {
          Parameter.new(name, type, mutable: mutable, passing_mode: passing_mode, boundary_type: boundary_type)
        }
      end

      def self.tuple(element_types, field_names: nil)
        et_frozen = element_types.freeze
        fn_frozen = field_names&.freeze
        _intern([:tuple, et_frozen, fn_frozen]) { Tuple.new(et_frozen, field_names: fn_frozen) }
      end

      def self.soa(element_type, count:)
        _intern([:soa, element_type, count]) { SoA.new(element_type, count: count) }
      end

      def self.simd(element_type, lane_count:)
        _intern([:simd, element_type, lane_count]) { Simd.new(element_type, lane_count: lane_count) }
      end

      def self.lifetime_ref(name)
        LifetimeRef.new(name)
      end

      def self.dyn(interface_binding, type_arguments = [])
        Dyn.new(interface_binding, type_arguments)
      end
    end
  end
end

# frozen_string_literal: true

module MilkTea
  module Types
    module Registry
      @pool = {}
      @mutex = Mutex.new

      module_function

      def reset!
        @mutex.synchronize { @pool.clear }
      end

      def _intern(key, &construct)
        @mutex.synchronize do
          @pool[key] ||= construct.call
        end
      end

      def primitive(name)
        _intern([:primitive, name]) { Primitive.new(name) }
      end

      def nullable(base)
        _intern([:nullable, base]) { Nullable.new(base) }
      end

      def generic_instance(name, arguments)
        args = arguments.freeze
        _intern([:generic, name, args]) { GenericInstance.new(name, args) }
      end

      def span(element_type)
        _intern([:span, element_type]) { Span.new(element_type) }
      end

      def task(result_type)
        _intern([:task, result_type]) { Task.new(result_type) }
      end

      def string_view
        _intern([:string_view]) { StringView.new }
      end

      def function(name, params:, return_type:, receiver_type: nil, receiver_editable: false, variadic: false, external: false)
        params_frozen = params.freeze
        _intern([:function, name, params_frozen, return_type, receiver_type, receiver_editable, variadic, external]) {
          Function.new(name, params: params_frozen, return_type: return_type, receiver_type: receiver_type, receiver_editable: receiver_editable, variadic: variadic, external: external)
        }
      end

      def proc(params:, return_type:)
        params_frozen = params.freeze
        _intern([:proc, params_frozen, return_type]) { Proc.new(params: params_frozen, return_type: return_type) }
      end

      def parameter(name, type, mutable: false, passing_mode: :plain, boundary_type: nil)
        _intern([:parameter, name, type, mutable, passing_mode, boundary_type]) {
          Parameter.new(name, type, mutable: mutable, passing_mode: passing_mode, boundary_type: boundary_type)
        }
      end

      def tuple(element_types, field_names: nil)
        et_frozen = element_types.freeze
        fn_frozen = field_names&.freeze
        _intern([:tuple, et_frozen, fn_frozen]) { Tuple.new(et_frozen, field_names: fn_frozen) }
      end

      def soa(element_type, count:)
        _intern([:soa, element_type, count]) { SoA.new(element_type, count: count) }
      end

      def type_var(name)
        TypeVar.new(name)
      end

      def lifetime_ref(name)
        LifetimeRef.new(name)
      end

      def dyn(interface_binding, type_arguments = [])
        Dyn.new(interface_binding, type_arguments)
      end

      def literal_type_arg(value)
        LiteralTypeArg.new(value)
      end
    end
  end
end

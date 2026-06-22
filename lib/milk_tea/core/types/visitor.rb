# frozen_string_literal: true

require_relative "predicates"

module MilkTea
  class TypeVisitor
    def initialize
      @visited = {}
    end

    def visit(type)
      return if type.nil?
      return if @visited[type.object_id]

      @visited[type.object_id] = true
      dispatch(type)
    end

    def dispatch(type)
      case type
      when Types::Nullable then visit_nullable(type)
      when Types::GenericInstance then visit_generic_instance(type)
      when Types::Span then visit_span(type)
      when Types::Task then visit_task(type)
      when Types::GenericStructDefinition then visit_generic_struct_definition(type)
      when Types::GenericVariantDefinition then visit_generic_variant_definition(type)
      when Types::Struct then visit_struct(type)
      when Types::Union then visit_union(type)
      when Types::StructInstance then visit_struct_instance(type)
      when Types::Variant then visit_variant(type)
      when Types::VariantInstance then visit_variant_instance(type)
      when Types::VariantArmPayload then visit_variant_arm_payload(type)
      when Types::Proc then visit_proc(type)
      when Types::Function then visit_function(type)
      when Types::Parameter then visit_parameter(type)
      when Types::TypeVar then visit_type_var(type)
      when Types::Null then visit_null(type)
      when Types::Tuple then visit_tuple(type)
      when Types::Dyn then visit_dyn(type)
      when Types::SoA then visit_soa(type)
      when Types::Event then visit_event(type)
      when Types::LifetimeRef then visit_lifetime_ref(type)
      else visit_default(type)
      end
    end

    def visit_children(type)
      type.children.each { |child| visit(child) }
    end

    def visit_nullable(type); visit_children(type); end
    def visit_generic_instance(type); visit_children(type); end
    def visit_span(type); visit_children(type); end
    def visit_task(type); visit_children(type); end
    def visit_generic_struct_definition(type); visit_children(type); end
    def visit_generic_variant_definition(type); visit_children(type); end
    def visit_struct(type); visit_children(type); end
    def visit_union(type); visit_children(type); end
    def visit_struct_instance(type); visit_children(type); end
    def visit_variant(type); visit_children(type); end
    def visit_variant_instance(type); visit_children(type); end
    def visit_variant_arm_payload(type); visit_children(type); end
    def visit_proc(type); visit_children(type); end
    def visit_function(type); visit_children(type); end
    def visit_parameter(type); visit_children(type); end
    def visit_tuple(type); visit_children(type); end
    def visit_dyn(type); visit_children(type); end
    def visit_soa(type); visit_children(type); end
    def visit_event(type); visit_children(type); end

    def visit_type_var(type); end
    def visit_null(type); end
    def visit_lifetime_ref(type); end
    def visit_default(type); end
  end

  class ContainsTypeVarVisitor < TypeVisitor
    def initialize
      super
      @found = false
    end

    def found?
      @found
    end

    def visit_type_var(type)
      @found = true
    end
  end

  class ContainsRefTypeVisitor < TypeVisitor
    def initialize(allow_lifetimes: [])
      super()
      @found = false
      @allow_lifetimes = allow_lifetimes
    end

    def found?
      @found
    end

    def visit_generic_instance(type)
      if type.name == "ref" && [1, 2].include?(type.arguments.length)
        if type.arguments.length == 2
          lt = type.arguments.first
          if lt.is_a?(String) && @allow_lifetimes.include?(lt)
            visit_children(type)
            return
          end
        end
        @found = true
        return
      end
      visit_children(type)
    end
  end

  class ContainsProcTypeVisitor < TypeVisitor
    def initialize
      super
      @found = false
    end

    def found?
      @found
    end

    def visit_proc(type)
      @found = true
    end

    def visit_generic_instance(type)
      if type.name == "array" && type.arguments.first && !type.arguments.first.is_a?(Types::LiteralTypeArg)
        visit(type.arguments.first)
      end
    end
  end

  class ContainsCallableRefTypeVisitor < TypeVisitor
    def initialize
      super
      @found = false
    end

    def found?
      @found
    end

    def visit_proc(type)
      checker = ContainsRefTypeVisitor.new
      checker.visit(type)
      @found = true if checker.found?
    end
    alias visit_function visit_proc
  end

  class StoredRefSupportedVisitor < TypeVisitor
    include TypePredicates

    def initialize(allow_lifetimes: [])
      super()
      @supported = true
      @allow_lifetimes = allow_lifetimes
    end

    def result?
      @supported
    end

    def visit_generic_instance(type)
      if ref_type?(type)
        lt = ref_lifetime(type)
        if lt && @allow_lifetimes.include?(lt)
          visit_children(type)
          return
        end
        @supported = false
        return
      end
      visit_children(type)
    end

    def visit_proc(type)
      @supported = false unless callable_param_ref_supported?(type)
    end
    alias visit_function visit_proc

    private

    def visit_children(type)
      type.children.each do |child|
        visit(child)
        return unless @supported
      end
    end
  end

  class SendableCheckVisitor < TypeVisitor
    def initialize
      super
      @sendable = true
    end

    def sendable?
      @sendable
    end

    def visit_children(type)
      type.children.each do |child|
        visit(child)
        return unless @sendable
      end
    end

    def visit_event(type)
      @sendable = false
    end

    def visit_dyn(type)
      @sendable = false
    end

    def visit_span(type)
      @sendable = false
    end

    def visit_proc(type)
      @sendable = false
    end

    def visit_function(type); end

    def visit_generic_instance(type)
      case type.name
      when "ptr", "const_ptr", "ref"
        @sendable = false
      when "array"
        el = type.arguments.first
        visit(el) unless el.is_a?(Types::LiteralTypeArg)
      when "str_buffer", "atomic"
        # sendable
      else
        @sendable = false
      end
    end

    def visit_struct(type)
      if type.respond_to?(:has_events?) && type.has_events?
        @sendable = false
        return
      end
      visit_children(type)
    end
    alias visit_struct_instance visit_struct

    def visit_default(type)
      case type
      when Types::Primitive
        @sendable = false if type.name == "str"
      when Types::Error, Types::Opaque, Types::StringView
        @sendable = false
      end
    end
  end

  class SubstituteTypeVisitor
    def initialize(substitutions)
      @substitutions = substitutions
    end

    def apply(type)
      case type
      when Types::TypeVar
        @substitutions.fetch(type.name, type)
      when Types::LifetimeRef
        @substitutions.fetch(type.name, type)
      when Types::Nullable
        substituted = apply(type.base)
        substituted.equal?(type.base) ? type : Types::Registry.nullable(substituted)
      when Types::GenericInstance
        new_args = type.arguments.map do |arg|
          arg.is_a?(Types::LiteralTypeArg) ? arg : apply(arg)
        end
        type.arguments.zip(new_args).all? { |old, new| old.equal?(new) } ? type : Types::Registry.generic_instance(type.name, new_args)
      when Types::Span
        substituted = apply(type.element_type)
        substituted.equal?(type.element_type) ? type : Types::Registry.span(substituted)
      when Types::Task
        substituted = apply(type.result_type)
        substituted.equal?(type.result_type) ? type : Types::Registry.task(substituted)
      when Types::Event
        new_payload = type.payload_type ? apply(type.payload_type) : nil
        if new_payload.equal?(type.payload_type)
          type
        else
          Types::Event.new(type.name, capacity: type.capacity, payload_type: new_payload, module_name: type.module_name, visibility: type.visibility, owner_type_name: type.owner_type_name)
        end
      when Types::Proc
        changed = false
        new_params = type.params.map do |param|
          new_param_type = apply(param.type)
          new_boundary = param.boundary_type ? apply(param.boundary_type) : nil
          changed = true unless new_param_type.equal?(param.type) && new_boundary.equal?(param.boundary_type)
          Types::Registry.parameter(param.name, new_param_type, mutable: param.mutable, passing_mode: param.passing_mode, boundary_type: new_boundary)
        end
        new_return = apply(type.return_type)
        changed = true unless new_return.equal?(type.return_type)
        changed ? Types::Registry.proc(params: new_params, return_type: new_return) : type
      when Types::Function
        changed = false
        new_params = type.params.map do |param|
          new_param_type = apply(param.type)
          new_boundary = param.boundary_type ? apply(param.boundary_type) : nil
          changed = true unless new_param_type.equal?(param.type) && new_boundary.equal?(param.boundary_type)
          Types::Registry.parameter(param.name, new_param_type, mutable: param.mutable, passing_mode: param.passing_mode, boundary_type: new_boundary)
        end
        new_return = apply(type.return_type)
        changed = true unless new_return.equal?(type.return_type)
        new_receiver = type.receiver_type ? apply(type.receiver_type) : nil
        changed = true unless new_receiver.equal?(type.receiver_type)
        changed ? Types::Registry.function(type.name, params: new_params, return_type: new_return, receiver_type: new_receiver, receiver_editable: type.receiver_editable, variadic: type.variadic, external: type.external) : type
      when Types::StructInstance
        new_args = type.arguments.map { |arg| apply(arg) }
        type.arguments.zip(new_args).all? { |old, new| old.equal?(new) } ? type : type.definition.instantiate(new_args)
      when Types::VariantInstance
        new_args = type.arguments.map { |arg| apply(arg) }
        type.arguments.zip(new_args).all? { |old, new| old.equal?(new) } ? type : type.definition.instantiate(new_args)
      else
        type
      end
    end
  end

  class ContainsArrayStorageVisitor < TypeVisitor
    def initialize
      super
      @found = false
    end

    def found?
      @found
    end

    def dispatch(type)
      case type
      when Types::Nullable, Types::Struct, Types::StructInstance
        visit_children(type)
      when Types::GenericInstance
        if type.name == "array"
          @found = true
        end
      end
    end

    def visit_children(type)
      type.children.each do |child|
        visit(child)
        return if @found
      end
    end
  end

  class ProcStorageSupportedVisitor < TypeVisitor
    def initialize
      super
      @supported = true
    end

    def result?
      @supported
    end

    def dispatch(type)
      case type
      when Types::Nullable, Types::GenericInstance, Types::Struct, Types::Union,
           Types::StructInstance, Types::Variant, Types::VariantInstance, Types::VariantArmPayload
        visit_children(type)
      when Types::Proc
      else
        @supported = false
      end
    end

    def visit_children(type)
      type.children.each do |child|
        visit(child)
        return unless @supported
      end
    end
  end

  class ValidateSpecializedTypeVisitor < TypeVisitor
    def initialize(function_name:, context:, on_error:, on_generic_instance: nil)
      super()
      @function_name = function_name
      @context = context
      @on_error = on_error
      @on_generic_instance = on_generic_instance
    end

    def visit_literal_type_arg(type)
      @on_error.call("#{@context} of function #{@function_name} must be a type, got #{type}")
    end

    def visit_type_var(type)
      @on_error.call("cannot infer type argument #{type.name} for function #{@function_name}")
    end

    def visit_generic_instance(type)
      @on_generic_instance&.call(type.name, type.arguments)
      visit_children(type)
    end

    def visit_proc(type)
      type.params.each do |param|
        with_context("#{@context} parameter #{param.name}") { visit(param.type) }
      end
      with_context("#{@context} return type") { visit(type.return_type) }
    end

    def visit_function(type)
      type.params.each do |param|
        with_context("#{@context} parameter #{param.name}") { visit(param.type) }
        if param.boundary_type
          with_context("#{@context} boundary parameter #{param.name}") { visit(param.boundary_type) }
        end
      end
      with_context("#{@context} return type") { visit(type.return_type) }
      if type.receiver_type
        with_context("#{@context} receiver type") { visit(type.receiver_type) }
      end
    end

    private

    def with_context(new_context)
      old = @context
      @context = new_context
      yield
    ensure
      @context = old
    end
  end
end

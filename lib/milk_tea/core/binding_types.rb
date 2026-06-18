# frozen_string_literal: true

module MilkTea
  class FlowScope
    def initialize = (@bindings = {})
    def [](key) = @bindings[key]
    def []=(key, val); @bindings[key] = val; end
    def key?(key) = @bindings.key?(key)
    def empty? = @bindings.empty?
    def each(&block) = @bindings.each(&block)
    def each_with_object(init, &block) = @bindings.each_with_object(init, &block)
  end

  ValueBinding = Data.define(:id, :name, :storage_type, :flow_type, :mutable, :kind, :const_value) do
    def type
      flow_type || storage_type
    end

    def with_flow_type(refined_type)
      ValueBinding.new(
        id:,
        name:,
        storage_type:,
        flow_type: refined_type == storage_type ? nil : refined_type,
        mutable:,
        kind:,
        const_value:,
      )
    end
  end

  FunctionBinding = Data.define(:name, :type, :body_params, :body_return_type, :ast, :external, :async, :type_params, :type_param_constraints, :instances, :type_arguments, :owner, :specialization_owner, :type_substitutions, :declared_receiver_type)

  ModuleBinding = Data.define(:name, :types, :type_declarations, :interfaces, :attributes, :attribute_applications, :values, :functions, :methods, :implemented_interfaces, :imports, :private_types, :private_interfaces, :private_attributes, :private_values, :private_functions, :private_methods, :private_implemented_interfaces) do
    def private_type?(name)
      private_types.key?(name)
    end

    def private_interface?(name)
      private_interfaces.key?(name)
    end

    def private_attribute?(name)
      private_attributes.key?(name)
    end

    def private_value?(name)
      private_values.key?(name)
    end

    def private_function?(name)
      private_functions.key?(name)
    end

    def private_method?(receiver_type, name)
      return true if private_methods.fetch(receiver_type, {}).key?(name)

      if receiver_type.is_a?(Types::GenericInstance)
        dispatch_receiver_type = Types::GenericInstance.new(
          receiver_type.name,
          receiver_type.arguments.each_with_index.map do |argument, index|
            argument.is_a?(Types::LiteralTypeArg) ? argument : Types::TypeVar.new("__receiver_arg#{index}")
          end,
        )
        return true if dispatch_receiver_type != receiver_type && private_methods.fetch(dispatch_receiver_type, {}).key?(name)
      end

      if receiver_type.is_a?(Types::Nullable)
        dispatch_base_type = receiver_type.base
        if dispatch_base_type.is_a?(Types::StructInstance)
          dispatch_base_type = dispatch_base_type.definition
        elsif dispatch_base_type.is_a?(Types::GenericInstance)
          dispatch_base_type = Types::GenericInstance.new(
            dispatch_base_type.name,
            dispatch_base_type.arguments.each_with_index.map do |argument, index|
              argument.is_a?(Types::LiteralTypeArg) ? argument : Types::TypeVar.new("__receiver_arg#{index}")
            end,
          )
        end

        dispatch_receiver_type = Types::Nullable.new(dispatch_base_type)
        return true if dispatch_receiver_type != receiver_type && private_methods.fetch(dispatch_receiver_type, {}).key?(name)
      end

      receiver_type.is_a?(Types::StructInstance) && private_methods.fetch(receiver_type.definition, {}).key?(name)
    end
  end

  AttributeBinding = Data.define(:name, :targets, :params, :module_name, :builtin, :ast)
  BUILTIN_ATTRIBUTE_NAMES = %w[packed align deprecated].freeze

  module_function

  def builtin_attribute_binding(name, types)
    case name
    when "packed"
      AttributeBinding.new(
        name: "packed",
        targets: [:struct].freeze,
        params: [].freeze,
        module_name: nil,
        builtin: true,
        ast: nil,
      )
    when "align"
      AttributeBinding.new(
        name: "align",
        targets: [:struct].freeze,
        params: [Types::Parameter.new("bytes", types.fetch("ptr_uint"))].freeze,
        module_name: nil,
        builtin: true,
        ast: nil,
      )
    when "deprecated"
      AttributeBinding.new(
        name: "deprecated",
        targets: %i[callable struct const enum flags union variant event].freeze,
        params: [Types::Parameter.new("message", types.fetch("str"))].freeze,
        module_name: nil,
        builtin: true,
        ast: nil,
      )
    end
  end
end

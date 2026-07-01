# frozen_string_literal: true

module MilkTea
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
        dispatch_receiver_type = Types::Registry.generic_instance(
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
          dispatch_base_type = Types::Registry.generic_instance(
            dispatch_base_type.name,
            dispatch_base_type.arguments.each_with_index.map do |argument, index|
              argument.is_a?(Types::LiteralTypeArg) ? argument : Types::TypeVar.new("__receiver_arg#{index}")
            end,
          )
        end

        dispatch_receiver_type = Types::Registry.nullable(dispatch_base_type)
        return true if dispatch_receiver_type != receiver_type && private_methods.fetch(dispatch_receiver_type, {}).key?(name)
      end

      receiver_type.is_a?(Types::StructInstance) && private_methods.fetch(receiver_type.definition, {}).key?(name)
    end
  end
end

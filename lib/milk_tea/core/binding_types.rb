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
end

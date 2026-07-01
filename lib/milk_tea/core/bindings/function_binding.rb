# frozen_string_literal: true

module MilkTea
  FunctionBinding = Data.define(:name, :type, :body_params, :body_return_type, :ast, :external, :async, :type_params, :type_param_constraints, :instances, :type_arguments, :owner, :specialization_owner, :type_substitutions, :declared_receiver_type)
end

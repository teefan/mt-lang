# frozen_string_literal: true

require "set"

require_relative "control_flow/graph"
require_relative "control_flow/builder"
require_relative "control_flow/dataflow"
require_relative "control_flow/liveness"
require_relative "control_flow/definite_assignment"
require_relative "control_flow/reachability"
require_relative "control_flow/termination"
require_relative "control_flow/nullability_flow"
require_relative "control_flow/constant_propagation"

module MilkTea
  module ControlFlow
    BindingResolution = Data.define(:identifier_binding_ids, :declaration_binding_ids, :mutating_argument_identifier_ids)
    ReadSite = Data.define(:binding_key, :line, :column, :length)

    Node = Struct.new(
      :id,
      :kind,
      :statement,
      :line,
      :reads,
      :reads_info,
      :writes,
      :writes_info,
      :succs,
      :preds,
      keyword_init: true
    )
  end
end

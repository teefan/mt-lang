# frozen_string_literal: true

require "set"

require_relative "cfg/graph"
require_relative "cfg/builder"
require_relative "cfg/dataflow"
require_relative "cfg/liveness"
require_relative "cfg/definite_assignment"
require_relative "cfg/reachability"
require_relative "cfg/termination"
require_relative "cfg/nullability_flow"
require_relative "cfg/constant_propagation"

module MilkTea
  module CFG
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

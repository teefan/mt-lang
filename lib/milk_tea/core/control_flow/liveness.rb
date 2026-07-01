# frozen_string_literal: true

module MilkTea
  module ControlFlow
    class Liveness
      Result = Data.define(:live_in, :live_out)

      def self.solve(graph)
        result = Dataflow.solve(
          graph,
          direction: :backward,
          initial: -> { Set.new },
          join: lambda do |states|
            states.reduce(Set.new) { |acc, state| acc | state }
          end,
          transfer: lambda do |node, live_out|
            node.reads | (live_out - node.writes)
          end,
        )
        Result.new(live_in: result.in_states, live_out: result.out_states)
      end
    end
  end
end

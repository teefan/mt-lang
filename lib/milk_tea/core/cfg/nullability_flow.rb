# frozen_string_literal: true

module MilkTea
  module CFG
    class NullabilityFlow
      Result = Data.define(:in_states, :out_states, :stmt_to_node_id) do
        def nonnull_before(stmt)
          node_id = stmt_to_node_id[stmt.object_id]
          return Set.new unless node_id

          in_states[node_id] || Set.new
        end
      end

      def self.solve(graph)
        stmt_to_node_id = {}
        graph.each_node { |n| stmt_to_node_id[n.statement.object_id] = n.id if n.statement }

        result = Dataflow.solve(
          graph,
          direction: :forward,
          initial: -> { Set.new },
          join: lambda do |states|
            return Set.new if states.empty?

            states.reduce { |acc, s| acc & s }
          end,
          edge_transfer: lambda do |node, in_state, succ_id, _edge_label|
            state = in_state - node.writes
            refs  = graph.edge_refinement(node.id, succ_id) || {}
            refs.each do |key, ref|
              ref == :non_null ? (state = state | Set[key]) : (state = state - Set[key])
            end
            state
          end,
          boundary_in: { graph.entry_id => Set.new }
        )

        Result.new(in_states: result.in_states, out_states: result.out_states, stmt_to_node_id:)
      end
    end
  end
end

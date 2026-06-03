# frozen_string_literal: true

module MilkTea
  module CFG
    class DefiniteAssignment
      ReadBeforeAssignment = Data.define(:node_id, :binding_key, :line, :column, :length)
      Result = Data.define(:definitely_assigned_in, :definitely_assigned_out, :read_before_assignment)

      def self.solve(graph, initially_assigned: Set.new)
        initially_assigned = initially_assigned.dup
        universe = initial_universe(graph, initially_assigned)

        result = Dataflow.solve(
          graph,
          direction: :forward,
          initial: -> { universe.dup },
          join: lambda do |states|
            if states.empty?
              universe.dup
            else
              states.reduce(universe.dup) { |acc, state| acc & state }
            end
          end,
          transfer: lambda do |node, in_state|
            in_state | node.writes
          end,
          boundary_in: { graph.entry_id => initially_assigned.dup }
        )

        read_before_assignment = []
        graph.each_node do |node|
          in_state = result.in_states[node.id]
          if node.reads_info.empty?
            node.reads.each do |binding_key|
              next if in_state.include?(binding_key)

              read_before_assignment << ReadBeforeAssignment.new(
                node_id: node.id,
                binding_key:,
                line: node.line,
                column: nil,
                length: nil,
              )
            end
            next
          end

          node.reads_info.each do |read_site|
            next if in_state.include?(read_site.binding_key)

            read_before_assignment << ReadBeforeAssignment.new(
              node_id: node.id,
              binding_key: read_site.binding_key,
              line: read_site.line || node.line,
              column: read_site.column,
              length: read_site.length,
            )
          end
        end

        Result.new(
          definitely_assigned_in: result.in_states,
          definitely_assigned_out: result.out_states,
          read_before_assignment:
        )
      end

      def self.initial_universe(graph, initially_assigned)
        universe = initially_assigned.dup
        graph.each_node do |node|
          universe.merge(node.writes)
          universe.merge(node.reads)
        end
        universe
      end
      private_class_method :initial_universe
    end
  end
end

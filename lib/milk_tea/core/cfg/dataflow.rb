# frozen_string_literal: true

module MilkTea
  module CFG
    class Dataflow
      Result = Data.define(:in_states, :out_states)

      def self.solve(graph, direction:, initial:, join:, transfer: nil, edge_transfer: nil, boundary_in: {}, boundary_out: {})
        raise ArgumentError, "direction must be :forward or :backward" unless %i[forward backward].include?(direction)
        raise ArgumentError, "provide either transfer: or edge_transfer:" if transfer.nil? && edge_transfer.nil?

        in_states  = {}
        out_states = {}
        edge_out   = {}  # [from_id, to_id] => state  (only when edge_transfer given)
        graph.ids.each do |id|
          in_states[id]  = initial.call
          out_states[id] = initial.call
        end

        changed = true
        while changed
          changed = false
          iteration_ids = direction == :forward ? graph.ids : graph.ids.reverse
          iteration_ids.each do |id|
            node = graph.nodes[id]

            if direction == :forward
              incoming =
                if boundary_in.key?(id)
                  boundary_in[id]
                elsif edge_transfer
                  join.call(node.preds.map { |pred| edge_out[[pred, id]] || initial.call })
                else
                  join.call(node.preds.map { |pred| out_states[pred] })
                end

              if edge_transfer
                node.succs.each do |succ|
                  label     = graph.edge_label(id, succ)
                  new_edge  = edge_transfer.call(node, incoming, succ, label)
                  old_edge  = edge_out[[id, succ]]
                  if old_edge != new_edge
                    edge_out[[id, succ]] = new_edge
                    changed = true
                  end
                end
                new_out = node.succs.empty? ? initial.call : join.call(node.succs.map { |s| edge_out[[id, s]] || initial.call })
              else
                new_out = boundary_out.fetch(id) { transfer.call(node, incoming) }
              end

              if in_states[id] != incoming || out_states[id] != new_out
                in_states[id]  = incoming
                out_states[id] = new_out
                changed = true
              end
            else
              outgoing = boundary_out.fetch(id) { join.call(node.succs.map { |succ| in_states[succ] }) }
              incoming = boundary_in.fetch(id)  { transfer.call(node, outgoing) }
              if in_states[id] != incoming || out_states[id] != outgoing
                in_states[id]  = incoming
                out_states[id] = outgoing
                changed = true
              end
            end
          end
        end

        Result.new(in_states:, out_states:)
      end
    end
  end
end

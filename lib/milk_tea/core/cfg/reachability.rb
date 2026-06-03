# frozen_string_literal: true

module MilkTea
  module CFG
    class Reachability
      Result = Data.define(:reachable_ids)

      def self.solve(graph)
        reachable = Set.new
        queue = [graph.entry_id]
        until queue.empty?
          id = queue.shift
          next if reachable.include?(id)

          reachable << id
          (graph.nodes[id]&.succs || []).each { |succ| queue << succ }
        end
        Result.new(reachable_ids: reachable)
      end
    end
  end
end

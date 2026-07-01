# frozen_string_literal: true

module MilkTea
  module ControlFlow
    class Termination
      def self.block_always_terminates?(statements, **builder_options)
        return false if statements.nil? || statements.empty?

        graph = Builder.new(**builder_options).build(statements)
        reachability = Reachability.solve(graph)
        !reachability.reachable_ids.include?(graph.exit_id)
      end

      def self.loop_body_always_exits?(statements, **builder_options)
        return false if statements.nil? || statements.empty?

        graph = Builder.new(**builder_options).build_loop_body(statements)
        reachability = Reachability.solve(graph)
        !reachability.reachable_ids.include?(graph.exit_id)
      end

      def self.block_always_terminates_in_loop?(statements, **builder_options)
        return false if statements.nil? || statements.empty?

        graph = Builder.new(**builder_options).build_loop_branch(statements)
        reachability = Reachability.solve(graph)
        !reachability.reachable_ids.include?(graph.exit_id)
      end
    end
  end
end

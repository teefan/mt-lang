# frozen_string_literal: true

module MilkTea
  module CFG
    class Graph
      attr_accessor :entry_id, :exit_id
      attr_reader :nodes

      def initialize
        @nodes = {}
        @next_id = 1
        @entry_id = nil
        @exit_id = nil
        @edge_labels = {}      # Hash[(from_id, to_id) → :true_branch | :false_branch]
        @edge_refinements = {} # Hash[(from_id, to_id) → Hash[binding_key → :non_null | :null]]
      end

      def add_node(kind:, statement: nil, line: nil, reads: Set.new, reads_info: [], writes: Set.new, writes_info: [])
        id = @next_id
        @next_id += 1
        @nodes[id] = Node.new(
          id:,
          kind:,
          statement:,
          line:,
          reads: reads.dup,
          reads_info: reads_info.map(&:dup),
          writes: writes.dup,
          writes_info: writes_info.map(&:dup),
          succs: [],
          preds: []
        )
        id
      end

      def add_edge(from, to, label: nil)
        return unless @nodes[from] && @nodes[to]

        @nodes[from].succs << to unless @nodes[from].succs.include?(to)
        @nodes[to].preds << from unless @nodes[to].preds.include?(from)
        @edge_labels[[from, to]] = label if label
      end

      def edge_label(from, to)
        @edge_labels[[from, to]]
      end

      def edge_refinement(from, to)
        @edge_refinements[[from, to]]
      end

      def set_edge_refinement(from, to, refinement)
        @edge_refinements[[from, to]] = refinement
      end

      def each_node
        return enum_for(:each_node) unless block_given?

        @nodes.each_value { |node| yield node }
      end

      def ids
        @nodes.keys
      end

      def rpo_ids
        visited = {}
        order = []

        dfs = lambda do |id|
          return if visited[id]

          visited[id] = true
          node = @nodes[id]
          node&.succs&.each { |succ| dfs.call(succ) }
          order.unshift(id)
        end

        dfs.call(@entry_id) if @entry_id
        order
      end

      def read_bindings
        keys = Set.new
        each_node { |node| keys.merge(node.reads) }
        keys
      end
    end
  end
end

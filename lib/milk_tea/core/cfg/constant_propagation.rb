# frozen_string_literal: true

require_relative "../const_eval"

module MilkTea
  module CFG
    class ConstantPropagation
      ConstVal = Data.define(:value)

      UNDEF = :undef
      NAC   = :nac

      Result = Data.define(:in_states, :out_states) do
        def constant_at(node_id, key)
          entry = in_states[node_id]
          return nil unless entry

          v = entry[key]
          v.is_a?(ConstVal) ? v.value : nil
        end
      end

      def self.solve(graph, binding_resolution: nil, strict_binding_ids: false)
        result = Dataflow.solve(
          graph,
          direction: :forward,
          initial: -> { {} },
          join: lambda do |states|
            return {} if states.empty?

            states.reduce do |acc, state|
              keys = acc.keys | state.keys
              keys.each_with_object({}) do |k, merged|
                a = acc[k]   || UNDEF
                b = state[k] || UNDEF
                merged[k] = join_lattice(a, b)
              end
            end
          end,
          transfer: lambda do |node, in_state|
            out = in_state.dup
            node.writes_info.each do |write|
              key = write[:binding_key]
              val = eval_const(node.statement, write, in_state, binding_resolution:, strict_binding_ids:)
              out[key] = val
            end
            out
          end,
          boundary_in: { graph.entry_id => {} }
        )

        Result.new(in_states: result.in_states, out_states: result.out_states)
      end

      def self.join_lattice(a, b)
        return b if a == UNDEF
        return a if b == UNDEF
        return NAC if a == NAC || b == NAC

        a == b ? a : NAC
      end
      private_class_method :join_lattice

      def self.eval_const(statement, _write, in_state, binding_resolution:, strict_binding_ids:)
        case statement
        when AST::LocalDecl
          eval_expr_const(statement.value, in_state, binding_resolution:, strict_binding_ids:)
        when AST::Assignment
          eval_assignment_const(statement, in_state, binding_resolution:, strict_binding_ids:)
        else
          NAC
        end
      end
      private_class_method :eval_const

      def self.eval_assignment_const(statement, in_state, binding_resolution:, strict_binding_ids:)
        return NAC unless statement.target.is_a?(AST::Identifier)

        rhs = eval_expr_const(statement.value, in_state, binding_resolution:, strict_binding_ids:)
        return NAC unless rhs.is_a?(ConstVal)

        return rhs if statement.operator == "="

        lhs = eval_expr_const(statement.target, in_state, binding_resolution:, strict_binding_ids:)
        return NAC unless lhs.is_a?(ConstVal)

        begin
          v = case statement.operator
              when "+="  then lhs.value + rhs.value
              when "-="  then lhs.value - rhs.value
              when "*="  then lhs.value * rhs.value
              when "/="  then rhs.value.zero? ? (return NAC) : lhs.value / rhs.value
              when "%="  then rhs.value.zero? ? (return NAC) : lhs.value % rhs.value
              when "&="  then lhs.value & rhs.value
              when "|="  then lhs.value | rhs.value
              when "^="  then lhs.value ^ rhs.value
              when "<<=" then lhs.value << rhs.value
              when ">>=" then lhs.value >> rhs.value
              else return NAC
              end
          ConstVal.new(v)
        rescue StandardError
          NAC
        end
      end
      private_class_method :eval_assignment_const

      def self.eval_expr_const(expr, state, binding_resolution:, strict_binding_ids:)
        return NAC if expr.nil?

        value = ConstEval.evaluate(
          expr,
          resolve_identifier: lambda do |identifier_expression|
            key = identifier_key(identifier_expression, binding_resolution:, strict_binding_ids:)
            next unless key

            state_value = state[key]
            state_value.is_a?(ConstVal) ? state_value.value : nil
          end,
          resolve_member_access: nil,
        )
        value.nil? ? NAC : ConstVal.new(value)
      end
      private_class_method :eval_expr_const

      def self.constant_value_of(expr, in_state, binding_resolution: nil, strict_binding_ids: false)
        result = send(:eval_expr_const, expr, in_state, binding_resolution:, strict_binding_ids:)
        result.is_a?(ConstVal) ? result.value : nil
      end

      def self.identifier_key(identifier_expression, binding_resolution:, strict_binding_ids:)
        if binding_resolution && (id = binding_resolution.identifier_binding_ids[identifier_expression.object_id])
          return id
        end

        return nil if strict_binding_ids

        identifier_expression.name
      end
      private_class_method :identifier_key
    end
  end
end

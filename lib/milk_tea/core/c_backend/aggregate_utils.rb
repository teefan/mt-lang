# frozen_string_literal: true

module MilkTea
  class CBackend
    module AggregateUtils
      def each_variant_arm_field_type
        @program.variants.each do |variant_decl|
          variant_decl.arms.each do |arm|
            arm.fields.each do |field|
              yield field.type
            end
          end
        end
      end

      def sort_aggregate_decls(struct_decls, union_decls, variant_decls)
        aggregate_decls = struct_decls + union_decls + variant_decls
        by_c_name = aggregate_decls.each_with_object({}) do |aggregate_decl, declarations|
          declarations[aggregate_decl.linkage_name] = aggregate_decl
        end
        variant_decls.each do |variant_decl|
          variant_decl.arms.each do |arm|
            next if arm.fields.empty?
            by_c_name[arm.linkage_name] = variant_decl
          end
        end
        visiting = {}
        visited = {}
        sorted = []

        visit = lambda do |aggregate_decl|
          return if visited[aggregate_decl.linkage_name]
          raise CBackendError.new("cyclic aggregate dependency involving #{aggregate_decl.linkage_name}", line: 0, column: 0, path: @path) if visiting[aggregate_decl.linkage_name]

          visiting[aggregate_decl.linkage_name] = true
          aggregate_decl_dependencies(aggregate_decl).each do |dependency|
            next unless by_c_name.key?(dependency)

            visit.call(by_c_name.fetch(dependency))
          end
          visiting.delete(aggregate_decl.linkage_name)
          visited[aggregate_decl.linkage_name] = true
          sorted << aggregate_decl
        end

        aggregate_decls.each do |aggregate_decl|
          visit.call(aggregate_decl)
        end

        sorted
      end

      def aggregate_decl_dependencies(aggregate_decl)
        own_name = aggregate_decl.linkage_name
        deps = case aggregate_decl
        when IR::StructDecl, IR::UnionDecl
          aggregate_decl.fields.flat_map { |field| aggregate_type_dependencies(field.type) }
        when IR::VariantDecl
          aggregate_decl.arms.flat_map { |arm| arm.fields.flat_map { |field| aggregate_type_dependencies(field.type) } }
        else
          []
        end

        deps.uniq.reject do |dep|
          next true if dep == own_name
          next false unless aggregate_decl.is_a?(IR::VariantDecl)

          (@cyclic_aggregate_pairs || Set.new).include?([own_name, dep])
        end
      end

      def build_cyclic_aggregate_pairs(all_decls)
        by_name = all_decls.each_with_object({}) { |d, h| h[d.linkage_name] = d }
        value_refs = {}
        all_decls.each { |d| value_refs[d.linkage_name] = Set.new }

        all_decls.each do |decl|
          own = decl.linkage_name
          fields = case decl
          when IR::StructDecl, IR::UnionDecl then decl.fields
          when IR::VariantDecl then decl.arms.flat_map(&:fields)
          else []
          end
          fields.each do |f|
            aggregate_type_dependencies(f.type).each do |dep|
              value_refs[own] << dep if by_name.key?(dep) && dep != own
            end
          end
        end

        pairs = Set.new
        value_refs.each do |a, refs|
          refs.each do |b|
            pairs << [a, b] if aggregate_can_reach?(b, a, value_refs)
          end
        end
        pairs
      end

      def aggregate_can_reach?(from, to, value_refs, visited = {})
        return false if visited[from]
        return true if from == to
        return true if (value_refs[from] || Set.new).include?(to)

        visited[from] = true
        (value_refs[from] || Set.new).any? { |next_name| aggregate_can_reach?(next_name, to, value_refs, visited) }
      end

      def aggregate_field_creates_cycle?(field_type, outer_c)
        return true if variant_self_reference?(field_type, outer_c)
        return false unless @cyclic_aggregate_pairs

        target_name = case field_type
        when Types::Variant, Types::VariantInstance, Types::Struct, Types::StructInstance, Types::Union
          named_type_c_name(field_type)
        else
          return false
        end

        @cyclic_aggregate_pairs.include?([outer_c, target_name])
      end

      def aggregate_type_dependencies(type)
        case type
        when Types::Nullable
          if c_backend_pointer_like_type?(type.base)
            aggregate_type_dependencies(type.base)
          else
            [nullable_opt_type_name(type)]
          end
        when Types::Task
          [task_type_name(type)]
        when Types::Proc
          [proc_type_name(type)]
        when Types::GenericInstance
          if pointer_type?(type)
            []
          elsif array_type?(type)
            aggregate_type_dependencies(array_element_type(type))
          elsif str_buffer_type?(type)
            [str_buffer_type_name(type)]
          else
            []
          end
        when Types::Function
          []
        when Types::Struct, Types::StructInstance, Types::Union, Types::Variant, Types::VariantInstance, Types::Event, Types::Subscription
          [named_type_c_name(type)]
        when Types::VariantArmPayload
          [named_type_c_name(type), named_type_c_name(type.variant_type)]
        else
          []
        end
      end
    end
  end
end

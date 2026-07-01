# frozen_string_literal: true

module MilkTea
  class CBackend
    module AggregateUtils
      private

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
              raise CBackendError, "cyclic aggregate dependency involving #{aggregate_decl.linkage_name}" if visiting[aggregate_decl.linkage_name]

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
            case aggregate_decl
            when IR::StructDecl, IR::UnionDecl
              aggregate_decl.fields.flat_map { |field| aggregate_type_dependencies(field.type) }.uniq
            when IR::VariantDecl
              own_name = aggregate_decl.linkage_name
              aggregate_decl.arms.flat_map { |arm| arm.fields.flat_map { |field| aggregate_type_dependencies(field.type) } }
                .uniq
                .reject { |dep| dep == own_name }
            else
              []
            end
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

# frozen_string_literal: true

module MilkTea
  class CBackend
    module CBackendTypes
      private

          C_KEYWORDS = %w[
            auto break case char const continue default do double
            else enum extern float for goto if inline int long
            register restrict return short signed sizeof static
            struct switch typedef union unsigned void volatile while
            _Bool _Complex _Imaginary alignas alignof bool complex
            imaginary noreturn static_assert thread_local
          ].to_set.freeze

          def sanitize_c_identifier(name)
            C_KEYWORDS.include?(name) ? "#{name}_" : name
          end

          def emit_forward_declarations(opaque_decls, aggregate_decls)
            lines = []
            opaque_decls.uniq { |opaque_decl| opaque_decl.linkage_name }.each do |opaque_decl|
              next unless opaque_decl.forward_declarable
              next unless opaque_decl.linkage_name.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)

              lines << "typedef struct #{opaque_decl.linkage_name} #{opaque_decl.linkage_name};"
            end
            aggregate_decls.uniq { |aggregate_decl| [aggregate_decl.class.name, aggregate_decl.linkage_name] }.each do |aggregate_decl|
              case aggregate_decl
              when IR::StructDecl
                lines << "typedef struct #{aggregate_decl.linkage_name} #{aggregate_decl.linkage_name};"
              when IR::UnionDecl
                lines << "typedef union #{aggregate_decl.linkage_name} #{aggregate_decl.linkage_name};"
              when IR::VariantDecl
                lines << "typedef struct #{aggregate_decl.linkage_name} #{aggregate_decl.linkage_name};"
                aggregate_decl.arms.each do |arm|
                  next if arm.fields.empty?
                  lines << "typedef struct #{arm.linkage_name} #{arm.linkage_name};"
                end
              end
            end
            lines
          end

          def emit_struct(struct_decl)
            lines = []
            lines << "struct #{struct_decl.linkage_name} {"
            struct_decl.fields.each do |field|
              lines << "#{INDENT}#{c_field_declaration(field.type, field.name)};"
            end
            lines << "}#{struct_layout_attributes(struct_decl)};"
            lines
          end

          def emit_union(union_decl)
            lines = []
            lines << "union #{union_decl.linkage_name} {"
            union_decl.fields.each do |field|
              lines << "#{INDENT}#{c_field_declaration(field.type, field.name)};"
            end
            lines << "};"
            lines
          end

          def variant_self_reference?(type, outer_c)
            return false unless type.is_a?(Types::Variant) || type.is_a?(Types::VariantInstance)

            named_type_c_name(type) == outer_c
          end

          def emit_variant(variant_decl)
            lines = []
            outer_c = variant_decl.linkage_name
            payload_arms = variant_decl.arms.select { |a| a.fields.any? }

             # Per-arm payload structs
             payload_arms.each do |arm|
               lines << "struct #{arm.linkage_name} {"
                arm.fields.each do |field|
                  if variant_self_reference?(field.type, outer_c)
                    lines << "#{INDENT}#{c_declaration(field.type, "*#{field.name}")};"
                  else
                    lines << "#{INDENT}#{c_field_declaration(field.type, field.name)};"
                  end
                end
               lines << "};"
               lines << "typedef struct #{arm.linkage_name} #{arm.linkage_name};"
             end


            # Kind enum
            lines << "typedef int32_t #{outer_c}_kind;"
            unless variant_decl.arms.empty?
              lines << "enum {"
              variant_decl.arms.each_with_index do |arm, index|
                suffix = index == variant_decl.arms.length - 1 ? "" : ","
                lines << "#{INDENT}#{outer_c}_kind_#{arm.name} = #{index}#{suffix}"
              end
              lines << "};"
            end

            # Data union (only if at least one arm has payload)
            if payload_arms.any?
              lines << "union #{outer_c}__data {"
              payload_arms.each do |arm|
                lines << "#{INDENT}struct #{arm.linkage_name} #{sanitize_c_identifier(arm.name)};"
              end
              lines << "};"
            end

            # Outer struct
            lines << "struct #{outer_c} {"
            lines << "#{INDENT}#{outer_c}_kind kind;"
            lines << "#{INDENT}union #{outer_c}__data data;" if payload_arms.any?
            lines << "};"
            lines
          end

          def emit_enum(enum_decl)
            lines = ["typedef #{c_type(enum_decl.backing_type)} #{enum_decl.linkage_name};"]
            return lines if enum_decl.members.empty?

            lines << "enum {"
            enum_decl.members.each_with_index do |member, index|
              suffix = index == enum_decl.members.length - 1 ? "" : ","
              lines << "#{INDENT}#{member.linkage_name} = #{emit_expression(member.value)}#{suffix}"
            end
            lines << "};"
            lines
          end

          def emit_function_declarations(functions)
            functions.map { |function| "#{function_signature(function)};" }
          end

          def function_signature(function)
            prefix = function.entry_point ? "" : "static "
            "#{prefix}#{c_function_declaration(function.return_type, function.linkage_name, function_params(function))}"
          end

          def function_params(function)
            params = []
            params << array_out_param_declaration(function.return_type, ARRAY_OUT_PARAM_NAME) if array_type?(function.return_type)
            params.concat(emitted_function_params(function).map { |param| c_declaration(param.pointer ? pointer_to(param.type) : param.type, param.linkage_name) })

            if params.empty?
              "void"
            else
              params.join(", ")
            end
          end

          def emit_function(function)
            @checked_index_alias_stack.clear
            @checked_index_alias_id = 0
            @suppressed_labels = []
            body = compact_generated_statement_sequence(function.body)
            lines = ["#{function_signature(function)} {"]
            used_labels = collect_used_labels(body)
            if body.empty?
              lines << "}"
            else
              lines.concat(emit_statement_sequence(body, 1, function:, used_labels:))
              lines << "}"
            end
            lines
          end

          def emit_string_type
            [
              "typedef struct mt_str {",
              "#{INDENT}char* data;",
              "#{INDENT}uintptr_t len;",
              "} mt_str;",
            ]
          end

          def emit_span_type(type)
            span_type = span_type_name(type)
            [
              "typedef struct #{span_type} {",
              "#{INDENT}#{c_declaration(pointer_to(type.element_type), 'data')};",
              "#{INDENT}#{c_declaration(Types::Registry.primitive('ptr_uint'), 'len')};",
              "} #{span_type};",
            ]
          end

          def emit_soa_type(type)
            name = soa_type_name(type)
            lines = ["typedef struct #{name} {"]
            type.fields.each do |field_name, field_type|
              lines << "#{INDENT}#{c_field_declaration(field_type, field_name)};"
            end
            lines << "} #{name};"
            lines
          end

          def struct_layout_attributes(struct_decl)
            attributes = []
            attributes << "packed" if struct_decl.packed
            attributes << "aligned(#{struct_decl.alignment})" if struct_decl.alignment
            return "" if attributes.empty?

            " __attribute__((#{attributes.join(', ')}))"
          end

          def emit_vector_math_types
            lines = []
            lines << "typedef struct mt_vec2 { float x; float y; } mt_vec2;"
            lines << "typedef struct mt_vec3 { float x; float y; float z; } mt_vec3;"
            lines << "typedef struct mt_vec4 { float x; float y; float z; float w; } mt_vec4;"
            lines << "typedef struct mt_ivec2 { int32_t x; int32_t y; } mt_ivec2;"
            lines << "typedef struct mt_ivec3 { int32_t x; int32_t y; int32_t z; } mt_ivec3;"
            lines << "typedef struct mt_ivec4 { int32_t x; int32_t y; int32_t z; int32_t w; } mt_ivec4;"
            lines << ""
            lines << "typedef struct mt_mat3 { mt_vec3 col0; mt_vec3 col1; mt_vec3 col2; } mt_mat3;"
            lines << "typedef struct mt_mat4 { mt_vec4 col0; mt_vec4 col1; mt_vec4 col2; mt_vec4 col3; } mt_mat4;"
            lines << "typedef struct mt_quat { float x; float y; float z; float w; } mt_quat;"
            lines
          end
    end
  end
end

# frozen_string_literal: true

module MilkTea
  module Bindgen
    class Generator
      module GeneratorDeclaration
        private

        def select_record_declarations(nodes)
          selected = {}

          nodes.each_with_index do |node, index|
            record_node, original_name = case node["kind"]
            when "RecordDecl"
              [node, @record_aliases[node["id"]] || node["name"]]
            when "TypedefDecl"
              target = typedef_target(node)
              next unless target&.fetch(:kind, nil) == "RecordDecl"

              record_node = @referenceable_record_declarations_by_id[target[:id]] || @referenceable_record_declarations[target[:name]]
              next unless record_node

              [record_node, node["name"]]
            else
              next
            end

            next unless %w[struct union].include?(record_node["tagUsed"])

            next unless original_name
            next unless allowed_declaration_name?(original_name)

            visible_name = visible_type_name(original_name)

            candidate = {
              index:,
              kind: record_complete_definition?(record_node) ? record_node["tagUsed"] : "opaque",
              name: visible_name,
              c_name: record_c_name(record_node),
              node: record_node,
            }

            existing = selected[visible_name]
            if existing.nil? || (existing[:kind] == "opaque" && candidate[:kind] != "opaque")
              selected[visible_name] = candidate
            end
          end

          @record_visible_names = {}
          selected.each_value do |declaration|
            tag_name = declaration[:node]["name"]
            @record_visible_names[tag_name] = declaration[:name] if tag_name
            @record_visible_names[declaration[:name]] = declaration[:name]
            @aggregate_declarations[declaration[:name]] = declaration[:node] if %w[struct union].include?(declaration[:kind])
          end
          selected.values
        end

        def record_complete_definition?(node)
          return true if node["completeDefinition"]

          Array(node["inner"]).any? { |child| child["kind"] == "FieldDecl" }
        end

        def select_enum_declarations(nodes)
          selected = {}

          nodes.each_with_index do |node, index|
            next unless node["kind"] == "EnumDecl"

            original_name = @enum_aliases[node["id"]] || node["name"]
            next unless original_name
            next unless allowed_declaration_name?(original_name)

            visible_name = visible_type_name(original_name)

            selected[visible_name] = { index:, kind: enum_kind(node), name: visible_name, node: }
          end

          @enum_visible_names = {}
          selected.each_value do |declaration|
            tag_name = declaration[:node]["name"]
            @enum_visible_names[tag_name] = declaration[:name] if tag_name
            @enum_visible_names[declaration[:name]] = declaration[:name]
          end
          selected.values
        end

        def select_type_alias_declarations(nodes)
          alias_names = nodes.filter_map { |node| node["name"] if node["kind"] == "TypedefDecl" }

          nodes.each_with_index.filter_map do |node, index|
            next unless node["kind"] == "TypedefDecl"
            next if typedef_target(node)
            next unless allowed_declaration_name?(node["name"])

            qual_type = alias_qual_type(node)
            mapped_type = if extract_function_proto(node)
                            map_function_pointer_typedef(node, context: node["name"])
                          else
                            map_c_type(qual_type, context: node["name"])
                          end
            next if node["name"] == mapped_type
            next if unresolved_alias_target?(mapped_type, alias_names)

            {
              index:,
              kind: "type_alias",
              name: visible_type_name(node["name"]),
              mapped_type:,
            }
          rescue BindgenError
            nil
          end

        end

        def alias_qual_type(node)
          type_qual_type(node)
        end

        def select_function_declarations(nodes)
          selected = {}

          nodes.each_with_index do |node, index|
            next unless node["kind"] == "FunctionDecl"
            has_body = Array(node["inner"]).any? { |child| child["kind"] == "CompoundStmt" }
            next if node["storageClass"] == "static" && !@allow_static_inline_functions
            next if has_body && !(node["storageClass"] == "static" && @allow_static_inline_functions)
            next unless allowed_declaration_name?(node["name"])

            params = Array(node["inner"]).select { |child| child["kind"] == "ParmVarDecl" }.each_with_index.map do |param, param_index|
              param_name = param["name"] || "arg#{param_index}"
              override_type = function_param_type_override(node["name"], param_name)
              record_nullable_param_override(node["name"], param_name, param, override_type) if override_type
              {
                name: param_name,
                type: override_type || map_type_node(param, context: "parameter #{param_name} of #{node["name"]}"),
              }
            end

            override_return_type = function_return_type_override(node["name"])
            record_nullable_return_override(node, override_return_type) if override_return_type
            return_type = override_return_type || map_c_type(function_return_type(node), context: "return type of #{node["name"]}")
            declaration = {
              index:,
              kind: "function",
              name: node["name"],
              params:,
              variadic: node["variadic"],
              return_type:,
            }
            selected[declaration[:name]] ||= declaration
          rescue BindgenError
            next
          end

          selected.values
        end

        def validate_function_param_type_overrides!(function_declarations)
          return if @function_param_type_overrides.empty?

          declarations_by_name = function_declarations.to_h { |declaration| [declaration[:name], declaration] }

          @function_param_type_overrides.each do |function_name, param_overrides|
            declaration = declarations_by_name[function_name]
            raise BindgenError, "function_param_type_overrides references unknown function #{function_name} for #{@header_path}" unless declaration

            param_names = declaration[:params].map { |param| param[:name] }
            param_overrides.each_key do |param_name|
              next if param_names.include?(param_name)

              raise BindgenError, "function_param_type_overrides references unknown parameter #{function_name}.#{param_name} for #{@header_path}"
            end
          end
        end

        def validate_function_return_type_overrides!(function_declarations)
          return if @function_return_type_overrides.empty?

          declarations_by_name = function_declarations.to_h { |declaration| [declaration[:name], declaration] }

          @function_return_type_overrides.each_key do |function_name|
            next if declarations_by_name.key?(function_name)

            raise BindgenError, "function_return_type_overrides references unknown function #{function_name} for #{@header_path}"
          end
        end

        def validate_field_type_overrides!(record_declarations)
          return if @field_type_overrides.empty?

          declarations_by_name = record_declarations.to_h { |declaration| [declaration[:name], declaration] }

          @field_type_overrides.each do |type_name, field_overrides|
            declaration = declarations_by_name[type_name]
            raise BindgenError, "field_type_overrides references unknown type #{type_name} for #{@header_path}" unless declaration

            field_names = Array(declaration[:node]["inner"]).select { |child| child["kind"] == "FieldDecl" }.map { |field| field["name"] }
            field_overrides.each_key do |field_name|
              next if field_names.include?(field_name)

              raise BindgenError, "field_type_overrides references unknown field #{type_name}.#{field_name} for #{@header_path}"
            end
          end
        end

        def select_constant_declarations(nodes)
          nodes.each_with_index.filter_map do |node, index|
            next unless node["kind"] == "VarDecl"
            next if node["isInvalid"]
            next unless constant_var_decl?(node)
            next unless allowed_declaration_name?(constant_name_for(node))

            begin
              initializer = Array(node["inner"]).first
              type = macro_string_constant_type(node, initializer, context: constant_name_for(node))
              type ||= map_c_type(constant_qual_type(node), context: constant_name_for(node))
              value = lower_constant_expression(initializer, expected_type: type, context: constant_name_for(node))
            rescue BindgenError
              raise unless macro_probe_declaration?(node)

              next
            end

            {
              index:,
              kind: "const",
              name: constant_name_for(node),
              type:,
              value:,
            }
          end
        end

        def macro_string_constant_type(node, initializer, context:)
          return nil unless macro_probe_declaration?(node)
          return nil unless constant_expression_kind(initializer) == "StringLiteral"

          qual_type = normalize_c_type(constant_qual_type(node))
          qual_type, = extract_top_level_nullability(qual_type)
          return "cstr" if string_literal_macro_compatible_c_type?(qual_type)

          raise BindgenError, "unsupported string macro type #{qual_type.inspect} for #{context}"
        end

        def constant_expression_kind(node)
          current = node

          while current.is_a?(Hash)
            case current["kind"]
            when "ImplicitCastExpr", "ConstantExpr", "CompoundLiteralExpr", "ParenExpr"
              current = Array(current["inner"]).first
            else
              return current["kind"]
            end
          end

          nil
        end

        def constant_var_decl?(node)
          qual_type = node.dig("type", "qualType")
          node["init"] && strip_qualifiers(normalize_c_type(qual_type)) != normalize_c_type(qual_type)
        end

        def constant_qual_type(node)
          qual_type = node.dig("type", "qualType")
          if macro_probe_declaration?(node) && qual_type.to_s.include?("typeof")
            node.dig("type", "desugaredQualType") || qual_type
          else
            qual_type
          end
        end

        def function_return_type(node)
          qual_type = type_qual_type(node)
          match = qual_type&.match(/\A(.+?)\s*\((?:.*)\)\z/)
          raise BindgenError, "unsupported function type for #{node["name"]}: #{qual_type.inspect}" unless match

          match[1]
        end

        def type_qual_type(node)
          qual_type = node.dig("type", "qualType")
          return qual_type if qual_type.to_s.match?(/_Nullable|_Nonnull|_Null_unspecified|_Nullable_result/)

          node.dig("type", "desugaredQualType") || qual_type
        end

        def enum_kind(node)
          values = enum_member_values(node).map { |member| member[:value] }
          non_zero = values.reject(&:zero?)
          return "enum" if non_zero.empty?

          non_zero.all? { |value| power_of_two?(value) } ? "flags" : "enum"
        end

        def power_of_two?(value)
          value.positive? && (value & (value - 1)).zero?
        end
      end
    end
  end
end

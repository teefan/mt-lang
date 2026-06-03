# frozen_string_literal: true

module MilkTea
  module Bindgen
    class Generator
      module GeneratorTypeMapper
        private

        def map_c_type(qual_type, context:)
          normalized = normalize_c_type(qual_type)
          raise BindgenError, "missing C type for #{context}" if normalized.empty?
          normalized, nullability = extract_top_level_nullability(normalized)
          mapped_type = if array_type?(normalized)
                          map_array_type(normalized, context:)
                        elsif function_pointer_type?(normalized)
                          map_function_pointer_type(normalized, context:)
                        else
                          pointer_candidate = strip_pointer_suffix_qualifiers(normalized)
                          if pointer_type?(pointer_candidate)
                            if va_list_pointer?(pointer_candidate)
                              synthesize_typedef_dependency("va_list")
                              "va_list"
                            elsif c_string_pointer?(pointer_candidate)
                              "cstr"
                            else
                              pointee = pointer_candidate.sub(/\s*\*\z/, "")
                              pointer_name = top_level_const_qualified?(pointee) ? "const_ptr" : "ptr"
                              "#{pointer_name}[#{map_c_type(pointee, context:)}]"
                            end
                          else
                            unqualified = strip_qualifiers(normalized)
                            if unqualified == "__va_list_tag" || unqualified == "struct __va_list_tag"
                              synthesize_typedef_dependency("__va_list_tag")
                              "__va_list_tag"
                            elsif standard_typedef_primitive(unqualified)
                              standard_typedef_primitive(unqualified)
                            elsif PRIMITIVE_TYPE_MAP.key?(unqualified)
                              PRIMITIVE_TYPE_MAP.fetch(unqualified)
                            elsif @type_overrides.key?(unqualified)
                              @type_overrides.fetch(unqualified)
                            elsif unqualified.start_with?("long") || unqualified.start_with?("unsigned long") || unqualified.start_with?("signed long")
                              map_long_type(unqualified, context:)
                            elsif unqualified.start_with?("struct ") || unqualified.start_with?("union ") || unqualified.start_with?("enum ")
                              tag_name = unqualified.split.last
                              @type_overrides.fetch(tag_name) do
                                if unqualified.start_with?("struct ")
                                  record_name_for(unqualified)
                                elsif unqualified.start_with?("union ")
                                  record_name_for(unqualified)
                                else
                                  enum_name_for(unqualified)
                                end
                              end
                            elsif unqualified.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
                              if known_generated_type_name?(unqualified, @visible_typedef_names)
                                visible_type_name(unqualified)
                              else
                                raise BindgenError, "unknown referenced C type #{unqualified.inspect} for #{context}"
                              end
                            else
                              raise BindgenError, "unsupported C type #{qual_type.inspect} for #{context}"
                            end
                          end
                        end

          apply_nullability(mapped_type, nullability)
        end

        def array_type?(qual_type)
          qual_type.match?(/\[[0-9]+\]\z/)
        end

        def map_array_type(qual_type, context:)
          match = qual_type.match(/\A(.+)\[([0-9]+)\]\z/)
          raise BindgenError, "unsupported array type #{qual_type.inspect} for #{context}" unless match

          element_type = map_c_type(match[1], context: "element type of #{context}")
          length = Integer(match[2], 10)
          "array[#{element_type}, #{length}]"
        end

        def va_list_pointer?(qual_type)
          stripped = strip_qualifiers(qual_type)
          stripped == "struct __va_list_tag *" || stripped == "__va_list_tag *"
        end

        def function_pointer_type?(qual_type)
          qual_type.match?(/\A.+\(\s*\*.*\)\s*\(.*\)\z/)
        end

        def map_function_pointer_typedef(node, context:)
          function_proto = extract_function_proto(node)
          raise BindgenError, "unsupported function pointer type #{node.dig("type", "qualType").inspect} for #{context}" unless function_proto

          map_function_proto_node(function_proto, context:, nullability: function_pointer_surface_nullability(type_qual_type(node)))
        end

        def map_function_proto_node(function_proto, context:, nullability: nil)
          inner_types = Array(function_proto["inner"])
          raise BindgenError, "unsupported function pointer type #{function_proto.inspect} for #{context}" if inner_types.empty?

          return_type = map_type_node(inner_types.first, context: "return type of #{context}")
          param_types = inner_types.drop(1)
          params = if param_types.empty? || (param_types.length == 1 && void_type_node?(param_types.first))
                     []
                   else
                     param_types.each_with_index.map do |param_type, index|
                       "arg#{index}: #{map_type_node(param_type, context: "parameter #{index} of #{context}")}"
                     end
                   end
          apply_nullability("fn(#{params.join(', ')}) -> #{return_type}", nullability)
        end

        def map_function_pointer_type(qual_type, context:)
          return_type_source, declarator_source, params_source = parse_function_pointer_signature(qual_type, context:)

          # Handles C forms like `void (*)(...)` and pointer-wrapped variants like `void (**)(...)`.
          pointer_depth_match = declarator_source.match(/\A((?:\*\s*)+)((?:_Nullable|_Nonnull|_Null_unspecified|_Nullable_result)?)\s*\z/)
          if pointer_depth_match
            pointer_depth = pointer_depth_match[1].count("*")
            base_nullability = nullability_for_token(pointer_depth_match[2])
            function_type = build_function_type(
              return_type_source:,
              params_source:,
              nullability: base_nullability,
              context:,
            )

            wrapped_type = function_type
            (pointer_depth - 1).times do
              wrapped_type = "ptr[#{wrapped_type}]"
            end
            return wrapped_type
          end

          # Handles C forms like `void (*(*)(...))(...)` (function pointer returning function pointer).
          nested_match = declarator_source.match(/\A\*\s*((?:_Nullable|_Nonnull|_Null_unspecified|_Nullable_result)?)\s*\(\s*\*\s*((?:_Nullable|_Nonnull|_Null_unspecified|_Nullable_result)?)\s*\)\s*\((.*)\)\s*\z/)
          if nested_match
            outer_nullability = nullability_for_token(nested_match[1])
            returned_fn_nullability = nullability_for_token(nested_match[2])
            outer_params_source = nested_match[3]

            returned_fn_type = build_function_type(
              return_type_source:,
              params_source:,
              nullability: returned_fn_nullability,
              context: "return type of #{context}",
            )

            outer_params = function_params_from_source(outer_params_source, context:)
            return apply_nullability("fn(#{outer_params.join(', ')}) -> #{returned_fn_type}", outer_nullability)
          end

          raise BindgenError, "unsupported function pointer type #{qual_type.inspect} for #{context}"
        end

        def parse_function_pointer_signature(qual_type, context:)
          source = qual_type.strip
          raise BindgenError, "unsupported function pointer type #{qual_type.inspect} for #{context}" unless source.end_with?(")")

          params_start = matching_open_paren_index(source, source.length - 1)
          raise BindgenError, "unsupported function pointer type #{qual_type.inspect} for #{context}" unless params_start

          params_source = source[(params_start + 1)...-1]
          prefix = source[0...params_start].rstrip
          raise BindgenError, "unsupported function pointer type #{qual_type.inspect} for #{context}" unless prefix.end_with?(")")

          declarator_end = prefix.length - 1
          declarator_start = matching_open_paren_index(prefix, declarator_end)
          raise BindgenError, "unsupported function pointer type #{qual_type.inspect} for #{context}" unless declarator_start

          declarator_source = prefix[(declarator_start + 1)...declarator_end].strip
          return_type_source = prefix[0...declarator_start].rstrip
          raise BindgenError, "unsupported function pointer type #{qual_type.inspect} for #{context}" if return_type_source.empty?

          [return_type_source, declarator_source, params_source]
        end

        def matching_open_paren_index(source, close_index)
          depth = 0
          index = close_index

          while index >= 0
            char = source[index]
            if char == ")"
              depth += 1
            elsif char == "("
              depth -= 1
              return index if depth.zero?
            end
            index -= 1
          end

          nil
        end

        def function_params_from_source(params_source, context:)
          param_list = split_top_level_csv(params_source)
          return [] if param_list.empty? || (param_list.length == 1 && strip_qualifiers(param_list.first) == "void")

          param_list.each_with_index.map do |param_type, index|
            "arg#{index}: #{map_c_type(param_type, context: "parameter #{index} of #{context}")}"
          end
        end

        def build_function_type(return_type_source:, params_source:, nullability:, context:)
          return_type = map_c_type(return_type_source, context: "return type of #{context}")
          params = function_params_from_source(params_source, context:)
          apply_nullability("fn(#{params.join(', ')}) -> #{return_type}", nullability)
        end

        def split_top_level_csv(source)
          return [] if source.strip.empty?

          parts = []
          current = +""
          depth = 0

          source.each_char do |char|
            case char
            when "(", "["
              depth += 1
              current << char
            when ")", "]"
              depth -= 1 if depth.positive?
              current << char
            when ","
              if depth.zero?
                parts << current.strip
                current = +""
              else
                current << char
              end
            else
              current << char
            end
          end

          parts << current.strip unless current.strip.empty?
          parts
        end

        def extract_function_proto(node)
          queue = Array(node["inner"]).dup
          until queue.empty?
            current = queue.shift
            next unless current.is_a?(Hash)
            return current if current["kind"] == "FunctionProtoType"

            queue.concat(Array(current["inner"]))
          end
          nil
        end

        def map_type_node(node, context:)
          alias_name = typedef_name_from_type_node(node)
          return @type_overrides.fetch(alias_name) if alias_name && @type_overrides.key?(alias_name)

          if alias_name && preserve_typedef_name?(alias_name) && direct_typedef_surface?(node, alias_name)
            synthesize_typedef_dependency(alias_name)
            return visible_type_name(alias_name)
          end

          qual_type = type_qual_type(node)
          if function_pointer_type?(qual_type)
            function_proto = extract_function_proto(node)
            return map_function_proto_node(function_proto, context:, nullability: function_pointer_surface_nullability(qual_type)) if function_proto
          end

          map_c_type(qual_type, context:)
        end

        def preserve_typedef_name?(name)
          name == "va_list" || @visible_typedef_names.include?(name)
        end

        def direct_typedef_surface?(node, alias_name)
          spelled_type = normalize_c_type(node.dig("type", "qualType"))
          strip_qualifiers(spelled_type) == alias_name
        end

        def unresolved_alias_target?(mapped_type, alias_names)
          match = mapped_type.match(/\A([A-Za-z_][A-Za-z0-9_]*)\z/)
          return false unless match

          name = match[1]
          return false unless name.start_with?("__")

          !known_generated_type_name?(name, alias_names)
        end

        def known_generated_type_name?(name, alias_names)
          return true if PRIMITIVE_TYPE_MAP.value?(name)
          return true if alias_names.include?(name)
          return true if @record_visible_names.value?(name)
          return true if @enum_visible_names.value?(name)
          return true if @synthetic_declarations.any? { |declaration| declaration[:name] == name }

          false
        end

        def typedef_name_from_type_node(node)
          queue = [node]
          until queue.empty?
            current = queue.shift
            next unless current.is_a?(Hash)

            if current["kind"] == "TypedefType"
              name = current.dig("decl", "name")
              return name if name && name != "__builtin_va_list"
            end

            queue.concat(Array(current["inner"]))
          end
          nil
        end

        def void_type_node?(node)
          node["kind"] == "BuiltinType" && normalize_c_type(node.dig("type", "qualType")) == "void"
        end

        def synthesize_typedef_dependency(name)
          case name
          when "va_list"
            return if @synthetic_declarations.any? { |declaration| declaration[:name] == "va_list" }

            @synthetic_declarations << { kind: "opaque", name: "va_list", c_name: "va_list" }
          when "__va_list_tag"
            return if @synthetic_declarations.any? { |declaration| declaration[:name] == "__va_list_tag" }

            @synthetic_declarations << { kind: "opaque", name: "__va_list_tag", c_name: "__va_list_tag" }
          end
        end

        def record_c_name(node)
          return unless node

          typedef_name = @record_aliases[node["id"]]
          typedef_name ||= @record_aliases_by_tag_name[node["name"]] if node["name"]
          return typedef_name if typedef_name

          tag_name = node["name"]
          return "#{node["tagUsed"]} #{tag_name}" if tag_name && !tag_name.empty?

          nil
        end

        def aggregate_explicit_c_name(name, node)
          c_name = record_c_name(node)
          return if c_name.nil? || c_name == name

          c_name
        end

        def synthetic_declarations_for(declarations)
          existing_names = declarations.filter_map { |declaration| declaration[:name] }.to_h { |name| [name, true] }
          @synthetic_declarations.reject { |declaration| existing_names.key?(declaration[:name]) }
        end

        def normalize_c_type(qual_type)
          qual_type.to_s.gsub(/\s+/, " ").strip
        end

        def extract_top_level_nullability(qual_type)
          result = qual_type
          nullability = nil
          qualifier_pattern = NULLABILITY_QUALIFIERS.join("|")

          loop do
            match = result.match(/\s*(#{qualifier_pattern})\z/)
            break unless match

            nullability ||= nullability_for_token(match[1])
            result = result[0...match.begin(0)].rstrip
          end

          [result, nullability]
        end

        def function_pointer_surface_nullability(qual_type)
          match = normalize_c_type(qual_type).match(/\(\s*\*\s*(_Nullable|_Nonnull|_Null_unspecified|_Nullable_result)?\s*\)\s*\(/)
          nullability_for_token(match && match[1])
        end

        def nullability_for_token(token)
          return :nullable if token == "_Nullable" || token == "_Nullable_result"
          return :nonnull if token == "_Nonnull"
          return :unspecified if token == "_Null_unspecified"

          nil
        end

        def apply_nullability(mapped_type, nullability)
          return mapped_type unless nullability == :nullable
          return mapped_type if mapped_type.end_with?("?")

          "#{mapped_type}?"
        end

        def nullable_policy_type?(type)
          type.include?("?")
        end

        def record_nullable_param_override(function_name, param_name, param_node, override_type)
          return unless nullable_policy_type?(override_type)

          auto_type, auto_error = infer_bindgen_type do
            map_type_node(param_node, context: "parameter #{param_name} of #{function_name}")
          end
          return if auto_error.nil? && auto_type == override_type

          @manual_nullable_param_overrides << {
            function: function_name,
            parameter: param_name,
            override_type: override_type,
            auto_type: auto_type,
            c_type: type_qual_type(param_node),
            auto_error: auto_error,
          }.compact
        end

        def record_nullable_return_override(node, override_type)
          return unless nullable_policy_type?(override_type)

          auto_type, auto_error = infer_bindgen_type do
            map_c_type(function_return_type(node), context: "return type of #{node["name"]}")
          end
          return if auto_error.nil? && auto_type == override_type

          @manual_nullable_return_overrides << {
            function: node["name"],
            override_type: override_type,
            auto_type: auto_type,
            c_type: function_return_type(node),
            auto_error: auto_error,
          }.compact
        end

        def infer_bindgen_type
          [yield, nil]
        rescue BindgenError => e
          [nil, e.message]
        end

        def strip_pointer_suffix_qualifiers(qual_type)
          result = qual_type
          qualifier_pattern = QUALIFIERS.join("|")

          loop do
            updated = result.sub(/\s*(?:#{qualifier_pattern})\z/, "")
            break if updated == result

            result = updated
          end

          result
        end

        def top_level_const_qualified?(qual_type)
          normalized = normalize_c_type(qual_type)
          pointer_candidate = strip_pointer_suffix_qualifiers(normalized)
          if pointer_type?(pointer_candidate)
            return pointer_suffix_qualifiers(normalized).include?("const")
          end

          normalized.split.include?("const")
        end

        def pointer_suffix_qualifiers(qual_type)
          result = qual_type
          qualifier_pattern = QUALIFIERS.join("|")
          qualifiers = []

          loop do
            match = result.match(/\s*(#{qualifier_pattern})\z/)
            break unless match

            qualifiers << match[1]
            result = result[0...match.begin(0)]
          end

          qualifiers
        end

        def standard_typedef_primitive(unqualified)
          return "ptr_uint" if unqualified == "size_t"
          return "ptr_int" if unqualified == "ssize_t" || unqualified == "ptrdiff_t"
          return "int" if unqualified == "wchar_t"

          integer_typedef_primitive(unqualified)
        end

        def integer_typedef_primitive(unqualified)
          match = unqualified.match(/\A(?:__)?(u_?)?int(8|16|32|64)_t\z/)
          return unless match

          signed_prefix = match[1]
          width = match[2]
          if signed_prefix
            {
              "8" => "ubyte",
              "16" => "ushort",
              "32" => "uint",
              "64" => "ulong",
            }.fetch(width)
          else
            {
              "8" => "byte",
              "16" => "short",
              "32" => "int",
              "64" => "long",
            }.fetch(width)
          end
        end

        def pointer_type?(qual_type)
          qual_type.end_with?("*")
        end

        def c_string_pointer?(qual_type)
          pointee = qual_type.sub(/\s*\*\z/, "")
          unqualified = strip_qualifiers(pointee)
          unqualified == "char" && pointee.split.include?("const")
        end

        def string_literal_macro_compatible_c_type?(qual_type)
          pointer_candidate = strip_pointer_suffix_qualifiers(qual_type)
          return true if c_string_pointer?(pointer_candidate)

          match = qual_type.match(/\A(.+)\[[0-9]+\]\z/)
          return false unless match

          strip_qualifiers(match[1]) == "char"
        end

        def strip_qualifiers(qual_type)
          qual_type.split.reject { |token| QUALIFIERS.include?(token) }.join(" ")
        end

        def map_long_type(unqualified, context:)
          case unqualified
          when "long", "long int", "signed long", "signed long int"
            long_width_type(signed: true)
          when "unsigned long", "unsigned long int"
            long_width_type(signed: false)
          else
            raise BindgenError, "unsupported C type #{context}: #{unqualified.inspect}"
          end
        end

        def long_width_type(signed:)
          width = long_width_bytes
          mapping = signed ? { 4 => "int", 8 => "long" } : { 4 => "uint", 8 => "ulong" }
          mapping.fetch(width) do
            raise BindgenError, "unsupported C long width #{width} bytes"
          end
        end

        def long_width_bytes
          return @long_width_bytes if defined?(@long_width_bytes)

          stdout, stderr, status = Open3.capture3(@clang, "-x", "c", "-dM", "-E", "-", *@clang_args, stdin_data: "")
          unless status.success?
            details = [stdout, stderr].reject(&:empty?).join
            raise BindgenError, details.empty? ? "failed to query clang target macros" : "failed to query clang target macros:\n#{details}"
          end

          define = stdout.lines.find { |line| line.start_with?("#define __SIZEOF_LONG__ ") }
          raise BindgenError, "clang did not report __SIZEOF_LONG__" unless define

          @long_width_bytes = Integer(define.split.last, 10)
        end

        def record_name_for(unqualified)
          synthesize_record_dependency(unqualified)
          tag_name = unqualified.split.last
          @record_visible_names[tag_name] || tag_name
        end

        def enum_name_for(unqualified)
          tag_name = unqualified.split.last
          @enum_visible_names[tag_name] || tag_name
        end

        def synthesize_record_dependency(unqualified)
          kind, tag_name = unqualified.split(" ", 2)
          return unless %w[struct union].include?(kind)
          return if tag_name.nil? || tag_name.empty?
          return if @record_visible_names.key?(tag_name) || @record_visible_names.value?(tag_name)

          record_node = @referenceable_record_declarations[tag_name]
          original_name = record_node ? (@record_aliases[record_node["id"]] || tag_name) : tag_name
          visible_name = visible_type_name(original_name)
          return if @synthetic_declarations.any? { |declaration| declaration[:name] == visible_name }

          @record_visible_names[tag_name] = visible_name
          @record_visible_names[visible_name] = visible_name

          if record_node && record_complete_definition?(record_node)
            @synthetic_declarations << {
              kind: record_node.fetch("tagUsed"),
              name: visible_name,
              node: record_node,
            }
            @aggregate_declarations[visible_name] = record_node
            return
          end

          @synthetic_declarations << {
            kind: "opaque",
            name: visible_name,
            c_name: "#{kind} #{tag_name}",
          }
        end

        def visible_type_name(name)
          @type_name_overrides.fetch(name, name)
        end
      end
    end
  end
end

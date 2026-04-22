# frozen_string_literal: true

require "json"
require "open3"
require "tempfile"

module MilkTea
  module Bindgen
    MACRO_CONST_PREFIX = "__mt_bindgen_macro_"
    QUALIFIERS = %w[const volatile restrict].freeze
    NON_VALUE_MACRO_TOKENS = %w[
      extern static inline typedef struct union enum do if else for while return sizeof
      __attribute__ __attribute __declspec
    ].freeze
    PRIMITIVE_TYPE_MAP = {
      "_Bool" => "bool",
      "bool" => "bool",
      "void" => "void",
      "char" => "char",
      "signed char" => "i8",
      "unsigned char" => "u8",
      "short" => "i16",
      "short int" => "i16",
      "signed short" => "i16",
      "signed short int" => "i16",
      "unsigned short" => "u16",
      "unsigned short int" => "u16",
      "int" => "i32",
      "signed" => "i32",
      "signed int" => "i32",
      "unsigned" => "u32",
      "unsigned int" => "u32",
      "long long" => "i64",
      "long long int" => "i64",
      "signed long long" => "i64",
      "signed long long int" => "i64",
      "unsigned long long" => "u64",
      "unsigned long long int" => "u64",
      "float" => "f32",
      "double" => "f64",
    }.freeze

    def self.generate(module_name:, header_path:, link_libraries: [], include_directives: nil, clang: ENV.fetch("CLANG", "clang"), clang_args: [])
      Generator.new(
        module_name:,
        header_path:,
        link_libraries:,
        include_directives:,
        clang:,
        clang_args:,
      ).generate
    end

    class Generator
      def initialize(module_name:, header_path:, link_libraries:, include_directives:, clang:, clang_args:)
        @module_name = module_name
        @header_path = File.expand_path(header_path)
        @link_libraries = link_libraries.dup
        @include_directives = include_directives&.dup
        @clang = clang
        @clang_args = clang_args.dup
        @record_aliases = {}
        @enum_aliases = {}
        @record_visible_names = {}
        @enum_visible_names = {}
        @aggregate_declarations = {}
        @synthetic_declarations = []
      end

      def generate
        ast = dump_ast
        top_level_nodes = extract_top_level_header_nodes(ast)
        build_alias_maps(top_level_nodes)

        declarations = []
        declarations.concat(select_record_declarations(top_level_nodes))
        declarations.concat(select_enum_declarations(top_level_nodes))
        declarations.concat(select_type_alias_declarations(top_level_nodes))
        declarations.concat(select_constant_declarations(top_level_nodes))
        declarations.concat(select_function_declarations(top_level_nodes))
        declarations.sort_by! { |declaration| declaration[:index] }

        emit_module(declarations)
      end

      private

      def dump_ast
        Tempfile.create(["milk-tea-bindgen", ".c"]) do |translation_unit|
          @translation_unit_path = translation_unit.path
          translation_unit.write(%(#include #{@header_path.dump}\n))
          macro_probe_declarations.each do |declaration|
            translation_unit.write(declaration)
            translation_unit.write("\n")
          end
          translation_unit.flush
          translation_unit.close

          command = [
            @clang,
            "-x",
            "c",
            "-fno-builtin",
            *@clang_args,
            "-Xclang",
            "-ast-dump=json",
            "-fsyntax-only",
            translation_unit.path,
          ]
          stdout, stderr, status = Open3.capture3(*command)
          unless status.success?
            details = [stdout, stderr].reject(&:empty?).join
            raise BindgenError, details.empty? ? "clang bindgen failed" : "clang bindgen failed:\n#{details}"
          end

          JSON.parse(stdout)
        end
      rescue Errno::ENOENT
        raise BindgenError, "clang not found: #{@clang}"
      rescue JSON::ParserError => e
        raise BindgenError, "failed to parse clang AST JSON: #{e.message}"
      end

      def extract_top_level_header_nodes(ast)
        Array(ast["inner"]).select do |node|
          node.is_a?(Hash) && interesting_top_level_kind?(node["kind"]) && node_from_header?(node)
        end
      end

      def interesting_top_level_kind?(kind)
        %w[TypedefDecl RecordDecl EnumDecl VarDecl FunctionDecl].include?(kind)
      end

      def node_from_header?(node)
        files = location_files(node)
        files.include?(@header_path) || files.include?(@translation_unit_path)
      end

      def location_files(node)
        [
          node.dig("loc", "file"),
          node.dig("loc", "includedFrom", "file"),
          node.dig("loc", "spellingLoc", "file"),
          node.dig("range", "begin", "file"),
          node.dig("range", "end", "file"),
          node.dig("range", "begin", "spellingLoc", "file"),
          node.dig("range", "end", "spellingLoc", "file"),
        ].compact.uniq
      end

      def build_alias_maps(nodes)
        nodes.each do |node|
          next unless node["kind"] == "TypedefDecl"

          target = typedef_target(node)
          next unless target

          case target[:kind]
          when "RecordDecl"
            @record_aliases[target[:id]] = node["name"]
          when "EnumDecl"
            @enum_aliases[target[:id]] = node["name"]
          end
        end
      end

      def macro_probe_declarations
        macro_constant_candidates.map do |name|
          %(static const __typeof__(#{name}) #{macro_probe_name(name)} = #{name};)
        end
      end

      def macro_constant_candidates
        return @macro_constant_candidates if defined?(@macro_constant_candidates)

        definitions = {}
        each_macro_definition do |name, body|
          definitions[name] = body
        end

        @macro_constant_candidates = definitions.filter_map do |name, body|
          next unless macro_constant_candidate?(name, body)

          name
        end
      end

      def each_macro_definition
        logical_line = +""

        File.foreach(@header_path) do |line|
          current = line.delete_suffix("\n")
          if logical_line.empty?
            logical_line = current
          else
            logical_line << current.lstrip
          end

          if logical_line.end_with?("\\")
            logical_line = logical_line.delete_suffix("\\") + " "
            next
          end

          match = logical_line.match(/\A\s*#define\s+([A-Za-z_][A-Za-z0-9_]*)(.*)\z/)
          if match
            name = match[1]
            suffix = match[2]
            yield(name, suffix.strip) unless suffix.start_with?("(")
          end

          logical_line = +""
        end
      end

      def macro_constant_candidate?(name, body)
        return false unless name.match?(/\A[A-Z][A-Z0-9_]*\z/)

        normalized = normalize_macro_body(body)
        return false if normalized.empty?
        return false if normalized.include?('"') || normalized.include?("'")

        first_token = normalized[/\A[A-Za-z_][A-Za-z0-9_]*/]
        return false if first_token && NON_VALUE_MACRO_TOKENS.include?(first_token)

        normalized.match?(/\A[A-Za-z0-9_()+\-*\/%<>&|~^.,{}\[\]:?\s]+\z/)
      end

      def normalize_macro_body(body)
        body.gsub(%r{/\*.*?\*/}, " ").sub(%r{//.*\z}, "").strip
      end

      def macro_probe_name(name)
        "#{MACRO_CONST_PREFIX}#{name}"
      end

      def macro_probe_declaration?(node)
        node["name"].to_s.start_with?(MACRO_CONST_PREFIX)
      end

      def constant_name_for(node)
        name = node["name"].to_s
        macro_probe_declaration?(node) ? name.delete_prefix(MACRO_CONST_PREFIX) : name
      end

      def typedef_target(node)
        inner = Array(node["inner"]).find { |child| %w[RecordType EnumType].include?(child["kind"]) }
        decl = inner&.dig("decl")
        return unless decl

        { id: decl["id"], kind: decl["kind"], name: decl["name"] }
      end

      def select_record_declarations(nodes)
        selected = {}

        nodes.each_with_index do |node, index|
          next unless node["kind"] == "RecordDecl"
          next unless %w[struct union].include?(node["tagUsed"])

          visible_name = @record_aliases[node["id"]] || node["name"]
          next unless visible_name

          candidate = {
            index:,
            kind: node["completeDefinition"] ? node["tagUsed"] : "opaque",
            name: visible_name,
            node:,
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

      def select_enum_declarations(nodes)
        selected = {}

        nodes.each_with_index do |node, index|
          next unless node["kind"] == "EnumDecl"

          visible_name = @enum_aliases[node["id"]] || node["name"]
          next unless visible_name

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
        nodes.each_with_index.filter_map do |node, index|
          next unless node["kind"] == "TypedefDecl"
          next if typedef_target(node)

          mapped_type = function_pointer_type?(node.dig("type", "qualType")) ? map_function_pointer_typedef(node, context: node["name"]) : map_c_type(node.dig("type", "qualType"), context: node["name"])
          {
            index:,
            kind: "type_alias",
            name: node["name"],
            mapped_type:,
          }
        end
      end

      def select_function_declarations(nodes)
        nodes.each_with_index.filter_map do |node, index|
          next unless node["kind"] == "FunctionDecl"
          next if node["storageClass"] == "static"
          next if Array(node["inner"]).any? { |child| child["kind"] == "CompoundStmt" }
          next if node["variadic"]

          params = Array(node["inner"]).select { |child| child["kind"] == "ParmVarDecl" }.each_with_index.map do |param, param_index|
            {
              name: param["name"] || "arg#{param_index}",
              type: map_c_type(param.dig("type", "qualType"), context: "parameter #{param["name"] || param_index} of #{node["name"]}"),
            }
          end

          return_type = map_c_type(function_return_type(node), context: "return type of #{node["name"]}")
          {
            index:,
            kind: "function",
            name: node["name"],
            params:,
            return_type:,
          }
        end
      end

      def select_constant_declarations(nodes)
        nodes.each_with_index.filter_map do |node, index|
          next unless node["kind"] == "VarDecl"
          next unless constant_var_decl?(node)

          begin
            type = map_c_type(constant_qual_type(node), context: constant_name_for(node))
            initializer = Array(node["inner"]).first
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

      def constant_var_decl?(node)
        node["init"] && strip_qualifiers(normalize_c_type(node.dig("type", "qualType"))) != normalize_c_type(node.dig("type", "qualType"))
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
        qual_type = node.dig("type", "qualType")
        match = qual_type&.match(/\A(.+?)\s*\((?:.*)\)\z/)
        raise BindgenError, "unsupported function type for #{node["name"]}: #{qual_type.inspect}" unless match

        match[1]
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

      def emit_module(declarations)
        declarations = synthetic_declarations_for(declarations) + declarations

        lines = []
        lines << "# generated by mtc bindgen from #{@header_path}"
        lines << "extern module #{@module_name}:"

        directives = []
        @link_libraries.each do |library|
          directives << %(    link #{library.dump})
        end
        includes = @include_directives && !@include_directives.empty? ? @include_directives : [File.basename(@header_path)]
        includes.each do |include_name|
          directives << %(    include #{include_name.dump})
        end
        lines.concat(directives)

        declarations.each do |declaration|
          lines << ""
          lines.concat(emit_declaration(declaration))
        end

        lines.join("\n") + "\n"
      end

      def emit_declaration(declaration)
        case declaration[:kind]
        when "struct", "union"
          emit_aggregate_declaration(declaration[:kind], declaration[:name], declaration[:node])
        when "opaque"
          ["    opaque #{declaration[:name]}"]
        when "enum", "flags"
          emit_enum_declaration(declaration[:kind], declaration[:name], declaration[:node])
        when "type_alias"
          ["    type #{declaration[:name]} = #{declaration[:mapped_type]}"]
        when "const"
          ["    const #{declaration[:name]}: #{declaration[:type]} = #{declaration[:value]}"]
        when "function"
          emit_function_declaration(declaration)
        else
          raise BindgenError, "unsupported bindgen declaration kind #{declaration[:kind]}"
        end
      end

      def emit_aggregate_declaration(kind, name, node)
        lines = ["    #{kind} #{name}:"]
        fields = Array(node["inner"]).select { |child| child["kind"] == "FieldDecl" }
        fields.each do |field|
          field_type = map_c_type(field.dig("type", "qualType"), context: "field #{name}.#{field["name"]}")
          lines << "        #{field["name"]}: #{field_type}"
        end
        lines
      end

      def emit_enum_declaration(kind, name, node)
        members = enum_member_values(node)
        backing_type = if members.empty?
                         "i32"
                       else
                         map_c_type(members.first.dig(:node, "type", "qualType"), context: "enum #{name}")
                       end
        lines = ["    #{kind} #{name}: #{backing_type}"]
        members.each do |member|
          lines << "        #{member[:node]["name"]} = #{member[:value]}"
        end
        lines
      end

      def enum_member_values(node)
        next_value = 0

        Array(node["inner"]).filter_map do |child|
          next unless child["kind"] == "EnumConstantDecl"

          explicit_value = integer_value(child)
          value = explicit_value ? Integer(explicit_value, 10) : next_value
          next_value = value + 1
          { node: child, value: }
        end
      end

      def integer_value(node)
        constant = Array(node["inner"]).find { |child| child["kind"] == "ConstantExpr" }
        return constant["value"] if constant && constant.key?("value")

        literal = Array(node["inner"]).find { |child| child["kind"] == "IntegerLiteral" }
        literal&.[]("value")
      end

      def emit_function_declaration(declaration)
        params = declaration[:params].map { |param| "#{param[:name]}: #{param[:type]}" }.join(", ")
        ["    extern def #{declaration[:name]}(#{params}) -> #{declaration[:return_type]}"]
      end

      def lower_constant_expression(node, expected_type:, context:)
        raise BindgenError, "missing initializer for #{context}" unless node

        case node["kind"]
        when "IntegerLiteral"
          node.fetch("value")
        when "FloatingLiteral"
          emit_float_value(node.fetch("value"), expected_type)
        when "StringLiteral"
          %(c#{node.fetch("value")})
        when "ImplicitCastExpr", "ConstantExpr", "CompoundLiteralExpr", "ParenExpr"
          child = Array(node["inner"]).first
          lower_constant_expression(child, expected_type:, context:)
        when "UnaryOperator"
          operator = node["opcode"]
          operand = lower_constant_expression(Array(node["inner"]).first, expected_type:, context:)
          "#{operator}#{operand}"
        when "InitListExpr"
          lower_init_list_expression(node, expected_type:, context:)
        else
          raise BindgenError, "unsupported constant initializer #{node["kind"]} for #{context}"
        end
      end

      def lower_init_list_expression(node, expected_type:, context:)
        aggregate = @aggregate_declarations[expected_type]
        raise BindgenError, "unsupported aggregate constant type #{expected_type} for #{context}" unless aggregate

        fields = Array(aggregate["inner"]).select { |child| child["kind"] == "FieldDecl" }
        values = Array(node["inner"])
        raise BindgenError, "initializer field count mismatch for #{context}" unless fields.length == values.length

        arguments = fields.zip(values).map do |field, value|
          field_type = map_c_type(field.dig("type", "qualType"), context: "field #{expected_type}.#{field["name"]}")
          lowered = lower_constant_expression(value, expected_type: field_type, context: "field #{field["name"]} of #{context}")
          "#{field["name"]} = #{lowered}"
        end
        "#{expected_type}(#{arguments.join(', ')})"
      end

      def emit_float_value(value, expected_type)
        literal = value.include?(".") ? value : "#{value}.0"
        expected_type == "f32" ? "#{literal}" : literal
      end

      def map_c_type(qual_type, context:)
        normalized = normalize_c_type(qual_type)
        raise BindgenError, "missing C type for #{context}" if normalized.empty?
        return map_array_type(normalized, context:) if array_type?(normalized)
        return map_function_pointer_type(normalized, context:) if function_pointer_type?(normalized)

        if pointer_type?(normalized)
          return "cstr" if c_string_pointer?(normalized)

          pointee = normalized.sub(/\s*\*\z/, "")
          return "ptr[#{map_c_type(pointee, context:)}]"
        end

        unqualified = strip_qualifiers(normalized)
        return PRIMITIVE_TYPE_MAP.fetch(unqualified) if PRIMITIVE_TYPE_MAP.key?(unqualified)
        return map_long_type(unqualified, context:) if unqualified.start_with?("long") || unqualified.start_with?("unsigned long") || unqualified.start_with?("signed long")
        return record_name_for(unqualified) if unqualified.start_with?("struct ")
        return record_name_for(unqualified) if unqualified.start_with?("union ")
        return enum_name_for(unqualified) if unqualified.start_with?("enum ")
        return unqualified if unqualified.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)

        raise BindgenError, "unsupported C type #{qual_type.inspect} for #{context}"
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

      def function_pointer_type?(qual_type)
        qual_type.match?(/\A.+\(\s*\*\s*\)\s*\(.*\)\z/)
      end

      def map_function_pointer_typedef(node, context:)
        function_proto = extract_function_proto(node)
        raise BindgenError, "unsupported function pointer type #{node.dig("type", "qualType").inspect} for #{context}" unless function_proto

        inner_types = Array(function_proto["inner"])
        raise BindgenError, "unsupported function pointer type #{node.dig("type", "qualType").inspect} for #{context}" if inner_types.empty?

        return_type = map_type_node(inner_types.first, context: "return type of #{context}")
        param_types = inner_types.drop(1)
        params = if param_types.empty? || (param_types.length == 1 && void_type_node?(param_types.first))
                   []
                 else
                   param_types.each_with_index.map do |param_type, index|
                     "arg#{index}: #{map_type_node(param_type, context: "parameter #{index} of #{context}")}"
                   end
                 end
        "fn(#{params.join(', ')}) -> #{return_type}"
      end

      def map_function_pointer_type(qual_type, context:)
        match = qual_type.match(/\A(.+?)\s*\(\s*\*\s*\)\s*\((.*)\)\z/)
        raise BindgenError, "unsupported function pointer type #{qual_type.inspect} for #{context}" unless match

        return_type = map_c_type(match[1], context: "return type of #{context}")
        param_list = split_top_level_csv(match[2])
        params = if param_list.empty? || (param_list.length == 1 && strip_qualifiers(param_list.first) == "void")
                   []
                 else
                   param_list.each_with_index.map do |param_type, index|
                     "arg#{index}: #{map_c_type(param_type, context: "parameter #{index} of #{context}")}"
                   end
                 end
        "fn(#{params.join(', ')}) -> #{return_type}"
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
        if alias_name
          synthesize_typedef_dependency(alias_name)
          return alias_name
        end

        map_c_type(node.dig("type", "qualType"), context:)
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
        return unless name == "va_list"
        return if @synthetic_declarations.any? { |declaration| declaration[:name] == "va_list" }

        @synthetic_declarations << { kind: "opaque", name: "__va_list_tag" }
        @synthetic_declarations << { kind: "type_alias", name: "va_list", mapped_type: "array[__va_list_tag, 1]" }
      end

      def synthetic_declarations_for(declarations)
        existing_names = declarations.filter_map { |declaration| declaration[:name] }.to_h { |name| [name, true] }
        @synthetic_declarations.reject { |declaration| existing_names.key?(declaration[:name]) }
      end

      def normalize_c_type(qual_type)
        qual_type.to_s.gsub(/\s+/, " ").strip
      end

      def pointer_type?(qual_type)
        qual_type.end_with?("*")
      end

      def c_string_pointer?(qual_type)
        pointee = qual_type.sub(/\s*\*\z/, "")
        unqualified = strip_qualifiers(pointee)
        unqualified == "char" && pointee.split.include?("const")
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
        mapping = signed ? { 4 => "i32", 8 => "i64" } : { 4 => "u32", 8 => "u64" }
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
        tag_name = unqualified.split.last
        @record_visible_names[tag_name] || tag_name
      end

      def enum_name_for(unqualified)
        tag_name = unqualified.split.last
        @enum_visible_names[tag_name] || tag_name
      end
    end
  end

  class BindgenError < StandardError; end
end

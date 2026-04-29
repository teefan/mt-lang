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
      "long" => "isize",
      "long int" => "isize",
      "signed long" => "isize",
      "signed long int" => "isize",
      "unsigned long" => "usize",
      "unsigned long int" => "usize",
      "long long" => "i64",
      "long long int" => "i64",
      "signed long long" => "i64",
      "signed long long int" => "i64",
      "unsigned long long" => "u64",
      "unsigned long long int" => "u64",
      "float" => "f32",
      "double" => "f64",
    }.freeze

    def self.generate(module_name:, header_path:, tracked_header_paths: [], tracked_header_prefixes: [], declaration_name_prefixes: [], link_libraries: [], include_directives: nil, bindgen_defines: [], bindgen_include_directives: [], module_imports: [], clang: ENV.fetch("CLANG", "clang"), clang_args: [], type_overrides: {}, function_param_type_overrides: {}, function_return_type_overrides: {}, field_type_overrides: {})
      Generator.new(
        module_name:,
        header_path:,
        tracked_header_paths:,
        tracked_header_prefixes:,
        declaration_name_prefixes:,
        link_libraries:,
        include_directives:,
        bindgen_defines:,
        bindgen_include_directives:,
        module_imports:,
        clang:,
        clang_args:,
        type_overrides:,
        function_param_type_overrides:,
        function_return_type_overrides:,
        field_type_overrides:,
      ).generate
    end

    class Generator
      def initialize(module_name:, header_path:, tracked_header_paths:, tracked_header_prefixes:, declaration_name_prefixes:, link_libraries:, include_directives:, bindgen_defines:, bindgen_include_directives:, module_imports:, clang:, clang_args:, type_overrides:, function_param_type_overrides:, function_return_type_overrides:, field_type_overrides:)
        @module_name = module_name
        @header_path = File.expand_path(header_path)
        @tracked_header_paths = ([header_path] + tracked_header_paths).map { |path| File.expand_path(path) }.uniq.freeze
        @tracked_header_prefixes = tracked_header_prefixes.map { |path| File.expand_path(path) }.uniq.freeze
        @declaration_name_prefixes = declaration_name_prefixes.dup.freeze
        @link_libraries = link_libraries.dup
        @include_directives = include_directives&.dup
        @bindgen_defines = bindgen_defines.dup.freeze
        @bindgen_include_directives = bindgen_include_directives.dup.freeze
        @module_imports = normalize_module_imports(module_imports)
        @clang = clang
        @clang_args = clang_args.dup
        @type_overrides = normalize_type_overrides(type_overrides)
        @function_param_type_overrides = normalize_function_param_type_overrides(function_param_type_overrides)
        @function_return_type_overrides = normalize_function_return_type_overrides(function_return_type_overrides)
        @field_type_overrides = normalize_field_type_overrides(field_type_overrides)
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
        @visible_typedef_names = top_level_nodes.filter_map do |node|
          node["name"] if node["kind"] == "TypedefDecl" && allowed_declaration_name?(node["name"])
        end
        build_alias_maps(top_level_nodes)

        declarations = []
        declarations.concat(select_record_declarations(top_level_nodes))
        validate_field_type_overrides!(declarations)
        discover_synthetic_aggregate_dependencies(declarations)
        declarations.concat(select_enum_declarations(top_level_nodes))
        declarations.concat(select_type_alias_declarations(top_level_nodes))
        declarations.concat(select_constant_declarations(top_level_nodes))
        function_declarations = select_function_declarations(top_level_nodes)
        validate_function_param_type_overrides!(function_declarations)
        validate_function_return_type_overrides!(function_declarations)
        declarations.concat(function_declarations)
        declarations.sort_by! { |declaration| declaration[:index] }

        emit_module(declarations)
      end

      private

      def dump_ast
        Tempfile.create(["milk-tea-bindgen", ".c"]) do |translation_unit|
          @translation_unit_path = translation_unit.path
          write_translation_unit_prelude(translation_unit)
          translation_unit.flush
          @active_macro_names = preprocessed_macro_names(translation_unit.path)
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
          begin
            return JSON.parse(stdout)
          rescue JSON::ParserError
            details = [stdout, stderr].reject(&:empty?).join
            raise BindgenError, details.empty? ? "clang bindgen failed" : "clang bindgen failed:\n#{details}" unless status.success?

            raise
          end
        end
      rescue Errno::ENOENT
        raise BindgenError, "clang not found: #{@clang}"
      rescue JSON::ParserError => e
        raise BindgenError, "failed to parse clang AST JSON: #{e.message}"
      end

      def write_translation_unit_prelude(translation_unit)
        @bindgen_defines.each do |define|
          name, value = define.split("=", 2)
          if value.nil?
            translation_unit.write("#define #{name}\n")
          else
            translation_unit.write("#define #{name} #{value}\n")
          end
        end

        translation_unit.write(%(#include #{@header_path.dump}\n))
        @bindgen_include_directives.each do |directive|
          translation_unit.write(%(#include #{directive.dump}\n))
        end
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
        source_files = node_source_files(node).map { |path| File.expand_path(path) }
        return true if source_files.include?(@translation_unit_path)
        return true if source_files.any? { |path| tracked_header_path?(path) }

        return false unless source_files.empty?

        include_files = node_include_files(node).map { |path| File.expand_path(path) }
        return true if include_files.include?(@translation_unit_path)

        include_files.any? { |path| tracked_header_path?(path) }
      end

      def tracked_header_path?(path)
        return true if @tracked_header_paths.include?(path)

        @tracked_header_prefixes.any? do |prefix|
          path == prefix || path.start_with?(prefix + File::SEPARATOR)
        end
      end

      def allowed_declaration_name?(name)
        return true if @declaration_name_prefixes.empty?
        return false unless name

        @declaration_name_prefixes.any? { |prefix| name.start_with?(prefix) }
      end

      def node_source_files(node)
        [
          node.dig("loc", "file"),
          node.dig("loc", "spellingLoc", "file"),
          node.dig("loc", "expansionLoc", "file"),
          node.dig("range", "begin", "file"),
          node.dig("range", "end", "file"),
          node.dig("range", "begin", "spellingLoc", "file"),
          node.dig("range", "begin", "expansionLoc", "file"),
          node.dig("range", "end", "spellingLoc", "file"),
          node.dig("range", "end", "expansionLoc", "file"),
        ].compact.uniq
      end

      def node_include_files(node)
        [
          node.dig("loc", "includedFrom", "file"),
          node.dig("loc", "spellingLoc", "includedFrom", "file"),
          node.dig("range", "begin", "includedFrom", "file"),
          node.dig("range", "end", "includedFrom", "file"),
          node.dig("range", "begin", "spellingLoc", "includedFrom", "file"),
          node.dig("range", "end", "spellingLoc", "includedFrom", "file"),
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
        current_file = nil

        preprocessed_macro_source.each_line do |line|
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

          line_marker = logical_line.match(/\A#\s+\d+\s+"([^"]+)"/)
          if line_marker
            current_file = normalize_preprocessor_path(line_marker[1])
            logical_line = +""
            next
          end

          match = logical_line.match(/\A\s*#define\s+([A-Za-z_][A-Za-z0-9_]*)(.*)\z/)
          if match && current_file && tracked_header_path?(current_file)
            name = match[1]
            suffix = match[2]
            yield(name, suffix.strip) unless suffix.start_with?("(")
          end

          logical_line = +""
        end
      end

      def macro_constant_candidate?(name, body)
        return false unless name.match?(/\A[A-Z][A-Z0-9_]*\z/)
        return false unless allowed_declaration_name?(name)
        return false unless active_macro_name?(name)

        normalized = normalize_macro_body(body)
        return false if normalized.empty?
        return false if normalized.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
        return false if normalized.include?('"') || normalized.include?("'")
        return false if contains_disallowed_macro_call?(normalized)

        first_token = normalized[/\A[A-Za-z_][A-Za-z0-9_]*/]
        return false if first_token && NON_VALUE_MACRO_TOKENS.include?(first_token)

        normalized.match?(/\A[A-Za-z0-9_()+\-*\/%<>&|~^.,{}\[\]:?\s]+\z/)
      end

      def active_macro_name?(name)
        @active_macro_names.include?(name)
      end

      def preprocessed_macro_names(translation_unit_path)
        command = [
          @clang,
          "-x",
          "c",
          "-fno-builtin",
          *@clang_args,
          "-dM",
          "-E",
          translation_unit_path,
        ]
        stdout, stderr, status = Open3.capture3(*command)
        unless status.success?
          details = [stdout, stderr].reject(&:empty?).join
          raise BindgenError, details.empty? ? "clang bindgen macro probe failed" : "clang bindgen macro probe failed:\n#{details}"
        end

        stdout.each_line.filter_map do |line|
          match = line.match(/\A#define\s+([A-Za-z_][A-Za-z0-9_]*)\b/)
          match[1] if match
        end.to_set
      end

      def contains_disallowed_macro_call?(source)
        index = 0

        while index < source.length
          match = source.match(/\b[A-Za-z_][A-Za-z0-9_]*\s*\(/, index)
          return false unless match

          callee = match[0][/\A[A-Za-z_][A-Za-z0-9_]*/]
          open_index = match[0].rindex("(") + match.begin(0)
          close_index = matching_paren_index(source, open_index)
          return true unless close_index

          return true unless callee&.match?(/\A[A-Z][A-Z0-9_]*\z/)

          index = close_index + 1
        end

        false
      end

      def matching_paren_index(source, open_index)
        depth = 0
        index = open_index

        while index < source.length
          case source[index]
          when "("
            depth += 1
          when ")"
            depth -= 1
            return index if depth.zero?
          end

          index += 1
        end

        nil
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
          next unless allowed_declaration_name?(visible_name)

          candidate = {
            index:,
            kind: node["completeDefinition"] ? node["tagUsed"] : "opaque",
            name: visible_name,
            c_name: opaque_c_name(node),
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
          next unless allowed_declaration_name?(visible_name)

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
          mapped_type = if function_pointer_type?(qual_type)
                          map_function_pointer_typedef(node, context: node["name"])
                        else
                          map_c_type(qual_type, context: node["name"])
                        end
          next if unresolved_alias_target?(mapped_type, alias_names)

          {
            index:,
            kind: "type_alias",
            name: node["name"],
            mapped_type:,
          }
        rescue BindgenError
          nil
        end

      end

      private

      def preprocessed_macro_source
        command = [
          @clang,
          "-x",
          "c",
          "-fno-builtin",
          *@clang_args,
          "-E",
          "-dD",
          @translation_unit_path,
        ]
        stdout, stderr, status = Open3.capture3(*command)
        unless status.success?
          details = [stdout, stderr].reject(&:empty?).join
          raise BindgenError, details.empty? ? "clang bindgen macro dump failed" : "clang bindgen macro dump failed:\n#{details}"
        end

        stdout
      end

      def normalize_preprocessor_path(path)
        return nil if path.start_with?("<") && path.end_with?(">")

        File.expand_path(path)
      end

      def alias_qual_type(node)
        type_qual_type(node)
      end

      def select_function_declarations(nodes)
        selected = {}

        nodes.each_with_index do |node, index|
          next unless node["kind"] == "FunctionDecl"
          next if node["storageClass"] == "static"
          next if Array(node["inner"]).any? { |child| child["kind"] == "CompoundStmt" }
          next unless allowed_declaration_name?(node["name"])

          params = Array(node["inner"]).select { |child| child["kind"] == "ParmVarDecl" }.each_with_index.map do |param, param_index|
            param_name = param["name"] || "arg#{param_index}"
            {
              name: param_name,
              type: function_param_type_override(node["name"], param_name) || map_type_node(param, context: "parameter #{param_name} of #{node["name"]}"),
            }
          end

          return_type = function_return_type_override(node["name"]) || map_c_type(function_return_type(node), context: "return type of #{node["name"]}")
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
        node.dig("type", "desugaredQualType") || node.dig("type", "qualType")
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

        @module_imports.each do |import|
          lines << %(    import #{import.fetch(:module_name)} as #{import.fetch(:alias)})
        end

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
          line = "    opaque #{declaration[:name]}"
          line += " = c#{declaration[:c_name].inspect}" if declaration[:c_name]
          [line]
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
          field_type = aggregate_field_type(field, owner_name: name, aggregate_node: node)
          lines << "        #{field["name"]}: #{field_type}"
        end
        lines
      end

      def discover_synthetic_aggregate_dependencies(declarations)
        pending = declarations.select { |declaration| %w[struct union].include?(declaration[:kind]) }.map do |declaration|
          [declaration[:name], declaration[:node]]
        end
        seen = {}

        until pending.empty?
          owner_name, aggregate_node = pending.shift
          key = [owner_name, aggregate_node["id"]]
          next if seen[key]

          seen[key] = true

          Array(aggregate_node["inner"]).select { |child| child["kind"] == "FieldDecl" }.each do |field|
            anonymous_record = anonymous_record_decl_for_field(field, aggregate_node)
            next unless anonymous_record

            synthetic_name = "#{owner_name}_#{field["name"]}"
            unless @synthetic_declarations.any? { |declaration| declaration[:name] == synthetic_name }
              @synthetic_declarations << { kind: anonymous_record.fetch("tagUsed"), name: synthetic_name, node: anonymous_record }
              @aggregate_declarations[synthetic_name] = anonymous_record
            end

            pending << [synthetic_name, anonymous_record]
          end
        end
      end

      def aggregate_field_type(field, owner_name:, aggregate_node:)
        override = field_type_override(owner_name, field["name"])
        return override if override

        anonymous_record = anonymous_record_decl_for_field(field, aggregate_node)
        return "#{owner_name}_#{field["name"]}" if anonymous_record

        map_type_node(field, context: "field #{owner_name}.#{field["name"]}")
      end

      def anonymous_record_decl_for_field(field, aggregate_node)
        qual_type = type_qual_type(field)
        return unless qual_type&.match?(/\A(?:struct|union) \(unnamed at /)

        field_begin = source_location_key(field.dig("range", "begin"))
        return unless field_begin

        expected_tag = qual_type.split.first
        Array(aggregate_node["inner"]).find do |child|
          next false unless child["kind"] == "RecordDecl"
          next false unless child["tagUsed"] == expected_tag

          source_location_key(child["loc"]) == field_begin
        end
      end

      def source_location_key(location)
        return unless location

        [
          location["offset"],
          location["line"],
          location["col"],
          location.dig("includedFrom", "file"),
          location["file"],
        ]
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
        params = declaration[:params].map { |param| "#{param[:name]}: #{param[:type]}" }
        params << "..." if declaration[:variadic]
        ["    extern def #{declaration[:name]}(#{params.join(', ')}) -> #{declaration[:return_type]}"]
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
          field_type = map_type_node(field, context: "field #{expected_type}.#{field["name"]}")
          lowered = lower_constant_expression(value, expected_type: field_type, context: "field #{field["name"]} of #{context}")
          "#{field["name"]} = #{lowered}"
        end
        "#{expected_type}(#{arguments.join(', ')})"
      end

      def emit_float_value(value, expected_type)
        literal = value.match?(/[.eE]/) ? value : "#{value}.0"
        expected_type == "f32" ? literal : literal
      end

      def function_param_type_override(function_name, param_name)
        @function_param_type_overrides.dig(function_name, param_name)
      end

      def function_return_type_override(function_name)
        @function_return_type_overrides[function_name]
      end

      def field_type_override(type_name, field_name)
        @field_type_overrides.dig(type_name, field_name)
      end

      def normalize_function_param_type_overrides(overrides)
        return {} if overrides.nil?

        raise BindgenError, "function_param_type_overrides must be a hash" unless overrides.is_a?(Hash)

        overrides.each_with_object({}) do |(function_name, param_overrides), normalized|
          unless function_name.is_a?(String) || function_name.is_a?(Symbol)
            raise BindgenError, "function_param_type_overrides function names must be strings or symbols"
          end

          raise BindgenError, "function_param_type_overrides for #{function_name} must be a hash" unless param_overrides.is_a?(Hash)

          normalized[function_name.to_s] = param_overrides.each_with_object({}) do |(param_name, type), params|
            unless param_name.is_a?(String) || param_name.is_a?(Symbol)
              raise BindgenError, "function_param_type_overrides parameter names must be strings or symbols"
            end

            raise BindgenError, "function_param_type_overrides for #{function_name}.#{param_name} must be a non-empty string" unless type.is_a?(String) && !type.empty?

            params[param_name.to_s] = type
          end.freeze
        end.freeze
      end

      def normalize_field_type_overrides(overrides)
        return {} if overrides.nil?

        raise BindgenError, "field_type_overrides must be a hash" unless overrides.is_a?(Hash)

        overrides.each_with_object({}) do |(type_name, field_overrides), normalized|
          unless type_name.is_a?(String) || type_name.is_a?(Symbol)
            raise BindgenError, "field_type_overrides type names must be strings or symbols"
          end

          raise BindgenError, "field_type_overrides for #{type_name} must be a hash" unless field_overrides.is_a?(Hash)

          normalized[type_name.to_s] = field_overrides.each_with_object({}) do |(field_name, type), fields|
            unless field_name.is_a?(String) || field_name.is_a?(Symbol)
              raise BindgenError, "field_type_overrides field names must be strings or symbols"
            end

            raise BindgenError, "field_type_overrides for #{type_name}.#{field_name} must be a non-empty string" unless type.is_a?(String) && !type.empty?

            fields[field_name.to_s] = type
          end.freeze
        end.freeze
      end

      def normalize_module_imports(imports)
        return [] if imports.nil?
        raise BindgenError, "module_imports must be an array" unless imports.is_a?(Array)

        imports.map do |entry|
          raise BindgenError, "module_imports entries must be hashes" unless entry.is_a?(Hash)

          module_name = entry.fetch(:module_name) { entry.fetch("module_name", nil) }
          import_alias = entry.fetch(:alias) { entry.fetch("alias", nil) }
          raise BindgenError, "module_imports module_name must be a non-empty string" unless module_name.is_a?(String) && !module_name.empty?
          raise BindgenError, "module_imports alias must be a non-empty string" unless import_alias.is_a?(String) && !import_alias.empty?

          { module_name:, alias: import_alias }
        end.freeze
      end

      def normalize_type_overrides(overrides)
        return {} if overrides.nil?
        raise BindgenError, "type_overrides must be a hash" unless overrides.is_a?(Hash)

        overrides.each_with_object({}) do |(type_name, mapped_type), normalized|
          unless type_name.is_a?(String) || type_name.is_a?(Symbol)
            raise BindgenError, "type_overrides type names must be strings or symbols"
          end

          raise BindgenError, "type_overrides for #{type_name} must be a non-empty string" unless mapped_type.is_a?(String) && !mapped_type.empty?

          normalized[type_name.to_s] = mapped_type
        end.freeze
      end

      def normalize_function_return_type_overrides(overrides)
        return {} if overrides.nil?

        raise BindgenError, "function_return_type_overrides must be a hash" unless overrides.is_a?(Hash)

        overrides.each_with_object({}) do |(function_name, type), normalized|
          unless function_name.is_a?(String) || function_name.is_a?(Symbol)
            raise BindgenError, "function_return_type_overrides function names must be strings or symbols"
          end

          raise BindgenError, "function_return_type_overrides for #{function_name} must be a non-empty string" unless type.is_a?(String) && !type.empty?

          normalized[function_name.to_s] = type
        end.freeze
      end

      def map_c_type(qual_type, context:)
        normalized = normalize_c_type(qual_type)
        raise BindgenError, "missing C type for #{context}" if normalized.empty?
        return map_array_type(normalized, context:) if array_type?(normalized)
        return map_function_pointer_type(normalized, context:) if function_pointer_type?(normalized)

        pointer_candidate = strip_pointer_suffix_qualifiers(normalized)
        if pointer_type?(pointer_candidate)
          if va_list_pointer?(pointer_candidate)
            synthesize_typedef_dependency("va_list")
            return "va_list"
          end

          return "cstr" if c_string_pointer?(pointer_candidate)

          pointee = pointer_candidate.sub(/\s*\*\z/, "")
          pointer_name = top_level_const_qualified?(pointee) ? "const_ptr" : "ptr"
          return "#{pointer_name}[#{map_c_type(pointee, context:)}]"
        end

        unqualified = strip_qualifiers(normalized)
        if unqualified == "__va_list_tag" || unqualified == "struct __va_list_tag"
          synthesize_typedef_dependency("__va_list_tag")
          return "__va_list_tag"
        end
        return standard_typedef_primitive(unqualified) if standard_typedef_primitive(unqualified)
        return PRIMITIVE_TYPE_MAP.fetch(unqualified) if PRIMITIVE_TYPE_MAP.key?(unqualified)
        return @type_overrides.fetch(unqualified) if @type_overrides.key?(unqualified)
        return map_long_type(unqualified, context:) if unqualified.start_with?("long") || unqualified.start_with?("unsigned long") || unqualified.start_with?("signed long")
        if unqualified.start_with?("struct ") || unqualified.start_with?("union ") || unqualified.start_with?("enum ")
          tag_name = unqualified.split.last
          return @type_overrides.fetch(tag_name) if @type_overrides.key?(tag_name)
        end
        return record_name_for(unqualified) if unqualified.start_with?("struct ")
        return record_name_for(unqualified) if unqualified.start_with?("union ")
        return enum_name_for(unqualified) if unqualified.start_with?("enum ")
        if unqualified.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
          return unqualified if known_generated_type_name?(unqualified, @visible_typedef_names)

          raise BindgenError, "unknown referenced C type #{unqualified.inspect} for #{context}"
        end

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

      def va_list_pointer?(qual_type)
        stripped = strip_qualifiers(qual_type)
        stripped == "struct __va_list_tag *" || stripped == "__va_list_tag *"
      end

      def function_pointer_type?(qual_type)
        qual_type.match?(/\A.+\(\s*\*\s*\)\s*\(.*\)\z/)
      end

      def map_function_pointer_typedef(node, context:)
        function_proto = extract_function_proto(node)
        raise BindgenError, "unsupported function pointer type #{node.dig("type", "qualType").inspect} for #{context}" unless function_proto

        map_function_proto_node(function_proto, context:)
      end

      def map_function_proto_node(function_proto, context:)
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
        return @type_overrides.fetch(alias_name) if alias_name && @type_overrides.key?(alias_name)

        if alias_name && preserve_typedef_name?(alias_name)
          synthesize_typedef_dependency(alias_name)
          return alias_name
        end

        qual_type = type_qual_type(node)
        if function_pointer_type?(qual_type)
          function_proto = extract_function_proto(node)
          return map_function_proto_node(function_proto, context:) if function_proto
        end

        map_c_type(qual_type, context:)
      end

      def preserve_typedef_name?(name)
        name == "va_list" || @visible_typedef_names.include?(name)
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

      def opaque_c_name(node)
        typedef_name = @record_aliases[node["id"]]
        return typedef_name if typedef_name

        "#{node["tagUsed"]} #{node["name"]}"
      end

      def synthetic_declarations_for(declarations)
        existing_names = declarations.filter_map { |declaration| declaration[:name] }.to_h { |name| [name, true] }
        @synthetic_declarations.reject { |declaration| existing_names.key?(declaration[:name]) }
      end

      def normalize_c_type(qual_type)
        qual_type.to_s.gsub(/\s+/, " ").strip
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
        return "usize" if unqualified == "size_t"
        return "isize" if unqualified == "ssize_t" || unqualified == "ptrdiff_t"
        return "i32" if unqualified == "wchar_t"

        integer_typedef_primitive(unqualified)
      end

      def integer_typedef_primitive(unqualified)
        match = unqualified.match(/\A(?:__)?(u_?)?int(8|16|32|64)_t\z/)
        return unless match

        signed_prefix = match[1]
        width = match[2]
        signed_prefix ? "u#{width}" : "i#{width}"
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

      def normalize_module_imports(imports)
        return [] if imports.nil?
        raise BindgenError, "module_imports must be an array" unless imports.is_a?(Array)

        imports.map do |entry|
          raise BindgenError, "module_imports entries must be hashes" unless entry.is_a?(Hash)

          module_name = entry.fetch(:module_name) { entry.fetch("module_name", nil) }
          import_alias = entry.fetch(:alias) { entry.fetch("alias", nil) }
          raise BindgenError, "module_imports module_name must be a non-empty string" unless module_name.is_a?(String) && !module_name.empty?
          raise BindgenError, "module_imports alias must be a non-empty string" unless import_alias.is_a?(String) && !import_alias.empty?

          { module_name:, alias: import_alias }
        end.freeze
      end

      def normalize_type_overrides(overrides)
        return {} if overrides.nil?

        raise BindgenError, "type_overrides must be a hash" unless overrides.is_a?(Hash)

        overrides.each_with_object({}) do |(type_name, mapped_type), normalized|
          unless type_name.is_a?(String) || type_name.is_a?(Symbol)
            raise BindgenError, "type_overrides type names must be strings or symbols"
          end

          raise BindgenError, "type_overrides for #{type_name} must be a non-empty string" unless mapped_type.is_a?(String) && !mapped_type.empty?

          normalized[type_name.to_s] = mapped_type
        end.freeze
      end

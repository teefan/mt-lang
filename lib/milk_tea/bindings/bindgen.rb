# frozen_string_literal: true

require "json"
require "open3"
require "tempfile"
require_relative "../core/token"
require_relative "../core/types"
require_relative "../tooling/formatter"

module MilkTea
  module Bindgen
    MACRO_CONST_PREFIX = "__mt_bindgen_macro_"
    QUALIFIERS = %w[const volatile restrict].freeze
    NULLABILITY_QUALIFIERS = %w[_Nullable _Nonnull _Null_unspecified _Nullable_result].freeze
    NON_VALUE_MACRO_TOKENS = %w[
      extern static inline typedef struct union enum do if else for while return sizeof
      __attribute__ __attribute __declspec
    ].freeze
    PRIMITIVE_TYPE_MAP = {
      "_Bool" => "bool",
      "bool" => "bool",
      "void" => "void",
      "char" => "char",
      "signed char" => "byte",
      "unsigned char" => "ubyte",
      "short" => "short",
      "short int" => "short",
      "signed short" => "short",
      "signed short int" => "short",
      "unsigned short" => "ushort",
      "unsigned short int" => "ushort",
      "int" => "int",
      "signed" => "int",
      "signed int" => "int",
      "unsigned" => "uint",
      "unsigned int" => "uint",
      "long" => "ptr_int",
      "long int" => "ptr_int",
      "signed long" => "ptr_int",
      "signed long int" => "ptr_int",
      "unsigned long" => "ptr_uint",
      "unsigned long int" => "ptr_uint",
      "long long" => "long",
      "long long int" => "long",
      "signed long long" => "long",
      "signed long long int" => "long",
      "unsigned long long" => "ulong",
      "unsigned long long int" => "ulong",
      "float" => "float",
      "double" => "double",
    }.freeze

    def self.generate(module_name:, header_path:, tracked_header_paths: [], tracked_header_prefixes: [], declaration_name_prefixes: [], excluded_declaration_names: [], link_libraries: [], include_directives: nil, bindgen_defines: [], bindgen_include_directives: [], module_imports: [], clang: ENV.fetch("CLANG", "clang"), clang_args: [], type_name_overrides: {}, type_overrides: {}, function_param_type_overrides: {}, function_return_type_overrides: {}, field_type_overrides: {}, allow_static_inline_functions: false)
      generate_with_report(
        module_name:,
        header_path:,
        tracked_header_paths:,
        tracked_header_prefixes:,
        declaration_name_prefixes:,
        excluded_declaration_names:,
        link_libraries:,
        include_directives:,
        bindgen_defines:,
        bindgen_include_directives:,
        module_imports:,
        clang:,
        clang_args:,
        type_name_overrides:,
        type_overrides:,
        function_param_type_overrides:,
        function_return_type_overrides:,
        field_type_overrides:,
        allow_static_inline_functions:,
      ).fetch(:source)
    end

    def self.generate_with_report(module_name:, header_path:, tracked_header_paths: [], tracked_header_prefixes: [], declaration_name_prefixes: [], excluded_declaration_names: [], link_libraries: [], include_directives: nil, bindgen_defines: [], bindgen_include_directives: [], module_imports: [], clang: ENV.fetch("CLANG", "clang"), clang_args: [], type_name_overrides: {}, type_overrides: {}, function_param_type_overrides: {}, function_return_type_overrides: {}, field_type_overrides: {}, allow_static_inline_functions: false)
      Generator.new(
        module_name:,
        header_path:,
        tracked_header_paths:,
        tracked_header_prefixes:,
        declaration_name_prefixes:,
        excluded_declaration_names:,
        link_libraries:,
        include_directives:,
        bindgen_defines:,
        bindgen_include_directives:,
        module_imports:,
        clang:,
        clang_args:,
        type_name_overrides:,
        type_overrides:,
        function_param_type_overrides:,
        function_return_type_overrides:,
        field_type_overrides:,
        allow_static_inline_functions:,
      ).generate_with_report
    end

    class Generator
      def initialize(module_name:, header_path:, tracked_header_paths:, tracked_header_prefixes:, declaration_name_prefixes:, excluded_declaration_names:, link_libraries:, include_directives:, bindgen_defines:, bindgen_include_directives:, module_imports:, clang:, clang_args:, type_name_overrides:, type_overrides:, function_param_type_overrides:, function_return_type_overrides:, field_type_overrides:, allow_static_inline_functions:)
        @module_name = module_name
        @header_path = File.expand_path(header_path)
        @tracked_header_paths = ([header_path] + tracked_header_paths).map { |path| File.expand_path(path) }.uniq.freeze
        @tracked_header_prefixes = tracked_header_prefixes.map { |path| File.expand_path(path) }.uniq.freeze
        @declaration_name_prefixes = declaration_name_prefixes.dup.freeze
        @excluded_declaration_names = excluded_declaration_names.map(&:to_s).freeze
        @link_libraries = link_libraries.dup
        @include_directives = include_directives&.dup
        @bindgen_defines = bindgen_defines.dup.freeze
        @bindgen_include_directives = bindgen_include_directives.dup.freeze
        @module_imports = normalize_module_imports(module_imports)
        @clang = clang
        @clang_args = clang_args.dup
        @type_name_overrides = normalize_type_name_overrides(type_name_overrides)
        @type_overrides = normalize_type_overrides(type_overrides)
        @function_param_type_overrides = normalize_function_param_type_overrides(function_param_type_overrides)
        @function_return_type_overrides = normalize_function_return_type_overrides(function_return_type_overrides)
        @field_type_overrides = normalize_field_type_overrides(field_type_overrides)
        @allow_static_inline_functions = allow_static_inline_functions
        @record_aliases = {}
        @record_aliases_by_tag_name = {}
        @enum_aliases = {}
        @record_visible_names = {}
        @enum_visible_names = {}
        @referenceable_record_declarations = {}
        @referenceable_record_declarations_by_id = {}
        @aggregate_declarations = {}
        @synthetic_declarations = []
        @manual_nullable_param_overrides = []
        @manual_nullable_return_overrides = []
      end

      def generate
        ast = dump_ast
        index_referenceable_record_declarations(ast)
        top_level_nodes = extract_top_level_header_nodes(ast)
        @visible_typedef_names = top_level_nodes.filter_map do |node|
          node["name"] if node["kind"] == "TypedefDecl" && allowed_declaration_name?(node["name"])
        end
        build_alias_maps(top_level_nodes)

        declarations = []
        declarations.concat(select_record_declarations(top_level_nodes))
        validate_field_type_overrides!(declarations)
        discover_synthetic_aggregate_dependencies(declarations)
        discover_synthetic_field_type_dependencies(declarations)
        declarations.concat(select_enum_declarations(top_level_nodes))
        declarations.concat(select_type_alias_declarations(top_level_nodes))
        declarations.concat(select_constant_declarations(top_level_nodes))
        function_declarations = select_function_declarations(top_level_nodes)
        validate_function_param_type_overrides!(function_declarations)
        validate_function_return_type_overrides!(function_declarations)
        declarations.concat(function_declarations)
        declarations.sort_by! { |declaration| declaration[:index] }

        format_generated_source(emit_module(declarations))
      end

      def generate_with_report
        source = generate
        {
          source:,
          nullable_policy_report: nullable_policy_report,
        }
      end

      private

      def nullable_policy_report
        parameter_entries = @manual_nullable_param_overrides.sort_by { |entry| [entry[:function], entry[:parameter]] }
        return_entries = @manual_nullable_return_overrides.sort_by { |entry| entry[:function] }

        {
          module_name: @module_name,
          header_path: @header_path,
          summary: {
            parameters: parameter_entries.length,
            return_types: return_entries.length,
            total: parameter_entries.length + return_entries.length,
          },
          manual_nullable_policy: {
            parameters: parameter_entries,
            return_types: return_entries,
          },
        }
      end

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
        seen_ids = {}

        Array(ast["inner"]).flat_map do |node|
          next [] unless node.is_a?(Hash)

          nodes = []
          nodes << node if interesting_top_level_kind?(node["kind"]) && node_from_header?(node)
          nodes.concat(typedef_owned_tag_nodes(node)) if node["kind"] == "TypedefDecl"
          nodes
        end.filter do |node|
          node_id = node["id"] || node.object_id
          next false if seen_ids.key?(node_id)

          seen_ids[node_id] = true
        end
      end

      def typedef_owned_tag_nodes(node)
        Array(node["inner"]).flat_map do |child|
          typedef_owned_tag_nodes_from(child)
        end
      end

      def typedef_owned_tag_nodes_from(node)
        return [] unless node.is_a?(Hash)

        nodes = []
        if %w[RecordDecl EnumDecl].include?(node["kind"]) && node_from_header?(node)
          nodes << node
        end

        Array(node["inner"]).each do |child|
          nodes.concat(typedef_owned_tag_nodes_from(child))
        end
        nodes
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
        return false unless name
        return false if @excluded_declaration_names.include?(name)
        return true if @declaration_name_prefixes.empty?

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
            if target[:name] && !target[:name].empty?
              @record_aliases_by_tag_name[target[:name]] ||= node["name"]
            end
          when "EnumDecl"
            @enum_aliases[target[:id]] = node["name"]
          end
        end
      end

      def index_referenceable_record_declarations(ast)
        indexed = {}
        indexed_by_id = {}
        queue = Array(ast["inner"]).dup

        until queue.empty?
          node = queue.shift
          next unless node.is_a?(Hash)

          if node["kind"] == "RecordDecl" && %w[struct union].include?(node["tagUsed"]) && node["name"]
            existing = indexed[node["name"]]
            if existing.nil? || (!record_complete_definition?(existing) && record_complete_definition?(node))
              indexed[node["name"]] = node
            end
            indexed_by_id[node["id"]] = node if node["id"]
          end

          queue.concat(Array(node["inner"]))
        end

        @referenceable_record_declarations = indexed
        @referenceable_record_declarations_by_id = indexed_by_id
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
            next if type.nil? && skip_macro_constant_declaration?(node, initializer)
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

      def skip_macro_constant_declaration?(node, initializer)
        return false unless macro_probe_declaration?(node)

        false
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

      def emit_module(declarations)
        declarations = synthetic_declarations_for(declarations) + declarations

        lines = []
        lines << "# generated by mtc bindgen from #{@header_path}"
        lines << "external"
        lines << ""

        @module_imports.each do |import|
          lines << %(import #{import.fetch(:module_name)} as #{import.fetch(:alias)})
        end

        directives = []
        @link_libraries.each do |library|
          directives << %(link #{library.dump})
        end
        includes = @include_directives && !@include_directives.empty? ? @include_directives : [File.basename(@header_path)]
        includes.each do |include_name|
          directives << %(include #{include_name.dump})
        end
        lines.concat(directives)

        declarations.each do |declaration|
          lines.concat(emit_declaration(declaration))
        end

        lines.join("\n") + "\n"
      end

      def format_generated_source(source)
        Formatter.format_source(source, path: generated_module_path, mode: :canonical)
      end

      def generated_module_path
        "#{@module_name.tr('.', '/')}" + ".mt"
      end

      def emit_declaration(declaration)
        case declaration[:kind]
        when "struct", "union"
          emit_aggregate_declaration(declaration[:kind], declaration[:name], declaration[:node])
        when "opaque"
          line = "opaque #{declaration[:name]}"
          line += " = c#{declaration[:c_name].inspect}" if declaration[:c_name]
          [line]
        when "enum", "flags"
          emit_enum_declaration(declaration[:kind], declaration[:name], declaration[:node])
        when "type_alias"
          ["type #{declaration[:name]} = #{declaration[:mapped_type]}"]
        when "const"
          ["const #{declaration[:name]}: #{declaration[:type]} = #{declaration[:value]}"]
        when "function"
          emit_function_declaration(declaration)
        else
          raise BindgenError, "unsupported bindgen declaration kind #{declaration[:kind]}"
        end
      end

      def emit_aggregate_declaration(kind, name, node)
        explicit_c_name = aggregate_explicit_c_name(name, node)
        header = "#{kind} #{name}"
        header += " = c#{explicit_c_name.inspect}" if explicit_c_name
        header += ":"
        lines = [header]
        fields = Array(node["inner"]).select { |child| child["kind"] == "FieldDecl" }
        fields.each do |field|
          field_type = aggregate_field_type(field, owner_name: name, aggregate_node: node)
          mt_name, = bindgen_field_name(aggregate_field_name(field, aggregate_node: node))
          lines << "    #{mt_name}: #{field_type}"
        end
        lines
      end

      def bindgen_field_name(name)
        return [name, nil] unless Token::KEYWORDS.key?(name)

        ["#{name}_", nil]
      end

      def bindgen_param_name(name)
        return [name, nil] unless generated_binding_name_conflict?(name)

        ["#{name}_", nil]
      end

      def generated_binding_name_conflict?(name)
        Token::KEYWORDS.key?(name) || Types::RESERVED_VALUE_TYPE_NAMES.include?(name)
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

            synthetic_name = synthetic_aggregate_name(owner_name, field, aggregate_node)
            unless @synthetic_declarations.any? { |declaration| declaration[:name] == synthetic_name }
              @synthetic_declarations << { kind: anonymous_record.fetch("tagUsed"), name: synthetic_name, node: anonymous_record }
              @aggregate_declarations[synthetic_name] = anonymous_record
            end

            pending << [synthetic_name, anonymous_record]
          end
        end
      end

      def discover_synthetic_field_type_dependencies(declarations)
        pending = declarations.select { |declaration| %w[struct union].include?(declaration[:kind]) }.map do |declaration|
          [declaration[:name], declaration[:node]]
        end
        pending.concat(
          @synthetic_declarations.select { |declaration| %w[struct union].include?(declaration[:kind]) }.map do |declaration|
            [declaration[:name], declaration[:node]]
          end,
        )
        seen = {}

        until pending.empty?
          owner_name, aggregate_node = pending.shift
          key = [owner_name, aggregate_node["id"]]
          next if seen[key]

          seen[key] = true

          Array(aggregate_node["inner"]).select { |child| child["kind"] == "FieldDecl" }.each do |field|
            aggregate_field_type(field, owner_name:, aggregate_node:)

            anonymous_record = anonymous_record_decl_for_field(field, aggregate_node)
            next unless anonymous_record

            pending << [synthetic_aggregate_name(owner_name, field, aggregate_node), anonymous_record]
          end
        end
      end

      def aggregate_field_type(field, owner_name:, aggregate_node:)
        override = field_type_override(owner_name, field["name"])
        return override if override

        anonymous_record = anonymous_record_decl_for_field(field, aggregate_node)
        return synthetic_aggregate_name(owner_name, field, aggregate_node) if anonymous_record

        map_type_node(field, context: "field #{owner_name}.#{field["name"]}")
      end

      def aggregate_field_name(field, aggregate_node:)
        name = field["name"]
        return name if name && !name.empty?

        anonymous_record = anonymous_record_decl_for_field(field, aggregate_node)
        return name unless anonymous_record

        field_index = Array(aggregate_node["inner"]).select { |child| child["kind"] == "FieldDecl" }.index { |child| child["id"] == field["id"] } || 0
        "anonymous_#{anonymous_record.fetch("tagUsed")}_#{field_index}"
      end

      def synthetic_aggregate_name(owner_name, field, aggregate_node)
        "#{owner_name}_#{aggregate_field_name(field, aggregate_node:)}"
      end

      def anonymous_record_decl_for_field(field, aggregate_node)
        qual_type = type_qual_type(field)
        return unless qual_type

        tag_match = qual_type.match(/\A(struct|union)\b/)
        return unless tag_match
        return unless qual_type.include?("(unnamed at ") || qual_type.include?("(anonymous at ")

        field_begin = source_location_key(field.dig("range", "begin"))
        return unless field_begin

        expected_tag = tag_match[1]
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
          location.dig("includedFrom", "file"),
          location["file"],
        ]
      end

      def emit_enum_declaration(kind, name, node)
        members = enum_member_values(node)
        backing_type = if members.empty?
                         "int"
                       else
                         map_c_type(members.first.dig(:node, "type", "qualType"), context: "enum #{name}")
                       end
        lines = ["#{kind} #{name}: #{backing_type}"]
        members.each do |member|
          lines << "    #{member[:node]["name"]} = #{member[:value]}"
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
        params = declaration[:params].map do |param|
          emitted_name, = bindgen_param_name(param[:name])
          "#{emitted_name}: #{param[:type]}"
        end
        params << "..." if declaration[:variadic]
        ["external function #{declaration[:name]}(#{params.join(', ')}) -> #{declaration[:return_type]}"]
      end

      def lower_constant_expression(node, expected_type:, context:)
        raise BindgenError, "missing initializer for #{context}" unless node

        case node["kind"]
        when "IntegerLiteral"
          integer_value = node.fetch("value")
          typed_null = pointer_zero_literal(expected_type, integer_value)
          return typed_null if typed_null

          integer_value
        when "FloatingLiteral"
          emit_float_value(node.fetch("value"), expected_type)
        when "StringLiteral"
          %(c#{node.fetch("value")})
        when "ImplicitValueInitExpr"
          lower_zero_value(expected_type:, context:)
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
        values = Array(node["inner"])

        aggregate = @aggregate_declarations[expected_type]
        return lower_aggregate_init_list(values, aggregate:, expected_type:, context:) if aggregate

        element_type, length = parse_array_type(expected_type)
        raise BindgenError, "unsupported aggregate constant type #{expected_type} for #{context}" unless element_type
        raise BindgenError, "initializer field count mismatch for #{context}" if values.length > length

        arguments = (0...length).map do |index|
          value = values[index]
          if value
            lower_constant_expression(value, expected_type: element_type, context: "element #{index} of #{context}")
          else
            lower_zero_value(expected_type: element_type, context: "element #{index} of #{context}")
          end
        end
        "#{expected_type}(#{arguments.join(', ')})"
      end

      def emit_float_value(value, expected_type)
        literal = value.match?(/[.eE]/) ? value : "#{value}.0"
        expected_type == "float" ? literal : literal
      end

      def lower_aggregate_init_list(values, aggregate:, expected_type:, context:)
        fields = Array(aggregate["inner"]).select { |child| child["kind"] == "FieldDecl" }
        raise BindgenError, "initializer field count mismatch for #{context}" if values.length > fields.length

        arguments = fields.each_with_index.map do |field, index|
          field_type = map_type_node(field, context: "field #{expected_type}.#{field["name"]}")
          value = values[index]
          lowered = if value
                      lower_constant_expression(value, expected_type: field_type, context: "field #{field["name"]} of #{context}")
                    else
                      lower_zero_value(expected_type: field_type, context: "field #{field["name"]} of #{context}")
                    end
          "#{field["name"]} = #{lowered}"
        end
        "#{expected_type}(#{arguments.join(', ')})"
      end

      def lower_zero_value(expected_type:, context:)
        return "false" if expected_type == "bool"
        return "0" if %w[char byte ubyte short ushort int uint long ulong ptr_int ptr_uint].include?(expected_type)
        return "0.0" if %w[float double].include?(expected_type)
        return "null[ptr[char]]" if expected_type == "cstr"
        return "null" if expected_type == "cstr?"
        return "null[#{expected_type}]" if expected_type.start_with?("ptr[") || expected_type.start_with?("const_ptr[")

        if @aggregate_declarations.key?(expected_type)
          return lower_aggregate_init_list([], aggregate: @aggregate_declarations.fetch(expected_type), expected_type:, context:)
        end

        element_type, length = parse_array_type(expected_type)
        if element_type
          values = Array.new(length) do |index|
            lower_zero_value(expected_type: element_type, context: "element #{index} of #{context}")
          end
          return "#{expected_type}(#{values.join(', ')})"
        end

        "#{expected_type}<-0"
      end

      def pointer_zero_literal(expected_type, value)
        return nil unless Integer(value, 10).zero?

        return "null[ptr[char]]" if expected_type == "cstr"
        return "null" if expected_type == "cstr?"
        return "null[#{expected_type}]" if expected_type.start_with?("ptr[") || expected_type.start_with?("const_ptr[")

        nil
      rescue ArgumentError
        nil
      end

      def parse_array_type(type)
        return [nil, nil] unless type.start_with?("array[") && type.end_with?("]")

        parts = split_top_level_csv(type.delete_prefix("array[").delete_suffix("]"))
        return [nil, nil] unless parts.length == 2

        [parts[0], Integer(parts[1], 10)]
      rescue ArgumentError
        [nil, nil]
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

      def normalize_type_name_overrides(overrides)
        return {} if overrides.nil?
        raise BindgenError, "type_name_overrides must be a hash" unless overrides.is_a?(Hash)

        overrides.each_with_object({}) do |(type_name, visible_name), normalized|
          unless type_name.is_a?(String) || type_name.is_a?(Symbol)
            raise BindgenError, "type_name_overrides type names must be strings or symbols"
          end
          unless visible_name.is_a?(String) && !visible_name.empty?
            raise BindgenError, "type_name_overrides for #{type_name} must be a non-empty string"
          end

          normalized[type_name.to_s] = visible_name
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

  class BindgenError < StandardError; end
end

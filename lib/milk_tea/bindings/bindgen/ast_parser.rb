# frozen_string_literal: true

module MilkTea
  module Bindgen
    class Generator
      module GeneratorAstParser
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
      end
    end
  end
end

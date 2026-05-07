# frozen_string_literal: true

require "json"
require_relative "../tooling/formatter"

module MilkTea
  module ImportedBindings
    class Error < StandardError; end

    class Binding
      attr_reader :name, :module_name, :binding_path, :raw_module_name, :policy_path, :import_alias

      def initialize(name:, module_name:, binding_path:, raw_module_name:, policy_path:, import_alias: "c")
        @name = name.to_s
        @module_name = module_name
        @binding_path = File.expand_path(binding_path.to_s)
        @raw_module_name = raw_module_name
        @policy_path = File.expand_path(policy_path.to_s)
        @import_alias = import_alias
      end

      def task_name
        "imported_bindings:#{name}"
      end

      def check_task_name
        "imported_bindings:check:#{name}"
      end

      def generate(module_roots: [MilkTea.root])
        Generator.new(
          module_name:,
          raw_module_name:,
          raw_module_path: resolve_module_path(raw_module_name, module_roots),
          policy_path:,
          import_alias:,
          module_roots:,
        ).generate
      end

      def write!(module_roots: [MilkTea.root])
        raw_module_path = resolve_module_path(raw_module_name, module_roots)
        source = Generator.new(
          module_name:,
          raw_module_name:,
          raw_module_path:,
          policy_path:,
          import_alias:,
          module_roots:,
        ).generate
        File.write(binding_path, source)
        raw_module_path
      end

      def check!(module_roots: [MilkTea.root])
        raw_module_path = resolve_module_path(raw_module_name, module_roots)
        actual = Generator.new(
          module_name:,
          raw_module_name:,
          raw_module_path:,
          policy_path:,
          import_alias:,
          module_roots:,
        ).generate
        expected = File.read(binding_path)

        if expected != actual
          raise Error, <<~MESSAGE
            #{binding_path} is out of date for #{raw_module_path} and #{policy_path}
            Run `rake #{task_name}` to regenerate it.
          MESSAGE
        end

        MilkTea::ModuleLoader.new(module_roots:).check_file(binding_path)
        raw_module_path
      end

      private

      def resolve_module_path(module_name, module_roots)
        relative_path = File.join(*module_name.split(".")) + ".mt"
        candidate = module_roots.lazy.map { |root| File.join(File.expand_path(root.to_s), relative_path) }.find { |path| File.file?(path) }
        raise Error, "module not found: #{module_name}" unless candidate

        File.expand_path(candidate)
      end
    end

    class Registry
      include Enumerable

      def initialize(bindings = [])
        @bindings = {}
        @bindings_by_module_name = {}
        bindings.each { |binding| register(binding) }
      end

      def register(binding)
        raise Error, "duplicate imported binding #{binding.name}" if @bindings.key?(binding.name)
        raise Error, "duplicate imported binding module #{binding.module_name}" if @bindings_by_module_name.key?(binding.module_name)

        @bindings[binding.name] = binding
        @bindings_by_module_name[binding.module_name] = binding
      end

      def fetch(name)
        @bindings.fetch(name.to_s)
      rescue KeyError
        raise Error, "unknown imported binding #{name}"
      end

      def each(&block)
        @bindings.each_value(&block)
      end

      def find_by_module_name(module_name)
        @bindings_by_module_name[module_name]
      end

      def task_names
        map(&:task_name)
      end

      def check_task_names
        map(&:check_task_name)
      end
    end

    class Generator
      def initialize(module_name:, raw_module_name:, raw_module_path:, policy_path:, import_alias:, module_roots:)
        @module_name = module_name
        @raw_module_name = raw_module_name
        @raw_module_path = File.expand_path(raw_module_path)
        @policy_path = File.expand_path(policy_path)
        @import_alias = import_alias
        @module_roots = module_roots.map { |root| File.expand_path(root.to_s) }
        @public_type_names_by_raw_name = {}
        @public_type_kinds_by_raw_name = {}
        @imported_public_types_by_alias = {}
        @raw_type_declarations = {}
      end

      def generate
        policy = load_policy
        validate_policy!(policy)

        raw_ast = Parser.parse(File.read(@raw_module_path), path: @raw_module_path)
        validate_raw_module!(raw_ast)
        declarations = index_raw_declarations(raw_ast)
        import_specs = merge_import_specs(raw_import_specs(raw_ast), normalize_imports(policy["imports"]))
        validate_import_specs!(import_specs)
        type_spec = normalize_alias_spec(policy["types"], context: "type")
        validate_shared_import_aliases!(type_spec, import_specs) if type_spec.key?(:shared_from)
        @imported_public_types_by_alias = build_imported_public_types(import_specs, aliases: type_spec.fetch(:shared_from, []))
        const_spec = normalize_alias_spec(policy["constants"], context: "constant")
        function_spec = normalize_function_spec(policy["functions"])
        @raw_type_declarations = declarations[:types]
        @public_type_names_by_raw_name = build_public_type_names(type_spec, declarations)

        lines = []
        lines << "# generated by mtc imported-bindings from #{@raw_module_name} using #{policy_label}"
        lines << "module #{@module_name}"
        lines << ""
        lines << "import #{@raw_module_name} as #{@import_alias}"
        import_specs.each do |spec|
          lines << "import #{spec[:module_name]} as #{spec[:alias]}"
        end

        sections = [
          emit_type_aliases(type_spec, declarations),
          emit_const_aliases(const_spec, declarations),
          emit_foreign_functions(function_spec, declarations),
        ].reject(&:empty?)

        sections.each do |section_lines|
          lines << ""
          lines.concat(section_lines)
        end

        Formatter.format_source(lines.join("\n") + "\n", path: generated_module_path, mode: :tidy)
      end

      private

      def load_policy
        JSON.parse(File.read(@policy_path))
      rescue Errno::ENOENT
        raise Error, "imported binding policy not found: #{@policy_path}"
      rescue JSON::ParserError => e
        raise Error, "failed to parse imported binding policy #{@policy_path}: #{e.message}"
      end

      def validate_policy!(policy)
        unless policy.is_a?(Hash)
          raise Error, "imported binding policy #{@policy_path} must be a JSON object"
        end

        if policy.key?("extra_source")
          raise Error, "extra_source in #{@policy_path} is no longer supported; move helper code into a normal .mt module"
        end

        policy_module_name = policy.fetch("module_name")
        if policy_module_name != @module_name
          raise Error, "imported binding policy #{@policy_path} targets #{policy_module_name}, expected #{@module_name}"
        end

        policy_raw_module_name = policy.fetch("raw_module_name")
        if policy_raw_module_name != @raw_module_name
          raise Error, "imported binding policy #{@policy_path} expects raw module #{policy_raw_module_name}, expected #{@raw_module_name}"
        end

        import_alias = policy["raw_import_alias"]
        return unless import_alias && import_alias != @import_alias

        raise Error, "imported binding policy #{@policy_path} expects import alias #{import_alias}, expected #{@import_alias}"
      end

      def validate_raw_module!(raw_ast)
        unless raw_ast.module_kind == :extern_module && raw_ast.module_name&.to_s == @raw_module_name
          raise Error, "expected #{@raw_module_path} to define extern module #{@raw_module_name}"
        end
      end

      def normalize_imports(value)
        return [] if value.nil?
        raise Error, "imports in #{@policy_path} must be an array" unless value.is_a?(Array)

        value.map do |entry|
          raise Error, "imports in #{@policy_path} must be objects" unless entry.is_a?(Hash)

          validate_allowed_keys!(entry, %w[module_name alias], context: "import")
          module_name = entry.fetch("module_name")
          import_alias = entry.fetch("alias")

          raise Error, "import module_name in #{@policy_path} must be a string" unless module_name.is_a?(String) && !module_name.empty?
          raise Error, "import alias in #{@policy_path} must be a string" unless import_alias.is_a?(String) && !import_alias.empty?

          {
            module_name:,
            alias: import_alias,
          }
        end
      end

      def raw_import_specs(raw_ast)
        raw_ast.imports.map do |import|
          {
            module_name: import.path.parts.join("."),
            alias: import.alias_name,
          }
        end
      end

      def generated_module_path
        "#{@module_name.tr('.', '/')}" + ".mt"
      end

      def merge_import_specs(*groups)
        merged = []

        groups.each do |group|
          group.each do |spec|
            next if merged.include?(spec)

            merged << spec
          end
        end

        merged
      end

      def validate_import_specs!(import_specs)
        duplicate_module = duplicate_name(import_specs.map { |spec| spec[:module_name] })
        raise Error, "duplicate import #{duplicate_module} in #{@policy_path}" if duplicate_module

        duplicate_alias = duplicate_name(([@import_alias] + import_specs.map { |spec| spec[:alias] }))
        raise Error, "duplicate import alias #{duplicate_alias} in #{@policy_path}" if duplicate_alias
      end

      def index_raw_declarations(raw_ast)
        types = {}
        type_order = []
        values = {}
        value_order = []
        functions = {}
        function_order = []

        raw_ast.declarations.each do |declaration|
          case declaration
          when AST::TypeAliasDecl, AST::StructDecl, AST::UnionDecl, AST::EnumDecl, AST::FlagsDecl, AST::OpaqueDecl
            types[declaration.name] = declaration
            type_order << declaration.name
          when AST::ConstDecl
            values[declaration.name] = declaration
            value_order << declaration.name
          when AST::ExternFunctionDecl
            functions[declaration.name] = declaration
            function_order << declaration.name
          end
        end

        {
          types:,
          type_order:,
          values:,
          value_order:,
          functions:,
          function_order:,
        }
      end

      def emit_type_aliases(spec, declarations)
        overrides = index_alias_overrides(spec[:overrides], declarations[:types], context: "type")
        seen_public_names = {}

        resolve_selected_names(spec, declarations[:types], declarations[:type_order], context: "type").map do |raw_name|
          raw_declaration = declarations[:types].fetch(raw_name)
          override = overrides[raw_name]
          public_name = alias_public_name(raw_name, spec:, override:)
          raise Error, "duplicate generated type #{public_name} in #{@policy_path}" if seen_public_names.key?(public_name)

          seen_public_names[public_name] = true
          case public_type_kind(raw_name, override:, raw_declaration:)
          when :alias
            mapping = override && override["mapping"] || shared_type_mapping(raw_name, spec:) || "#{@import_alias}.#{raw_name}"
            "pub type #{public_name} = #{mapping}"
          when :opaque
            opaque_c_name = raw_declaration.c_name || raw_name
            "pub opaque #{public_name} = c#{opaque_c_name.inspect}"
          else
            raise Error, "unsupported generated public type kind for #{raw_name} in #{@policy_path}"
          end
        end
      end

      def emit_const_aliases(spec, declarations)
        overrides = index_alias_overrides(spec[:overrides], declarations[:values], context: "constant")
        seen_public_names = {}

        resolve_selected_names(spec, declarations[:values], declarations[:value_order], context: "constant").map do |raw_name|
          raw_declaration = declarations[:values].fetch(raw_name)
          override = overrides[raw_name]
          public_name = alias_public_name(raw_name, spec:, override:)
          raise Error, "duplicate generated constant #{public_name} in #{@policy_path}" if seen_public_names.key?(public_name)

          seen_public_names[public_name] = true
          const_type = override && override["type"] || render_type(raw_declaration.type)
          mapping = override && override["mapping"] || "#{@import_alias}.#{raw_name}"
          "pub const #{public_name}: #{const_type} = #{mapping}"
        end
      end

      def emit_foreign_functions(spec, declarations)
        validate_known_raw_names!(spec[:exclude], declarations[:functions], context: "function")
        validate_known_raw_names!(spec[:include], declarations[:functions], context: "function") unless spec[:include] == :all

        overrides = index_function_overrides(spec[:overrides], declarations[:functions])
        seen_public_names = {}

        declarations[:function_order].flat_map do |raw_name|
          selected = selected_by_spec?(raw_name, spec) || overrides.key?(raw_name)
          next [] unless selected
          next [] if spec[:exclude].include?(raw_name)

          raw_declaration = declarations[:functions].fetch(raw_name)
          if raw_declaration.variadic
            if overrides.key?(raw_name)
              generated_signatures = overrides.fetch(raw_name).map do |entry|
                if entry.key?("wrapper")
                  raise Error, "variadic raw function #{raw_name} in #{@raw_module_name} cannot use wrapper overrides"
                end

                unless entry.key?("mapping")
                  raise Error, "variadic raw function #{raw_name} in #{@raw_module_name} requires an explicit mapping override"
                end

                render_overridden_function(entry, raw_declaration, spec:)
              end

              generated_signatures.each do |public_name, _signature_lines|
                raise Error, "duplicate generated function #{public_name} in #{@policy_path}" if seen_public_names.key?(public_name)

                seen_public_names[public_name] = true
              end

              next generated_signatures.flat_map(&:last)
            end

            if spec[:include] == :all
              next []
            end

            raise Error, "variadic raw function #{raw_name} in #{@raw_module_name} cannot be imported"
          end

          generated_signatures = if overrides.key?(raw_name)
                                   overrides.fetch(raw_name).map do |entry|
                                     render_overridden_function(entry, raw_declaration, spec:)
                                   end
                                 else
                                   [render_pass_through_foreign_function(raw_declaration, spec:)]
                                 end

          generated_signatures.each do |public_name, _signature_lines|
            raise Error, "duplicate generated function #{public_name} in #{@policy_path}" if seen_public_names.key?(public_name)

            seen_public_names[public_name] = true
          end

          generated_signatures.flat_map(&:last)
        end
      end

      def normalize_alias_spec(value, context:)
        case value
        when nil
          spec = {
            include: :all,
            include_prefixes: [],
            exclude: [],
            overrides: [],
            rename_rules: [],
            strip_prefix: nil,
          }
          spec[:shared_from] = [] if context == "type"
          spec
        when Array
          spec = {
            include: normalize_name_list(value, context:, label: "include"),
            include_prefixes: [],
            exclude: [],
            overrides: [],
            rename_rules: [],
            strip_prefix: nil,
          }
          spec[:shared_from] = [] if context == "type"
          spec
        when Hash
          allowed_keys = %w[include include_prefixes exclude overrides rename_rules strip_prefix]
          allowed_keys << "shared_from" if context == "type"
          validate_allowed_keys!(value, allowed_keys, context: "#{context} section")
          spec = {
            include: default_include(value, context:),
            include_prefixes: normalize_prefix_list(value["include_prefixes"], context:),
            exclude: normalize_name_list(value["exclude"], context:, label: "exclude"),
            overrides: normalize_alias_overrides(value["overrides"], context:),
            rename_rules: normalize_rename_rules(value["rename_rules"], context:),
            strip_prefix: normalize_strip_prefix(value["strip_prefix"], context:),
          }
          spec[:shared_from] = normalize_name_list(value["shared_from"], context: "type import alias", label: "shared_from") if context == "type"
          spec
        else
          raise Error, "#{context} section in #{@policy_path} must be an array or object"
        end
      end

      def normalize_function_spec(value)
        case value
        when nil
          {
            include: [],
            include_prefixes: [],
            exclude: [],
            overrides: [],
            rename_rules: [],
            strip_prefix: nil,
          }
        when Array
          if value.all? { |entry| entry.is_a?(String) }
            {
              include: normalize_name_list(value, context: "function", label: "include"),
              include_prefixes: [],
              exclude: [],
              overrides: [],
              rename_rules: [],
              strip_prefix: nil,
            }
          else
            {
              include: [],
              include_prefixes: [],
              exclude: [],
              overrides: normalize_function_overrides(value),
              rename_rules: [],
              strip_prefix: nil,
            }
          end
        when Hash
          validate_allowed_keys!(value, %w[include include_prefixes exclude overrides rename_rules strip_prefix], context: "function section")
          {
            include: default_include(value, context: "function"),
            include_prefixes: normalize_prefix_list(value["include_prefixes"], context: "function"),
            exclude: normalize_name_list(value["exclude"], context: "function", label: "exclude"),
            overrides: normalize_function_overrides(value["overrides"]),
            rename_rules: normalize_rename_rules(value["rename_rules"], context: "function"),
            strip_prefix: normalize_strip_prefix(value["strip_prefix"], context: "function"),
          }
        else
          raise Error, "function section in #{@policy_path} must be an array or object"
        end
      end

      def normalize_alias_overrides(value, context:)
        return [] if value.nil?
        raise Error, "#{context} overrides in #{@policy_path} must be an array" unless value.is_a?(Array)

        value.each do |entry|
          raise Error, "#{context} overrides in #{@policy_path} must be objects" unless entry.is_a?(Hash)
        end

        value
      end

      def normalize_strip_prefix(value, context:)
        return nil if value.nil?
        raise Error, "#{context} strip_prefix in #{@policy_path} must be a string" unless value.is_a?(String)
        raise Error, "#{context} strip_prefix in #{@policy_path} cannot be empty" if value.empty?

        value
      end

      def normalize_rename_rules(value, context:)
        return [] if value.nil?
        raise Error, "#{context} rename_rules in #{@policy_path} must be an array" unless value.is_a?(Array)

        value.map do |entry|
          raise Error, "#{context} rename_rules in #{@policy_path} must be objects" unless entry.is_a?(Hash)

          validate_allowed_keys!(entry, %w[kind match replace_with], context: "#{context} rename rule")

          kind = entry.fetch("kind")
          unless %w[prefix replace].include?(kind)
            raise Error, "#{context} rename rule kind in #{@policy_path} must be prefix or replace"
          end

          match = entry.fetch("match")
          raise Error, "#{context} rename rule match in #{@policy_path} must be a string" unless match.is_a?(String)
          raise Error, "#{context} rename rule match in #{@policy_path} cannot be empty" if match.empty?

          replace_with = entry.fetch("replace_with", "")
          raise Error, "#{context} rename rule replace_with in #{@policy_path} must be a string" unless replace_with.is_a?(String)

          {
            kind: kind.to_sym,
            match:,
            replace_with:,
          }
        end
      end

      def normalize_include(value, context:)
        return :all if value.nil? || value == "all"

        normalize_name_list(value, context:, label: "include")
      end

      def default_include(value, context:)
        return normalize_include(value["include"], context:) if value.key?("include")
        return [] if value.key?("include_prefixes")

        :all
      end

      def normalize_prefix_list(value, context:)
        return [] if value.nil?
        raise Error, "include_prefixes #{context}s in #{@policy_path} must be an array" unless value.is_a?(Array)

        prefixes = value.map do |entry|
          raise Error, "include_prefixes #{context} entries in #{@policy_path} must be strings" unless entry.is_a?(String)
          raise Error, "include_prefixes #{context} entries in #{@policy_path} cannot be empty" if entry.empty?

          entry
        end

        duplicate = duplicate_name(prefixes)
        raise Error, "duplicate include_prefixes #{context} #{duplicate} in #{@policy_path}" if duplicate

        prefixes
      end

      def normalize_name_list(value, context:, label:)
        return [] if value.nil?
        raise Error, "#{label} #{context}s in #{@policy_path} must be an array" unless value.is_a?(Array)

        names = value.map do |entry|
          raise Error, "#{label} #{context} entries in #{@policy_path} must be strings" unless entry.is_a?(String)

          entry
        end

        duplicate = duplicate_name(names)
        raise Error, "duplicate #{label} #{context} #{duplicate} in #{@policy_path}" if duplicate

        names
      end

      def normalize_function_overrides(value)
        return [] if value.nil?
        raise Error, "function overrides in #{@policy_path} must be an array" unless value.is_a?(Array)

        value.each do |entry|
          raise Error, "function overrides in #{@policy_path} must be objects" unless entry.is_a?(Hash)
        end

        value
      end

      def duplicate_name(names)
        names.tally.each do |name, count|
          return name if count > 1
        end

        nil
      end

      def validate_allowed_keys!(value, allowed_keys, context:)
        unknown_keys = value.keys - allowed_keys
        return if unknown_keys.empty?

        raise Error, "#{context} in #{@policy_path} has unknown keys: #{unknown_keys.join(', ')}"
      end

      def resolve_selected_names(spec, declarations_by_name, ordered_names, context:)
        validate_known_raw_names!(spec[:exclude], declarations_by_name, context:)

        selected_names = if spec[:include] == :all
                           ordered_names.dup
                         else
                           validate_known_raw_names!(spec[:include], declarations_by_name, context:)
                           ordered_names.select { |raw_name| selected_by_spec?(raw_name, spec) }
                         end

        selected_names.reject { |raw_name| spec[:exclude].include?(raw_name) }
      end

      def selected_by_spec?(raw_name, spec)
        return true if spec[:include] == :all

        spec[:include].include?(raw_name) || spec[:include_prefixes].any? { |prefix| raw_name.start_with?(prefix) }
      end

      def validate_known_raw_names!(names, declarations_by_name, context:)
        names.each do |name|
          next if declarations_by_name.key?(name)

          raise Error, "unknown raw #{context} #{name} in #{@raw_module_name}"
        end
      end

      def build_public_type_names(spec, declarations)
        overrides = index_alias_overrides(spec[:overrides], declarations[:types], context: "type")
        public_names = {}
        seen_public_names = {}
        @public_type_kinds_by_raw_name = {}

        resolve_selected_names(spec, declarations[:types], declarations[:type_order], context: "type").each do |raw_name|
          raw_declaration = declarations[:types].fetch(raw_name)
          override = overrides[raw_name]
          public_name = alias_public_name(raw_name, spec:, override:)
          raise Error, "duplicate generated type #{public_name} in #{@policy_path}" if seen_public_names.key?(public_name)

          seen_public_names[public_name] = true
          @public_type_kinds_by_raw_name[raw_name] = public_type_kind(raw_name, override:, raw_declaration:)
          public_names[raw_name] = public_name
        end

        public_names
      end

      def validate_shared_import_aliases!(spec, import_specs)
        known_aliases = import_specs.map { |import_spec| import_spec[:alias] }
        spec.fetch(:shared_from).each do |import_alias|
          next if known_aliases.include?(import_alias)

          raise Error, "unknown shared_from import alias #{import_alias} in #{@policy_path}"
        end
      end

      def build_imported_public_types(import_specs, aliases:)
        aliases.each_with_object({}) do |import_alias, public_types_by_alias|
          import_spec = import_specs.find { |spec| spec[:alias] == import_alias }
          public_types_by_alias[import_alias] = public_type_names_for_module(import_spec[:module_name])
        end
      end

      def public_type_names_for_module(module_name)
        module_path = resolve_module_path(module_name)
        ast = Parser.parse(File.read(module_path), path: module_path)

        ast.declarations.each_with_object([]) do |declaration, names|
          next unless declaration.respond_to?(:visibility) && declaration.visibility == :public
          next unless declaration.is_a?(AST::TypeAliasDecl) || declaration.is_a?(AST::StructDecl) || declaration.is_a?(AST::UnionDecl) || declaration.is_a?(AST::EnumDecl) || declaration.is_a?(AST::FlagsDecl) || declaration.is_a?(AST::OpaqueDecl)

          names << declaration.name
        end
      end

      def shared_type_mapping(raw_name, spec:)
        matching_aliases = spec.fetch(:shared_from, []).select do |import_alias|
          @imported_public_types_by_alias.fetch(import_alias, []).include?(raw_name)
        end

        if matching_aliases.length > 1
          raise Error, "shared type #{raw_name} in #{@policy_path} is ambiguous across imports: #{matching_aliases.join(', ')}"
        end

        import_alias = matching_aliases.first
        return unless import_alias

        "#{import_alias}.#{raw_name}"
      end

      def index_alias_overrides(entries, declarations_by_name, context:)
        overrides = {}
        allowed_keys = context == "constant" ? %w[raw name type mapping] : %w[raw name mapping kind]

        entries.each do |entry|
          validate_allowed_keys!(entry, allowed_keys, context: "#{context} override")

          raw_name = entry.fetch("raw")
          raise Error, "#{context} override raw names in #{@policy_path} must be strings" unless raw_name.is_a?(String)
          raise Error, "unknown raw #{context} #{raw_name} in #{@raw_module_name}" unless declarations_by_name.key?(raw_name)
          raise Error, "duplicate #{context} override #{raw_name} in #{@policy_path}" if overrides.key?(raw_name)

          overrides[raw_name] = entry
        end

        overrides
      end

      def alias_public_name(raw_name, spec:, override:)
        return override["name"] if override && override.key?("name")

        default_public_name(raw_name, spec:, context: "generated name")
      end

      def public_type_kind(raw_name, override:, raw_declaration:)
        kind = override && override["kind"]
        return :alias if kind.nil?
        raise Error, "type override kind for #{raw_name} in #{@policy_path} must be alias or opaque" unless %w[alias opaque].include?(kind)

        return :alias if kind == "alias"

        unless raw_declaration.is_a?(AST::OpaqueDecl)
          raise Error, "type override #{raw_name} in #{@policy_path} can only use kind opaque for raw opaque declarations"
        end

        if override.key?("mapping")
          raise Error, "type override #{raw_name} in #{@policy_path} cannot use mapping with kind opaque"
        end

        :opaque
      end

      def default_public_name(raw_name, spec:, context:)
        transformed = apply_rename_rules(raw_name, spec[:rename_rules], context:)
        transformed = strip_prefix(transformed, spec[:strip_prefix], context:) if spec[:strip_prefix]
        raise Error, "#{context} in #{@policy_path} cannot be empty" if transformed.empty?

        transformed
      end

      def apply_rename_rules(name, rules, context:)
        transformed = name

        rules.each do |rule|
          case rule[:kind]
          when :prefix
            next unless transformed.start_with?(rule[:match])

            transformed = rule[:replace_with] + transformed.delete_prefix(rule[:match])
          when :replace
            transformed = transformed.gsub(rule[:match], rule[:replace_with])
          else
            raise Error, "unsupported #{context} rename rule #{rule[:kind]} in #{@policy_path}"
          end
        end

        raise Error, "#{context} in #{@policy_path} cannot be empty" if transformed.empty?

        transformed
      end

      def strip_prefix(name, prefix, context:)
        stripped = prefix && name.start_with?(prefix) ? name.delete_prefix(prefix) : name
        raise Error, "#{context} in #{@policy_path} cannot be empty" if stripped.empty?

        stripped
      end

      def index_function_overrides(entries, declarations_by_name)
        overrides = {}

        entries.each do |entry|
          validate_allowed_keys!(entry, %w[raw name type_params params return_type mapping wrapper], context: "function override")

          raw_name = entry.fetch("raw")
          raise Error, "function override raw names in #{@policy_path} must be strings" unless raw_name.is_a?(String)
          raise Error, "unknown raw function #{raw_name} in #{@raw_module_name}" unless declarations_by_name.key?(raw_name)

          (overrides[raw_name] ||= []) << entry
        end

        overrides
      end

      def render_overridden_function(entry, raw_declaration, spec:)
        if entry.key?("wrapper")
          render_wrapped_function(entry, raw_declaration, spec:)
        else
          render_overridden_foreign_function(entry, raw_declaration, spec:)
        end
      end

      def render_overridden_foreign_function(entry, raw_declaration, spec:)
        raw_name = raw_declaration.name
        function_name = entry["name"] || foreign_function_name(raw_name, spec:)
        type_params = override_type_param_names(entry, raw_declaration)
        params = override_param_specs(entry, raw_declaration).map { |param| render_foreign_param(param) }
        return_type = entry["return_type"] || render_public_foreign_type(raw_declaration.return_type)
        mapping = entry["mapping"] || "#{@import_alias}.#{raw_name}"

        [function_name, [build_foreign_signature(function_name, type_params:, params:, return_type:, mapping:)]]
      end

      def render_pass_through_foreign_function(raw_declaration, spec:)
        function_name = foreign_function_name(raw_declaration.name, spec:)
        params = raw_declaration.params.map { |param| render_raw_foreign_param(param) }
        return_type = render_public_foreign_type(raw_declaration.return_type)
        mapping = "#{@import_alias}.#{raw_declaration.name}"

        [function_name, [build_foreign_signature(function_name, type_params: raw_type_param_names(raw_declaration), params:, return_type:, mapping:)]]
      end

      def render_wrapped_function(entry, raw_declaration, spec:)
        raw_name = raw_declaration.name
        function_name = entry["name"] || foreign_function_name(raw_name, spec:)
        raw_function_name = "mt_raw_#{function_name}"
        type_params = override_type_param_names(entry, raw_declaration)
        param_specs = override_param_specs(entry, raw_declaration)
        wrapper = normalize_function_wrapper(entry["wrapper"], raw_name)

        if entry.key?("mapping")
          raise Error, "function wrapper #{raw_name} in #{@policy_path} cannot use mapping"
        end
        if entry.key?("return_type")
          raise Error, "function wrapper #{raw_name} in #{@policy_path} cannot use return_type"
        end

        case wrapper[:kind]
        when :owned_string
          render_owned_string_wrapper(
            raw_name,
            function_name:,
            raw_function_name:,
            type_params:,
            param_specs:,
            raw_declaration:,
            wrapper:,
          )
        when :owned_bytes
          render_owned_bytes_wrapper(
            raw_name,
            function_name:,
            raw_function_name:,
            type_params:,
            param_specs:,
            raw_declaration:,
            wrapper:,
          )
        when :owned_vec
          render_owned_vec_wrapper(
            raw_name,
            function_name:,
            raw_function_name:,
            type_params:,
            param_specs:,
            raw_declaration:,
            wrapper:,
          )
        else
          raise Error, "unsupported wrapper kind #{wrapper[:kind]} for #{raw_name} in #{@policy_path}"
        end
      end

      def render_owned_string_wrapper(raw_name, function_name:, raw_function_name:, type_params:, param_specs:, raw_declaration:, wrapper:)
        validate_owned_string_wrapper_return_type!(raw_declaration, raw_name)
        validate_owned_string_wrapper_param_specs!(param_specs, raw_name)

        raw_return_type = render_public_foreign_type(raw_declaration.return_type)
        raw_signature_params = param_specs.map { |param| render_foreign_param(param) }
        public_signature_params = param_specs.map { |param| render_wrapper_param(param, raw_name:) }
        public_return_type = owned_string_wrapper_return_type(raw_declaration, wrapper)
        call_args = param_specs.map { |param| param.fetch("name") }.join(', ')
        raw_value_expression = "ptr[char]<-raw_result"

        lines = []
        lines << build_foreign_signature(raw_function_name, type_params:, params: raw_signature_params, return_type: raw_return_type, mapping: "#{@import_alias}.#{raw_name}", visibility: :private)
        lines << ""
        lines << build_function_signature(function_name, type_params:, params: public_signature_params, return_type: public_return_type)
        lines << "    let raw_result = #{raw_function_name}#{render_call_args(call_args)}"

        if raw_declaration.return_type.nullable
          option_alias = wrapper.fetch(:option_alias)
          string_alias = wrapper.fetch(:string_alias)
          lines << "    if raw_result == null:"
          lines << "        return #{option_alias}.Option[#{string_alias}.String].none()"
          lines << ""
        end

        lines << "    let value = #{wrapper.fetch(:string_alias)}.String.from_str(#{wrapper.fetch(:text_alias)}.chars_as_str(#{raw_value_expression}))"
        lines << "    #{wrapper.fetch(:release)}(#{raw_value_expression})"

        if raw_declaration.return_type.nullable
          option_alias = wrapper.fetch(:option_alias)
          string_alias = wrapper.fetch(:string_alias)
          lines << "    return #{option_alias}.Option[#{string_alias}.String].some(value)"
        else
          lines << "    return value"
        end

        [function_name, lines]
      end

      def render_owned_bytes_wrapper(raw_name, function_name:, raw_function_name:, type_params:, param_specs:, raw_declaration:, wrapper:)
        validate_owned_bytes_wrapper_return_type!(raw_declaration, raw_name)
        size_param, public_param_specs = owned_bytes_wrapper_params(param_specs, raw_name)

        raw_return_type = render_public_foreign_type(raw_declaration.return_type)
        raw_signature_params = param_specs.map { |param| render_foreign_param(param) }
        public_signature_params = public_param_specs.map { |param| render_wrapper_param(param, raw_name:) }
        public_return_type = owned_bytes_wrapper_return_type(raw_declaration, wrapper)
        call_args = param_specs.map { |param| param.fetch("name") }.join(', ')
        raw_value_expression = "ptr[ubyte]<-raw_result"
        size_name = size_param.fetch("name")

        lines = []
        lines << build_foreign_signature(raw_function_name, type_params:, params: raw_signature_params, return_type: raw_return_type, mapping: "#{@import_alias}.#{raw_name}", visibility: :private)
        lines << ""
        lines << build_function_signature(function_name, type_params:, params: public_signature_params, return_type: public_return_type)
        lines << "    var #{size_name} = 0"
        lines << "    let raw_result = #{raw_function_name}#{render_call_args(call_args)}"

        if raw_declaration.return_type.nullable
          option_alias = wrapper.fetch(:option_alias)
          bytes_alias = wrapper.fetch(:bytes_alias)
          lines << "    if raw_result == null:"
          lines << "        return #{option_alias}.Option[#{bytes_alias}.Buffer].none()"
          lines << ""
        end

        lines << "    if #{size_name} < 0:"
        lines << "        #{wrapper.fetch(:release)}(#{raw_value_expression})"
        lines << "        panic(c\"imported wrapper #{function_name} returned negative size\")"
        lines << ""
        lines << "    var value = #{wrapper.fetch(:bytes_alias)}.with_capacity(ptr_uint<-#{size_name})"
        lines << "    #{wrapper.fetch(:bytes_alias)}.append(ref_of(value), span[ubyte](data = #{raw_value_expression}, len = ptr_uint<-#{size_name}))"
        lines << "    #{wrapper.fetch(:release)}(#{raw_value_expression})"

        if raw_declaration.return_type.nullable
          option_alias = wrapper.fetch(:option_alias)
          bytes_alias = wrapper.fetch(:bytes_alias)
          lines << "    return #{option_alias}.Option[#{bytes_alias}.Buffer].some(value)"
        else
          lines << "    return value"
        end

        [function_name, lines]
      end

      def render_owned_vec_wrapper(raw_name, function_name:, raw_function_name:, type_params:, param_specs:, raw_declaration:, wrapper:)
        element_type = owned_vec_wrapper_element_type(raw_declaration, raw_name)
        count_param, public_param_specs = owned_vec_wrapper_params(param_specs, raw_name)

        raw_return_type = render_public_foreign_type(raw_declaration.return_type)
        raw_signature_params = param_specs.map { |param| render_foreign_param(param) }
        public_signature_params = public_param_specs.map { |param| render_wrapper_param(param, raw_name:) }
        public_return_type = owned_vec_wrapper_return_type(raw_declaration, wrapper, element_type)
        call_args = param_specs.map { |param| param.fetch("name") }.join(', ')
        raw_value_expression = "#{raw_return_type.delete_suffix('?')}<-raw_result"
        count_name = count_param.fetch("name")
        vec_alias = wrapper.fetch(:vec_alias)

        lines = []
        lines << build_foreign_signature(raw_function_name, type_params:, params: raw_signature_params, return_type: raw_return_type, mapping: "#{@import_alias}.#{raw_name}", visibility: :private)
        lines << ""
        lines << build_function_signature(function_name, type_params:, params: public_signature_params, return_type: public_return_type)
        lines << "    var #{count_name} = 0"
        lines << "    let raw_result = #{raw_function_name}#{render_call_args(call_args)}"
        lines << "    if #{count_name} < 0:"
        lines << "        if raw_result != null:"
        lines << "            #{wrapper.fetch(:release)}(#{raw_value_expression})"
        lines << "        panic(c\"imported wrapper #{function_name} returned negative count\")"
        lines << ""
        lines << "    var value = #{vec_alias}.Vec[#{element_type}].with_capacity(ptr_uint<-#{count_name})"
        lines << "    if #{count_name} == 0:"
        lines << "        if raw_result != null:"
        lines << "            #{wrapper.fetch(:release)}(#{raw_value_expression})"

        if raw_declaration.return_type.nullable
          option_alias = wrapper.fetch(:option_alias)
          lines << "        return #{option_alias}.Option[#{vec_alias}.Vec[#{element_type}]].some(value)"
        else
          lines << "        return value"
        end

        lines << ""
        if raw_declaration.return_type.nullable
          option_alias = wrapper.fetch(:option_alias)
          lines << "    if raw_result == null:"
          lines << "        return #{option_alias}.Option[#{vec_alias}.Vec[#{element_type}]].none()"
          lines << ""
        end

        lines << "    var index: ptr_uint = 0"
        lines << "    while index < ptr_uint<-#{count_name}:"
        lines << "        unsafe:"
        lines << "            value.push(read(#{raw_value_expression} + index))"
        lines << "        index += 1"
        lines << "    #{wrapper.fetch(:release)}(#{raw_value_expression})"

        if raw_declaration.return_type.nullable
          option_alias = wrapper.fetch(:option_alias)
          lines << "    return #{option_alias}.Option[#{vec_alias}.Vec[#{element_type}]].some(value)"
        else
          lines << "    return value"
        end

        [function_name, lines]
      end

      def normalize_function_wrapper(value, raw_name)
        raise Error, "function wrapper for #{raw_name} in #{@policy_path} must be an object" unless value.is_a?(Hash)

        kind = value.fetch("kind")
        raise Error, "function wrapper kind for #{raw_name} in #{@policy_path} must be a string" unless kind.is_a?(String)

        case kind
        when "owned_string"
          validate_allowed_keys!(value, %w[kind option_alias text_alias string_alias release], context: "function wrapper")
          text_alias = value.fetch("text_alias")
          string_alias = value.fetch("string_alias")
          release = value.fetch("release")
          option_alias = value["option_alias"]

          [text_alias, string_alias, release, option_alias].compact.each do |field|
            raise Error, "function wrapper fields for #{raw_name} in #{@policy_path} must be strings" unless field.is_a?(String) && !field.empty?
          end

          {
            kind: :owned_string,
            option_alias: option_alias,
            text_alias:,
            string_alias:,
            release:,
          }
        when "owned_bytes"
          validate_allowed_keys!(value, %w[kind option_alias bytes_alias release], context: "function wrapper")
          bytes_alias = value.fetch("bytes_alias")
          release = value.fetch("release")
          option_alias = value["option_alias"]

          [bytes_alias, release, option_alias].compact.each do |field|
            raise Error, "function wrapper fields for #{raw_name} in #{@policy_path} must be strings" unless field.is_a?(String) && !field.empty?
          end

          {
            kind: :owned_bytes,
            option_alias: option_alias,
            bytes_alias:,
            release:,
          }
        when "owned_vec"
          validate_allowed_keys!(value, %w[kind option_alias vec_alias release], context: "function wrapper")
          vec_alias = value.fetch("vec_alias")
          release = value.fetch("release")
          option_alias = value["option_alias"]

          [vec_alias, release, option_alias].compact.each do |field|
            raise Error, "function wrapper fields for #{raw_name} in #{@policy_path} must be strings" unless field.is_a?(String) && !field.empty?
          end

          {
            kind: :owned_vec,
            option_alias: option_alias,
            vec_alias:,
            release:,
          }
        else
          raise Error, "unsupported function wrapper kind #{kind} for #{raw_name} in #{@policy_path}"
        end
      end

      def override_type_param_names(entry, raw_declaration)
        if entry.key?("type_params")
          normalize_name_list(entry["type_params"], context: "function type parameter", label: "function type parameter")
        else
          raw_type_param_names(raw_declaration)
        end
      end

      def override_param_specs(entry, raw_declaration)
        if entry.key?("params")
          Array(entry["params"])
        else
          raw_declaration.params.map do |param|
            {
              "name" => snake_case(param.name),
              "type" => render_public_foreign_type(param.type),
            }
          end
        end
      end

      def validate_owned_string_wrapper_return_type!(raw_declaration, raw_name)
        type = raw_declaration.return_type
        unless type.is_a?(AST::TypeRef) && type.name.to_s == "ptr" && type.arguments.length == 1
          raise Error, "owned_string wrapper for #{raw_name} in #{@policy_path} requires ptr[char] or ptr[char]? return type"
        end

        pointee = type.arguments.first.value
        unless pointee.is_a?(AST::TypeRef) && pointee.name.to_s == "char" && pointee.arguments.empty? && !pointee.nullable
          raise Error, "owned_string wrapper for #{raw_name} in #{@policy_path} requires ptr[char] or ptr[char]? return type"
        end
      end

      def validate_owned_bytes_wrapper_return_type!(raw_declaration, raw_name)
        type = raw_declaration.return_type
        unless type.is_a?(AST::TypeRef) && type.name.to_s == "ptr" && type.arguments.length == 1
          raise Error, "owned_bytes wrapper for #{raw_name} in #{@policy_path} requires ptr[ubyte] or ptr[ubyte]? return type"
        end

        pointee = type.arguments.first.value
        unless pointee.is_a?(AST::TypeRef) && pointee.name.to_s == "ubyte" && pointee.arguments.empty? && !pointee.nullable
          raise Error, "owned_bytes wrapper for #{raw_name} in #{@policy_path} requires ptr[ubyte] or ptr[ubyte]? return type"
        end
      end

      def owned_vec_wrapper_element_type(raw_declaration, raw_name)
        type = raw_declaration.return_type
        unless type.is_a?(AST::TypeRef) && type.name.to_s == "ptr" && type.arguments.length == 1
          raise Error, "owned_vec wrapper for #{raw_name} in #{@policy_path} requires ptr[T] or ptr[T]? return type"
        end

        render_public_foreign_type(type.arguments.first.value)
      end

      def validate_owned_string_wrapper_param_specs!(param_specs, raw_name)
        param_specs.each do |param|
          unless param.is_a?(Hash)
            raise Error, "function parameters in #{@policy_path} must be objects"
          end

          mode = param["mode"]
          next if mode.nil? || mode == "plain"

          raise Error, "function wrapper #{raw_name} in #{@policy_path} does not support parameter mode #{mode}"
        end
      end

      def owned_bytes_wrapper_params(param_specs, raw_name)
        param_specs.each do |param|
          raise Error, "function parameters in #{@policy_path} must be objects" unless param.is_a?(Hash)
        end

        out_params = []
        public_params = []

        param_specs.each do |param|
          mode = param["mode"]
          if mode.nil? || mode == "plain"
            public_params << param
          elsif mode == "out"
            out_params << param
          else
            raise Error, "function wrapper #{raw_name} in #{@policy_path} does not support parameter mode #{mode}"
          end
        end

        if out_params.length != 1
          raise Error, "owned_bytes wrapper for #{raw_name} in #{@policy_path} requires exactly one out int parameter"
        end

        size_param = out_params.first
        unless size_param["type"] == "int"
          raise Error, "owned_bytes wrapper for #{raw_name} in #{@policy_path} requires its out parameter to use type int"
        end
        if size_param["boundary_type"]
          raise Error, "owned_bytes wrapper for #{raw_name} in #{@policy_path} cannot use boundary_type on its out parameter"
        end

        [size_param, public_params]
      end

      def owned_vec_wrapper_params(param_specs, raw_name)
        param_specs.each do |param|
          raise Error, "function parameters in #{@policy_path} must be objects" unless param.is_a?(Hash)
        end

        out_params = []
        public_params = []

        param_specs.each do |param|
          mode = param["mode"]
          if mode.nil? || mode == "plain"
            public_params << param
          elsif mode == "out"
            out_params << param
          else
            raise Error, "function wrapper #{raw_name} in #{@policy_path} does not support parameter mode #{mode}"
          end
        end

        if out_params.length != 1
          raise Error, "owned_vec wrapper for #{raw_name} in #{@policy_path} requires exactly one out int parameter"
        end

        count_param = out_params.first
        unless count_param["type"] == "int"
          raise Error, "owned_vec wrapper for #{raw_name} in #{@policy_path} requires its out parameter to use type int"
        end
        if count_param["boundary_type"]
          raise Error, "owned_vec wrapper for #{raw_name} in #{@policy_path} cannot use boundary_type on its out parameter"
        end

        [count_param, public_params]
      end

      def render_wrapper_param(param, raw_name:)
        unless param.is_a?(Hash)
          raise Error, "function parameters in #{@policy_path} must be objects"
        end

        if param["boundary_type"] && !param["boundary_type"].is_a?(String)
          raise Error, "function wrapper #{raw_name} in #{@policy_path} requires boundary_type strings when present"
        end

        "#{param.fetch("name")}: #{param.fetch("type")}"
      end

      def owned_string_wrapper_return_type(raw_declaration, wrapper)
        string_type = "#{wrapper.fetch(:string_alias)}.String"
        return string_type unless raw_declaration.return_type.nullable

        option_alias = wrapper[:option_alias]
        raise Error, "owned_string wrapper in #{@policy_path} requires option_alias for nullable raw returns" unless option_alias

        "#{option_alias}.Option[#{string_type}]"
      end

      def owned_bytes_wrapper_return_type(raw_declaration, wrapper)
        buffer_type = "#{wrapper.fetch(:bytes_alias)}.Buffer"
        return buffer_type unless raw_declaration.return_type.nullable

        option_alias = wrapper[:option_alias]
        raise Error, "owned_bytes wrapper in #{@policy_path} requires option_alias for nullable raw returns" unless option_alias

        "#{option_alias}.Option[#{buffer_type}]"
      end

      def owned_vec_wrapper_return_type(raw_declaration, wrapper, element_type)
        vec_type = "#{wrapper.fetch(:vec_alias)}.Vec[#{element_type}]"
        return vec_type unless raw_declaration.return_type.nullable

        option_alias = wrapper[:option_alias]
        raise Error, "owned_vec wrapper in #{@policy_path} requires option_alias for nullable raw returns" unless option_alias

        "#{option_alias}.Option[#{vec_type}]"
      end

      def build_function_signature(name, type_params:, params:, return_type:)
        signature = +"pub def #{name}"
        signature << render_type_params(type_params)
        signature << "(#{params.join(', ')})"
        signature << " -> #{return_type}"
        signature << ":"
        signature
      end

      def render_call_args(arguments)
        return "()" if arguments.empty?

        "(#{arguments})"
      end

      def foreign_function_name(raw_name, spec:)
        snake_case(default_public_name(raw_name, spec:, context: "generated function name"))
      end

      def build_foreign_signature(name, type_params:, params:, return_type:, mapping:, visibility: :public)
        signature = +""
        signature << "pub " if visibility == :public
        signature << "foreign def #{name}"
        signature << render_type_params(type_params)
        signature << "(#{params.join(', ')}) -> #{return_type}"
        signature << " = #{mapping}"
        signature
      end

      def raw_type_param_names(raw_declaration)
        Array(raw_declaration.type_params).map(&:name)
      end

      def render_raw_foreign_param(param)
        "#{snake_case(param.name)}: #{render_public_foreign_type(param.type)}"
      end

      def render_public_foreign_type(type)
        projected_handle = project_public_handle_type(type)
        return projected_handle if projected_handle

        render_type(type)
      end

      def project_public_handle_type(type)
        return unless type.is_a?(AST::TypeRef)
        return unless %w[ptr const_ptr].include?(type.name.to_s)
        return unless type.arguments.length == 1

        pointee = type.arguments.first.value
        return unless pointee.is_a?(AST::TypeRef)
        return unless pointee.arguments.empty?
        return unless @public_type_kinds_by_raw_name[pointee.name.to_s] == :opaque

        text = rendered_type_name(pointee.name.to_s).dup
        text << "?" if type.nullable
        text
      end

      def render_foreign_param(param)
        unless param.is_a?(Hash)
          raise Error, "function parameters in #{@policy_path} must be objects"
        end

        text = +""
        mode = param["mode"]
        text << "#{mode} " if mode
        text << "#{param.fetch("name")}: #{param.fetch("type")}"
        boundary_type = param["boundary_type"]
        text << " as #{boundary_type}" if boundary_type
        text
      end

      def render_type_params(type_params)
        return "" if type_params.empty?

        "[#{type_params.join(', ')}]"
      end

      def snake_case(name)
        name.to_s
            .gsub(/([A-Z]+)([A-Z][a-z])/, '\\1_\\2')
            .gsub(/([a-z])([A-Z])/, '\\1_\\2')
            .gsub(/([A-Za-z])([0-9])/, '\\1_\\2')
            .downcase
      end

      def render_type(type)
        case type
        when AST::TypeRef
          text = rendered_type_name(type.name.to_s).dup
          unless type.arguments.empty?
            rendered_arguments = type.arguments.map { |argument| render_type_argument(argument.value) }
            text << "[#{rendered_arguments.join(', ')}]"
          end
          text << "?" if type.nullable
          text
        when AST::FunctionType
          params = type.params.map { |param| render_function_type_param(param) }.join(', ')
          "fn(#{params}) -> #{render_public_foreign_type(type.return_type)}"
        else
          raise Error, "unsupported raw type node #{type.class.name} in #{@raw_module_path}"
        end
      end

      def render_function_type_param(param)
        case param
        when AST::Param
          "#{param.name}: #{render_public_foreign_type(param.type)}"
        when AST::ForeignParam
          render_foreign_param({ "name" => param.name, "type" => render_public_foreign_type(param.type), "mode" => param.mode, "boundary_type" => param.boundary_type && render_public_foreign_type(param.boundary_type) })
        else
          render_type(param)
        end
      end

      def render_type_argument(argument)
        case argument
        when AST::TypeRef, AST::FunctionType
          render_type(argument)
        when AST::IntegerLiteral
          argument.lexeme
        when AST::Identifier
          argument.name
        else
          raise Error, "unsupported raw type argument #{argument.class.name} in #{@raw_module_path}"
        end
      end

      def rendered_type_name(raw_name, seen = [])
        public_name = @public_type_names_by_raw_name[raw_name]
        return public_name if public_name

        raise Error, "cyclic raw type alias #{raw_name} in #{@raw_module_path}" if seen.include?(raw_name)

        raw_declaration = @raw_type_declarations[raw_name]
        if raw_declaration.is_a?(AST::TypeAliasDecl) &&
            raw_declaration.target.is_a?(AST::TypeRef) &&
            raw_declaration.target.arguments.empty? &&
            !raw_declaration.target.nullable
          return rendered_type_name(raw_declaration.target.name.to_s, seen + [raw_name])
        end

        raw_name
      end

      def policy_label
        root_prefix = MilkTea.root.to_s + "/"
        return @policy_path.delete_prefix(root_prefix) if @policy_path.start_with?(root_prefix)

        File.basename(@policy_path)
      end

      def resolve_module_path(module_name)
        relative_path = File.join(*module_name.split(".")) + ".mt"
        candidate = @module_roots.lazy.map { |root| File.join(root, relative_path) }.find { |path| File.file?(path) }
        raise Error, "module not found: #{module_name}" unless candidate

        File.expand_path(candidate)
      end
    end

    def self.default_bindings(root: MilkTea.root)
      [
        Binding.new(
          name: "raylib",
          module_name: "std.raylib",
          binding_path: root.join("std/raylib.mt"),
          raw_module_name: "std.c.raylib",
          policy_path: root.join("bindings/imported/raylib.binding.json"),
        ),
        Binding.new(
          name: "rlgl",
          module_name: "std.rlgl",
          binding_path: root.join("std/rlgl.mt"),
          raw_module_name: "std.c.rlgl",
          policy_path: root.join("bindings/imported/rlgl.binding.json"),
        ),
        Binding.new(
          name: "raygui",
          module_name: "std.raygui",
          binding_path: root.join("std/raygui.mt"),
          raw_module_name: "std.c.raygui",
          policy_path: root.join("bindings/imported/raygui.binding.json"),
        ),
        Binding.new(
          name: "sdl3",
          module_name: "std.sdl3",
          binding_path: root.join("std/sdl3.mt"),
          raw_module_name: "std.c.sdl3",
          policy_path: root.join("bindings/imported/sdl3.binding.json"),
        ),
        Binding.new(
          name: "box2d",
          module_name: "std.box2d",
          binding_path: root.join("std/box2d.mt"),
          raw_module_name: "std.c.box2d",
          policy_path: root.join("bindings/imported/box2d.binding.json"),
        ),
        Binding.new(
          name: "cjson",
          module_name: "std.cjson",
          binding_path: root.join("std/cjson.mt"),
          raw_module_name: "std.c.cjson",
          policy_path: root.join("bindings/imported/cjson.binding.json"),
        ),
        Binding.new(
          name: "steamworks",
          module_name: "std.steamworks",
          binding_path: root.join("std/steamworks.mt"),
          raw_module_name: "std.c.steamworks",
          policy_path: root.join("bindings/imported/steamworks.binding.json"),
        ),
        Binding.new(
          name: "libuv",
          module_name: "std.libuv",
          binding_path: root.join("std/libuv.mt"),
          raw_module_name: "std.c.libuv",
          policy_path: root.join("bindings/imported/libuv.binding.json"),
        ),
        Binding.new(
          name: "libc",
          module_name: "std.libc",
          binding_path: root.join("std/libc.mt"),
          raw_module_name: "std.c.libc",
          policy_path: root.join("bindings/imported/libc.binding.json"),
        ),
        Binding.new(
          name: "libm",
          module_name: "std.libm",
          binding_path: root.join("std/libm.mt"),
          raw_module_name: "std.c.libm",
          policy_path: root.join("bindings/imported/libm.binding.json"),
        ),
      ]
    end

    def self.default_registry(root: MilkTea.root)
      Registry.new(default_bindings(root:))
    end
  end
end

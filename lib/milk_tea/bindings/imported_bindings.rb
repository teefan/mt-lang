# frozen_string_literal: true

require "json"
require_relative "../core/token"
require_relative "../core/types"
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
      MethodSource = Data.define(:module_name, :module_path, :module_kind, :import_alias, :imports_by_alias, :public_type_names, :functions, :function_order, :import_specs)

      def initialize(module_name:, raw_module_name:, raw_module_path:, policy_path:, import_alias:, module_roots:)
        @module_name = module_name
        @raw_module_name = raw_module_name
        @raw_module_path = File.expand_path(raw_module_path)
        @policy_path = File.expand_path(policy_path)
        @import_alias = import_alias
        @module_roots = module_roots.map { |root| File.expand_path(root.to_s) }
        @public_type_names_by_raw_name = {}
        @public_type_kinds_by_raw_name = {}
        @raw_type_declarations = {}
      end

      def generate
        policy = load_policy
        validate_policy!(policy)

        raw_ast = ModuleLoader.new(module_roots: @module_roots).load_file(@raw_module_path)
        validate_raw_module!(raw_ast)
        declarations = index_raw_declarations(raw_ast)
        import_specs = raw_import_specs(raw_ast)
        validate_import_specs!(import_specs)
        type_spec = normalize_alias_spec(policy["types"], context: "type")
        const_spec = normalize_alias_spec(policy["constants"], context: "constant")
        function_spec = normalize_function_spec(policy["functions"])
        method_specs = normalize_method_specs(policy["methods"])
        method_sources = load_method_sources(method_specs)
        @raw_type_declarations = declarations[:types]
        @public_type_names_by_raw_name = build_public_type_names(type_spec, declarations)
        function_entries = plan_foreign_functions(function_spec, declarations)
        generated_import_specs = merge_import_specs(raw_import_specs(raw_ast), method_source_import_specs(method_sources))
        validate_import_specs!(generated_import_specs)

        lines = []
        lines << "# generated by mtc imported-bindings from #{@raw_module_name} using #{policy_label}"
        lines << ""
        lines << "import #{@raw_module_name} as #{@import_alias}"
        generated_import_specs.each do |spec|
          lines << "import #{spec[:module_name]} as #{spec[:alias]}"
        end

        sections = [
          emit_type_aliases(type_spec, declarations),
          emit_const_aliases(const_spec, declarations),
          emit_foreign_functions(function_entries),
          emit_methods(method_specs, function_entries, declarations, method_sources:),
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

        if policy.key?("imports")
          raise Error, "imports in #{@policy_path} are no longer supported; imported bindings must depend only on raw std.c.* modules"
        end

        validate_allowed_keys!(policy, %w[module_name raw_module_name raw_import_alias types constants functions methods], context: "imported binding policy")

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
        unless raw_ast.module_kind == :raw_module && raw_ast.module_name&.to_s == @raw_module_name
          raise Error, "expected #{@raw_module_path} to be external file #{@raw_module_name}"
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

      def validate_import_specs!(import_specs)
        duplicate_module = duplicate_name(import_specs.map { |spec| spec[:module_name] })
        raise Error, "duplicate import #{duplicate_module} in #{@policy_path}" if duplicate_module

        duplicate_alias = duplicate_name(([@import_alias] + import_specs.map { |spec| spec[:alias] }))
        raise Error, "duplicate import alias #{duplicate_alias} in #{@policy_path}" if duplicate_alias
      end

      def merge_import_specs(*groups)
        seen = {}

        groups.flatten.compact.each_with_object([]) do |spec, merged|
          key = [spec[:module_name], spec[:alias]]
          next if seen[key]

          seen[key] = true
          merged << spec
        end
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

      def index_method_source_declarations(source_ast)
        types = {}
        type_order = []
        functions = {}
        function_order = []

        source_ast.declarations.each do |declaration|
          case declaration
          when AST::TypeAliasDecl, AST::StructDecl, AST::UnionDecl, AST::EnumDecl, AST::FlagsDecl, AST::OpaqueDecl
            next unless visible_from_method_source?(declaration, module_kind: source_ast.module_kind)

            types[declaration.name] = declaration
            type_order << declaration.name
          when AST::ExternFunctionDecl, AST::ForeignFunctionDecl
            next unless visible_from_method_source?(declaration, module_kind: source_ast.module_kind)

            functions[declaration.name] = declaration
            function_order << declaration.name
          end
        end

        {
          types:,
          type_order:,
          functions:,
          function_order:,
        }
      end

      def visible_from_method_source?(declaration, module_kind:)
        return true if module_kind == :raw_module

        declaration.respond_to?(:visibility) && declaration.visibility == :public
      end

      def emit_type_aliases(spec, declarations)
        overrides = index_alias_overrides(spec[:overrides], declarations[:types], context: "type")
        seen_public_names = {}

        resolve_selected_names(spec, declarations[:types], declarations[:type_order], context: "type").map do |raw_name|
          raw_declaration = declarations[:types].fetch(raw_name)
          override = overrides[raw_name]
          public_name = alias_public_name(raw_name, spec:, override:, binding_kind: :type)
          raise Error, "duplicate generated type #{public_name} in #{@policy_path}" if seen_public_names.key?(public_name)

          seen_public_names[public_name] = true
          case public_type_kind(raw_name, override:, raw_declaration:)
          when :alias
            mapping = override && override["mapping"] || "#{@import_alias}.#{raw_name}"
            "public type #{public_name} = #{mapping}"
          when :opaque
            opaque_c_name = raw_declaration.c_name || raw_name
            "public opaque #{public_name} = c#{opaque_c_name.inspect}"
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
          public_name = alias_public_name(raw_name, spec:, override:, binding_kind: :value)
          raise Error, "duplicate generated constant #{public_name} in #{@policy_path}" if seen_public_names.key?(public_name)

          seen_public_names[public_name] = true
          const_type = override && override["type"] || render_type(raw_declaration.type)
          mapping = override && override["mapping"] || "#{@import_alias}.#{raw_name}"
          "public const #{public_name}: #{const_type} = #{mapping}"
        end
      end

      def emit_foreign_functions(function_entries)
        function_entries.map do |entry|
          build_foreign_signature(
            entry.fetch(:public_name),
            type_params: entry.fetch(:type_params),
            params: entry.fetch(:params).map { |param| render_foreign_param(param) },
            return_type: entry.fetch(:return_type),
            mapping: entry.fetch(:mapping),
          )
        end
      end

      def emit_methods(method_specs, function_entries, declarations, method_sources:)
        return [] if method_specs.empty?

        entries_by_raw_name = function_entries.group_by { |entry| entry.fetch(:raw_name) }
        available_entries = entries_by_raw_name.transform_values(&:first)
        ordered_names = declarations[:function_order].select { |raw_name| entries_by_raw_name.key?(raw_name) }
        lines = []

        method_specs.each do |spec|
          if spec[:module_name]
            source = method_sources.fetch(method_source_key(spec))
            source_entries = source.functions
            selected_names = resolve_selected_names(spec, source_entries, source.function_order, context: "method function")
            next if selected_names.empty?

            seen_method_names = {}
            lines << "" unless lines.empty?
            lines << "extending #{spec.fetch(:type)}:"

            selected_names.each do |source_name|
              method_name, wrapper_lines = render_method_wrapper(plan_method_source_function(source_entries.fetch(source_name), source:), spec:)
              if seen_method_names.key?(method_name)
                raise Error, "duplicate generated method #{method_name} in #{@policy_path}"
              end

              seen_method_names[method_name] = true
              wrapper_lines.each { |line| lines << "    #{line}" }
            end

            next
          end

          selected_names = resolve_selected_names(spec, available_entries, ordered_names, context: "method function")
          next if selected_names.empty?

          seen_method_names = {}
          lines << "" unless lines.empty?
          lines << "extending #{spec.fetch(:type)}:"

          selected_names.each do |raw_name|
            generated_entries = entries_by_raw_name.fetch(raw_name)
            if generated_entries.length != 1
              raise Error, "method generation for #{raw_name} in #{@policy_path} does not support multiple generated signatures"
            end

            method_name, wrapper_lines = render_method_wrapper(generated_entries.first, spec:)
            if seen_method_names.key?(method_name)
              raise Error, "duplicate generated method #{method_name} in #{@policy_path}"
            end

            seen_method_names[method_name] = true
            wrapper_lines.each { |line| lines << "    #{line}" }
          end
        end

        lines
      end

      def load_method_sources(method_specs)
        method_specs.each_with_object({}) do |spec, sources|
          next unless spec[:module_name]

          key = method_source_key(spec)
          next if sources.key?(key)

          sources[key] = load_method_source(spec)
        end
      end

      def load_method_source(spec)
        module_name = spec.fetch(:module_name)
        module_path = resolve_module_path(module_name)
        source_ast = ModuleLoader.new(module_roots: @module_roots).load_file(module_path)
        unless source_ast.module_name&.to_s == module_name
          raise Error, "expected #{module_path} to define module #{module_name}"
        end

        declarations = index_method_source_declarations(source_ast)
        MethodSource.new(
          module_name:,
          module_path:,
          module_kind: source_ast.module_kind,
          import_alias: spec.fetch(:module_import_alias),
          imports_by_alias: source_ast.imports.to_h { |import| [import.alias_name, import.path.parts.join(".")] },
          public_type_names: declarations[:types].keys,
          functions: declarations[:functions],
          function_order: declarations[:function_order],
          import_specs: [{ module_name:, alias: spec.fetch(:module_import_alias) }],
        )
      end

      def method_source_import_specs(method_sources)
        method_sources.values.flat_map(&:import_specs)
      end

      def method_source_key(spec)
        [spec.fetch(:module_name), spec.fetch(:module_import_alias)]
      end

      def plan_foreign_functions(spec, declarations)
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
              generated_entries = overrides.fetch(raw_name).map do |entry|
                unless entry.key?("mapping")
                  raise Error, "variadic raw function #{raw_name} in #{@raw_module_name} requires an explicit mapping override"
                end

                plan_overridden_function(entry, raw_declaration, spec:)
              end

              generated_entries.each do |entry|
                public_name = entry.fetch(:public_name)
                raise Error, "duplicate generated function #{public_name} in #{@policy_path}" if seen_public_names.key?(public_name)

                seen_public_names[public_name] = true
              end

              next generated_entries
            end

            if spec[:include] == :all
              next []
            end

            raise Error, "variadic raw function #{raw_name} in #{@raw_module_name} cannot be imported"
          end

          generated_entries = if overrides.key?(raw_name)
                                 overrides.fetch(raw_name).map do |entry|
                                   plan_overridden_function(entry, raw_declaration, spec:)
                                   end
                                 else
                                   [plan_pass_through_foreign_function(raw_declaration, spec:)]
                                 end

          generated_entries.each do |entry|
            public_name = entry.fetch(:public_name)
            raise Error, "duplicate generated function #{public_name} in #{@policy_path}" if seen_public_names.key?(public_name)

            seen_public_names[public_name] = true
          end

          generated_entries
        end
      end

      def normalize_alias_spec(value, context:)
        case value
        when nil
          {
            include: :all,
            include_prefixes: [],
            exclude: [],
            overrides: [],
            rename_rules: [],
            strip_prefix: nil,
          }
        when Array
          {
            include: normalize_name_list(value, context:, label: "include"),
            include_prefixes: [],
            exclude: [],
            overrides: [],
            rename_rules: [],
            strip_prefix: nil,
          }
        when Hash
          allowed_keys = %w[include include_prefixes exclude overrides rename_rules strip_prefix]
          validate_allowed_keys!(value, allowed_keys, context: "#{context} section")
          {
            include: default_include(value, context:),
            include_prefixes: normalize_prefix_list(value["include_prefixes"], context:),
            exclude: normalize_name_list(value["exclude"], context:, label: "exclude"),
            overrides: normalize_alias_overrides(value["overrides"], context:),
            rename_rules: normalize_rename_rules(value["rename_rules"], context:),
            strip_prefix: normalize_strip_prefix(value["strip_prefix"], context:),
          }
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

      def normalize_method_specs(value)
        return [] if value.nil?
        raise Error, "methods section in #{@policy_path} must be an array" unless value.is_a?(Array)

        value.map do |entry|
          raise Error, "methods entries in #{@policy_path} must be objects" unless entry.is_a?(Hash)

          validate_allowed_keys!(entry, %w[type receiver_types include include_prefixes exclude rename_rules strip_prefix module_name module_import_alias], context: "methods entry")

          type = normalize_method_type(entry["type"])
          {
            type:,
            receiver_types: normalize_method_receiver_types(entry["receiver_types"], type:),
            include: default_include(entry, context: "method"),
            include_prefixes: normalize_prefix_list(entry["include_prefixes"], context: "method"),
            exclude: normalize_name_list(entry["exclude"], context: "method", label: "exclude"),
            rename_rules: normalize_rename_rules(entry["rename_rules"], context: "method"),
            strip_prefix: normalize_strip_prefix(entry["strip_prefix"], context: "method"),
            module_name: normalize_method_module_name(entry["module_name"]),
            module_import_alias: normalize_method_module_import_alias(entry["module_import_alias"], module_name: entry["module_name"]),
          }
        end
      end

      def normalize_method_module_name(value)
        return nil if value.nil?
        raise Error, "methods entry module_name in #{@policy_path} must be a string" unless value.is_a?(String)
        raise Error, "methods entry module_name in #{@policy_path} cannot be empty" if value.empty?

        value
      end

      def normalize_method_module_import_alias(value, module_name:)
        return nil if module_name.nil? && value.nil?
        raise Error, "methods entry module_import_alias in #{@policy_path} requires module_name" if module_name.nil?
        return module_name.split(".").last if value.nil?
        raise Error, "methods entry module_import_alias in #{@policy_path} must be a string" unless value.is_a?(String)
        raise Error, "methods entry module_import_alias in #{@policy_path} cannot be empty" if value.empty?

        value
      end

      def normalize_method_type(value)
        raise Error, "methods entry type in #{@policy_path} must be a string" unless value.is_a?(String)
        raise Error, "methods entry type in #{@policy_path} cannot be empty" if value.empty?

        value
      end

      def normalize_method_receiver_types(value, type:)
        return [type] if value.nil?

        normalize_name_list(value, context: "method receiver type", label: "method receiver type")
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
          public_name = alias_public_name(raw_name, spec:, override:, binding_kind: :type)
          raise Error, "duplicate generated type #{public_name} in #{@policy_path}" if seen_public_names.key?(public_name)

          seen_public_names[public_name] = true
          @public_type_kinds_by_raw_name[raw_name] = public_type_kind(raw_name, override:, raw_declaration:)
          public_names[raw_name] = public_name
        end

        public_names
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

      def alias_public_name(raw_name, spec:, override:, binding_kind:)
        return override["name"] if override && override.key?("name")

        default_public_name(raw_name, spec:, context: "generated name", binding_kind:)
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

      def default_public_name(raw_name, spec:, context:, binding_kind:)
        transformed = apply_rename_rules(raw_name, spec[:rename_rules], context:)
        transformed = strip_prefix(transformed, spec[:strip_prefix], context:) if spec[:strip_prefix]
        raise Error, "#{context} in #{@policy_path} cannot be empty" if transformed.empty?

        sanitize_generated_binding_name(transformed, binding_kind:)
      end

      def sanitize_generated_binding_name(name, binding_kind:)
        return name unless generated_binding_name_conflict?(name, binding_kind:)

        "#{name}_"
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
          validate_allowed_keys!(entry, %w[raw name type_params params return_type mapping], context: "function override")

          raw_name = entry.fetch("raw")
          raise Error, "function override raw names in #{@policy_path} must be strings" unless raw_name.is_a?(String)
          raise Error, "unknown raw function #{raw_name} in #{@raw_module_name}" unless declarations_by_name.key?(raw_name)

          (overrides[raw_name] ||= []) << entry
        end

        overrides
      end

      def render_overridden_function(entry, raw_declaration, spec:)
        render_overridden_foreign_function(entry, raw_declaration, spec:)
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
        params = raw_declaration.params.map { |param| render_heuristic_foreign_param(param) }
        return_type = render_public_foreign_type(raw_declaration.return_type)
        mapping = "#{@import_alias}.#{raw_declaration.name}"

        [function_name, [build_foreign_signature(function_name, type_params: raw_type_param_names(raw_declaration), params:, return_type:, mapping:)]]
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
              "name" => generated_foreign_param_name(param.name),
              "type" => render_public_foreign_type(param.type),
            }
          end
        end
      end

      def plan_overridden_function(entry, raw_declaration, spec:)
        raw_name = raw_declaration.name
        {
          raw_name:,
          public_name: entry["name"] || foreign_function_name(raw_name, spec:),
          type_params: override_type_param_names(entry, raw_declaration),
          params: override_param_specs(entry, raw_declaration),
          return_type: entry["return_type"] || render_public_foreign_type(raw_declaration.return_type),
          mapping: entry["mapping"] || "#{@import_alias}.#{raw_name}",
        }
      end

      def plan_pass_through_foreign_function(raw_declaration, spec:)
        {
          raw_name: raw_declaration.name,
          public_name: foreign_function_name(raw_declaration.name, spec:),
          type_params: raw_type_param_names(raw_declaration),
          params: raw_declaration.params.map { |param| heuristic_foreign_param_spec(param) },
          return_type: render_public_foreign_type(raw_declaration.return_type),
          mapping: "#{@import_alias}.#{raw_declaration.name}",
        }
      end

      def foreign_function_name(raw_name, spec:)
        snake_case(default_public_name(raw_name, spec:, context: "generated function name", binding_kind: :value))
      end

      def render_method_wrapper(function_entry, spec:)
        raw_name = function_entry.fetch(:raw_name)
        method_name = snake_case(default_public_name(raw_name, spec:, context: "generated method name", binding_kind: :value))
        method_kind = method_kind(function_entry, spec:, raw_name:)
        method_params = method_kind == :static ? function_entry.fetch(:params) : function_entry.fetch(:params).drop(1)
        if method_params.any? { |param| param["mode"] }
          raise Error, "method generation for #{raw_name} in #{@policy_path} cannot wrap out/inout non-receiver parameters; exclude it from methods"
        end
        call_args = []
        call_args << "this" unless method_kind == :static
        call_args.concat(method_params.map { |param| param.fetch("name") })
        call_expression = build_call_expression(function_entry.fetch(:call_name, function_entry.fetch(:public_name)), type_params: function_entry.fetch(:type_params), args: call_args)
        body_line = function_entry.fetch(:return_type) == "void" ? call_expression : "return #{call_expression}"

        [
          method_name,
          [
            build_method_signature(
              method_name,
              type_params: function_entry.fetch(:type_params),
              params: method_params.map { |param| render_method_param(param) },
              return_type: function_entry.fetch(:return_type),
              kind: method_kind,
            ),
            "    #{body_line}",
          ],
        ]
      end

      def method_kind(function_entry, spec:, raw_name:)
        first_param = function_entry.fetch(:params).first
        return :static unless first_param
        return :static unless spec.fetch(:receiver_types).include?(first_param.fetch("type"))

        case first_param["mode"]
        when nil
          :instance
        when "inout"
          :mutable
        else
          raise Error, "method generation for #{raw_name} in #{@policy_path} cannot use receiver mode #{first_param["mode"].inspect}"
        end
      end

      def build_foreign_signature(name, type_params:, params:, return_type:, mapping:, visibility: :public)
        signature = +""
        signature << "public " if visibility == :public
        signature << "foreign function #{name}"
        signature << render_type_params(type_params)
        signature << "(#{params.join(', ')}) -> #{return_type}"
        signature << " = #{mapping}"
        signature
      end

      def build_method_signature(name, type_params:, params:, return_type:, kind:, visibility: :public)
        signature = +""
        signature << "public " if visibility == :public
        signature << case kind
                     when :static
                       "static function "
                     when :mutable
                       "mutable function "
                     else
                       "function "
                     end
        signature << name
        signature << render_type_params(type_params)
        signature << "(#{params.join(', ')}) -> #{return_type}:"
        signature
      end

      def build_call_expression(name, type_params:, args:)
        expression = name.dup
        expression << render_type_params(type_params)
        expression << "(#{args.join(', ')})"
        expression
      end

      def raw_type_param_names(raw_declaration)
        Array(raw_declaration.type_params).map(&:name)
      end

      def plan_method_source_function(declaration, source:)
        if declaration.respond_to?(:variadic) && declaration.variadic
          raise Error, "method generation for #{declaration.name} in #{source.module_path} cannot use variadic functions"
        end

        {
          raw_name: declaration.name,
          public_name: declaration.name,
          call_name: "#{source.import_alias}.#{declaration.name}",
          type_params: raw_type_param_names(declaration),
          params: declaration.params.map { |param| project_method_source_param(param, source:) },
          return_type: project_method_source_type(declaration.return_type, source:),
        }
      end

      def project_method_source_param(param, source:)
        case param
        when AST::ForeignParam
          {
            "name" => param.name,
            "type" => project_method_source_type(param.type, source:),
            "mode" => normalize_method_source_param_mode(param.mode),
          }
        when AST::Param
          {
            "name" => param.name,
            "type" => project_method_source_type(param.type, source:),
          }
        else
          raise Error, "unsupported method source parameter #{param.class.name} in #{source.module_path}"
        end
      end

      def normalize_method_source_param_mode(mode)
        return nil if mode == :plain || mode.nil?

        mode.to_s
      end

      def project_method_source_type(type, source:)
        case type
        when AST::TypeRef
          text = project_method_source_type_name(type.name.to_s, source:)
          unless type.arguments.empty?
            rendered_arguments = type.arguments.map { |argument| project_method_source_type_argument(argument.value, source:) }
            text << "[#{rendered_arguments.join(', ')}]"
          end
          text << "?" if type.nullable
          text
        when AST::FunctionType
          params = type.params.map { |param| project_method_source_function_type_param(param, source:) }.join(', ')
          "fn(#{params}) -> #{project_method_source_type(type.return_type, source:)}"
        else
          raise Error, "unsupported method source type node #{type.class.name} in #{source.module_path}"
        end
      end

      def project_method_source_function_type_param(param, source:)
        case param
        when AST::Param
          "#{param.name}: #{project_method_source_type(param.type, source:)}"
        when AST::ForeignParam
          text = +""
          text << "#{param.mode} " if param.mode
          text << "#{param.name}: #{project_method_source_type(param.type, source:)}"
          if param.boundary_type
            text << " as #{project_method_source_type(param.boundary_type, source:)}"
          end
          text
        else
          project_method_source_type(param, source:)
        end
      end

      def project_method_source_type_argument(argument, source:)
        case argument
        when AST::TypeRef, AST::FunctionType
          project_method_source_type(argument, source:)
        when AST::IntegerLiteral
          argument.lexeme
        when AST::Identifier
          argument.name
        else
          raise Error, "unsupported method source type argument #{argument.class.name} in #{source.module_path}"
        end
      end

      def project_method_source_type_name(raw_name, source:)
        parts = raw_name.split(".")
        if parts.length > 1
          import_alias = parts.first
          imported_name = parts[1..].join(".")
          imported_module_name = source.imports_by_alias[import_alias]
          return rendered_type_name(imported_name) if imported_module_name == @raw_module_name
          return imported_name if imported_module_name == @module_name
          return raw_name if imported_module_name
        end

        return "#{source.import_alias}.#{raw_name}" if source.public_type_names.include?(raw_name)

        rendered_type_name(raw_name)
      end

      def render_raw_foreign_param(param)
        "#{generated_foreign_param_name(param.name)}: #{render_public_foreign_type(param.type)}"
      end

      def render_method_param(param)
        "#{param.fetch("name")}: #{param.fetch("type")}"
      end

      def render_heuristic_foreign_param(param)
        type = param.type

        if type.is_a?(AST::TypeRef) && type.name.to_s == "cstr" && type.arguments.empty? && !type.nullable
          name = generated_foreign_param_name(param.name)
          return render_foreign_param({ "name" => name, "type" => "str", "boundary_type" => "cstr" })
        end

        render_raw_foreign_param(param)
      end

      def heuristic_foreign_param_spec(param)
        type = param.type

        if type.is_a?(AST::TypeRef) && type.name.to_s == "cstr" && type.arguments.empty? && !type.nullable
          name = generated_foreign_param_name(param.name)
          return { "name" => name, "type" => "str", "boundary_type" => "cstr" }
        end

        { "name" => generated_foreign_param_name(param.name), "type" => render_public_foreign_type(param.type) }
      end

      def generated_foreign_param_name(name)
        normalized = snake_case(name)
        return normalized unless generated_binding_name_conflict?(normalized, binding_kind: :value)

        "#{normalized}_"
      end

      def generated_binding_name_conflict?(name, binding_kind:)
        return true if Token::KEYWORDS.key?(name)

        case binding_kind
        when :type
          Types::RESERVED_TYPE_BINDING_NAMES.include?(name)
        when :value
          Types::RESERVED_VALUE_TYPE_NAMES.include?(name)
        else
          raise Error, "unsupported generated binding kind #{binding_kind.inspect} in #{@policy_path}"
        end
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
          .gsub(/([a-z0-9])([A-Z])/, '\\1_\\2')
          .downcase
          .gsub(/([a-z])(\d+)_d\b/, '\\1_\\2d')
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
          name: "raymath",
          module_name: "std.raymath",
          binding_path: root.join("std/raymath.mt"),
          raw_module_name: "std.c.raymath",
          policy_path: root.join("bindings/imported/raymath.binding.json"),
        ),
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
          name: "libuv",
          module_name: "std.libuv",
          binding_path: root.join("std/libuv.mt"),
          raw_module_name: "std.c.libuv",
          policy_path: root.join("bindings/imported/libuv.binding.json"),
        ),
        Binding.new(
          name: "zstd",
          module_name: "std.zstd",
          binding_path: root.join("std/zstd.mt"),
          raw_module_name: "std.c.zstd",
          policy_path: root.join("bindings/imported/zstd.binding.json"),
        ),
        Binding.new(
          name: "sqlite3",
          module_name: "std.sqlite3",
          binding_path: root.join("std/sqlite3.mt"),
          raw_module_name: "std.c.sqlite3",
          policy_path: root.join("bindings/imported/sqlite3.binding.json"),
        ),
        Binding.new(
          name: "curl",
          module_name: "std.curl",
          binding_path: root.join("std/curl.mt"),
          raw_module_name: "std.c.curl",
          policy_path: root.join("bindings/imported/curl.binding.json"),
        ),
        Binding.new(
          name: "pcre2",
          module_name: "std.pcre2",
          binding_path: root.join("std/pcre2.mt"),
          raw_module_name: "std.c.pcre2",
          policy_path: root.join("bindings/imported/pcre2.binding.json"),
        ),
        Binding.new(
          name: "steamworks",
          module_name: "std.steamworks",
          binding_path: root.join("std/steamworks.mt"),
          raw_module_name: "std.c.steamworks",
          policy_path: root.join("bindings/imported/steamworks.binding.json"),
        ),
      ]
    end

    def self.default_registry(root: MilkTea.root)
      Registry.new(default_bindings(root:))
    end
  end
end

# frozen_string_literal: true

require "json"
require_relative "../tooling/formatter"
require_relative "../core/token"
require_relative "../core/common/types"

require_relative "imported_bindings/generator"
require_relative "imported_bindings/method_source"
require_relative "imported_bindings/naming"
require_relative "imported_bindings/defaults"

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
        @raw_function_declarations = {}
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
        extra_import_specs = policy_import_specs(policy)
        type_spec = normalize_alias_spec(policy["types"], context: "type")
        @native_type_mapping = type_spec[:native_types]
        const_spec = normalize_alias_spec(policy["constants"], context: "constant")
        function_spec = normalize_function_spec(policy["functions"])
        method_specs = normalize_method_specs(policy["methods"])
        method_sources = load_method_sources(method_specs)
        @raw_function_declarations = declarations[:functions]
        @raw_type_declarations = declarations[:types]
        @public_type_names_by_raw_name = build_public_type_names(type_spec, declarations)
        function_entries = plan_foreign_functions(function_spec, declarations)
        generated_import_specs = merge_import_specs(raw_import_specs(raw_ast), extra_import_specs, method_source_import_specs(method_sources))
        validate_import_specs!(generated_import_specs)
        const_lines = emit_const_aliases(const_spec, declarations)
        function_lines = emit_foreign_functions(function_entries)
        method_lines = emit_methods(method_specs, function_entries, declarations, method_sources:)
        type_lines = emit_type_aliases(
          type_spec,
          declarations,
          referenced_lines: const_lines + function_lines + method_lines,
          method_sources:,
        )

        lines = []
        lines << "# generated by mtc imported-bindings from #{@raw_module_name} using #{policy_label}"
        lines << ""
        lines << "import #{@raw_module_name} as #{@import_alias}"
        generated_import_specs.each do |spec|
          lines << "import #{spec[:module_name]} as #{spec[:alias]}"
        end

        sections = [
          type_lines,
          const_lines,
          function_lines,
          method_lines,
        ].reject(&:empty?)

        sections.each do |section_lines|
          lines << ""
          lines.concat(section_lines)
        end

        source = lines.join("\n") + "\n"
        Formatter.format_source(source, path: generated_module_path, mode: :tidy)
      end

      private

      include GeneratorPolicy
      include GeneratorMethodSource
      include GeneratorNaming
    end
  end
end

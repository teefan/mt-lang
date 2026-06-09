# frozen_string_literal: true

require "json"

module MilkTea
  module RawBindings
    class Error < StandardError; end

    class Binding
      attr_reader :name, :module_name, :binding_path, :include_directives, :bindgen_defines, :bindgen_include_directives, :module_imports, :link_libraries, :header_candidates, :tracked_header_paths, :tracked_header_prefixes, :declaration_name_prefixes, :excluded_declaration_names, :env_var, :clang_args, :compiler_flags, :implementation_defines, :type_name_overrides, :type_overrides, :function_param_type_overrides, :function_return_type_overrides, :field_type_overrides, :vendored_library

      def initialize(name:, module_name:, binding_path:, header_candidates:, tracked_header_paths: [], tracked_header_prefixes: [], declaration_name_prefixes: [], excluded_declaration_names: [], include_directives: nil, bindgen_defines: [], bindgen_include_directives: [], module_imports: [], link_libraries: [], link_flags: [], env_var: nil, clang: nil, clang_args: [], compiler_flags: [], implementation_defines: [], type_name_overrides: {}, type_overrides: {}, function_param_type_overrides: {}, function_return_type_overrides: {}, field_type_overrides: {}, vendored_library: nil, prepare: nil, generator: nil, allow_static_inline_functions: false)
        @name = name.to_s
        @module_name = module_name
        @binding_path = File.expand_path(binding_path.to_s)
        @header_candidates = header_candidates.map { |path| File.expand_path(path) }.freeze
        @tracked_header_paths = tracked_header_paths.map { |path| File.expand_path(path) }.freeze
        @tracked_header_prefixes = tracked_header_prefixes.map { |path| File.expand_path(path) }.freeze
        @declaration_name_prefixes = declaration_name_prefixes.dup.freeze
        @excluded_declaration_names = excluded_declaration_names.map(&:to_s).freeze
        @include_directives = include_directives&.dup&.freeze
        @bindgen_defines = bindgen_defines.dup.freeze
        @bindgen_include_directives = bindgen_include_directives.dup.freeze
        @link_libraries = link_libraries.dup.freeze
        @link_flags = link_flags.dup.freeze
        @env_var = env_var
        @clang = clang
        @clang_args = clang_args.dup.freeze
        @compiler_flags = compiler_flags.dup.freeze
        @implementation_defines = implementation_defines.dup.freeze
        @module_imports = module_imports.dup.freeze
        @type_name_overrides = type_name_overrides.transform_keys(&:to_s).transform_values(&:to_s).freeze
        @type_overrides = type_overrides.transform_keys(&:to_s).freeze
        @function_param_type_overrides = normalize_function_param_type_overrides(function_param_type_overrides)
        @function_return_type_overrides = function_return_type_overrides.transform_keys(&:to_s).freeze
        @field_type_overrides = normalize_field_type_overrides(field_type_overrides)
        @vendored_library = vendored_library
        @prepare = prepare
        @generator = generator
        @allow_static_inline_functions = allow_static_inline_functions
      end

      def task_name
        "bindgen:#{name}"
      end

      def check_task_name
        "bindgen:check:#{name}"
      end

      def legacy_check_task_name
        "bindgen:check_#{name}"
      end

      def header_label
        return include_directives.first if include_directives && !include_directives.empty?
        return File.basename(header_candidates.first) unless header_candidates.empty?

        name
      end

      def link_flags(platform: nil)
        flags = []
        flags.concat(vendored_library.link_flags(platform:)) if vendored_library
        flags.concat(@link_flags)
        flags.uniq
      end

      def header_path(env: ENV)
        candidates = []
        override = env_var && env[env_var]
        candidates << override unless override.nil? || override.empty?
        candidates.concat(header_candidates)

        resolved = candidates.find { |path| File.file?(path) }
        return resolved if resolved

        if env_var
          raise Error, "#{header_label} header not found; set #{env_var} or install #{header_label} headers"
        end

        raise Error, "#{header_label} header not found"
      end

      def generate(env: ENV, header_path: nil)
        resolved_header_path = header_path || self.header_path(env:)
        return @generator.call(self, env:, header_path: resolved_header_path) if @generator

        MilkTea::Bindgen.generate(**bindgen_kwargs(env:, header_path: resolved_header_path))
      end

      def nullable_policy_report(env: ENV, header_path: nil)
        resolved_header_path = header_path || self.header_path(env:)
        raise Error, "nullable policy report unavailable for custom raw binding generator #{name}" if @generator

        MilkTea::Bindgen.generate_with_report(**bindgen_kwargs(env:, header_path: resolved_header_path)).fetch(:nullable_policy_report)
      end

      def nullable_policy_report_path(root: MilkTea.root)
        File.expand_path(File.join(root, "tmp", "bindgen-nullable-reports", "#{name}.json"))
      end

      def write_nullable_policy_report!(env: ENV, header_path: nil, output_path: nil)
        resolved_header_path = header_path || self.header_path(env:)
        report_path = File.expand_path(output_path || nullable_policy_report_path)
        FileUtils.mkdir_p(File.dirname(report_path))
        if @generator
          File.write(report_path, JSON.pretty_generate({}))
        else
          File.write(report_path, JSON.pretty_generate(nullable_policy_report(env:, header_path: resolved_header_path)))
        end
        report_path
      end

      def build_flags(env: ENV, header_path: nil, platform: nil)
        resolved_header_path = header_path || self.header_path(env:)
        include_dir = File.dirname(resolved_header_path)
        flags = []
        flags << "-I#{include_dir}" unless include_dir.nil? || include_dir.empty?
        implementation_defines.each do |define|
          flags << "-D#{define}"
        end
        flags.concat(compiler_flags)
        flags.concat(vendored_library.build_flags(platform:)) if vendored_library&.respond_to?(:build_flags)
        flags.uniq
      end

      def write!(env: ENV)
        prepare!(env:, cc: env.fetch("CC", "cc"))
        resolved_header_path = header_path(env:)
        File.write(binding_path, generate(env:, header_path: resolved_header_path))
        resolved_header_path
      end

      def check!(env: ENV)
        prepare!(env:, cc: env.fetch("CC", "cc"))
        resolved_header_path = header_path(env:)
        expected = normalized_output(File.read(binding_path))
        actual = normalized_output(generate(env:, header_path: resolved_header_path))

        if expected != actual
          raise Error, <<~MESSAGE
            #{binding_path} is out of date for #{resolved_header_path}
            Run `rake #{task_name}` to regenerate it.
          MESSAGE
        end

        MilkTea::ModuleLoader.check_file(binding_path)
        resolved_header_path
      end

      def prepare!(env: ENV, cc: ENV.fetch("CC", "cc"), platform: nil)
        if @prepare
          kwargs = { env:, cc: }
          kwargs[:platform] = platform if prepare_accepts_keyword?(:platform)
          @prepare.call(self, **kwargs)
        end
        vendored_library&.prepare!(env:, cc:, platform:)
      end

      private

      def normalize_function_param_type_overrides(overrides)
        overrides.each_with_object({}) do |(function_name, param_overrides), normalized|
          normalized[function_name.to_s] = param_overrides.each_with_object({}) do |(param_name, type), params|
            params[param_name.to_s] = type.to_s
          end.freeze
        end.freeze
      end

      def normalize_field_type_overrides(overrides)
        overrides.each_with_object({}) do |(type_name, field_overrides), normalized|
          normalized[type_name.to_s] = field_overrides.each_with_object({}) do |(field_name, type), fields|
            fields[field_name.to_s] = type.to_s
          end.freeze
        end.freeze
      end

      def resolved_clang(env)
        @clang || env.fetch("CLANG", "clang")
      end

      def bindgen_kwargs(env:, header_path:)
        kwargs = {
          module_name:,
          header_path:,
          link_libraries:,
          include_directives:,
          bindgen_defines:,
          bindgen_include_directives:,
          module_imports:,
          clang: resolved_clang(env),
          clang_args:,
          type_name_overrides:,
          type_overrides:,
          function_param_type_overrides:,
          function_return_type_overrides:,
          field_type_overrides:,
        }
        kwargs[:tracked_header_paths] = tracked_header_paths unless tracked_header_paths.empty?
        kwargs[:tracked_header_prefixes] = tracked_header_prefixes unless tracked_header_prefixes.empty?
        kwargs[:declaration_name_prefixes] = declaration_name_prefixes unless declaration_name_prefixes.empty?
        kwargs[:excluded_declaration_names] = excluded_declaration_names unless excluded_declaration_names.empty?
        kwargs[:allow_static_inline_functions] = true if @allow_static_inline_functions
        kwargs
      end

      def prepare_accepts_keyword?(keyword)
        @prepare.parameters.any? do |kind, name|
          kind == :keyrest || ((kind == :key || kind == :keyreq) && name == keyword)
        end
      end

      def normalized_output(source)
        source.sub(/\A# generated by mtc bindgen from .*\n/, "# generated by mtc bindgen from <header>\n")
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
        raise Error, "duplicate raw binding #{binding.name}" if @bindings.key?(binding.name)
        raise Error, "duplicate raw binding module #{binding.module_name}" if @bindings_by_module_name.key?(binding.module_name)

        @bindings[binding.name] = binding
        @bindings_by_module_name[binding.module_name] = binding
      end

      def fetch(name)
        @bindings.fetch(name.to_s)
      rescue KeyError
        raise Error, "unknown raw binding #{name}"
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

    require_relative "raw_bindings/defaults"

    def self.default_registry(root: MilkTea.root)
      registry = Registry.new
      default_bindings(root:).each { |binding| registry.register(binding) }
      registry
    end
  end
end

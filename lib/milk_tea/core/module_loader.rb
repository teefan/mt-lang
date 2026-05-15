# frozen_string_literal: true

module MilkTea
  class ModuleLoadError < StandardError
    attr_reader :path

    def initialize(message, path:)
      @path = path
      super("#{message}: #{path}")
    end
  end

  class ModuleLoader
    Program = Data.define(:root_path, :root_analysis, :analyses_by_path, :analyses_by_module_name)
    ImportResolutionError = Data.define(:import, :error)
    ImportResolution = Data.define(:modules, :errors)
    PLATFORM_SUFFIXES = {
      "linux" => :linux,
      "windows" => :windows,
      "wasm" => :wasm,
    }.freeze

    def self.load_file(path, platform: nil)
      new(platform:).load_file(path)
    end

    def self.check_file(path, platform: nil)
      new(platform:).check_file(path)
    end

    def self.check_program(path, platform: nil)
      new(platform:).check_program(path)
    end

    def self.normalize_platform_name(value)
      return nil if value.nil? || value.to_s.strip.empty?

      case value.to_s.strip.downcase
      when "linux"
        :linux
      when "windows", "win", "win32"
        :windows
      when "wasm", "web", "html5", "browser"
        :wasm
      else
        raise ArgumentError, "unknown platform #{value}; expected linux|windows|wasm"
      end
    end

    def self.platform_suffix_for_path(path)
      match = File.basename(path.to_s).match(/\.(linux|windows|wasm)\.mt\z/)
      return nil unless match

      PLATFORM_SUFFIXES.fetch(match[1])
    end

    def self.effective_platform_for_path(path, platform_override: nil, host_platform: nil)
      normalized_override = normalize_platform_name(platform_override)
      return normalized_override if normalized_override

      suffix_platform = platform_suffix_for_path(path)
      return suffix_platform if suffix_platform

      manifest_platform = PackageManifest.load(path).platform
      return manifest_platform if manifest_platform

      normalize_platform_name(host_platform || default_host_platform)
    rescue PackageManifestError
      normalize_platform_name(host_platform || default_host_platform)
    end

    def self.resolve_source_path(path, platform: nil, error_class: nil)
      expanded_path = File.expand_path(path.to_s)
      normalized_platform = platform.nil? ? nil : normalize_platform_name(platform)
      pinned_platform = platform_suffix_for_path(expanded_path)

      if pinned_platform
        if normalized_platform && normalized_platform != pinned_platform
          raise_platform_conflict!(expanded_path, pinned_platform, normalized_platform, error_class:)
        end
        return expanded_path
      end

      return expanded_path unless normalized_platform && expanded_path.end_with?(".mt")

      variant_path = expanded_path.sub(/\.mt\z/, ".#{normalized_platform}.mt")
      return variant_path if File.file?(variant_path)

      expanded_path
    end

    def self.default_host_platform
      /mswin|mingw|cygwin/ === RUBY_PLATFORM ? :windows : :linux
    end

    # +shared_cache+ is an optional Hash owned by the caller (e.g. the LSP Workspace)
    # that persists across multiple ModuleLoader invocations.  Entries are keyed by
    # absolute path and hold { mtime: Float, analysis: Sema::Analysis }.  When an
    # entry's mtime matches the file's current mtime the cached analysis is reused,
    # avoiding full re-parse + re-sema of large stdlib files on every LSP request.
    #
    # +source_overrides+ is an optional path => source hash used by the LSP for
    # unsaved open documents. When any override is present the shared cache is
    # bypassed so dependent analyses never reuse bindings built from stale disk state.
    def initialize(module_roots: [MilkTea.root], package_graph: nil, shared_cache: nil, source_overrides: nil, platform: nil)
      @module_roots = module_roots.map { |root| File.expand_path(root.to_s) }
      @ast_cache = {}
      @analysis_cache = {}
      @checking_paths = []
      @platform = self.class.normalize_platform_name(platform)
      @package_graph = package_graph
      @package_manifest_cache = {}
      @shared_cache = shared_cache # Hash or nil; mutated in-place to persist across calls
      @source_overrides = normalize_source_overrides(source_overrides)
    end

    def load_file(path)
      resolved_path = self.class.resolve_source_path(path, platform: @platform, error_class: ModuleLoadError)
      @ast_cache[resolved_path] ||= parse_file(resolved_path)
    end

    def check_file(path)
      check_program(path).root_analysis
    end

    def check_program(path)
      requested_path = File.expand_path(path)
      previous_platform = @platform
      @platform ||= self.class.platform_suffix_for_path(requested_path)
      root_path = self.class.resolve_source_path(requested_path, platform: @platform, error_class: ModuleLoadError)
      root_analysis = check_path(root_path)

      analyses_by_module_name = @analysis_cache.each_value.each_with_object({}) do |analysis, modules|
        next unless analysis.module_name

        modules[analysis.module_name] = analysis
      end

      Program.new(
        root_path:,
        root_analysis:,
        analyses_by_path: @analysis_cache.dup.freeze,
        analyses_by_module_name: analyses_by_module_name.freeze,
      )
    ensure
      @platform = previous_platform
    end

    def imported_modules_for_ast(ast, importer_path: nil)
      resolution = imported_modules_for_ast_collecting_errors(ast, importer_path:)
      raise resolution.errors.first.error if resolution.errors.any?

      resolution.modules
    end

    def imported_modules_for_ast_collecting_errors(ast, importer_path: nil)
      modules = {}
      errors = []

      ast.imports.each do |import|
        begin
          import_path = resolve_module_path(import.path.to_s, importer_path:, importer_module_name: ast.module_name.to_s)
          import_analysis = check_path(import_path)
          modules[import.path.to_s] = module_binding(import_analysis)
        rescue ModuleLoadError, PackageLockError => e
          errors << ImportResolutionError.new(import:, error: e)
        end
      end

      begin
        install_async_runtime_dependency!(ast, modules, importer_path:)
      rescue ModuleLoadError, PackageLockError => e
        errors << ImportResolutionError.new(import: nil, error: e)
      end

      ImportResolution.new(modules: modules.freeze, errors: errors.freeze)
    end

    private

    def self.raise_platform_conflict!(path, pinned_platform, active_platform, error_class: nil)
      if error_class == ModuleLoadError
        raise ModuleLoadError.new("source file targets platform #{pinned_platform}; active platform is #{active_platform}", path:)
      end

      message = "source file #{path} targets platform #{pinned_platform}; active platform is #{active_platform}"
      raise(error_class || ArgumentError, message)
    end
    private_class_method :raise_platform_conflict!

    def check_path(path)
      resolved_path = self.class.resolve_source_path(path, platform: @platform, error_class: ModuleLoadError)

      # 1. Instance-local cache (within a single check_program call, prevents re-entrant work)
      return @analysis_cache[resolved_path] if @analysis_cache.key?(resolved_path)

      # 2. Shared cross-request cache (owned by the LSP Workspace): reuse if the
      #    file has not changed on disk since it was last analyzed.
      if use_shared_cache?
        entry = @shared_cache[resolved_path]
        if entry
          current_mtime = File.mtime(resolved_path).to_f rescue nil
          if current_mtime && entry[:mtime] == current_mtime
            @analysis_cache[resolved_path] = entry[:analysis]
            return entry[:analysis]
          end
        end
      end

      if @checking_paths.include?(resolved_path)
        raise ModuleLoadError.new("cyclic import detected", path: resolved_path)
      end

      @checking_paths << resolved_path
      ast = load_file(resolved_path)
      imported_modules = imported_modules_for_ast(ast, importer_path: resolved_path)

      analysis = Sema.check(ast, imported_modules:)
      @analysis_cache[resolved_path] = analysis

      # Populate shared cache with current mtime so subsequent requests skip re-analysis.
      if use_shared_cache?
        mtime = File.mtime(resolved_path).to_f rescue nil
        @shared_cache[resolved_path] = { mtime: mtime, analysis: analysis } if mtime
      end

      analysis
    ensure
      @checking_paths.pop if @checking_paths.last == resolved_path
    end

    def parse_file(path)
      source = @source_overrides.fetch(path) { File.read(path) }
      ast = Parser.parse(source, path: path)
      inferred_module_name = inferred_module_name_for_path(path)
      AST::SourceFile.new(
        module_name: AST::QualifiedName.new(inferred_module_name.split(".")),
        module_kind: ast.module_kind,
        imports: ast.imports,
        directives: ast.directives,
        declarations: ast.declarations,
        line: ast.line,
      )
    rescue Errno::ENOENT
      raise ModuleLoadError.new("source file not found", path: path)
    rescue Errno::EISDIR
      raise ModuleLoadError.new("expected a source file, got a directory", path: path)
    end

    def normalize_source_overrides(source_overrides)
      return {} unless source_overrides

      source_overrides.each_with_object({}) do |(path, source), overrides|
        overrides[File.expand_path(path.to_s)] = source.to_s
      end
    end

    def inferred_module_name_for_path(path)
      manifest = begin
        PackageManifest.load(path)
      rescue PackageManifestError
        nil
      end

      if manifest && path_within_root?(path, manifest.source_root)
        return module_name_for_path(path, manifest.source_root)
      end

      matching_root = @module_roots
                      .select { |root| path_within_root?(path, root) }
                      .max_by(&:length)
      return module_name_for_path(path, matching_root) if matching_root

      File.basename(path).sub(/\.(linux|windows|wasm)\.mt\z/, ".mt").sub(/\.mt\z/, "")
    end

    def module_name_for_path(path, root)
      relative_path = path.delete_prefix(File.expand_path(root) + File::SEPARATOR)
      relative_path = File.basename(path) if relative_path == path
      relative_path = relative_path.sub(/\.(linux|windows|wasm)\.mt\z/, '.mt')
      relative_path.sub(/\.mt\z/, '').split(File::SEPARATOR).join('.')
    end

    def path_within_root?(path, root)
      normalized_path = File.expand_path(path)
      normalized_root = File.expand_path(root)
      normalized_path == normalized_root || normalized_path.start_with?(normalized_root + File::SEPARATOR)
    end

    def use_shared_cache?
      @shared_cache && @source_overrides.empty?
    end

    def resolve_module_path(module_name, importer_path: nil, importer_module_name: nil)
      package_candidate = resolve_package_module_path(module_name, importer_path:)
      return package_candidate if package_candidate

      relative_path = File.join(*module_name.split(".")) + ".mt"
      blocked = false
      candidate = @module_roots.lazy.map { |root| self.class.resolve_source_path(File.join(root, relative_path), platform: @platform) }.find do |path|
        next false unless File.file?(path)

        allowed = import_allowed?(module_name, importer_path, path)
        blocked ||= !allowed
        allowed
      end
      raise ModuleLoadError.new("package dependency not declared", path: module_name) if blocked
      unless candidate
        message = namespace_hint_for_missing_module(module_name, importer_path:, importer_module_name:) || "module not found"
        raise ModuleLoadError.new(message, path: module_name)
      end

      File.expand_path(candidate)
    end

    def namespace_hint_for_missing_module(module_name, importer_path:, importer_module_name:)
      return nil unless importer_path && importer_module_name
      return nil unless entry_module_namespace_like?(importer_path, importer_module_name)
      return nil unless module_name.start_with?("#{importer_module_name}.")

      sibling_import = module_name.delete_prefix("#{importer_module_name}.")
      sibling_path = File.join(File.dirname(importer_path), *sibling_import.split(".")) + ".mt"
      resolved_sibling_path = self.class.resolve_source_path(sibling_path, platform: @platform)
      return nil unless File.file?(resolved_sibling_path)

      namespaced_path = File.join(File.dirname(importer_path), importer_module_name, *sibling_import.split(".")) + ".mt"
      "module not found; entry module '#{importer_module_name}' does not create an import namespace for sibling files. Import '#{sibling_import}' instead, or move the module to #{namespaced_path}"
    end

    def entry_module_namespace_like?(importer_path, importer_module_name)
      return false if importer_module_name.include?(".")

      File.basename(importer_path).match?(/\Amain(?:\.(linux|windows|wasm))?\.mt\z/)
    end

    def resolve_package_module_path(module_name, importer_path: nil)
      return nil unless @package_graph && importer_path

      importer_package = @package_graph.package_for_path(importer_path)
      return nil unless importer_package

      relative_path = File.join(*module_name.split(".")) + ".mt"
      candidates = []
      if package_namespace_match?(module_name, importer_package.manifest.package_name)
        candidates << [
          importer_package.manifest.package_name,
          File.join(importer_package.manifest.source_root, relative_path),
        ]
      end

      importer_package.edges.each do |edge|
        next unless edge.node && package_namespace_match?(module_name, edge.dependency.name)

        candidates << [
          edge.dependency.name,
          File.join(edge.node.manifest.source_root, relative_path),
        ]
      end

      return nil if candidates.empty?

      best_namespace_length = candidates.map { |namespace, _path| namespace.length }.max
      matching_candidates = candidates.select { |namespace, _path| namespace.length == best_namespace_length }
      if matching_candidates.length > 1
        raise ModuleLoadError.new("ambiguous package dependency import", path: module_name)
      end

      resolved_path = self.class.resolve_source_path(matching_candidates.first.last, platform: @platform)
      raise ModuleLoadError.new("module not found", path: module_name) unless File.file?(resolved_path)

      File.expand_path(resolved_path)
    end

    def import_allowed?(module_name, importer_path, candidate_path)
      if @package_graph
        return import_allowed_by_graph?(module_name, importer_path, candidate_path)
      end

      importer_manifest = package_manifest_for_path(importer_path)
      return true unless importer_manifest

      candidate_manifest = package_manifest_for_path(candidate_path)
      return true unless candidate_manifest
      return true if candidate_manifest.manifest_path == importer_manifest.manifest_path

      dependency = importer_manifest.dependencies.find { |entry| entry.name == candidate_manifest.package_name }
      return false unless dependency

      package_namespace_match?(module_name, dependency.name)
    end

    def import_allowed_by_graph?(module_name, importer_path, candidate_path)
      importer_package = @package_graph.package_for_path(importer_path)
      return true unless importer_package

      candidate_package = @package_graph.package_for_path(candidate_path)
      return true unless candidate_package
      return true if candidate_package.manifest.manifest_path == importer_package.manifest.manifest_path

      dependency = importer_package.edges.find do |edge|
        edge.node && edge.node.manifest.package_name == candidate_package.manifest.package_name
      end
      return false unless dependency

      package_namespace_match?(module_name, dependency.dependency.name)
    end

    def package_manifest_for_path(path)
      return nil unless path

      package_root = ModuleRoots.package_root_for_path(path)
      return nil unless package_root

      manifest_path = File.join(package_root, "package.toml")
      return @package_manifest_cache[manifest_path] if @package_manifest_cache.key?(manifest_path)

      @package_manifest_cache[manifest_path] = PackageManifest.load(path)
    rescue PackageManifestError
      @package_manifest_cache[manifest_path] = nil if manifest_path
      nil
    end

    def package_namespace_match?(module_name, package_name)
      module_name == package_name || module_name.start_with?("#{package_name}.")
    end

    def module_binding(analysis)
      types = {}
      interfaces = {}
      private_types = {}
      private_interfaces = {}
      values = {}
      private_values = {}
      functions = {}
      private_functions = {}

      analysis.ast.declarations.each do |declaration|
        case declaration
        when AST::StructDecl, AST::UnionDecl, AST::VariantDecl, AST::EnumDecl, AST::FlagsDecl, AST::OpaqueDecl, AST::TypeAliasDecl
          target = exported_declaration?(analysis, declaration) ? types : private_types
          target[declaration.name] = analysis.types.fetch(declaration.name)
        when AST::InterfaceDecl
          target = exported_declaration?(analysis, declaration) ? interfaces : private_interfaces
          target[declaration.name] = analysis.interfaces.fetch(declaration.name)
        when AST::ConstDecl, AST::VarDecl
          target = exported_declaration?(analysis, declaration) ? values : private_values
          target[declaration.name] = analysis.values.fetch(declaration.name)
        when AST::FunctionDef, AST::ExternFunctionDecl, AST::ForeignFunctionDecl
          target = exported_declaration?(analysis, declaration) ? functions : private_functions
          target[declaration.name] = analysis.functions.fetch(declaration.name)
        end
      end

      methods, private_methods = exported_methods(analysis, types)
      implemented_interfaces, private_implemented_interfaces = exported_interface_implementations(analysis, types, interfaces)

      Sema::ModuleBinding.new(
        name: analysis.module_name,
        types:,
        interfaces:,
        values:,
        functions:,
        methods:,
        implemented_interfaces:,
        private_types:,
        private_interfaces:,
        private_values:,
        private_functions:,
        private_methods:,
        private_implemented_interfaces:,
      )
    end

    def install_async_runtime_dependency!(ast, modules, importer_path: nil)
      return if modules.key?("std.async")
      return unless async_main_declared?(ast)

      import_path = resolve_module_path("std.async", importer_path:)
      import_analysis = check_path(import_path)
      modules["std.async"] = module_binding(import_analysis)
    end

    def async_main_declared?(ast)
      ast.declarations.any? do |decl|
        decl.is_a?(AST::FunctionDef) && decl.name == "main" && decl.async
      end
    end

    def exported_declaration?(analysis, declaration)
      return true if analysis.module_kind == :raw_module
      return false unless declaration.respond_to?(:visibility)

      declaration.visibility == :public
    end

    def exported_methods(analysis, exported_types)
      if analysis.module_kind == :raw_module
        return [analysis.methods.transform_values(&:dup), {}]
      end

      methods = {}
      private_methods = {}

      analysis.methods.each do |receiver_type, bindings|
        public_bindings = {}
        hidden_bindings = {}

        bindings.each do |name, binding|
          visible = binding.ast.respond_to?(:visibility) &&
            binding.ast.visibility == :public &&
            exported_method_receiver?(receiver_type, analysis, exported_types)

          if visible
            public_bindings[name] = binding
          else
            hidden_bindings[name] = binding
          end
        end

        methods[receiver_type] = public_bindings unless public_bindings.empty?
        private_methods[receiver_type] = hidden_bindings unless hidden_bindings.empty?
      end

      [methods, private_methods]
    end

    def exported_interface_implementations(analysis, exported_types, exported_interfaces)
      implemented_interfaces = {}
      private_implemented_interfaces = {}

      analysis.implemented_interfaces.each do |receiver_type, interfaces|
        public_interfaces = []
        hidden_interfaces = []

        interfaces.each do |interface|
          visible = exported_method_receiver?(receiver_type, analysis, exported_types) &&
            exported_interface_binding?(interface, analysis, exported_interfaces) &&
            exported_interface_methods?(receiver_type, interface, analysis, exported_types)
          if visible
            public_interfaces << interface
          else
            hidden_interfaces << interface
          end
        end

        implemented_interfaces[receiver_type] = public_interfaces.freeze unless public_interfaces.empty?
        private_implemented_interfaces[receiver_type] = hidden_interfaces.freeze unless hidden_interfaces.empty?
      end

      [implemented_interfaces.freeze, private_implemented_interfaces.freeze]
    end

    def exported_interface_methods?(receiver_type, interface, analysis, exported_types)
      return false unless exported_method_receiver?(receiver_type, analysis, exported_types)

      interface.methods.each_key.all? do |method_name|
        binding = analysis.methods.fetch(receiver_type, {})[method_name]
        binding && binding.ast.respond_to?(:visibility) && binding.ast.visibility == :public
      end
    end

    def exported_interface_binding?(interface, analysis, exported_interfaces)
      return true if exported_interfaces.value?(interface)

      imported_interface_binding?(interface, analysis.imports)
    end

    def exported_method_receiver?(receiver_type, analysis, exported_types)
      return true if receiver_type.is_a?(Types::StringView)
      return true if exported_types.value?(receiver_type)
      return true if imported_receiver_type?(receiver_type, analysis.imports)
      return exported_method_receiver?(receiver_type.base, analysis, exported_types) if receiver_type.is_a?(Types::Nullable)
      return receiver_type.arguments.all? { |argument| exported_method_receiver_argument?(argument, analysis, exported_types) } if receiver_type.is_a?(Types::GenericInstance)

      receiver_type.is_a?(Types::StructInstance) &&
        (exported_types.value?(receiver_type.definition) || imported_receiver_type?(receiver_type.definition, analysis.imports))
    end

    def exported_method_receiver_argument?(argument, analysis, exported_types)
      return true if argument.is_a?(Types::LiteralTypeArg)
      return true if argument.is_a?(Types::TypeVar)

      exported_method_receiver?(argument, analysis, exported_types)
    end

    def imported_receiver_type?(receiver_type, imports)
      imports.each_value do |module_binding|
        return true if module_binding.types.value?(receiver_type)
      end

      false
    end

    def imported_interface_binding?(interface, imports)
      imports.each_value do |module_binding|
        return true if module_binding.interfaces.value?(interface)
      end

      false
    end
  end
end

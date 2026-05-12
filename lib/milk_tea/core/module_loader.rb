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

    def self.load_file(path)
      new.load_file(path)
    end

    def self.check_file(path)
      new.check_file(path)
    end

    def self.check_program(path)
      new.check_program(path)
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
    def initialize(module_roots: [MilkTea.root], package_graph: nil, shared_cache: nil, source_overrides: nil)
      @module_roots = module_roots.map { |root| File.expand_path(root.to_s) }
      @ast_cache = {}
      @analysis_cache = {}
      @checking_paths = []
      @package_graph = package_graph
      @package_manifest_cache = {}
      @shared_cache = shared_cache # Hash or nil; mutated in-place to persist across calls
      @source_overrides = normalize_source_overrides(source_overrides)
    end

    def load_file(path)
      expanded_path = File.expand_path(path)
      @ast_cache[expanded_path] ||= parse_file(expanded_path)
    end

    def check_file(path)
      check_program(path).root_analysis
    end

    def check_program(path)
      root_path = File.expand_path(path)
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
    end

    def imported_modules_for_ast(ast, importer_path: nil)
      modules = ast.imports.each_with_object({}) do |import, modules_acc|
        import_path = resolve_module_path(import.path.to_s, importer_path:)
        import_analysis = check_path(import_path)
        modules_acc[import.path.to_s] = module_binding(import_analysis)
      end

      install_async_runtime_dependency!(ast, modules, importer_path:)
      modules
    end

    private

    def check_path(path)
      # 1. Instance-local cache (within a single check_program call, prevents re-entrant work)
      return @analysis_cache[path] if @analysis_cache.key?(path)

      # 2. Shared cross-request cache (owned by the LSP Workspace): reuse if the
      #    file has not changed on disk since it was last analyzed.
      if use_shared_cache?
        entry = @shared_cache[path]
        if entry
          current_mtime = File.mtime(path).to_f rescue nil
          if current_mtime && entry[:mtime] == current_mtime
            @analysis_cache[path] = entry[:analysis]
            return entry[:analysis]
          end
        end
      end

      if @checking_paths.include?(path)
        raise ModuleLoadError.new("cyclic import detected", path: path)
      end

      @checking_paths << path
      ast = load_file(path)
      imported_modules = imported_modules_for_ast(ast, importer_path: path)

      analysis = Sema.check(ast, imported_modules:)
      @analysis_cache[path] = analysis

      # Populate shared cache with current mtime so subsequent requests skip re-analysis.
      if use_shared_cache?
        mtime = File.mtime(path).to_f rescue nil
        @shared_cache[path] = { mtime: mtime, analysis: analysis } if mtime
      end

      analysis
    ensure
      @checking_paths.pop if @checking_paths.last == path
    end

    def parse_file(path)
      source = @source_overrides.fetch(path) { File.read(path) }
      Parser.parse(source, path: path)
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

    def use_shared_cache?
      @shared_cache && @source_overrides.empty?
    end

    def resolve_module_path(module_name, importer_path: nil)
      relative_path = File.join(*module_name.split(".")) + ".mt"
      blocked = false
      candidate = @module_roots.lazy.map { |root| File.join(root, relative_path) }.find do |path|
        next false unless File.file?(path)

        allowed = import_allowed?(module_name, importer_path, path)
        blocked ||= !allowed
        allowed
      end
      raise ModuleLoadError.new("package dependency not declared", path: module_name) if blocked
      raise ModuleLoadError.new("module not found", path: module_name) unless candidate

      File.expand_path(candidate)
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
      return true if analysis.module_kind == :extern_module
      return false unless declaration.respond_to?(:visibility)

      declaration.visibility == :public
    end

    def exported_methods(analysis, exported_types)
      if analysis.module_kind == :extern_module
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

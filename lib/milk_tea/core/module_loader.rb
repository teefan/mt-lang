# frozen_string_literal: true

require_relative "module_loader/errors"
require_relative "module_loader/resolution"
require_relative "module_loader/package_graph"
require_relative "module_loader/binding"
require_relative "module_loader/async_runtime"

module MilkTea
  class ModuleLoader
    Program = Data.define(:root_path, :root_analysis, :analyses_by_path, :analyses_by_module_name)
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
      when "darwin", "macos", "osx"
        :darwin
      else
        raise ArgumentError, "unknown platform #{value}; expected linux|windows|wasm|darwin"
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
      MilkTea.host_platform
    end

    def initialize(module_roots: [MilkTea.root], package_graph: nil, shared_cache: nil, source_overrides: nil, platform: nil)
      @module_roots = module_roots.map { |root| File.expand_path(root.to_s) }
      @ast_cache = {}
      @analysis_cache = {}
      @collecting_analysis_cache = {}
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
      modules = {}

      ast.imports.each do |import|
        import_path = resolve_module_path(import.path.to_s, importer_path:, importer_module_name: ast.module_name.to_s)
        import_analysis = check_path(import_path)
        modules[import.path.to_s] = module_binding(import_analysis)
      end

      install_async_runtime_dependency!(ast, modules, importer_path:, collecting_errors: false)
      modules.freeze
    end

    def imported_modules_for_ast_collecting_errors(ast, importer_path: nil)
      modules = {}
      errors = []

      ast.imports.each do |import|
        begin
          import_path = resolve_module_path(import.path.to_s, importer_path:, importer_module_name: ast.module_name.to_s)
          import_analysis = check_path_collecting_errors(import_path)
          modules[import.path.to_s] = module_binding(import_analysis)
        rescue ModuleLoadError, PackageLockError, SemaError => e
          errors << ImportResolutionError.new(import:, error: e)
        end
      end

      begin
        install_async_runtime_dependency!(ast, modules, importer_path:, collecting_errors: true)
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

    include Resolution
    include PackageGraph
    include Binding
    include AsyncRuntime

    def check_path(path)
      resolved_path = self.class.resolve_source_path(path, platform: @platform, error_class: ModuleLoadError)
      shared_cache_mtime = nil
      shared_cache_mtime_checked = false

      return @analysis_cache[resolved_path] if @analysis_cache.key?(resolved_path)

      if use_shared_cache?
        entry = @shared_cache[resolved_path]
        if entry
          shared_cache_mtime_checked = true
          shared_cache_mtime = File.mtime(resolved_path).to_f rescue nil
          if shared_cache_mtime && entry[:mtime] == shared_cache_mtime
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

      analysis = Sema.check(ast, imported_modules:, path: resolved_path)
      @analysis_cache[resolved_path] = analysis

      if use_shared_cache?
        mtime = if shared_cache_mtime_checked
                  shared_cache_mtime
                else
                  File.mtime(resolved_path).to_f rescue nil
                end
        @shared_cache[resolved_path] = { mtime: mtime, analysis: analysis } if mtime
      end

      analysis
    ensure
      @checking_paths.pop if @checking_paths.last == resolved_path
    end

    def check_path_collecting_errors(path)
      resolved_path = self.class.resolve_source_path(path, platform: @platform, error_class: ModuleLoadError)

      return @analysis_cache[resolved_path] if @analysis_cache.key?(resolved_path)
      return @collecting_analysis_cache[resolved_path] if @collecting_analysis_cache.key?(resolved_path)

      if use_shared_cache?
        entry = @shared_cache[resolved_path]
        if entry
          mtime = File.mtime(resolved_path).to_f rescue nil
          if mtime && entry[:mtime] == mtime
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
      imported_modules = imported_modules_for_ast_collecting_errors(ast, importer_path: resolved_path).modules
      result = Sema.check_collecting_errors(ast, imported_modules:, path: resolved_path)
      analysis = result[:analysis]
      raise(result[:errors].first || ModuleLoadError.new("module analysis unavailable", path: resolved_path)) unless analysis

      @collecting_analysis_cache[resolved_path] = analysis
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
  end
end

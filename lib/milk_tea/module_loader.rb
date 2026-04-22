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

    def initialize(module_roots: [MilkTea.root])
      @module_roots = module_roots.map { |root| File.expand_path(root.to_s) }
      @ast_cache = {}
      @analysis_cache = {}
      @checking_paths = []
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

    private

    def check_path(path)
      return @analysis_cache[path] if @analysis_cache.key?(path)

      if @checking_paths.include?(path)
        raise ModuleLoadError.new("cyclic import detected", path: path)
      end

      @checking_paths << path
      ast = load_file(path)
      imported_modules = ast.imports.each_with_object({}) do |import, modules|
        import_path = resolve_module_path(import.path.to_s)
        import_analysis = check_path(import_path)
        modules[import.path.to_s] = module_binding(import_analysis)
      end

      analysis = Sema.check(ast, imported_modules:)
      @analysis_cache[path] = analysis
    ensure
      @checking_paths.pop if @checking_paths.last == path
    end

    def parse_file(path)
      source = File.read(path)
      Parser.parse(source, path: path)
    rescue Errno::ENOENT
      raise ModuleLoadError.new("source file not found", path: path)
    rescue Errno::EISDIR
      raise ModuleLoadError.new("expected a source file, got a directory", path: path)
    end

    def resolve_module_path(module_name)
      relative_path = File.join(*module_name.split(".")) + ".mt"
      candidate = @module_roots.lazy.map { |root| File.join(root, relative_path) }.find { |path| File.file?(path) }
      raise ModuleLoadError.new("module not found", path: module_name) unless candidate

      File.expand_path(candidate)
    end

    def module_binding(analysis)
      types = {}
      values = {}
      functions = {}
      methods = analysis.methods.transform_values(&:dup)

      analysis.ast.declarations.each do |declaration|
        case declaration
        when AST::StructDecl, AST::UnionDecl, AST::EnumDecl, AST::FlagsDecl, AST::OpaqueDecl, AST::TypeAliasDecl
          types[declaration.name] = analysis.types.fetch(declaration.name)
        when AST::ConstDecl
          values[declaration.name] = analysis.values.fetch(declaration.name)
        when AST::FunctionDef, AST::ExternFunctionDecl
          functions[declaration.name] = analysis.functions.fetch(declaration.name)
        end
      end

      Sema::ModuleBinding.new(name: analysis.module_name, types:, values:, functions:, methods:)
    end
  end
end

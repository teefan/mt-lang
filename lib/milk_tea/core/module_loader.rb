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
      ensure_format_string_support_loaded!

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
      private_types = {}
      values = {}
      private_values = {}
      functions = {}
      private_functions = {}

      analysis.ast.declarations.each do |declaration|
        case declaration
        when AST::StructDecl, AST::UnionDecl, AST::EnumDecl, AST::FlagsDecl, AST::OpaqueDecl, AST::TypeAliasDecl
          target = exported_declaration?(analysis, declaration) ? types : private_types
          target[declaration.name] = analysis.types.fetch(declaration.name)
        when AST::ConstDecl, AST::VarDecl
          target = exported_declaration?(analysis, declaration) ? values : private_values
          target[declaration.name] = analysis.values.fetch(declaration.name)
        when AST::FunctionDef, AST::ExternFunctionDecl, AST::ForeignFunctionDecl
          target = exported_declaration?(analysis, declaration) ? functions : private_functions
          target[declaration.name] = analysis.functions.fetch(declaration.name)
        end
      end

      methods, private_methods = exported_methods(analysis, types)

      Sema::ModuleBinding.new(
        name: analysis.module_name,
        types:,
        values:,
        functions:,
        methods:,
        private_types:,
        private_values:,
        private_functions:,
        private_methods:,
      )
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
          visible = binding.ast.respond_to?(:visibility) && binding.ast.visibility == :public && exported_method_receiver?(receiver_type, exported_types)

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

    def exported_method_receiver?(receiver_type, exported_types)
      receiver_type.is_a?(Types::StringView) || exported_types.value?(receiver_type)
    end

    def ensure_format_string_support_loaded!
      return unless @ast_cache.each_value.any? { |ast| contains_format_string_node?(ast) }

      check_path(resolve_module_path("std.fmt"))
    end

    def contains_format_string_node?(node)
      case node
      when AST::FormatString
        true
      when Array
        node.any? { |entry| contains_format_string_node?(entry) }
      else
        return false unless node.respond_to?(:deconstruct_keys)

        node.deconstruct_keys(nil).values.any? { |value| contains_format_string_node?(value) }
      end
    end
  end
end

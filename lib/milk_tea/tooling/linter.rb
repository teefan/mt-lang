# frozen_string_literal: true

require "cgi/escape"
require "set"
require "uri"

module MilkTea
  class Linter
    BUILTIN_TYPE_STYLE_NAMES = %w[
      bool short ushort int uint long ulong ptr_int ptr_uint float double void str cstr
    ].to_set.freeze

    # severity: :error | :warning | :hint
    Warning = Data.define(:path, :line, :column, :length, :code, :message, :severity, :symbol_name) do
      def initialize(path:, line:, column: nil, length: nil, code:, message:, severity: :warning, symbol_name: nil) = super

      def to_diagnostic
        Diagnostic.new(path:, line:, column:, length:, code:, message:, severity:, symbol_name:)
      end
    end
    # binding_kind: :local | :param
    # allow_prefer_let: true only for `var` locals — flag prefer-let if never mutated
    # mutated: true if ever the target of a plain `=` or compound assignment
    Binding = Struct.new(
      :name, :line, :column, :used, :binding_kind, :allow_prefer_let, :mutated,
      keyword_init: true
    )

    def self.lint_source(source, path: nil, select: nil, ignore: nil, sema_analysis: nil, unresolved_import_paths: nil)
      context = nil
      if sema_analysis.nil? || unresolved_import_paths.nil?
        context = best_effort_lint_context(source, path:)
        sema_analysis ||= context[:analysis]
        unresolved_import_paths ||= context[:unresolved_import_paths]
      end

      ast = sema_analysis&.ast || context&.fetch(:ast, nil) || Parser.parse(source, path:)
      trivia = Lexer.lex_with_trivia(source, path:).trivia
      suppressions = parse_suppressions(trivia)
      warnings = new(path:, sema_analysis:, source:, unresolved_import_paths:).lint(ast)
      warnings = apply_suppressions(warnings, suppressions)

      # Layer in config-file defaults before per-call overrides
      if (cfg = load_config(path))
        select ||= cfg[:select]
        ignore ||= cfg[:ignore]
      end

      warnings = filter_by_rules(warnings, select:, ignore:)
      warnings
    end

    # Load the nearest .mt-lint.yml walking up from the source file's directory.
    # Returns Hash { select: Set|nil, ignore: Set|nil } or nil if no config found.
    def self.load_config(path)
      return nil unless path

      dir = File.directory?(path) ? path : File.dirname(path)
      # Walk up until we either find a config or leave the project
      100.times do
        candidate = File.join(dir, ".mt-lint.yml")
        if File.exist?(candidate)
          return parse_config_file(candidate)
        end
        parent = File.dirname(dir)
        break if parent == dir  # filesystem root

        dir = parent
      end
      nil
    rescue StandardError
      nil
    end

    def self.parse_config_file(path)
      require "yaml"
      raw = YAML.safe_load_file(path, symbolize_names: true) || {}
      result = {}
      if (s = raw[:select])
        result[:select] = Array(s).map(&:to_s).to_set
      end
      if (i = raw[:ignore])
        result[:ignore] = Array(i).map(&:to_s).to_set
      end
      result
    rescue StandardError
      {}
    end

    # Apply auto-fixable rules to source text.
    # Handles: prefer-let, redundant-else, redundant-unsafe.
    # Returns the fixed source (may be identical if nothing was fixable).
    def self.fix_source(source, path: nil, sema_analysis: nil)
      warnings = lint_source(source, path:, sema_analysis: sema_analysis || best_effort_sema_analysis(source, path:))
      lines = source.lines

      # prefer-let: simple var→let substitution on the declaration line
      prefer_let_fixes = warnings.select { |w| w.code == "prefer-let" && w.line }
      prefer_let_fixes.sort_by(&:line).each do |w|
        idx = w.line - 1
        next unless lines[idx]

        lines[idx] = lines[idx].sub(/\bvar\b/, "let")
      end

      # redundant-else: for each warning, find the `else:` line above, delete it,
      # and dedent the else body by one indent level.
      # Process in reverse line order to keep indices stable.
      redundant_else_fixes = warnings.select { |w| w.code == "redundant-else" && w.line }
      redundant_else_fixes.sort_by(&:line).reverse_each do |w|
        else_idx = w.line - 1   # 0-based index of the `else:` line
        next unless lines[else_idx]&.match?(/\A\s*else:\s*\z/)

        else_indent  = lines[else_idx].match(/\A(\s*)/)[1]
        body_indent  = else_indent + "    "   # one additional 4-space indent level
        first_body_idx = else_idx + 1

        # Find extent of the else body: all consecutive lines that are blank or indented >= body_indent
        body_end_idx = first_body_idx - 1
        (first_body_idx...lines.length).each do |i|
          l = lines[i]
          if l.chomp.empty? || l.start_with?(body_indent)
            body_end_idx = i
          else
            break
          end
        end

        # Dedent the body lines by 4 spaces
        (first_body_idx..body_end_idx).each do |i|
          lines[i] = lines[i].sub(/\A    /, "") if lines[i]
        end

        # Delete the `else:` line
        lines.delete_at(else_idx)
      end

      # redundant-unsafe: delete the `unsafe:` line and dedent the block body.
      redundant_unsafe_fixes = warnings.select { |w| w.code == "redundant-unsafe" && w.line }
      redundant_unsafe_fixes.sort_by(&:line).reverse_each do |w|
        unsafe_idx = w.line - 1
        next unless lines[unsafe_idx]&.match?(/\A\s*unsafe:\s*\z/)

        unsafe_indent = lines[unsafe_idx].match(/\A(\s*)/)[1]
        body_indent = unsafe_indent + "    "
        first_body_idx = unsafe_idx + 1
        next if first_body_idx >= lines.length

        body_end_idx = first_body_idx - 1
        (first_body_idx...lines.length).each do |i|
          line = lines[i]
          if line.chomp.empty? || line.start_with?(body_indent)
            body_end_idx = i
          else
            break
          end
        end

        next if body_end_idx < first_body_idx

        (first_body_idx..body_end_idx).each do |i|
          lines[i] = lines[i].sub(/\A    /, "") if lines[i]
        end

        lines.delete_at(unsafe_idx)
      end

      # unused-import: delete the import line entirely.
      # Process in reverse order to keep indices stable after deletions.
      import_fixes = warnings.select { |w| w.code == "unused-import" && w.line }
      import_fixes.sort_by(&:line).reverse_each do |w|
        idx = w.line - 1
        lines.delete_at(idx) if lines[idx]&.match?(/\A\s*import\b/)
      end

      # dead-assignment: delete dead plain assignment statements.
      # Declaration initializers are intentionally not auto-fixed.
      dead_fixes = warnings.select { |w| w.code == "dead-assignment" && w.line }
      dead_fixes.sort_by(&:line).reverse_each do |w|
        idx = w.line - 1
        next unless lines[idx]
        # Only delete if it looks like a plain assignment (not let/var declaration)
        next if lines[idx].match?(/\A\s*(let|var)\b/)

        lines.delete_at(idx)
      end

      lines.join
    end

    def self.best_effort_lint_context(source, path: nil)
      ast = Parser.parse(source, path:)
      imported_modules = {}
      unresolved_import_paths = Set.new

      resolved_path = resolve_lint_path(path)
      if resolved_path && File.file?(resolved_path)
        loader = ModuleLoader.new(
          module_roots: MilkTea::ModuleRoots.roots_for_path(resolved_path),
          package_graph: load_lint_package_graph(resolved_path),
          source_overrides: { resolved_path => source },
        )
        ast = loader.load_file(resolved_path)
        resolution = loader.imported_modules_for_ast_collecting_errors(ast, importer_path: resolved_path)
        imported_modules = resolution.modules
        unresolved_import_paths.merge(resolution.errors.filter_map { |entry| entry.import&.path&.to_s })
      end

      {
        ast: ast,
        analysis: Sema.check_collecting_errors(ast, imported_modules: imported_modules)[:analysis],
        unresolved_import_paths: unresolved_import_paths,
      }
    rescue StandardError
      { ast: nil, analysis: nil, unresolved_import_paths: Set.new }
    end

    def self.best_effort_sema_analysis(source, path: nil)
      best_effort_lint_context(source, path:).fetch(:analysis)
    end

    def self.resolve_lint_path(path)
      return nil unless path.is_a?(String) && !path.empty?

      if path.start_with?("file://")
        CGI.unescape(URI.parse(path).path)
      else
        File.expand_path(path)
      end
    rescue StandardError
      nil
    end

    def self.load_lint_package_graph(path)
      PackageGraph.load(path)
    rescue PackageManifestError, PackageLockError
      nil
    end

    # Parse `# lint: ignore` / `# lint: ignore(rule1, rule2)` comments.
    # Returns Hash { line_number => Set<code> | :all }
    def self.parse_suppressions(trivia)
      result = {}
      trivia.select { |t| t.kind == :comment }.each do |t|
        text = t.text.strip
        if (m = text.match(/\A#\s*lint:\s*ignore\(([^)]+)\)\z/))
          codes = m[1].split(",").map(&:strip).to_set
          result[t.line] = codes
        elsif text.match(/\A#\s*lint:\s*ignore\z/)
          result[t.line] = :all
        end
      end
      result
    end

    def self.apply_suppressions(warnings, suppressions)
      return warnings if suppressions.empty?

      warnings.reject do |w|
        next false unless w.line
        # Suppression on same line (trailing) or preceding line (leading comment)
        [w.line, w.line - 1].any? do |check_line|
          entry = suppressions[check_line]
          entry == :all || (entry.is_a?(Set) && entry.include?(w.code))
        end
      end
    end

    def self.filter_by_rules(warnings, select:, ignore:)
      warnings = warnings.select { |w| select.include?(w.code) } if select
      warnings = warnings.reject { |w| ignore.include?(w.code) } if ignore
      warnings
    end

    def initialize(path: nil, sema_analysis: nil, source: nil, unresolved_import_paths: nil)
      @path = path
      @sema_analysis = sema_analysis
      @unresolved_import_paths = (unresolved_import_paths || Set.new).to_set
      @source_lines = source ? source.lines.map { |line| line.delete_suffix("\n") } : []
      @warnings = []
      @scopes = []
    end

    def lint(ast)
      visit_source_file(ast)
      @warnings
    end

    private

    def visit_source_file(source_file)
      check_unused_imports(source_file)
      check_platform_api_drift(source_file)
      source_file.declarations.each do |declaration|
        case declaration
        when AST::FunctionDef, AST::MethodDef
          warn_builtin_type_style_name(declaration.name, line: declaration.line, column: declaration.column, kind_label: "function")
          visit_function(declaration)
        when AST::MethodsBlock
          declaration.methods.each do |method|
            warn_builtin_type_style_name(method.name, line: method.line, column: method.column, kind_label: "function")
            visit_function(method)
          end
        when AST::ExternFunctionDecl, AST::ForeignFunctionDecl
          warn_builtin_type_style_name(declaration.name, line: declaration.line, column: declaration_column(declaration), kind_label: "function")
        when AST::ConstDecl
          warn_builtin_type_style_name(declaration.name, line: declaration.line, column: declaration_column(declaration), kind_label: "constant")
        when AST::VarDecl
          warn_builtin_type_style_name(declaration.name, line: declaration.line, column: declaration_column(declaration), kind_label: "module variable")
        end
      end
    end

    # ── unused-import ────────────────────────────────────────────────────

    def check_unused_imports(source_file)
      return if source_file.imports.empty?

      used = collect_used_names(source_file)
      used.merge(collect_method_only_import_uses(source_file))
      source_file.imports.each do |import|
        next if @unresolved_import_paths.include?(import.path.to_s)

        local_name = import.alias_name || import.path.parts.last
        next if ignored_binding_name?(local_name)
        next if used.include?(local_name)

        @warnings << Warning.new(
          path: @path,
          line: import.line,
          column: import.column,
          length: import.length,
          code: "unused-import",
          message: "unused import '#{local_name}'",
          symbol_name: local_name
        )
      end
    end

    def check_platform_api_drift(source_file)
      resolved_path = self.class.resolve_lint_path(@path)
      return unless resolved_path&.end_with?(".mt")

      sibling_paths = platform_variant_sibling_paths(resolved_path)
      return if sibling_paths.empty?

      current_surface = exported_api_surface(source_file)
      sibling_paths.each do |sibling_path|
        sibling_source_file = load_sibling_source_file(sibling_path)
        next unless sibling_source_file
        next unless sibling_source_file.module_name.to_s == source_file.module_name.to_s

        sibling_surface = exported_api_surface(sibling_source_file)
        next if sibling_surface == current_surface

        missing = (sibling_surface - current_surface).to_a.sort
        extra = (current_surface - sibling_surface).to_a.sort
        @warnings << Warning.new(
          path: @path,
          line: source_file.line || 1,
          column: 1,
          length: 1,
          code: "platform-api-drift",
          message: platform_api_drift_message(sibling_path, missing:, extra:)
        )
      end
    end

    def platform_variant_sibling_paths(path)
      current_platform = ModuleLoader.platform_suffix_for_path(path)
      shared_path = if current_platform
        path.sub(/\.#{Regexp.escape(current_platform.to_s)}\.mt\z/, ".mt")
      else
        path
      end

      [
        shared_path,
        *ModuleLoader::PLATFORM_SUFFIXES.keys.map { |platform_name| shared_path.delete_suffix(".mt") + ".#{platform_name}.mt" }
      ].uniq.select { |candidate| candidate != path && File.file?(candidate) }
    end

    def load_sibling_source_file(path)
      ModuleLoader.load_file(path)
    rescue StandardError
      nil
    end

    def exported_api_surface(source_file)
      exported_type_names = exported_type_names(source_file)
      source_file.declarations.each_with_object(Set.new) do |declaration, surface|
        case declaration
        when AST::ConstDecl
          surface << render_value_surface("const", declaration) if exported_declaration?(source_file, declaration)
        when AST::VarDecl
          surface << render_value_surface("var", declaration) if exported_declaration?(source_file, declaration)
        when AST::TypeAliasDecl
          surface << "type #{declaration.name} = #{render_type_surface(declaration.target)}" if exported_declaration?(source_file, declaration)
        when AST::StructDecl
          surface << render_struct_surface(declaration) if exported_declaration?(source_file, declaration)
        when AST::UnionDecl
          surface << render_union_surface(declaration) if exported_declaration?(source_file, declaration)
        when AST::EnumDecl
          surface << render_enum_surface("enum", declaration) if exported_declaration?(source_file, declaration)
        when AST::FlagsDecl
          surface << render_enum_surface("flags", declaration) if exported_declaration?(source_file, declaration)
        when AST::OpaqueDecl
          surface << render_opaque_surface(declaration) if exported_declaration?(source_file, declaration)
        when AST::InterfaceDecl
          surface << render_interface_surface(declaration) if exported_declaration?(source_file, declaration)
        when AST::VariantDecl
          surface << render_variant_surface(declaration) if exported_declaration?(source_file, declaration)
        when AST::FunctionDef
          surface << render_callable_surface("function", declaration) if exported_declaration?(source_file, declaration)
        when AST::ExternFunctionDecl
          surface << render_callable_surface("external function", declaration, variadic: declaration.variadic) if exported_declaration?(source_file, declaration)
        when AST::ForeignFunctionDecl
          surface << render_callable_surface("foreign function", declaration, variadic: declaration.variadic) if exported_declaration?(source_file, declaration)
        when AST::MethodsBlock
          next unless exported_type_names.include?(declaration.type_name.to_s)

          declaration.methods.each do |method|
            next unless method.visibility == :public

            surface << render_method_surface(declaration.type_name.to_s, method)
          end
        end
      end
    end

    def exported_type_names(source_file)
      source_file.declarations.each_with_object(Set.new) do |declaration, names|
        next unless declaration.respond_to?(:name)
        next unless declaration.is_a?(AST::TypeAliasDecl) || declaration.is_a?(AST::StructDecl) ||
                    declaration.is_a?(AST::UnionDecl) || declaration.is_a?(AST::EnumDecl) ||
                    declaration.is_a?(AST::FlagsDecl) || declaration.is_a?(AST::OpaqueDecl) ||
                    declaration.is_a?(AST::InterfaceDecl) || declaration.is_a?(AST::VariantDecl)
        next unless exported_declaration?(source_file, declaration)

        names << declaration.name
      end
    end

    def exported_declaration?(source_file, declaration)
      return true if source_file.module_kind == :raw_module

      declaration.respond_to?(:visibility) && declaration.visibility == :public
    end

    def render_value_surface(kind, declaration)
      return "#{kind} #{declaration.name}" unless declaration.type

      "#{kind} #{declaration.name}: #{render_type_surface(declaration.type)}"
    end

    def render_struct_surface(declaration)
      prefix = declaration.packed ? "packed struct" : "struct"
      suffix = declaration.alignment ? " align(#{declaration.alignment})" : ""
      "#{prefix} #{declaration.name}#{render_type_params_surface(declaration.type_params)}#{render_implements_surface(declaration.implements)}#{suffix} { #{render_fields_surface(declaration.fields)} }"
    end

    def render_union_surface(declaration)
      "union #{declaration.name} { #{render_fields_surface(declaration.fields)} }"
    end

    def render_enum_surface(kind, declaration)
      members = declaration.members.map(&:name).join(", ")
      "#{kind} #{declaration.name}: #{render_type_surface(declaration.backing_type)} { #{members} }"
    end

    def render_opaque_surface(declaration)
      "opaque #{declaration.name}#{render_implements_surface(declaration.implements)}"
    end

    def render_interface_surface(declaration)
      methods = declaration.methods.map { |method| render_interface_method_surface(declaration.name, method) }.sort.join(", ")
      "interface #{declaration.name} { #{methods} }"
    end

    def render_variant_surface(declaration)
      arms = declaration.arms.map { |arm| render_variant_arm_surface(arm) }.join(", ")
      "variant #{declaration.name}#{render_type_params_surface(declaration.type_params)} { #{arms} }"
    end

    def render_variant_arm_surface(arm)
      return arm.name if arm.fields.empty?

      "#{arm.name}(#{arm.fields.map { |field| render_type_surface(field.respond_to?(:type) ? field.type : field) }.join(', ')})"
    end

    def render_method_surface(receiver_name, declaration)
      prefix = declaration.kind == :static ? "static method" : "method"
      render_callable_surface("#{prefix} #{receiver_name}.", declaration, name_prefix: "")
    end

    def render_interface_method_surface(interface_name, declaration)
      render_callable_surface("interface method #{interface_name}.", declaration, name_prefix: "")
    end

    def render_callable_surface(kind, declaration, variadic: false, name_prefix: nil)
      params = declaration.params.map { |param| render_param_surface(param) }
      params << "..." if variadic
      text = +""
      text << "async " if declaration.respond_to?(:async) && declaration.async
      text << kind
      text << (name_prefix.nil? ? " #{declaration.name}" : "#{name_prefix}#{declaration.name}")
      text << render_type_params_surface(declaration.respond_to?(:type_params) ? declaration.type_params : [])
      text << "(#{params.join(', ')})"
      text << " -> #{render_type_surface(declaration.return_type)}" if declaration.return_type
      text
    end

    def render_fields_surface(fields)
      fields.map { |field| "#{field.name}: #{render_type_surface(field.type)}" }.join(", ")
    end

    def render_param_surface(param)
      if param.respond_to?(:boundary_type) && param.boundary_type
        return "#{param.name}: #{render_type_surface(param.type)} as #{render_type_surface(param.boundary_type)}"
      end

      return param.name unless param.respond_to?(:type) && param.type

      "#{param.name}: #{render_type_surface(param.type)}"
    end

    def render_type_surface(type)
      case type
      when AST::TypeRef
        text = type.name.to_s
        unless type.arguments.empty?
          text += "[#{type.arguments.map { |argument| render_type_argument_surface(argument.value) }.join(', ')}]"
        end
        type.nullable ? "#{text}?" : text
      when AST::FunctionType
        "fn(#{type.params.map { |param| render_param_surface(param) }.join(', ')}) -> #{render_type_surface(type.return_type)}"
      when AST::ProcType
        "proc(#{type.params.map { |param| render_param_surface(param) }.join(', ')}) -> #{render_type_surface(type.return_type)}"
      else
        type.to_s
      end
    end

    def render_type_argument_surface(argument)
      case argument
      when AST::IntegerLiteral, AST::FloatLiteral
        argument.lexeme
      else
        render_type_surface(argument)
      end
    end

    def render_type_params_surface(type_params)
      return "" if type_params.nil? || type_params.empty?

      rendered = type_params.map do |type_param|
        next type_param.name if type_param.constraints.empty?

        "#{type_param.name} #{render_type_param_constraints_surface(type_param.constraints)}"
      end
      "[#{rendered.join(', ')}]"
    end

    def render_type_param_constraints_surface(constraints)
      parts = []
      index = 0
      while index < constraints.length
        constraint = constraints[index]
        if constraint.kind == :interface
          interfaces = [constraint.interface_ref.to_s]
          index += 1
          while index < constraints.length && constraints[index].kind == :interface
            interfaces << constraints[index].interface_ref.to_s
            index += 1
          end
          parts << "implements #{interfaces.join(' and ')}"
        else
          parts << case constraint.kind
                   when :defaults then "defaults"
                   when :hashes then "hashes"
                   when :equates then "equates"
                   else
                     raise "unsupported type parameter constraint #{constraint.kind}"
                   end
          index += 1
        end
      end

      parts.join(" and ")
    end

    def render_implements_surface(implements)
      return "" if implements.nil? || implements.empty?

      " implements #{implements.map(&:to_s).sort.join(', ')}"
    end

    def platform_api_drift_message(sibling_path, missing:, extra:)
      parts = []
      parts << "missing #{summarize_platform_surface_entries(missing)}" unless missing.empty?
      parts << "extra #{summarize_platform_surface_entries(extra)}" unless extra.empty?
      "public API differs from #{File.basename(sibling_path)}: #{parts.join('; ')}"
    end

    def summarize_platform_surface_entries(entries, limit: 2)
      shown = entries.first(limit).map { |entry| "'#{entry}'" }
      remaining = entries.length - shown.length
      return shown.join(", ") if remaining <= 0

      "#{shown.join(', ')} (+#{remaining} more)"
    end

    # Returns a Set of every "root name" referenced in expressions and type
    # positions across all declarations.  Import usage is determined by checking
    # whether the import's local binding name appears as such a root name.
    def collect_used_names(source_file)
      used = Set.new
      source_file.declarations.each do |decl|
        collect_names_from_declaration(decl, used)
      end
      used
    end

    def collect_method_only_import_uses(source_file)
      return Set.new unless @sema_analysis

      called_members = Set.new
      source_file.declarations.each do |decl|
        collect_called_members_from_declaration(decl, called_members)
      end
      return Set.new if called_members.empty?

      @sema_analysis.imports.each_with_object(Set.new) do |(local_name, imported_module), used|
        method_names = imported_module.methods.each_value.each_with_object(Set.new) do |bindings, names|
          names.merge(bindings.keys)
        end
        used << local_name unless (called_members & method_names).empty?
      end
    end

    def collect_names_from_declaration(decl, used)
      case decl
      when AST::FunctionDef, AST::MethodDef
        decl.params.each { |p| collect_names_from_type(p.type, used) if p.respond_to?(:type) && p.type }
        collect_names_from_type(decl.return_type, used) if decl.return_type
        decl.body.each { |stmt| collect_names_from_statement(stmt, used) }
      when AST::MethodsBlock
        decl.methods.each { |m| collect_names_from_declaration(m, used) }
      when AST::StructDecl
        decl.fields.each { |f| collect_names_from_type(f.type, used) }
      when AST::UnionDecl
        decl.fields.each { |f| collect_names_from_type(f.type, used) }
      when AST::TypeAliasDecl
        collect_names_from_type(decl.target, used)
      when AST::ConstDecl, AST::VarDecl
        collect_names_from_type(decl.type, used) if decl.type
        collect_names_from_expr(decl.value, used) if decl.value
      when AST::ExternFunctionDecl
        decl.params.each { |p| collect_names_from_type(p.type, used) if p.respond_to?(:type) && p.type }
        collect_names_from_type(decl.return_type, used) if decl.return_type
      when AST::ForeignFunctionDecl
        decl.params.each { |p| collect_names_from_type(p.type, used) if p.respond_to?(:type) && p.type }
        collect_names_from_type(decl.return_type, used) if decl.return_type
        collect_names_from_expr(decl.mapping, used) if decl.mapping
      end
    end

    def collect_names_from_statement(stmt, used)
      case stmt
      when AST::LocalDecl
        collect_names_from_type(stmt.type, used) if stmt.type
        collect_names_from_expr(stmt.value, used) if stmt.value
      when AST::Assignment
        collect_names_from_expr(stmt.target, used)
        collect_names_from_expr(stmt.value, used)
      when AST::IfStmt
        stmt.branches.each do |b|
          collect_names_from_expr(b.condition, used)
          b.body.each { |s| collect_names_from_statement(s, used) }
        end
        stmt.else_body&.each { |s| collect_names_from_statement(s, used) }
      when AST::MatchStmt
        collect_names_from_expr(stmt.expression, used)
        stmt.arms.each do |arm|
          collect_names_from_expr(arm.pattern, used)
          arm.body.each { |s| collect_names_from_statement(s, used) }
        end
      when AST::ForStmt
        stmt.iterables.each { |iterable| collect_names_from_expr(iterable, used) }
        stmt.body.each { |s| collect_names_from_statement(s, used) }
      when AST::WhileStmt
        collect_names_from_expr(stmt.condition, used)
        stmt.body.each { |s| collect_names_from_statement(s, used) }
      when AST::UnsafeStmt
        stmt.body.each { |s| collect_names_from_statement(s, used) }
      when AST::DeferStmt
        collect_names_from_expr(stmt.expression, used) if stmt.expression
        stmt.body&.each { |s| collect_names_from_statement(s, used) }
      when AST::ReturnStmt
        collect_names_from_expr(stmt.value, used) if stmt.value
      when AST::ExpressionStmt
        collect_names_from_expr(stmt.expression, used)
      when AST::StaticAssert
        collect_names_from_expr(stmt.condition, used)
      end
    end

    def collect_names_from_expr(expr, used)
      case expr
      when nil then nil
      when AST::Identifier then used << expr.name
      when AST::MemberAccess then collect_names_from_expr(expr.receiver, used)
      when AST::IndexAccess
        collect_names_from_expr(expr.receiver, used)
        collect_names_from_expr(expr.index, used)
      when AST::Specialization
        collect_names_from_expr(expr.callee, used)
      when AST::Call
        collect_names_from_expr(expr.callee, used)
        expr.arguments.each { |arg| collect_names_from_expr(arg.value, used) }
      when AST::UnaryOp then collect_names_from_expr(expr.operand, used)
      when AST::BinaryOp
        collect_names_from_expr(expr.left, used)
        collect_names_from_expr(expr.right, used)
      when AST::RangeExpr
        collect_names_from_expr(expr.start_expr, used)
        collect_names_from_expr(expr.end_expr, used)
      when AST::ExpressionList
        expr.elements.each { |e| collect_names_from_expr(e, used) }
      when AST::IfExpr
        collect_names_from_expr(expr.condition, used)
        collect_names_from_expr(expr.then_expression, used)
        collect_names_from_expr(expr.else_expression, used)
      when AST::ProcExpr
        expr.params.each { |p| collect_names_from_type(p.type, used) if p.respond_to?(:type) && p.type }
        expr.body.each { |s| collect_names_from_statement(s, used) }
      when AST::AwaitExpr then collect_names_from_expr(expr.expression, used)
      when AST::UnsafeExpr then collect_names_from_expr(expr.expression, used)
      when AST::FormatString
        expr.parts.each { |p| collect_names_from_expr(p.expression, used) if p.is_a?(AST::FormatExprPart) }
      end
    end

    def collect_names_from_type(type, used)
      case type
      when nil then nil
      when AST::TypeRef
        # Record the root module/alias name (first part of qualified name)
        used << type.name.parts.first if type.name.respond_to?(:parts) && type.name.parts.any?
        type.arguments.each { |arg| collect_names_from_type(arg.value, used) }
      when AST::FunctionType, AST::ProcType
        type.params.each { |p| collect_names_from_type(p.respond_to?(:type) ? p.type : p, used) }
        collect_names_from_type(type.return_type, used) if type.return_type
      end
    end

    def collect_called_members_from_declaration(decl, called_members)
      case decl
      when AST::FunctionDef, AST::MethodDef
        decl.body.each { |stmt| collect_called_members_from_statement(stmt, called_members) }
      when AST::MethodsBlock
        decl.methods.each { |method| collect_called_members_from_declaration(method, called_members) }
      when AST::ConstDecl, AST::VarDecl
        collect_called_members_from_expr(decl.value, called_members) if decl.value
      end
    end

    def collect_called_members_from_statement(stmt, called_members)
      case stmt
      when AST::LocalDecl
        collect_called_members_from_expr(stmt.value, called_members) if stmt.value
      when AST::Assignment
        collect_called_members_from_expr(stmt.target, called_members)
        collect_called_members_from_expr(stmt.value, called_members)
      when AST::IfStmt
        stmt.branches.each do |branch|
          collect_called_members_from_expr(branch.condition, called_members)
          branch.body.each { |child| collect_called_members_from_statement(child, called_members) }
        end
        stmt.else_body&.each { |child| collect_called_members_from_statement(child, called_members) }
      when AST::MatchStmt
        collect_called_members_from_expr(stmt.expression, called_members)
        stmt.arms.each { |arm| arm.body.each { |child| collect_called_members_from_statement(child, called_members) } }
      when AST::ForStmt
        stmt.iterables.each { |iterable| collect_called_members_from_expr(iterable, called_members) }
        stmt.body.each { |child| collect_called_members_from_statement(child, called_members) }
      when AST::WhileStmt
        collect_called_members_from_expr(stmt.condition, called_members)
        stmt.body.each { |child| collect_called_members_from_statement(child, called_members) }
      when AST::UnsafeStmt
        stmt.body.each { |child| collect_called_members_from_statement(child, called_members) }
      when AST::DeferStmt
        collect_called_members_from_expr(stmt.expression, called_members) if stmt.expression
        stmt.body&.each { |child| collect_called_members_from_statement(child, called_members) }
      when AST::ReturnStmt
        collect_called_members_from_expr(stmt.value, called_members) if stmt.value
      when AST::ExpressionStmt
        collect_called_members_from_expr(stmt.expression, called_members)
      when AST::StaticAssert
        collect_called_members_from_expr(stmt.condition, called_members)
      end
    end

    def collect_called_members_from_expr(expr, called_members)
      case expr
      when nil then nil
      when AST::MemberAccess
        collect_called_members_from_expr(expr.receiver, called_members)
      when AST::IndexAccess
        collect_called_members_from_expr(expr.receiver, called_members)
        collect_called_members_from_expr(expr.index, called_members)
      when AST::Specialization
        collect_called_members_from_expr(expr.callee, called_members)
      when AST::Call
        called_members << expr.callee.member if expr.callee.is_a?(AST::MemberAccess)
        collect_called_members_from_expr(expr.callee, called_members)
        expr.arguments.each { |argument| collect_called_members_from_expr(argument.value, called_members) }
      when AST::UnaryOp
        collect_called_members_from_expr(expr.operand, called_members)
      when AST::BinaryOp
        collect_called_members_from_expr(expr.left, called_members)
        collect_called_members_from_expr(expr.right, called_members)
      when AST::RangeExpr
        collect_called_members_from_expr(expr.start_expr, called_members)
        collect_called_members_from_expr(expr.end_expr, called_members)
      when AST::ExpressionList
        expr.elements.each { |element| collect_called_members_from_expr(element, called_members) }
      when AST::IfExpr
        collect_called_members_from_expr(expr.condition, called_members)
        collect_called_members_from_expr(expr.then_expression, called_members)
        collect_called_members_from_expr(expr.else_expression, called_members)
      when AST::ProcExpr
        expr.body.each { |stmt| collect_called_members_from_statement(stmt, called_members) }
      when AST::AwaitExpr
        collect_called_members_from_expr(expr.expression, called_members)
      when AST::UnsafeExpr
        collect_called_members_from_expr(expr.expression, called_members)
      when AST::FormatString
        expr.parts.each { |part| collect_called_members_from_expr(part.expression, called_members) if part.is_a?(AST::FormatExprPart) }
      end
    end

    def visit_function(function)
      with_scope do
        function.params.each do |param|
          declare_param(
            param.name,
            line: param_line(param, fallback: function.line),
            column: param_column(param)
          )
        end
        visit_statement_list(function.body)
        emit_dead_assignment_warnings(function.body)
        emit_unreachable_warnings(function.body)
        emit_borrow_warnings(function.body)
        emit_constant_condition_warnings(function.body)
        emit_redundant_null_check_warnings(function.body)
        emit_redundant_unsafe_warnings(function.body)
        emit_loop_single_iteration_warnings(function.body)
      end
      check_missing_return(function)
    end

    # ── missing-return ───────────────────────────────────────────────────

    def check_missing_return(function)
      return unless function.return_type           # implicit void — no check
      return if void_return_type?(function.return_type)
      return if always_returns?(function.body)

      @warnings << Warning.new(
        path: @path,
        line: function.line,
        column: function.respond_to?(:column) ? function.column : nil,
        length: function.name.length,
        code: "missing-return",
        message: "function '#{function.name}' does not always return a value",
        severity: :error,
        symbol_name: function.name
      )
    end

    def void_return_type?(return_type)
      case return_type
      when AST::TypeRef
        name = return_type.name
        name.is_a?(AST::QualifiedName) && name.parts == ["void"]
      when Types::Primitive
        return_type.name == "void"
      else
        false
      end
    end

    # Returns true if every execution path through `stmts` ends with a
    # guaranteed return.  Conservative: only IfStmt with else + MatchStmt
    # with arms are considered exhaustive.
    def always_returns?(stmts)
      stmts.any? do |stmt|
        case stmt
        when AST::ReturnStmt
          true
        when AST::ExpressionStmt
          terminating_expression?(stmt.expression)
        when AST::IfStmt
          # Only exhaustive if there is an else branch AND every branch returns
          stmt.else_body && !stmt.else_body.empty? &&
            stmt.branches.all? { |b| always_returns?(b.body) } &&
            always_returns?(stmt.else_body)
        when AST::WhileStmt
          infinite_while_without_break?(stmt)
        when AST::MatchStmt
          stmt.arms.any? && stmt.arms.all? { |arm| always_returns?(arm.body) }
        when AST::UnsafeStmt
          always_returns?(stmt.body)
        else
          false
        end
      end
    end

    def infinite_while_without_break?(stmt)
      stmt.condition.is_a?(AST::BooleanLiteral) &&
        stmt.condition.value == true &&
        !loop_body_can_break?(stmt.body)
    end

    def loop_body_can_break?(body)
      return false if body.nil? || body.empty?

      graph = CFG::Builder.new.build_loop_body(body)
      reachability = CFG::Reachability.solve(graph)
      graph.each_node.any? do |node|
        node.kind == :break_exit && reachability.reachable_ids.include?(node.id)
      end
    end

    def terminating_expression?(expression)
      case expression
      when AST::Call
        terminating_callee?(expression.callee)
      when AST::Specialization
        terminating_callee?(expression.callee)
      else
        false
      end
    end

    def terminating_callee?(callee)
      case callee
      when AST::Identifier
        callee.name == "fatal"
      when AST::Specialization
        terminating_callee?(callee.callee)
      else
        false
      end
    end

    # ── redundant-else ───────────────────────────────────────────────────
    # Fire when every explicit if/elif branch always returns, making the else
    # block an unnecessary level of indentation.
    def check_redundant_else(stmt)
      return unless stmt.else_body && !stmt.else_body.empty?
      return unless stmt.branches.all? { |b| always_returns?(b.body) }

      # Use the line of the first else-body statement as the diagnostic anchor.
      else_line = stmt.else_body.first.respond_to?(:line) ? stmt.else_body.first.line : stmt.line
      @warnings << Warning.new(
        path: @path,
        line: stmt.else_line || else_line,
        column: stmt.else_column,
        length: 4,
        code: "redundant-else",
        message: "else block is redundant because all preceding branches return"
      )
    end

    # ── useless-expression ───────────────────────────────────────────────────

    PURE_EXPRESSION_TYPES = [
      AST::IntegerLiteral, AST::FloatLiteral, AST::StringLiteral, AST::FormatString,
      AST::BooleanLiteral, AST::NullLiteral,
      AST::BinaryOp, AST::UnaryOp,
      AST::Identifier, AST::UnsafeExpr,
    ].freeze

    def check_useless_expression(stmt)
      expr = stmt.expression
      return unless PURE_EXPRESSION_TYPES.any? { |t| expr.is_a?(t) }

      line = expression_line(expr) || (stmt.respond_to?(:line) ? stmt.line : nil)
      column = expression_column(expr)
      length = expression_length(expr)
      if line && (!column || !length || !expr.respond_to?(:column) || expr.is_a?(AST::UnsafeExpr))
        fallback_span = source_statement_span(line)
        column ||= fallback_span&.first
        length = fallback_span&.last if !length || !expr.respond_to?(:column) || expr.is_a?(AST::UnsafeExpr)
      end

      @warnings << Warning.new(
        path: @path,
        line:,
        column:,
        length:,
        code: "useless-expression",
        message: "expression result is unused and has no side effects",
        severity: :warning
      )
    end

    # Visits a list of statements in sequence for lint rules.
    # Statements after a guaranteed terminator are skipped to avoid cascading
    # false-positive unused/dead warnings on unreachable code.
    # CFG-based emit_unreachable_warnings handles the actual diagnostic.
    def visit_statement_list(stmts)
      terminated = false
      stmts.each do |stmt|
        next if terminated  # skip visitation only; CFG emits the warning

        visit_statement(stmt)
        terminated = true if terminator?(stmt)
      end
    end

    def terminator?(stmt)
      stmt.is_a?(AST::ReturnStmt) || stmt.is_a?(AST::BreakStmt) || stmt.is_a?(AST::ContinueStmt)
    end

    def visit_statement(statement)
      case statement
      when AST::LocalDecl
        visit_expression(statement.value) if statement.value
        declare_local(
          statement.name,
          statement.line,
          column: statement.column,
          var: statement.kind == :var
        )
      when AST::Assignment
        visit_expression(statement.value)          # visit RHS first — reads in RHS count against dead-assignment
        mark_assignment_target_reads(statement.target, statement.operator) # compound: marks target as read
        visit_assignment_target(statement.target)  # non-identifier sub-expressions in target
        mark_mutated(statement.target)
        check_self_assignment(statement)
      when AST::IfStmt
        statement.branches.each do |branch|
          visit_expression(branch.condition)
          with_scope { visit_statement_list(branch.body) }
        end
        with_scope { visit_statement_list(statement.else_body) } if statement.else_body
        check_redundant_else(statement)
      when AST::MatchStmt
        visit_expression(statement.expression)
        statement.arms.each do |arm|
          with_scope do
            binding_line = arm.binding_line || statement.line
            binding_column = arm.binding_column
            declare_local(arm.binding_name, binding_line, column: binding_column, var: false) if arm.binding_name
            visit_statement_list(arm.body)
          end
        end
      when AST::UnsafeStmt
        with_scope { visit_statement_list(statement.body) }
      when AST::ForStmt
        visit_expression(statement.iterable)
        with_scope do
          declare_local(statement.name, statement.line, column: statement.column, var: false) if statement.name
          visit_statement_list(statement.body)
        end
      when AST::WhileStmt
        visit_expression(statement.condition)
        with_scope { visit_statement_list(statement.body) }
      when AST::ReturnStmt
        visit_expression(statement.value) if statement.value
      when AST::DeferStmt
        visit_expression(statement.expression) if statement.expression
        with_scope { visit_statement_list(statement.body) } if statement.body
      when AST::ExpressionStmt
        visit_expression(statement.expression)
        check_useless_expression(statement)
      when AST::StaticAssert
        visit_expression(statement.condition)
      when AST::BreakStmt, AST::ContinueStmt
        nil
      else
        nil
      end
    end

    def visit_expression(expression)
      case expression
      when nil
        nil
      when AST::Identifier
        mark_used(expression.name)
      when AST::MemberAccess
        visit_expression(expression.receiver)
      when AST::IndexAccess
        visit_expression(expression.receiver)
        visit_expression(expression.index)
      when AST::Specialization
        visit_expression(expression.callee)
        expression.arguments.each { |argument| visit_type_argument(argument) }
      when AST::Call
        visit_expression(expression.callee)
        expression.arguments.each do |argument|
          visit_expression(argument.value)
          mark_call_argument_mutated(argument.value)
        end
        mark_alias_source_mutated(expression)
        mark_call_receiver_mutated(expression)
      when AST::UnaryOp
        visit_expression(expression.operand)
      when AST::BinaryOp
        visit_expression(expression.left)
        visit_expression(expression.right)
        check_self_comparison(expression)
      when AST::RangeExpr
        visit_expression(expression.start_expr)
        visit_expression(expression.end_expr)
      when AST::ExpressionList
        expression.elements.each { |e| visit_expression(e) }
      when AST::IfExpr
        visit_expression(expression.condition)
        visit_expression(expression.then_expression)
        visit_expression(expression.else_expression)
      when AST::UnsafeExpr
        visit_expression(expression.expression)
      when AST::ProcExpr
        with_scope do
          fallback_line = expression.respond_to?(:line) ? expression.line : nil
          expression.params.each do |param|
            declare_param(
              param.name,
              line: param_line(param, fallback: fallback_line),
              column: param_column(param)
            )
          end
          visit_statement_list(expression.body)
          emit_dead_assignment_warnings(expression.body)
          emit_unreachable_warnings(expression.body)
          emit_borrow_warnings(expression.body)
          emit_constant_condition_warnings(expression.body)
          emit_redundant_null_check_warnings(expression.body)
          emit_redundant_unsafe_warnings(expression.body)
          emit_loop_single_iteration_warnings(expression.body)
        end
      when AST::AwaitExpr
        visit_expression(expression.expression)
      when AST::FormatString
        expression.parts.each do |part|
          next unless part.is_a?(AST::FormatExprPart)

          visit_expression(part.expression)
        end
      when AST::IntegerLiteral, AST::FloatLiteral, AST::StringLiteral, AST::BooleanLiteral, AST::NullLiteral,
           AST::SizeofExpr, AST::AlignofExpr, AST::OffsetofExpr
        nil
      else
        nil
      end
    end

    def visit_type_argument(argument)
      visit_expression(argument.value) if argument.respond_to?(:value)
    end

    def visit_assignment_target(target)
      case target
      when AST::Identifier
        nil
      when AST::MemberAccess
        visit_expression(target.receiver)
      when AST::IndexAccess
        visit_expression(target.receiver)
        visit_expression(target.index)
      else
        visit_expression(target)
      end
    end

    def mark_assignment_target_reads(target, operator)
      return if operator == "="

      mark_used(target.name) if target.is_a?(AST::Identifier)
    end

    def mark_mutated(target)
      return unless target.is_a?(AST::Identifier) || target.is_a?(AST::IndexAccess) || target.is_a?(AST::MemberAccess)

      # For direct identifier assignment (e.g., x = value), mark x as mutated.
      if target.is_a?(AST::Identifier)
        @scopes.reverse_each do |scope|
          binding = scope[target.name]
          next unless binding

          binding.mutated = true
          return
        end
      end

      # For index assignment (e.g., array[0] = value), mark the array as mutated.
      if target.is_a?(AST::IndexAccess)
        mark_mutated(target.receiver)
      end

      # For field assignment (e.g., rect.w = value), mark the struct variable as mutated.
      if target.is_a?(AST::MemberAccess)
        mark_mutated(target.receiver)
      end
    end

    def mark_call_argument_mutated(expression)
      if expression.is_a?(AST::Identifier) && mutating_argument_identifier?(expression)
        mark_mutated(expression)
        return
      end

      if expression.is_a?(AST::UnaryOp) && %w[out inout].include?(expression.operator)
        mark_mutated(expression.operand)
        return
      end

      # ref_of(x) and ptr_of(x) can expose writable aliases — treat as potential
      # mutation since callees may write through them (common C-FFI out-param pattern).
      if expression.is_a?(AST::Call) &&
         expression.callee.is_a?(AST::Identifier) &&
        ["ref_of", "ptr_of"].include?(expression.callee.name) &&
         expression.arguments.length == 1
        mark_mutated(expression.arguments.first.value)
      end
    end

    def mutating_argument_identifier?(expression)
      return false unless expression.is_a?(AST::Identifier)

      @sema_analysis&.binding_resolution&.mutating_argument_identifier_ids&.key?(expression.object_id)
    end

    def mark_call_receiver_mutated(expression)
      return unless expression.is_a?(AST::Call)
      return unless expression.callee.is_a?(AST::MemberAccess)
      return unless editable_receiver_expression?(expression.callee.receiver)

      mark_mutated(expression.callee.receiver)
    end

    def mark_alias_source_mutated(expression)
      return unless expression.is_a?(AST::Call)
      return unless expression.callee.is_a?(AST::Identifier)
      return unless %w[ref_of ptr_of].include?(expression.callee.name)
      return unless expression.arguments.length == 1

      mark_mutated(expression.arguments.first.value)
    end

    def editable_receiver_expression?(expression)
      @sema_analysis&.binding_resolution&.editable_receiver_expression_ids&.key?(expression.object_id)
    end

    def with_scope
      @scopes << {}
      yield
    ensure
      emit_scope_warnings(@scopes.pop)
    end

    def declare_local(name, line, column: nil, var: false)
      return if ignored_binding_name?(name)

      warn_builtin_type_style_name(name, line:, column:, kind_label: "local")

      # shadow: check whether any outer scope already has a binding for this name
      if @scopes.length > 1
        @scopes[0..-2].each do |outer_scope|
          if outer_scope.key?(name)
            @warnings << Warning.new(
              path: @path, line:, column:, length: name.length, code: "shadow",
              message: "local '#{name}' shadows a binding from an outer scope",
              symbol_name: name
            )
            break
          end
        end
      end

      @scopes.last[name] = Binding.new(
        name:, line:, column:, used: false,
        binding_kind: :local,
        allow_prefer_let: var,
        mutated: false
      )
    end

    def declare_param(name, line: nil, column: nil)
      return if ignored_binding_name?(name)

      warn_builtin_type_style_name(name, line:, column:, kind_label: "parameter")

      @scopes.last[name] = Binding.new(
        name:, line:, column:, used: false,
        binding_kind: :param,
        allow_prefer_let: false,
        mutated: false
      )
    end

    def warn_builtin_type_style_name(name, line:, column:, kind_label:)
      return unless BUILTIN_TYPE_STYLE_NAMES.include?(name)

      @warnings << Warning.new(
        path: @path,
        line:,
        column:,
        length: name.length,
        code: "builtin-type-name",
        message: "#{kind_label} '#{name}' reuses builtin type name '#{name}'; choose a less ambiguous name",
        severity: :warning,
        symbol_name: name,
      )
    end

    def param_line(param, fallback: nil)
      line = param.respond_to?(:line) ? param.line : nil
      line || fallback
    end

    def param_column(param)
      param.respond_to?(:column) ? param.column : nil
    end

    def declaration_column(declaration)
      declaration.respond_to?(:column) ? declaration.column : nil
    end

    def source_line_text(line)
      return nil unless line && line >= 1 && line <= @source_lines.length

      @source_lines[line - 1]
    end

    def source_code_line(line)
      text = source_line_text(line)
      return nil unless text

      text.rstrip
    end

    def source_statement_span(line)
      text = source_code_line(line)
      return nil unless text

      start_index = text.index(/\S/)
      return nil unless start_index

      [start_index + 1, text.length - start_index]
    end

    def source_condition_span(line, keyword_pattern:)
      text = source_code_line(line)
      return nil unless text

      match = text.match(/\A\s*(?:#{keyword_pattern})\s+(.*?)\s*:/)
      return nil unless match

      condition = match[1].rstrip
      return nil if condition.empty?

      [match.begin(1) + 1, condition.length]
    end

    def expression_line(expr)
      return nil unless expr

      return expr.line if expr.respond_to?(:line) && expr.line

      case expr
      when AST::BinaryOp
        expression_line(expr.left) || expression_line(expr.right)
      when AST::UnaryOp
        expression_line(expr.operand)
      when AST::Specialization
        expression_line(expr.callee)
      when AST::Call
        expression_line(expr.callee) || expr.arguments.filter_map { |argument| expression_line(argument.value) }.first
      when AST::IndexAccess
        expression_line(expr.receiver) || expression_line(expr.index)
      when AST::MemberAccess
        expression_line(expr.receiver)
      when AST::RangeExpr
        expression_line(expr.start_expr) || expression_line(expr.end_expr)
      when AST::ExpressionList
        expr.elements.filter_map { |element| expression_line(element) }.first
      when AST::IfExpr
        expression_line(expr.condition) || expression_line(expr.then_expression) || expression_line(expr.else_expression)
      when AST::AwaitExpr
        expression_line(expr.expression)
      when AST::UnsafeExpr
        expression_line(expr.expression)
      when AST::FormatString
        expr.parts.filter_map do |part|
          expression_line(part.expression) if part.is_a?(AST::FormatExprPart)
        end.first
      else
        nil
      end
    end

    def expression_column(expr)
      return nil unless expr

      if expr.respond_to?(:column) && expr.column
        return expr.column
      end

      case expr
      when AST::BinaryOp
        expression_column(expr.left) || expression_column(expr.right)
      when AST::UnaryOp
        expression_column(expr.operand)
      when AST::Specialization
        expression_column(expr.callee)
      when AST::Call
        expression_column(expr.callee)
      when AST::IndexAccess
        expression_column(expr.receiver)
      when AST::MemberAccess
        expression_column(expr.receiver)
      when AST::RangeExpr
        expression_column(expr.start_expr) || expression_column(expr.end_expr)
      when AST::ExpressionList
        expr.elements.filter_map { |element| expression_column(element) }.first
      when AST::IfExpr
        expression_column(expr.condition) || expression_column(expr.then_expression) || expression_column(expr.else_expression)
      when AST::AwaitExpr
        expression_column(expr.expression)
      when AST::UnsafeExpr
        expression_column(expr.expression)
      else
        nil
      end
    end

    def expression_length(expr)
      return nil unless expr

      case expr
      when AST::Identifier
        expr.name.length
      when AST::BooleanLiteral
        expr.value ? 4 : 5
      when AST::NullLiteral
        4
      when AST::IntegerLiteral, AST::FloatLiteral, AST::StringLiteral
        expr.lexeme.length
      when AST::BinaryOp
        left_column = expression_column(expr.left)
        right_column = expression_column(expr.right)
        right_length = expression_length(expr.right)
        if left_column && right_column && right_length
          (right_column + right_length) - left_column
        end
      when AST::UnaryOp
        expression_length(expr.operand)
      when AST::Specialization
        expression_length(expr.callee)
      when AST::Call
        expression_length(expr.callee)
      when AST::AwaitExpr
        expression_length(expr.expression)
      when AST::UnsafeExpr
        expression_length(expr.expression)
      else
        1
      end
    end

    def statement_column(statement)
      return nil unless statement

      if statement.respond_to?(:column) && statement.column
        return statement.column
      end

      case statement
      when AST::IfStmt
        statement.branches.first&.column || statement.else_column
      when AST::WhileStmt
        expression_column(statement.condition)
      when AST::MatchStmt
        expression_column(statement.expression)
      when AST::ReturnStmt
        expression_column(statement.value)
      when AST::DeferStmt
        expression_column(statement.expression)
      when AST::ExpressionStmt
        expression_column(statement.expression) || source_statement_span(statement.line)&.first
      else
        nil
      end
    end

    def statement_length(statement)
      return nil unless statement

      if statement.respond_to?(:length) && statement.length
        return statement.length
      end

      case statement
      when AST::LocalDecl, AST::ForStmt
        statement.name.length
      when AST::IfStmt
        statement.branches.first&.length || (statement.else_column ? 4 : nil)
      when AST::WhileStmt
        expression_length(statement.condition)
      when AST::MatchStmt
        expression_length(statement.expression)
      when AST::ReturnStmt
        expression_length(statement.value)
      when AST::DeferStmt
        expression_length(statement.expression)
      when AST::ExpressionStmt
        expression_length(statement.expression) || source_statement_span(statement.line)&.last
      else
        nil
      end
    end

    def condition_span(expr, line:, keyword_pattern:)
      source_span = source_condition_span(line, keyword_pattern:)
      if source_span
        [line, source_span.first, source_span.last]
      else
        [expression_line(expr) || line, expression_column(expr), expression_length(expr)]
      end
    end

    def condition_symbol_name(expr)
      case expr
      when AST::Identifier
        expr.name
      when AST::BooleanLiteral
        expr.value ? "true" : "false"
      when AST::BinaryOp
        condition_symbol_name(expr.left) || condition_symbol_name(expr.right)
      when AST::UnaryOp
        condition_symbol_name(expr.operand)
      when AST::Call
        condition_symbol_name(expr.callee)
      when AST::IndexAccess
        condition_symbol_name(expr.receiver)
      when AST::MemberAccess
        condition_symbol_name(expr.receiver)
      when AST::RangeExpr
        condition_symbol_name(expr.start_expr) || condition_symbol_name(expr.end_expr)
      else
        nil
      end
    end

    def mark_used(name)
      @scopes.reverse_each do |scope|
        binding = scope[name]
        next unless binding

        binding.used = true
        return
      end
    end

    def emit_dead_assignment_warnings(stmts)
      graph = CFG::Builder.new(
        ignore_name: method(:ignored_binding_name?),
        binding_resolution: cfg_binding_resolution,
      ).build(stmts)
      liveness = CFG::Liveness.solve(graph)
      readable_bindings = graph.read_bindings

      # Only flag assignments to locally declared bindings. Writes to globals
      # (names that are assigned but never declared in this function's body)
      # always escape via persistent state and must never be flagged.
      locally_declared = Set.new
      graph.each_node do |node|
        node.writes_info.each do |w|
          locally_declared << w[:binding_key] if w[:origin] == :declaration
        end
      end

      # For the common pattern `var x = default; while cond: x = compute(); use(x)`,
      # the initial value of x is technically dead (loop might not run), but this is
      # idiomatic and warning about it is noise. Suppress declaration-dead warnings
      # when the binding's overwriting assignment lives inside a loop body.
      loop_initialized = Set.new
      graph.each_node do |node|
        node.writes_info.each do |w|
          next unless w[:origin] == :assignment
          loop_initialized << w[:binding_key] if assignment_inside_loop?(graph, node.id)
        end
      end

      graph.each_node do |node|
        node.writes_info.each do |write|
          next if write[:origin] == :call_argument

          binding_key = write[:binding_key]
          name = write[:name]
          next unless readable_bindings.include?(binding_key)
          next unless locally_declared.include?(binding_key)
          next if liveness.live_out[node.id].include?(binding_key)
          next if write[:origin] == :declaration && loop_initialized.include?(binding_key)

          @warnings << Warning.new(
            path: @path,
            line: write[:line],
            column: write[:column],
            length: name.length,
            code: "dead-assignment",
            message: "value assigned to '#{name}' is never read",
            symbol_name: name
          )
        end
      end
    end

    # Returns true if node_id is inside a while/for loop body — i.e., walking
    # predecessor edges backward from it eventually reaches a :while_condition
    # or :for_header node before the function entry. This is used to suppress
    # dead-declaration warnings for the "var x = default; while ...: x = ..."
    # pattern where the initial value is a required placeholder, not a bug.
    def assignment_inside_loop?(graph, node_id)
      visited = Set.new
      stack = graph.nodes[node_id].preds.dup
      until stack.empty?
        id = stack.pop
        next if visited.include?(id)
        visited << id
        node = graph.nodes[id]
        return true if %i[while_condition for_header].include?(node.kind)
        node.preds.each { |p| stack << p }
      end
      false
    end

    def emit_unreachable_warnings(stmts)
      graph      = CFG::Builder.new(ignore_name: method(:ignored_binding_name?), binding_resolution: cfg_binding_resolution).build(stmts)
      reachable  = CFG::Reachability.solve(graph)

      graph.each_node do |node|
        next if reachable.reachable_ids.include?(node.id)
        next if node.kind == :exit
        next unless node.statement

        statement = node.statement
        line = statement.respond_to?(:line) ? statement.line : nil
        @warnings << Warning.new(
          path: @path,
          line:,
          column: statement_column(statement),
          length: statement_length(statement),
          code: "unreachable-code",
          message: "unreachable code"
        )
      end
    end

    # Detects obvious aliasing hazards: a mutable reference (ref_of / ptr_of)
    # is taken from a local variable that is also written later in the same body.
    def emit_borrow_warnings(stmts)
      return if stmts.nil? || stmts.empty?

      borrowed = collect_borrowed_names(stmts)
      return if borrowed.empty?

      written = collect_written_names(stmts)
      (borrowed & written).each do |name|
        # Find the earliest borrow site for the warning location
        borrow_line, borrow_column, borrow_length = find_borrow_location(stmts, name)
        @warnings << Warning.new(
          path: @path,
          line: borrow_line,
          column: borrow_column,
          length: borrow_length,
          code: "borrow-and-mutate",
          message: "'#{name}' is borrowed via ref_of/ptr_of and also mutated in the same scope — potential aliasing hazard",
          severity: :warning,
          symbol_name: name,
        )
      end
    end

    def emit_scope_warnings(scope)
      scope.each_value do |binding|
        if !binding.used
          code = binding.binding_kind == :param ? "unused-param" : "unused-local"
          kind_label = binding.binding_kind == :param ? "parameter" : "local"
          @warnings << Warning.new(
            path: @path,
            line: binding.line,
            column: binding.column,
            length: binding.name.length,
            code: code,
            message: "unused #{kind_label} '#{binding.name}'",
            symbol_name: binding.name,
          )
        else
          if binding.allow_prefer_let && !binding.mutated
            @warnings << Warning.new(
              path: @path,
              line: binding.line,
              column: binding.column,
              length: binding.name.length,
              code: "prefer-let",
              message: "variable '#{binding.name}' is never reassigned, prefer 'let'",
              severity: :hint,
              symbol_name: binding.name
            )
          end
        end
      end
    end

    def cfg_binding_resolution
      binding_resolution = @sema_analysis&.binding_resolution
      return nil unless binding_resolution

      CFG::BindingResolution.new(
        identifier_binding_ids: binding_resolution.identifier_binding_ids,
        declaration_binding_ids: binding_resolution.declaration_binding_ids,
        mutating_argument_identifier_ids: binding_resolution.mutating_argument_identifier_ids,
      )
    end

    def cfg_identifier_binding_key(identifier)
      binding_resolution = cfg_binding_resolution
      return identifier.name unless binding_resolution

      binding_resolution.identifier_binding_ids[identifier.object_id] || identifier.name
    end

    def ignored_binding_name?(name)
      name == "_" || name.start_with?("_")
    end

    # ── self-assignment ────────────────────────────────────────────────────

    def check_self_assignment(stmt)
      return unless stmt.operator == "="
      return unless stmt.target.is_a?(AST::Identifier) && stmt.value.is_a?(AST::Identifier)
      return unless stmt.target.name == stmt.value.name

      @warnings << Warning.new(
        path: @path,
        line: expression_line(stmt.target) || stmt.line,
        column: expression_column(stmt.target),
        length: expression_length(stmt.target),
        code: "self-assignment",
        message: "'#{stmt.target.name}' is assigned to itself",
        severity: :warning,
        symbol_name: stmt.target.name
      )
    end

    # ── self-comparison ────────────────────────────────────────────────────

    def check_self_comparison(expr)
      return unless %w[== !=].include?(expr.operator)
      return unless expr.left.is_a?(AST::Identifier) && expr.right.is_a?(AST::Identifier)
      return unless expr.left.name == expr.right.name

      line = expression_line(expr) || expr.left.line
      always = expr.operator == "==" ? "always true" : "always false"
      @warnings << Warning.new(
        path: @path,
        line:,
        column: expression_column(expr),
        length: expression_length(expr),
        code: "self-comparison",
        message: "'#{expr.left.name}' is compared to itself — #{always}",
        severity: :warning,
        symbol_name: expr.left.name
      )
    end

    # ── constant-condition ─────────────────────────────────────────────────
    # Uses ConstantPropagation to detect conditions that are always true/false.
    # Skips `while true` — it is an idiomatic infinite loop.
    # Skips if conditions inside loops, since variables can change across iterations.

    def emit_constant_condition_warnings(stmts)
      return if stmts.nil? || stmts.empty?

      binding_resolution = cfg_binding_resolution
      graph = CFG::Builder.new(ignore_name: method(:ignored_binding_name?), binding_resolution:).build(stmts)
      cp    = CFG::ConstantPropagation.solve(graph, binding_resolution:, strict_binding_ids: !binding_resolution.nil?)

      # Precompute which nodes are inside loops by finding back-edges (a node reachable from its successors).
      loop_bodies = compute_loop_body_nodes(graph)

      graph.each_node do |node|
        cond_expr, line, keyword_pattern, skip_node =
          case node.kind
          when :if_condition
            branch = node.statement
            # Skip if conditions inside loops; variables can change across iterations.
            skip = loop_bodies.include?(node.id)
            [branch&.condition, branch&.line || node.line, "if|elif", skip]
          when :while_condition
            wstmt = node.statement
            # `while true` is an idiomatic infinite loop — do not warn
            skip = wstmt&.condition.is_a?(AST::BooleanLiteral) && wstmt.condition.value == true
            condition = wstmt&.condition
            [condition, node.line, "while", skip]
          else
            next
          end

        next if skip_node || cond_expr.nil?

        in_state  = cp.in_states[node.id] || {}
        const_val = CFG::ConstantPropagation.constant_value_of(
          cond_expr,
          in_state,
          binding_resolution:,
          strict_binding_ids: !binding_resolution.nil?
        )
        next unless const_val == true || const_val == false

        ctx = node.kind == :while_condition ? "loop condition" : "branch condition"
        line, column, length = condition_span(cond_expr, line:, keyword_pattern:)
        @warnings << Warning.new(
          path: @path,
          line:,
          column:,
          length:,
          code: "constant-condition",
          message: "#{ctx} is always #{const_val}",
          severity: :warning,
          symbol_name: condition_symbol_name(cond_expr)
        )
      end
    end

    # Returns the set of node IDs that are inside loops (reachable from a back-edge).
    # A back-edge exists when a node is reachable from its own successors.
    private def compute_loop_body_nodes(graph)
      loop_nodes = Set.new

      # Find all back-edges: detect cycles by checking if any successor of a node
      # can reach back to that node.
      graph.each_node do |node|
        node.succs.each do |succ_id|
          # Check if succ can reach back to node (indicating a loop/cycle).
          if reachable_from?(graph, succ_id, node.id)
            # Mark all nodes reachable from succ (the loop body) as inside a loop.
            mark_reachable_nodes(graph, succ_id, loop_nodes)
          end
        end
      end

      loop_nodes
    end

    # Returns true if target_id is reachable from start_id via forward edges.
    private def reachable_from?(graph, start_id, target_id)
      visited = Set.new
      queue = [start_id]

      while queue.any?
        node_id = queue.shift
        return true if node_id == target_id
        next if visited.include?(node_id)

        visited.add(node_id)
        node = graph.nodes[node_id]
        node.succs.each { |succ| queue.push(succ) }
      end

      false
    end

    # Mark all nodes reachable from start_id as being inside a loop.
    private def mark_reachable_nodes(graph, start_id, loop_nodes)
      visited = Set.new
      queue = [start_id]

      while queue.any?
        node_id = queue.shift
        loop_nodes.add(node_id)
        next if visited.include?(node_id)

        visited.add(node_id)
        node = graph.nodes[node_id]
        node.succs.each { |succ| queue.push(succ) unless visited.include?(succ) }
      end
    end

    # ── redundant-null-check ───────────────────────────────────────────────
    # After a variable has been narrowed to non-null by a prior check,
    # a subsequent `x != nil` guard is always true.

    def emit_redundant_null_check_warnings(stmts)
      return if stmts.nil? || stmts.empty?

      binding_resolution = cfg_binding_resolution
      graph = CFG::Builder.new(ignore_name: method(:ignored_binding_name?), binding_resolution:).build(stmts)
      nf    = CFG::NullabilityFlow.solve(graph)

      graph.each_node do |node|
        next unless node.kind == :if_condition

        branch = node.statement
        next unless branch.is_a?(AST::IfBranch)

        identifier = null_check_identifier(branch.condition)
        next unless identifier
        next if ignored_binding_name?(identifier.name)

        nonnull = nf.nonnull_before(branch)
        next unless nonnull.include?(cfg_identifier_binding_key(identifier))

        line, column, length = condition_span(branch.condition, line: node.line, keyword_pattern: "if|elif")

        @warnings << Warning.new(
          path: @path,
          line:,
          column:,
          length:,
          code: "redundant-null-check",
          message: "'#{identifier.name}' is already known to be non-null here — this nil check is redundant",
          severity: :hint,
          symbol_name: identifier.name
        )
      end
    end

    # Returns the Identifier being nil-tested if `cond` is `x != nil` or
    # `nil != x`, otherwise nil.
    def null_check_identifier(cond)
      return nil unless cond.is_a?(AST::BinaryOp) && cond.operator == "!="

      if cond.left.is_a?(AST::Identifier) && cond.right.is_a?(AST::NullLiteral)
        cond.left
      elsif cond.left.is_a?(AST::NullLiteral) && cond.right.is_a?(AST::Identifier)
        cond.right
      end
    end

    # ── redundant-unsafe ───────────────────────────────────────────────

    def emit_redundant_unsafe_warnings(stmts)
      return if stmts.nil? || stmts.empty?

      required_unsafe_lines = @sema_analysis&.required_unsafe_lines
      return unless required_unsafe_lines

      walk_stmts_for_redundant_unsafe(stmts, required_unsafe_lines)
    end

    def walk_stmts_for_redundant_unsafe(stmts, required_unsafe_lines)
      stmts.each do |stmt|
        case stmt
        when AST::UnsafeStmt
          if stmt.line && !required_unsafe_lines.include?(stmt.line)
            @warnings << Warning.new(
              path: @path,
              line: stmt.line,
              column: stmt.column,
              length: stmt.length || "unsafe".length,
              code: "redundant-unsafe",
              message: "unsafe block does not contain any operation that requires unsafe",
              severity: :hint
            )
          end
          walk_stmts_for_redundant_unsafe(stmt.body, required_unsafe_lines) if stmt.body
        when AST::IfStmt
          stmt.branches.each { |branch| walk_stmts_for_redundant_unsafe(branch.body, required_unsafe_lines) }
          walk_stmts_for_redundant_unsafe(stmt.else_body, required_unsafe_lines) if stmt.else_body
        when AST::MatchStmt
          stmt.arms.each { |arm| walk_stmts_for_redundant_unsafe(arm.body, required_unsafe_lines) }
        when AST::ForStmt, AST::WhileStmt
          walk_stmts_for_redundant_unsafe(stmt.body, required_unsafe_lines)
        when AST::DeferStmt
          walk_stmts_for_redundant_unsafe(stmt.body, required_unsafe_lines) if stmt.body
        end
      end
    end

    # ── loop-single-iteration ──────────────────────────────────────────────
    # A loop whose body unconditionally exits (return/break) before the
    # back-edge is taken will execute at most once.

    def emit_loop_single_iteration_warnings(stmts)
      return if stmts.nil? || stmts.empty?

      walk_stmts_for_loop_check(stmts)
    end

    def walk_stmts_for_loop_check(stmts)
      stmts.each do |stmt|
        case stmt
        when AST::WhileStmt
          body = stmt.body || []
          if !body.empty? && CFG::Termination.loop_body_always_exits?(body)
            @warnings << Warning.new(
              path: @path,
              line: stmt.line,
              column: stmt.column,
              length: stmt.length || "while".length,
              code: "loop-single-iteration",
              message: "loop body always exits on the first iteration — consider replacing with an 'if' block",
              severity: :warning
            )
          end
          walk_stmts_for_loop_check(body)
        when AST::ForStmt
          body = stmt.body || []
          if !body.empty? && CFG::Termination.loop_body_always_exits?(body)
            @warnings << Warning.new(
              path: @path,
              line: stmt.line,
              column: stmt.column,
              length: stmt.length || "for".length,
              code: "loop-single-iteration",
              message: "loop body always exits on the first iteration — consider iterating directly without a loop",
              severity: :warning
            )
          end
          walk_stmts_for_loop_check(body)
        when AST::IfStmt
          stmt.branches.each { |b| walk_stmts_for_loop_check(b.body) }
          walk_stmts_for_loop_check(stmt.else_body) if stmt.else_body
        when AST::MatchStmt
          stmt.arms.each { |arm| walk_stmts_for_loop_check(arm.body) }
        when AST::UnsafeStmt
          walk_stmts_for_loop_check(stmt.body) if stmt.body
        when AST::DeferStmt
          walk_stmts_for_loop_check(stmt.body) if stmt.body
        end
      end
    end

    # ── borrow analysis helpers ───────────────────────────────────────────────

    BORROW_CALL_NAMES = %w[ref_of ptr_of].freeze

    def collect_borrowed_names(stmts)
      names = Set.new
      stmts.each { |s| collect_borrows_from_stmt(s, names) }
      names
    end

    def collect_borrows_from_stmt(stmt, names)
      case stmt
      when AST::LocalDecl
        collect_borrows_from_expr(stmt.value, names) if stmt.value
      when AST::Assignment
        collect_borrows_from_expr(stmt.value, names)
      when AST::ExpressionStmt
        collect_borrows_from_expr(stmt.expression, names)
      when AST::IfStmt
        stmt.branches.each do |b|
          collect_borrows_from_expr(b.condition, names)
          b.body.each { |s| collect_borrows_from_stmt(s, names) }
        end
        stmt.else_body&.each { |s| collect_borrows_from_stmt(s, names) }
      when AST::WhileStmt
        collect_borrows_from_expr(stmt.condition, names)
        stmt.body.each { |s| collect_borrows_from_stmt(s, names) }
      when AST::ForStmt
        stmt.body.each { |s| collect_borrows_from_stmt(s, names) }
      when AST::ReturnStmt
        collect_borrows_from_expr(stmt.value, names) if stmt.value
      end
    end

    def collect_borrows_from_expr(expr, names, inside_call_argument: false)
      case expr
      when nil then nil
      when AST::Call
        if !inside_call_argument && expr.callee.is_a?(AST::Identifier) && BORROW_CALL_NAMES.include?(expr.callee.name)
          arg = expr.arguments.first
          if arg&.value.is_a?(AST::Identifier)
            names << arg.value.name
          end
        else
          collect_borrows_from_expr(expr.callee, names)
          expr.arguments.each { |a| collect_borrows_from_expr(a.value, names, inside_call_argument: true) }
        end
      when AST::UnaryOp  then collect_borrows_from_expr(expr.operand, names, inside_call_argument:)
      when AST::BinaryOp
        collect_borrows_from_expr(expr.left, names, inside_call_argument:)
        collect_borrows_from_expr(expr.right, names, inside_call_argument:)
      when AST::IfExpr
        collect_borrows_from_expr(expr.condition, names, inside_call_argument:)
        collect_borrows_from_expr(expr.then_expression, names, inside_call_argument:)
        collect_borrows_from_expr(expr.else_expression, names, inside_call_argument:)
      when AST::AwaitExpr
        collect_borrows_from_expr(expr.expression, names, inside_call_argument:)
      when AST::UnsafeExpr
        collect_borrows_from_expr(expr.expression, names, inside_call_argument:)
      when AST::MemberAccess  then collect_borrows_from_expr(expr.receiver, names, inside_call_argument:)
      when AST::IndexAccess
        collect_borrows_from_expr(expr.receiver, names, inside_call_argument:)
        collect_borrows_from_expr(expr.index, names, inside_call_argument:)
      end
    end

    def collect_written_names(stmts)
      names = Set.new
      stmts.each { |s| collect_writes_from_stmt(s, names) }
      names
    end

    def collect_writes_from_stmt(stmt, names)
      case stmt
      when AST::Assignment
        names << stmt.target.name if stmt.target.is_a?(AST::Identifier)
        collect_writes_from_stmt_list(stmt_sub_stmts(stmt), names)
      when AST::IfStmt
        stmt.branches.each { |b| b.body.each { |s| collect_writes_from_stmt(s, names) } }
        stmt.else_body&.each { |s| collect_writes_from_stmt(s, names) }
      when AST::WhileStmt
        stmt.body.each { |s| collect_writes_from_stmt(s, names) }
      when AST::ForStmt
        stmt.body.each { |s| collect_writes_from_stmt(s, names) }
      end
    end

    def collect_writes_from_stmt_list(stmts, names)
      stmts.each { |s| collect_writes_from_stmt(s, names) }
    end

    def stmt_sub_stmts(_stmt)
      []
    end

    def find_borrow_location(stmts, name)
      stmts.each do |stmt|
        location = find_borrow_location_in_stmt(stmt, name)
        return location if location
      end
      nil
    end

    def find_borrow_location_in_stmt(stmt, name)
      case stmt
      when AST::LocalDecl
        find_borrow_location_in_expr(stmt.value, name) if stmt.value
      when AST::Assignment
        find_borrow_location_in_expr(stmt.value, name)
      when AST::ExpressionStmt
        find_borrow_location_in_expr(stmt.expression, name)
      when AST::IfStmt
        stmt.branches.each do |b|
          location = find_borrow_location_in_expr(b.condition, name)
          return location if location
          b.body.each { |s| location = find_borrow_location_in_stmt(s, name); return location if location }
        end
        stmt.else_body&.each { |s| location = find_borrow_location_in_stmt(s, name); return location if location }
        nil
      when AST::WhileStmt
        location = find_borrow_location_in_expr(stmt.condition, name)
        return location if location
        stmt.body.each { |s| location = find_borrow_location_in_stmt(s, name); return location if location }
        nil
      when AST::ForStmt
        stmt.body.each { |s| location = find_borrow_location_in_stmt(s, name); return location if location }
        nil
      when AST::ReturnStmt
        find_borrow_location_in_expr(stmt.value, name) if stmt.value
      end
    end

    def find_borrow_location_in_expr(expr, name)
      case expr
      when nil then nil
      when AST::Call
        if expr.callee.is_a?(AST::Identifier) && BORROW_CALL_NAMES.include?(expr.callee.name)
          arg = expr.arguments.first
          if arg&.value.is_a?(AST::Identifier) && arg.value.name == name
            return [arg.value.line, arg.value.column, arg.value.name.length]
          end
        end
        location = find_borrow_location_in_expr(expr.callee, name)
        return location if location
        expr.arguments.each do |a|
          location = find_borrow_location_in_expr(a.value, name)
          return location if location
        end
        nil
      when AST::UnaryOp  then find_borrow_location_in_expr(expr.operand, name)
      when AST::BinaryOp
        find_borrow_location_in_expr(expr.left, name) || find_borrow_location_in_expr(expr.right, name)
      when AST::IfExpr
        find_borrow_location_in_expr(expr.condition, name) ||
          find_borrow_location_in_expr(expr.then_expression, name) ||
          find_borrow_location_in_expr(expr.else_expression, name)
      when AST::AwaitExpr
        find_borrow_location_in_expr(expr.expression, name)
      when AST::UnsafeExpr
        find_borrow_location_in_expr(expr.expression, name)
      else
        nil
      end
    end
  end
end

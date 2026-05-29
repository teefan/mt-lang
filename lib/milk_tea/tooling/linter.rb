# frozen_string_literal: true

require "cgi/escape"
require "set"
require "uri"

module MilkTea
  class Linter
    UNSET = Object.new.freeze
    DEFAULT_CONFIG_FILE_NAME = ".mt-lint.yml".freeze
    KNOWN_RULE_CODES = %w[
      borrow-and-mutate
      constant-condition
      dead-assignment
      directional-ffi-arg
      line-too-long
      loop-single-iteration
      missing-return
      platform-api-drift
      prefer-let
      prefer-let-else
      redundant-cast
      redundant-else
      redundant-ignored-match-binding
      redundant-null-check
      redundant-read-cast
      redundant-read-release-temp
      redundant-return
      redundant-unsafe
      reserved-primitive-name
      self-assignment
      self-comparison
      shadow
      unreachable-code
      unused-import
      unused-local
      unused-param
      useless-expression
    ].freeze
    RESERVED_VALUE_TYPE_NAMES = Types::RESERVED_VALUE_TYPE_NAMES.to_set.freeze
    RESERVED_IMPORT_ALIAS_NAMES = Types::RESERVED_IMPORT_ALIAS_NAMES.to_set.freeze
    RESERVED_TYPE_BINDING_NAMES = Types::RESERVED_TYPE_BINDING_NAMES.to_set.freeze
    AUTO_FIXABLE_RULE_CODES = %w[
      line-too-long
      prefer-let
      redundant-ignored-match-binding
      redundant-read-cast
      redundant-read-release-temp
      prefer-let-else
      directional-ffi-arg
      redundant-else
      redundant-unsafe
      redundant-return
      unused-import
      dead-assignment
      redundant-cast
      reserved-primitive-name
    ].freeze
    LINT_TIERS = %i[fast full].freeze
    EXPENSIVE_LINT_RULE_CODES = %w[redundant-unsafe redundant-cast].to_set.freeze
    STATIC_QUICK_FIX_TITLES = {
      "line-too-long" => "Wrap long line",
      "prefer-let" => "Replace 'var' with 'let'",
      "redundant-ignored-match-binding" => "Remove redundant as _",
      "redundant-else" => "Remove redundant else",
      "redundant-unsafe" => "Remove redundant unsafe",
      "redundant-return" => "Remove redundant return",
      "redundant-read-cast" => "Remove redundant read cast",
      "redundant-cast" => "Remove redundant cast",
      "redundant-read-release-temp" => "Inline read(...).release()",
      "prefer-let-else" => "Rewrite as let-else",
      "directional-ffi-arg" => "Pass lvalue directly",
    }.freeze
    FIX_ALL_TITLE = "Apply all auto-fixes".freeze
    INTEGER_SURFACE_INFO = {
      "byte" => { width: 8, signed: true },
      "ubyte" => { width: 8, signed: false },
      "short" => { width: 16, signed: true },
      "ushort" => { width: 16, signed: false },
      "int" => { width: 32, signed: true },
      "uint" => { width: 32, signed: false },
      "long" => { width: 64, signed: true },
      "ulong" => { width: 64, signed: false },
      "ptr_int" => { width: 64, signed: true },
      "ptr_uint" => { width: 64, signed: false },
    }.freeze
    FLOAT_SURFACE_WIDTHS = {
      "float" => 32,
      "double" => 64,
    }.freeze

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
      :replacement_name, :replacement_base_name, :fix_index,
      keyword_init: true
    )
    PrefixCastSite = Data.define(
      :line, :column, :length, :target_text, :replacement_text,
      :start_offset, :end_offset, :pointer_like, :literal_source
    )
    ReservedPrimitiveNameSite = Data.define(:line, :column, :length)
    ReservedPrimitiveNameFix = Data.define(:kind, :original_name, :replacement_name, :sites)

    class Profile
      attr_reader :timings_ms, :counts

      def initialize
        @timings_ms = Hash.new(0.0)
        @counts = Hash.new(0)
      end

      def measure(name)
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = yield
        @timings_ms[name] += (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000.0
        @counts[name] += 1
        result
      end

      def empty?
        @timings_ms.empty?
      end

      def summary(limit: 10, min_ms: 0.1)
        @timings_ms
          .sort_by { |_name, total_ms| -total_ms }
          .filter_map do |name, total_ms|
            rounded_ms = total_ms.round(1)
            next if rounded_ms < min_ms

            count = @counts[name]
            count > 1 ? "#{name}:#{count}x/#{rounded_ms}" : "#{name}:#{rounded_ms}"
          end
          .first(limit)
          .join(',')
      end
    end

    StatementFlowAnalysis = Data.define(:graph, :reachability, :nullability, :constant_propagation, :loop_body_nodes)
    DeadAssignmentAnalysis = Data.define(:graph, :liveness, :readable_bindings, :locally_declared)

    def self.normalize_lint_tier(tier)
      normalized = tier.to_s.strip.downcase.to_sym
      LINT_TIERS.include?(normalized) ? normalized : :full
    end

    def self.lint_source(source, path: nil, select: nil, ignore: nil, sema_facts: UNSET, unresolved_import_paths: UNSET, profile: nil, lint_tier: :full)
      sema_facts_provided = !sema_facts.equal?(UNSET)
      unresolved_import_paths_provided = !unresolved_import_paths.equal?(UNSET)
      cfg = load_config(path)
      context = nil
      if !sema_facts_provided || !unresolved_import_paths_provided
        context = best_effort_lint_context(source, path:, profile:, label: "context_bootstrap")
        sema_facts = context[:facts] unless sema_facts_provided
        unresolved_import_paths = context[:unresolved_import_paths] unless unresolved_import_paths_provided
      end

      ast = profile_phase(profile, "resolve_ast") do
        sema_facts&.ast || context&.fetch(:ast, nil) || Parser.parse(source, path:)
      end
      imported_modules = context&.fetch(:imported_modules, nil)
      imported_modules ||= imported_modules_from_facts(ast, sema_facts)
      trivia = profile_phase(profile, "lex_trivia") { Lexer.lex_with_trivia(source, path:).trivia }
      suppressions = profile_phase(profile, "parse_suppressions") { parse_suppressions(trivia) }
      warnings = new(
        path:,
        sema_facts:,
        source:,
        unresolved_import_paths:,
        imported_modules:,
        source_ast: ast,
        profile:,
        lint_tier: normalize_lint_tier(lint_tier),
        max_line_length: cfg&.fetch(:max_line_length, nil),
      ).lint(ast)
      warnings = profile_phase(profile, "apply_suppressions") { apply_suppressions(warnings, suppressions) }

      # Layer in config-file defaults before per-call overrides
      if cfg
        select ||= cfg[:select]
        ignore ||= cfg[:ignore]
      end

      warnings = profile_phase(profile, "filter_rules") { filter_by_rules(warnings, select:, ignore:) }
      warnings
    end

    def self.quick_fix_title(code)
      STATIC_QUICK_FIX_TITLES[code]
    end

    def self.effective_max_line_length(path = nil)
      load_config(path)&.fetch(:max_line_length, nil) || Formatter::DEFAULT_MAX_LINE_LENGTH
    end

    def self.default_config_source
      lines = [
        "# Default Milk Tea lint configuration.",
        "# Remove entries from `select` to disable rules globally.",
        "max_line_length: #{Formatter::DEFAULT_MAX_LINE_LENGTH}",
        "select:",
      ]
      KNOWN_RULE_CODES.each do |code|
        lines << "  - #{code}"
      end
      lines << "ignore: []"
      "#{lines.join("\n")}\n"
    end

    def self.collect_reserved_primitive_name_fixes(source, path: nil, sema_facts: UNSET, unresolved_import_paths: UNSET)
      sema_facts_provided = !sema_facts.equal?(UNSET)
      unresolved_import_paths_provided = !unresolved_import_paths.equal?(UNSET)
      context = nil
      if !sema_facts_provided || !unresolved_import_paths_provided
        context = best_effort_lint_context(source, path:)
        sema_facts = context[:facts] unless sema_facts_provided
        unresolved_import_paths = context[:unresolved_import_paths] unless unresolved_import_paths_provided
      end

      ast = sema_facts&.ast || context&.fetch(:ast, nil) || Parser.parse(source, path:)
      imported_modules = context&.fetch(:imported_modules, nil)
      imported_modules ||= imported_modules_from_facts(ast, sema_facts)
      linter = new(path:, sema_facts:, source:, unresolved_import_paths:, imported_modules:, source_ast: ast)
      linter.lint(ast)
      linter.reserved_primitive_name_fixes
    end

    # Load the nearest .mt-lint.yml walking up from the source file's directory.
    # Returns Hash { select: Set|nil, ignore: Set|nil } or nil if no config found.
    def self.load_config(path)
      resolved_path = resolve_lint_path(path)
      return nil unless resolved_path

      dir = File.directory?(resolved_path) ? resolved_path : File.dirname(resolved_path)
      # Walk up until we either find a config or leave the project
      100.times do
        candidate = File.join(dir, DEFAULT_CONFIG_FILE_NAME)
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
      if raw.key?(:max_line_length)
        max_line_length = raw[:max_line_length].to_i
        result[:max_line_length] = max_line_length if max_line_length.positive?
      end
      result
    rescue StandardError
      {}
    end

    def self.profile_phase(profile, name)
      return yield unless profile

      profile.measure(name) { yield }
    end

    def self.imported_modules_from_facts(ast, sema_facts)
      return {} unless ast && sema_facts

      ast.imports.each_with_object({}) do |import, imported_modules|
        alias_name = import.alias_name || import.path.parts.last
        module_binding = sema_facts.imports[alias_name]
        imported_modules[import.path.to_s] = module_binding if module_binding
      end
    end

    # Apply auto-fixable rules to source text.
    # Handles: prefer-let, redundant-ignored-match-binding,
    # redundant-read-cast, redundant-read-release-temp, prefer-let-else,
    # directional-ffi-arg, redundant-else, redundant-unsafe,
    # redundant-return, redundant-cast, line-too-long.
    # Returns the fixed source (may be identical if nothing was fixable).
    def self.fix_source(source, path: nil, sema_facts: nil)
      working_context = best_effort_lint_context(source, path:)
      working_sema_facts = sema_facts || working_context[:facts]
      warnings = lint_source(
        source,
        path:,
        sema_facts: working_sema_facts,
        unresolved_import_paths: working_context[:unresolved_import_paths],
      )
      lines = source.lines

      # prefer-let: simple var→let substitution on the declaration line
      prefer_let_fixes = warnings.select { |w| w.code == "prefer-let" && w.line }
      prefer_let_fixes.sort_by(&:line).each do |w|
        idx = w.line - 1
        next unless lines[idx]

        lines[idx] = lines[idx].sub(/\bvar\b/, "let")
      end

      redundant_ignored_match_binding_fixes = warnings.select do |w|
        w.code == "redundant-ignored-match-binding" && w.line && w.column
      end
      redundant_ignored_match_binding_fixes.sort_by { |w| [w.line, w.column] }.reverse_each do |w|
        idx = w.line - 1
        next unless lines[idx]

        span = redundant_ignored_match_binding_span(lines[idx], column: w.column)
        next unless span

        lines[idx] = lines[idx].dup
        lines[idx][span[:start_char]...span[:end_char]] = ""
      end

      # redundant-read-cast: replace read(T<-value) with read(value).
      redundant_read_cast_fixes = warnings.select { |w| w.code == "redundant-read-cast" && w.line && w.symbol_name }
      redundant_read_cast_fixes.sort_by(&:line).each do |w|
        idx = w.line - 1
        next unless lines[idx]

        symbol = Regexp.escape(w.symbol_name)
        pattern = /(read\(\s*)(?:ptr|const_ptr|ref)\[[^\)]*\]<-\s*#{symbol}(\s*\))/
        lines[idx] = lines[idx].sub(pattern, "\\1#{w.symbol_name}\\2")
      end

      # redundant-read-release-temp: collapse `var owned = read(...); owned.release()`
      # into `read(...).release()`.
      read_release_temp_fixes = warnings.select { |w| w.code == "redundant-read-release-temp" && w.line }
      read_release_temp_fixes.sort_by(&:line).reverse_each do |w|
        fix = build_read_release_temp_fix(lines, w.line - 1)
        next unless fix

        lines[fix[:start_line_idx]..fix[:end_line_idx]] = [fix[:new_text]]
      end

      # prefer-let-else: rewrite adjacent nullable guard clauses into
      # `let value = expr else:`.
      prefer_let_else_fixes = warnings.select { |w| w.code == "prefer-let-else" && w.line }
      prefer_let_else_fixes.sort_by(&:line).reverse_each do |w|
        fix = build_prefer_let_else_fix(lines, w.line - 1, symbol_name: w.symbol_name)
        next unless fix

        lines[fix[:start_line_idx]..fix[:end_line_idx]] = [fix[:new_text]]
      end

      # directional-ffi-arg: strip legacy wrappers where the callee already
      # declares in/out/inout passing.
      directional_ffi_arg_fixes = warnings.select { |w| w.code == "directional-ffi-arg" && w.line }
      directional_ffi_arg_fixes.sort_by(&:line).each do |w|
        idx = w.line - 1
        next unless lines[idx]

        lines[idx] = rewrite_directional_ffi_argument(lines[idx])
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

      # redundant-unsafe: delete the `unsafe:` line and dedent the block body,
      # or strip an inline `unsafe:` expression prefix.
      redundant_unsafe_fixes = warnings.select { |w| w.code == "redundant-unsafe" && w.line }
      redundant_unsafe_fixes.sort_by(&:line).reverse_each do |w|
        unsafe_idx = w.line - 1
        next unless lines[unsafe_idx]

        unless lines[unsafe_idx].match?(/\A\s*unsafe:\s*\z/)
          next unless w.column

          lines[unsafe_idx] = remove_inline_unsafe_prefix(lines[unsafe_idx], column: w.column)
          next
        end

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

      # redundant-return: delete a final bare `return` in a void function.
      redundant_return_fixes = warnings.select { |w| w.code == "redundant-return" && w.line }
      redundant_return_fixes.sort_by(&:line).reverse_each do |w|
        idx = w.line - 1
        next unless lines[idx]&.match?(/\A\s*return\s*\z/)

        lines.delete_at(idx)
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

      fixed_source = lines.join
      fixed_source = Formatter.wrap_long_argument_lists(
        fixed_source,
        max_line_length: effective_max_line_length(path),
        path:,
      )
      redundant_cast_warnings = lint_source(fixed_source, path:).select do |w|
        w.code == "redundant-cast" && w.line && w.column && w.length
      end
      unless redundant_cast_warnings.empty?
        fixed_lines = fixed_source.lines
        redundant_cast_warnings.sort_by { |w| [w.line, w.column] }.reverse_each do |w|
          idx = w.line - 1
          next unless fixed_lines[idx]

          start_char = w.column - 1
          cast_text = fixed_lines[idx][start_char, w.length]
          replacement = extract_prefix_cast_source_text(cast_text)
          next unless replacement

          fixed_lines[idx] = fixed_lines[idx].dup
          fixed_lines[idx][start_char, w.length] = replacement
        end

        fixed_source = fixed_lines.join
      end

      reserved_warnings = lint_source(fixed_source, path:).select do |w|
        w.code == "reserved-primitive-name" && w.line && w.column && w.symbol_name
      end
      if reserved_warnings.empty?
        return validated_fixed_source(source, fixed_source, path:, baseline_errors: working_context[:errors])
      end

      warning_sites = reserved_warnings.each_with_object(Set.new) do |warning, sites|
        sites << [warning.line, warning.column, warning.symbol_name]
      end
      reserved_fixes = collect_reserved_primitive_name_fixes(fixed_source, path:).select do |fix|
        declaration_site = fix.sites.first
        warning_sites.include?([declaration_site.line, declaration_site.column, fix.original_name])
      end

      fixed_source = apply_reserved_primitive_name_fixes(fixed_source, reserved_fixes)
      validated_fixed_source(source, fixed_source, path:, baseline_errors: working_context[:errors])
    end

    def self.validated_fixed_source(original_source, fixed_source, path:, baseline_errors:)
      return fixed_source if fixed_source == original_source

      fixed_context = best_effort_lint_context(fixed_source, path:)
      return fixed_source if fixed_context[:ast] && !introduces_new_errors?(
        error_signature_counts(fixed_context[:errors]),
        error_signature_counts(baseline_errors),
      )

      original_source
    end

    def self.error_signature_counts(errors)
      Array(errors).each_with_object(Hash.new(0)) do |error, counts|
        counts[[error.line, error.column, error.message]] += 1
      end
    end

    def self.introduces_new_errors?(modified_counts, baseline_counts)
      modified_counts.any? do |signature, count|
        count > baseline_counts.fetch(signature, 0)
      end
    end

    def self.extract_prefix_cast_source_text(text)
      return nil unless text&.include?("<-")

      separator = text.index("<-")
      return nil unless separator

      replacement = text[(separator + 2)..]
      replacement = replacement.sub(/\A\s+/, "")
      replacement unless replacement.nil? || replacement.empty?
    end

    def self.apply_reserved_primitive_name_fixes(source, fixes)
      return source if fixes.empty?

      line_offsets = line_start_offsets(source)
      edits = fixes.flat_map do |fix|
        fix.sites.uniq { |site| [site.line, site.column] }.filter_map do |site|
          next unless site.line && site.column
          next unless site.line >= 1 && site.line <= line_offsets.length

          {
            start_offset: line_offsets[site.line - 1] + site.column - 1,
            length: site.length,
            replacement: fix.replacement_name,
          }
        end
      end
      return source if edits.empty?

      updated_source = source.dup
      edits.sort_by { |edit| [edit[:start_offset], edit[:length]] }.reverse_each do |edit|
        updated_source[edit[:start_offset], edit[:length]] = edit[:replacement]
      end
      updated_source
    end

    def self.line_start_offsets(source)
      offsets = []
      start_offset = 0
      source.lines.each do |line|
        offsets << start_offset
        start_offset += line.length
      end
      offsets
    end

    def self.rewrite_directional_ffi_argument(line)
      updated = line.sub(/\b(ptr_of|ref_of)\(([^()]+)\)/, "\\2")
      return updated if updated != line

      updated = line.sub(/\b(?:out|inout|in)\s+([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*|\[[^\]]+\])*)/, "\\1")
      return updated if updated != line

      line.sub(/\b(?:ptr|const_ptr|ref)\[[^\)]*\]<-\s*([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*|\[[^\]]+\])*)/, "\\1")
    end

    def self.build_read_release_temp_fix(lines, decl_idx)
      return nil if decl_idx.nil? || decl_idx.negative? || decl_idx + 1 >= lines.length

      declaration = lines[decl_idx].delete_suffix("\n")
      release = lines[decl_idx + 1].delete_suffix("\n")
      match = declaration.match(/\A(\s*)var\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s*:\s*[^=]+)?\s*=\s*(read\(.+\))\s*(#.*)?\z/)
      return nil unless match

      indent, name, read_expression, comment = match.captures
      return nil unless release.match?(/\A#{Regexp.escape(indent)}#{Regexp.escape(name)}\.release\(\)\s*\z/)

      new_text = +"#{indent}#{read_expression}.release()"
      new_text << " #{comment}" if comment
      new_text << "\n"

      { start_line_idx: decl_idx, end_line_idx: decl_idx + 1, new_text: }
    end

    def self.build_prefer_let_else_fix(lines, if_idx, symbol_name: nil)
      return nil if if_idx.nil? || if_idx <= 0 || if_idx >= lines.length

      declaration = lines[if_idx - 1].delete_suffix("\n")
      guard = lines[if_idx].delete_suffix("\n")
      name = symbol_name ||
        guard[/\A\s*if\s+([A-Za-z_][A-Za-z0-9_]*)\s*==\s*null\s*:/, 1] ||
        guard[/\A\s*if\s+null\s*==\s*([A-Za-z_][A-Za-z0-9_]*)\s*:/, 1]
      return nil unless name

      declaration_comment = declaration[/\s+#.*\z/] || ""
      declaration_base = declaration.sub(/\s+#.*\z/, "").rstrip
      return nil unless declaration_base.match?(/\A\s*let\s+#{Regexp.escape(name)}\s*=\s*.+\z/)
      return nil if declaration_base.end_with?(" else:")
      return nil unless guard.match?(/\A\s*if\s+(?:#{Regexp.escape(name)}\s*==\s*null|null\s*==\s*#{Regexp.escape(name)})\s*:\s*(?:#.*)?\z/)

      new_text = +"#{declaration_base} else:"
      new_text << declaration_comment unless declaration_comment.empty?
      new_text << "\n"

      { start_line_idx: if_idx - 1, end_line_idx: if_idx, new_text: }
    end

    def self.best_effort_lint_context(source, path: nil, profile: nil, label: "best_effort_lint_context")
      ast = profile_phase(profile, "#{label}.parse") { Parser.parse(source, path:) }
      imported_modules = {}
      unresolved_import_paths = Set.new

      resolved_path = resolve_lint_path(path)
      if resolved_path && File.file?(resolved_path)
        effective_platform = ModuleLoader.effective_platform_for_path(resolved_path)
        loader = ModuleLoader.new(
          module_roots: MilkTea::ModuleRoots.roots_for_path(resolved_path),
          package_graph: load_lint_package_graph(resolved_path),
          source_overrides: { resolved_path => source },
          platform: effective_platform,
        )
        ast = profile_phase(profile, "#{label}.load_root") { loader.load_file(resolved_path) }
        resolution = profile_phase(profile, "#{label}.imports") do
          loader.imported_modules_for_ast_collecting_errors(ast, importer_path: resolved_path)
        end
        imported_modules = resolution.modules
        unresolved_import_paths.merge(resolution.errors.filter_map { |entry| entry.import&.path&.to_s })
      end

      sema_snapshot = profile_phase(profile, "#{label}.sema") do
        Sema.tooling_snapshot(ast, imported_modules: imported_modules, path: resolved_path || path)
      end

      {
        ast: ast,
        facts: sema_snapshot.facts,
        sema_snapshot: sema_snapshot,
        errors: sema_snapshot.diagnostics,
        imported_modules: imported_modules,
        unresolved_import_paths: unresolved_import_paths,
      }
    rescue StandardError
      { ast: nil, facts: nil, sema_snapshot: nil, errors: nil, imported_modules: {}, unresolved_import_paths: Set.new }
    end

    def self.best_effort_sema_facts(source, path: nil)
      best_effort_lint_context(source, path:).fetch(:facts)
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

    def self.remove_inline_unsafe_prefix(line, column:)
      start_idx = column - 1
      return line unless start_idx >= 0 && start_idx < line.length

      prefix = line[0...start_idx]
      suffix = line[start_idx..]
      return line unless suffix&.start_with?("unsafe:")

      prefix + suffix.sub(/\Aunsafe:\s*/, "")
    end

    def self.redundant_ignored_match_binding_span(line, column:)
      anchor_idx = column - 1
      return nil unless anchor_idx >= 0 && anchor_idx < line.length

      scan_start = [anchor_idx - 5, 0].max
      match = line[scan_start..]&.match(/\s+as\s+_/)
      return nil unless match

      start_char = scan_start + match.begin(0)
      end_char = scan_start + match.end(0)
      return nil unless anchor_idx >= start_char && anchor_idx < end_char

      {
        start_char:,
        end_char:,
      }
    end

    def self.load_lint_package_graph(path)
      PackageGraph.load(path)
    rescue PackageManifestError, PackageLockError
      nil
    end

    def self.prefix_cast_sites(source, facts: nil)
      byte_offset = 0
      sites = []

      source.each_line.with_index(1) do |raw_line, line_number|
        line = raw_line.delete_suffix("\n")
        line_prefix_cast_sites(line, line_number, facts:).each do |site|
          sites << PrefixCastSite.new(
            line: site.line,
            column: site.column,
            length: site.length,
            target_text: site.target_text,
            replacement_text: site.replacement_text,
            start_offset: byte_offset + site.start_offset,
            end_offset: byte_offset + site.end_offset,
            pointer_like: site.pointer_like,
            literal_source: site.literal_source,
          )
        end
        byte_offset += raw_line.bytesize
      end

      sites
    end

    def self.line_prefix_cast_sites(line, line_number, facts: nil)
      return [] unless line.include?("<-")

      indent_width = line[/\A\s*/].length
      lexed_line = line[indent_width..] || ""
      tokens = Lexer.lex(lexed_line)
      less_indices = tokens.each_index.select do |index|
        token = tokens[index]
        minus = tokens[index + 1]
        token.type == :less && minus&.type == :minus && contiguous_tokens?(token, minus)
      end
      return [] if less_indices.empty?

      seen = Set.new
      less_indices.each_with_object([]) do |less_index, sites|
        matching_site = nil
        tokens[0...less_index].each_index.select { |index| tokens[index].type == :identifier }.each do |start_index|
          site = parse_prefix_cast_site(lexed_line, line_number, tokens[start_index].start_offset, facts:)
          next unless site
          next unless site.start_offset <= tokens[less_index].start_offset && tokens[less_index].start_offset < site.end_offset

          matching_site = PrefixCastSite.new(
            line: site.line,
            column: site.column + indent_width,
            length: site.length,
            target_text: site.target_text,
            replacement_text: site.replacement_text,
            start_offset: site.start_offset + indent_width,
            end_offset: site.end_offset + indent_width,
            pointer_like: site.pointer_like,
            literal_source: site.literal_source,
          )
          break
        end
        next unless matching_site

        key = [matching_site.start_offset, matching_site.end_offset]
        next if seen.include?(key)

        seen << key
        sites << matching_site
      end
    rescue LexError
      # Best-effort single-line scanning cannot lex heredoc opener lines such as
      # `<<-TAG`, which also contain `<-`. Skip those lines instead of aborting
      # redundant-cast analysis for the whole file.
      []
    end

    def self.parse_prefix_cast_site(line, line_number, start_offset, facts: nil)
      snippet = line.byteslice(start_offset, line.bytesize - start_offset)
      return nil unless snippet&.include?("<-")

      snippet_for_parse = snippet
      tokens = nil
      loop do
        tokens = Lexer.lex(snippet_for_parse)
        break
      rescue LexError => e
        match = e.message.match(/unexpected closing delimiter at \d+:(\d+)/)
        raise e unless match

        closer_index = match[1].to_i - 1
        raise e if closer_index <= 0

        snippet_for_parse = snippet_for_parse.byteslice(0, closer_index).rstrip
        raise e if snippet_for_parse.nil? || snippet_for_parse.empty?
      end

      parser = Parser.new(tokens)
      seed_prefix_cast_parser!(parser, facts)
      expression = parser.send(:parse_unary)
      return nil unless prefix_cast_expression?(expression)

      current = parser.instance_variable_get(:@current)
      consumed_tokens = tokens[0...current].reject(&:eof?)
      return nil if consumed_tokens.empty?

      less_index = consumed_tokens.each_index.find do |index|
        token = consumed_tokens[index]
        minus = consumed_tokens[index + 1]
        token.type == :less && minus&.type == :minus && contiguous_tokens?(token, minus)
      end
      return nil unless less_index

      source_token = consumed_tokens[(less_index + 2)..]&.first
      return nil unless source_token

      target_type = expression.callee.arguments.first.value
      end_offset = consumed_tokens.last.end_offset
      target_text = snippet_for_parse.byteslice(0, consumed_tokens[less_index].start_offset).rstrip
      replacement_text = snippet_for_parse.byteslice(source_token.start_offset, end_offset - source_token.start_offset)
      return nil if target_text.empty? || replacement_text.nil? || replacement_text.empty?

      PrefixCastSite.new(
        line: line_number,
        column: start_offset + 1,
        length: end_offset,
        target_text: target_text,
        replacement_text: replacement_text,
        start_offset: start_offset,
        end_offset: start_offset + end_offset,
        pointer_like: target_type.is_a?(AST::TypeRef) && !target_type.nullable && %w[ptr const_ptr ref].include?(target_type.name.to_s),
        literal_source: expression.arguments.first.value.is_a?(AST::IntegerLiteral) || expression.arguments.first.value.is_a?(AST::FloatLiteral),
      )
    rescue ParseError
      nil
    end

    def self.seed_prefix_cast_parser!(parser, facts)
      return unless facts

      known_type_names = parser.instance_variable_get(:@known_type_names)
      facts.types.each_key { |name| known_type_names[name] = true }
      facts.interfaces.each_key { |name| known_type_names[name] = true }

      known_import_aliases = parser.instance_variable_get(:@known_import_aliases)
      facts.imports.each_key { |name| known_import_aliases[name] = true }
    end

    def self.prefix_cast_expression?(expression)
      return false unless expression.is_a?(AST::Call)

      callee = expression.callee
      return false unless callee.is_a?(AST::Specialization)
      return false unless callee.callee.is_a?(AST::Identifier) && callee.callee.name == "cast"
      return false unless callee.arguments.length == 1 && expression.arguments.length == 1

      callee.arguments.first.value.is_a?(AST::TypeRef)
    end

    def self.contiguous_tokens?(left, right)
      left.line == right.line && right.column == (left.column + left.lexeme.length)
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

    def initialize(path: nil, sema_facts: nil, source: nil, unresolved_import_paths: nil, imported_modules: nil, source_ast: nil, profile: nil, lint_tier: :full, max_line_length: nil)
      @path = path
      @sema_facts = sema_facts
      @unresolved_import_paths = (unresolved_import_paths || Set.new).to_set
      @imported_modules = (imported_modules || {}).dup
      @source = source.to_s
      @source_lines = source ? source.lines.map { |line| line.delete_suffix("\n") } : []
      @source_ast = source_ast
      @profile = profile
      @warnings = []
      @scopes = []
      @module_bindings = {}
      @declared_callable_names = Set.new
      @declared_directional_functions = {}
      @generic_function_depth = 0
      @current_function_stack = []
      @prefix_cast_sites = nil
      @redundant_cast_context_site_keys = Set.new
      @contextual_redundant_cast_details = {}
      @recheck_context_cache = {}
      @reserved_primitive_name_fixes = []
      @lint_tier = self.class.normalize_lint_tier(lint_tier)
      @max_line_length = max_line_length&.to_i&.positive? ? max_line_length.to_i : Formatter::DEFAULT_MAX_LINE_LENGTH
      @cfg_binding_resolution = nil
      @cfg_binding_resolution_computed = false
      @statement_flow_analysis_cache = {}
      @dead_assignment_analysis_cache = {}
    end

    def lint(ast)
      @source_ast ||= ast
      visit_source_file(ast)
      profile_phase("rule.line_too_long") { emit_line_too_long_warnings }
      profile_phase("rule.redundant_cast") { emit_redundant_cast_warnings } if expensive_lint_rules_enabled?
      @warnings
    end

    def reserved_primitive_name_fixes
      @reserved_primitive_name_fixes
    end

    private

    def emit_line_too_long_warnings
      return unless @max_line_length.positive?
      return if @source.empty?

      @source_lines.each_with_index do |line, index|
        next if line.empty?
        next unless line.length > @max_line_length

        fix = Formatter.build_long_line_wrap_fix(@source, index, max_line_length: @max_line_length, path: @path)
        message = "line exceeds max length of #{@max_line_length} columns (#{line.length})"
        message << "; wrap the expression" if fix
        @warnings << Warning.new(
          path: @path,
          line: index + 1,
          column: @max_line_length + 1,
          length: line.length - @max_line_length,
          code: "line-too-long",
          message:,
          severity: :warning,
        )
      end
    end

    def profile_phase(name)
      return yield unless @profile

      @profile.measure(name) { yield }
    end

    def visit_source_file(source_file)
      @declared_callable_names = declared_callable_names(source_file)
      @declared_directional_functions = declared_directional_functions(source_file)
      profile_phase("seed_module_bindings") { seed_module_bindings(source_file) }
      profile_phase("rule.unused_imports") { check_unused_imports(source_file) }
      profile_phase("rule.platform_api_drift") { check_platform_api_drift(source_file) }
      source_file.declarations.each do |declaration|
        case declaration
        when AST::FunctionDef
          visit_function(declaration)
        when AST::MethodDef
          warn_reserved_primitive_name(declaration.name, line: declaration.line, column: declaration.column, kind_label: "function")
          visit_function(declaration)
        when AST::ExtendingBlock
          generic_context = methods_block_generic?(declaration)
          declaration.methods.each do |method|
            warn_reserved_primitive_name(method.name, line: method.line, column: method.column, kind_label: "function")
            visit_function(method, generic_context:)
          end
        end
      end
    end

    def seed_module_bindings(source_file)
      @module_bindings = {}

      import_names = source_file.imports.filter_map do |import|
        import.alias_name || import.path.parts.last
      end
      source_file.imports.each do |import|
        local_name = import.alias_name || import.path.parts.last
        next if ignored_binding_name?(local_name)

        declare_reserved_import_alias_module_binding(
          local_name,
          kind_label: "import alias",
          line: import.line,
          column: import.column,
          unavailable_names: import_names,
        )
      end

      source_file.declarations.each do |declaration|
        kind_label = case declaration
                     when AST::FunctionDef, AST::ExternFunctionDecl, AST::ForeignFunctionDecl
                       "function"
                     when AST::ConstDecl
                       "constant"
                     when AST::VarDecl
                       "module variable"
                     when AST::EventDecl
                       "event"
                     else
                       nil
                     end
        next unless kind_label
        next if ignored_binding_name?(declaration.name)

        declare_reserved_primitive_module_binding(
          declaration.name,
          kind_label:,
          line: declaration.line,
          column: declaration_column(declaration),
          unavailable_names: @declared_callable_names,
        )
      end
    end

    def declare_reserved_value_type_module_binding(name, kind_label:, line:, column:, unavailable_names:)
      declare_reserved_module_binding(
        name,
        kind_label:,
        line:,
        column:,
        unavailable_names:,
        reserved_names: RESERVED_VALUE_TYPE_NAMES,
      )
    end

    def declare_reserved_import_alias_module_binding(name, kind_label:, line:, column:, unavailable_names:)
      declare_reserved_module_binding(
        name,
        kind_label:,
        line:,
        column:,
        unavailable_names:,
        reserved_names: RESERVED_IMPORT_ALIAS_NAMES,
      )
    end

    def declare_reserved_module_binding(name, kind_label:, line:, column:, unavailable_names:, reserved_names:)
      replacement_name = nil
      replacement_base_name = nil
      if reserved_names.include?(name)
        replacement_base_name = suggested_reserved_primitive_name(name, kind_label:)
        replacement_name = next_available_reserved_primitive_name(
          replacement_base_name,
          unavailable_names,
        )
      end

      binding = Binding.new(
        name:,
        line:,
        column:,
        used: false,
        binding_kind: :module,
        allow_prefer_let: false,
        mutated: false,
        replacement_name:,
        replacement_base_name:,
      )
      register_reserved_primitive_name_fix(binding, kind_label:, replacement_name:) if replacement_name
      @module_bindings[name] = binding
    end

    def declare_reserved_primitive_module_binding(name, kind_label:, line:, column:, unavailable_names:)
      declare_reserved_value_type_module_binding(name, kind_label:, line:, column:, unavailable_names:)
    end

    def methods_block_generic?(declaration)
      declaration.type_name.respond_to?(:arguments) && declaration.type_name.arguments.any?
    end

    def declared_callable_names(source_file)
      source_file.declarations.each_with_object(Set.new) do |declaration, names|
        case declaration
        when AST::FunctionDef, AST::ExternFunctionDecl, AST::ForeignFunctionDecl,
             AST::ConstDecl, AST::VarDecl, AST::EventDecl
          names << declaration.name
        end
      end
    end

    def declared_directional_functions(source_file)
      source_file.declarations.each_with_object({}) do |declaration, functions|
        next unless declaration.is_a?(AST::ExternFunctionDecl) || declaration.is_a?(AST::ForeignFunctionDecl)
        next unless declaration.params.any? { |param| %i[in out inout].include?(param.mode) }

        functions[declaration.name] = declaration
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

      current_surface_sites = exported_api_surface_sites(source_file)
      current_surface = current_surface_sites.keys.to_set
      sibling_paths.each do |sibling_path|
        sibling_source_file = load_sibling_source_file(sibling_path)
        next unless sibling_source_file
        next unless sibling_source_file.module_name.to_s == source_file.module_name.to_s

        sibling_surface = exported_api_surface(sibling_source_file)
        next if sibling_surface == current_surface

        missing = (sibling_surface - current_surface).to_a.sort
        extra = (current_surface - sibling_surface).to_a.sort
        anchor = platform_api_drift_anchor(source_file, current_surface_sites, extra:)
        @warnings << Warning.new(
          path: @path,
          line: anchor[:line],
          column: anchor[:column],
          length: anchor[:length],
          code: "platform-api-drift",
          message: platform_api_drift_message(sibling_path, missing:, extra:),
          symbol_name: anchor[:symbol_name],
        )
      end
    end

    def platform_api_drift_anchor(source_file, current_surface_sites, extra:)
      extra.each do |surface_entry|
        site = current_surface_sites[surface_entry]
        return site if site
      end

      first_export_site = current_surface_sites.values.min_by do |site|
        [site[:line] || Float::INFINITY, site[:column] || Float::INFINITY]
      end
      return first_export_site if first_export_site

      first_declaration = source_file.declarations.find { |declaration| declaration.respond_to?(:line) && declaration.line }
      return declaration_anchor(first_declaration) if first_declaration

      { line: source_file.line || 1, column: 1, length: 1, symbol_name: nil }
    end

    def exported_api_surface_sites(source_file)
      exported_type_names = exported_type_names(source_file)
      source_file.declarations.each_with_object({}) do |declaration, sites|
        case declaration
        when AST::ConstDecl
          sites[render_value_surface("const", declaration)] = declaration_anchor(declaration) if exported_declaration?(source_file, declaration)
        when AST::VarDecl
          sites[render_value_surface("var", declaration)] = declaration_anchor(declaration) if exported_declaration?(source_file, declaration)
        when AST::EventDecl
          sites[render_event_surface(declaration)] = declaration_anchor(declaration) if exported_declaration?(source_file, declaration)
        when AST::TypeAliasDecl
          sites["type #{declaration.name} = #{render_type_surface(declaration.target)}"] = declaration_anchor(declaration) if exported_declaration?(source_file, declaration)
        when AST::StructDecl
          sites[render_struct_surface(declaration)] = declaration_anchor(declaration) if exported_declaration?(source_file, declaration)
        when AST::UnionDecl
          sites[render_union_surface(declaration)] = declaration_anchor(declaration) if exported_declaration?(source_file, declaration)
        when AST::EnumDecl
          sites[render_enum_surface("enum", declaration)] = declaration_anchor(declaration) if exported_declaration?(source_file, declaration)
        when AST::FlagsDecl
          sites[render_enum_surface("flags", declaration)] = declaration_anchor(declaration) if exported_declaration?(source_file, declaration)
        when AST::OpaqueDecl
          sites[render_opaque_surface(declaration)] = declaration_anchor(declaration) if exported_declaration?(source_file, declaration)
        when AST::InterfaceDecl
          sites[render_interface_surface(declaration)] = declaration_anchor(declaration) if exported_declaration?(source_file, declaration)
        when AST::VariantDecl
          sites[render_variant_surface(declaration)] = declaration_anchor(declaration) if exported_declaration?(source_file, declaration)
        when AST::FunctionDef
          sites[render_callable_surface("function", declaration)] = declaration_anchor(declaration) if exported_declaration?(source_file, declaration)
        when AST::ExternFunctionDecl
          sites[render_callable_surface("external function", declaration, variadic: declaration.variadic)] = declaration_anchor(declaration) if exported_declaration?(source_file, declaration)
        when AST::ForeignFunctionDecl
          sites[render_callable_surface("foreign function", declaration, variadic: declaration.variadic)] = declaration_anchor(declaration) if exported_declaration?(source_file, declaration)
        when AST::ExtendingBlock
          next unless exported_type_names.include?(declaration.type_name.to_s)

          declaration.methods.each do |method|
            next unless method.visibility == :public

            sites[render_method_surface(declaration.type_name.to_s, method)] = declaration_anchor(method)
          end
        end
      end
    end

    def declaration_anchor(declaration)
      return { line: 1, column: 1, length: 1, symbol_name: nil } unless declaration

      symbol_name = declaration.respond_to?(:name) ? declaration.name : nil
      length = symbol_name.to_s.empty? ? 1 : symbol_name.to_s.length
      line = declaration.respond_to?(:line) && declaration.line ? declaration.line : 1

      if declaration.respond_to?(:column) && declaration.column
        return { line:, column: declaration.column, length:, symbol_name: }
      end

      if symbol_name && line
        line_text = @source_lines[line - 1].to_s
        index = line_text.index(symbol_name.to_s)
        return { line:, column: index ? index + 1 : 1, length:, symbol_name: }
      end

      { line:, column: 1, length: 1, symbol_name: }
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
        when AST::EventDecl
          surface << render_event_surface(declaration) if exported_declaration?(source_file, declaration)
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
        when AST::ExtendingBlock
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

    def render_event_surface(declaration)
      text = +"event #{declaration.name}[#{declaration.capacity}]"
      text << "(#{render_type_surface(declaration.payload_type)})" if declaration.payload_type
      text
    end

    def render_struct_surface(declaration)
      prefix = render_attribute_applications_surface(declaration.attributes)
      text = +""
      text << "#{prefix} " unless prefix.empty?
      text << "struct #{declaration.name}#{render_type_params_surface(declaration.type_params)}#{render_implements_surface(declaration.implements)}"
      members = []
      members.concat(declaration.fields.map { |field| "#{field.name}: #{render_type_surface(field.type)}" })
      members.concat(declaration.events.map { |event| render_event_surface(event) })
      text << " { #{members.join(', ')} }"
      text
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

    def render_attribute_applications_surface(attributes)
      attributes.map { |attribute| render_attribute_application_surface(attribute) }.join(' ')
    end

    def render_attribute_application_surface(attribute)
      text = +"@[#{attribute.name}"
      unless attribute.arguments.empty?
        rendered_arguments = attribute.arguments.map do |argument|
          value = case argument.value
                  when AST::IntegerLiteral, AST::FloatLiteral
                    argument.value.lexeme
                  when AST::StringLiteral
                    argument.value.lexeme
                  when AST::Identifier
                    argument.value.name
                  when AST::MemberAccess
                    "#{argument.value.receiver.name}.#{argument.value.member}"
                  else
                    "..."
                  end
          argument.name ? "#{argument.name} = #{value}" : value
        end
        text << "(#{rendered_arguments.join(', ')})"
      end
      text << "]"
      text
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
          raise "unsupported type parameter constraint #{constraint.kind}"
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
      return Set.new unless @sema_facts

      called_members = Set.new
      source_file.declarations.each do |decl|
        collect_called_members_from_declaration(decl, called_members)
      end
      return Set.new if called_members.empty?

      @sema_facts.imports.each_with_object(Set.new) do |(local_name, imported_module), used|
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
      when AST::ExtendingBlock
        decl.methods.each { |m| collect_names_from_declaration(m, used) }
      when AST::StructDecl
        decl.fields.each { |f| collect_names_from_type(f.type, used) }
        decl.events.each { |event| collect_names_from_type(event.payload_type, used) if event.payload_type }
      when AST::UnionDecl
        decl.fields.each { |f| collect_names_from_type(f.type, used) }
      when AST::TypeAliasDecl
        collect_names_from_type(decl.target, used)
      when AST::EventDecl
        collect_names_from_type(decl.payload_type, used) if decl.payload_type
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
      when AST::ExtendingBlock
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

    def visit_function(function, generic_context: false)
      generic_body = generic_context || function.type_params.any?
      @generic_function_depth += 1 if generic_body
      @current_function_stack << function
      with_scope do
        profile_phase("rule.reserved_primitive_type_params") do
          warn_reserved_primitive_type_params(function.type_params, kind_label: "type parameter")
        end
        profile_phase("declare_params") do
          function.params.each do |param|
            declare_param(
              param.name,
              line: param_line(param, fallback: function.line),
              column: param_column(param)
            )
          end
        end
        profile_phase("visit_statement_list") { visit_statement_list(function.body) }
        profile_phase("rule.dead_assignment") { emit_dead_assignment_warnings(function.body) }
        profile_phase("rule.unreachable") { emit_unreachable_warnings(function.body) }
        profile_phase("rule.borrow") { emit_borrow_warnings(function.body) }
        profile_phase("rule.constant_condition") { emit_constant_condition_warnings(function.body) }
        profile_phase("rule.redundant_null_check") { emit_redundant_null_check_warnings(function.body) }
        profile_phase("rule.prefer_let_else") { emit_prefer_let_else_warnings(function.body) }
        profile_phase("rule.redundant_read_cast") { emit_redundant_read_cast_warnings(function.body) }
        profile_phase("rule.redundant_read_release_temp") { emit_redundant_read_release_temp_warnings(function.body) }
        profile_phase("rule.redundant_unsafe") { emit_redundant_unsafe_warnings(function.body) } if expensive_lint_rules_enabled?
        profile_phase("rule.redundant_return") { emit_redundant_return_warnings(function) }
        profile_phase("rule.loop_single_iteration") { emit_loop_single_iteration_warnings(function.body) }
      end
      profile_phase("rule.missing_return") { check_missing_return(function) }
    ensure
      @current_function_stack.pop
      @generic_function_depth -= 1 if generic_body
    end

    def generic_function_context?
      @generic_function_depth > 0
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

    def emit_redundant_return_warnings(function)
      return unless function.return_type
      return unless void_return_type?(function.return_type)

      final_statement = function.body&.last
      return unless final_statement.is_a?(AST::ReturnStmt)
      return unless final_statement.value.nil?

      @warnings << Warning.new(
        path: @path,
        line: final_statement.line,
        column: final_statement.column,
        length: final_statement.length || "return".length,
        code: "redundant-return",
        message: "final bare return in void function is redundant",
        severity: :hint,
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
    # Fire when every explicit if/else if branch always returns, making the else
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
        if statement.type && statement.value
          remember_contextual_redundant_cast_site(
            statement.value,
            expected_type_text: render_type_surface(statement.type),
            preferred_lines: [statement.line],
          )
        end
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
            warn_redundant_ignored_match_binding(arm.binding_name, line: binding_line, column: binding_column)
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
        if statement.value && current_function&.return_type
          remember_contextual_redundant_cast_site(
            statement.value,
            expected_type_text: render_type_surface(current_function.return_type),
            preferred_lines: [statement.line],
          )
        end
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
        mark_used(expression.name, identifier: expression)
      when AST::MemberAccess
        visit_expression(expression.receiver)
      when AST::IndexAccess
        visit_expression(expression.receiver)
        visit_expression(expression.index)
      when AST::Specialization
        visit_expression(expression.callee)
        expression.arguments.each { |argument| visit_type_argument(argument) }
      when AST::Call
        remember_contextual_call_argument_cast_sites(expression)
        visit_expression(expression.callee)
        expression.arguments.each do |argument|
          visit_expression(argument.value)
          mark_call_argument_mutated(argument.value)
        end
        mark_alias_source_mutated(expression)
        mark_call_receiver_mutated(expression)
        check_directional_ffi_call(expression)
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
      when AST::MatchExpr
        visit_expression(expression.expression)
        expression.arms.each do |arm|
          with_scope do
            binding_line = arm.binding_line || expression.line
            binding_column = arm.binding_column
            warn_redundant_ignored_match_binding(arm.binding_name, line: binding_line, column: binding_column)
            declare_local(arm.binding_name, binding_line, column: binding_column, var: false) if arm.binding_name
            visit_expression(arm.value)
          end
        end
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
          emit_prefer_let_else_warnings(expression.body)
          emit_redundant_read_cast_warnings(expression.body)
          emit_redundant_read_release_temp_warnings(expression.body)
          emit_redundant_unsafe_warnings(expression.body) if expensive_lint_rules_enabled?
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

      mark_used(target.name, identifier: target) if target.is_a?(AST::Identifier)
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

      @sema_facts&.binding_resolution&.mutating_argument_identifier_ids&.key?(expression.object_id)
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
      return true unless @sema_facts

      @sema_facts&.binding_resolution&.mutable_receiver_expression_ids&.key?(expression.object_id)
    end

    def with_scope
      @scopes << {}
      yield
    ensure
      emit_scope_warnings(@scopes.pop)
    end

    def declare_local(name, line, column: nil, var: false)
      return if ignored_binding_name?(name)

      resolve_reserved_primitive_name_conflicts!(name)

      replacement_name = nil
      replacement_base_name = nil
      if RESERVED_VALUE_TYPE_NAMES.include?(name)
        replacement_base_name = suggested_reserved_primitive_name(name, kind_label: "local")
        replacement_name = next_available_reserved_primitive_name(
          replacement_base_name,
          visible_binding_names(excluding_name: name),
        )
      end

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
        allow_prefer_let: var && !generic_function_context?,
        mutated: false,
        replacement_name:,
        replacement_base_name:,
      )
      register_reserved_primitive_name_fix(@scopes.last[name], kind_label: "local", replacement_name:) if replacement_name
    end

    def declare_param(name, line: nil, column: nil)
      return if ignored_binding_name?(name)

      resolve_reserved_primitive_name_conflicts!(name)

      replacement_name = nil
      replacement_base_name = nil
      if RESERVED_VALUE_TYPE_NAMES.include?(name)
        replacement_base_name = suggested_reserved_primitive_name(name, kind_label: "parameter")
        replacement_name = next_available_reserved_primitive_name(
          replacement_base_name,
          visible_binding_names(excluding_name: name),
        )
      end

      @scopes.last[name] = Binding.new(
        name:, line:, column:, used: false,
        binding_kind: :param,
        allow_prefer_let: false,
        mutated: false,
        replacement_name:,
        replacement_base_name:,
      )
      register_reserved_primitive_name_fix(@scopes.last[name], kind_label: "parameter", replacement_name:) if replacement_name
    end

    def warn_reserved_primitive_name(name, line:, column:, kind_label:, reserved_names: RESERVED_VALUE_TYPE_NAMES)
      return unless reserved_names.include?(name)

      @warnings << Warning.new(
        path: @path,
        line:,
        column:,
        length: name.length,
        code: "reserved-primitive-name",
        message: "#{kind_label} '#{name}' uses reserved built-in type name '#{name}'; rename it before this becomes a hard error",
        severity: :warning,
        symbol_name: name,
      )
    end

    def warn_redundant_ignored_match_binding(name, line:, column:)
      return unless name == "_"

      span = nil
      if line && column
        source_line = @source_lines[line - 1].to_s
        span = self.class.redundant_ignored_match_binding_span(source_line, column:)
      end

      @warnings << Warning.new(
        path: @path,
        line:,
        column: span ? span[:start_char] + 1 : column,
        length: span ? span[:end_char] - span[:start_char] : 1,
        code: "redundant-ignored-match-binding",
        message: "ignored match binding is redundant; remove 'as _'",
        severity: :hint,
      )
    end

    def warn_reserved_primitive_type_params(type_params, kind_label:)
      Array(type_params).each do |type_param|
        warn_reserved_primitive_name(
          type_param.name,
          line: type_param.line,
          column: type_param.column,
          kind_label:,
          reserved_names: RESERVED_TYPE_BINDING_NAMES,
        )
      end
    end

    def register_reserved_primitive_name_fix(binding, kind_label:, replacement_name:)
      warn_reserved_primitive_name(binding.name, line: binding.line, column: binding.column, kind_label:)
      return unless binding.line && binding.column

      binding.fix_index = @reserved_primitive_name_fixes.length
      @reserved_primitive_name_fixes << ReservedPrimitiveNameFix.new(
        kind: kind_label,
        original_name: binding.name,
        replacement_name: replacement_name,
        sites: [ReservedPrimitiveNameSite.new(line: binding.line, column: binding.column, length: binding.name.length)],
      )
    end

    def suggested_reserved_primitive_name(name, kind_label:)
      case kind_label
      when "function"
        "#{name}_fn"
      when "import alias"
        "#{name}_module"
      else
        "#{name}_value"
      end
    end

    def next_available_reserved_primitive_name(base_name, unavailable_names)
      unavailable = unavailable_names.to_set
      return base_name unless unavailable.include?(base_name)

      suffix = 2
      loop do
        candidate = "#{base_name}_#{suffix}"
        return candidate unless unavailable.include?(candidate)

        suffix += 1
      end
    end

    def visible_binding_names(excluding_name: nil)
      names = visible_bindings.each_with_object(Set.new) do |binding, result|
        result << binding.name
        result << binding.replacement_name if binding.replacement_name
      end
      names.delete(excluding_name) if excluding_name
      names
    end

    def visible_bindings
      @module_bindings.values + @scopes.flat_map(&:values)
    end

    def resolve_reserved_primitive_name_conflicts!(declared_name)
      visible_bindings.each do |binding|
        next unless binding.replacement_name == declared_name

        replacement_name = next_available_reserved_primitive_name(
          binding.replacement_base_name || binding.replacement_name,
          visible_binding_names(excluding_name: binding.name),
        )
        next if replacement_name == binding.replacement_name

        binding.replacement_name = replacement_name
        next unless binding.fix_index

        fix = @reserved_primitive_name_fixes[binding.fix_index]
        @reserved_primitive_name_fixes[binding.fix_index] = fix.with(replacement_name:)
      end
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

    def mark_used(name, identifier: nil)
      @scopes.reverse_each do |scope|
        binding = scope[name]
        next unless binding

        binding.used = true
        record_reserved_primitive_identifier_use(binding, identifier)
        return
      end

      binding = @module_bindings[name]
      return unless binding

      binding.used = true
      record_reserved_primitive_identifier_use(binding, identifier)
    end

    def record_reserved_primitive_identifier_use(binding, identifier)
      return unless binding.fix_index
      return unless identifier&.line && identifier&.column

      @reserved_primitive_name_fixes[binding.fix_index].sites << ReservedPrimitiveNameSite.new(
        line: identifier.line,
        column: identifier.column,
        length: binding.name.length,
      )
    end

    def emit_dead_assignment_warnings(stmts)
      analysis = dead_assignment_analysis(stmts)
      return unless analysis

      graph = analysis.graph
      liveness = analysis.liveness
      readable_bindings = analysis.readable_bindings
      locally_declared = analysis.locally_declared

      graph.each_node do |node|
        node.writes_info.each do |write|
          next if write[:origin] == :call_argument
            next if write[:origin] == :declaration

          binding_key = write[:binding_key]
          name = write[:name]
          next unless readable_bindings.include?(binding_key)
          next unless locally_declared.include?(binding_key)
          next if liveness.live_out[node.id].include?(binding_key)

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

    def emit_unreachable_warnings(stmts)
      analysis = statement_flow_analysis(stmts)
      return unless analysis

      graph = analysis.graph
      reachable = analysis.reachability

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
      return @cfg_binding_resolution if @cfg_binding_resolution_computed

      binding_resolution = @sema_facts&.binding_resolution
      @cfg_binding_resolution = if binding_resolution
                                  CFG::BindingResolution.new(
                                    identifier_binding_ids: binding_resolution.identifier_binding_ids,
                                    declaration_binding_ids: binding_resolution.declaration_binding_ids,
                                    mutating_argument_identifier_ids: binding_resolution.mutating_argument_identifier_ids,
                                  )
                                end
      @cfg_binding_resolution_computed = true
      @cfg_binding_resolution
    end

    def statement_flow_analysis(stmts)
      return nil if stmts.nil? || stmts.empty?

      @statement_flow_analysis_cache[stmts.object_id] ||= begin
        binding_resolution = cfg_binding_resolution
        graph = profile_phase("flow.graph") do
          CFG::Builder.new(ignore_name: method(:ignored_binding_name?), binding_resolution:).build(stmts)
        end
        reachability = profile_phase("flow.reachability") { CFG::Reachability.solve(graph) }
        nullability = profile_phase("flow.nullability") { CFG::NullabilityFlow.solve(graph) }
        constant_propagation = profile_phase("flow.constant_propagation") do
          CFG::ConstantPropagation.solve(graph, binding_resolution:, strict_binding_ids: !binding_resolution.nil?)
        end
        loop_body_nodes = profile_phase("flow.loop_body_nodes") { compute_loop_body_nodes(graph) }
        StatementFlowAnalysis.new(graph:, reachability:, nullability:, constant_propagation:, loop_body_nodes:)
      end
    end

    def dead_assignment_analysis(stmts)
      return nil if stmts.nil? || stmts.empty?

      @dead_assignment_analysis_cache[stmts.object_id] ||= begin
        binding_resolution = cfg_binding_resolution
        graph = profile_phase("dead_assignment.graph") do
          CFG::Builder.new(
            ignore_name: method(:ignored_binding_name?),
            binding_resolution:,
            local_decl_without_initializer_writes: true,
          ).build(stmts)
        end
        liveness = profile_phase("dead_assignment.liveness") { CFG::Liveness.solve(graph) }
        locally_declared = profile_phase("dead_assignment.locals") do
          graph.each_node.each_with_object(Set.new) do |node, bindings|
            node.writes_info.each do |write|
              bindings << write[:binding_key] if write[:origin] == :declaration
            end
          end
        end
        DeadAssignmentAnalysis.new(
          graph:,
          liveness:,
          readable_bindings: graph.read_bindings,
          locally_declared:,
        )
      end
    end

    def cfg_identifier_binding_key(identifier)
      binding_resolution = cfg_binding_resolution
      return identifier.name unless binding_resolution

      binding_resolution.identifier_binding_ids[identifier.object_id] || identifier.name
    end

    def ignored_binding_name?(name)
      name == "_" || name.start_with?("_")
    end

    def expensive_lint_rules_enabled?
      @lint_tier == :full
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

      analysis = statement_flow_analysis(stmts)
      return unless analysis

      binding_resolution = cfg_binding_resolution
      graph = analysis.graph
      cp = analysis.constant_propagation
      loop_bodies = analysis.loop_body_nodes

      graph.each_node do |node|
        cond_expr, line, keyword_pattern, skip_node =
          case node.kind
          when :if_condition
            branch = node.statement
            # Skip if conditions inside loops; variables can change across iterations.
            skip = loop_bodies.include?(node.id)
            [branch&.condition, branch&.line || node.line, "else if|if", skip]
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

      analysis = statement_flow_analysis(stmts)
      return unless analysis

      graph = analysis.graph
      nf = analysis.nullability

      graph.each_node do |node|
        next unless node.kind == :if_condition

        branch = node.statement
        next unless branch.is_a?(AST::IfBranch)

        identifier = null_check_identifier(branch.condition)
        next unless identifier
        next if ignored_binding_name?(identifier.name)

        nonnull = nf.nonnull_before(branch)
        next unless nonnull.include?(cfg_identifier_binding_key(identifier))

        line, column, length = condition_span(branch.condition, line: node.line, keyword_pattern: "else if|if")

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

    # ── prefer-let-else ────────────────────────────────────────────────

    def emit_prefer_let_else_warnings(stmts)
      return if stmts.nil? || stmts.empty?

      walk_statement_lists(stmts) do |statement_list|
        statement_list.each_with_index do |_statement, index|
          candidate = prefer_let_else_candidate(statement_list, index)
          next unless candidate

          branch = candidate[:branch]
          line, column, length = condition_span(branch.condition, line: candidate[:if_stmt].line, keyword_pattern: "if")

          @warnings << Warning.new(
            path: @path,
            line:,
            column:,
            length:,
            code: "prefer-let-else",
            message: "nullable guard for '#{candidate[:declaration].name}' can use let ... else",
            severity: :hint,
            symbol_name: candidate[:declaration].name
          )
        end
      end
    end

    def prefer_let_else_candidate(stmts, index)
      declaration = stmts[index]
      if_stmt = stmts[index + 1]
      return unless declaration.is_a?(AST::LocalDecl)
      return unless declaration.kind == :let
      return if declaration.type || declaration.else_binding || declaration.else_body || declaration.recovered_else
      return unless declaration.value && declaration.name
      return if ignored_binding_name?(declaration.name)
      return unless if_stmt.is_a?(AST::IfStmt)
      return unless if_stmt.else_body.nil? && if_stmt.branches.length == 1

      branch = if_stmt.branches.first
      identifier = null_equality_identifier(branch.condition)
      return unless identifier&.name == declaration.name
      return unless nullable_binding_declaration?(declaration)
      return unless CFG::Termination.block_always_terminates?(branch.body, ignore_name: method(:ignored_binding_name?), binding_resolution: cfg_binding_resolution)

      { declaration:, if_stmt:, branch: }
    end

    def null_equality_identifier(cond)
      return nil unless cond.is_a?(AST::BinaryOp) && cond.operator == "=="

      if cond.left.is_a?(AST::Identifier) && cond.right.is_a?(AST::NullLiteral)
        cond.left
      elsif cond.left.is_a?(AST::NullLiteral) && cond.right.is_a?(AST::Identifier)
        cond.right
      end
    end

    def nullable_binding_declaration?(statement)
      binding_type = binding_type_for_declaration(statement)
      return binding_type.is_a?(Types::Nullable) if binding_type

      nullable_initializer_without_binding_type?(statement.value)
    end

    def nullable_initializer_without_binding_type?(expression)
      case expression
      when AST::Identifier, AST::MemberAccess, AST::IndexAccess, AST::Call, AST::IfExpr, AST::MatchExpr
        true
      when AST::AwaitExpr, AST::UnsafeExpr
        nullable_initializer_without_binding_type?(expression.expression)
      else
        false
      end
    end

    def binding_type_for_declaration(statement)
      binding_resolution = @sema_facts&.binding_resolution
      return nil unless binding_resolution&.binding_types

      binding_id = binding_resolution.declaration_binding_ids[statement.object_id]
      return nil unless binding_id

      binding_resolution.binding_types[binding_id]
    end

    # ── redundant-read-cast ──────────────────────────────────────────────

    def emit_redundant_read_cast_warnings(stmts)
      return if stmts.nil? || stmts.empty?

      binding_resolution = @sema_facts&.binding_resolution
      binding_types = binding_resolution&.binding_types
      cfg_resolution = cfg_binding_resolution
      return unless binding_resolution && binding_types && cfg_resolution

      analysis = statement_flow_analysis(stmts)
      return unless analysis

      graph = analysis.graph
      nf = analysis.nullability
      seen = Set.new

      graph.each_node do |node|
        statement = node.statement
        next unless statement
        next if seen.include?(statement.object_id)

        seen << statement.object_id
        warn_redundant_read_casts_in_statement(statement, nonnull: nf.nonnull_before(statement), binding_resolution:, binding_types:)
      end
    end

    def warn_redundant_read_casts_in_statement(statement, nonnull:, binding_resolution:, binding_types:)
      each_statement_expression(statement) do |expression|
        candidate = redundant_read_cast_candidate(expression)
        next unless candidate

        source = candidate[:source]
        binding_id = binding_resolution.identifier_binding_ids[source.object_id]
        next unless binding_id

        binding_type = binding_types[binding_id]
        next unless binding_type

        target_text = render_type_surface(candidate[:target_type])
        redundant = if binding_type.to_s == target_text
                      true
                    elsif binding_type.is_a?(Types::Nullable) && binding_type.base.to_s == target_text
                      nonnull.include?(binding_id)
                    else
                      false
                    end
        next unless redundant

        @warnings << Warning.new(
          path: @path,
          line: expression_line(candidate[:cast_expression]) || expression_line(source),
          column: expression_column(candidate[:cast_expression]) || expression_column(source),
          length: expression_length(candidate[:cast_expression]) || expression_length(source),
          code: "redundant-read-cast",
          message: "cast to #{target_text} is redundant here; use read(#{source.name}) directly",
          severity: :hint,
          symbol_name: source.name
        )
      end
    end

    def redundant_read_cast_candidate(expression)
      return unless expression.is_a?(AST::Call)
      return unless expression.callee.is_a?(AST::Identifier) && expression.callee.name == "read"
      return unless expression.arguments.length == 1

      cast = pointer_like_cast_expression(expression.arguments.first.value)
      return unless cast
      return unless cast[:source].is_a?(AST::Identifier)

      {
        source: cast[:source],
        target_type: cast[:target_type],
        cast_expression: expression.arguments.first.value,
      }
    end

    def pointer_like_cast_expression(expression)
      return unless expression.is_a?(AST::Call)

      callee = expression.callee
      return unless callee.is_a?(AST::Specialization)
      return unless callee.callee.is_a?(AST::Identifier) && callee.callee.name == "cast"
      return unless callee.arguments.length == 1 && expression.arguments.length == 1

      target_type = callee.arguments.first.value
      return unless target_type.is_a?(AST::TypeRef)
      return unless pointer_like_type_ref?(target_type)

      { target_type:, source: expression.arguments.first.value }
    end

    # ── redundant-cast ───────────────────────────────────────────────────

    def current_function
      @current_function_stack.last
    end

    def remember_contextual_redundant_cast_site(expression, expected_type_text:, preferred_lines:, used_site_keys: nil)
      return unless expected_type_text

      site = contextual_redundant_cast_site(
        expression,
        expected_type_text:,
        preferred_lines:,
        used_site_keys: used_site_keys || Set.new,
      )
      return unless site

      @redundant_cast_context_site_keys << prefix_cast_site_key(site)
      @contextual_redundant_cast_details[prefix_cast_site_key(site)] = {
        source_expression: expression.arguments.first.value,
        expected_type_text: expected_type_text,
      }
    end

    def remember_contextual_call_argument_cast_sites(expression)
      params = callable_params_for_expression(expression.callee)
      return if params.nil? || params.empty?

      positional_index = 0
      used_site_keys = Set.new
      expression.arguments.each do |argument|
        parameter = if argument.name
                      params.find { |param| parameter_name(param) == argument.name }
                    else
                      params[positional_index].tap { positional_index += 1 }
                    end
        next unless parameter

        expected_type_text = render_parameter_type_surface(parameter)
        next unless expected_type_text

        remember_contextual_redundant_cast_site(
          argument.value,
          expected_type_text:,
          preferred_lines: [expression_line(argument.value), expression_line(expression)],
          used_site_keys:,
        )
      end
    end

    def contextual_redundant_cast_site(expression, expected_type_text:, preferred_lines:, used_site_keys:)
      return unless prefix_cast_expression?(expression)

      target_type = expression.callee.arguments.first.value
      return unless render_type_surface(target_type) == expected_type_text

      lines = Array(preferred_lines).compact.uniq
      return if lines.empty?

      prefix_cast_sites.find do |site|
        next false if used_site_keys.include?(prefix_cast_site_key(site))
        next false unless site.target_text == expected_type_text
        next false unless lines.include?(site.line)

        used_site_keys << prefix_cast_site_key(site)
        true
      end
    end

    def callable_params_for_expression(callee)
      return unless @sema_facts

      case callee
      when AST::Specialization
        callable_params_for_expression(callee.callee)
      when AST::Identifier
        if (binding = @sema_facts.functions[callee.name])
          return binding.type.params
        end

        if (binding = @sema_facts.values[callee.name]) && binding.type.respond_to?(:params)
          return binding.type.params
        end

        nil
      when AST::MemberAccess
        return nil unless callee.receiver.is_a?(AST::Identifier)

        imported_module = @sema_facts.imports[callee.receiver.name]
        return nil unless imported_module

        binding = imported_module.functions[callee.member]
        binding&.type&.params
      else
        nil
      end
    end

    def render_parameter_type_surface(parameter)
      return nil unless parameter.respond_to?(:type) && parameter.type

      render_type_surface(parameter.type)
    end

    def prefix_cast_expression?(expression)
      self.class.prefix_cast_expression?(expression)
    end

    def prefix_cast_site_key(site)
      [site.start_offset, site.end_offset]
    end

    def contextual_redundant_cast_site?(site)
      @redundant_cast_context_site_keys.include?(prefix_cast_site_key(site))
    end

    def emit_redundant_cast_warnings
      return unless @sema_facts
      return if @source.empty?

      prefix_cast_sites.each do |site|
        next if site.pointer_like
        next unless site.literal_source || contextual_redundant_cast_site?(site)
        next unless redundant_cast_site?(site)

        @warnings << Warning.new(
          path: @path,
          line: site.line,
          column: site.column,
          length: site.length,
          code: "redundant-cast",
          message: "cast to #{site.target_text} is redundant here; remove the cast",
          severity: :hint,
        )
      end
    end

    def prefix_cast_sites
      @prefix_cast_sites ||= profile_phase("rule.redundant_cast.scan_candidates") do
        self.class.prefix_cast_sites(@source, facts: @sema_facts)
      end
    end

    def redundant_cast_site?(site)
      modified_source = @source.dup
      modified_source[site.start_offset...site.end_offset] = site.replacement_text
      context = recheck_context(modified_source, label: "redundant_cast_recheck")
      return false unless context[:facts]

      modified_counts = error_signature_counts(context[:errors])
      baseline_counts = current_error_signature_counts
      return true unless introduces_new_errors?(modified_counts, baseline_counts)

      contextual_redundant_cast_site?(site) && contextual_cast_source_implicitly_compatible?(site)
    end

    def pointer_like_type_ref?(type_ref)
      return false if type_ref.nullable

      %w[ptr const_ptr ref].include?(type_ref.name.to_s)
    end

    def each_statement_expression(statement, &block)
      case statement
      when AST::LocalDecl
        walk_expression_tree(statement.value, &block)
      when AST::Assignment
        walk_expression_tree(statement.target, &block)
        walk_expression_tree(statement.value, &block)
      when AST::IfBranch
        walk_expression_tree(statement.condition, &block)
      when AST::IfStmt
        statement.branches.each { |branch| walk_expression_tree(branch.condition, &block) }
      when AST::WhileStmt
        walk_expression_tree(statement.condition, &block)
      when AST::ForStmt
        statement.iterables.each { |iterable| walk_expression_tree(iterable, &block) }
      when AST::MatchStmt
        walk_expression_tree(statement.expression, &block)
      when AST::ReturnStmt
        walk_expression_tree(statement.value, &block)
      when AST::DeferStmt
        walk_expression_tree(statement.expression, &block)
      when AST::ExpressionStmt
        walk_expression_tree(statement.expression, &block)
      when AST::StaticAssert
        walk_expression_tree(statement.condition, &block)
      end
    end

    def walk_expression_tree(expression, &block)
      return unless expression

      yield expression
      case expression
      when AST::MemberAccess
        walk_expression_tree(expression.receiver, &block)
      when AST::IndexAccess
        walk_expression_tree(expression.receiver, &block)
        walk_expression_tree(expression.index, &block)
      when AST::Specialization
        walk_expression_tree(expression.callee, &block)
      when AST::Call
        walk_expression_tree(expression.callee, &block)
        expression.arguments.each { |argument| walk_expression_tree(argument.value, &block) }
      when AST::UnaryOp
        walk_expression_tree(expression.operand, &block)
      when AST::BinaryOp
        walk_expression_tree(expression.left, &block)
        walk_expression_tree(expression.right, &block)
      when AST::RangeExpr
        walk_expression_tree(expression.start_expr, &block)
        walk_expression_tree(expression.end_expr, &block)
      when AST::ExpressionList
        expression.elements.each { |element| walk_expression_tree(element, &block) }
      when AST::IfExpr
        walk_expression_tree(expression.condition, &block)
        walk_expression_tree(expression.then_expression, &block)
        walk_expression_tree(expression.else_expression, &block)
      when AST::AwaitExpr
        walk_expression_tree(expression.expression, &block)
      when AST::UnsafeExpr
        walk_expression_tree(expression.expression, &block)
      when AST::FormatString
        expression.parts.each do |part|
          walk_expression_tree(part.expression, &block) if part.is_a?(AST::FormatExprPart)
        end
      end
    end

    # ── redundant-read-release-temp ─────────────────────────────────────

    def emit_redundant_read_release_temp_warnings(stmts)
      return if stmts.nil? || stmts.empty?

      walk_statement_lists(stmts) do |statement_list|
        statement_list.each_with_index do |_statement, index|
          candidate = redundant_read_release_temp_candidate(statement_list, index)
          next unless candidate

          declaration = candidate[:declaration]
          @warnings << Warning.new(
            path: @path,
            line: declaration.line,
            column: declaration.column,
            length: declaration.name.length,
            code: "redundant-read-release-temp",
            message: "temporary '#{declaration.name}' only stores read(...) to call release(); use read(...).release() directly",
            severity: :hint,
            symbol_name: declaration.name
          )
        end
      end
    end

    def redundant_read_release_temp_candidate(stmts, index)
      declaration = stmts[index]
      release_stmt = stmts[index + 1]
      return unless declaration.is_a?(AST::LocalDecl)
      return unless declaration.kind == :var
      return unless declaration.value && declaration.name
      return if ignored_binding_name?(declaration.name)
      return unless read_call_expression?(declaration.value)
      return unless release_stmt.is_a?(AST::ExpressionStmt)
      return unless release_call_on_identifier?(release_stmt.expression, declaration.name)
      return if stmts[(index + 2)..]&.any? { |statement| statement_uses_identifier?(statement, declaration.name) }

      { declaration:, release_stmt: }
    end

    def read_call_expression?(expression)
      expression.is_a?(AST::Call) &&
        expression.callee.is_a?(AST::Identifier) &&
        expression.callee.name == "read" &&
        expression.arguments.length == 1
    end

    def release_call_on_identifier?(expression, name)
      expression.is_a?(AST::Call) &&
        expression.callee.is_a?(AST::MemberAccess) &&
        expression.callee.member == "release" &&
        expression.callee.receiver.is_a?(AST::Identifier) &&
        expression.callee.receiver.name == name &&
        expression.arguments.empty?
    end

    def statement_uses_identifier?(statement, name)
      catch(:statement_uses_identifier) do
        each_statement_expression(statement) do |expression|
          throw(:statement_uses_identifier, true) if expression.is_a?(AST::Identifier) && expression.name == name
        end
        false
      end
    end

    def walk_statement_lists(stmts, &block)
      return if stmts.nil? || stmts.empty?

      yield stmts
      stmts.each do |statement|
        case statement
        when AST::IfStmt
          statement.branches.each { |branch| walk_statement_lists(branch.body, &block) }
          walk_statement_lists(statement.else_body, &block) if statement.else_body
        when AST::MatchStmt
          statement.arms.each { |arm| walk_statement_lists(arm.body, &block) }
        when AST::UnsafeStmt, AST::ForStmt, AST::WhileStmt
          walk_statement_lists(statement.body, &block)
        when AST::DeferStmt
          walk_statement_lists(statement.body, &block) if statement.body
        end
      end
    end

    # ── directional-ffi-arg ──────────────────────────────────────────────

    def check_directional_ffi_call(expression)
      call = resolve_directional_ffi_call(expression.callee)
      return unless call

      call[:params].zip(expression.arguments).each do |parameter, argument|
        next unless parameter && argument

        passing_mode = parameter_passing_mode(parameter)
        next unless %i[in out inout].include?(passing_mode)
        next unless legacy_directional_argument_expression?(argument.value)

        @warnings << Warning.new(
          path: @path,
          line: expression_line(argument.value),
          column: expression_column(argument.value),
          length: expression_length(argument.value),
          code: "directional-ffi-arg",
          message: "pass the lvalue directly to '#{call[:name]}'; parameter '#{parameter_name(parameter)}' already declares #{passing_mode} passing",
          severity: :hint,
          symbol_name: parameter_name(parameter)
        )
      end
    end

    def resolve_directional_ffi_call(callee)
      case callee
      when AST::Specialization
        resolve_directional_ffi_call(callee.callee)
      when AST::Identifier
        if @sema_facts && (binding = @sema_facts.functions[callee.name]) && directional_ffi_binding?(binding)
          return { name: binding.name, params: binding.type.params }
        end

        if (declaration = @declared_directional_functions[callee.name])
          return { name: declaration.name, params: declaration.params }
        end

        nil
      when AST::MemberAccess
        return nil unless callee.receiver.is_a?(AST::Identifier)
        return nil unless @sema_facts

        imported_module = @sema_facts.imports[callee.receiver.name]
        return nil unless imported_module

        binding = imported_module.functions[callee.member]
        return nil unless directional_ffi_binding?(binding)

        { name: binding.name, params: binding.type.params }
      else
        nil
      end
    end

    def directional_ffi_binding?(binding)
      return false unless binding
      return false unless binding.respond_to?(:ast) && (binding.ast.is_a?(AST::ExternFunctionDecl) || binding.ast.is_a?(AST::ForeignFunctionDecl))

      binding.type.params.any? { |parameter| %i[in out inout].include?(parameter.passing_mode) }
    end

    def parameter_passing_mode(parameter)
      parameter.respond_to?(:passing_mode) ? parameter.passing_mode : parameter.mode
    end

    def parameter_name(parameter)
      parameter.respond_to?(:name) ? parameter.name : "argument"
    end

    def legacy_directional_argument_expression?(expression)
      return true if expression.is_a?(AST::UnaryOp) && %w[in out inout].include?(expression.operator)

      if expression.is_a?(AST::Call) && expression.callee.is_a?(AST::Identifier) && %w[ptr_of ref_of].include?(expression.callee.name)
        return expression.arguments.length == 1
      end

      cast = pointer_like_cast_expression(expression)
      return false unless cast

      lvalue_expression?(cast[:source]) || legacy_directional_argument_expression?(cast[:source])
    end

    def lvalue_expression?(expression)
      expression.is_a?(AST::Identifier) || expression.is_a?(AST::MemberAccess) || expression.is_a?(AST::IndexAccess)
    end

    # ── redundant-unsafe ───────────────────────────────────────────────

    def emit_redundant_unsafe_warnings(stmts)
      return if stmts.nil? || stmts.empty?

      required_unsafe_lines = @sema_facts&.required_unsafe_lines
      return unless required_unsafe_lines

      walk_stmts_for_redundant_unsafe(stmts, required_unsafe_lines)
    end

    def walk_stmts_for_redundant_unsafe(stmts, required_unsafe_lines)
      stmts.each do |stmt|
        each_statement_expression(stmt) do |expression|
          next unless expression.is_a?(AST::UnsafeExpr)
          next unless redundant_unsafe_expression?(expression)

          @warnings << Warning.new(
            path: @path,
            line: expression.line,
            column: expression.column,
            length: expression.length || "unsafe".length,
            code: "redundant-unsafe",
            message: "unsafe expression does not contain any operation that requires unsafe",
            severity: :hint,
          )
        end

        case stmt
        when AST::UnsafeStmt
          if stmt.line && !required_unsafe_lines.include?(stmt.line) && !unsafe_block_contains_builtin_unsafe_syntax?(stmt.body)
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

    def redundant_unsafe_expression?(expression)
      return false unless expression.line && expression.column

      modified_source = source_without_inline_unsafe(expression.line, expression.column)
      return false unless modified_source

      context = recheck_context(modified_source, label: "redundant_unsafe_recheck")
      return false unless context[:facts]

      !introduces_new_errors?(error_signature_counts(context[:errors]), current_error_signature_counts)
    end

    def source_without_inline_unsafe(line, column)
      lines = @source.lines
      idx = line - 1
      return nil unless lines[idx]

      modified_line = self.class.remove_inline_unsafe_prefix(lines[idx], column:)
      return nil if modified_line == lines[idx]

      modified_lines = lines.dup
      modified_lines[idx] = modified_line
      modified_lines.join
    end

    def current_error_signature_counts
      @current_error_signature_counts ||= begin
        context = recheck_context(@source, label: "redundant_unsafe_baseline")
        error_signature_counts(context[:errors])
      end
    end

    # Recheck helpers are only used for small expression-local rewrites, so the
    # import graph and inferred module identity are unchanged. Reusing the
    # current file's imported module bindings avoids routing every candidate back
    # through ModuleLoader/import resolution.
    def recheck_context(source, label:)
      @recheck_context_cache[source] ||= begin
        ast = profile_phase("#{label}.parse") { Parser.parse(source, path: @path) }
        ast = with_recheck_module_identity(ast)
        sema_snapshot = profile_phase("#{label}.sema") do
          Sema.tooling_snapshot(ast, imported_modules: @imported_modules, path: @path)
        end
        {
          ast: ast,
          facts: sema_snapshot.facts,
          sema_snapshot: sema_snapshot,
          errors: sema_snapshot.diagnostics,
          imported_modules: @imported_modules,
          unresolved_import_paths: @unresolved_import_paths,
        }
      rescue StandardError
        {
          ast: nil,
          facts: nil,
          sema_snapshot: nil,
          errors: nil,
          imported_modules: @imported_modules,
          unresolved_import_paths: @unresolved_import_paths,
        }
      end
    end

    def with_recheck_module_identity(ast)
      return ast unless @source_ast&.module_name
      return ast if ast.module_name&.to_s == @source_ast.module_name.to_s

      AST::SourceFile.new(
        module_name: @source_ast.module_name,
        module_kind: ast.module_kind,
        imports: ast.imports,
        directives: ast.directives,
        declarations: ast.declarations,
        line: ast.line,
      )
    end

    def error_signature_counts(errors)
      Array(errors).each_with_object(Hash.new(0)) do |error, counts|
        counts[[error.line, error.column, error.message]] += 1
      end
    end

    def contextual_cast_source_implicitly_compatible?(site)
      detail = @contextual_redundant_cast_details[prefix_cast_site_key(site)]
      return false unless detail

      actual_type_text = expression_type_surface(detail[:source_expression])
      return false unless actual_type_text

      lossless_contextual_type_surface_compatibility?(actual_type_text, detail[:expected_type_text])
    end

    def expression_type_surface(expression)
      return nil unless @sema_facts

      case expression
      when AST::Identifier
        binding_id = @sema_facts.binding_resolution&.identifier_binding_ids&.[](expression.object_id)
        @sema_facts.binding_resolution&.binding_types&.[](binding_id)&.to_s
      else
        nil
      end
    end

    def lossless_contextual_type_surface_compatibility?(actual_type_text, expected_type_text)
      return true if actual_type_text == expected_type_text
      return true if lossless_integer_surface_compatibility?(actual_type_text, expected_type_text)
      return true if lossless_float_surface_compatibility?(actual_type_text, expected_type_text)

      false
    end

    def lossless_integer_surface_compatibility?(actual_type_text, expected_type_text)
      actual = integer_surface_info(actual_type_text)
      expected = integer_surface_info(expected_type_text)
      return false unless actual && expected

      if actual[:signed] == expected[:signed]
        return expected[:width] >= actual[:width]
      end

      return false if actual[:signed]

      expected[:signed] && expected[:width] > actual[:width]
    end

    def lossless_float_surface_compatibility?(actual_type_text, expected_type_text)
      actual_width = FLOAT_SURFACE_WIDTHS[actual_type_text]
      expected_width = FLOAT_SURFACE_WIDTHS[expected_type_text]
      actual_width && expected_width && expected_width >= actual_width
    end

    def integer_surface_info(type_text)
      INTEGER_SURFACE_INFO[type_text]
    end

    def introduces_new_errors?(modified_counts, baseline_counts)
      modified_counts.any? do |signature, count|
        count > baseline_counts.fetch(signature, 0)
      end
    end

    def unsafe_block_contains_builtin_unsafe_syntax?(stmts)
      stmts.any? { |stmt| statement_contains_builtin_unsafe_syntax?(stmt) }
    end

    def statement_contains_builtin_unsafe_syntax?(stmt)
      case stmt
      when AST::LocalDecl
        expression_contains_builtin_unsafe_syntax?(stmt.value)
      when AST::Assignment
        expression_contains_builtin_unsafe_syntax?(stmt.target) || expression_contains_builtin_unsafe_syntax?(stmt.value)
      when AST::IfStmt
        stmt.branches.any? do |branch|
          expression_contains_builtin_unsafe_syntax?(branch.condition) || unsafe_block_contains_builtin_unsafe_syntax?(branch.body)
        end || (stmt.else_body && unsafe_block_contains_builtin_unsafe_syntax?(stmt.else_body))
      when AST::MatchStmt
        expression_contains_builtin_unsafe_syntax?(stmt.expression) || stmt.arms.any? { |arm| unsafe_block_contains_builtin_unsafe_syntax?(arm.body) }
      when AST::ForStmt
        stmt.iterables.any? { |iterable| expression_contains_builtin_unsafe_syntax?(iterable) } || unsafe_block_contains_builtin_unsafe_syntax?(stmt.body)
      when AST::WhileStmt
        expression_contains_builtin_unsafe_syntax?(stmt.condition) || unsafe_block_contains_builtin_unsafe_syntax?(stmt.body)
      when AST::DeferStmt
        (stmt.expression && expression_contains_builtin_unsafe_syntax?(stmt.expression)) ||
          (stmt.body && unsafe_block_contains_builtin_unsafe_syntax?(stmt.body))
      when AST::ReturnStmt
        stmt.value && expression_contains_builtin_unsafe_syntax?(stmt.value)
      when AST::ExpressionStmt
        expression_contains_builtin_unsafe_syntax?(stmt.expression)
      when AST::StaticAssert
        expression_contains_builtin_unsafe_syntax?(stmt.condition)
      when AST::UnsafeStmt
        false
      else
        false
      end
    end

    def expression_contains_builtin_unsafe_syntax?(expression)
      case expression
      when nil
        false
      when AST::MemberAccess
        expression_contains_builtin_unsafe_syntax?(expression.receiver)
      when AST::IndexAccess
        expression_contains_builtin_unsafe_syntax?(expression.receiver) || expression_contains_builtin_unsafe_syntax?(expression.index)
      when AST::Specialization
        expression_contains_builtin_unsafe_syntax?(expression.callee)
      when AST::Call
        builtin_unsafe_call_syntax?(expression) ||
          expression_contains_builtin_unsafe_syntax?(expression.callee) ||
          expression.arguments.any? { |argument| expression_contains_builtin_unsafe_syntax?(argument.value) }
      when AST::UnaryOp
        expression_contains_builtin_unsafe_syntax?(expression.operand)
      when AST::BinaryOp
        expression_contains_builtin_unsafe_syntax?(expression.left) || expression_contains_builtin_unsafe_syntax?(expression.right)
      when AST::RangeExpr
        expression_contains_builtin_unsafe_syntax?(expression.start_expr) || expression_contains_builtin_unsafe_syntax?(expression.end_expr)
      when AST::ExpressionList
        expression.elements.any? { |element| expression_contains_builtin_unsafe_syntax?(element) }
      when AST::IfExpr
        expression_contains_builtin_unsafe_syntax?(expression.condition) ||
          expression_contains_builtin_unsafe_syntax?(expression.then_expression) ||
          expression_contains_builtin_unsafe_syntax?(expression.else_expression)
      when AST::UnsafeExpr, AST::ProcExpr
        false
      when AST::AwaitExpr
        expression_contains_builtin_unsafe_syntax?(expression.expression)
      when AST::FormatString
        expression.parts.any? do |part|
          part.is_a?(AST::FormatExprPart) && expression_contains_builtin_unsafe_syntax?(part.expression)
        end
      else
        false
      end
    end

    def builtin_unsafe_call_syntax?(expression)
      builtin_read_call_syntax?(expression) ||
        builtin_reinterpret_call_syntax?(expression) ||
        builtin_pointer_cast_call_syntax?(expression)
    end

    def builtin_read_call_syntax?(expression)
      return false unless expression.callee.is_a?(AST::Identifier)
      return false unless expression.callee.name == "read"

      !unsafe_builtin_name_shadowed?("read")
    end

    def builtin_reinterpret_call_syntax?(expression)
      return false unless expression.callee.is_a?(AST::Specialization)
      return false unless expression.callee.callee.is_a?(AST::Identifier)
      return false unless expression.callee.callee.name == "reinterpret"

      true
    end

    def builtin_pointer_cast_call_syntax?(expression)
      return false unless expression.callee.is_a?(AST::Specialization)
      return false unless expression.callee.callee.is_a?(AST::Identifier)
      return false unless expression.callee.callee.name == "cast"

      target_argument = expression.callee.arguments.first
      target_type = target_argument&.value
      target_type.is_a?(AST::TypeRef) && %w[ptr const_ptr].include?(target_type.name.to_s)
    end

    def unsafe_builtin_name_shadowed?(name)
      @scopes.reverse_each do |scope|
        return true if scope.key?(name)
      end

      @declared_callable_names.include?(name)
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

    # ── borrow facts helpers ──────────────────────────────────────────────────

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

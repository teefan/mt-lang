# frozen_string_literal: true

require "cgi/escape"
require "set"
require "uri"
require_relative "linter/doc_tags.rb"
require_relative "linter/fix_engine.rb"
require_relative "linter/flow_rules.rb"
require_relative "linter/imports_platform.rb"
require_relative "linter/release_rules.rb"
require_relative "linter/reserved_names.rb"
require_relative "linter/rules.rb"
require_relative "linter/source_helpers.rb"
require_relative "linter/trailing_comma.rb"
require_relative "linter/visitors.rb"

module MilkTea
  class Linter
    UNSET = Object.new.freeze
    DEFAULT_CONFIG_FILE_NAME = ".mt-lint.yml".freeze
    KNOWN_RULE_CODES = %w[
      borrow-and-mutate
      constant-condition
      dead-assignment
      duplicate-if-condition
      directional-ffi-arg
      doc-tag
      event-capacity
      line-too-long
      loop-single-iteration
      missing-return
      noop-compound-assignment
      platform-api-drift
      owning-release-leak
      owning-release-double
      prefer-conditional-expression
      prefer-inline-if
      prefer-is-variant
      prefer-let
      prefer-let-else
      prefer-or-pattern
      prefer-own-ptr
      prefer-struct-with
      prefer-try
      prefer-var-else
      redundant-bool-compare
      redundant-cast
      redundant-else
      redundant-ignored-match-binding
      redundant-null-check
      redundant-return
      redundant-type-annotation
      reserved-primitive-name
      self-assignment
      self-comparison
      shadow
      trailing-list-comma
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
      prefer-let
      redundant-ignored-match-binding
      prefer-let-else
      prefer-var-else
      redundant-bool-compare
      redundant-cast
      redundant-else
      redundant-return
      redundant-type-annotation
      reserved-primitive-name
      trailing-list-comma
    ].freeze
    # NOTE: `unused-import` is intentionally NOT auto-fixable. Removing an import
    # has non-local effects the linter cannot see under per-file validation:
    # it may drop extension methods / canonical hooks (`hash[T]`, `equal[T]`),
    # a bare-name type provided via the prelude bootstrap (e.g. `std.option`),
    # or break downstream consumers of a library module. It remains a reported
    # hint so authors can remove genuinely-unused imports deliberately.
    LINT_TIERS = %i[fast full].freeze
    STATIC_QUICK_FIX_TITLES = {
      "line-too-long" => "Wrap long line",
      "prefer-let" => "Replace 'var' with 'let'",
      "redundant-ignored-match-binding" => "Remove redundant as _",
      "redundant-bool-compare" => "Simplify boolean comparison",
      "redundant-cast" => "Remove redundant cast",
      "redundant-else" => "Remove redundant else",
      "redundant-return" => "Remove redundant return",
      "redundant-type-annotation" => "Remove redundant type annotation",
      "prefer-let-else" => "Rewrite as let-else",
      "prefer-var-else" => "Rewrite as var-else",
      "trailing-list-comma" => "Remove trailing list comma",
    }.freeze
    EVENT_STACK_SNAPSHOT_WARNING_THRESHOLD = 128
    FIX_ALL_TITLE = "Apply all auto-fixes".freeze

    # severity: :error | :warning | :hint
    Warning = Data.define(:path, :line, :column, :length, :code, :message, :severity, :symbol_name) do
      def initialize(path:, line:, column: nil, length: nil, code:, message:, severity: :warning, symbol_name: nil) = super

      def to_diagnostic
        Diagnostic.new(path:, line:, column:, length:, code:, message:, severity:, symbol_name:)
      end

      def as_json(*)
        {
          path:,
          line:,
          column:,
          length:,
          code:,
          message:,
          severity: severity.to_s,
          symbol_name:,
        }.compact
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

      def total_time_ms(prefix: nil)
        return @timings_ms.values.sum unless prefix

        @timings_ms.sum { |name, total_ms| name.start_with?(prefix) ? total_ms : 0.0 }
      end

      def rule_breakdown(limit: 10, min_ms: 0.1)
        @timings_ms
          .filter_map do |name, total_ms|
            next unless name.start_with?("rule.")
            next if total_ms < min_ms

            count = @counts[name]
            {
              phase: name,
              code: name.delete_prefix("rule.").tr("_", "-"),
              total_ms: total_ms,
              count:,
              avg_ms: count.positive? ? (total_ms / count) : total_ms,
            }
          end
          .sort_by { |entry| -entry[:total_ms] }
          .first(limit)
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
      if sema_facts_provided && !unresolved_import_paths_provided
        # Callers that already computed semantic facts should not pay for a
        # second context bootstrap only to derive unresolved imports.
        unresolved_import_paths = Set.new
        unresolved_import_paths_provided = true
      end
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
      suppressions = {}
      if source.match?(/#\s*lint:\s*ignore(?:\(|\b)/)
        trivia = profile_phase(profile, "lex_trivia") { Lexer.lex_with_trivia(source, path:).trivia }
        suppressions = profile_phase(profile, "parse_suppressions") { parse_suppressions(trivia) }
      end
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
    # prefer-let-else, prefer-var-else, redundant-bool-compare,
    # redundant-else,
    # redundant-return, reserved-primitive-name,
    # trailing-list-comma.
    # Returns the fixed source (may be identical if nothing was fixable).
    def self.fix_source(source, path: nil, sema_facts: nil, select: nil, ignore: nil, max_passes: 5, profile: nil)
      pass_limit = [max_passes.to_i, 1].max
      current_source = source
      current_sema_facts = sema_facts

      pass_limit.times do
        updated_source = fix_source_single_pass_isolating_rules(
          current_source,
          path:,
          sema_facts: current_sema_facts,
          select:,
          ignore:,
          profile:,
        )
        return current_source if updated_source == current_source

        current_source = updated_source
        # Facts passed by callers are only valid for the first source snapshot.
        current_sema_facts = nil
      end

      current_source
    end

    def self.fix_source_single_pass_isolating_rules(source, path: nil, sema_facts: nil, select: nil, ignore: nil, profile: nil)
      cfg = load_config(path)
      effective_select = select || cfg&.fetch(:select, nil)
      effective_ignore = ignore || cfg&.fetch(:ignore, nil)
      enabled_rules = AUTO_FIXABLE_RULE_CODES.select do |rule_code|
        next false if effective_select && !effective_select.include?(rule_code)
        next false if effective_ignore && effective_ignore.include?(rule_code)

        true
      end
      return source if enabled_rules.empty?

      current_source = source
      current_sema_facts = sema_facts

      # When no semantic facts are supplied, omit the argument entirely so
      # lint_source rebuilds a best-effort context. Passing an explicit `nil`
      # would suppress sema-dependent rules (e.g. widening redundant-cast).
      preflight_args = {
        path:,
        select: Set.new(enabled_rules),
        ignore: effective_ignore,
        profile:,
      }
      preflight_args[:sema_facts] = current_sema_facts if current_sema_facts
      preflight_warnings = lint_source(current_source, **preflight_args)
      return current_source if preflight_warnings.empty?

      preflight_codes = preflight_warnings.map(&:code).to_set
      active_rules = enabled_rules.select { |rule_code| preflight_codes.include?(rule_code) }
      return current_source if active_rules.empty?

      active_rules.each do |rule_code|
        updated_source = fix_source_single_pass(
          current_source,
          path:,
          sema_facts: current_sema_facts,
          select: Set[rule_code],
          ignore: effective_ignore,
        )
        next if updated_source == current_source

        current_source = updated_source
        current_sema_facts = nil
      end

      current_source
    end

    def self.fix_source_single_pass(source, path: nil, sema_facts: nil, select: nil, ignore: nil)
      cfg = load_config(path)
      effective_select = select || cfg&.fetch(:select, nil)
      effective_ignore = ignore || cfg&.fetch(:ignore, nil)
      rule_enabled = lambda do |code|
        next false if effective_select && !effective_select.include?(code)
        next false if effective_ignore && effective_ignore.include?(code)

        true
      end

      working_context = sema_facts ? nil : best_effort_lint_context(source, path:)
      working_sema_facts = sema_facts || working_context[:facts]
      unresolved_import_paths = sema_facts ? Set.new : working_context[:unresolved_import_paths]
      warnings = lint_source(
        source,
        path:,
        sema_facts: working_sema_facts,
        unresolved_import_paths:,
        select:,
        ignore:,
      )
      lines = source.lines

      warnings.group_by(&:code).each do |code, code_warnings|
        next unless rule_enabled.call(code)

        code_warnings.sort_by { |w| [-(w.line || 0), -(w.column || 0)] }.each do |warning|
          edits = FixEngine.edits_for_rule(code, lines, warning)
          FixEngine.apply_fix_edits(lines, edits)
        end
      end

      fixed_source = lines.join

      if rule_enabled.call("reserved-primitive-name")
        reserved_warnings = lint_source(fixed_source, path:, select: Set["reserved-primitive-name"]).select do |w|
          w.code == "reserved-primitive-name" && w.line && w.column && w.symbol_name
        end
        unless reserved_warnings.empty?
          warning_sites = reserved_warnings.each_with_object(Set.new) do |warning, sites|
            sites << [warning.line, warning.column, warning.symbol_name]
          end
          reserved_fixes = collect_reserved_primitive_name_fixes(fixed_source, path:).select do |fix|
            declaration_site = fix.sites.first
            warning_sites.include?([declaration_site.line, declaration_site.column, fix.original_name])
          end

          fixed_source = apply_reserved_primitive_name_fixes(fixed_source, reserved_fixes)
        end
      end
      # Validation compares a best-effort re-analysis of the fixed source against
      # a baseline. When the caller supplied rich (full-package) facts there is
      # no working_context, but the fixed-source check is still best-effort — so
      # the baseline must also come from a best-effort analysis of the ORIGINAL
      # source, otherwise pre-existing best-effort-only errors (e.g. unresolved
      # cross-module imports in std files) would be counted as "new" and reject
      # every otherwise-valid fix.
      baseline_context = working_context || best_effort_lint_context(source, path:)
      validated_fixed_source(source, fixed_source, path:, baseline_errors: baseline_context[:errors])
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
      declaration_match = declaration_base.match(/\A(\s*)(let|var)\s+#{Regexp.escape(name)}\s*=\s*.+\z/)
      return nil unless declaration_match
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
        SemanticAnalyzer.tooling_snapshot(ast, imported_modules: imported_modules, path: resolved_path || path)
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
      unresolved = ast ? ast.imports.map { |i| i.path.to_s }.to_set : Set.new
      { ast: nil, facts: nil, sema_snapshot: nil, errors: nil, imported_modules: {}, unresolved_import_paths: unresolved }
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

    def self.redundant_bool_compare_replacement(expression_text)
      match = expression_text.match(/\A\s*(.+?)\s*(==|!=)\s*(.+?)\s*\z/m)
      return nil unless match

      left_text = match[1].strip
      operator = match[2]
      right_text = match[3].strip
      left_bool = bool_literal_value(left_text)
      right_bool = bool_literal_value(right_text)
      return nil if left_bool.nil? == right_bool.nil?

      literal_value = left_bool.nil? ? right_bool : left_bool
      compared_text = left_bool.nil? ? left_text : right_text
      negate = if operator == "=="
                 literal_value == false
               else
                 literal_value == true
               end

      negate ? negate_expression_text(compared_text) : compared_text
    end

    def self.bool_literal_value(text)
      case text
      when "true" then true
      when "false" then false
      else nil
      end
    end

    def self.negate_expression_text(text)
      stripped = text.strip
      return "not #{stripped}" if stripped.match?(/\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\z/)

      "not (#{stripped})"
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

    def initialize(path: nil, sema_facts: nil, source: nil, unresolved_import_paths: nil, imported_modules: nil, source_ast: nil, profile: nil, lint_tier: :full, max_line_length: nil)
      @path = path
      @sema_facts = sema_facts
      @unresolved_import_paths = (unresolved_import_paths || Set.new).to_set
      @imported_modules = (imported_modules || {}).dup
      @source = source.to_s
      @source_lines = source ? source.lines.map { |line| line.delete_suffix("\n") } : []
      @tokens = begin
        Lexer.lex(@source, path: @path)
      rescue StandardError
        []
      end
      @token_index_by_location = @tokens.each_with_index.each_with_object({}) do |(token, index), locations|
        locations[[token.line, token.column]] ||= index
      end
      @tokens_by_line = @tokens.each_with_object(Hash.new { |hash, line| hash[line] = [] }) do |token, by_line|
        next if %i[newline indent dedent eof].include?(token.type)

        by_line[token.line] << token
      end
      @source_ast = source_ast
      @profile = profile
      @warnings = []
      @scopes = []
      @module_bindings = {}
      @declared_callable_names = Set.new
      @declared_directional_functions = {}
      @generic_function_depth = 0
      @current_function_stack = []
      @unsafe_depth = 0
      @binding_ptr_unsafe_uses = Hash.new { |h, k| h[k] = { safe: 0, unsafe: 0 } }
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
      profile_phase("rule.doc_tag") { emit_doc_tag_warnings(ast) } if full_tier?
      profile_phase("rule.event_capacity") { emit_event_capacity_warnings(ast) }
      profile_phase("rule.trailing_list_comma") { emit_trailing_list_comma_warnings(ast) }
      profile_phase("rule.line_too_long") { emit_line_too_long_warnings }
      @warnings
    end

    def full_tier?
      @lint_tier == :full
    end

    def reserved_primitive_name_fixes
      @reserved_primitive_name_fixes
    end

    private

    include LinterDocTags
    include LinterFlowRules
    include LinterImportsPlatform
    include LinterReleaseRules
    include LinterReservedNames
    include LinterRules
    include LinterSourceHelpers
    include LinterTrailingComma
    include LinterVisitors
  end
end

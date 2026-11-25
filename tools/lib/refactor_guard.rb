# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"

module MilkTea
  # Structural analysis of the self-host compiler tree for refactoring passes.
  #
  # The parity harnesses prove observable behavior; this guard measures and
  # ratchets the properties they cannot see: module layering, naming, dead
  # exports, duplication, size, and marker hygiene.  Textual by design: it
  # parses declarations and imports with anchored regexes over `projects/mtc`,
  # so it stays fast and independent of the compiler being refactored.
  #
  # Modes:
  #   report (default)      human report, exit 0
  #   --check               hard invariants: layering, naming, markers
  #   --check --strict      + new dead-export candidates vs the baseline
  #   --check --ratchet     + code/duplication growth and test-count drops
  #   --write-baseline      rewrite the committed baseline deterministically
  class RefactorGuard
    BASELINE_VERSION = 1
    DEFAULT_WINDOW = 12
    DIFFICULTY_FUNCTION_LINES = 200
    DIFFICULTY_FILE_CODE_LINES = 2_000

    SOURCE_ROOT = "projects/mtc/src"
    TEST_ROOTS = ["projects/mtc/test", "test/mt"].freeze
    MARKER_GLOBS = [
      "projects/mtc/src/**/*.mt",
      "projects/mtc/test/*.mt",
      "test/mt/*.mt",
      "lib/**/*.rb",
      "tools/*.rb",
      "tools/lib/*.rb",
      "tools/*.sh",
      "Rakefile",
    ].freeze

    # Rank 0 is foundational; an import may target an equal or lower rank.
    # Same-rank cycles are legal in Milk Tea and are allowed.
    LAYER_RANKS = {
      "float_text" => 0,
      "http_util" => 0,
      "strings" => 0,
      "profile" => 0,
      "version_info" => 0,
      "cli_help" => 0,
      "std_catalog" => 0,
      "browser" => 0,
      "wasm_shell" => 0,
      "docs_public" => 0,
      "lexer" => 1,
      "parser" => 2,
      # `c_naming` mangles semantic types, so it ranks with `semantic`.
      "c_naming" => 3,
      "semantic" => 3,
      "loader" => 4,
      "packages" => 4,
      # `linter` <-> `formatter.tidy` is a same-rank cycle (formatter consumes
      # lint config/warnings for fix candidates); `pretty_printer` formats the
      # IR, so it ranks with `ir`; `imported_bindings` tidy-formats its output.
      "linter" => 5,
      "formatter" => 5,
      "pretty_printer" => 5,
      "imported_bindings" => 5,
      "ir" => 5,
      "lowering" => 6,
      "sexpr" => 6,
      "debug_map" => 6,
      "c_backend" => 7,
      # `upstream_sources` holds the pinned vendored-source table and fetch
      # machinery; `build` must reach it to fetch a missing tree on demand, so it
      # ranks below `build`.
      "upstream_sources" => 7,
      "build" => 8,
      "build_cache" => 8,
      "bindgen" => 8,
      "lsp" => 9,
      "dap" => 9,
      "main" => 10,
      "docs_app" => 10,
      "wasm_preview" => 10,
      "toolchain_cli" => 10,
      "toolchain_bindings" => 10,
    }.freeze

    # Documented exceptions where a higher-ranked module legitimately imports a
    # higher-ranked one.  Each entry is "source_area -> target_area".
    ALLOWED_UPWARD = {
      # (empty: calibrate the rank table instead of adding exceptions)
    }.freeze

    ENTRY_POINTS = %w[main].freeze

    # Canonical aliases forced away from the basename by local shadowing.
    ALIAS_OVERRIDES = {
      # `source` and `package_source` are both common locals/parameters.
      "packages.source" => "pkg_source",
    }.freeze

    IMPORT_RE = /^\s*import\s+mtc\.([A-Za-z0-9_.]+)(?:\s+as\s+([A-Za-z_][A-Za-z0-9_]*))?/
    FUNCTION_RE = /^([ \t]*)(?:public\s+)?function\s+([A-Za-z_][A-Za-z0-9_]*)/
    TYPE_RE = /^([ \t]*)(?:public\s+)?(struct|enum|variant|type|interface)\s+([A-Za-z_][A-Za-z0-9_]*)/
    EVENT_RE = /^([ \t]*)(?:public\s+)?event\s+([A-Za-z_][A-Za-z0-9_]*)/
    CONST_RE = /^(?:public\s+)?const\s+([A-Za-z_][A-Za-z0-9_]*)/
    PUBLIC_DECL_RE = /^public\s+(function|struct|enum|variant|type|const|event|interface)\s+([A-Za-z_][A-Za-z0-9_]*)/
    MARKER_RE = /\b(TODO|FIXME|XXX|HACK)\b/
    WORD_RE = /[A-Za-z_][A-Za-z0-9_]*/

    DOTTED_IDENTIFIER_RE = /^[a-z][a-z0-9_]*$/
    PASCAL_TYPE_RE = /^[A-Z][A-Za-z0-9]*$/
    UPPER_SNAKE_RE = /^[A-Z][A-Z0-9_]*$/

    # The operation vocabulary: `create_*` constructs a value, `alloc_*`
    # allocates, `find_*` searches a collection/table, and compiler nodes use
    # the short `decl`/`expr` nouns.  The retired spellings are guarded so a
    # new inconsistency fails at the gate.
    VOCABULARY_PREFIXES = {
      "new_" => "create_ (or alloc_)",
      "lookup_" => "find_ (or resolve_)",
    }.freeze
    VOCABULARY_SUFFIXES = {
      "_declaration" => "_decl",
      "_expression" => "_expr",
    }.freeze

    class FileEntry
      attr_reader :path, :relative, :area, :lines

      def initialize(path:, relative:, area:, lines:)
        @path = path
        @relative = relative
        @area = area
        @lines = lines
      end

      def import_entries
        @import_entries ||= lines.each_with_index.filter_map do |line, index|
          match = IMPORT_RE.match(line)
          next unless match

          target = match[1]
          {
            target: target,
            alias: match[2] || target.split(".").last,
            path: relative,
            line: index + 1,
          }
        end
      end

      def imports
        @imports ||= import_entries.map { |entry| entry[:target] }.uniq
      end

      def declarations
        @declarations ||= lines.each_with_index.filter_map do |line, index|
          match = FUNCTION_RE.match(line)
          next { kind: "function", name: match[2], line: index + 1 } if match

          match = TYPE_RE.match(line)
          next { kind: match[2], name: match[3], line: index + 1 } if match

          match = EVENT_RE.match(line)
          next { kind: "event", name: match[2], line: index + 1 } if match

          match = CONST_RE.match(line)
          next { kind: "const", name: match[1], line: index + 1 } if match

          nil
        end
      end

      def functions
        @functions ||= begin
          list = []
          lines.each_with_index do |line, index|
            match = FUNCTION_RE.match(line)
            next unless match

            indent = match[1].length
            list << {
              name: match[2],
              line: index + 1,
              indent: indent,
              end_line: function_end(index, indent),
            }
          end
          list
        end
      end

      def function_end(start_index, indent)
        last = start_index
        index = start_index + 1

        # A signature may span lines.  Advance to its closing `:` so the body
        # scan starts at the body, not at a parameter line indented past the
        # declaration (which would otherwise end the function at the `)`).
        unless lines[start_index].rstrip.end_with?(":")
          while index < lines.length
            stripped = lines[index].strip
            if stripped.end_with?(":")
              last = index
              break
            end
            current_indent = lines[index][/\A[ \t]*/].length
            if !stripped.empty? && !stripped.start_with?("#") && current_indent <= indent && !stripped.start_with?(")")
              return start_index + 1
            end
            index += 1
          end
          return start_index + 1 if last == start_index
        end

        index = last + 1
        while index < lines.length
          text = lines[index]
          stripped = text.strip
          if stripped.empty? || stripped.start_with?("#")
            index += 1
            next
          end

          current_indent = text[/\A[ \t]*/].length
          break if current_indent <= indent

          last = index
          index += 1
        end
        last + 1
      end

      def code_lines
        lines.count { |line| !line.strip.empty? && !line.strip.start_with?("#") }
      end

      def max_line_length
        lines.map(&:length).max || 0
      end
    end

    attr_reader :root, :baseline_path, :window, :tolerance

    def initialize(root: Dir.pwd, baseline_path: nil, window: DEFAULT_WINDOW, tolerance: 0)
      @root = File.expand_path(root)
      @baseline_path = baseline_path || File.join(@root, "tools", "refactor_baseline.json")
      @window = window
      @tolerance = tolerance
    end

    def source_files
      @source_files ||= Dir.glob(File.join(root, SOURCE_ROOT, "**", "*.mt")).sort
    end

    def test_files
      @test_files ||= TEST_ROOTS.flat_map do |relative|
        Dir.glob(File.join(root, relative, "**", "*.mt"))
           .reject { |path| File.basename(path).start_with?("__mt_test_runner_") }
           .sort
      end
    end

    def marker_files
      @marker_files ||= MARKER_GLOBS.flat_map { |glob| Dir.glob(File.join(root, glob)) }.uniq.sort
    end

    def relative(path)
      path.delete_prefix("#{root}/")
    end

    def area_for(path)
      relative_source = path.delete_prefix(File.join(root, SOURCE_ROOT, "mtc") + "/")
      parts = relative_source.split("/")
      parts.length > 1 ? parts.first : File.basename(parts.first, ".mt")
    end

    def load_entry(path)
      FileEntry.new(path: path, relative: relative(path), area: area_for(path), lines: File.readlines(path, chomp: true))
    end

    def entries
      @entries ||= source_files.map { |path| load_entry(path) }
    end

    def layer_report
      edges = []
      violations = []

      entries.each do |entry|
        source_rank = LAYER_RANKS[entry.area]
        if source_rank.nil?
          violations << "#{entry.relative}: unclassified module area '#{entry.area}'"
          next
        end

        entry.imports.each do |target|
          target_area = target.split(".").first
          target_rank = LAYER_RANKS[target_area]
          if target_rank.nil?
            violations << "#{entry.relative}: unclassified import target '#{target}'"
            next
          end

          edge = "#{entry.area} -> #{target_area}"
          edges << edge
          next if target_rank <= source_rank

          next if ALLOWED_UPWARD.key?(edge)

          violations << "#{entry.relative}:#{import_line(entry, target)}: " \
                        "upward layer edge #{edge} (#{entry.area} rank #{source_rank} -> #{target_area} rank #{target_rank})"
        end
      end

      {
        ranks: LAYER_RANKS,
        edges: edges.uniq.sort,
        violations: violations.uniq.sort,
        exceptions: ALLOWED_UPWARD.keys.sort,
      }
    end

    def import_line(entry, target)
      index = entry.lines.index do |line|
        match = IMPORT_RE.match(line)
        match && match[1] == target
      end
      index.nil? ? 0 : index + 1
    end

    def alias_report
      forms = Hash.new { |hash, key| hash[key] = Hash.new { |inner, inner_key| inner[inner_key] = [] } }
      entries.each do |entry|
        entry.import_entries.each do |import|
          forms[import[:target]][import[:alias]] << import
        end
      end

      canon = {}
      violations = []
      entries.each do |entry|
        entry.import_entries.group_by { |import| import[:target] }.each do |target, uses|
          next if uses.length < 2

          violations << "#{entry.relative}:#{uses.last[:line]}: duplicate import of #{target}"
        end
        entry.import_entries.group_by { |import| import[:alias] }.each do |name, uses|
          targets = uses.map { |use| use[:target] }.uniq
          next if targets.length < 2

          violations << "#{entry.relative}:#{uses.last[:line]}: alias #{name} used for #{targets.join(', ')}"
        end
      end

      forms.each do |target, by_alias|
        counts = by_alias.transform_values(&:length)
        max = counts.values.max
        winners = counts.select { |_name, count| count == max }.keys.sort
        # A tie has no majority convention; prefer the longer, more descriptive
        # alias (`linter_mod` over a bare `linter`), then lexical order.
        canonical = ALIAS_OVERRIDES[target] || winners.max_by { |name| [name.length, name] }
        canon[target] = canonical
        if winners.length > 1 && !ALIAS_OVERRIDES.key?(target)
          violations << "#{target}: ambiguous alias #{winners.join(' / ')}"
        end

        by_alias.each do |name, uses|
          next if name == canonical

          uses.each do |use|
            violations << "#{use[:path]}:#{use[:line]}: #{target} as #{name} (canonical #{canonical})"
          end
        end
      end

      { canon: canon.sort.to_h, violations: violations.uniq.sort }
    end

    def naming_violations
      violations = []

      source_files.each do |path|
        basename = File.basename(path, ".mt")
        unless DOTTED_IDENTIFIER_RE.match?(basename)
          violations << { path: relative(path), line: 0, name: basename, expected: "file name snake_case" }
        end
      end

      entries.each do |entry|
        entry.declarations.each do |declaration|
          name = declaration[:name]
          kind = declaration[:kind]
          expected =
            case kind
            when "function", "event" then DOTTED_IDENTIFIER_RE
            when "struct", "enum", "variant", "type", "interface" then PASCAL_TYPE_RE
            when "const" then UPPER_SNAKE_RE
            end
          next unless expected
          next if expected.match?(name)

          level = kind == "function" ? "snake_case" : (kind == "const" ? "UPPER_SNAKE" : "PascalCase")
          violations << {
            path: entry.relative,
            line: declaration[:line],
            name: name,
            expected: "#{kind} name #{level}",
          }
        end
      end

      violations.sort_by { |violation| [violation[:path], violation[:line], violation[:name]] }
    end

    def vocabulary_violations
      violations = []
      entries.each do |entry|
        entry.declarations.each do |declaration|
          next unless declaration[:kind] == "function"

          name = declaration[:name]
          prefix = VOCABULARY_PREFIXES.keys.find { |candidate| name.start_with?(candidate) }
          suffix = VOCABULARY_SUFFIXES.keys.find { |candidate| name.end_with?(candidate) }
          if prefix
            violations << {
              path: entry.relative,
              line: declaration[:line],
              name: name,
              expected: "retired prefix #{prefix} (use #{VOCABULARY_PREFIXES[prefix]})",
            }
          elsif suffix
            violations << {
              path: entry.relative,
              line: declaration[:line],
              name: name,
              expected: "retired suffix #{suffix} (use #{VOCABULARY_SUFFIXES[suffix]})",
            }
          end
        end
      end
      violations.sort_by { |violation| [violation[:path], violation[:line], violation[:name]] }
    end

    def dead_exports
      declarations = entries.flat_map do |entry|
        entry.lines.each_with_index.filter_map do |line, index|
          match = PUBLIC_DECL_RE.match(line)
          next unless match

          {
            path: entry.relative,
            module: entry.area,
            kind: match[1],
            name: match[2],
            line: index + 1,
          }
        end
      end

      source_counts = identifier_counts(source_files)
      test_counts = identifier_counts(test_files)

      unused = []
      test_only = []
      declarations.each do |declaration|
        name = declaration[:name]
        next if ENTRY_POINTS.include?(name)

        source_references = [source_counts.fetch(name, 0) - 1, 0].max
        test_references = test_counts.fetch(name, 0)
        if source_references.zero?
          (test_references.positive? ? test_only : unused) << declaration
        end
      end

      {
        unused: unused.sort_by { |declaration| [declaration[:path], declaration[:line]] },
        test_only: test_only.sort_by { |declaration| [declaration[:path], declaration[:line]] },
      }
    end

    def identifier_counts(paths)
      counts = Hash.new(0)
      paths.each do |path|
        File.foreach(path) do |line|
          stripped = line.strip
          next if stripped.start_with?("#")

          line.scan(WORD_RE) { |word| counts[word] += 1 }
        end
      end
      counts
    end

    def duplication_report
      by_hash = Hash.new { |hash, key| hash[key] = [] }
      total_functions = 0

      entries.each do |entry|
        entry.functions.each do |function|
          normalized = (function[:line]...function[:end_line]).filter_map do |line_index|
            normalize_line(entry.lines[line_index] || "")
          end
          total_functions += 1
          next if normalized.length < window

          (0..(normalized.length - window)).each do |offset|
            slice = normalized[offset, window]
            digest = Digest::SHA1.hexdigest(slice.join("\n"))
            by_hash[digest] << {
              path: entry.relative,
              function: function[:name],
              line: function[:line] + offset,
            }
          end
        end
      end

      duplicated_windows = by_hash.select do |_digest, occurrences|
        occurrences.map { |occurrence| [occurrence[:path], occurrence[:function]] }.uniq.length > 1
      end

      line_keys = {}
      duplicated_windows.each_value do |occurrences|
        occurrences.each do |occurrence|
          window.times do |offset|
            line_keys[[occurrence[:path], occurrence[:function], occurrence[:line] + offset]] = true
          end
        end
      end

      clusters = duplicated_windows.map do |digest, occurrences|
        first = occurrences.min_by { |occurrence| [occurrence[:path], occurrence[:line]] }
        {
          digest: digest,
          first: first,
          occurrences: occurrences.sort_by { |occurrence| [occurrence[:path], occurrence[:line]] },
        }
      end

      clusters.sort_by! { |cluster| [-cluster[:occurrences].length, cluster[:first][:path], cluster[:first][:line]] }

      {
        window: window,
        functions: total_functions,
        windows: clusters.length,
        duplicated_lines: line_keys.length,
        fingerprints: clusters.map { |cluster| cluster[:digest] }.sort,
        clusters: clusters.first(15),
      }
    end

    def normalize_line(line)
      text = line.strip
      return nil if text.empty? || text.start_with?("#")

      text = text.gsub(/"(?:\\.|[^"\\])*"/, '"S"')
      text = text.gsub(/\b\d+(?:\.\d+)?\b/, "N")
      text.gsub(/\s+/, " ")
    end

    def size_report
      files = {}
      functions = []
      total_code = 0

      entries.each do |entry|
        file_functions = entry.functions.map do |function|
          length = function[:end_line] - function[:line] + 1
          {
            path: entry.relative,
            name: function[:name],
            line: function[:line],
            length: length,
          }
        end
        functions.concat(file_functions)
        code = entry.code_lines
        total_code += code
        files[entry.relative] = {
          lines: entry.lines.length,
          code: code,
          max_line: entry.max_line_length,
          max_function: file_functions.map { |function| function[:length] }.max || 0,
        }
      end

      {
        files: files.sort.to_h,
        total_code: total_code,
        functions_over_limit: functions.count { |function| function[:length] >= DIFFICULTY_FUNCTION_LINES },
        files_over_limit: files.count { |_path, stats| stats[:code] >= DIFFICULTY_FILE_CODE_LINES },
        longest_functions: functions.sort_by { |function| [-function[:length], function[:path], function[:line]] }.first(15),
        largest_files: files.sort_by { |path, stats| [-stats[:code], path] }.first(15),
      }
    end

    def marker_report
      markers = []
      marker_files.each do |path|
        # The guard itself names the marker words in its own regex/comment.
        next if relative(path) == "tools/lib/refactor_guard.rb"


        File.foreach(path).with_index(1) do |line, number|
          match = MARKER_RE.match(line)
          markers << { path: relative(path), line: number, marker: match[1] } if match
        end
      end
      markers.sort_by { |marker| [marker[:path], marker[:line], marker[:marker]] }
    end

    def test_report
      {
        projects: Dir.glob(File.join(root, "projects/mtc/test/**/*.mt"))
                    .reject { |path| File.basename(path).start_with?("__mt_test_runner_") }.length,
        test_mt: Dir.glob(File.join(root, "test/mt/**/*.mt"))
                   .reject { |path| File.basename(path).start_with?("__mt_test_runner_") }.length,
      }
    end

    def build_report
      layers = layer_report
      {
        version: BASELINE_VERSION,
        source: { files: source_files.length, lines: entries.sum { |entry| entry.lines.length } },
        layers: layers,
        naming: { violations: naming_violations },
        vocabulary: { violations: vocabulary_violations },
        aliases: alias_report,
        dead_exports: dead_exports,
        duplication: duplication_report,
        sizes: size_report,
        markers: marker_report,
        tests: test_report,
      }
    end

    def baseline_hash(report)
      {
        "version" => BASELINE_VERSION,
        "layers" => {
          "ranks" => report[:layers][:ranks].sort.to_h,
          "edges" => report[:layers][:edges].sort,
          "exceptions" => report[:layers][:exceptions].sort,
        },
        "naming" => report[:naming][:violations].map { |violation| format_violation(violation) }.sort,
        "vocabulary" => report[:vocabulary][:violations].map { |violation| format_violation(violation) }.sort,
        "aliases" => report[:aliases][:canon].sort.to_h,
        "dead_exports" => {
          "unused" => report[:dead_exports][:unused].map { |declaration| format_declaration(declaration) }.sort,
          "test_only" => report[:dead_exports][:test_only].map { |declaration| format_declaration(declaration) }.sort,
        },
        "duplication" => {
          "window" => report[:duplication][:window],
          "windows" => report[:duplication][:windows],
          "duplicated_lines" => report[:duplication][:duplicated_lines],
          "fingerprints" => report[:duplication][:fingerprints].sort,
        },
        "sizes" => {
          "total_code" => report[:sizes][:total_code],
          "functions_over_limit" => report[:sizes][:functions_over_limit],
          "files_over_limit" => report[:sizes][:files_over_limit],
          "files" => report[:sizes][:files].sort.to_h,
        },
        "markers" => report[:markers].map { |marker| format_marker(marker) }.sort,
        "tests" => report[:tests].sort.to_h,
      }
    end

    def format_violation(violation)
      "#{violation[:path]}:#{violation[:line]}:#{violation[:name]}:#{violation[:expected]}"
    end

    def format_declaration(declaration)
      "#{declaration[:path]}:#{declaration[:line]}:#{declaration[:kind]}:#{declaration[:name]}"
    end

    def format_marker(marker)
      "#{marker[:path]}:#{marker[:line]}:#{marker[:marker]}"
    end

    def write_baseline(report = build_report)
      FileUtils.mkdir_p(File.dirname(baseline_path))
      File.write(baseline_path, "#{JSON.pretty_generate(baseline_hash(report))}\n")
      baseline_path
    end

    def load_baseline
      return nil unless File.exist?(baseline_path)

      JSON.parse(File.read(baseline_path))
    rescue JSON::ParserError
      nil
    end

    def check(strict: false, ratchet: false)
      report = build_report
      baseline = load_baseline
      failures = []

      if (strict || ratchet) && baseline.nil?
        return [false, ["baseline missing: #{relative(baseline_path)} (run tools/refactor_guard.rb --write-baseline)"]]
      end

      failures.concat(report[:layers][:violations])
      failures.concat(report[:aliases][:violations])

      baseline_naming = Array(baseline && baseline["naming"])
      current_naming = report[:naming][:violations].map { |violation| format_violation(violation) }
      (current_naming - baseline_naming).sort.each { |entry| failures << "naming: #{entry}" }

      baseline_vocabulary = Array(baseline && baseline["vocabulary"])
      current_vocabulary = report[:vocabulary][:violations].map { |violation| format_violation(violation) }
      (current_vocabulary - baseline_vocabulary).sort.each { |entry| failures << "vocabulary: #{entry}" }

      baseline_markers = Array(baseline && baseline["markers"])
      current_markers = report[:markers].map { |marker| format_marker(marker) }
      (current_markers - baseline_markers).sort.each { |entry| failures << "marker: #{entry}" }

      if strict
        baseline_dead = baseline ? baseline["dead_exports"] : {}
        %w[unused test_only].each do |kind|
          current = report[:dead_exports][kind.to_sym].map { |declaration| format_declaration(declaration) }
          known = Array(baseline_dead[kind])
          (current - known).sort.each { |entry| failures << "dead-export (#{kind}): #{entry}" }
        end
      end

      if ratchet
        failures.concat(ratchet_failures(report, baseline))
      end

      [failures.empty?, failures.uniq.sort]
    end

    def ratchet_failures(report, baseline)
      failures = []
      sizes = baseline["sizes"] || {}
      baseline_code = sizes["total_code"].to_i
      if report[:sizes][:total_code] > baseline_code + tolerance
        failures << "ratchet: total code lines #{report[:sizes][:total_code]} > baseline #{baseline_code} + #{tolerance}"
      end

      baseline_functions = sizes["functions_over_limit"].to_i
      if report[:sizes][:functions_over_limit] > baseline_functions
        failures << "ratchet: functions >= #{DIFFICULTY_FUNCTION_LINES} lines " \
                    "#{report[:sizes][:functions_over_limit]} > baseline #{baseline_functions}"
      end

      baseline_files = sizes["files_over_limit"].to_i
      if report[:sizes][:files_over_limit] > baseline_files
        failures << "ratchet: files >= #{DIFFICULTY_FILE_CODE_LINES} code lines " \
                    "#{report[:sizes][:files_over_limit]} > baseline #{baseline_files}"
      end

      baseline_duplication = (baseline["duplication"] || {})["duplicated_lines"].to_i
      if report[:duplication][:duplicated_lines] > baseline_duplication
        failures << "ratchet: duplicated lines #{report[:duplication][:duplicated_lines]} > " \
                    "baseline #{baseline_duplication}"
      end

      baseline_tests = baseline["tests"] || {}
      if report[:tests][:projects] < baseline_tests["projects"].to_i
        failures << "ratchet: projects/mtc test files #{report[:tests][:projects]} < baseline #{baseline_tests['projects']}"
      end
      if report[:tests][:test_mt] < baseline_tests["test_mt"].to_i
        failures << "ratchet: test/mt files #{report[:tests][:test_mt]} < baseline #{baseline_tests['test_mt']}"
      end

      failures
    end

    def render_report(report, io = $stdout, top: 10)
      io.puts "refactor guard: #{SOURCE_ROOT} (#{report[:source][:files]} files, #{report[:source][:lines]} lines)"
      io.puts "layers: #{report[:layers][:edges].length} edges, #{report[:layers][:violations].length} violations"
      report[:layers][:violations].first(top).each { |violation| io.puts "  #{violation}" }

      io.puts "aliases: #{report[:aliases][:canon].length} modules, #{report[:aliases][:violations].length} violations"
      report[:aliases][:violations].first(top).each { |violation| io.puts "  #{violation}" }

      io.puts "vocabulary: #{report[:vocabulary][:violations].length} violations"
      report[:vocabulary][:violations].first(top).each do |violation|
        io.puts "  #{violation[:path]}:#{violation[:line]}: #{violation[:name]} (#{violation[:expected]})"
      end

      io.puts "naming: #{report[:naming][:violations].length} violations"
      report[:naming][:violations].first(top).each do |violation|
        io.puts "  #{violation[:path]}:#{violation[:line]}: #{violation[:name]} (#{violation[:expected]})"
      end

      io.puts "dead exports: #{report[:dead_exports][:unused].length} unused, " \
              "#{report[:dead_exports][:test_only].length} test-only"
      report[:dead_exports][:unused].first(top).each do |declaration|
        io.puts "  #{declaration[:path]}:#{declaration[:line]}: #{declaration[:kind]} #{declaration[:name]}"
      end

      io.puts "duplication: #{report[:duplication][:windows]} clusters, " \
              "#{report[:duplication][:duplicated_lines]} duplicated lines (window #{report[:duplication][:window]})"
      report[:duplication][:clusters].first(3).each do |cluster|
        locations = cluster[:occurrences].first(3).map { |occurrence| "#{occurrence[:path]}:#{occurrence[:line]}" }
        io.puts "  #{cluster[:occurrences].length}x #{locations.join(' ')}"
      end

      sizes = report[:sizes]
      io.puts "size: #{sizes[:total_code]} code lines; " \
              "#{sizes[:functions_over_limit]} functions >= #{DIFFICULTY_FUNCTION_LINES} lines; " \
              "#{sizes[:files_over_limit]} files >= #{DIFFICULTY_FILE_CODE_LINES} code lines"
      sizes[:longest_functions].first(5).each do |function|
        io.puts "  #{function[:path]}:#{function[:line]} #{function[:name]} (#{function[:length]} lines)"
      end
      sizes[:largest_files].first(5).each do |path, stats|
        io.puts "  #{path} (#{stats[:code]} code lines)"
      end

      io.puts "markers: #{report[:markers].length}"
      report[:markers].first(top).each { |marker| io.puts "  #{format_marker(marker)}" }

      io.puts "tests: projects/mtc #{report[:tests][:projects]}, test/mt #{report[:tests][:test_mt]}"
    end
  end
end

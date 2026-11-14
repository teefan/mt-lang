# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "../test_helper"

class MilkTeaRefactorGuardTest < Minitest::Test
  SOURCE = "projects/mtc/src/mtc"

  def with_tree(files)
    Dir.mktmpdir("milk-tea-refactor-guard") do |dir|
      files.each do |relative, content|
        path = File.join(dir, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end
      yield dir
    end
  end

  def guard(dir, window: MilkTea::RefactorGuard::DEFAULT_WINDOW)
    MilkTea::RefactorGuard.new(
      root: dir,
      baseline_path: File.join(dir, "baseline.json"),
      window: window,
    )
  end

  def test_extracts_module_imports_and_edges
    with_tree(
      "#{SOURCE}/parser/parser.mt" => <<~MT,
        import std.vec as vec
        import mtc.lexer.lexer as lexer

        function parse() -> void:
            pass
      MT
      "#{SOURCE}/loader/loader.mt" => "import mtc.semantic.types as types\nimport mtc.parser.parser as parser\n",
      "#{SOURCE}/lexer/lexer.mt" => "function lex() -> void:\n    pass\n",
      "#{SOURCE}/semantic/types.mt" => "function kind() -> void:\n    pass\n",
    ) do |dir|
      report = guard(dir).layer_report
      assert_includes report[:edges], "parser -> lexer"
      assert_includes report[:edges], "loader -> semantic"
      assert_includes report[:edges], "loader -> parser"
      assert_empty report[:violations]
    end
  end

  def test_flags_upward_layer_edge
    with_tree(
      "#{SOURCE}/lexer/lexer.mt" => "import mtc.lowering.lowering as lowering\n",
      "#{SOURCE}/lowering/lowering.mt" => "function lower() -> void:\n    pass\n",
    ) do |dir|
      report = guard(dir).layer_report
      assert_equal 1, report[:violations].length
      assert_includes report[:violations].first, "upward layer edge lexer -> lowering"
    end
  end

  def test_allows_downward_and_same_rank_edges
    with_tree(
      "#{SOURCE}/loader/loader.mt" => "import mtc.semantic.types as types\nimport mtc.loader.cache as cache\n",
      "#{SOURCE}/loader/cache.mt" => "function hit() -> void:\n    pass\n",
      "#{SOURCE}/semantic/types.mt" => "function kind() -> void:\n    pass\n",
      "#{SOURCE}/linter/linter.mt" => "import mtc.formatter.tidy as tidy\n",
      "#{SOURCE}/formatter/tidy.mt" => "import mtc.linter.linter as linter\n",
    ) do |dir|
      assert_empty guard(dir).layer_report[:violations]
    end
  end

  def test_unclassified_module_is_a_violation
    with_tree(
      "#{SOURCE}/new_area/thing.mt" => "function thing() -> void:\n    pass\n",
      "#{SOURCE}/parser/parser.mt" => "import mtc.new_area.thing as thing\n",
    ) do |dir|
      violations = guard(dir).layer_report[:violations]
      assert violations.any? { |violation| violation.include?("unclassified import target 'new_area.thing'") }
    end
  end

  def test_naming_rules
    with_tree(
      "#{SOURCE}/parser/parser.mt" => <<~MT,
        public function BadName() -> void:
            pass

        struct lower_name:
            value: int

        const lower_const: int = 1
      MT
    ) do |dir|
      violations = guard(dir).naming_violations
      names = violations.map { |violation| violation[:name] }
      assert_includes names, "BadName"
      assert_includes names, "lower_name"
      assert_includes names, "lower_const"
      assert violations.any? { |violation| violation[:expected] == "function name snake_case" }
      assert violations.any? { |violation| violation[:expected] == "struct name PascalCase" }
      assert violations.any? { |violation| violation[:expected] == "const name UPPER_SNAKE" }
    end
  end

  def test_alias_consistency
    with_tree(
      "#{SOURCE}/parser/parser.mt" => "import mtc.semantic.types as types\n",
      "#{SOURCE}/loader/loader.mt" => "import mtc.semantic.types as types_mod\n",
      "#{SOURCE}/semantic/types.mt" => "function kind() -> void:\n    pass\n",
    ) do |dir|
      violations = guard(dir).alias_report[:violations]
      assert violations.any? { |violation| violation.include?("semantic.types as types (canonical types_mod)") }
    end
  end

  def test_duplicate_import_and_alias_collision
    with_tree(
      "#{SOURCE}/parser/parser.mt" => <<~MT,
        import mtc.parser.ast as ast
        import mtc.parser.ast as ast
        import mtc.semantic.types as ast
      MT
      "#{SOURCE}/parser/ast.mt" => "function node() -> void:\n    pass\n",
      "#{SOURCE}/semantic/types.mt" => "function kind() -> void:\n    pass\n",
    ) do |dir|
      violations = guard(dir).alias_report[:violations]
      assert violations.any? { |violation| violation.include?("duplicate import of parser.ast") }
      assert violations.any? { |violation| violation.include?("alias ast used for") }
    end
  end

  def test_vocabulary_rules
    with_tree(
      "#{SOURCE}/parser/parser.mt" => <<~MT,
        function new_thing() -> void:
            pass

        function lookup_thing() -> void:
            pass

        function parse_declaration() -> void:
            pass

        function render_expression() -> void:
            pass

        function create_thing() -> void:
            pass

        function find_thing() -> void:
            pass

        function parse_decl() -> void:
            pass

        function render_expr() -> void:
            pass
      MT
    ) do |dir|
      names = guard(dir).vocabulary_violations.map { |violation| violation[:name] }
      assert_equal %w[lookup_thing new_thing parse_declaration render_expression], names.sort
    end
  end

  def test_dead_export_classification
    with_tree(
      "#{SOURCE}/parser/parser.mt" => <<~MT,
        public function used_elsewhere() -> void:
            pass

        public function dead_export() -> void:
            pass

        public function test_only_export() -> void:
            pass
      MT
      "#{SOURCE}/semantic/consumer.mt" => <<~MT,
        import mtc.parser.parser as parser

        function consume() -> void:
            parser.used_elsewhere()
      MT
      "test/mt/parser_test.mt" => <<~MT,
        @[test]
        function test_dead() -> void:
            test_only_export()
      MT
    ) do |dir|
      exports = guard(dir).dead_exports
      unused = exports[:unused].map { |declaration| declaration[:name] }
      test_only = exports[:test_only].map { |declaration| declaration[:name] }

      assert_includes unused, "dead_export"
      refute_includes unused, "used_elsewhere"
      assert_includes test_only, "test_only_export"
    end
  end

  def test_duplicate_window_detection
    body = (1..14).map { |index| "    value_#{index}()\n" }.join
    with_tree(
      "#{SOURCE}/parser/a.mt" => "function alpha() -> void:\n#{body}",
      "#{SOURCE}/parser/b.mt" => "function beta() -> void:\n#{body}",
    ) do |dir|
      duplication = guard(dir, window: 12).duplication_report
      assert_operator duplication[:windows], :>=, 1
      assert_operator duplication[:duplicated_lines], :>, 0

      assert_equal 0, guard(dir, window: 40).duplication_report[:windows]
    end
  end

  def test_baseline_round_trip_and_strict_failures
    with_tree(
      "#{SOURCE}/parser/parser.mt" => <<~MT,
        public function dead_export() -> void:
            pass
      MT
    ) do |dir|
      report_guard = guard(dir)
      report_guard.write_baseline
      assert_equal [true, []], report_guard.check(strict: true, ratchet: true)

      File.write(File.join(dir, SOURCE, "parser", "parser.mt"), <<~MT)
        public function dead_export() -> void:
            pass

        public function new_dead_export() -> void:
            pass

        # TODO: remove this fixture marker
      MT
      report_guard = guard(dir)
      ok, failures = report_guard.check(strict: true)
      refute ok
      assert failures.any? { |failure| failure.include?("dead-export (unused):") && failure.include?("new_dead_export") }
      assert failures.any? { |failure| failure.start_with?("marker:") }
    end
  end

  def test_ratchet_detects_growth
    with_tree(
      "#{SOURCE}/parser/parser.mt" => "function parse() -> void:\n    pass\n",
    ) do |dir|
      report_guard = guard(dir)
      report_guard.write_baseline
      assert_equal [true, []], report_guard.check(ratchet: true)

      File.write(File.join(dir, SOURCE, "parser", "parser.mt"), <<~MT)
        function parse() -> void:
            pass
            first()
            second()
            third()
      MT
      report_guard = guard(dir)
      ok, failures = report_guard.check(ratchet: true)
      refute ok
      assert failures.any? { |failure| failure.start_with?("ratchet: total code lines") }
    end
  end

  def test_size_metrics_and_test_counts
    body = (1..20).map { |index| "    step_#{index}()\n" }.join
    with_tree(
      "#{SOURCE}/parser/parser.mt" => "function parse() -> void:\n#{body}",
      "projects/mtc/test/one_test.mt" => "function test_one() -> void:\n    pass\n",
      "test/mt/two_test.mt" => "function test_two() -> void:\n    pass\n",
      "projects/mtc/test/__mt_test_runner_1.mt" => "function main() -> void:\n    pass\n",
    ) do |dir|
      sizes = guard(dir).size_report
      assert_equal 1, sizes[:files].length
      assert_operator sizes[:longest_functions].first[:length], :>=, 20
      assert_equal({ projects: 1, test_mt: 1 }, guard(dir).test_report)
    end
  end

  def test_repository_invariants_pass
    root = File.expand_path("../..", __dir__)
    ok, failures = MilkTea::RefactorGuard.new(root: root).check
    assert ok, failures.join("\n")
  end
end

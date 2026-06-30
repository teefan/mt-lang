# frozen_string_literal: true

require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../test_helper"

# Exercises the development SExpr IR pipeline end to end:
#   source -> tokens(sexpr) -> AST(sexpr) -> analysis(sexpr) -> IR(sexpr) -> C
#
# Guarantees verified here:
#   * each stage round-trips through sexpr (from_sexpr(to_sexpr(x)) is faithful)
#   * driving the pipeline stage-by-stage through sexpr produces byte-identical
#     C to the in-process path (single- and multi-module)
#   * emission is deterministic and independent of analysis/module ordering
class MilkTeaPipelineTest < Minitest::Test
  # ── Corpus ────────────────────────────────────────────────────────────────

  MINIMAL = {
    files: { "main.mt" => <<~MT },
      function main() -> int:
          return 0
    MT
    root: "main.mt",
  }.freeze

  FEATURES = {
    files: { "feat.mt" => <<~MT },
      struct Box:
          value: int?

      variant Shape:
          circle(r: float)
          square(side: float)

      function area(s: Shape) -> float:
          match s:
              Shape.circle(r):
                  return 3.14 * r * r
              Shape.square(side):
                  return side * side

      function main() -> int:
          let s = Shape.square(side = 3.0)
          let a = area(s)
          let b = Box(value = if a > 0.0: 1 else: 0)
          let v = b.value
          if v != null:
              return v
          return 0
    MT
    root: "feat.mt",
  }.freeze

  MULTI_MODULE = {
    files: {
      "demo/util.mt" => <<~MT,
        # module demo.util

        public function twice(x: int) -> int:
            return x * 2
      MT
      "demo/app.mt" => <<~MT,
        # module demo.app

        import demo.util as util

        struct Box:
            value: int?

        function pack(n: int) -> Box:
            return Box(value = util.twice(n))

        function main() -> int:
            let b = pack(21)
            let v = b.value
            if v != null:
                return v
            return 0
      MT
    },
    root: "demo/app.mt",
  }.freeze

  CORPUS = { "minimal" => MINIMAL, "features" => FEATURES, "multi_module" => MULTI_MODULE }.freeze

  # ── Differential: every staged path must equal the direct path ─────────────

  def test_check_analysis_pipeline_matches_direct_emit_c
    each_corpus do |dir, root_path|
      direct = emit_c_direct(dir, root_path)
      staged = emit_c_via_analysis_bundle(dir, root_path)
      assert_equal direct, staged
    end
  end

  def test_ast_sexpr_pipeline_matches_direct_emit_c
    each_corpus do |dir, root_path|
      direct = emit_c_direct(dir, root_path)
      staged = emit_c_via_ast_sexpr(dir, root_path)
      assert_equal direct, staged
    end
  end

  # ── Determinism ────────────────────────────────────────────────────────────

  def test_emit_c_is_deterministic_across_runs
    each_corpus do |dir, root_path|
      assert_equal emit_c_direct(dir, root_path), emit_c_direct(dir, root_path)
    end
  end

  def test_lowering_is_independent_of_imported_module_ordering
    program = MULTI_MODULE
    Dir.mktmpdir("mt-sexpr-order") do |dir|
      write_files(dir, program[:files])
      root_path = File.join(dir, program[:root])

      bundle_path = File.join(dir, "bundle.sexpr")
      status, = cli("check", root_path, "-I", dir, "--emit-analysis-sexpr", bundle_path)
      assert_equal 0, status

      original = MilkTea::SExpr.from_sexpr(File.read(bundle_path))
      refute_empty original["imported"], "expected imported modules in the bundle"

      # Reverse the imported-module ordering; emission must be unaffected.
      reordered = original.merge("imported" => original["imported"].to_a.reverse.to_h)
      reordered_path = File.join(dir, "bundle_reordered.sexpr")
      File.write(reordered_path, MilkTea::SExpr.to_sexpr(reordered))

      assert_equal lower_then_emit(dir, bundle_path), lower_then_emit(dir, reordered_path)
    end
  end

  # ── Per-stage JSON round-trips (library API) ───────────────────────────────

  def test_tokens_round_trip
    source = FEATURES[:files]["feat.mt"]
    tokens = MilkTea::Lexer.lex(source, path: "feat.mt")
    once = MilkTea::Serializer.tokens_to_sexpr(tokens)
    twice = MilkTea::Serializer.tokens_to_sexpr(MilkTea::Serializer.tokens_from_sexpr(once))
    assert_equal once, twice
  end

  def test_ast_round_trip
    source = FEATURES[:files]["feat.mt"]
    ast = MilkTea::Parser.parse(source, path: "feat.mt")
    once = MilkTea::Serializer.ast_to_sexpr(ast)
    twice = MilkTea::Serializer.ast_to_sexpr(MilkTea::Serializer.ast_from_sexpr(once))
    assert_equal once, twice
  end

  def test_ir_round_trip_produces_identical_c
    %w[minimal features].each do |name|
      program_spec = CORPUS.fetch(name)
      Dir.mktmpdir("mt-sexpr-ir-rt") do |dir|
        write_files(dir, program_spec[:files])
        root_path = File.join(dir, program_spec[:root])
        program = MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root]).check_program(root_path)
        ir = MilkTea::Lowering.lower(program)
        ir2 = MilkTea::Serializer.ir_from_sexpr(MilkTea::Serializer.ir_to_sexpr(ir))
        c1 = MilkTea::CBackend.generate_c(ir, emit_line_directives: false)
        c2 = MilkTea::CBackend.generate_c(ir2, emit_line_directives: false)
        assert_equal c1, c2, "IR round-trip changed emitted C for #{name}"
      end
    end
  end

  private

  def each_corpus
    CORPUS.each_value do |spec|
      Dir.mktmpdir("mt-sexpr-pipeline") do |dir|
        write_files(dir, spec[:files])
        yield dir, File.join(dir, spec[:root])
      end
    end
  end

  def write_files(dir, files)
    files.each do |rel, src|
      path = File.join(dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, src)
    end
  end

  def cli(*argv)
    out = StringIO.new
    err = StringIO.new
    status = MilkTea::CLI.start(argv, out:, err:)
    [status, out.string, err.string]
  end

  def emit_c_direct(dir, root_path)
    status, out, err = cli("emit-c", root_path, "-I", dir)
    assert_equal 0, status, "direct emit-c failed: #{err}"
    out
  end

  def emit_c_via_analysis_bundle(dir, root_path)
    bundle = File.join(dir, "bundle.sexpr")
    s1, _o1, e1 = cli("check", root_path, "-I", dir, "--emit-analysis-sexpr", bundle)
    assert_equal 0, s1, "check --emit-analysis-sexpr failed: #{e1}"
    lower_then_emit(dir, bundle)
  end

  def emit_c_via_ast_sexpr(dir, root_path)
    ast = File.join(dir, "ast.sexpr")
    bundle = File.join(dir, "ast_bundle.sexpr")
    s1, _o1, e1 = cli("parse", root_path, "-I", dir, "--emit-ast-sexpr", ast)
    assert_equal 0, s1, "parse --emit-ast-sexpr failed: #{e1}"
    s2, _o2, e2 = cli("check", "--from-ast-sexpr", ast, "-I", dir, "--emit-analysis-sexpr", bundle)
    assert_equal 0, s2, "check --from-ast-sexpr failed: #{e2}"
    lower_then_emit(dir, bundle, suffix: "ast")
  end

  def lower_then_emit(dir, bundle_path, suffix: "")
    ir = File.join(dir, "ir#{suffix}.sexpr")
    s1, _o1, e1 = cli("lower", "--from-analysis-sexpr", bundle_path, "--emit-ir-sexpr", ir)
    assert_equal 0, s1, "lower --from-analysis-sexpr failed: #{e1}"
    s2, out, e2 = cli("emit-c", "--from-ir-sexpr", ir)
    assert_equal 0, s2, "emit-c --from-ir-sexpr failed: #{e2}"
    out
  end
end

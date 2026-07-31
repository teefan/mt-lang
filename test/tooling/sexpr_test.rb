# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "stringio"
require_relative "../test_helper"

class MilkTeaSexprTest < Minitest::Test
  def with_sexpr(source)
    Dir.mktmpdir("mt-sexpr-test") do |dir|
      path = File.join(dir, "main.mt")
      File.write(path, source)
      program = MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root]).check_program(path)
      ir = MilkTea::Lowering.lower(program)
      MilkTea::SexprDumper.dump_ir(ir)
    end
  end

  # ── Byte-identical output ──────────────────────────────────────────

  def test_byte_identical_across_runs
    source = <<~MT
      # module main

      function main() -> int:
          return 0
    MT

    Dir.mktmpdir("mt-sexpr-test") do |dir|
      path = File.join(dir, "main.mt")
      File.write(path, source)
      program1 = MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root]).check_program(path)
      sexpr1 = MilkTea::SexprDumper.dump_ir(MilkTea::Lowering.lower(program1))

      program2 = MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root]).check_program(path)
      sexpr2 = MilkTea::SexprDumper.dump_ir(MilkTea::Lowering.lower(program2))

      assert_equal sexpr1, sexpr2, "canonical output must be byte-identical across runs"
    end
  end

  def test_byte_identical_with_constants
    source = <<~MT
      # module main

      const WIDTH: int = 800
      const LABEL: str = "hello"

      function main() -> int:
          return 0
    MT

    Dir.mktmpdir("mt-sexpr-test") do |dir|
      path = File.join(dir, "main.mt")
      File.write(path, source)
      program1 = MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root]).check_program(path)
      sexpr1 = MilkTea::SexprDumper.dump_ir(MilkTea::Lowering.lower(program1))

      program2 = MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root]).check_program(path)
      sexpr2 = MilkTea::SexprDumper.dump_ir(MilkTea::Lowering.lower(program2))

      assert_equal sexpr1, sexpr2
    end
  end

  def test_byte_identical_with_struct
    source = <<~MT
      # module main

      struct Vec2:
          x: float
          y: float

      function main() -> int:
          let v = Vec2(x = 1.0, y = 2.0)
          return 0
    MT

    Dir.mktmpdir("mt-sexpr-test") do |dir|
      path = File.join(dir, "main.mt")
      File.write(path, source)
      program1 = MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root]).check_program(path)
      sexpr1 = MilkTea::SexprDumper.dump_ir(MilkTea::Lowering.lower(program1))

      program2 = MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root]).check_program(path)
      sexpr2 = MilkTea::SexprDumper.dump_ir(MilkTea::Lowering.lower(program2))

      assert_equal sexpr1, sexpr2
    end
  end

  # ── Round-trip (serialize → deserialize → re-serialize) ─────────────

  def test_round_trip_simple
    source = <<~MT
      # module main

      function main() -> int:
          return 0
    MT

    sexpr1 = with_sexpr(source)
    MilkTea::Types::Registry.reset!
    ir = MilkTea::SexprParser.parse_ir(sexpr1)
    sexpr2 = MilkTea::SexprDumper.dump_ir(ir)
    assert_equal sexpr1, sexpr2
  end

  def test_round_trip_with_variables
    source = <<~MT
      # module main

      function main() -> int:
          var x: int = 42
          x += 1
          return x
    MT

    sexpr1 = with_sexpr(source)
    MilkTea::Types::Registry.reset!
    ir = MilkTea::SexprParser.parse_ir(sexpr1)
    sexpr2 = MilkTea::SexprDumper.dump_ir(ir)
    assert_equal sexpr1, sexpr2
  end

  def test_round_trip_with_if_else
    source = <<~MT
      # module main

      function choose(flag: bool) -> int:
          if flag:
              return 1
          else:
              return 0

      function main() -> int:
          return choose(true)
    MT

    sexpr1 = with_sexpr(source)
    MilkTea::Types::Registry.reset!
    ir = MilkTea::SexprParser.parse_ir(sexpr1)
    sexpr2 = MilkTea::SexprDumper.dump_ir(ir)
    assert_equal sexpr1, sexpr2
  end

  def test_round_trip_with_while
    source = <<~MT
      # module main

      function sum(n: int) -> int:
          var total: int = 0
          var i: int = 0
          while i < n:
              total = total + i
              i = i + 1
          return total

      function main() -> int:
          return sum(5)
    MT

    sexpr1 = with_sexpr(source)
    MilkTea::Types::Registry.reset!
    ir = MilkTea::SexprParser.parse_ir(sexpr1)
    sexpr2 = MilkTea::SexprDumper.dump_ir(ir)
    assert_equal sexpr1, sexpr2
  end

  def test_round_trip_with_pointer_types
    source = <<~MT
      # module main

      function read_value(p: ptr[int]) -> int:
          unsafe:
              return read(p)

      function main() -> int:
          var x: int = 99
          let p = ptr_of(x)
          return read_value(p)
    MT

    sexpr1 = with_sexpr(source)
    MilkTea::Types::Registry.reset!
    ir = MilkTea::SexprParser.parse_ir(sexpr1)
    sexpr2 = MilkTea::SexprDumper.dump_ir(ir)
    assert_equal sexpr1, sexpr2
  end

  def test_round_trip_with_nullable
    source = <<~MT
      # module main

      function check(ptr: ptr[int]?) -> int:
          let p = ptr else:
              return 0
          return unsafe: read(p)

      function main() -> int:
          return check(null)
    MT

    sexpr1 = with_sexpr(source)
    MilkTea::Types::Registry.reset!
    ir = MilkTea::SexprParser.parse_ir(sexpr1)
    sexpr2 = MilkTea::SexprDumper.dump_ir(ir)
    assert_equal sexpr1, sexpr2
  end

  # ── Token canonical format ─────────────────────────────────────────

  def test_token_dump_format
    source = "42"
    tokens = MilkTea::Lexer.lex(source, path: "test.mt")
    output = MilkTea::SexprDumper.dump_tokens(tokens)
    assert_includes output, "(token"
    assert_includes output, ":type :integer"
    assert_includes output, ":literal 42"
  end

  def test_token_dump_byte_identical
    source = "let x = 1.5"
    tokens1 = MilkTea::Lexer.lex(source, path: "test.mt")
    tokens2 = MilkTea::Lexer.lex(source, path: "test.mt")
    output1 = MilkTea::SexprDumper.dump_tokens(tokens1)
    output2 = MilkTea::SexprDumper.dump_tokens(tokens2)
    assert_equal output1, output2
  end

  # ── CLI integration ────────────────────────────────────────────────

  def test_cli_lower_sexpr_output
    in_tmpdir do |dir|
      source = <<~MT
        # module main

        function main() -> int:
            return 0
      MT

      path = File.join(dir, "main.mt")
      File.write(path, source)

      out1 = StringIO.new
      out2 = StringIO.new
      err = StringIO.new

      MilkTea::CLI.start(["lower", path, "--sexpr"], out: out1, err: err)
      assert_empty err.string
      MilkTea::CLI.start(["lower", path, "--sexpr"], out: out2, err: err)

      assert_equal out1.string, out2.string, "sexpr output must be byte-identical"
      assert_includes out1.string, "(IR::Program"
    end
  end

  def test_cli_lower_default_format_still_works
    in_tmpdir do |dir|
      source = <<~MT
        # module main

        function main() -> int:
            return 0
      MT

      path = File.join(dir, "main.mt")
      File.write(path, source)

      out = StringIO.new
      err = StringIO.new

      MilkTea::CLI.start(["lower", path], out: out, err: err)
      assert_empty err.string
      assert_includes out.string, "program"
      assert_includes out.string, "fn main"
    end
  end

  # ── Format characteristics ─────────────────────────────────────────

  def test_canonical_is_single_line
    source = <<~MT
      # module main

      function main() -> int:
          var x: int = 1
          var y: int = 2
          return x + y
    MT

    sexpr = with_sexpr(source)
    refute_includes sexpr, "\n", "canonical output must be a single line"
  end

  private

  def in_tmpdir
    dir = Dir.mktmpdir("mt_sexpr_test")
    yield dir
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end

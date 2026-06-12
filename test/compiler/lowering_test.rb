# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "../test_helper"

class MilkTeaLoweringTest < Minitest::Test
  # ── Constants and globals ─────────────────────────────────────────────────

  def test_lowers_constants
    program = check_program_source(<<~MT)
      # module demo.main

      const WIDTH: int = 800
      const HEIGHT: int = 600
      const LABEL: str = "hello"

      function main() -> int:
          return 0
    MT

    ir = MilkTea::Lowering.lower(program)
    names = ir.constants.map(&:name)
    assert_includes names, "WIDTH"
    assert_includes names, "HEIGHT"
    assert_includes names, "LABEL"
    assert ir.constants.all? { |c| c.c_name }, "all constants must have c_name"
  end

  def test_lowers_globals
    program = check_program_source(<<~MT)
      # module demo.main

      var counter: int = 0
      var scratch: array[ubyte, 256]

      function main() -> int:
          counter = 1
          return 0
    MT

    ir = MilkTea::Lowering.lower(program)
    names = ir.globals.map(&:name)
    assert_includes names, "counter"
    assert_includes names, "scratch"
    assert ir.globals.all? { |g| g.c_name }, "all globals must have c_name"
  end

  # ── Structs, unions, enums ────────────────────────────────────────────────

  def test_lowers_structs
    program = check_program_source(<<~MT)
      # module demo.main

      struct Vec2:
          x: float
          y: float

      struct Player:
          position: Vec2
          health: int

      function main() -> int:
          return 0
    MT

    ir = MilkTea::Lowering.lower(program)
    names = ir.structs.map(&:name)
    assert_includes names, "Vec2"
    assert_includes names, "Player"
    vec2 = ir.structs.find { |s| s.name == "Vec2" }
    field_names = vec2.fields.map(&:name)
    assert_includes field_names, "x"
    assert_includes field_names, "y"
  end

  def test_lowers_enums
    program = check_program_source(<<~MT)
      # module demo.main

      enum State: ubyte
          idle = 0
          running = 1
          paused = 2

      function main() -> int:
          return 0
    MT

    ir = MilkTea::Lowering.lower(program)
    names = ir.enums.map(&:name)
    assert_includes names, "State"
    e = ir.enums.find { |en| en.name == "State" }
    member_names = e.members.map(&:name)
    assert_includes member_names, "idle"
    assert_includes member_names, "running"
    assert_includes member_names, "paused"
  end

  def test_lowers_unions
    program = check_program_source(<<~MT)
      # module demo.main

      union Number:
          i: int
          f: float

      function main() -> int:
          return 0
    MT

    ir = MilkTea::Lowering.lower(program)
    names = ir.unions.map(&:name)
    assert_includes names, "Number"
    u = ir.unions.find { |un| un.name == "Number" }
    field_names = u.fields.map(&:name)
    assert_includes field_names, "i"
    assert_includes field_names, "f"
  end

  # ── Functions ─────────────────────────────────────────────────────────────

  def test_lowers_simple_function
    program = check_program_source(<<~MT)
      # module demo.main

      function add(a: int, b: int) -> int:
          return a + b

      function main() -> int:
          return add(2, 3)
    MT

    ir = MilkTea::Lowering.lower(program)
    func_names = ir.functions.map(&:name)
    assert_includes func_names, "add"
    assert_includes func_names, "main"
    add = ir.functions.find { |f| f.name == "add" }
    assert_equal 2, add.params.length
    refute_nil add.body
  end

  def test_lowers_function_with_if_else
    program = check_program_source(<<~MT)
      # module demo.main

      function clamp(value: int, lo: int, hi: int) -> int:
          if value < lo:
              return lo
          else if value > hi:
              return hi
          else:
              return value

      function main() -> int:
          return clamp(5, 0, 10)
    MT

    ir = MilkTea::Lowering.lower(program)
    clamp = ir.functions.find { |f| f.name == "clamp" }
    refute_nil clamp
    refute_nil clamp.body
  end

  def test_lowers_function_with_while
    program = check_program_source(<<~MT)
      # module demo.main

      function sum_to(n: int) -> int:
          var total: int = 0
          var i: int = 0
          while i < n:
              total += i
              i += 1
          return total

      function main() -> int:
          return sum_to(10)
    MT

    ir = MilkTea::Lowering.lower(program)
    sum_to = ir.functions.find { |f| f.name == "sum_to" }
    refute_nil sum_to
    refute_nil sum_to.body
  end

  def test_lowers_function_with_for_range
    program = check_program_source(<<~MT)
      # module demo.main

      function count_to(n: int) -> int:
          var total: int = 0
          for i in 0..n:
              total += 1
          return total

      function main() -> int:
          return count_to(10)
    MT

    ir = MilkTea::Lowering.lower(program)
    count_to = ir.functions.find { |f| f.name == "count_to" }
    refute_nil count_to
    refute_nil count_to.body
  end

  def test_lowers_function_with_match_enum
    program = check_program_source(<<~MT)
      # module demo.main

      enum Kind: ubyte
          a = 0
          b = 1
          c = 2

      function handle(kind: Kind) -> int:
          match kind:
              Kind.a:
                  return 1
              Kind.b:
                  return 2
              Kind.c:
                  return 3

      function main() -> int:
          return handle(Kind.a)
    MT

    ir = MilkTea::Lowering.lower(program)
    handle = ir.functions.find { |f| f.name == "handle" }
    refute_nil handle
    refute_nil handle.body
  end

  def test_lowers_function_with_defer
    program = check_program_source(<<~MT)
      # module demo.main

      function process() -> int:
          defer do_something()
          return 42

      function do_something() -> void:
          return

      function main() -> int:
          return process()
    MT

    ir = MilkTea::Lowering.lower(program)
    process = ir.functions.find { |f| f.name == "process" }
    refute_nil process
    refute_nil process.body
  end

  # ── Methods ───────────────────────────────────────────────────────────────

  def test_lowers_struct_methods
    program = check_program_source(<<~MT)
      # module demo.main

      struct Counter:
          value: int

      extending Counter:
          function read() -> int:
              return this.value

          editable function bump() -> void:
              this.value += 1

          static function zero() -> Counter:
              return Counter(value = 0)

      function main() -> int:
          var c = Counter(value = 0)
          c.bump()
          return c.read()
    MT

    ir = MilkTea::Lowering.lower(program)
    func_names = ir.functions.map(&:name)
    assert_includes func_names, "read"
    assert_includes func_names, "bump"
    assert_includes func_names, "zero"
  end

  def test_lowers_imported_struct_methods_and_associated_functions
    program = check_program_source(
      <<~MT,
        # module demo.main

        import demo.lib as lib

        function main() -> int:
            var value = lib.make()
            defer value.release()

            var created = lib.Buffer.create()
            defer created.release()
            return 0
      MT
      {
        "demo/lib.mt" => <<~MT,
          # module demo.lib

          public struct Buffer:
              value: int

          public function make() -> Buffer:
              return Buffer.create()

          extending Buffer:
              public static function create() -> Buffer:
                  return Buffer(value = 0)

              public editable function release() -> void:
                  this.value = 0
        MT
      },
    )

    ir = MilkTea::Lowering.lower(program)
    assert_equal "demo.main", ir.module_name
    assert_includes ir.functions.map(&:name), "main"
  end

  # ── Variants ──────────────────────────────────────────────────────────────

  def test_lowers_variant
    program = check_program_source(<<~MT)
      # module demo.main

      variant Token:
          ident(text: str)
          number(value: int)
          eof

      function describe(tok: Token) -> str:
          match tok:
              Token.ident as t:
                  return t.text
              Token.number as n:
                  return "number"
              Token.eof:
                  return "eof"

      function main() -> int:
          return 0
    MT

    ir = MilkTea::Lowering.lower(program)
    variant_names = ir.variants.map(&:name)
    assert_includes variant_names, "Token"
  end

  # ── Events ────────────────────────────────────────────────────────────────

  def test_lowers_event_declaration
    program = check_program_source(<<~MT)
      # module demo.main

      public event finished[4]

      function on_finish() -> void:
          return

      function main() -> int:
          let _ = finished.subscribe(on_finish) else:
              return 1
          finished.emit()
          return 0
    MT

    ir = MilkTea::Lowering.lower(program)
    assert ir.globals.any? { |g| g.name == "finished" }
  end

  # ── Module identity ───────────────────────────────────────────────────────

  def test_lowers_module_name
    program = check_program_source(<<~MT)
      # module demo.main

      function main() -> int:
          return 0
    MT

    ir = MilkTea::Lowering.lower(program)
    assert_equal "demo.main", ir.module_name
  end

  def test_lowers_source_path
    Dir.mktmpdir("milk-tea-lowering") do |dir|
      source = <<~MT
        # module demo.main

        function main() -> int:
            return 0
      MT
      root_path = File.join(dir, source_relative_path(source))
      FileUtils.mkdir_p(File.dirname(root_path))
      File.write(root_path, source)

      program = MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root]).check_program(root_path)
      ir = MilkTea::Lowering.lower(program)
      assert_equal root_path, ir.source_path
    end
  end

  def test_rejects_lowering_raw_module
    raw_source = <<~MT
      external

      external function DoThing() -> void
    MT

    Dir.mktmpdir("milk-tea-lowering-raw") do |dir|
      path = File.join(dir, "std", "c", "sample.mt")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, raw_source)

      caller_source = <<~MT
        # module demo.main

        import std.c.sample as c

        function main() -> int:
            return 0
      MT
      caller_path = File.join(dir, "demo", "main.mt")
      FileUtils.mkdir_p(File.dirname(caller_path))
      File.write(caller_path, caller_source)

      program = MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root]).check_program(caller_path)
      ir = MilkTea::Lowering.lower(program)
      refute_nil ir
    end
  end

  private

  def check_program_source(source, imported_sources = {})
    Dir.mktmpdir("milk-tea-lowering") do |dir|
      root_path = File.join(dir, source_relative_path(source))
      FileUtils.mkdir_p(File.dirname(root_path))
      File.write(root_path, source)

      imported_sources.each do |relative_path, imported_source|
        path = File.join(dir, relative_path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, imported_source)
      end

      return MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root]).check_program(root_path)
    end
  end
end

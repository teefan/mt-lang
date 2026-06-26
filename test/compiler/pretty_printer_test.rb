# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaPrettyPrinterTest < Minitest::Test
  def test_formats_ast_like_source
    source = <<~MT
struct Counter:
    value: int

function main() -> int:
    var counter = Counter(value = 3)
    let counter_ptr = ptr_of(counter)
    unsafe: counter_ptr.value = 7
    return counter.value
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_single_statement_unsafe_block_canonically
    source = <<~MT
struct Counter:
    value: int

function main() -> int:
    var counter = Counter(value = 3)
    let counter_ptr = ptr_of(counter)
    unsafe:
        counter_ptr.value = 7
    return counter.value
    MT

    expected = <<~MT
struct Counter:
    value: int

function main() -> int:
    var counter = Counter(value = 3)
    let counter_ptr = ptr_of(counter)
    unsafe: counter_ptr.value = 7
    return counter.value
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal expected, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_multi_statement_unsafe_block_like_source
    source = <<~MT
function main(ptr: ptr[int]) -> int:
    unsafe:
        let value = read(ptr)
        return value
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_let_else_with_error_binding_like_source
    source = <<~MT
      function main(result: int) -> int:
          let value = result else as error:
              return error
          return value
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_raw_module_ast_like_source
    source = <<~MT
      external

      link "sample"
      include "sample.h"

      external function add(a: int, b: int) -> int
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_raw_module_imports_like_source
    source = <<~MT
      external

      import std.c.dep as dep

      include "helper.h"

      struct Holder:
          value: dep.Vec
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_public_declarations_and_methods_like_source
    source = <<~MT
      public struct Counter:
          value: int

      extending Counter:
          public function read() -> int:
              return this.value

          function bump() -> void:
              this.value += 1

      public function main() -> int:
          let counter = Counter(value = 3)
          return counter.read()
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_generic_extending_block_targets_like_source
    source = <<~MT
      struct Box[T]:
          value: T

      extending Box[T]:
          function get() -> T:
              return this.value
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_multiple_interface_type_param_constraints_like_source
    source = <<~MT
      function same_key[T implements Named and Tagged](left: T, right: T) -> bool:
          return left.equal(right)
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_expression_bodied_proc_expressions_like_source
    source = <<~MT
      function apply(callback: proc(value: int) -> bool, value: int) -> bool:
          return callback(value)

      function main() -> bool:
          return apply(proc(value: int) -> bool: value > 3, 4)
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_variadic_raw_module_ast_like_source
    source = <<~MT
      external

      include "stdio.h"

      external function printf(format: cstr, ...) -> int
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_extern_opaque_with_explicit_c_name_like_source
    source = <<~MT
      external

      opaque tm = c"struct tm"
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_extern_struct_with_explicit_c_name_like_source
    source = <<~MT
      external

      struct timespec = c"struct timespec":
          tv_sec: ptr_int
          tv_nsec: ptr_int
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_raw_module_groups_simple_declarations_by_kind
    source = <<~MT
      external

      include "sample.h"

      opaque Handle = c"struct Handle"
      type Flags = uint

      const MAGIC: int = 7
      const LIMIT: int = 8

      external function init() -> int
      external function close() -> void
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_foreign_declarations_and_calls_like_source
    source = <<~MT
      import std.c.raylib as c

      public foreign function load_file_data(file_name: str as cstr, out data_size: int) -> ptr[ubyte]? = c.LoadFileData

      public foreign function set_shader_value[T](shader: Shader, loc_index: int, in value: T as const_ptr[void], uniform_type: int) -> void = c.SetShaderValue

      public foreign function close_window(consuming window: Window) -> void = c.CloseWindow

      public foreign function save_file_data(file_name: str as cstr, data: span[ubyte]) -> bool = c.SaveFileData(file_name, data.data, int<-data.len)

      function main(path: str) -> ptr[ubyte]?:
          var data_size = 0
          let contrast = 1.0
          set_shader_value(Shader(), 0, contrast, 0)
          return load_file_data(path, data_size)
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_variadic_foreign_declarations_like_source
    source = <<~MT
      import std.c.stdio as c

      public foreign function print(format: str as cstr, ...) -> int = c.printf
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_array_char_zero_construction_like_source
    source = <<~MT
      function main() -> int:
          var buffer = zero[array[char, 64]]
          buffer[0] = 65
          return 0
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_typed_local_without_initializer_like_source
    source = <<~MT
      function main() -> void:
          var buffer: array[char, 64]
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_defer_block_like_source
    source = <<~MT
      function main() -> void:
          defer:
              first_cleanup()
              second_cleanup()
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_pass_statements_like_source
    source = <<~MT
      function main(flag: bool) -> int:
          if flag:
              pass
          defer:
              pass
          return 0
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_heredoc_literals_like_source
    source = <<~MT
      const shader: cstr = c<<-GLSL
          #version 330
          void main()
          {
          }
      GLSL
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_multiline_adjacent_string_literals_like_source
    source = <<~MT
      const title: str = "Milk Tea keeps this text readable"
          " while storing a single logical line."
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_preserves_unsafe_block_shape_when_blank_line_trivia_exists
    source = <<~MT
      function main() -> int:
          unsafe:

              return 1
    MT

    ast = MilkTea::Parser.parse(source)
    lexed = MilkTea::Lexer.lex_with_trivia(source)
    formatted = MilkTea::PrettyPrinter.format_ast(ast, trivia: lexed.trivia)

    assert_match(/unsafe:\n\s+return 1/, formatted)
    refute_match(/unsafe: return 1/, formatted)
  end

  def test_formats_inline_comments_from_trivia_for_raw_module_headers
    source = <<~MT
      external # module marker

      import std.c.dep as dep # import alias

      include "helper.h"

      struct Holder:
          value: dep.Vec
    MT

    ast = MilkTea::Parser.parse(source)
    lexed = MilkTea::Lexer.lex_with_trivia(source)
    formatted = MilkTea::PrettyPrinter.format_ast(ast, trivia: lexed.trivia)

    assert_includes formatted, "external  # module marker"
    assert_includes formatted, "import std.c.dep as dep  # import alias"
  end

  def test_formats_lowered_ir_as_structured_output
    source = <<~MT

struct Counter:
    value: int

function main() -> int:
    var counter = Counter(value = 3)
    let counter_ptr = ptr_of(counter)
    unsafe:
        counter_ptr.value = 7
    return counter.value

    MT

    output = with_program(source, relative_path: File.join("demo", "pretty.mt")) do |program|
      MilkTea::PrettyPrinter.format_ir(MilkTea::Lowering.lower(program))
    end

    assert_includes output, "program demo.pretty"
    assert_includes output, "struct Counter as demo_pretty_Counter:"
    assert_includes output, "fn main() -> int [entry]:"
    assert_includes output, "let counter_ptr: ptr[demo.pretty.Counter] = &counter"
    assert_includes output, "counter_ptr->value = 7"
    assert_includes output, "return counter.value"
  end

  def test_formats_lowered_ir_for_clauses
    source = <<~MT

function keep(value: int) -> void:
    return

function main() -> void:
    for i in 0..3:
        keep(i)

    MT

    output = with_program(source, relative_path: File.join("demo", "pretty_for.mt")) do |program|
      MilkTea::PrettyPrinter.format_ir(MilkTea::Lowering.lower(program))
    end

    assert_includes output, "fn main as demo_pretty_for_main() -> void:"
    assert_includes output, "fn main() -> int [entry]:"
    assert_includes output, "for i: int = 0; i < 3; i += 1:"
    assert_includes output, "demo_pretty_for_keep(i)"
  end

  def test_formats_lowered_ir_with_nil_else_and_switch_default_case
    source = <<~MT

function describe(code: int) -> int:
    if code < 0:
        return 0

    match code:
        1:
            return 10
        _:
            return 20

function main() -> int:
    return describe(2)

    MT

    output = with_program(source, relative_path: File.join("demo", "pretty_match.mt")) do |program|
      MilkTea::PrettyPrinter.format_ir(MilkTea::Lowering.lower(program))
    end

    assert_includes output, "fn describe as demo_pretty_match_describe(code: int) -> int:"
    assert_includes output, "if code < 0:"
    assert_includes output, "switch code:"
    assert_includes output, "default:"
  end

  def test_formats_constructs_repaired_in_completeness_fixes
    sources = {
      char_literal: <<~MT,
        function f() -> int:
            let a = 'a'
            let n = '\\n'
            return 0
      MT
      block_bodied_const: <<~MT,
        const N -> int:
            var x = 1
            return x
      MT
      tuples: <<~MT,
        function f() -> int:
            let a = (1, 2)
            let b = (x = 1, y = 2)
            return 0
      MT
      value_type_param: <<~MT,
        function f[N: int]() -> int:
            return N
      MT
      parallel_block: <<~MT,
        function f() -> int:
            parallel:
                a()
                b()
            return 0
      MT
      when_statement: <<~MT,
        function f() -> int:
            when state:
                State.idle:
                    return 1
                else:
                    return 2
      MT
      detach_and_gather: <<~MT,
        function f() -> int:
            let h = detach work()
            gather h
            return 0
      MT
    }

    sources.each do |name, source|
      ast = MilkTea::Parser.parse(source)
      formatted = MilkTea::PrettyPrinter.format_ast(ast)
      reformatted = MilkTea::PrettyPrinter.format_ast(MilkTea::Parser.parse(formatted))
      assert_equal formatted, reformatted, "#{name}: pretty-printer output is not stable / re-parseable"
    end
  end

  def test_completeness_pass_fidelity
    # Operator precedence must match the parser (regression for a bug that
    # silently stripped parens and changed program meaning): |/^/& are looser
    # than ==/!=, which are looser than relational, which are looser than shifts.
    [
      "function f(a: int, b: int, c: int) -> int:\n    return (a & b) == c\n",
      "function f(a: int, b: int, c: int) -> int:\n    return a & b == c\n",
      "function f(a: int, b: int, c: int) -> int:\n    return a == b << c\n",
    ].each do |source|
      assert_equal source, MilkTea::PrettyPrinter.format_ast(MilkTea::Parser.parse(source)), "operator precedence not preserved"
    end

    # `is` re-sugaring, format-string escaping, destructuring, tuple-type returns,
    # and multi-line proc bodies must re-parse and be idempotent.
    [
      <<~'MT',
        function f(x: Token) -> bool:
            return x is Token.eof
      MT
      <<~'MT',
        function f(x: int) -> str:
            return f"line: #{x}\nend"
      MT
      <<~'MT',
        function f() -> int:
            let (a, b) = pair
            return a
      MT
      <<~'MT',
        function pair() -> (int, int):
            return (1, 2)
      MT
      <<~'MT',
        function f() -> int:
            let g = proc(x: int) -> int:
                var y = x
                while y > 0:
                    y -= 1
                return y
            return 0
      MT
    ].each do |source|
      f1 = MilkTea::PrettyPrinter.format_ast(MilkTea::Parser.parse(source))
      MilkTea::Parser.parse(f1)
      f2 = MilkTea::PrettyPrinter.format_ast(MilkTea::Parser.parse(f1))
      assert_equal f1, f2, "not idempotent: #{source.lines.first.strip}"
    end
  end

  private

  def with_program(source, relative_path: "program.mt")
    Dir.mktmpdir("milk-tea-pretty-printer") do |dir|
      path = File.join(dir, relative_path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, source)
      yield MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root]).check_program(path)
    end
  end
end

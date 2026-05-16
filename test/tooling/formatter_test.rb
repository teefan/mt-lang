# frozen_string_literal: true

require_relative "../test_helper"

class MilkTeaFormatterTest < Minitest::Test
  def test_check_source_detects_changes
    source = "function main()->int:\n    return 0\n"

    result = MilkTea::Formatter.check_source(source, path: "demo.mt")

    assert_equal true, result.changed
    assert_equal "function main() -> int:\n    return 0\n", result.formatted_source
  end

  def test_canonical_mode_rewrites_single_statement_unsafe_blocks
    source = <<~MT
      function main(counter_ptr: ptr[int]) -> void:
          unsafe:
              counter_ptr[0] = 1
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :canonical)

    assert_equal <<~MT, formatted
      function main(counter_ptr: ptr[int]) -> void:
          unsafe: counter_ptr[0] = 1
    MT
  end

  def test_build_cst_reconstructs_original_source
    source = <<~MT
      # banner

      function main() -> int: # keep
          return 0
    MT

    cst = MilkTea::Formatter.build_cst(source, path: "demo.mt")

    assert_equal source, cst.reconstruct
    assert_equal source, cst.reconstruct_from_tokens
    assert_equal true, cst.trivia.any? { |token| token.kind == :comment }
  end

  def test_preserve_mode_keeps_comments_exactly
    source = <<~MT
      # banner

      function main() -> int: # trailing
          return 0
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :preserve)

    assert_equal source, formatted
  end

  def test_preserve_mode_keeps_multiline_call_arguments
    source = <<~MT
      function main() -> int:
          log(
              "a",
              "b",
          )
          return 0
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :preserve)

    assert_equal source, formatted
  end

  def test_safe_mode_preserves_comments_in_canonical_output
    source = <<~MT
      # banner
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt")

    assert_includes formatted, "# banner"
  end

  def test_canonical_mode_preserves_comments
    source = <<~MT
      # banner
    MT

    # canonical mode now preserves comments — no error raised
    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :canonical)
    assert_includes formatted, "# banner"
  end

  def test_reconstruct_handles_comment_only_tail_without_newline
    source = "# trailing"

    cst = MilkTea::Formatter.build_cst(source, path: "demo.mt")

    assert_equal source, cst.reconstruct
  end

  def test_preserve_mode_normalizes_crlf_without_truncation
    source = "function main() -> int:\r\n    return 0\r\n"

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :preserve)

    assert_equal "function main() -> int:\n    return 0\n", formatted
  end

  # ── comment preservation ─────────────────────────────────────────────

  def test_canonical_preserves_leading_standalone_comment
    source = <<~MT
      # top-level comment
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :canonical)

    assert_equal "# top-level comment\n", formatted
  end

  def test_canonical_preserves_comment_before_function
    source = <<~MT
      # computes sum
      function add(a: int, b: int) -> int:
          return a + b
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :canonical)

    assert_includes formatted, "# computes sum"
    idx_comment = formatted.index("# computes sum")
    idx_def     = formatted.index("function add(")
    assert idx_comment < idx_def, "comment should precede function declaration"
  end

  def test_canonical_preserves_comment_before_statement
    source = <<~MT
      function main() -> int:
          # initialize counter
          let x = 0
          return x
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :canonical)

    assert_includes formatted, "# initialize counter"
    assert formatted.index("# initialize counter") < formatted.index("let x = 0")
  end

  def test_canonical_preserves_inline_trailing_comment
    source = <<~MT
      function main() -> int:
          let x = 42  # the answer
          return x
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :canonical)

    # Inline comment should appear on the same line as the let statement
    assert_match(/let x = 42\s+# the answer/, formatted)
  end

  def test_canonical_formats_top_level_var_declaration
    source = <<~MT
      public var  counter  :  int   =  1
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :canonical)

    assert_equal "public var counter: int = 1\n", formatted
  end

  def test_tidy_mode_does_not_insert_blank_lines_before_first_method
    source = <<~MT
      struct Ball:
          x: int

      methods Ball:


          function draw() -> void:
              return
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :tidy)

    assert_includes formatted, "methods Ball:\n    function draw() -> void:"
    refute_includes formatted, "methods Ball:\n\n    function draw() -> void:"
  end

  def test_tidy_mode_does_not_insert_blank_lines_before_first_interface_method
    source = <<~MT
      interface ScreenState:


          editable function update(effect: rl.Sound) -> void
          function draw(texture: rl.Texture2D) -> void
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :tidy)

    assert_includes formatted, "interface ScreenState:\n    editable function update(effect: rl.Sound) -> void"
    refute_includes formatted, "interface ScreenState:\n\n    editable function update(effect: rl.Sound) -> void"
  end

  def test_tidy_mode_inserts_two_blank_lines_before_methods_block
    source = <<~MT
      function helper() -> void:
          return

      methods Ball:
          function draw() -> void:
              return
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :tidy)

    assert_includes formatted, "    return\n\n\nmethods Ball:"
    refute_includes formatted, "    return\n\nmethods Ball:"
  end

  def test_tidy_mode_preserves_utf8_string_literals
    source = <<~MT
      const text: cstr = c"いろはにほへと　ちりぬるを\\nわかよたれそ"
      const path: cstr = c"../resources/DotGothic16-Regular.ttf"
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :tidy)

    assert_includes formatted, "const text: cstr = c\"いろはにほへと　ちりぬるを\\nわかよたれそ\""
    assert_includes formatted, "\nconst path: cstr = c\"../resources/DotGothic16-Regular.ttf\""
  end

  def test_canonical_groups_raw_module_simple_declarations_by_kind
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

    formatted = MilkTea::Formatter.format_source(source, path: "sample.mt", mode: :canonical)

    assert_equal <<~MT, formatted
      external

      include "sample.h"

      opaque Handle = c"struct Handle"
      type Flags = uint

      const MAGIC: int = 7
      const LIMIT: int = 8

      external function init() -> int
      external function close() -> void
    MT
  end
end

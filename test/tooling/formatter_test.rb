# frozen_string_literal: true

require_relative "../test_helper"

class MilkTeaFormatterTest < Minitest::Test
  def test_check_source_detects_changes
    source = "module demo.f\n\ndef main()->i32:\n    return 0\n"

    result = MilkTea::Formatter.check_source(source, path: "demo.mt")

    assert_equal true, result.changed
    assert_equal "module demo.f\n\ndef main() -> i32:\n    return 0\n", result.formatted_source
  end

  def test_build_cst_reconstructs_original_source
    source = <<~MT
      # banner
      module demo.cst

      def main() -> i32: # keep
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
      module demo.fmt

      def main() -> i32: # trailing
          return 0
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :preserve)

    assert_equal source, formatted
  end

  def test_safe_mode_preserves_comments_in_canonical_output
    source = <<~MT
      # banner
      module demo.safe
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt")

    assert_includes formatted, "# banner"
    assert_includes formatted, "module demo.safe"
  end

  def test_canonical_mode_preserves_comments
    source = <<~MT
      # banner
      module demo.fmt
    MT

    # canonical mode now preserves comments — no error raised
    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :canonical)
    assert_includes formatted, "# banner"
    assert_includes formatted, "module demo.fmt"
  end

  def test_reconstruct_handles_comment_only_tail_without_newline
    source = "module demo.tail\n# trailing"

    cst = MilkTea::Formatter.build_cst(source, path: "demo.mt")

    assert_equal source, cst.reconstruct
  end

  # ── comment preservation ─────────────────────────────────────────────

  def test_canonical_preserves_leading_standalone_comment
    source = <<~MT
      # top-level comment
      module demo.comments
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :canonical)

    assert_equal "# top-level comment\nmodule demo.comments\n", formatted
  end

  def test_canonical_preserves_comment_before_function
    source = <<~MT
      module demo.comments

      # computes sum
      def add(a: i32, b: i32) -> i32:
          return a + b
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :canonical)

    assert_includes formatted, "# computes sum"
    idx_comment = formatted.index("# computes sum")
    idx_def     = formatted.index("def add(")
    assert idx_comment < idx_def, "comment should precede function def"
  end

  def test_canonical_preserves_comment_before_statement
    source = <<~MT
      module demo.comments

      def main() -> i32:
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
      module demo.comments

      def main() -> i32:
          let x = 42  # the answer
          return x
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :canonical)

    # Inline comment should appear on the same line as the let statement
    assert_match(/let x = 42\s+# the answer/, formatted)
  end
end

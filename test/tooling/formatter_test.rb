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

  def test_safe_mode_keeps_comment_sources_exactly
    source = <<~MT
      # banner
      module demo.safe
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt")

    assert_equal source, formatted
  end

  def test_canonical_mode_rejects_comment_sources
    source = <<~MT
      # banner
      module demo.fmt
    MT

    error = assert_raises(MilkTea::FormatterError) do
      MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :canonical)
    end

    assert_match(/does not preserve comments/, error.message)
  end

  def test_reconstruct_handles_comment_only_tail_without_newline
    source = "module demo.tail\n# trailing"

    cst = MilkTea::Formatter.build_cst(source, path: "demo.mt")

    assert_equal source, cst.reconstruct
  end
end

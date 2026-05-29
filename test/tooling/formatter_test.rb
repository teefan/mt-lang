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

  def test_canonical_mode_formats_event_declarations
    source = <<~MT
      public event reloaded[4]

      struct Resize:
          width: int
          height: int

      struct Window:
          title: str
          public event closed[4]
          public event resized[8](Resize)
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :canonical)

    assert_equal source, formatted
  end

  def test_canonical_mode_formats_await_expressions
    source = <<~MT
      async function main() -> int:
          return await compute()
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :canonical)

    assert_equal source, formatted
  end

  def test_canonical_mode_formats_async_method_signatures
    source = <<~MT
      struct Worker:
          value: int

      extending Worker:
          public async mutable function tick() -> int:
              return await next()
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :canonical)

    assert_equal source, formatted
  end

  def test_tidy_mode_wraps_long_call_arguments_using_project_max_line_length
    Dir.mktmpdir("milk-tea-formatter-wrap-long-call") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(File.join(dir, ".mt-lint.yml"), <<~YAML)
        max_line_length: 40
        select:
          - line-too-long
        ignore: []
      YAML

      source = <<~MT
        function main() -> int:
            return log_value("alpha", "beta", "gamma", "delta")
      MT

      formatted = MilkTea::Formatter.format_source(source, path: path, mode: :tidy)

      assert_includes formatted, "return log_value(\n"
      assert_includes formatted, "        \"alpha\",\n"
      assert_includes formatted, "        \"delta\",\n"
      formatted.lines.each do |line|
        assert_operator line.delete_suffix("\n").length, :<=, 40
      end
    end
  end

  def test_tidy_mode_wraps_long_static_assert_attribute_reflection_call
    source = <<~MT
      static_assert(has_attribute(PacketBuffer, align) and attribute_arg[ptr_uint](attribute_of(PacketBuffer, align), bytes) == 16, "PacketBuffer should stay 16-byte aligned")
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :tidy, max_line_length: 120)

    assert_includes formatted, "static_assert(\n"
    formatted.lines.each do |line|
      assert_operator line.delete_suffix("\n").length, :<=, 120
    end
  end

  def test_tidy_mode_wraps_long_tuple_literal_without_trailing_comma
    source = <<~MT
      function main() -> int:
          let pair = (alpha_value, beta_value, gamma_value)
          return 0
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :tidy, max_line_length: 40)

    assert_includes formatted, "let pair = (\n"
    assert_includes formatted, "        alpha_value,\n"
    assert_includes formatted, "        gamma_value\n"
    refute_includes formatted, "        gamma_value,\n"
  end

  def test_tidy_mode_wraps_long_type_argument_list
    source = <<~MT
      function main() -> Result[Option[AlphaValue], BetaValue, GammaValue]:
          return 0
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :tidy, max_line_length: 50)

    assert_includes formatted, "function main() -> Result[\n"
    assert_includes formatted, "    Option[AlphaValue],\n"
    assert_includes formatted, "    GammaValue,\n"
    assert_includes formatted, "]:\n"
  end

  def test_tidy_mode_wraps_long_if_logical_chain
    source = <<~MT
      function main(kind: int, has_byte: bool, ctrl: bool, alt: bool, input_byte: int) -> void:
          if kind == 2 and has_byte and not ctrl and not alt and input_byte >= 32 and input_byte < 127 and input_byte != 64:
              pass
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :tidy, max_line_length: 100)

    assert_includes formatted, "    if (\n"
    assert_includes formatted, "        kind == 2\n"
    assert_includes formatted, "        and has_byte\n"
    assert_includes formatted, "        and input_byte != 64\n"
    assert_includes formatted, "    ):\n"
  end

  def test_tidy_mode_wraps_long_else_if_logical_chain
    source = <<~MT
      function main(flag: bool, value: int, other: int) -> int:
          if flag:
              return 1
          else if flag and value > 0 and other > 0 and value != other and other < 100 and value < 200:
              return 2
          return 0
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :tidy, max_line_length: 90)

    assert_includes formatted, "    else if (\n"
    assert_includes formatted, "        flag\n"
    assert_includes formatted, "        and value > 0\n"
    assert_includes formatted, "        and value < 200\n"
    assert_includes formatted, "    ):\n"
  end

  def test_canonical_mode_flattens_grouped_multiline_binary_expression
    source = <<~MT
      function main() -> int:
          let total = (
              subtotal
              + tax
              - discount
          )
          return total
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :canonical)

    assert_equal <<~MT, formatted
      function main() -> int:
          let total = subtotal + tax - discount
          return total
    MT
  end

  def test_preserve_mode_keeps_grouped_multiline_binary_expression
    source = <<~MT
      function main() -> int:
          let total = (
              subtotal
              + tax
              - discount
          )
          return total
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :preserve)

    assert_equal source, formatted
  end

  def test_canonical_mode_flattens_operator_led_binary_continuation
    source = <<~MT
      function main() -> int:
          let total = subtotal +
              tax -
              discount
          return total
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :canonical)

    assert_equal <<~MT, formatted
      function main() -> int:
          let total = subtotal + tax - discount
          return total
    MT
  end

  def test_canonical_mode_preserves_match_statement_bindings
    source = <<~MT
      function main(value: Option[int]) -> int:
          match value:
              Option.some as payload:
                  return payload.value
              Option.none:
                  return 0
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :canonical)

    assert_includes formatted, "Option.some as payload:"
    assert_includes formatted, "return payload.value"
    refute_includes formatted, "Option.some:\n        return payload.value"
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

      extending Ball:


          function draw() -> void:
              return
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :tidy)

    assert_includes formatted, "extending Ball:\n    function draw() -> void:"
    refute_includes formatted, "extending Ball:\n\n    function draw() -> void:"
  end

  def test_tidy_mode_does_not_insert_blank_lines_before_first_interface_method
    source = <<~MT
      interface ScreenState:


          mutable function update(effect: rl.Sound) -> void
          function draw(texture: rl.Texture2D) -> void
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :tidy)

    assert_includes formatted, "interface ScreenState:\n    mutable function update(effect: rl.Sound) -> void"
    refute_includes formatted, "interface ScreenState:\n\n    mutable function update(effect: rl.Sound) -> void"
  end

  def test_tidy_mode_inserts_two_blank_lines_before_extending_block
    source = <<~MT
      function helper() -> void:
          return

      extending Ball:
          function draw() -> void:
              return
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :tidy)

    assert_includes formatted, "    return\n\n\nextending Ball:"
    refute_includes formatted, "    return\n\nextending Ball:"
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

  def test_tidy_mode_formats_attribute_declarations_and_applications
    source = <<~MT
      public  attribute[field, callable]  trace(name: str)

      @[packed, align(16)]
      struct Packet:
          @[trace("payload_len")]
          payload_len : uint

      @[trace(name = "parse_packet")]
      function parse_packet() -> int:
          return 0
    MT

    formatted = MilkTea::Formatter.format_source(source, path: "demo.mt", mode: :tidy)

    assert_equal <<~MT, formatted
      public attribute[field, callable] trace(name: str)

      @[packed, align(16)]
      struct Packet:
          @[trace("payload_len")]
          payload_len : uint

      @[trace(name = "parse_packet")]
      function parse_packet() -> int:
          return 0
    MT
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

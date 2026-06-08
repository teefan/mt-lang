# frozen_string_literal: true

require_relative "../test_helper"

class MilkTeaLexerTest < Minitest::Test
  def test_emits_indent_and_dedent_tokens_for_blocks
    source = <<~MT
      struct Ball:
          radius: float
    MT

    types = MilkTea::Lexer.lex(source).map(&:type)

    assert_equal(
      %i[struct identifier colon newline indent identifier colon identifier newline dedent eof],
      types,
    )
  end

  def test_rejects_tabs
    source = <<~MT
      function main() -> int:
	return 0
    MT

    error = assert_raises(MilkTea::LexError) do
      MilkTea::Lexer.lex(source)
    end

    assert_match(/tabs are not allowed/, error.message)
  end

  def test_ignores_indentation_inside_parenthesized_calls
    source = <<~MT
      function main() -> int:
          var ball = Ball(
              radius = 20.0,
          )
          return 0
    MT

    tokens = MilkTea::Lexer.lex(source)
    types = tokens.map(&:type)

    assert_equal 1, types.count(:indent)
    assert_equal 1, types.count(:dedent)
  end

  def test_lexes_cstrings_booleans_nulls_and_non_decimal_numbers
    source = <<~MT
      const mask: int = 0xff
      const bits: int = 0b1010
      const title: cstr = c"Milk\\nTea"
      const ready: bool = true
      const missing: ptr[Window]? = null
    MT

    tokens = MilkTea::Lexer.lex(source)

    assert_equal 0xff, tokens.find { |token| token.lexeme == "0xff" }.literal
    assert_equal 0b1010, tokens.find { |token| token.lexeme == "0b1010" }.literal
    assert_equal "Milk\nTea", tokens.find { |token| token.type == :cstring }.literal
    assert_equal true, tokens.find { |token| token.type == :true }.literal
    assert_nil tokens.find { |token| token.type == :null }.literal
  end

  def test_lexes_scientific_float_literals
    source = <<~MT
      const epsilon: float = 1.1920929E-7
      const large: double = 2e+3
    MT

    tokens = MilkTea::Lexer.lex(source)

    assert_in_delta 1.1920929e-7, tokens.find { |token| token.lexeme == "1.1920929E-7" }.literal, 1e-15
    assert_in_delta 2000.0, tokens.find { |token| token.lexeme == "2e+3" }.literal, 1e-12
  end

  def test_reports_indentation_and_grouping_errors
    indentation_error = assert_raises(MilkTea::LexError) do
      MilkTea::Lexer.lex("function main() -> int:\n  return 0\n")
    end
    assert_match(/multiples of 4 spaces/, indentation_error.message)

    grouping_error = assert_raises(MilkTea::LexError) do
      MilkTea::Lexer.lex(")\n")
    end
    assert_match(/unexpected closing delimiter/, grouping_error.message)

    unclosed_grouping_error = assert_raises(MilkTea::LexError) do
      MilkTea::Lexer.lex("var ball = Ball(\n")
    end
    assert_match(/unclosed grouping delimiter/, unclosed_grouping_error.message)
  end

  def test_suppresses_newlines_after_range_operator_continuation
    types = MilkTea::Lexer.lex("function main() -> void:\n    let values = 1 ..\n        4\n    pass\n").map(&:type)

    refute_includes types.each_cons(2).to_a, [:dot_dot, :newline]
  end

  def test_lexes_bitwise_tokens_and_normal_strings
    source = <<~MT
      const mask: uint = ~0 | 1 & 2 ^ 4 << 1 >> 0
      link "c"
    MT

    types = MilkTea::Lexer.lex(source).map(&:type)

    assert_includes types, :tilde
    assert_includes types, :pipe
    assert_includes types, :amp
    assert_includes types, :caret
    assert_includes types, :shift_left
    assert_includes types, :shift_right
    assert_includes types, :string
  end

  def test_lexes_ellipsis_token
    types = MilkTea::Lexer.lex("external function printf(format: cstr, ...) -> int\n").map(&:type)

    assert_includes types, :ellipsis
  end

  def test_lexes_attribute_tokens
    types = MilkTea::Lexer.lex("@[packed]\npublic attribute[field] rename(name: str)\n").map(&:type)

    assert_includes types, :at
    assert_includes types, :attribute
  end

  def test_lexes_builtin_attribute_names_as_identifiers
    tokens = MilkTea::Lexer.lex("@[packed]\n@[align(16)]\n")
    packed_token = tokens.find { |token| token.lexeme == "packed" }
    align_token = tokens.find { |token| token.lexeme == "align" }

    refute_nil packed_token
    refute_nil align_token
    assert_equal :identifier, packed_token.type
    assert_equal :identifier, align_token.type
  end

  def test_lexes_pass_as_keyword
    types = MilkTea::Lexer.lex("function main() -> void:\n    pass\n").map(&:type)

    assert_includes types, :pass
  end

  def test_lexes_format_string_literal_parts
    tokens = MilkTea::Lexer.lex("const message = f\"value=\#{count} ok=\#{true}\"\n")
    format_token = tokens.find { |token| token.type == :fstring }

    refute_nil format_token
    assert_equal [:text, :expr, :text, :expr], format_token.literal.map { |part| part.fetch(:kind) }
    assert_equal "value=", format_token.literal[0].fetch(:value)
    assert_equal "count", format_token.literal[1].fetch(:source)
    assert_equal " ok=", format_token.literal[2].fetch(:value)
    assert_equal "true", format_token.literal[3].fetch(:source)
  end

  def test_lexes_format_string_interpolations_with_expression_colons
    tokens = MilkTea::Lexer.lex("const message = f\"value=\#{unsafe: read(handle)} precise=\#{if flag: 1.0 else: 2.0:.2}\"\n")
    format_token = tokens.find { |token| token.type == :fstring }

    refute_nil format_token
    assert_equal "unsafe: read(handle)", format_token.literal[1].fetch(:source)
    assert_nil format_token.literal[1].fetch(:format_spec)
    assert_equal "if flag: 1.0 else: 2.0", format_token.literal[3].fetch(:source)
    assert_equal ".2", format_token.literal[3].fetch(:format_spec)
  end

  def test_lexes_format_string_hex_specs
    tokens = MilkTea::Lexer.lex('const message = f"hex=#{count:x} HEX=#{count:X}"' + "\n")
    format_token = tokens.find { |token| token.type == :fstring }

    refute_nil format_token
    assert_equal "x", format_token.literal[1].fetch(:format_spec)
    assert_equal "X", format_token.literal[3].fetch(:format_spec)
  end

  def test_lexes_format_string_octal_and_binary_specs
    tokens = MilkTea::Lexer.lex('const message = f"oct=#{count:o} OCT=#{count:O} bin=#{count:b} BIN=#{count:B}"' + "\n")
    format_token = tokens.find { |token| token.type == :fstring }

    refute_nil format_token
    assert_equal "o", format_token.literal[1].fetch(:format_spec)
    assert_equal "O", format_token.literal[3].fetch(:format_spec)
    assert_equal "b", format_token.literal[5].fetch(:format_spec)
    assert_equal "B", format_token.literal[7].fetch(:format_spec)
  end

  def test_lexes_heredoc_strings_and_cstrings
    source = <<~MT
      const shader: cstr = c<<-GLSL
          #version 330
          void main()
          {
          }
      GLSL

      const text = <<-TEXT
          alpha
            beta

      TEXT
    MT

    tokens = MilkTea::Lexer.lex(source)
    shader = tokens.find { |token| token.type == :cstring }
    text = tokens.find { |token| token.type == :string }

    refute_nil shader
    refute_nil text
    assert_equal "#version 330\nvoid main()\n{\n}\n", shader.literal
    assert_equal "alpha\n  beta\n\n", text.literal
  end

  def test_lexes_format_heredoc_literal_parts
    source = <<~MT
      const message = f<<-FMT
          value=\#{count}
          precise=\#{if flag: 1.0 else: 2.0:.2}
      FMT
    MT

    tokens = MilkTea::Lexer.lex(source)
    format_token = tokens.find { |token| token.type == :fstring }

    refute_nil format_token
    assert_equal [:text, :expr, :text, :expr, :text], format_token.literal.map { |part| part.fetch(:kind) }
    assert_equal "value=", format_token.literal[0].fetch(:value)
    assert_equal "count", format_token.literal[1].fetch(:source)
    assert_equal "\nprecise=", format_token.literal[2].fetch(:value)
    assert_equal "if flag: 1.0 else: 2.0", format_token.literal[3].fetch(:source)
    assert_equal ".2", format_token.literal[3].fetch(:format_spec)
    assert_equal "\n", format_token.literal[4].fetch(:value)
    assert_equal 2, format_token.literal[1].fetch(:line)
    assert_equal 13, format_token.literal[1].fetch(:column)
  end

  def test_lexes_multiline_adjacent_strings_and_cstrings
    source = <<~MT
      const title = "The quick brown fox"
          " jumps over the lazy dog."

      const c_title: cstr = c"alpha"
          c" beta"
          c" gamma"
    MT

    tokens = MilkTea::Lexer.lex(source)
    title = tokens.find { |token| token.type == :string }
    c_title = tokens.find { |token| token.type == :cstring }

    refute_nil title
    refute_nil c_title
    assert_equal "The quick brown fox jumps over the lazy dog.", title.literal
    assert_equal "alpha beta gamma", c_title.literal
  end

  def test_does_not_merge_non_indented_next_line_strings
    source = <<~MT
      const title = "one"
      "two"
    MT

    tokens = MilkTea::Lexer.lex(source)
    strings = tokens.select { |token| token.type == :string }

    assert_equal 2, strings.length
    assert_equal "one", strings[0].literal
    assert_equal "two", strings[1].literal
  end

  def test_rejects_unterminated_heredoc_literals
    source = <<~MT
      const shader = <<-GLSL
          #version 330
    MT

    error = assert_raises(MilkTea::LexError) do
      MilkTea::Lexer.lex(source)
    end

    assert_match(/unterminated heredoc literal/, error.message)
  end

  def test_recovers_from_unterminated_string_and_continues_lexing_following_declaration
    source = <<~MT
      const title = "milk tea
      function after() -> int:
          return 2
    MT

    recovery_errors = []
    tokens = MilkTea::Lexer.lex(source, path: "string_recovery.mt", recovery_errors: recovery_errors)

    assert_equal 1, recovery_errors.length
    assert_match(/unterminated string literal/, recovery_errors.first.message)
    assert_includes tokens.map(&:type), :function
    assert_includes tokens.map(&:lexeme), "after"
  end

  def test_recovers_from_unterminated_heredoc_and_continues_lexing_following_declaration
    source = <<~MT
      const shader = <<-GLSL
          #version 330
      function after() -> int:
          return 2
    MT

    recovery_errors = []
    tokens = MilkTea::Lexer.lex(source, path: "heredoc_recovery.mt", recovery_errors: recovery_errors)

    assert_equal 1, recovery_errors.length
    assert_match(/unterminated heredoc literal/, recovery_errors.first.message)
    assert_includes tokens.map(&:type), :function
    assert_includes tokens.map(&:lexeme), "after"
  end

  def test_recovers_from_unterminated_format_string_and_continues_lexing_following_declaration
    source = <<~'MT'
      const message = f"value=#{1 + 2
      function after() -> int:
          return 2
    MT

    recovery_errors = []
    tokens = MilkTea::Lexer.lex(source, path: "format_recovery.mt", recovery_errors: recovery_errors)

    assert_equal 2, recovery_errors.length
    assert_match(/unterminated format interpolation|unterminated format string literal/, recovery_errors.first.message)
    assert_includes tokens.map(&:type), :function
    assert_includes tokens.map(&:lexeme), "after"
  end

  def test_recovers_from_unmatched_closing_delimiter_and_continues_lexing_following_declaration
    source = <<~MT
      function main() -> int:
          return )

      function after() -> int:
          return 2
    MT

    recovery_errors = []
    tokens = MilkTea::Lexer.lex(source, path: "grouping_recovery.mt", recovery_errors: recovery_errors)

    assert_equal 1, recovery_errors.length
    assert_match(/unexpected closing delimiter/, recovery_errors.first.message)
    assert_includes tokens.map(&:type), :function
    assert_equal 2, tokens.count { |token| token.type == :function }
  end

  def test_recovers_from_stray_closing_brace_and_continues_lexing_following_declaration
    source = <<~MT
      function main() -> int:
          return }

      function after() -> int:
          return 2
    MT

    recovery_errors = []
    tokens = MilkTea::Lexer.lex(source, path: "brace_recovery.mt", recovery_errors: recovery_errors)

    assert_equal 1, recovery_errors.length
    assert_match(/unexpected closing delimiter/, recovery_errors.first.message)
    assert_equal 2, tokens.count { |token| token.type == :function }
  end

  def test_lex_with_trivia_captures_comments_and_blank_lines
    source = <<~MT
      # module banner

      function main() -> int: # inline doc
          return 0
    MT

    result = MilkTea::Lexer.lex_with_trivia(source)

    comment_kinds = result.trivia.select { |token| token.kind == :comment }
    blank_line_kinds = result.trivia.select { |token| token.kind == :blank_line }

    assert_equal 2, comment_kinds.length
    assert_equal 1, blank_line_kinds.length

    main_token = result.tokens.find { |token| token.lexeme == "function" }
    refute_nil main_token
    assert_equal true, main_token.leading_trivia.any? { |token| token.kind == :comment }

    colon_token = result.tokens.find { |token| token.type == :colon }
    refute_nil colon_token
    assert_equal true, colon_token.trailing_trivia.any? { |token| token.kind == :comment }
  end

  def test_lexed_tokens_include_source_offsets
    tokens = MilkTea::Lexer.lex("let answer = 42\n")
    let_token = tokens.find { |token| token.lexeme == "let" }
    int_token = tokens.find { |token| token.lexeme == "42" }

    refute_nil let_token
    refute_nil int_token
    assert_equal 0, let_token.start_offset
    assert_equal 3, let_token.end_offset
    assert_equal 13, int_token.start_offset
    assert_equal 15, int_token.end_offset
  end
end

# frozen_string_literal: true

require_relative "../test_helper"

class DiagnosticConversionTest < Minitest::Test
  def assert_diagnostic(error, expected_code:, expected_line: nil, expected_column: nil, expected_path: nil)
    diagnostic = error.to_diagnostic
    assert_instance_of(MilkTea::Diagnostic, diagnostic)
    assert_equal(expected_code, diagnostic.code)
    assert_equal(:error, diagnostic.severity)
    assert_equal(expected_line, diagnostic.line)
    assert_equal(expected_column, diagnostic.column)
    assert_equal(expected_path, diagnostic.path)
  end

  def test_lex_error_converts_with_lex_code
    error = MilkTea::LexError.new("bad token", line: 3, column: 7, path: "a.mt")
    assert_diagnostic(error, expected_code: "lex/error", expected_line: 3, expected_column: 7, expected_path: "a.mt")
  end

  def build_token(line:, column:)
    MilkTea::Token.new(
      type: :identifier,
      lexeme: "x",
      literal: nil,
      line:,
      column:,
      start_offset: 0,
      end_offset: 1,
      leading_trivia: [],
      trailing_trivia: [],
    )
  end

  def test_parse_error_converts_with_parse_code
    token = build_token(line: 5, column: 2)
    error = MilkTea::ParseError.new("expected newline", token:, path: "b.mt")
    assert_diagnostic(error, expected_code: "parse/error", expected_line: 5, expected_column: 2, expected_path: "b.mt")
  end

  def test_semantic_error_converts_with_sema_code
    error = MilkTea::SemanticError.new("bad type", line: 9, column: 4, length: 3, path: "c.mt")
    assert_diagnostic(error, expected_code: "sema/error", expected_line: 9, expected_column: 4, expected_path: "c.mt")
    assert_equal(3, error.to_diagnostic.length)
  end

  def test_module_load_error_converts_with_module_code
    error = MilkTea::ModuleLoadError.new("source file not found", path: "d.mt", line: 1, column: 2)
    assert_diagnostic(error, expected_code: "module/error", expected_line: 1, expected_column: 2, expected_path: "d.mt")
  end

  def test_lowering_error_converts_with_lowering_code
    error = MilkTea::LoweringError.new("unknown callee", line: 2, column: 3, path: "e.mt")
    assert_diagnostic(error, expected_code: "lowering/internal", expected_line: 2, expected_column: 3, expected_path: "e.mt")
  end

  def test_c_backend_error_converts_with_backend_code
    error = MilkTea::CBackendError.new("unsupported type", line: 1, column: 1, path: "f.mt")
    assert_diagnostic(error, expected_code: "backend/internal", expected_line: 1, expected_column: 1, expected_path: "f.mt")
  end

  def test_compile_time_error_converts_with_compile_time_code
    error = MilkTea::CompileTime::Error.new("iteration limit exceeded")
    diagnostic = error.to_diagnostic(path: "g.mt")
    assert_instance_of(MilkTea::Diagnostic, diagnostic)
    assert_equal("compile_time/error", diagnostic.code)
    assert_equal(:error, diagnostic.severity)
    assert_equal("g.mt", diagnostic.path)
    assert_nil(diagnostic.line)
    assert_nil(diagnostic.column)
  end

  def test_to_diagnostic_uses_supplied_path_when_error_has_none
    token = build_token(line: 1, column: 1)
    error = MilkTea::ParseError.new("boom", token:)
    diagnostic = error.to_diagnostic(path: "supplied.mt")
    assert_equal("supplied.mt", diagnostic.path)
  end
end

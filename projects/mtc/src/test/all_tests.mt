## Test runner — collects and runs all lexer tests.

import std.testing as t
import test.lexer_test as lex_tests

public function run_all() -> int:
    var stats = t.Stats.create()

    stats = t.record(stats, "keywords_are_recognized", lex_tests.test_keywords_are_recognized())
    stats = t.record(stats, "bool_and_null_literals", lex_tests.test_bool_and_null_literals())
    stats = t.record(stats, "integer_literals", lex_tests.test_integer_literals())
    stats = t.record(stats, "float_literals", lex_tests.test_float_literals())
    stats = t.record(stats, "char_literals", lex_tests.test_char_literals())
    stats = t.record(stats, "string_literal_escapes", lex_tests.test_string_literal_escapes())
    stats = t.record(stats, "cstring_literal", lex_tests.test_cstring_literal())
    stats = t.record(stats, "heredoc_cstring", lex_tests.test_heredoc_cstring())
    stats = t.record(stats, "heredoc_string", lex_tests.test_heredoc_string())
    stats = t.record(stats, "format_string", lex_tests.test_format_string())
    stats = t.record(stats, "operators", lex_tests.test_operators())
    stats = t.record(stats, "assignment_operators", lex_tests.test_assignment_operators())
    stats = t.record(stats, "indentation_increases", lex_tests.test_indentation_increases())
    stats = t.record(stats, "grouping_suppresses_newlines", lex_tests.test_grouping_suppresses_newlines())
    stats = t.record(stats, "line_continuation", lex_tests.test_line_continuation())
    stats = t.record(stats, "comments_are_skipped", lex_tests.test_comments_are_skipped())
    stats = t.record(stats, "comment_only_source", lex_tests.test_comment_only_source())
    stats = t.record(stats, "empty_source", lex_tests.test_empty_source())
    stats = t.record(stats, "adjacent_strings", lex_tests.test_adjacent_strings())
    stats = t.record(stats, "parallel_keyword", lex_tests.test_parallel_keyword())

    return t.summarize(stats)

## In-language tests for the CST-backed formatter modes (`:tidy`, `:preserve`).
## Run with: `mtc test projects/mtc`.
##
## Every expected string in this file is the Ruby host's output
## (`MilkTea::Formatter.check_source(..., mode: :tidy | :preserve)`) for the
## same input, so these tests pin the self-host to host behaviour, including
## the host's quirks (continuation newlines dropped by the CST reconstruct,
## multi-byte lines measured in characters).

import std.str
import std.string as string
import std.vec as vec

import mtc.formatter.cst as cst
import mtc.formatter.tidy as tidy
import mtc.lexer.token as tok


## `:tidy` with the default maximum line length.
function format_tidy(source: str) -> string.String:
    let formatted = tidy.format_tidy(source, "test.mt", 120, null) else:
        return string.String.from_str("FAIL: tidy refused to format")
    return formatted


## `:preserve` (CST reconstruct).
function format_preserve(source: str) -> string.String:
    let formatted = tidy.format_preserve(source, null) else:
        return string.String.from_str("FAIL: preserve refused to format")
    return formatted

# =============================================================================
#  Blank-line rules, comments and space normalization
# =============================================================================


@[test]
function test_tidy_blank_lines_and_comments() -> void:
    var source = string.String.from_str(
        "import std.vec as vec\n\n\n## Doc comment.\nstruct  Sample:\n    x:int\n    y:int\nstruct Other:\n    z:int\nextending Sample:\n    function sum() -> int:\n        return this.x + this.y\nfunction main() -> int:\n    # inline comment\n    return 0\n",
    )
    defer: source.release()

    var formatted = format_tidy(source.as_str())
    defer: formatted.release()

    expect_eq(
        formatted.as_str(),
        "import std.vec as vec\n\n\n## Doc comment.\nstruct Sample:\n    x:int\n    y:int\n\nstruct Other:\n    z:int\n\n\nextending Sample:\n    function sum() -> int:\n        return this.x + this.y\n\n\nfunction main() -> int:\n    # inline comment\n    return 0\n",
    )


@[test]
function test_tidy_keeps_doc_comment_attached_to_function() -> void:
    ## `##` docs attach to the next declaration only with no blank line; the
    ## blank-line pass must not insert one between the docs and the function.
    var source = string.String.from_str(
        "## Documentation.\nfunction main() -> void:\n    pass\n",
    )
    defer: source.release()

    var formatted = format_tidy(source.as_str())
    defer: formatted.release()

    expect(formatted.as_str().contains_substring("## Documentation.\nfunction main"))
    expect(not formatted.as_str().contains_substring("## Documentation.\n\nfunction main"))

    var again = format_tidy(formatted.as_str())
    defer: again.release()
    expect_eq(again.as_str(), formatted.as_str())


@[test]
function test_tidy_keeps_doc_comment_attached_after_a_function() -> void:
    ## The insertion bug appeared when the previous content was a bodyful
    ## function: the docs themselves were separated from the next declaration.
    var source = string.String.from_str(
        "function first() -> void:\n    pass\n\n\n## Documentation.\nfunction second() -> void:\n    pass\n",
    )
    defer: source.release()

    var formatted = format_tidy(source.as_str())
    defer: formatted.release()

    expect(formatted.as_str().contains_substring("## Documentation.\nfunction second"))
    expect(not formatted.as_str().contains_substring("## Documentation.\n\nfunction second"))


@[test]
function test_tidy_preserves_blank_separating_doc_comment() -> void:
    ## A blank line between docs and the declaration is the author's explicit
    ## choice to detach them; the pass keeps one blank.
    var source = string.String.from_str(
        "## Not attached.\n\nfunction main() -> void:\n    pass\n",
    )
    defer: source.release()

    var formatted = format_tidy(source.as_str())
    defer: formatted.release()

    expect(formatted.as_str().contains_substring("## Not attached.\n\nfunction main"))

# =============================================================================
#  Long-line wrapping
# =============================================================================


@[test]
function test_tidy_wraps_argument_lists() -> void:
    var source = string.String.from_str(
        "function main() -> int:\n    return call_alpha(argument_one, argument_two, argument_three, argument_four, argument_five, argument_six, argument_seven, argument_eight)\n",
    )
    defer: source.release()

    var formatted = format_tidy(source.as_str())
    defer: formatted.release()

    expect_eq(
        formatted.as_str(),
        "function main() -> int:\n    return call_alpha(\n        argument_one,\n        argument_two,\n        argument_three,\n        argument_four,\n        argument_five,\n        argument_six,\n        argument_seven,\n        argument_eight\n    )\n",
    )


@[test]
function test_tidy_wraps_logical_chains() -> void:
    var source = string.String.from_str(
        "function main() -> bool:\n    if alpha_condition_one and alpha_condition_two and alpha_condition_three and alpha_condition_four and alpha_condition_five and alpha_condition_six:\n        return true\n    return false\n",
    )
    defer: source.release()

    var formatted = format_tidy(source.as_str())
    defer: formatted.release()

    expect_eq(
        formatted.as_str(),
        "function main() -> bool:\n    if (\n        alpha_condition_one\n        and alpha_condition_two\n        and alpha_condition_three\n        and alpha_condition_four\n        and alpha_condition_five\n        and alpha_condition_six\n    ):\n        return true\n    return false\n",
    )


@[test]
function test_tidy_wraps_chain_of_equal_width_groups() -> void:
    ## Equal-width candidates keep source order (the host's `sort_by` is stable
    ## for the small candidate lists a line produces), so the middle call wraps.
    var source = string.String.from_str(
        "function main() -> bool:\n    if a and b:\n        if c:\n            if d:\n                return expr_calls(cond.condition, name) or expr_calls(cond.then_expression, name) or expr_calls(cond.else_expression, name)\n    return false\n",
    )
    defer: source.release()

    var formatted = format_tidy(source.as_str())
    defer: formatted.release()

    expect_eq(
        formatted.as_str(),
        "function main() -> bool:\n    if a and b:\n        if c:\n            if d:\n                return expr_calls(cond.condition, name) or expr_calls(\n                    cond.then_expression,\n                    name\n                ) or expr_calls(cond.else_expression, name)\n    return false\n",
    )


@[test]
function test_tidy_preserves_heredoc_literal() -> void:
    ## A heredoc is one multi-line token, not layout.  Its body must be copied
    ## verbatim: the blank-line pass used to see its `function` line as a
    ## top-level declaration and insert blank lines into the literal.
    var source = string.String.from_str(
        "function main() -> void:\n    var text = <<-TXT\n        function inner() -> int:\n            return 1\n    TXT\n    expect(text.len > 0)\n"
    )
    defer: source.release()

    var first = format_tidy(source.as_str())
    defer: first.release()
    expect(first.as_str().contains_substring("<<-TXT\n        function inner() -> int:\n            return 1\n    TXT"))
    expect(not first.as_str().contains_substring("<<-TXT\n\n"))
    var second = format_tidy(first.as_str())
    defer: second.release()
    expect_eq(second.as_str(), first.as_str())


@[test]
function test_tidy_two_blanks_between_imports_and_commented_function() -> void:
    ## PEP 8 / Black / ruff: two blank lines after the import block precede a
    ## top-level function's comment block, and the block stays attached.
    var source = string.String.from_str(
        "import std.vec as vec\n\n## Docs for main.\nfunction main() -> void:\n    pass\n"
    )
    defer: source.release()

    var formatted = format_tidy(source.as_str())
    defer: formatted.release()
    expect(formatted.as_str().contains_substring("import std.vec as vec\n\n\n## Docs for main.\nfunction main"))


@[test]
function test_tidy_two_blanks_before_comment_block_on_function() -> void:
    ## A top-level comment block introducing a function belongs to it, so the
    ## two-blank-line function separator goes before the block (PEP 8 / ruff).
    var source = string.String.from_str(
        "function first() -> void:\n    pass\n\n## Docs for second.\nfunction second() -> void:\n    pass\n"
    )
    defer: source.release()

    var formatted = format_tidy(source.as_str())
    defer: formatted.release()
    expect(formatted.as_str().contains_substring("pass\n\n\n## Docs for second.\nfunction second"))


@[test]
function test_tidy_preserves_continuation_newlines() -> void:
    ## The CST's trivia omits a newline after a continuation operator.  Tidy
    ## must keep the source gap: its own wrap pass emits those newlines, so
    ## dropping them made a second tidy pass undo the first.
    var source = string.String.from_str("function main() -> int:\n    let x = 1 +\n        2\n    return x\n")
    defer: source.release()

    var first = format_tidy(source.as_str())
    defer: first.release()
    expect(first.as_str().contains_substring("let x = 1 +\n        2"))
    var second = format_tidy(first.as_str())
    defer: second.release()
    expect_eq(second.as_str(), first.as_str())


@[test]
function test_tidy_wraps_more_than_100_long_lines_in_one_pass() -> void:
    ## The wrap-fix budget must scale with the file: a fixed 100 left the
    ## remaining long lines for the next `format` invocation, so a file with
    ## more than 100 of them was not idempotent.
    var source = string.String.create()
    defer: source.release()
    source.append("function main() -> void:\n")
    var i: ptr_uint = 0
    while i < 120:
        source.append("    let value = call_alpha(argument_one, argument_two, argument_three, argument_four, argument_five, argument_six, argument_seven)\n")
        i += 1

    var first = format_tidy(source.as_str())
    defer: first.release()
    var second = format_tidy(first.as_str())
    defer: second.release()

    expect_eq(second.as_str(), first.as_str())


@[test]
function test_tidy_measures_multibyte_lines_in_characters() -> void:
    ## 73 characters, 79 bytes: under the 120 limit, so nothing wraps — the
    ## host measures `String#length` (characters), not bytes.
    var source = string.String.from_str(
        "function main() -> int:\n    let message = \"Falsches \u00dcben von Xylophonmusik qu\u00e4lt jeden gr\u00f6\u00dferen Zwerg\"\n    return message.len\n",
    )
    defer: source.release()

    var formatted = format_tidy(source.as_str())
    defer: formatted.release()

    expect_eq(
        formatted.as_str(),
        "function main() -> int:\n    let message = \"Falsches \u00dcben von Xylophonmusik qu\u00e4lt jeden gr\u00f6\u00dferen Zwerg\"\n    return message.len\n",
    )

# =============================================================================
#  Preserve (CST reconstruct)
# =============================================================================


@[test]
function test_preserve_is_verbatim() -> void:
    var source = string.String.from_str("struct  Sample:\n    x:int\n\n\n# a comment\nfunction main() -> int:\n    return 0\n")
    defer: source.release()

    var formatted = format_preserve(source.as_str())
    defer: formatted.release()

    expect_eq(formatted.as_str(), source.as_str())


@[test]
function test_preserve_drops_continuation_newlines() -> void:
    ## Host quirk: a newline after a line-continuation operator is not part of
    ## the CST (neither a token nor trivia), so the reconstruct joins the lines.
    var source = string.String.from_str("function main() -> int:\n    let x = 1 +\n        2\n    return x\n")
    defer: source.release()

    var formatted = format_preserve(source.as_str())
    defer: formatted.release()

    expect_eq(formatted.as_str(), "function main() -> int:\n    let x = 1 +        2\n    return x\n")

# =============================================================================
#  CST building directly
# =============================================================================


@[test]
function test_cst_reconstruct_normalized_collapses_only_interior_spaces() -> void:
    ## Indentation, comments and blank lines survive; interior runs collapse.
    var source = string.String.from_str("function  main()  ->  int:\n    # keep    me\n    return  0\n")
    defer: source.release()

    var diags = vec.Vec[tok.LexDiagnostic].create()
    defer: diags.release()
    var tree = cst.build_cst(source.as_str(), ref_of(diags))
    defer: cst.release_cst(ref_of(tree))

    expect_eq(diags.len(), 0)

    var normalized = cst.reconstruct_normalized(tree)
    defer: normalized.release()
    expect_eq(normalized.as_str(), "function main() -> int:\n    # keep    me\n    return 0\n")

    var verbatim = cst.reconstruct(tree)
    defer: verbatim.release()
    expect_eq(verbatim.as_str(), source.as_str())

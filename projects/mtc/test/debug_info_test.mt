## Pins the debug dump's histogram sort: MRI's *uniform* introsort
## (`rb_uniform_intro_sort_2`, `enum.c`) — the path `sort_by { |_k, v| -v }`
## takes when every computed key is a Fixnum.  It is not stable, so the
## tie orders below are MRI's, not insertion order; they were recorded by
## running the same count tables through MRI.

import std.vec as vec

import mtc.lexer.token_kinds as tk
import mtc.lsp.debug_info as debug_info


function build_entries(
    entries: ref[vec.Vec[debug_info.HistogramEntry]],
    kinds: span[tk.TokenKind],
    counts: span[ptr_uint]
) -> void:
    var i: ptr_uint = 0
    while i < kinds.len:
        entries.push(debug_info.HistogramEntry(
            kind = unsafe: read(kinds.data + i),
            count = unsafe: read(counts.data + i),
        ))
        i += 1


function expect_kinds(
    entries: ref[vec.Vec[debug_info.HistogramEntry]],
    expected: span[tk.TokenKind],
    label: str
) -> void:
    if entries.len() != expected.len:
        expect(false, label)
        return
    var i: ptr_uint = 0
    while i < expected.len:
        let ep = entries.get(i) else:
            expect(false, label)
            return
        if unsafe: read(ep).kind != unsafe: read(expected.data + i):
            expect(false, label)
            return
        i += 1
    return


@[test]
function test_histogram_intro_tie_pair() -> void:
    # counts [1, 2, 1, 1, 1] over five kinds; MRI orders the two leading
    # equal counts 1, 0 (a partition swap).
    let kinds = array[tk.TokenKind, 5](tk.TokenKind.identifier, tk.TokenKind.integer,
                                      tk.TokenKind.string, tk.TokenKind.float_literal,
                                      tk.TokenKind.lparen)
    let counts = array[ptr_uint, 5](1, 2, 1, 1, 1)
    var entries = vec.Vec[debug_info.HistogramEntry].create()
    defer: entries.release()
    build_entries(ref_of(entries), kinds.as_span(), counts.as_span())
    debug_info.histogram_intro_sort(ref_of(entries))
    let expected = array[tk.TokenKind, 5](tk.TokenKind.integer, tk.TokenKind.identifier,
                                         tk.TokenKind.string, tk.TokenKind.float_literal,
                                         tk.TokenKind.lparen)
    expect_kinds(ref_of(entries), expected.as_span(), "tie pair")
    return


@[test]
function test_histogram_intro_ascending_counts() -> void:
    # Eighteen kinds, all count 1 except the last at 2: MRI's introsort
    # reverses the run of equal keys.
    let kinds = array[tk.TokenKind, 18](
        tk.TokenKind.identifier, tk.TokenKind.integer, tk.TokenKind.string,
        tk.TokenKind.float_literal, tk.TokenKind.lparen, tk.TokenKind.rparen,
        tk.TokenKind.comma, tk.TokenKind.dot, tk.TokenKind.equal, tk.TokenKind.plus,
        tk.TokenKind.star, tk.TokenKind.colon, tk.TokenKind.newline, tk.TokenKind.indent,
        tk.TokenKind.dedent, tk.TokenKind.eof, tk.TokenKind.lbracket, tk.TokenKind.rbracket)
    let counts = array[ptr_uint, 18](1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2)
    var entries = vec.Vec[debug_info.HistogramEntry].create()
    defer: entries.release()
    build_entries(ref_of(entries), kinds.as_span(), counts.as_span())
    debug_info.histogram_intro_sort(ref_of(entries))
    let expected = array[tk.TokenKind, 18](
        tk.TokenKind.rbracket, tk.TokenKind.lbracket, tk.TokenKind.eof, tk.TokenKind.dedent,
        tk.TokenKind.indent, tk.TokenKind.newline, tk.TokenKind.colon, tk.TokenKind.star,
        tk.TokenKind.plus, tk.TokenKind.equal, tk.TokenKind.dot, tk.TokenKind.comma,
        tk.TokenKind.rparen, tk.TokenKind.lparen, tk.TokenKind.float_literal, tk.TokenKind.string,
        tk.TokenKind.integer, tk.TokenKind.identifier)
    expect_kinds(ref_of(entries), expected.as_span(), "ascending counts")
    return


@[test]
function test_histogram_intro_alternating() -> void:
    # Twenty kinds alternating 3, 1: exercises the quicksort partition path
    # (n > 16).
    let kinds = array[tk.TokenKind, 20](
        tk.TokenKind.identifier, tk.TokenKind.integer, tk.TokenKind.string,
        tk.TokenKind.float_literal, tk.TokenKind.lparen, tk.TokenKind.rparen,
        tk.TokenKind.comma, tk.TokenKind.dot, tk.TokenKind.equal, tk.TokenKind.plus,
        tk.TokenKind.star, tk.TokenKind.colon, tk.TokenKind.newline, tk.TokenKind.indent,
        tk.TokenKind.dedent, tk.TokenKind.eof, tk.TokenKind.lbracket, tk.TokenKind.rbracket,
        tk.TokenKind.slash, tk.TokenKind.minus)
    let counts = array[ptr_uint, 20](3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1)
    var entries = vec.Vec[debug_info.HistogramEntry].create()
    defer: entries.release()
    build_entries(ref_of(entries), kinds.as_span(), counts.as_span())
    debug_info.histogram_intro_sort(ref_of(entries))
    let expected = array[tk.TokenKind, 20](
        tk.TokenKind.slash, tk.TokenKind.lbracket, tk.TokenKind.dedent, tk.TokenKind.newline,
        tk.TokenKind.star, tk.TokenKind.equal, tk.TokenKind.comma, tk.TokenKind.lparen,
        tk.TokenKind.string, tk.TokenKind.identifier, tk.TokenKind.dot, tk.TokenKind.rparen,
        tk.TokenKind.plus, tk.TokenKind.colon, tk.TokenKind.float_literal, tk.TokenKind.indent,
        tk.TokenKind.eof, tk.TokenKind.integer, tk.TokenKind.rbracket, tk.TokenKind.minus)
    expect_kinds(ref_of(entries), expected.as_span(), "alternating counts")
    return


@[test]
function test_histogram_intro_already_sorted_is_untouched() -> void:
    # The host's `rb_uniform_is_larger` probe short-circuits a descending run.
    let kinds = array[tk.TokenKind, 5](tk.TokenKind.identifier, tk.TokenKind.integer,
                                      tk.TokenKind.string, tk.TokenKind.float_literal,
                                      tk.TokenKind.lparen)
    let counts = array[ptr_uint, 5](5, 4, 3, 2, 1)
    var entries = vec.Vec[debug_info.HistogramEntry].create()
    defer: entries.release()
    build_entries(ref_of(entries), kinds.as_span(), counts.as_span())
    debug_info.histogram_intro_sort(ref_of(entries))
    let expected = array[tk.TokenKind, 5](tk.TokenKind.identifier, tk.TokenKind.integer,
                                         tk.TokenKind.string, tk.TokenKind.float_literal,
                                         tk.TokenKind.lparen)
    expect_kinds(ref_of(entries), expected.as_span(), "already sorted")
    return

## Concrete syntax tree for the formatter: the token stream plus the trivia
## entries the with-trivia lexer collected.
##
## Ports `lib/milk_tea/core/cst.rb` (reconstruct / reconstruct_normalized).
## The Ruby CST attaches leading/trailing trivia to each token; the reconstruct
## here merges the source-ordered trivia list with the token list by offset,
## which emits the same bytes because trivia never crosses a token span.

import std.string as string
import std.vec as vec

import mtc.lexer.lexer as lexer
import mtc.lexer.token as tok
import mtc.lexer.token_kinds as tk
import mtc.lexer.trivia as triv


public struct CstSourceFile:
    source: str
    tokens: vec.Vec[tok.Token]
    trivia: vec.Vec[triv.TriviaEntry]


## Build the CST, collecting lexer diagnostics into `diagnostics`.
public function build_cst(source: str, diagnostics: ref[vec.Vec[tok.LexDiagnostic]]) -> CstSourceFile:
    let lexed = lexer.lex_with_trivia(source, diagnostics)
    return CstSourceFile(source = source, tokens = lexed.tokens, trivia = lexed.trivia)


public function release_cst(cst: ref[CstSourceFile]) -> void:
    cst.tokens.release()
    cst.trivia.release()


## Reconstruct the source verbatim (host mode `:preserve`).
public function reconstruct(cst: CstSourceFile) -> string.String:
    return reconstruct_with(cst, false)


## Reconstruct the source with interior whitespace runs collapsed to a single
## space.  Line indentation (a leading space run at column 1), comments, blank
## lines and swallowed grouping newlines stay verbatim (host mode `:tidy`'s
## normalize step).
public function reconstruct_normalized(cst: CstSourceFile) -> string.String:
    return reconstruct_with(cst, true)


function reconstruct_with(cst: CstSourceFile, normalize_spaces: bool) -> string.String:
    var output = string.String.create()

    var trivia_index: ptr_uint = 0
    var token_index: ptr_uint = 0

    while token_index < cst.tokens.len():
        let token_ptr = cst.tokens.get(token_index) else:
            break
        let token = unsafe: read(token_ptr)

        while trivia_index < cst.trivia.len():
            let entry_ptr = cst.trivia.get(trivia_index) else:
                break
            let entry = unsafe: read(entry_ptr)
            if entry.start_offset > token.start_offset:
                break
            append_trivia_entry(ref_of(output), cst.source, entry, normalize_spaces)
            trivia_index += 1

        if token.kind != tk.TokenKind.eof:
            append_source_segment(ref_of(output), cst.source, token.start_offset, token.end_offset)

        token_index += 1

    while trivia_index < cst.trivia.len():
        let entry_ptr = cst.trivia.get(trivia_index) else:
            break
        let entry = unsafe: read(entry_ptr)
        append_trivia_entry(ref_of(output), cst.source, entry, normalize_spaces)
        trivia_index += 1

    return output


function append_trivia_entry(
    output: ref[string.String],
    source: str,
    entry: triv.TriviaEntry,
    normalize_spaces: bool,
) -> void:
    if normalize_spaces and entry.kind == triv.TriviaKind.space and entry.column > 1:
        unsafe:
            read(output).append(" ")
        return
    append_source_segment(output, source, entry.start_offset, entry.end_offset)


function append_source_segment(output: ref[string.String], source: str, start_offset: ptr_uint, end_offset: ptr_uint) -> void:
    if end_offset <= start_offset or end_offset > source.len:
        return
    let segment = unsafe: str(data = source.data + start_offset, len = end_offset - start_offset)
    unsafe:
        read(output).append(segment)

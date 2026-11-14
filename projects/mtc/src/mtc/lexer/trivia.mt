## Trivia collected by the lexer's with-trivia mode (comments, blank lines,
## whitespace runs, and newlines swallowed by a grouping continuation).
##
## Mirrors the Ruby lexer's `Lexer::Trivia` hooks and `TriviaToken` kinds
## (`lib/milk_tea/core/lexer/trivia.rb`), which the concrete-syntax-tree
## reconstruct and the tidy formatter consume.

import std.vec as vec

import mtc.lexer.token as token_mod


## Trivia kinds.  `space` is the only kind the normalized reconstruct
## rewrites (to a single space, unless it is line indentation).
public enum TriviaKind: ubyte
    blank_line = 0
    comment    = 1
    space      = 2
    newline    = 3


## One piece of non-token source text, in source order.
public struct TriviaEntry:
    kind: TriviaKind
    start_offset: ptr_uint
    end_offset: ptr_uint
    line: ptr_uint
    column: ptr_uint


## Result of a with-trivia lex: the ordinary token stream plus every trivia
## entry in source order.  `tokens` and `trivia` are owned; the caller
## releases both (see `formatter.cst.release_cst`).
public struct CstLexResult:
    tokens: vec.Vec[token_mod.Token]
    trivia: vec.Vec[TriviaEntry]

## Parser state and core token access — the shared foundation imported by
## `parser.mt` and its extracted sub-modules (`literal_parsing.mt`, etc.).
##
## Moves `ParserState`, `ParseDiagnostic`, and the minimal set of
## token-access helpers so extracted parser sub-modules can consume/dispatch
## tokens without a circular dependency on the full parser.

import std.map as map_mod
import std.vec as vec

import mtc.lexer.token_kinds as tk
import mtc.lexer.token as token_mod
import mtc.parser.token_stream as ts


## Diagnostic with position info — survives function scope (value type).
public struct ParseDiagnostic:
    line: ptr_uint
    column: ptr_uint
    message: cstr
    lexeme: str
    kind: str

const MAX_LOOP_STEPS: ptr_uint = 500000
const MAX_TOTAL_STEPS: ptr_uint = 50000000

public struct ParserState:
    stream: ts.TokenStream
    source: str
    step_counter: ptr_uint
    total_steps: ptr_uint
    in_inline_block_body: bool
    recovery_errors: ptr[vec.Vec[ParseDiagnostic]]?
    known_type_names: map_mod.Map[str, bool]
    known_import_aliases: map_mod.Map[str, bool]
    known_generic_callable_names: map_mod.Map[str, bool]
    current_type_param_names: vec.Vec[str]
    suppress_errors: bool
    error_suppressed: bool


# =============================================================================
#  Loop guard — per-declaration safety net against parser bugs.
#  The caller (parse_declaration) resets step_counter to zero before each
#  top-level declaration, so a single stuck loop aborts quickly without
#  blocking legitimate large files (cumulative steps across many declarations
#  are intentionally not counted — only steps within one declaration matter).
# =============================================================================

public function step(s: ref[ParserState]) -> void:
    s.step_counter += 1
    s.total_steps += 1
    if s.total_steps > MAX_TOTAL_STEPS:
        record_loop_guard_diagnostic(s, 0, 0)
        fatal(c"parser step limit exceeded: the source file is too large or the parser entered an unrecoverable loop")
        return
    if s.step_counter > MAX_LOOP_STEPS:
        if not s.error_suppressed:
            let tok = peek(s) else:
                record_loop_guard_diagnostic(s, 0, 0)
                s.error_suppressed = true
                return
            unsafe:
                let t = read(tok)
                record_loop_guard_diagnostic(s, t.line, t.column)
                s.error_suppressed = true
                return
        ts.advance(ref_of(s.stream))
        s.step_counter = 0
        return


function record_loop_guard_diagnostic(s: ref[ParserState], line: ptr_uint, col: ptr_uint) -> void:
    unsafe:
        let diags_ptr = read(s).recovery_errors
        if diags_ptr == null:
            return
        var diags = read(diags_ptr)
        let diag = ParseDiagnostic(
            line = line,
            column = col,
            message = c"internal parser error: loop guard triggered — this is a compiler bug, please report it",
            lexeme = "",
            kind = ""
        )
        diags.push(diag)
        read(diags_ptr) = diags


# =============================================================================
#  Token access helpers
# =============================================================================

public function peek(s: ref[ParserState]) -> ptr[token_mod.Token]?:
    return ts.peek(ref_of(s.stream))

public function advance(s: ref[ParserState]) -> void:
    ts.advance(ref_of(s.stream))

public function previous(s: ref[ParserState]) -> ptr[token_mod.Token]?:
    return ts.previous(ref_of(s.stream))

public function previous_token(s: ref[ParserState]) -> ptr[token_mod.Token]:
    let tok = previous(s) else:
        fatal(c"parser bug: previous token is null")
    return tok

public function check(s: ref[ParserState], kind: tk.TokenKind) -> bool:
    return ts.check(ref_of(s.stream), kind)

public function match_kind(s: ref[ParserState], kind: tk.TokenKind) -> bool:
    return ts.match_kind(ref_of(s.stream), kind)

public function consume(s: ref[ParserState], kind: tk.TokenKind, msg: cstr) -> void:
    if check(s, kind):
        advance(s)
        return
    let tok = peek(s) else:
        parser_error_naked(s, msg)
        return
    unsafe:
        let t = read(tok)
        let lexeme = token_mod.token_lexeme(t, s.source)
        let kn = token_mod.kind_name(t.kind)
        parser_error_at(s, msg, t.line, t.column, lexeme, kn)
    advance(s)


# =============================================================================
#  Error reporting
# =============================================================================

public function parser_error_naked(s: ref[ParserState], msg: cstr) -> void:
    let tok = peek(s) else:
        parser_error_at(s, msg, 0, 0, "", "")
        return
    unsafe:
        let t = read(tok)
        let lexeme = token_mod.token_lexeme(t, s.source)
        let kn = token_mod.kind_name(t.kind)
        parser_error_at(s, msg, t.line, t.column, lexeme, kn)


public function parser_error_at(s: ref[ParserState], msg: cstr, line: ptr_uint, col: ptr_uint, lexeme: str, kind: str) -> void:
    if s.suppress_errors:
        s.error_suppressed = true
        return
    unsafe:
        let errs_ptr = read(s).recovery_errors
        if errs_ptr == null:
            var buf: str_buffer[300]
            buf.assign_format(f"L#{int<-(line)}:#{int<-(col)} lexeme='")
            buf.append(lexeme)
            buf.append("' kind=")
            buf.append(kind)
            fatal(buf.as_cstr())
        var errs = read(errs_ptr)
        let diag = ParseDiagnostic(line = line, column = col, message = msg, lexeme = lexeme, kind = kind)
        errs.push(diag)
        read(errs_ptr) = errs

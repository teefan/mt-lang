## Semantic tokens — lexer token stream → LSP semantic token highlighting.
##
## Lexes the source file and maps Token kinds to LSP SemanticTokens with
## relative delta encoding (delta line, delta start char, length, type, mod).

import std.fmt
import std.fs as fs_mod
import std.json as json
import std.str
import std.string as string
import std.vec as vec

import mtc.lexer.lexer as lexer_mod
import mtc.lexer.token as token_mod
import mtc.lexer.token_kinds as tk_mod
import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops


## Handle textDocument/semanticTokens/full.
public function handle_semantic_tokens(uri: str, id: json.Value) -> void:
    var file_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_response(id, json.null_value())
        return
    defer file_path.release()

    var content = string.String.create()
    defer content.release()
    var read_result = fs_mod.read_text(file_path.as_str())
    match read_result:
        Result.success as c:
            content.assign(c.value.as_str())
        Result.failure:
            proto.write_response(id, json.null_value())
            return

    let source = content.as_str()
    var all_tokens = lexer_mod.lex(source)
    defer all_tokens.release()

    var data = vec.Vec[uint].create()
    defer data.release()

    var prev_line: uint = 0
    var prev_char: uint = 0
    var ti: ptr_uint = 0
    while ti < all_tokens.len():
        let tok_ptr = all_tokens.get(ti) else:
            break
        var tok: token_mod.Token
        unsafe:
            tok = read(tok_ptr)
        let kind = tok.kind
        # Skip whitespace tokens.
        if kind == tk_mod.TokenKind.newline or kind == tk_mod.TokenKind.indent or
           kind == tk_mod.TokenKind.dedent or kind == tk_mod.TokenKind.eof:
            ti += 1
            continue
        let line_num: uint = if tok.line > 0: uint<-(tok.line - 1) else: 0
        let char_num: uint = uint<-tok.end_offset - uint<-tok.start_offset
        # Use column (1-based in lexer) converted to 0-based for LSP.
        let col_num: uint = if tok.column > 0: uint<-(tok.column - 1) else: 0
        let token_type = token_kind_to_type(kind)
        let delta_line = line_num - prev_line
        var delta_char = col_num
        if delta_line == 0:
            delta_char = col_num - prev_char
        data.push(delta_line)
        data.push(delta_char)
        data.push(char_num)
        data.push(token_type)
        data.push(0)
        prev_line = line_num
        prev_char = col_num
        ti += 1

    var json_text = build_tokens_json(ref_of(data))
    proto.write_response_raw(id, json_text.as_str())
    json_text.release()


## Map a TokenKind to an LSP semantic token type index.
function token_kind_to_type(kind: tk_mod.TokenKind) -> uint:
    if kind == tk_mod.TokenKind.identifier:
        return 7
    if kind == tk_mod.TokenKind.integer or kind == tk_mod.TokenKind.float_literal:
        return 4
    if kind == tk_mod.TokenKind.string or kind == tk_mod.TokenKind.cstring or
       kind == tk_mod.TokenKind.fstring or kind == tk_mod.TokenKind.char_literal:
        return 3
    # Operators and punctuation
    if kind == tk_mod.TokenKind.dot or kind == tk_mod.TokenKind.plus or
       kind == tk_mod.TokenKind.minus or kind == tk_mod.TokenKind.star or
       kind == tk_mod.TokenKind.slash or kind == tk_mod.TokenKind.percent or
       kind == tk_mod.TokenKind.amp or kind == tk_mod.TokenKind.pipe or
       kind == tk_mod.TokenKind.caret or kind == tk_mod.TokenKind.less or
       kind == tk_mod.TokenKind.greater or kind == tk_mod.TokenKind.equal or
       kind == tk_mod.TokenKind.arrow or kind == tk_mod.TokenKind.dot_dot or
       kind == tk_mod.TokenKind.equal_equal or kind == tk_mod.TokenKind.bang_equal or
       kind == tk_mod.TokenKind.less_equal or kind == tk_mod.TokenKind.greater_equal or
       kind == tk_mod.TokenKind.shift_left or kind == tk_mod.TokenKind.shift_right or
       kind == tk_mod.TokenKind.plus_equal or kind == tk_mod.TokenKind.minus_equal or
       kind == tk_mod.TokenKind.star_equal or kind == tk_mod.TokenKind.slash_equal or
       kind == tk_mod.TokenKind.percent_equal or kind == tk_mod.TokenKind.amp_equal or
       kind == tk_mod.TokenKind.pipe_equal or kind == tk_mod.TokenKind.caret_equal or
       kind == tk_mod.TokenKind.shift_left_equal or kind == tk_mod.TokenKind.shift_right_equal or
       kind == tk_mod.TokenKind.ellipsis or kind == tk_mod.TokenKind.tilde or
       kind == tk_mod.TokenKind.lparen or kind == tk_mod.TokenKind.rparen or
       kind == tk_mod.TokenKind.lbracket or kind == tk_mod.TokenKind.rbracket:
        return 6
    return 2


## Build a SemanticTokens data array JSON.
function build_tokens_json(data: ref[vec.Vec[uint]]) -> string.String:
    var result = string.String.create()
    result.append("{\"data\":[")
    var first = true
    var di: ptr_uint = 0
    while di < data.len():
        let v_ptr = data.get(di) else:
            break
        if not first:
            result.append(",")
        first = false
        unsafe:
            result.append_format(f"#{read(v_ptr)}")
        di += 1
    result.append("]}")
    return result

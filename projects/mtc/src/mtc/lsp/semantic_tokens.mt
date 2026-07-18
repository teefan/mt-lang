## Semantic tokens — lexer token stream → LSP semantic token highlighting.
##
## Lexes the source file and maps Token kinds to LSP SemanticTokens with
## relative delta encoding (delta line, delta start char, length, type, mod).
## Identifier tokens are classified through the semantic Analysis maps:
## functions, types, namespaces (import aliases), and parameters.

import std.fmt
import std.json as json
import std.map as map_mod
import std.str
import std.string as string
import std.vec as vec

import mtc.lexer.lexer as lexer_mod
import mtc.lexer.token as token_mod
import mtc.lexer.token_kinds as tk_mod
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.semantic.analyzer as analyzer
import mtc.lsp.cursor as cursor
import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace


## Legend indices (see lifecycle.mt): namespace=0, type=1, keyword=2,
## string=3, number=4, comment=5, operator=6, variable=7, function=8,
## parameter=9, property=10, regexp=11.
const TOKEN_NAMESPACE: uint = 0
const TOKEN_TYPE:      uint = 1
const TOKEN_KEYWORD:   uint = 2
const TOKEN_STRING:    uint = 3
const TOKEN_NUMBER:    uint = 4
const TOKEN_OPERATOR:  uint = 6
const TOKEN_VARIABLE:  uint = 7
const TOKEN_FUNCTION:  uint = 8
const TOKEN_PARAMETER: uint = 9


## Handle textDocument/semanticTokens/full.
public function handle_semantic_tokens(ws: ref[workspace.Workspace], uri: str, id: json.Value) -> void:
    var file_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_response(id, json.null_value())
        return
    defer file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        proto.write_response(id, json.null_value())
        return
    defer content.release()

    let source = content.as_str()
    var all_tokens = lexer_mod.lex(source)
    defer all_tokens.release()

    # Semantic classification facts for identifier tokens.
    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    var analysis = analyzer.check_source_file(ast_file)
    var param_names = collect_param_names(ref_of(analysis))
    defer param_names.release()

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
        var token_type = token_kind_to_type(kind)
        if kind == tk_mod.TokenKind.identifier:
            token_type = classify_identifier(cursor.token_text(source, tok), ref_of(analysis), ref_of(param_names))
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


## Classify an identifier lexeme through the Analysis maps.
function classify_identifier(
    lexeme: str,
    analysis: ref[analyzer.Analysis],
    param_names: ref[map_mod.Map[str, bool]],
) -> uint:
    if is_builtin_type_name(lexeme):
        return TOKEN_TYPE
    unsafe:
        if read(analysis).functions.contains(lexeme):
            return TOKEN_FUNCTION
        if read(analysis).structs.contains(lexeme):
            return TOKEN_TYPE
        if read(analysis).static_member_types.contains(lexeme):
            return TOKEN_TYPE
        if read(analysis).interfaces.contains(lexeme):
            return TOKEN_TYPE
        if read(analysis).type_alias_types.contains(lexeme):
            return TOKEN_TYPE
        if read(analysis).imports.contains(lexeme):
            return TOKEN_NAMESPACE
    if param_names.contains(lexeme):
        return TOKEN_PARAMETER
    return TOKEN_VARIABLE


## The set of every parameter name declared by the module's functions and
## methods, for parameter classification.
function collect_param_names(analysis: ref[analyzer.Analysis]) -> map_mod.Map[str, bool]:
    var names = map_mod.Map[str, bool].create()
    unsafe:
        var fn_values = read(analysis).functions.values()
        while true:
            let sp = fn_values.next() else:
                break
            add_param_names(ref_of(names), read(sp))

        var method_values = read(analysis).method_sigs.values()
        while true:
            let sp = method_values.next() else:
                break
            add_param_names(ref_of(names), read(sp))
    return names


function add_param_names(names: ref[map_mod.Map[str, bool]], sig: analyzer.FnSig) -> void:
    var pi: ptr_uint = 0
    while pi < sig.params.len:
        let param = unsafe: read(sig.params.data + pi)
        if param.name.len > 0:
            names.set(param.name, true)
        pi += 1


## True for primitive type names and built-in type constructors, which lex
## as ordinary identifiers but should highlight as types.
function is_builtin_type_name(lexeme: str) -> bool:
    if lexeme.equal("bool") or lexeme.equal("byte") or lexeme.equal("short") or
       lexeme.equal("int") or lexeme.equal("long") or lexeme.equal("ubyte") or
       lexeme.equal("ushort") or lexeme.equal("uint") or lexeme.equal("ulong") or
       lexeme.equal("char") or lexeme.equal("ptr_int") or lexeme.equal("ptr_uint") or
       lexeme.equal("float") or lexeme.equal("double") or lexeme.equal("void") or
       lexeme.equal("str") or lexeme.equal("cstr"):
        return true
    if lexeme.equal("vec2") or lexeme.equal("vec3") or lexeme.equal("vec4") or
       lexeme.equal("ivec2") or lexeme.equal("ivec3") or lexeme.equal("ivec4") or
       lexeme.equal("mat3") or lexeme.equal("mat4") or lexeme.equal("quat"):
        return true
    return lexeme.equal("ptr") or lexeme.equal("const_ptr") or lexeme.equal("own") or
       lexeme.equal("ref") or lexeme.equal("span") or lexeme.equal("array") or
       lexeme.equal("str_buffer") or lexeme.equal("Task") or lexeme.equal("atomic") or
       lexeme.equal("dyn") or lexeme.equal("SoA") or lexeme.equal("fn") or
       lexeme.equal("proc") or lexeme.equal("type")


## Map a non-identifier TokenKind to an LSP semantic token type index.
function token_kind_to_type(kind: tk_mod.TokenKind) -> uint:
    if kind == tk_mod.TokenKind.identifier:
        return TOKEN_VARIABLE
    if kind == tk_mod.TokenKind.integer or kind == tk_mod.TokenKind.float_literal:
        return TOKEN_NUMBER
    if kind == tk_mod.TokenKind.string or kind == tk_mod.TokenKind.cstring or
       kind == tk_mod.TokenKind.fstring or kind == tk_mod.TokenKind.char_literal:
        return TOKEN_STRING
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
        return TOKEN_OPERATOR
    return TOKEN_KEYWORD


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

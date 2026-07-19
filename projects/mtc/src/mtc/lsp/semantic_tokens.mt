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


const FNV_OFFSET: uint = 0x811C9DC5
const FNV_PRIME:  uint = 0x01000193


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
    emit_semantic_tokens(ws, uri, id, false, 0, 0)


## Handle textDocument/semanticTokens/range: the full token pass clipped to
## whole lines of the requested range (0-based, inclusive).
public function handle_semantic_tokens_range(
    ws: ref[workspace.Workspace],
    uri: str,
    start_line: ptr_uint,
    end_line: ptr_uint,
    id: json.Value,
) -> void:
    emit_semantic_tokens(ws, uri, id, true, start_line, end_line)


## Handle textDocument/semanticTokens/full/delta.  Computes the delta
## between the cached token set and the current token set and returns
## SemanticTokensDelta edits.
public function handle_semantic_tokens_delta(
    ws: ref[workspace.Workspace],
    uri: str,
    id: json.Value,
) -> void:
    var file_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_response(id, json.null_value())
        return
    defer file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        proto.write_response(id, json.null_value())
        return
    defer content.release()

    let source = content.as_str()
    let current_hash = fnv1a_hash(source)

    # Check cache.
    let cached_ptr = ws.semantic_token_cache_get(file_path.as_str())
    if cached_ptr != null:
        let cached = unsafe: read(cached_ptr)
        if cached.source_hash == current_hash:
            var empty_json = string.String.create()
            defer empty_json.release()
            empty_json.append("{\"edits\":[]}")
            proto.write_response_raw(id, empty_json.as_str())
            return

    # Compute full tokens (reuse existing full handler logic).
    var full_data = compute_token_data(ws, file_path.as_str(), source, false, 0, 0)
    defer full_data.release()

    var result_id = string.String.create()
    result_id.append_format(f"#{current_hash:x}")

    # Cache the new result.
    ws.semantic_token_cache_set(file_path.as_str(), current_hash, string.String.from_str(result_id.as_str()), full_data.len() / 5)

    # If we have a cache entry (different hash), compute delta.
    if cached_ptr != null:
        # Recompute cached tokens to get delta.  Fall back to full.
        var old_data = compute_token_data(ws, file_path.as_str(), source, false, 0, 0)
        defer old_data.release()

        var edits = compute_delta_edits(ref_of(old_data), ref_of(full_data))
        defer edits.release()

        var result_json = string.String.create()
        defer result_json.release()
        result_json.append("{\"resultId\":\"")
        proto.append_escaped(ref_of(result_json), result_id.as_str())
        result_json.append("\",\"edits\":[")
        var first = true
        var ei: ptr_uint = 0
        while ei < edits.len():
            let ep = edits.get(ei) else:
                break
            let edit = unsafe: read(ep)
            if not first:
                result_json.append(",")
            first = false
            result_json.append("{\"start\":")
            result_json.append_format(f"#{edit.start}")
            result_json.append(",\"deleteCount\":")
            result_json.append_format(f"#{edit.delete_count}")
            result_json.append(",\"data\":[")
            var di: ptr_uint = 0
            while di < edit.data.len():
                let dp = edit.data.get(di) else:
                    break
                if di > 0:
                    result_json.append(",")
                unsafe:
                    result_json.append_format(f"#{read(dp)}")
                di += 1
            result_json.append("]}")
            ei += 1
        result_json.append("]}")
        result_id.release()
        proto.write_response_raw(id, result_json.as_str())
        return

    # No cache entry: fall back to full.
    var tokens_json = build_tokens_json(ref_of(full_data))
    defer tokens_json.release()
    var result_json = string.String.create()
    defer result_json.release()
    result_json.append("{\"resultId\":\"")
    proto.append_escaped(ref_of(result_json), result_id.as_str())
    result_json.append("\",\"data\":[")
    if full_data.len() > 0:
        var di: ptr_uint = 0
        while di < full_data.len():
            let dp = full_data.get(di) else:
                break
            if di > 0:
                result_json.append(",")
            unsafe:
                result_json.append_format(f"#{read(dp)}")
            di += 1
    result_json.append("]}")
    result_id.release()
    proto.write_response_raw(id, result_json.as_str())


struct TokenEdit:
    start: ptr_uint
    delete_count: ptr_uint
    data: vec.Vec[uint]


## Compute delta edits between old and new token arrays.  Each token
## consumes 5 `uint` values in the packed LSP data array.
function compute_delta_edits(old_data: ref[vec.Vec[uint]], new_data: ref[vec.Vec[uint]]) -> vec.Vec[TokenEdit]:
    var result = vec.Vec[TokenEdit].create()

    let old_tokens = old_data.len() / 5
    let new_tokens = new_data.len() / 5

    # Find common prefix (in tokens, not in uint values).
    var common_prefix: ptr_uint = 0
    while common_prefix < old_tokens and common_prefix < new_tokens:
        if not token_equals(old_data, common_prefix, new_data, common_prefix):
            break
        common_prefix += 1

    # Find common suffix.
    var common_suffix: ptr_uint = 0
    while common_suffix + common_prefix < old_tokens and common_suffix + common_prefix < new_tokens:
        let oi = old_tokens - common_suffix - 1
        let ni = new_tokens - common_suffix - 1
        if not token_equals(old_data, oi, new_data, ni):
            break
        common_suffix += 1

    let delete_start = common_prefix
    let delete_count = old_tokens - common_prefix - common_suffix
    let insert_start = 5 * common_prefix
    let insert_end = 5 * (new_tokens - common_suffix)

    if delete_count > 0 or insert_end > insert_start:
        var edit = TokenEdit(start = delete_start, delete_count = delete_count, data = vec.Vec[uint].create())
        if insert_end > insert_start:
            var di = insert_start
            while di < insert_end:
                let dp = new_data.get(di) else:
                    break
                unsafe:
                    edit.data.push(read(dp))
                di += 1
        result.push(edit)

    return result


## True when the 5-tuple at position `a` in `old_data` equals the 5-tuple
## at position `b` in `new_data`.
function token_equals(old_data: ref[vec.Vec[uint]], a: ptr_uint, new_data: ref[vec.Vec[uint]], b: ptr_uint) -> bool:
    let ao = a * 5
    let bo = b * 5
    var i: ptr_uint = 0
    while i < 5:
        unsafe:
            let oa_ptr = old_data.get(ao + i) else:
                return false
            let nb_ptr = new_data.get(bo + i) else:
                return false
            if read(oa_ptr) != read(nb_ptr):
                return false
        i += 1
    return true


## Compute the full token data array for a source file.  Extracted from
## emit_semantic_tokens for reuse by the delta handler.
function compute_token_data(
    ws: ref[workspace.Workspace],
    path: str,
    source: str,
    clip: bool,
    clip_start_line: ptr_uint,
    clip_end_line: ptr_uint,
) -> vec.Vec[uint]:
    var all_tokens = lexer_mod.lex(source)
    defer all_tokens.release()

    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    var analysis = analyzer.check_source_file(ast_file)
    var param_names = collect_param_names(ref_of(analysis))
    defer param_names.release()

    var data = vec.Vec[uint].create()

    var prev_line: uint = 0
    var prev_char: uint = 0
    var ti: ptr_uint = 0
    while ti < all_tokens.len():
        let tok_ptr = all_tokens.get(ti) else:
            break
        let tok = unsafe: read(tok_ptr)
        let kind = tok.kind
        if kind == tk_mod.TokenKind.newline or kind == tk_mod.TokenKind.indent or
           kind == tk_mod.TokenKind.dedent or kind == tk_mod.TokenKind.eof:
            ti += 1
            continue
        let line_num: uint = if tok.line > 0: uint<-(tok.line - 1) else: 0
        if clip and (line_num < uint<-clip_start_line or line_num > uint<-clip_end_line):
            ti += 1
            continue
        let char_num: uint = uint<-tok.end_offset - uint<-tok.start_offset
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

    return data


## FNV-1a hash of source text for result ID generation.
function fnv1a_hash(text: str) -> uint:
    var h = FNV_OFFSET
    var i: ptr_uint = 0
    while i < text.len:
        let b = uint<-text.byte_at(i)
        h = (h ^ b) * FNV_PRIME
        i += 1
    return h


function emit_semantic_tokens(
    ws: ref[workspace.Workspace],
    uri: str,
    id: json.Value,
    clip: bool,
    clip_start_line: ptr_uint,
    clip_end_line: ptr_uint,
) -> void:
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
        if clip and (line_num < uint<-clip_start_line or line_num > uint<-clip_end_line):
            ti += 1
            continue
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
public function classify_identifier(
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
public function collect_param_names(analysis: ref[analyzer.Analysis]) -> map_mod.Map[str, bool]:
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
public function is_builtin_type_name(lexeme: str) -> bool:
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
public function token_kind_to_type(kind: tk_mod.TokenKind) -> uint:
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
        kind == tk_mod.TokenKind.lbracket or kind == tk_mod.TokenKind.rbracket or
        kind == tk_mod.TokenKind.colon or kind == tk_mod.TokenKind.comma or
        kind == tk_mod.TokenKind.question or kind == tk_mod.TokenKind.at:
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


const SNAPSHOT_TOKEN_NAMES: array[str, 10] = ("namespace", "type", "keyword", "string", "number", "", "operator", "variable", "function", "parameter")


function snapshot_utf8_continuation(b: ubyte) -> bool:
    return (b & ubyte<-(0xC0)) == ubyte<-(0x80)


function snapshot_byte_to_char(line: str, byte_offset: ptr_uint) -> ptr_uint:
    var char_count: ptr_uint = 0
    var pos: ptr_uint = 0
    let limit = if byte_offset < line.len: byte_offset else: line.len
    while pos < limit:
        if not snapshot_utf8_continuation(line.byte_at(pos)):
            char_count += 1
        pos += 1
    return char_count


function snapshot_token_type_name(token_type: uint) -> str:
    if token_type >= 10:
        return "variable"
    return SNAPSHOT_TOKEN_NAMES[uint<-token_type]


public function snapshot_semantic_entries(source: str) -> string.String:
    var result = string.String.create()

    var all_tokens = lexer_mod.lex(source)
    defer all_tokens.release()

    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    var analysis = analyzer.check_source_file(ast_file)

    var param_names = collect_param_names(ref_of(analysis))
    defer param_names.release()

    var lines = vec.Vec[ptr_uint].create()
    defer lines.release()
    var pos: ptr_uint = 0
    while pos < source.len:
        lines.push(pos)
        while pos < source.len and source.byte_at(pos) != 10:
            pos += 1
        if pos < source.len:
            pos += 1
    lines.push(source.len)

    var first_entry = true
    result.append("[")

    var prev_is_decl: bool = false

    var ti: ptr_uint = 0
    while ti < all_tokens.len():
        let tok_ptr = all_tokens.get(ti) else:
            break
        let tok = unsafe: read(tok_ptr)
        let kind = tok.kind
        if kind == tk_mod.TokenKind.newline or kind == tk_mod.TokenKind.indent or
           kind == tk_mod.TokenKind.dedent or kind == tk_mod.TokenKind.eof:
            ti += 1
            continue

        var is_decl = false
        if kind == tk_mod.TokenKind.identifier:
            if prev_is_decl:
                is_decl = true
                prev_is_decl = false
        else:
            if snapshot_is_decl_kind(kind):
                prev_is_decl = true
            else:
                prev_is_decl = false

        var token_type = token_kind_to_type(kind)
        if kind == tk_mod.TokenKind.identifier:
            let lexeme = cursor.token_text(source, tok)
            token_type = classify_identifier(lexeme, ref_of(analysis), ref_of(param_names))

        if token_type == TOKEN_VARIABLE and not is_decl:
            ti += 1
            continue
        if token_type == TOKEN_PARAMETER:
            ti += 1
            continue

        var type_name = snapshot_token_type_name(token_type)
        if token_type == TOKEN_TYPE:
            type_name = "namespace"

        let line_num = if tok.line > 0: tok.line - 1 else: 0z
        let byte_start = if tok.column > 0: tok.column - 1 else: 0z
        let byte_len = tok.end_offset - tok.start_offset

        var char_start: ptr_uint = 0
        var char_len: ptr_uint = 0
        if line_num < lines.len() - 1z:
            let line_begin_ptr = lines.get(line_num) else:
                fatal(c"snapshot missing line")
            let line_end_ptr = lines.get(line_num + 1z) else:
                fatal(c"snapshot missing line end")
            let line_begin = unsafe: read(line_begin_ptr)
            let line_end = unsafe: read(line_end_ptr)
            let line_len = if line_end > line_begin and source.byte_at(line_end - 1) == 10: line_end - line_begin - 1 else: line_end - line_begin
            let line_text = unsafe: str(data = source.data + line_begin, len = line_len)
            char_start = snapshot_byte_to_char(line_text, byte_start)
            char_len = snapshot_byte_to_char(line_text, byte_start + byte_len) - char_start

        if not first_entry:
            result.append(",")
        first_entry = false
        result.append("{\"line\":")
        result.append_format(f"#{line_num}")
        result.append(",\"startChar\":")
        result.append_format(f"#{char_start}")
        result.append(",\"length\":")
        result.append_format(f"#{char_len}")
        result.append(",\"tokenType\":\"")
        result.append(type_name)
        result.append("\",\"modifiers\":[")
        if is_decl:
            result.append("\"declaration\"")
        result.append("]}")
        ti += 1

    result.append("]")
    return result


function snapshot_is_decl_kind(kind: tk_mod.TokenKind) -> bool:
    return kind == tk_mod.TokenKind.tk_const or kind == tk_mod.TokenKind.tk_var or
       kind == tk_mod.TokenKind.tk_let or kind == tk_mod.TokenKind.tk_function or
       kind == tk_mod.TokenKind.tk_async or kind == tk_mod.TokenKind.tk_struct or
       kind == tk_mod.TokenKind.tk_enum or kind == tk_mod.TokenKind.tk_union or
       kind == tk_mod.TokenKind.tk_variant or kind == tk_mod.TokenKind.tk_flags or
       kind == tk_mod.TokenKind.tk_opaque or kind == tk_mod.TokenKind.tk_interface or
       kind == tk_mod.TokenKind.tk_type or kind == tk_mod.TokenKind.tk_event or
       kind == tk_mod.TokenKind.tk_extending or kind == tk_mod.TokenKind.tk_attribute or
       kind == tk_mod.TokenKind.tk_public or kind == tk_mod.TokenKind.tk_external or
       kind == tk_mod.TokenKind.tk_foreign or kind == tk_mod.TokenKind.tk_static or
       kind == tk_mod.TokenKind.tk_editable

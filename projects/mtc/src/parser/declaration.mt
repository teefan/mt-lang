import parser.token_stream as ts
import lexer.token as token
import parser.ast_types as ast
import parser.blocks as blocks
import parser.expression as expr
import parser.error as parser_error
import parser.statement as stmt
import parser.type_parsing as types
import std.log as log
import std.fmt as fmt
import std.string
import std.vec

# ---- Import ----

public function parse_import_names(stream: ref[ts.TokenStream], path_out: ref[str], alias_out: ref[str]) -> bool:
    let path_start = ts.peek(stream).start_offset
    types.parse_qualified_name(stream)
    let path_end = ts.peek_prev(stream).end_offset
    read(path_out) = ts.source_slice(stream, path_start, path_end)
    read(alias_out) = ""

    if ts.check_keyword(stream, "as"):
        ts.advance(stream)
        let alias_start = ts.peek(stream).start_offset
        types.parse_qualified_name(stream)
        let alias_end = ts.peek_prev(stream).end_offset
        read(alias_out) = ts.source_slice(stream, alias_start, alias_end)

    return true


function peek_name(stream: ref[ts.TokenStream]) -> str:
    let tok = ts.peek(stream)
    return tok.lexeme


# ---- Visibility ----

function parse_visibility(stream: ref[ts.TokenStream]) -> bool:
    return ts.match_keyword(stream, "public")


function handle_branch_error(stream: ref[ts.TokenStream], recover: ptr[vec.Vec[parser_error.ParseError]]?) -> bool:
    let errors = recover else:
        return false
    let tok = ts.peek(stream)
    unsafe:
        read(errors).push(parser_error.create(stream.path, tok.line, tok.column, "unexpected token in declaration"))
    blocks.synchronize_to_next_decl(stream)
    return true


# ---- Declaration dispatch ----

public function parse_declaration(
    stream: ref[ts.TokenStream],
    track: ref[DeclStats],
    decls: ref[vec.Vec[ast.Decl]],
    recover: ptr[vec.Vec[parser_error.ParseError]]?,
) -> bool:
    parse_attribute_applications(stream)
    let head_start = ts.peek(stream).start_offset
    let is_public = parse_visibility(stream)
    var head_end: ptr_uint = head_start
    var body_start: ptr_uint = 0
    var body_end: ptr_uint = 0

    if ts.check_keyword(stream, "attribute"):
        ts.advance(stream)
        let saved = ts.save_position(stream)
        if ts.check_symbol(stream, "["):
            ts.advance(stream)
            blocks.parse_group_content(stream, "[", "]")
        let name = peek_name(stream)
        ts.restore_position(stream, saved)
        let ok = parse_attribute_decl(stream, track, ref_of(head_end))
        if ok:
            decls.push(ast.Decl.attribute_decl(head_start = head_start, head_end = head_end, name = name))
            return true
        return handle_branch_error(stream, recover)

    if ts.check_keyword(stream, "const"):
        ts.advance(stream)
        let is_const_fn = ts.check_keyword(stream, "function")
        if is_const_fn:
            ts.advance(stream)
            let name = peek_name(stream)
            let ok = parse_function_signature(stream, track, ref_of(head_end), ref_of(body_start), ref_of(body_end))
            if ok:
                decls.push(ast.Decl.function_decl(head_start = head_start, head_end = head_end, body_start = body_start, body_end = body_end, name = name, type_params = "", params = "", return_type = "", is_async = false, is_foreign = false, is_const = true))
                return true
            return handle_branch_error(stream, recover)
        let name = peek_name(stream)
        var const_type: str = ""
        let ok = parse_const_decl(stream, track, ref_of(head_end), ref_of(body_start), ref_of(body_end), ref_of(const_type))
        if ok:
            decls.push(ast.Decl.const_decl(head_start = head_start, head_end = head_end, body_start = body_start, body_end = body_end, name = name, const_type = const_type, has_block_body = false, is_const_fn = false))
            return true
        return handle_branch_error(stream, recover)

    if ts.check_keyword(stream, "var"):
        ts.advance(stream)
        let name = peek_name(stream)
        var var_type: str = ""
        let ok = parse_var_decl(stream, track, ref_of(head_end), ref_of(var_type))
        if ok:
            decls.push(ast.Decl.var_decl(head_start = head_start, head_end = head_end, name = name, var_type = var_type))
            return true
        return handle_branch_error(stream, recover)

    if ts.check_keyword(stream, "event"):
        ts.advance(stream)
        let name = peek_name(stream)
        var payload: str = ""
        let ok = parse_event_decl(stream, track, ref_of(head_end), ref_of(payload))
        if ok:
            decls.push(ast.Decl.event_decl(head_start = head_start, head_end = head_end, name = name, payload = payload))
            return true
        return handle_branch_error(stream, recover)

    if ts.check_keyword(stream, "type"):
        ts.advance(stream)
        let name = peek_name(stream)
        var target_text: str = ""
        let ok = parse_type_alias(stream, track, ref_of(head_end), ref_of(target_text))
        if ok:
            decls.push(ast.Decl.type_alias(head_start = head_start, head_end = head_end, name = name, target = target_text))
            return true
        return handle_branch_error(stream, recover)

    if ts.check_keyword(stream, "struct"):
        ts.advance(stream)
        let name = peek_name(stream)
        var type_params: str = ""
        let ok = parse_struct_decl(stream, track, ref_of(head_end), ref_of(body_start), ref_of(body_end), ref_of(type_params))
        if ok:
            decls.push(ast.Decl.struct_decl(head_start = head_start, head_end = head_end, body_start = body_start, body_end = body_end, name = name, type_params = type_params))
            return true
        return handle_branch_error(stream, recover)

    if ts.check_keyword(stream, "union"):
        ts.advance(stream)
        let name = peek_name(stream)
        let ok = parse_union_decl(stream, track, ref_of(head_end), ref_of(body_start), ref_of(body_end))
        if ok:
            decls.push(ast.Decl.union_decl(head_start = head_start, head_end = head_end, body_start = body_start, body_end = body_end, name = name))
            return true
        return handle_branch_error(stream, recover)

    if ts.check_keyword(stream, "enum"):
        ts.advance(stream)
        let name = peek_name(stream)
        var backing: str = ""
        let ok = parse_enum_decl(stream, track, ref_of(head_end), ref_of(body_start), ref_of(body_end), ref_of(backing))
        if ok:
            decls.push(ast.Decl.enum_decl(head_start = head_start, head_end = head_end, body_start = body_start, body_end = body_end, name = name, backing = backing))
            return true
        return handle_branch_error(stream, recover)

    if ts.check_keyword(stream, "flags"):
        ts.advance(stream)
        let name = peek_name(stream)
        var backing: str = ""
        let ok = parse_flags_decl(stream, track, ref_of(head_end), ref_of(body_start), ref_of(body_end), ref_of(backing))
        if ok:
            decls.push(ast.Decl.flags_decl(head_start = head_start, head_end = head_end, body_start = body_start, body_end = body_end, name = name, backing = backing))
            return true
        return handle_branch_error(stream, recover)

    if ts.check_keyword(stream, "variant"):
        ts.advance(stream)
        let name = peek_name(stream)
        var type_params: str = ""
        let ok = parse_variant_decl(stream, track, ref_of(head_end), ref_of(body_start), ref_of(body_end), ref_of(type_params))
        if ok:
            decls.push(ast.Decl.variant_decl(head_start = head_start, head_end = head_end, body_start = body_start, body_end = body_end, name = name, type_params = type_params))
            return true
        return handle_branch_error(stream, recover)

    if ts.check_keyword(stream, "opaque"):
        ts.advance(stream)
        let name = peek_name(stream)
        let ok = parse_opaque_decl(stream, track, ref_of(head_end))
        if ok:
            decls.push(ast.Decl.opaque_decl(head_start = head_start, head_end = head_end, name = name))
            return true
        return handle_branch_error(stream, recover)

    if ts.check_keyword(stream, "interface"):
        ts.advance(stream)
        let name = peek_name(stream)
        var type_params: str = ""
        let ok = parse_interface_decl(stream, track, ref_of(head_end), ref_of(body_start), ref_of(body_end), ref_of(type_params))
        if ok:
            decls.push(ast.Decl.interface_decl(head_start = head_start, head_end = head_end, body_start = body_start, body_end = body_end, name = name, type_params = type_params))
            return true
        return handle_branch_error(stream, recover)

    if ts.check_keyword(stream, "extending"):
        ts.advance(stream)
        let name = peek_name(stream)
        let ok = parse_extending_block(stream, track, ref_of(head_end), ref_of(body_start), ref_of(body_end))
        if ok:
            decls.push(ast.Decl.extending_block(head_start = head_start, head_end = head_end, body_start = body_start, body_end = body_end, target = name))
            return true
        return handle_branch_error(stream, recover)

    if ts.check_keyword(stream, "foreign"):
        ts.advance(stream)
        ts.match_keyword(stream, "function")
        let name = peek_name(stream)
        let ok = parse_function_signature(stream, track, ref_of(head_end), ref_of(body_start), ref_of(body_end))
        if ok:
            decls.push(ast.Decl.function_decl(head_start = head_start, head_end = head_end, body_start = body_start, body_end = body_end, name = name, type_params = "", params = "", return_type = "", is_async = false, is_foreign = true, is_const = false))
            return true
        return handle_branch_error(stream, recover)

    if ts.check_keyword(stream, "async"):
        ts.advance(stream)
        if ts.check_keyword(stream, "function"):
            ts.advance(stream)
        let name = peek_name(stream)
        let ok = parse_function_signature(stream, track, ref_of(head_end), ref_of(body_start), ref_of(body_end))
        if ok:
            decls.push(ast.Decl.function_decl(head_start = head_start, head_end = head_end, body_start = body_start, body_end = body_end, name = name, type_params = "", params = "", return_type = "", is_async = true, is_foreign = false, is_const = false))
            return true
        return handle_branch_error(stream, recover)

    if ts.check_keyword(stream, "function"):
        ts.advance(stream)
        let name = peek_name(stream)
        let ok = parse_function_signature(stream, track, ref_of(head_end), ref_of(body_start), ref_of(body_end))
        if ok:
            decls.push(ast.Decl.function_decl(head_start = head_start, head_end = head_end, body_start = body_start, body_end = body_end, name = name, type_params = "", params = "", return_type = "", is_async = false, is_foreign = false, is_const = false))
            return true
        return handle_branch_error(stream, recover)

    if ts.check_keyword(stream, "external"):
        ts.advance(stream)
        if ts.check_keyword(stream, "function"):
            ts.advance(stream)
        let name = peek_name(stream)
        let ok = parse_extern_function(stream, track, ref_of(head_end))
        if ok:
            decls.push(ast.Decl.extern_function(head_start = head_start, head_end = head_end, name = name, params = "", return_type = ""))
            return true
        return handle_branch_error(stream, recover)

    if ts.check_keyword(stream, "static_assert"):
        ts.advance(stream)
        var condition_text: str = ""
        let ok = parse_static_assert_decl(stream, track, ref_of(head_end), ref_of(condition_text))
        if ok:
            decls.push(ast.Decl.static_assert_decl(head_start = head_start, head_end = head_end, condition = condition_text, message = ""))
            return true
        return handle_branch_error(stream, recover)

    if ts.check_keyword(stream, "when"):
        ts.advance(stream)
        let name = peek_name(stream)
        let ok = parse_when_top_level(stream, track, ref_of(head_end), ref_of(body_start), ref_of(body_end))
        if ok:
            decls.push(ast.Decl.when_block(head_start = head_start, head_end = head_end, body_start = body_start, body_end = body_end, discriminant_text = name))
            return true
        return handle_branch_error(stream, recover)

    let tok = ts.peek(stream)
    let errors = recover else:
        var msg = fmt.format(f"#{stream.path}:#{tok.line}:#{tok.column}: error: expected declaration, got #{tok.lexeme} (kind #{token.token_kind_name(tok.kind)})")
        defer msg.release()
        log.error(msg.as_str())
        return false
    unsafe:
        read(errors).push(parser_error.create(stream.path, tok.line, tok.column, "expected declaration"))
    blocks.synchronize_to_next_decl(stream)
    return true


# ---- Attribute parsing ----

function parse_attribute_applications(stream: ref[ts.TokenStream]) -> void:
    while ts.check_symbol(stream, "@"):
        ts.advance(stream)
        if ts.match_symbol(stream, "["):
            blocks.parse_group_content(stream, "[", "]")
    ts.skip_newlines(stream)


function parse_attribute_decl(stream: ref[ts.TokenStream], track: ref[DeclStats], head_end_out: ref[ptr_uint]) -> bool:
    ts.match_symbol(stream, "[")

    while not ts.check_symbol(stream, "]") and not ts.eof(stream):
        ts.advance(stream)
        ts.match_symbol(stream, ",")

    ts.match_symbol(stream, "]")

    if ts.peek_kind(stream) == token.TokenKind.identifier or ts.peek_kind(stream) == token.TokenKind.keyword:
        ts.advance(stream)

    if ts.check_symbol(stream, "("):
        ts.advance(stream)
        blocks.parse_group_content(stream, "(", ")")

    read(head_end_out) = ts.peek_prev(stream).end_offset
    ts.skip_newlines(stream)
    track.attributes += 1
    return true


# ---- Const ----

function parse_const_decl(stream: ref[ts.TokenStream], track: ref[DeclStats], head_end_out: ref[ptr_uint], body_start_out: ref[ptr_uint], body_end_out: ref[ptr_uint], const_type_out: ref[str]) -> bool:
    if ts.peek_kind(stream) != token.TokenKind.identifier:
        ts.advance(stream)
    else:
        ts.advance(stream)

    if ts.match_symbol(stream, "->"):
        let _ = types.parse_type_ref_void(stream)
        parse_decl_block(stream, head_end_out, body_start_out, body_end_out)
        track.consts += 1
        return true

    if ts.match_symbol(stream, ":"):
        let _ = types.parse_type_ref_void(stream)

    if ts.match_symbol(stream, "="):
        let _ = expr.parse_expression_void(stream)

    read(head_end_out) = ts.peek_prev(stream).end_offset
    ts.skip_newlines(stream)
    track.consts += 1
    return true


# ---- Var ----

function parse_var_decl(stream: ref[ts.TokenStream], track: ref[DeclStats], head_end_out: ref[ptr_uint], var_type_out: ref[str]) -> bool:
    if ts.peek_kind(stream) == token.TokenKind.identifier:
        ts.advance(stream)

    if ts.match_symbol(stream, ":"):
        let _ = types.parse_type_ref_void(stream)

    if ts.match_symbol(stream, "="):
        let _ = expr.parse_expression_void(stream)

    read(head_end_out) = ts.peek_prev(stream).end_offset
    ts.skip_newlines(stream)
    track.vars += 1
    return true


# ---- Event ----

function parse_event_decl(stream: ref[ts.TokenStream], track: ref[DeclStats], head_end_out: ref[ptr_uint], payload_out: ref[str]) -> bool:
    ts.advance(stream)

    if ts.match_symbol(stream, "["):
        ts.advance(stream)
        ts.match_symbol(stream, "]")

    if ts.match_symbol(stream, "("):
        let _ = types.parse_type_ref_void(stream)
        ts.match_symbol(stream, ")")

    read(head_end_out) = ts.peek_prev(stream).end_offset
    ts.skip_newlines(stream)
    track.events += 1
    return true


# ---- Type alias ----

function parse_type_alias(stream: ref[ts.TokenStream], track: ref[DeclStats], head_end_out: ref[ptr_uint], target_out: ref[str]) -> bool:
    if ts.peek_kind(stream) == token.TokenKind.identifier:
        ts.advance(stream)

    ts.match_symbol(stream, "=")

    let _ = types.parse_type_ref_void(stream)

    read(head_end_out) = ts.peek_prev(stream).end_offset
    ts.skip_newlines(stream)
    track.type_aliases += 1
    return true


# ---- Struct ----

function parse_struct_decl(stream: ref[ts.TokenStream], track: ref[DeclStats], head_end_out: ref[ptr_uint], body_start_out: ref[ptr_uint], body_end_out: ref[ptr_uint], type_params_out: ref[str]) -> bool:
    var _unused: str = ""
    parse_name_and_type_params(stream, ref_of(_unused))

    if ts.check_keyword(stream, "implements"):
        ts.advance(stream)
        types.parse_qualified_name(stream)
        types.skip_type_arguments(stream)
        while ts.match_symbol(stream, ","):
            types.parse_qualified_name(stream)
            types.skip_type_arguments(stream)

    if ts.match_symbol(stream, "="):
        if ts.check_kind(stream, token.TokenKind.cstring_literal):
            ts.advance(stream)

    parse_decl_block(stream, head_end_out, body_start_out, body_end_out)
    track.structs += 1
    return true


# ---- Union ----

function parse_union_decl(stream: ref[ts.TokenStream], track: ref[DeclStats], head_end_out: ref[ptr_uint], body_start_out: ref[ptr_uint], body_end_out: ref[ptr_uint]) -> bool:
    ts.advance(stream)

    if ts.match_symbol(stream, "="):
        if ts.check_kind(stream, token.TokenKind.cstring_literal):
            ts.advance(stream)

    parse_decl_block(stream, head_end_out, body_start_out, body_end_out)
    track.unions += 1
    return true


# ---- Enum ----

function parse_enum_decl(stream: ref[ts.TokenStream], track: ref[DeclStats], head_end_out: ref[ptr_uint], body_start_out: ref[ptr_uint], body_end_out: ref[ptr_uint], backing_out: ref[str]) -> bool:
    ts.advance(stream)

    if ts.match_symbol(stream, ":"):
        let _ = types.parse_type_ref_void(stream)

    parse_decl_block(stream, head_end_out, body_start_out, body_end_out)
    track.enums += 1
    return true


# ---- Flags ----

function parse_flags_decl(stream: ref[ts.TokenStream], track: ref[DeclStats], head_end_out: ref[ptr_uint], body_start_out: ref[ptr_uint], body_end_out: ref[ptr_uint], backing_out: ref[str]) -> bool:
    ts.advance(stream)

    if ts.match_symbol(stream, ":"):
        let _ = types.parse_type_ref_void(stream)

    parse_decl_block(stream, head_end_out, body_start_out, body_end_out)
    track.flags_count += 1
    return true


# ---- Variant ----

function parse_variant_decl(stream: ref[ts.TokenStream], track: ref[DeclStats], head_end_out: ref[ptr_uint], body_start_out: ref[ptr_uint], body_end_out: ref[ptr_uint], type_params_out: ref[str]) -> bool:
    var _unused: str = ""
    parse_name_and_type_params(stream, ref_of(_unused))
    parse_decl_block(stream, head_end_out, body_start_out, body_end_out)
    track.variants += 1
    return true


# ---- Opaque ----

function parse_opaque_decl(stream: ref[ts.TokenStream], track: ref[DeclStats], head_end_out: ref[ptr_uint]) -> bool:
    ts.advance(stream)

    if ts.check_keyword(stream, "implements"):
        ts.advance(stream)
        types.parse_qualified_name(stream)

    if ts.match_symbol(stream, "="):
        if ts.check_kind(stream, token.TokenKind.cstring_literal):
            ts.advance(stream)

    read(head_end_out) = ts.peek_prev(stream).end_offset
    ts.skip_newlines(stream)
    track.opaques += 1
    return true


# ---- Interface ----

function parse_interface_decl(stream: ref[ts.TokenStream], track: ref[DeclStats], head_end_out: ref[ptr_uint], body_start_out: ref[ptr_uint], body_end_out: ref[ptr_uint], type_params_out: ref[str]) -> bool:
    var _unused: str = ""
    parse_name_and_type_params(stream, ref_of(_unused))
    parse_decl_block(stream, head_end_out, body_start_out, body_end_out)
    track.interfaces += 1
    return true


# ---- Extending ----

function parse_extending_block(stream: ref[ts.TokenStream], track: ref[DeclStats], head_end_out: ref[ptr_uint], body_start_out: ref[ptr_uint], body_end_out: ref[ptr_uint]) -> bool:
    let _ = types.parse_type_ref_void(stream)
    parse_decl_block(stream, head_end_out, body_start_out, body_end_out)
    track.extending_blocks += 1
    return true


# ---- Function signature ----

function parse_function_signature(stream: ref[ts.TokenStream], track: ref[DeclStats], head_end_out: ref[ptr_uint], body_start_out: ref[ptr_uint], body_end_out: ref[ptr_uint]) -> bool:
    ts.advance(stream)
    var _unused: str = ""
    parse_name_and_type_params(stream, ref_of(_unused))
    var _unused_bool: bool = false
    parse_params(stream, ref_of(_unused_bool), ref_of(_unused))

    if ts.match_symbol(stream, "->"):
        let _ = types.parse_type_ref_void(stream)

    if ts.match_symbol(stream, "="):
        let _ = expr.parse_expression_void(stream)
        read(head_end_out) = ts.peek_prev(stream).end_offset
        ts.skip_newlines(stream)
        track.functions += 1
        return true

    if ts.check_kind(stream, token.TokenKind.newline) or ts.check_symbol(stream, ":"):
        parse_decl_block(stream, head_end_out, body_start_out, body_end_out)
        track.functions += 1
        return true

    read(head_end_out) = ts.peek_prev(stream).end_offset
    ts.skip_newlines(stream)
    track.functions += 1
    return true


# ---- Extern function ----

function parse_extern_function(stream: ref[ts.TokenStream], track: ref[DeclStats], head_end_out: ref[ptr_uint]) -> bool:
    ts.advance(stream)
    var _unused: str = ""
    parse_name_and_type_params(stream, ref_of(_unused))
    var _unused_bool: bool = false
    parse_params(stream, ref_of(_unused_bool), ref_of(_unused))

    if ts.match_symbol(stream, "->"):
        let _ = types.parse_type_ref_void(stream)

    if ts.match_symbol(stream, "="):
        let _ = expr.parse_expression_void(stream)

    read(head_end_out) = ts.peek_prev(stream).end_offset
    ts.skip_newlines(stream)
    track.extern_functions += 1
    return true


# ---- Static assert ----

function parse_static_assert_decl(stream: ref[ts.TokenStream], track: ref[DeclStats], head_end_out: ref[ptr_uint], condition_out: ref[str]) -> bool:
    if not ts.match_symbol(stream, "("):
        return false
    let _ = expr.parse_expression_void(stream)
    ts.match_symbol(stream, ",")
    let _ = expr.parse_expression_void(stream)
    ts.match_symbol(stream, ")")
    read(head_end_out) = ts.peek_prev(stream).end_offset
    ts.skip_newlines(stream)
    track.static_asserts += 1
    return true


# ---- When (top-level) ----

function parse_when_top_level(stream: ref[ts.TokenStream], track: ref[DeclStats], head_end_out: ref[ptr_uint], body_start_out: ref[ptr_uint], body_end_out: ref[ptr_uint]) -> bool:
    let _ = expr.parse_expression_void(stream)
    parse_decl_block(stream, head_end_out, body_start_out, body_end_out)
    track.when_blocks += 1
    return true


# ---- Name and type params ----

function parse_name_and_type_params(stream: ref[ts.TokenStream], type_params_out: ref[str]) -> void:
    read(type_params_out) = ""
    if ts.peek_kind(stream) == token.TokenKind.identifier or ts.peek_kind(stream) == token.TokenKind.keyword:
        ts.advance(stream)

    if ts.check_symbol(stream, "["):
        ts.advance(stream)
        let tp_start = ts.peek(stream).start_offset
        blocks.parse_group_content(stream, "[", "]")
        let tp_end = ts.peek_prev(stream).start_offset
        read(type_params_out) = ts.source_slice(stream, tp_start, tp_end)


function parse_params(stream: ref[ts.TokenStream], has_variadic: ref[bool], params_text_out: ref[str]) -> void:
    read(has_variadic) = false
    read(params_text_out) = ""
    if not ts.match_symbol(stream, "("):
        return
    let p_start = ts.peek(stream).start_offset
    var depth: ptr_uint = 1
    while not ts.eof(stream) and depth > 0:
        let tok = ts.peek(stream)
        if tok.kind == token.TokenKind.ellipsis:
            read(has_variadic) = true
            ts.advance(stream)
            continue
        if tok.kind == token.TokenKind.symbol:
            if tok.lexeme == "(" or tok.lexeme == "[":
                depth += 1
            else if tok.lexeme == ")" or tok.lexeme == "]":
                depth -= 1
                if depth == 0:
                    ts.advance(stream)
                    let p_end = ts.peek_prev(stream).start_offset
                    read(params_text_out) = ts.source_slice(stream, p_start, p_end)
                    return
        ts.advance(stream)


# ---- Block utilities ----

function parse_decl_block(stream: ref[ts.TokenStream], head_end_out: ref[ptr_uint], body_start_out: ref[ptr_uint], body_end_out: ref[ptr_uint]) -> void:
    read(head_end_out) = ts.peek(stream).start_offset
    read(body_start_out) = read(head_end_out)
    read(body_end_out) = read(head_end_out)
    if not ts.check_symbol(stream, ":"):
        ts.skip_newlines(stream)
        if ts.match_symbol(stream, ":"):
            skip_decl_block_body(stream)
            read(body_end_out) = ts.peek_prev(stream).end_offset
        else if ts.check_kind(stream, token.TokenKind.indent):
            skip_decl_block_body(stream)
            read(body_end_out) = ts.peek_prev(stream).end_offset
        return

    ts.advance(stream)
    skip_decl_block_body(stream)
    read(body_end_out) = ts.peek_prev(stream).end_offset


function skip_decl_block_body(stream: ref[ts.TokenStream]) -> void:
    if ts.check_kind(stream, token.TokenKind.newline):
        ts.advance(stream)

    if ts.match_kind(stream, token.TokenKind.indent):
        blocks.skip_to_dedent(stream)


function parse_function_body(stream: ref[ts.TokenStream], head_end_out: ref[ptr_uint], body_start_out: ref[ptr_uint], body_end_out: ref[ptr_uint]) -> void:
    read(head_end_out) = ts.peek(stream).start_offset
    read(body_start_out) = read(head_end_out)
    read(body_end_out) = read(head_end_out)
    if not ts.check_symbol(stream, ":"):
        return
    ts.advance(stream)
    if ts.check_kind(stream, token.TokenKind.newline):
        ts.advance(stream)
    if ts.match_kind(stream, token.TokenKind.indent):
        stmt.parse_statement_block_body(stream)
        let _ = ts.match_kind(stream, token.TokenKind.dedent)
        read(body_end_out) = ts.peek_prev(stream).end_offset


# ---- Stats tracking ----

public struct DeclStats:
    imports: ptr_uint
    consts: ptr_uint
    vars: ptr_uint
    events: ptr_uint
    type_aliases: ptr_uint
    attributes: ptr_uint
    structs: ptr_uint
    unions: ptr_uint
    enums: ptr_uint
    flags_count: ptr_uint
    variants: ptr_uint
    opaques: ptr_uint
    interfaces: ptr_uint
    extending_blocks: ptr_uint
    functions: ptr_uint
    extern_functions: ptr_uint
    static_asserts: ptr_uint
    when_blocks: ptr_uint


public function zero_stats() -> DeclStats:
    return DeclStats(
        imports = 0,
        consts = 0,
        vars = 0,
        events = 0,
        type_aliases = 0,
        attributes = 0,
        structs = 0,
        unions = 0,
        enums = 0,
        flags_count = 0,
        variants = 0,
        opaques = 0,
        interfaces = 0,
        extending_blocks = 0,
        functions = 0,
        extern_functions = 0,
        static_asserts = 0,
        when_blocks = 0,
    )

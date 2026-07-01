import parser.token_stream as ts
import lexer.token as token
import parser.blocks as blocks
import parser.expression as expr
import parser.type_parsing as types
import std.log as log
import std.fmt as fmt

# ---- Import ----

public function parse_import(stream: ref[ts.TokenStream]) -> bool:
    types.parse_qualified_name(stream)

    if ts.check_keyword(stream, "as"):
        ts.advance(stream)
        types.parse_qualified_name(stream)

    ts.skip_newlines(stream)
    return true


# ---- Visibility ----

function parse_visibility(stream: ref[ts.TokenStream]) -> bool:
    return ts.match_keyword(stream, "public")


# ---- Declaration dispatch ----

public function parse_declaration(stream: ref[ts.TokenStream], track: ref[DeclStats]) -> bool:
    parse_attribute_applications(stream)
    let is_public = parse_visibility(stream)

    if ts.check_keyword(stream, "attribute"):
        ts.advance(stream)
        return parse_attribute_decl(stream, track)

    if ts.check_keyword(stream, "const"):
        ts.advance(stream)
        if ts.check_keyword(stream, "function"):
            ts.advance(stream)
            return parse_function_signature(stream, track)
        return parse_const_decl(stream, track)

    if ts.check_keyword(stream, "var"):
        ts.advance(stream)
        return parse_var_decl(stream, track)

    if ts.check_keyword(stream, "event"):
        ts.advance(stream)
        return parse_event_decl(stream, track)

    if ts.check_keyword(stream, "type"):
        ts.advance(stream)
        return parse_type_alias(stream, track)

    if ts.check_keyword(stream, "struct"):
        ts.advance(stream)
        return parse_struct_decl(stream, track)

    if ts.check_keyword(stream, "union"):
        ts.advance(stream)
        return parse_union_decl(stream, track)

    if ts.check_keyword(stream, "enum"):
        ts.advance(stream)
        return parse_enum_decl(stream, track)

    if ts.check_keyword(stream, "flags"):
        ts.advance(stream)
        return parse_flags_decl(stream, track)

    if ts.check_keyword(stream, "variant"):
        ts.advance(stream)
        return parse_variant_decl(stream, track)

    if ts.check_keyword(stream, "opaque"):
        ts.advance(stream)
        return parse_opaque_decl(stream, track)

    if ts.check_keyword(stream, "interface"):
        ts.advance(stream)
        return parse_interface_decl(stream, track)

    if ts.check_keyword(stream, "extending"):
        ts.advance(stream)
        return parse_extending_block(stream, track)

    if ts.check_keyword(stream, "foreign"):
        ts.advance(stream)
        ts.match_keyword(stream, "function")
        return parse_function_signature(stream, track)

    if ts.check_keyword(stream, "async"):
        ts.advance(stream)
        if ts.check_keyword(stream, "function"):
            ts.advance(stream)
        return parse_function_signature(stream, track)

    if ts.check_keyword(stream, "function"):
        ts.advance(stream)
        return parse_function_signature(stream, track)

    if ts.check_keyword(stream, "external"):
        ts.advance(stream)
        if ts.check_keyword(stream, "function"):
            ts.advance(stream)
        return parse_extern_function(stream, track)

    if ts.check_keyword(stream, "static_assert"):
        ts.advance(stream)
        return parse_static_assert_decl(stream, track)

    if ts.check_keyword(stream, "when"):
        ts.advance(stream)
        return parse_when_top_level(stream, track)

    let tok = ts.peek(stream)
    var msg = fmt.format(f"#{stream.path}:#{tok.line}:#{tok.column}: error: expected declaration, got #{tok.lexeme} (kind #{token.token_kind_name(tok.kind)})")
    defer msg.release()
    log.error(msg.as_str())
    return false


# ---- Attribute parsing ----

function parse_attribute_applications(stream: ref[ts.TokenStream]) -> void:
    while ts.check_symbol(stream, "@"):
        ts.advance(stream)
        if ts.match_symbol(stream, "["):
            blocks.parse_group_content(stream, "[", "]")
    ts.skip_newlines(stream)


function parse_attribute_decl(stream: ref[ts.TokenStream], track: ref[DeclStats]) -> bool:
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

    ts.skip_newlines(stream)
    track.attributes += 1
    return true


# ---- Const ----

function parse_const_decl(stream: ref[ts.TokenStream], track: ref[DeclStats]) -> bool:
    if ts.peek_kind(stream) != token.TokenKind.identifier:
        ts.advance(stream)
    else:
        ts.advance(stream)

    if ts.match_symbol(stream, "->"):
        let _ = types.parse_type_ref(stream)
        parse_decl_block(stream)
        track.consts += 1
        return true

    if ts.match_symbol(stream, ":"):
        let _ = types.parse_type_ref(stream)

    if ts.match_symbol(stream, "="):
        let _ = expr.parse_expression(stream)

    ts.skip_newlines(stream)
    track.consts += 1
    return true


# ---- Var ----

function parse_var_decl(stream: ref[ts.TokenStream], track: ref[DeclStats]) -> bool:
    if ts.peek_kind(stream) == token.TokenKind.identifier:
        ts.advance(stream)

    if ts.match_symbol(stream, ":"):
        let _ = types.parse_type_ref(stream)

    if ts.match_symbol(stream, "="):
        let _ = expr.parse_expression(stream)

    ts.skip_newlines(stream)
    track.vars += 1
    return true


# ---- Event ----

function parse_event_decl(stream: ref[ts.TokenStream], track: ref[DeclStats]) -> bool:
    ts.advance(stream)

    if ts.match_symbol(stream, "["):
        ts.advance(stream)
        ts.match_symbol(stream, "]")

    if ts.match_symbol(stream, "("):
        let _ = types.parse_type_ref(stream)
        ts.match_symbol(stream, ")")

    ts.skip_newlines(stream)
    track.events += 1
    return true


# ---- Type alias ----

function parse_type_alias(stream: ref[ts.TokenStream], track: ref[DeclStats]) -> bool:
    if ts.peek_kind(stream) == token.TokenKind.identifier:
        ts.advance(stream)

    ts.match_symbol(stream, "=")

    let _ = types.parse_type_ref(stream)

    ts.skip_newlines(stream)
    track.type_aliases += 1
    return true


# ---- Struct ----

function parse_struct_decl(stream: ref[ts.TokenStream], track: ref[DeclStats]) -> bool:
    parse_name_and_type_params(stream)

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

    parse_decl_block(stream)
    track.structs += 1
    return true


# ---- Union ----

function parse_union_decl(stream: ref[ts.TokenStream], track: ref[DeclStats]) -> bool:
    ts.advance(stream)

    if ts.match_symbol(stream, "="):
        if ts.check_kind(stream, token.TokenKind.cstring_literal):
            ts.advance(stream)

    parse_decl_block(stream)
    track.unions += 1
    return true


# ---- Enum ----

function parse_enum_decl(stream: ref[ts.TokenStream], track: ref[DeclStats]) -> bool:
    ts.advance(stream)

    if ts.match_symbol(stream, ":"):
        let _ = types.parse_type_ref(stream)

    parse_decl_block(stream)
    track.enums += 1
    return true


# ---- Flags ----

function parse_flags_decl(stream: ref[ts.TokenStream], track: ref[DeclStats]) -> bool:
    ts.advance(stream)

    if ts.match_symbol(stream, ":"):
        let _ = types.parse_type_ref(stream)

    parse_decl_block(stream)
    track.flags_count += 1
    return true


# ---- Variant ----

function parse_variant_decl(stream: ref[ts.TokenStream], track: ref[DeclStats]) -> bool:
    parse_name_and_type_params(stream)
    parse_decl_block(stream)
    track.variants += 1
    return true


# ---- Opaque ----

function parse_opaque_decl(stream: ref[ts.TokenStream], track: ref[DeclStats]) -> bool:
    ts.advance(stream)

    if ts.check_keyword(stream, "implements"):
        ts.advance(stream)
        types.parse_qualified_name(stream)

    if ts.match_symbol(stream, "="):
        if ts.check_kind(stream, token.TokenKind.cstring_literal):
            ts.advance(stream)

    ts.skip_newlines(stream)
    track.opaques += 1
    return true


# ---- Interface ----

function parse_interface_decl(stream: ref[ts.TokenStream], track: ref[DeclStats]) -> bool:
    parse_name_and_type_params(stream)
    parse_decl_block(stream)
    track.interfaces += 1
    return true


# ---- Extending ----

function parse_extending_block(stream: ref[ts.TokenStream], track: ref[DeclStats]) -> bool:
    let _ = types.parse_type_ref(stream)
    parse_decl_block(stream)
    track.extending_blocks += 1
    return true


# ---- Function signature ----

function parse_function_signature(stream: ref[ts.TokenStream], track: ref[DeclStats]) -> bool:
    ts.advance(stream)
    parse_name_and_type_params(stream)
    parse_params(stream)

    if ts.match_symbol(stream, "->"):
        let _ = types.parse_type_ref(stream)

    if ts.match_symbol(stream, "="):
        let _ = expr.parse_expression(stream)
        ts.skip_newlines(stream)
        track.functions += 1
        return true

    if ts.check_kind(stream, token.TokenKind.newline) or ts.check_symbol(stream, ":"):
        parse_decl_block(stream)
        track.functions += 1
        return true

    ts.skip_newlines(stream)
    track.functions += 1
    return true


# ---- Extern function ----

function parse_extern_function(stream: ref[ts.TokenStream], track: ref[DeclStats]) -> bool:
    ts.advance(stream)
    parse_name_and_type_params(stream)
    parse_params(stream)

    if ts.match_symbol(stream, "->"):
        let _ = types.parse_type_ref(stream)

    if ts.match_symbol(stream, "="):
        let _ = expr.parse_expression(stream)

    ts.skip_newlines(stream)
    track.extern_functions += 1
    return true


# ---- Static assert ----

function parse_static_assert_decl(stream: ref[ts.TokenStream], track: ref[DeclStats]) -> bool:
    if not ts.match_symbol(stream, "("):
        return false
    let _ = expr.parse_expression(stream)
    ts.match_symbol(stream, ",")
    let _ = expr.parse_expression(stream)
    ts.match_symbol(stream, ")")
    ts.skip_newlines(stream)
    track.static_asserts += 1
    return true


# ---- When (top-level) ----

function parse_when_top_level(stream: ref[ts.TokenStream], track: ref[DeclStats]) -> bool:
    let _ = expr.parse_expression(stream)
    parse_decl_block(stream)
    track.when_blocks += 1
    return true


# ---- Name and type params ----

function parse_name_and_type_params(stream: ref[ts.TokenStream]) -> void:
    if ts.peek_kind(stream) == token.TokenKind.identifier or ts.peek_kind(stream) == token.TokenKind.keyword:
        ts.advance(stream)

    if ts.check_symbol(stream, "["):
        ts.advance(stream)
        blocks.parse_group_content(stream, "[", "]")


function parse_params(stream: ref[ts.TokenStream]) -> void:
    if ts.match_symbol(stream, "("):
        blocks.parse_group_content(stream, "(", ")")


# ---- Block utilities ----

function parse_decl_block(stream: ref[ts.TokenStream]) -> void:
    if not ts.check_symbol(stream, ":"):
        ts.skip_newlines(stream)
        if ts.match_symbol(stream, ":"):
            skip_decl_block_body(stream)
        else if ts.check_kind(stream, token.TokenKind.indent):
            skip_decl_block_body(stream)
        return

    ts.advance(stream)
    skip_decl_block_body(stream)


function skip_decl_block_body(stream: ref[ts.TokenStream]) -> void:
    if ts.check_kind(stream, token.TokenKind.newline):
        ts.advance(stream)

    if ts.match_kind(stream, token.TokenKind.indent):
        blocks.skip_to_dedent(stream)


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

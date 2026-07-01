import parser.token_stream as ts
import lexer.token as token
import parser.blocks as blocks
import parser.ast_types as ast

public function parse_qualified_name(stream: ref[ts.TokenStream]) -> bool:
    if not parse_name_part(stream):
        return false

    while ts.check_symbol(stream, "."):
        ts.advance(stream)
        if not parse_name_part(stream):
            return false

    return true


function parse_name_part(stream: ref[ts.TokenStream]) -> bool:
    let kind = ts.peek_kind(stream)
    if kind == token.TokenKind.identifier:
        ts.advance(stream)
        return true

    if kind == token.TokenKind.keyword:
        ts.advance(stream)
        return true

    return false


public function parse_type_ref(stream: ref[ts.TokenStream], builder: ref[ast.TypeBuilder], out_idx: ref[ast.TypeExprIdx]) -> bool:
    let tok = ts.peek(stream)

    if tok.kind == token.TokenKind.keyword:
        if tok.lexeme == "fn":
            let start_off = tok.start_offset
            ts.advance(stream)
            return parse_function_type(stream, builder, out_idx, start_off)
        else if tok.lexeme == "proc":
            let start_off = tok.start_offset
            ts.advance(stream)
            return parse_proc_type(stream, builder, out_idx, start_off)
        else if tok.lexeme == "dyn":
            let start_off = tok.start_offset
            ts.advance(stream)
            return parse_dyn_type(stream, builder, out_idx, start_off)

    if tok.kind == token.TokenKind.symbol:
        if tok.lexeme == "(":
            return parse_tuple_type(stream, builder, out_idx)
        if tok.lexeme == "@":
            return parse_lifetime_ref(stream, builder, out_idx)

    let name_start = ts.peek(stream).start_offset
    if not parse_qualified_name(stream):
        return false
    let name_end = ts.peek_prev(stream).end_offset
    let name = ts.source_slice(stream, name_start, name_end)

    parse_type_arguments(stream)

    var has_nullable = false
    if ts.match_symbol(stream, "?"):
        has_nullable = true

    let end_off = ts.peek_prev(stream).end_offset
    read(out_idx) = builder.push(ast.TypeExpr.named(qualified_name = name, start_off = name_start, end_off = end_off))
    return true


public function parse_type_ref_void(stream: ref[ts.TokenStream]) -> bool:
    var builder = ast.TypeBuilder.create()
    defer builder.release()
    var idx: ast.TypeExprIdx = ast.TYPE_EXPR_NULL
    return parse_type_ref(stream, ref_of(builder), ref_of(idx))


public function parse_type_ref_as_text(stream: ref[ts.TokenStream], text_out: ref[str]) -> bool:
    let tok = ts.peek(stream)

    if tok.kind == token.TokenKind.keyword:
        if tok.lexeme == "fn" or tok.lexeme == "proc":
            ts.advance(stream)
            parse_type_arguments(stream)
            parse_type_arguments(stream)
            return true
        else if tok.lexeme == "dyn":
            ts.advance(stream)
            ts.match_symbol(stream, "[")
            parse_qualified_name(stream)
            parse_type_arguments(stream)
            ts.match_symbol(stream, "]")
            ts.match_symbol(stream, "?")
            return true

    if tok.kind == token.TokenKind.symbol:
        if tok.lexeme == "(":
            ts.advance(stream)
            if not parse_type_ref_as_text(stream, text_out):
                return false
            while ts.match_symbol(stream, ","):
                let _ = parse_type_ref_as_text(stream, text_out)
            ts.match_symbol(stream, ")")
            ts.match_symbol(stream, "?")
            return true
        if tok.lexeme == "@":
            ts.advance(stream)
            parse_name_part(stream)
            return true

    let start = ts.peek(stream).start_offset
    if not parse_qualified_name(stream):
        return false
    let end = ts.peek_prev(stream).end_offset
    read(text_out) = ts.source_slice(stream, start, end)

    parse_type_arguments(stream)

    let _ = ts.match_symbol(stream, "?")

    return true


function parse_function_type(stream: ref[ts.TokenStream], builder: ref[ast.TypeBuilder], out_idx: ref[ast.TypeExprIdx], start_off: ptr_uint) -> bool:
    ts.match_symbol(stream, "(")
    let params_start = ts.peek(stream).start_offset

    while not ts.check_symbol(stream, ")") and not ts.eof(stream):
        ts.advance(stream)

    let params_end = ts.peek_prev(stream).end_offset
    let params = ts.source_slice(stream, params_start, params_end)
    if not ts.match_symbol(stream, ")"):
        return false
    if not ts.match_symbol(stream, "->"):
        return false

    var ret_type: str = ""
    let _ = parse_type_ref_as_text(stream, ref_of(ret_type))
    let end_off = ts.peek_prev(stream).end_offset
    read(out_idx) = builder.push(ast.TypeExpr.func_type(params = params, return_type = ret_type, start_off = start_off, end_off = end_off))
    return true


function parse_proc_type(stream: ref[ts.TokenStream], builder: ref[ast.TypeBuilder], out_idx: ref[ast.TypeExprIdx], start_off: ptr_uint) -> bool:
    ts.match_symbol(stream, "(")
    let params_start = ts.peek(stream).start_offset

    while not ts.check_symbol(stream, ")") and not ts.eof(stream):
        ts.advance(stream)

    let params_end = ts.peek_prev(stream).end_offset
    let params = ts.source_slice(stream, params_start, params_end)
    if not ts.match_symbol(stream, ")"):
        return false
    if not ts.match_symbol(stream, "->"):
        return false

    var ret_type: str = ""
    let _ = parse_type_ref_as_text(stream, ref_of(ret_type))
    let end_off = ts.peek_prev(stream).end_offset
    read(out_idx) = builder.push(ast.TypeExpr.proc_type(params = params, return_type = ret_type, start_off = start_off, end_off = end_off))
    return true


function parse_dyn_type(stream: ref[ts.TokenStream], builder: ref[ast.TypeBuilder], out_idx: ref[ast.TypeExprIdx], start_off: ptr_uint) -> bool:
    if not ts.match_symbol(stream, "["):
        return false

    let name_start = ts.peek(stream).start_offset
    if not parse_qualified_name(stream):
        return false
    let name_end = ts.peek_prev(stream).end_offset
    let iname = ts.source_slice(stream, name_start, name_end)

    parse_type_arguments(stream)

    if not ts.match_symbol(stream, "]"):
        return false

    let end_off = ts.peek_prev(stream).end_offset
    let _ = ts.match_symbol(stream, "?")
    read(out_idx) = builder.push(ast.TypeExpr.dyn_type(interface_name = iname, start_off = start_off, end_off = end_off))
    return true


function parse_tuple_type(stream: ref[ts.TokenStream], builder: ref[ast.TypeBuilder], out_idx: ref[ast.TypeExprIdx]) -> bool:
    if not ts.check_symbol(stream, "("):
        return false

    let start_off = ts.peek(stream).start_offset
    ts.advance(stream)

    if not parse_type_ref(stream, builder, out_idx):
        return false

    while ts.match_symbol(stream, ","):
        var next: ast.TypeExprIdx = ast.TYPE_EXPR_NULL
        if not parse_type_ref(stream, builder, ref_of(next)):
            return false

    if not ts.match_symbol(stream, ")"):
        return false

    let end_off = ts.peek_prev(stream).end_offset
    let _ = ts.match_symbol(stream, "?")
    read(out_idx) = builder.push(ast.TypeExpr.tuple_type(element_types = ts.source_slice(stream, start_off, end_off), start_off = start_off, end_off = end_off))
    return true


function parse_lifetime_ref(stream: ref[ts.TokenStream], builder: ref[ast.TypeBuilder], out_idx: ref[ast.TypeExprIdx]) -> bool:
    let start_off = ts.peek(stream).start_offset
    ts.advance(stream)
    if not parse_name_part(stream):
        return false
    let end_off = ts.peek_prev(stream).end_offset
    read(out_idx) = builder.push(ast.TypeExpr.lifetime(ref_text = ts.source_slice(stream, start_off, end_off), start_off = start_off, end_off = end_off))
    return true


function parse_type_arguments(stream: ref[ts.TokenStream]) -> void:
    if not ts.check_symbol(stream, "["):
        return

    ts.advance(stream)

    if ts.match_symbol(stream, "@"):
        parse_name_part(stream)
        let _ = ts.match_symbol(stream, ",")

    var bracket_depth: ptr_uint = 1
    while not ts.eof(stream) and bracket_depth > 0:
        let tok = ts.peek(stream)
        if tok.kind == token.TokenKind.symbol:
            if tok.lexeme == "[":
                bracket_depth += 1
            else if tok.lexeme == "]":
                bracket_depth -= 1
                if bracket_depth == 0:
                    ts.advance(stream)
                    return
        ts.advance(stream)


public function skip_type_arguments(stream: ref[ts.TokenStream]) -> void:
    if not ts.check_symbol(stream, "["):
        return

    ts.advance(stream)
    blocks.parse_group_content(stream, "[", "]")


function parse_type_comma_list(stream: ref[ts.TokenStream], end_symbol: str) -> void:
    while not ts.check_symbol(stream, end_symbol) and not ts.eof(stream):
        let tok = ts.peek(stream)
        if tok.kind == token.TokenKind.keyword:
            if tok.lexeme == "fn" or tok.lexeme == "proc" or tok.lexeme == "dyn":
                var builder = ast.TypeBuilder.create()
                defer builder.release()
                var idx: ast.TypeExprIdx = ast.TYPE_EXPR_NULL
                let _ = parse_type_ref(stream, ref_of(builder), ref_of(idx))
            else:
                ts.advance(stream)
        else if tok.kind == token.TokenKind.identifier or tok.kind == token.TokenKind.symbol:
            ts.advance(stream)
        else if tok.kind == token.TokenKind.char_literal or tok.kind == token.TokenKind.integer_literal or tok.kind == token.TokenKind.float_literal:
            ts.advance(stream)
        else if tok.kind == token.TokenKind.string_literal or tok.kind == token.TokenKind.cstring_literal or tok.kind == token.TokenKind.fstring_literal:
            ts.advance(stream)
        else:
            return

        if not ts.match_symbol(stream, ","):
            break

import parser.token_stream as ts
import lexer.token as token
import parser.blocks as blocks

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


public function parse_type_ref(stream: ref[ts.TokenStream]) -> bool:
    let tok = ts.peek(stream)

    if tok.kind == token.TokenKind.keyword:
        if tok.lexeme == "fn":
            ts.advance(stream)
            return parse_function_type(stream)
        else if tok.lexeme == "proc":
            ts.advance(stream)
            return parse_proc_type(stream)
        else if tok.lexeme == "dyn":
            ts.advance(stream)
            return parse_dyn_type(stream)

    if tok.kind == token.TokenKind.symbol:
        if tok.lexeme == "(":
            return parse_tuple_type(stream)
        if tok.lexeme == "@":
            return parse_lifetime_ref(stream)

    if not parse_qualified_name(stream):
        return false

    parse_type_arguments(stream)

    let _ = ts.match_symbol(stream, "?")

    return true


function parse_function_type(stream: ref[ts.TokenStream]) -> bool:
    ts.match_symbol(stream, "(")

    while not ts.check_symbol(stream, ")") and not ts.eof(stream):
        ts.advance(stream)

    if not ts.match_symbol(stream, ")"):
        return false
    if not ts.match_symbol(stream, "->"):
        return false

    return parse_type_ref(stream)


function parse_proc_type(stream: ref[ts.TokenStream]) -> bool:
    ts.match_symbol(stream, "(")

    while not ts.check_symbol(stream, ")") and not ts.eof(stream):
        ts.advance(stream)

    if not ts.match_symbol(stream, ")"):
        return false
    if not ts.match_symbol(stream, "->"):
        return false

    return parse_type_ref(stream)


function parse_dyn_type(stream: ref[ts.TokenStream]) -> bool:
    if not ts.match_symbol(stream, "["):
        return false
    if not parse_qualified_name(stream):
        return false

    parse_type_arguments(stream)

    if not ts.match_symbol(stream, "]"):
        return false

    let _ = ts.match_symbol(stream, "?")

    return true


function parse_tuple_type(stream: ref[ts.TokenStream]) -> bool:
    if not ts.check_symbol(stream, "("):
        return false

    ts.advance(stream)

    if not parse_type_ref(stream):
        return false

    if ts.match_symbol(stream, ","):
        while true:
            if not parse_type_ref(stream):
                return false
            if not ts.match_symbol(stream, ","):
                break

    if not ts.match_symbol(stream, ")"):
        return false

    let _ = ts.match_symbol(stream, "?")

    return true


function parse_lifetime_ref(stream: ref[ts.TokenStream]) -> bool:
    ts.advance(stream)
    if not parse_name_part(stream):
        return false
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
                let _ = parse_type_ref(stream)
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

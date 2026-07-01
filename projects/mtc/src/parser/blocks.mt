import parser.token_stream as ts
import lexer.token as token
import std.fmt as fmt
import std.mem.arena as arena
import std.string
import std.vec

public function parse_block(stream: ref[ts.TokenStream]) -> bool:
    if not ts.match_symbol(stream, ":"):
        return false
    if not ts.match_kind(stream, token.TokenKind.newline):
        return false
    if not ts.match_kind(stream, token.TokenKind.indent):
        return false
    return true

public function consume_dedent(stream: ref[ts.TokenStream]) -> bool:
    return ts.match_kind(stream, token.TokenKind.dedent)

public function skip_to_dedent(stream: ref[ts.TokenStream]) -> void:
    var depth: ptr_uint = 1
    var sk_iters: ptr_uint = 0
    while not ts.eof(stream) and depth > 0:
        sk_iters += 1
        if sk_iters >= 10000:
            let ftok = ts.peek(stream)
            var arena_storage = arena.create(256)
            var msg = string.String.create()
            msg.append(stream.path)
            msg.append(":")
            fmt.append_ptr_uint(ref_of(msg), ftok.line)
            msg.append(": fatal: skip_to_dedent hung after 10000 iter")
            fatal(arena_storage.to_cstr(msg.as_str()))
        let kind = ts.peek_kind(stream)
        if kind == token.TokenKind.indent:
            depth += 1
        else if kind == token.TokenKind.dedent:
            depth -= 1
            if depth == 0:
                ts.advance(stream)
                return
        else if kind == token.TokenKind.eof:
            return
        ts.advance(stream)

public function parse_group_content(stream: ref[ts.TokenStream], open: str, close: str) -> void:
    var depth: ptr_uint = 1
    var gc_iters: ptr_uint = 0
    while not ts.eof(stream) and depth > 0:
        gc_iters += 1
        if gc_iters >= 10000:
            let ftok = ts.peek(stream)
            var arena_storage = arena.create(256)
            var msg = string.String.create()
            msg.append(stream.path)
            msg.append(":")
            fmt.append_ptr_uint(ref_of(msg), ftok.line)
            msg.append(": fatal: parse_group_content hung after 10000 iter")
            fatal(arena_storage.to_cstr(msg.as_str()))
        let tok = ts.peek(stream)
        if tok.kind == token.TokenKind.symbol:
            if tok.lexeme == open or tok.lexeme == "[" or tok.lexeme == "(":
                depth += 1
            else if tok.lexeme == close or tok.lexeme == "]" or tok.lexeme == ")":
                depth -= 1
                if depth == 0:
                    ts.advance(stream)
                    return
        ts.advance(stream)

public function synchronize_to_next_decl(stream: ref[ts.TokenStream]) -> void:
    var indent_depth: ptr_uint = 0
    var sync_iters: ptr_uint = 0
    while not ts.eof(stream):
        sync_iters += 1
        if sync_iters >= 10000:
            let ftok = ts.peek(stream)
            var arena_storage = arena.create(256)
            var msg = string.String.create()
            msg.append(stream.path)
            msg.append(":")
            fmt.append_ptr_uint(ref_of(msg), ftok.line)
            msg.append(": fatal: synchronize_to_next_decl hung after 10000 iter")
            fatal(arena_storage.to_cstr(msg.as_str()))
        let tok = ts.peek(stream)
        if tok.kind == token.TokenKind.indent:
            indent_depth += 1
        else if tok.kind == token.TokenKind.dedent:
            if indent_depth == 0:
                ts.advance(stream)
                break
            indent_depth -= 1
        else if tok.kind == token.TokenKind.newline and indent_depth == 0:
            ts.advance(stream)
            ts.skip_newlines(stream)
            let next = ts.peek(stream)
            if next.kind == token.TokenKind.keyword:
                break
        else:
            ts.advance(stream)


public function parse_body_lines(stream: ref[ts.TokenStream]) -> vec.Vec[str]:
    var result = vec.Vec[str].create()
    if not ts.check_kind(stream, token.TokenKind.indent):
        return result
    ts.advance(stream)

    var depth: ptr_uint = 1
    var member_start: ptr_uint = ts.peek(stream).start_offset
    var iter_count: ptr_uint = 0

    while not ts.eof(stream) and depth > 0:
        iter_count += 1
        if iter_count >= 50000:
            let ftok = ts.peek(stream)
            var arena_storage = arena.create(256)
            var msg = string.String.create()
            msg.append(stream.path)
            msg.append(":")
            fmt.append_ptr_uint(ref_of(msg), ftok.line)
            msg.append(": fatal: parse_body_lines hung after 50000 iter")
            fatal(arena_storage.to_cstr(msg.as_str()))

        let kind = ts.peek_kind(stream)
        if kind == token.TokenKind.indent:
            depth += 1
            ts.advance(stream)
        else if kind == token.TokenKind.dedent:
            depth -= 1
            if depth == 0:
                let member_end = ts.peek_prev(stream).end_offset
                if member_end > member_start:
                    result.push(ts.source_slice(stream, member_start, member_end))
                ts.advance(stream)
                return result
            ts.advance(stream)
        else if kind == token.TokenKind.newline:
            let member_end = ts.peek_prev(stream).end_offset
            if member_end > member_start:
                result.push(ts.source_slice(stream, member_start, member_end))
            ts.advance(stream)
            ts.skip_newlines(stream)
            if not ts.eof(stream) and ts.peek_kind(stream) != token.TokenKind.dedent:
                member_start = ts.peek(stream).start_offset
        else:
            ts.advance(stream)

    return result

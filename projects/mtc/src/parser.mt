import lexer
import lexer.token as token
import lexer.error as lex_error
import parser.token_stream as ts
import parser.ast_types as ast
import parser.declaration as decl
import parser.error as parser_error
import std.string
import std.vec


public struct ParseResult:
    success: bool
    imports: ptr_uint
    total_decls: ptr_uint
    stats: decl.DeclStats


public function parse(
    tokens: ref[vec.Vec[token.Token]],
    path: str,
    source: str,
    decls_out: ref[vec.Vec[ast.Decl]],
) -> ParseResult:
    var tok_stream = ts.make_stream(tokens, path, source)
    var stats = decl.zero_stats()
    let result = parse_source_file(ref_of(tok_stream), ref_of(stats), decls_out, null)
    return build_result(result, ref_of(stats))


public function parse_recovering(
    source: str,
    path: str,
    decls_out: ref[vec.Vec[ast.Decl]],
    errors: ref[vec.Vec[parser_error.ParseError]],
) -> ParseResult:
    var lex_errors = vec.Vec[lex_error.LexError].create()
    defer lex_errors.release()

    var tokens = lexer.lex_recovering(source, path, ref_of(lex_errors))
    defer tokens.release()

    var index: ptr_uint = 0
    while index < lex_errors.len():
        let lex_err_ptr = lex_errors.get(index) else:
            fatal(c"parse_recovering missing lex error")
        unsafe:
            let le = read(lex_err_ptr)
            errors.push(parser_error.create(path, le.line, le.column, le.message.as_str()))
        index += 1

    var tok_stream = ts.make_stream(ref_of(tokens), path, source)
    var stats = decl.zero_stats()
    let result = parse_source_file(ref_of(tok_stream), ref_of(stats), decls_out, unsafe: ptr[vec.Vec[parser_error.ParseError]]<-ptr_of(read(errors)))
    return build_result(result, ref_of(stats))


function build_result(ok: bool, stats: ref[decl.DeclStats]) -> ParseResult:
    var total = (
        read(stats).consts + read(stats).vars + read(stats).events + read(stats).type_aliases
        + read(stats).attributes + read(stats).structs + read(stats).unions + read(stats).enums
        + read(stats).flags_count + read(stats).variants + read(stats).opaques + read(stats).interfaces
        + read(stats).extending_blocks + read(stats).functions + read(stats).extern_functions
        + read(stats).static_asserts + read(stats).when_blocks
    )

    return ParseResult(
        success = ok,
        imports = read(stats).imports,
        total_decls = total,
        stats = read(stats),
    )


function parse_source_file(
    s: ref[ts.TokenStream],
    stats: ref[decl.DeclStats],
    decls_out: ref[vec.Vec[ast.Decl]],
    recover: ptr[vec.Vec[parser_error.ParseError]]?,
) -> bool:
    ts.skip_newlines(s)

    if ts.check_keyword(s, "external"):
        return parse_raw_module(s, stats, decls_out, recover)

    while ts.check_keyword(s, "import"):
        let head_start = ts.peek(s).start_offset
        ts.advance(s)
        var path_buf: str = ""
        var alias_buf: str = ""
        let ok = decl.parse_import_names(s, ref_of(path_buf), ref_of(alias_buf))
        if not ok:
            return false
        decls_out.push(ast.Decl.import_decl(head_start = head_start, head_end = ts.peek_prev(s).end_offset, path = path_buf, alias = alias_buf))
        stats.imports += 1
        ts.skip_newlines(s)

    while not ts.eof(s):
        if not decl.parse_declaration(s, stats, decls_out, recover):
            if recover == null:
                return false
        ts.skip_newlines(s)

    return true


function parse_raw_module(
    s: ref[ts.TokenStream],
    stats: ref[decl.DeclStats],
    decls_out: ref[vec.Vec[ast.Decl]],
    recover: ptr[vec.Vec[parser_error.ParseError]]?,
) -> bool:
    ts.advance(s)
    ts.skip_newlines(s)

    while ts.check_keyword(s, "import"):
        let head_start = ts.peek(s).start_offset
        ts.advance(s)
        var path_buf: str = ""
        var alias_buf: str = ""
        let ok = decl.parse_import_names(s, ref_of(path_buf), ref_of(alias_buf))
        if not ok:
            return false
        decls_out.push(ast.Decl.import_decl(head_start = head_start, head_end = ts.peek_prev(s).end_offset, path = path_buf, alias = alias_buf))
        stats.imports += 1
        ts.skip_newlines(s)

    while ts.check_keyword(s, "link") or ts.check_keyword(s, "include") or ts.check_keyword(s, "compiler_flag"):
        ts.advance(s)
        if ts.peek_kind(s) == token.TokenKind.string_literal:
            ts.advance(s)
        ts.skip_newlines(s)

    while not ts.eof(s):
        if not decl.parse_declaration(s, stats, decls_out, recover):
            if recover == null:
                return false
        ts.skip_newlines(s)

    return true

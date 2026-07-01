import lexer.token as token
import parser.token_stream as ts
import parser.ast_types as ast
import parser.declaration as decl
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
    decls_out: ref[vec.Vec[ast.Decl]],
) -> ParseResult:
    var tok_stream = ts.make_stream(tokens, path)
    var stats = decl.zero_stats()

    let result = parse_source_file(ref_of(tok_stream), ref_of(stats), decls_out)

    var total = (
        stats.consts + stats.vars + stats.events + stats.type_aliases
        + stats.attributes + stats.structs + stats.unions + stats.enums
        + stats.flags_count + stats.variants + stats.opaques + stats.interfaces
        + stats.extending_blocks + stats.functions + stats.extern_functions
        + stats.static_asserts + stats.when_blocks
    )

    return ParseResult(
        success = result,
        imports = stats.imports,
        total_decls = total,
        stats = stats,
    )


function parse_source_file(
    s: ref[ts.TokenStream],
    stats: ref[decl.DeclStats],
    decls_out: ref[vec.Vec[ast.Decl]],
) -> bool:
    ts.skip_newlines(s)

    if ts.check_keyword(s, "external"):
        return parse_raw_module(s, stats, decls_out)

    while ts.check_keyword(s, "import"):
        let head_start = ts.peek(s).start_offset
        ts.advance(s)
        let ok = decl.parse_import_names(s)
        if not ok:
            return false
        decls_out.push(ast.Decl.import_decl(head_start = head_start, head_end = ts.peek_prev(s).end_offset, path = "", alias = ""))
        stats.imports += 1
        ts.skip_newlines(s)

    while not ts.eof(s):
        if not decl.parse_declaration(s, stats, decls_out):
            return false
        ts.skip_newlines(s)

    return true


function parse_raw_module(
    s: ref[ts.TokenStream],
    stats: ref[decl.DeclStats],
    decls_out: ref[vec.Vec[ast.Decl]],
) -> bool:
    ts.advance(s)
    ts.skip_newlines(s)

    while ts.check_keyword(s, "import"):
        let head_start = ts.peek(s).start_offset
        ts.advance(s)
        let ok = decl.parse_import_names(s)
        if not ok:
            return false
        decls_out.push(ast.Decl.import_decl(head_start = head_start, head_end = ts.peek_prev(s).end_offset, path = "", alias = ""))
        stats.imports += 1
        ts.skip_newlines(s)

    while ts.check_keyword(s, "link") or ts.check_keyword(s, "include") or ts.check_keyword(s, "compiler_flag"):
        ts.advance(s)
        if ts.peek_kind(s) == token.TokenKind.string_literal:
            ts.advance(s)
        ts.skip_newlines(s)

    while not ts.eof(s):
        if not decl.parse_declaration(s, stats, decls_out):
            return false
        ts.skip_newlines(s)

    return true

import lexer.token as token
import parser.token_stream as ts
import parser.declaration as decl
import std.log as log
import std.vec

public struct ParseResult:
    success: bool
    imports: ptr_uint
    total_decls: ptr_uint
    stats: decl.DeclStats


public function parse(tokens: ref[vec.Vec[token.Token]], path: str) -> ParseResult:
    var stream = ts.make_stream(tokens, path)
    var stats = decl.zero_stats()

    let result = parse_source_file(ref_of(stream), ref_of(stats))

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


function parse_source_file(stream: ref[ts.TokenStream], stats: ref[decl.DeclStats]) -> bool:
    ts.skip_newlines(stream)

    if ts.check_keyword(stream, "external"):
        return parse_raw_module(stream, stats)

    while ts.check_keyword(stream, "import"):
        ts.advance(stream)
        decl.parse_import(stream)
        stats.imports += 1
        ts.skip_newlines(stream)

    while not ts.eof(stream):
        if not decl.parse_declaration(stream, stats):
            return false
        ts.skip_newlines(stream)

    return true


function parse_raw_module(stream: ref[ts.TokenStream], stats: ref[decl.DeclStats]) -> bool:
    ts.advance(stream)
    ts.skip_newlines(stream)

    while ts.check_keyword(stream, "import"):
        ts.advance(stream)
        decl.parse_import(stream)
        stats.imports += 1
        ts.skip_newlines(stream)

    while ts.check_keyword(stream, "link") or ts.check_keyword(stream, "include") or ts.check_keyword(stream, "compiler_flag"):
        ts.advance(stream)
        if ts.peek_kind(stream) == token.TokenKind.string_literal:
            ts.advance(stream)
        ts.skip_newlines(stream)

    while not ts.eof(stream):
        if not decl.parse_declaration(stream, stats):
            return false
        ts.skip_newlines(stream)

    return true

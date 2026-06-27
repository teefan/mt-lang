## Self-hosted Milk Tea parser.
##
## Consumes tokens (via TokenStream) and produces AST JSON matching the
## Ruby mtc format, consumable by comparison with `ruby bin/mtc parse --json`.

import std.vec as vec_mod
import std.string as string_mod
import std.str
import std.fmt as fmt

import lexer.lexer as lexer_mod
import parser.token_stream as ts
import parser.ast_json as ast

# ── parser state ──────────────────────────────────────────────────────────

struct Parser:
    tokens: ts.TokenStream
    ast_buf: ast.AstBuf
    need_comma: bool
    stmt_failed: bool
    known_generics: vec_mod.Vec[str]
    block_expr_done: bool
    pending_packed: bool
    pending_alignment: ptr_uint
    has_pending_alignment: bool
    pending_attrs: string_mod.String

function ast_open_node(p: ref[Parser], node_type: str) -> void:
    if p.need_comma:
        ast.ast_comma(ref_of(p.ast_buf))
        p.need_comma = false
    ast.ast_open(ref_of(p.ast_buf), node_type)
    p.need_comma = true

# ── token helpers ─────────────────────────────────────────────────────────

function peek_kind(p: ref[Parser]) -> str:
    return p.tokens.peek_kind()

function check(p: ref[Parser], kind: str) -> bool:
    return p.tokens.check(kind)

function match_kind(p: ref[Parser], kind: str) -> bool:
    return p.tokens.match_kind(kind)

function advance(p: ref[Parser]) -> void:
    p.tokens.advance()

function consume(p: ref[Parser], kind: str, msg: str) -> void:
    if check(p, kind):
        advance(p)
    else:
        p.stmt_failed = true

function is_eof(p: ref[Parser]) -> bool:
    return p.tokens.is_eof()

function skip_newlines(p: ref[Parser]) -> void:
    p.tokens.skip_newlines()

function peek_lexeme(p: ref[Parser]) -> str:
    let tok = p.tokens.peek() else:
        return ""

    return unsafe: read(tok).lexeme

function peek_lit_json(p: ref[Parser]) -> str:
    let tok = p.tokens.peek() else:
        return ""

    return unsafe: read(tok).lit_json.as_str()

function format_spec_json(fmts: str) -> str:
    var n = fmts.len
    if n == 0:
        return "null"
    if n == 1:
        let c = fmts.byte_at(0)
        if c == 'b':
            return "{\"kind\":{\"$sym\":\"bin\"},\"uppercase\":false}"
        if c == 'x':
            return "{\"kind\":{\"$sym\":\"hex\"},\"uppercase\":false}"
        if c == 'X':
            return "{\"kind\":{\"$sym\":\"hex\"},\"uppercase\":true}"
        if c == 'o':
            return "{\"kind\":{\"$sym\":\"oct\"},\"uppercase\":false}"
        if c == 'O':
            return "{\"kind\":{\"$sym\":\"oct\"},\"uppercase\":true}"
        if c == 'B':
            return "{\"kind\":{\"$sym\":\"bin\"},\"uppercase\":true}"
    if n == 2 and fmts.byte_at(0) == '.' and fmts.byte_at(1) == '2':
        return "{\"kind\":{\"$sym\":\"precision\"},\"value\":2}"
    return "null"

function build_fstring_from_lexeme(lexeme: str) -> string_mod.String:
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:FormatString\",\"parts\":[")
    var first = true
    var n = lexeme.len
    var start: ptr_uint = 0
    var end = n
    var heredoc_margin: ptr_uint = 0

    if n >= 2 and lexeme.byte_at(0) == 'f' and lexeme.byte_at(1) == '"':
        start = 2
    else if n >= 4 and lexeme.byte_at(0) == 'f' and lexeme.byte_at(1) == '<' and lexeme.byte_at(2) == '<' and lexeme.byte_at(3) == '-':
        start = 4
        while start < n and lexeme.byte_at(start) != '\n':
            start += 1
        if start < n:
            start += 1
        while end > 0 and lexeme.byte_at(end - 1) == '\n':
            end -= 1
        while end > start and lexeme.byte_at(end - 1) != '\n':
            end -= 1
        var min_indent: ptr_uint = 999
        var i2 = start
        while i2 < end:
            var line_indent: ptr_uint = 0
            while i2 < end and lexeme.byte_at(i2) == ' ':
                line_indent += 1
                i2 += 1
            if i2 < end and lexeme.byte_at(i2) != '\n' and line_indent < min_indent:
                min_indent = line_indent
            while i2 < end and lexeme.byte_at(i2) != '\n':
                i2 += 1
            if i2 < end:
                i2 += 1
        if min_indent > 0 and min_indent < 999:
            start += min_indent
            heredoc_margin = min_indent
    if end > start and lexeme.byte_at(end - 1) == '"':
        end -= 1

    var i = start

    while i < end:
        let ch = lexeme.byte_at(i)

        if ch == '#' and i + 1 < end and lexeme.byte_at(i + 1) == '{':
            i += 2
            var expr = string_mod.String.create()
            var fmt_spec = string_mod.String.create()
            var brace_depth: ptr_uint = 1
            var in_fmt = false
            var expr_done = false
            while i < end and brace_depth > 0:
                let ec = lexeme.byte_at(i)
                if ec == ':' and not in_fmt and brace_depth == 1 and not expr_done:
                    in_fmt = true
                    i += 1
                else if ec == '{':
                    brace_depth += 1
                    if in_fmt:
                        fmt_spec.push_byte(ec)
                    else:
                        expr.push_byte(ec)
                    i += 1
                else if ec == '}':
                    brace_depth -= 1
                    if brace_depth > 0:
                        if in_fmt:
                            fmt_spec.push_byte(ec)
                        else:
                            expr.push_byte(ec)
                    else:
                        expr_done = true
                    i += 1
                else if in_fmt:
                    fmt_spec.push_byte(ec)
                    i += 1
                else:
                    expr.push_byte(ec)
                    i += 1

            if expr.len > 0:
                if not first:
                    r.push_byte(',')
                first = false
                var expr_ast = parse_standalone_expr(expr.as_str())
                r.append("{\"$mt_type\":\"AST:FormatExprPart\",\"expression\":")
                r.append(expr_ast.as_str())
                expr_ast.release()
                r.append(",\"format_spec\":")
                if fmt_spec.len > 0:
                    r.append(format_spec_json(fmt_spec.as_str()))
                else:
                    r.append("null")
                r.push_byte('}')
            expr.release()
            fmt_spec.release()
        else:
            var txt = string_mod.String.create()
            while i < end:
                let tc = lexeme.byte_at(i)
                if tc == '#' and i + 1 < end and lexeme.byte_at(i + 1) == '{':
                    break
                txt.push_byte(tc)
                i += 1
                if tc == '\n' and heredoc_margin > 0:
                    var si: ptr_uint = 0
                    while i < end and si < heredoc_margin and lexeme.byte_at(i) == ' ':
                        i += 1
                        si += 1

            if txt.len > 0:
                if not first:
                    r.push_byte(',')
                first = false
                r.append("{\"$mt_type\":\"AST:FormatTextPart\",\"value\":")
                var ve = lexer_mod.json_escaped(txt.as_str())
                r.append(ve.as_str())
                ve.release()
                r.push_byte('}')
            txt.release()

            if heredoc_margin > 0:
                var skip: ptr_uint = 0
                while i < end and skip < heredoc_margin and lexeme.byte_at(i) == ' ':
                    i += 1
                    skip += 1

    r.append("],\"line\":null,\"column\":null}")
    return r

# ── source file ───────────────────────────────────────────────────────────

function parse_source_file(p: ref[Parser], module_name: str) -> string_mod.String:
    p.ast_buf = ast.AstBuf(buf = string_mod.String.create(), first_field = true)

    ast.ast_open(ref_of(p.ast_buf), "SourceFile")
    ast.ast_str(ref_of(p.ast_buf), "module_name", module_name)

    var module_kind: str
    if check(p, "external"):
        advance(p)
        skip_newlines(p)
        module_kind = "raw_module"
    else:
        module_kind = "module"

    ast.ast_sym(ref_of(p.ast_buf), "module_kind", module_kind)

    ast.ast_array_start(ref_of(p.ast_buf), "imports")
    skip_newlines(p)
    var first_import = true
    while check(p, "import"):
        if not first_import:
            ast.ast_comma(ref_of(p.ast_buf))
        parse_import(p)
        skip_newlines(p)
        first_import = false
    ast.ast_array_end(ref_of(p.ast_buf))

    ast.ast_array_start(ref_of(p.ast_buf), "directives")
    ast.ast_array_end(ref_of(p.ast_buf))

    ast.ast_array_start(ref_of(p.ast_buf), "declarations")
    skip_newlines(p)
    var first = true
    var dangling = false
    var safety: ptr_uint = 0
    while not is_eof(p):
        safety += 1
        if safety > 50000:
            fatal(c"parse: infinite loop safety limit reached")

        p.pending_packed = false
        p.has_pending_alignment = false
        p.pending_attrs.clear()
        p.pending_attrs.push_byte('[')
        var attrs_first = true
        while check(p, "at"):
            advance(p)
            if check(p, "lbracket"):
                advance(p)
                while not check(p, "rbracket") and not is_eof(p):
                    if check(p, "identifier"):
                        let alx = peek_lexeme(p)
                        if not attrs_first:
                            p.pending_attrs.push_byte(',')
                        attrs_first = false
                        p.pending_attrs.append("{\"$mt_type\":\"AST:AttributeApplication\",\"name\":")
                        var aname = qname_single_json(alx)
                        p.pending_attrs.append(aname.as_str())
                        aname.release()
                        p.pending_attrs.append(",\"arguments\":[")
                        advance(p)
                        if alx == "packed":
                            p.pending_packed = true
                        var arg_first = true
                        if check(p, "lparen"):
                            advance(p)
                            while not check(p, "rparen") and not is_eof(p):
                                if not arg_first:
                                    p.pending_attrs.push_byte(',')
                                arg_first = false
                                if check(p, "integer"):
                                    let ilex = peek_lexeme(p)
                                    var il = int_lit_json(ilex)
                                    p.pending_attrs.append("{\"$mt_type\":\"AST:Argument\",\"name\":null,\"value\":")
                                    p.pending_attrs.append(il.as_str())
                                    il.release()
                                    p.pending_attrs.push_byte('}')
                                    advance(p)
                                    if alx == "align" or alx == "alignment":
                                        let al = lexer_mod.parse_int(ilex)
                                        p.pending_alignment = ptr_uint<-al
                                        p.has_pending_alignment = true
                                else if check(p, "string"):
                                    var sl = str_lit_json(p, false)
                                    p.pending_attrs.append("{\"$mt_type\":\"AST:Argument\",\"name\":null,\"value\":")
                                    p.pending_attrs.append(sl.as_str())
                                    sl.release()
                                    p.pending_attrs.push_byte('}')
                                else if check(p, "cstring"):
                                    var sl = str_lit_json(p, true)
                                    p.pending_attrs.append("{\"$mt_type\":\"AST:Argument\",\"name\":null,\"value\":")
                                    p.pending_attrs.append(sl.as_str())
                                    sl.release()
                                    p.pending_attrs.push_byte('}')
                                else if check(p, "char"):
                                    var cl = char_lit_json(p)
                                    p.pending_attrs.append("{\"$mt_type\":\"AST:Argument\",\"name\":null,\"value\":")
                                    p.pending_attrs.append(cl.as_str())
                                    cl.release()
                                    p.pending_attrs.push_byte('}')
                                if check(p, "comma"):
                                    advance(p)
                            if check(p, "rparen"):
                                advance(p)
                        p.pending_attrs.append("],\"line\":null,\"column\":null}")
                        if check(p, "comma"):
                            advance(p)
                    else:
                        advance(p)
                if check(p, "rbracket"):
                    advance(p)
            skip_newlines(p)
        p.pending_attrs.push_byte(']')

        let decl_kind = peek_kind(p)
        if decl_kind == "eof" or decl_kind == "dedent":
            break

        if not first and not dangling:
            ast.ast_comma(ref_of(p.ast_buf))
            dangling = true

        let blen = p.ast_buf.buf.len
        parse_declaration_safe(p)
        let emitted = p.ast_buf.buf.len != blen

        if emitted:
            first = false
            dangling = false

        skip_newlines(p)
    ast.ast_array_end(ref_of(p.ast_buf))

    # Remove trailing comma from last element
    var buf_len = p.ast_buf.buf.len
    if buf_len >= 3:
        unsafe:
            let data = ptr[char]<-p.ast_buf.buf.data
            if read(data + buf_len - 2) == ',' and read(data + buf_len - 1) == ']':
                read(data + buf_len - 2) = ' '
        p.ast_buf.buf.len = buf_len

    ast.ast_null(ref_of(p.ast_buf), "line")
    ast.ast_close(ref_of(p.ast_buf))

    return p.ast_buf.buf

# ── imports ───────────────────────────────────────────────────────────────

function is_ident_or_keyword(p: ref[Parser]) -> bool:
    let k = peek_kind(p)
    if k == "identifier":
        return true

    if k == "dot" or k == "as" or k == "newline" or k == "eof":
        return false

    if k == "colon" or k == "lparen" or k == "lbracket" or k == "comma":
        return false

    if k == "equal" or k == "arrow" or k == "rparen" or k == "rbracket":
        return false

    return true

function parse_import(p: ref[Parser]) -> void:
    advance(p)  # consume "import"

    var parts = vec_mod.Vec[str].create()
    while is_ident_or_keyword(p):
        parts.push(peek_lexeme(p))
        advance(p)
        if check(p, "dot"):
            advance(p)
        else:
            break

    var alias_name: str

    if check(p, "as"):
        advance(p)
        alias_name = peek_lexeme(p)
        advance(p)

    var import_name = ast.name_json(parts)
    parts.release()

    ast.ast_open(ref_of(p.ast_buf), "Import")
    ast.ast_raw(ref_of(p.ast_buf), "path", import_name.as_str())
    import_name.release()

    if alias_name == "":
        ast.ast_null(ref_of(p.ast_buf), "alias_name")
    else:
        ast.ast_str(ref_of(p.ast_buf), "alias_name", alias_name)

    ast.ast_null(ref_of(p.ast_buf), "line")
    ast.ast_null(ref_of(p.ast_buf), "column")
    ast.ast_null(ref_of(p.ast_buf), "length")
    ast.ast_close(ref_of(p.ast_buf))

# ── declarations ──────────────────────────────────────────────────────────

function parse_declaration_safe(p: ref[Parser]) -> void:
    let kind = peek_kind(p)
    let buf_before = p.ast_buf.buf.len

    if kind == "const":
        parse_const(p)
    else if kind == "var":
        parse_var(p)
    else if kind == "type":
        parse_type_alias(p)
    else if kind == "function":
        parse_function_def(p)
    else if kind == "async":
        parse_function_def(p)
    else if kind == "external":
        parse_extern_function(p)
    else if kind == "foreign":
        parse_foreign_function(p)
    else if kind == "struct":
        parse_struct(p)
    else if kind == "enum":
        parse_enum_or_flags(p, false)
    else if kind == "flags":
        parse_enum_or_flags(p, true)
    else if kind == "union":
        parse_union(p)
    else if kind == "variant":
        parse_variant(p)
    else if kind == "opaque":
        parse_opaque(p)
    else if kind == "interface":
        parse_interface(p)
    else if kind == "extending":
        parse_extending(p)
    else if kind == "attribute":
        parse_attribute(p)
    else if kind == "static_assert":
        parse_static_assert(p)
    else if kind == "event":
        parse_event(p)
    else if kind == "public":
        advance(p)
        parse_declaration_public(p)
    else if kind == "when":
        parse_when_block(p)
    else if kind == "eof" or kind == "dedent":
        return
    else:
        advance(p)

function parse_when_block(p: ref[Parser]) -> void:
    advance(p)
    var safety: ptr_uint = 0
    while not check(p, "newline") and not is_eof(p):
        safety += 1
        if safety > 100:
            break
        advance(p)
    if check(p, "newline"):
        advance(p)
    if check(p, "indent"):
        advance(p)
        var depth: ptr_uint = 1
        while depth > 0 and not is_eof(p):
            if check(p, "indent") or check(p, "when"):
                depth += 1
            else if check(p, "dedent"):
                depth -= 1
            advance(p)
    ast.ast_open(ref_of(p.ast_buf), "WhenStmt")
    ast.ast_null(ref_of(p.ast_buf), "discriminant")
    ast.ast_array_start(ref_of(p.ast_buf), "branches")
    ast.ast_array_end(ref_of(p.ast_buf))
    ast.ast_null(ref_of(p.ast_buf), "else_body")
    ast.ast_null(ref_of(p.ast_buf), "line")
    ast.ast_null(ref_of(p.ast_buf), "column")
    ast.ast_null(ref_of(p.ast_buf), "length")
    ast.ast_close(ref_of(p.ast_buf))

function parse_declaration_public(p: ref[Parser]) -> void:
    let kind = peek_kind(p)

    if kind == "const":
        parse_const_with_visibility(p, "public")
    else if kind == "var":
        parse_var_with_visibility(p, "public")
    else if kind == "type":
        parse_type_alias_with_visibility(p, "public")
    else if kind == "function" or kind == "async":
        parse_function_with_visibility(p, "public", false)
    else if kind == "struct":
        parse_struct_with_visibility(p, "public")
    else if kind == "event":
        parse_event_with_visibility(p, "public")
    else if kind == "variant":
        parse_variant_with_visibility(p, "public")
    else if kind == "enum":
        parse_enum_with_visibility(p, "public", false)
    else if kind == "flags":
        parse_enum_with_visibility(p, "public", true)
    else if kind == "interface":
        parse_interface_with_visibility(p, "public")
    else if kind == "opaque":
        parse_opaque_with_visibility(p, "public")
    else if kind == "union":
        parse_union_with_visibility(p, "public")
    else if kind == "foreign":
        parse_foreign_function_with_visibility(p, "public")
    else:
        fatal(c"parse: unexpected public declaration")

# ── const ─────────────────────────────────────────────────────────────────

function parse_const(p: ref[Parser]) -> void:
    parse_const_with_visibility(p, "")

function parse_const_with_visibility(p: ref[Parser], vis: str) -> void:
    advance(p)

    if check(p, "function"):
        parse_function_with_visibility(p, vis, true)
        return

    let cname = peek_lexeme(p)
    advance(p)

    var const_type = parse_type_annotation_capture(p)

    var has_block = false
    if check(p, "arrow"):
        advance(p)
        const_type.release()
        const_type = parse_type(p)
        has_block = true

    var const_value = string_mod.String.create()
    if check(p, "equal") and not has_block:
        advance(p)
        const_value.release()
        const_value = parse_expr(p)
        while not check(p, "newline") and not is_eof(p):
            advance(p)

    var block_body_json = string_mod.String.create()
    block_body_json.append("null")
    if has_block:
        if check(p, "colon"):
            advance(p)
            consume_nl(p)
            if check(p, "indent"):
                advance(p)
                let body_start = p.tokens.pos
                var bdepth: ptr_uint = 1
                while not is_eof(p):
                    if check(p, "indent"):
                        bdepth += 1
                        advance(p)
                    else if check(p, "dedent"):
                        bdepth -= 1
                        if bdepth == 0:
                            break
                        advance(p)
                    else:
                        advance(p)
                let body_end = p.tokens.pos
                p.tokens.pos = body_start
                p.stmt_failed = false
                var parsed = parse_stmt_block_body(p)
                if not p.stmt_failed and p.tokens.pos == body_end:
                    block_body_json.release()
                    block_body_json = parsed
                else:
                    parsed.release()
                p.tokens.pos = body_end
                if check(p, "dedent"):
                    advance(p)
    else:
        consume_nl(p)

    ast.ast_open(ref_of(p.ast_buf), "ConstDecl")
    ast.ast_str(ref_of(p.ast_buf), "name", cname)
    if const_type.len == 0:
        ast.ast_null(ref_of(p.ast_buf), "type")
    else:
        ast.ast_raw(ref_of(p.ast_buf), "type", const_type.as_str())
    const_type.release()
    if const_value.len == 0:
        ast.ast_null(ref_of(p.ast_buf), "value")
    else:
        ast.ast_raw(ref_of(p.ast_buf), "value", const_value.as_str())
    const_value.release()
    ast.ast_raw(ref_of(p.ast_buf), "block_body", block_body_json.as_str())
    block_body_json.release()
    ast.ast_visibility(ref_of(p.ast_buf), "visibility", vis)
    emit_attrs(p)
    ast.ast_null(ref_of(p.ast_buf), "line")
    ast.ast_null(ref_of(p.ast_buf), "column")
    ast.ast_close(ref_of(p.ast_buf))

# ── var ───────────────────────────────────────────────────────────────────

function parse_var(p: ref[Parser]) -> void:
    parse_var_with_visibility(p, "")

function parse_var_with_visibility(p: ref[Parser], vis: str) -> void:
    advance(p)
    let vname = peek_lexeme(p)
    advance(p)

    var var_type = parse_type_annotation_capture(p)

    var var_value = string_mod.String.create()
    if check(p, "equal"):
        advance(p)
        var_value.release()
        var_value = parse_expr(p)

    consume_nl(p)

    ast.ast_open(ref_of(p.ast_buf), "VarDecl")
    ast.ast_str(ref_of(p.ast_buf), "name", vname)
    if var_type.len == 0:
        ast.ast_null(ref_of(p.ast_buf), "type")
    else:
        ast.ast_raw(ref_of(p.ast_buf), "type", var_type.as_str())
    var_type.release()
    if var_value.len == 0:
        ast.ast_null(ref_of(p.ast_buf), "value")
    else:
        ast.ast_raw(ref_of(p.ast_buf), "value", var_value.as_str())
    var_value.release()
    ast.ast_visibility(ref_of(p.ast_buf), "visibility", vis)
    ast.ast_null(ref_of(p.ast_buf), "line")
    ast.ast_null(ref_of(p.ast_buf), "column")
    ast.ast_close(ref_of(p.ast_buf))

# ── type alias ────────────────────────────────────────────────────────────

function parse_type_alias(p: ref[Parser]) -> void:
    parse_type_alias_with_visibility(p, "")

function parse_type_alias_with_visibility(p: ref[Parser], vis: str) -> void:
    advance(p)
    let tname = peek_lexeme(p)
    advance(p)
    consume(p, "equal", "expected = in type alias")
    var alias_target = parse_type(p)

    consume_nl(p)

    ast.ast_open(ref_of(p.ast_buf), "TypeAliasDecl")
    ast.ast_str(ref_of(p.ast_buf), "name", tname)
    ast.ast_raw(ref_of(p.ast_buf), "target", alias_target.as_str())
    alias_target.release()
    ast.ast_visibility(ref_of(p.ast_buf), "visibility", vis)
    ast.ast_null(ref_of(p.ast_buf), "line")
    ast.ast_null(ref_of(p.ast_buf), "column")
    ast.ast_close(ref_of(p.ast_buf))

# ── function ──────────────────────────────────────────────────────────────

function parse_function_def(p: ref[Parser]) -> void:
    parse_function_with_visibility(p, "", false)

function parse_function_with_visibility(p: ref[Parser], vis: str, is_const: bool) -> void:
    var is_async = false
    if check(p, "async"):
        advance(p)
        is_async = true

    consume(p, "function", "expected function")

    let fname = peek_lexeme(p)

    if fname == "":
        fatal(c"parse: expected function name")

    advance(p)

    ast.ast_open(ref_of(p.ast_buf), "FunctionDef")
    ast.ast_str(ref_of(p.ast_buf), "name", fname)

    parse_type_params(p)
    parse_params_ast(p)

    var ret_type = string_mod.String.create()
    if check(p, "arrow"):
        advance(p)
        ret_type.release()
        ret_type = parse_type(p)

    if ret_type.len == 0:
        ast.ast_null(ref_of(p.ast_buf), "return_type")
    else:
        ast.ast_raw(ref_of(p.ast_buf), "return_type", ret_type.as_str())
    ret_type.release()

    var body_json = string_mod.String.create()
    body_json.append("[]")
    if check(p, "colon"):
        advance(p)
        consume_nl(p)
        if check(p, "indent"):
            advance(p)
            let body_start = p.tokens.pos
            var bdepth: ptr_uint = 1
            while not is_eof(p):
                if check(p, "indent"):
                    bdepth += 1
                    advance(p)
                else if check(p, "dedent"):
                    bdepth -= 1
                    if bdepth == 0:
                        break
                    advance(p)
                else:
                    advance(p)
            let body_end = p.tokens.pos
            p.tokens.pos = body_start
            p.stmt_failed = false
            body_json.release()
            body_json = parse_stmt_block_body(p)
            if p.stmt_failed or p.tokens.pos != body_end:
                body_json.release()
                body_json = string_mod.String.create()
                body_json.append("[]")
            p.tokens.pos = body_end
            if check(p, "dedent"):
                advance(p)
    else:
        consume_nl(p)

    ast.ast_raw(ref_of(p.ast_buf), "body", body_json.as_str())
    body_json.release()

    ast.ast_visibility(ref_of(p.ast_buf), "visibility", vis)
    ast.ast_bool(ref_of(p.ast_buf), "async", is_async)
    ast.ast_bool(ref_of(p.ast_buf), "const", is_const)
    emit_attrs(p)
    ast.ast_null(ref_of(p.ast_buf), "line")
    ast.ast_null(ref_of(p.ast_buf), "column")
    ast.ast_close(ref_of(p.ast_buf))

# ── extern / foreign / struct / enum / flags ──────────────────────────────

function parse_extern_function(p: ref[Parser]) -> void:
    advance(p)  # external
    consume(p, "function", "expected function after external")
    let fname = peek_lexeme(p)
    advance(p)

    var params_json = string_mod.String.create()
    params_json.push_byte('[')
    var pfirst = true
    if check(p, "lparen"):
        advance(p)
        while not check(p, "rparen") and not is_eof(p):
            let pname = peek_lexeme(p)
            advance(p)
            consume(p, "colon", "expected : in param")
            var ptype = parse_type(p)
            if not pfirst:
                params_json.push_byte(',')
            pfirst = false
            params_json.append("{\"$mt_type\":\"AST:ForeignParam\",\"name\":")
            var pe = lexer_mod.json_escaped(pname)
            params_json.append(pe.as_str())
            pe.release()
            params_json.append(",\"type\":")
            params_json.append(ptype.as_str())
            ptype.release()
            params_json.append(",\"mode\":{\"$sym\":\"plain\"},\"boundary_type\":null}")
            if check(p, "comma"):
                advance(p)
        consume(p, "rparen", "expected ) after params")
    params_json.push_byte(']')

    var ret_json = string_mod.String.create()
    if check(p, "arrow"):
        advance(p)
        ret_json.release()
        ret_json = parse_type(p)
    else:
        ret_json.append("null")

    consume_nl(p)

    ast.ast_open(ref_of(p.ast_buf), "ExternFunctionDecl")
    ast.ast_str(ref_of(p.ast_buf), "name", fname)
    ast.ast_array_start(ref_of(p.ast_buf), "type_params")
    ast.ast_array_end(ref_of(p.ast_buf))
    ast.ast_raw(ref_of(p.ast_buf), "params", params_json.as_str())
    params_json.release()
    ast.ast_raw(ref_of(p.ast_buf), "return_type", ret_json.as_str())
    ret_json.release()
    ast.ast_bool(ref_of(p.ast_buf), "variadic", false)
    emit_attrs(p)
    ast.ast_null(ref_of(p.ast_buf), "line")
    ast.ast_null(ref_of(p.ast_buf), "mapping")
    ast.ast_close(ref_of(p.ast_buf))

function parse_foreign_function(p: ref[Parser]) -> void:
    parse_foreign_function_with_visibility(p, "")

function parse_foreign_function_with_visibility(p: ref[Parser], vis: str) -> void:
    advance(p)  # foreign
    consume(p, "function", "expected function after foreign")
    let fname = peek_lexeme(p)
    advance(p)

    parse_params_skip(p)
    if check(p, "arrow"):
        advance(p)
        advance(p)

    consume(p, "equal", "expected = in foreign")
    let mapping_name = peek_lexeme(p)
    advance(p)
    consume_nl(p)

    ast.ast_open(ref_of(p.ast_buf), "ForeignFunctionDecl")
    ast.ast_str(ref_of(p.ast_buf), "name", fname)
    ast.ast_array_start(ref_of(p.ast_buf), "type_params")
    ast.ast_array_end(ref_of(p.ast_buf))
    ast.ast_array_start(ref_of(p.ast_buf), "params")
    ast.ast_array_end(ref_of(p.ast_buf))
    ast.ast_null(ref_of(p.ast_buf), "return_type")
    ast.ast_bool(ref_of(p.ast_buf), "variadic", false)
    ast.ast_str(ref_of(p.ast_buf), "mapping", mapping_name)
    ast.ast_visibility(ref_of(p.ast_buf), "visibility", vis)
    emit_attrs(p)
    ast.ast_null(ref_of(p.ast_buf), "line")
    ast.ast_close(ref_of(p.ast_buf))

function parse_impl_qualname_json(p: ref[Parser]) -> string_mod.String:
    var parts = vec_mod.Vec[str].create()
    parts.push(peek_lexeme(p))
    advance(p)
    while check(p, "dot"):
        advance(p)
        parts.push(peek_lexeme(p))
        advance(p)
    var targs = string_mod.String.create()
    targs.push_byte('[')
    if check(p, "lbracket"):
        advance(p)
        var tfirst = true
        var tsafety: ptr_uint = 0
        while not check(p, "rbracket") and not is_eof(p):
            tsafety += 1
            if tsafety > 10000:
                break
            if not tfirst:
                targs.push_byte(',')
            tfirst = false
            var t = parse_type(p)
            targs.append(t.as_str())
            t.release()
            if check(p, "comma"):
                advance(p)
        consume(p, "rbracket", "expected ] after interface type args")
    targs.push_byte(']')
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:QualifiedName\",\"parts\":[")
    var i: ptr_uint = 0
    while i < parts.len:
        let pp = parts.at(i) else:
            break
        if i > 0:
            r.push_byte(',')
        var e = lexer_mod.json_escaped(pp)
        r.append(e.as_str())
        e.release()
        i += 1
    r.append("],\"type_arguments\":")
    r.append(targs.as_str())
    targs.release()
    r.append(",\"line\":null,\"column\":null}")
    parts.release()
    return r

function parse_fields_json(p: ref[Parser]) -> string_mod.String:
    var r = string_mod.String.create()
    r.push_byte('[')
    var first = true
    skip_newlines(p)
    var safety: ptr_uint = 0
    while not check(p, "dedent") and not is_eof(p):
        safety += 1
        if safety > 100000:
            break
        let k = peek_kind(p)
        if k == "struct" or k == "enum" or k == "union" or k == "variant" or k == "flags" or k == "opaque" or k == "event" or k == "at" or k == "indent":
            skip_statement(p)
        else:
            let fname = peek_lexeme(p)
            advance(p)
            if check(p, "colon"):
                advance(p)
                var ft = parse_type(p)
                if not first:
                    r.push_byte(',')
                first = false
                r.append("{\"$mt_type\":\"AST:Field\",\"name\":")
                var ne = lexer_mod.json_escaped(fname)
                r.append(ne.as_str())
                ne.release()
                r.append(",\"type\":")
                r.append(ft.as_str())
                ft.release()
                r.append(",\"attributes\":[],\"line\":null,\"column\":null}")
                if check(p, "newline"):
                    advance(p)
            else:
                skip_to_stmt_end(p)
        skip_newlines(p)
    r.push_byte(']')
    return r

function parse_struct(p: ref[Parser]) -> void:
    parse_struct_with_visibility(p, "")

function parse_struct_with_visibility(p: ref[Parser], vis: str) -> void:
    advance(p)
    let sname = peek_lexeme(p)
    advance(p)

    var lifetime_json = string_mod.String.create()
    var struct_tp = string_mod.String.create()
    parse_struct_params(p, ref_of(struct_tp), ref_of(lifetime_json))

    var implements_json = string_mod.String.create()
    implements_json.push_byte('[')
    var first_impl = true
    if check(p, "implements"):
        advance(p)
        var isafety: ptr_uint = 0
        while true:
            isafety += 1
            if isafety > 10000:
                break
            if not first_impl:
                implements_json.push_byte(',')
            first_impl = false
            var qn = parse_impl_qualname_json(p)
            implements_json.append(qn.as_str())
            qn.release()
            if check(p, "comma"):
                advance(p)
            else:
                break
    implements_json.push_byte(']')

    var body_start: ptr_uint = 0
    var body_end: ptr_uint = 0
    var has_body = false
    var fields_json = string_mod.String.create()
    fields_json.append("[]")

    if check(p, "colon"):
        advance(p)
        consume_nl(p)
        if check(p, "indent"):
            advance(p)
            has_body = true
            body_start = p.tokens.pos
            var bdepth: ptr_uint = 1
            while not is_eof(p):
                if check(p, "indent"):
                    bdepth += 1
                    advance(p)
                else if check(p, "dedent"):
                    bdepth -= 1
                    if bdepth == 0:
                        break
                    advance(p)
                else:
                    advance(p)
            body_end = p.tokens.pos

    ast.ast_open(ref_of(p.ast_buf), "StructDecl")
    ast.ast_str(ref_of(p.ast_buf), "name", sname)
    ast.ast_raw(ref_of(p.ast_buf), "type_params", struct_tp.as_str())
    struct_tp.release()
    ast.ast_raw(ref_of(p.ast_buf), "implements", implements_json.as_str())
    ast.ast_null(ref_of(p.ast_buf), "c_name")

    if has_body:
        p.tokens.pos = body_start
        fields_json.release()
        fields_json = parse_fields_json(p)

    ast.ast_raw(ref_of(p.ast_buf), "fields", fields_json.as_str())
    fields_json.release()

    if has_body:
        var saved_packed = p.pending_packed
        var saved_has_align = p.has_pending_alignment
        var saved_align = p.pending_alignment
        var saved_attrs = string_mod.String.create()
        saved_attrs.append(p.pending_attrs.as_str())

        p.tokens.pos = body_start
        ast.ast_array_start(ref_of(p.ast_buf), "events")
        var efirst = true
        while p.tokens.pos < body_end and not is_eof(p):
            skip_newlines(p)
            if p.tokens.pos >= body_end:
                break
            if check(p, "event"):
                if not efirst:
                    ast.ast_comma(ref_of(p.ast_buf))
                efirst = false
                parse_event(p)
            else if check(p, "public") and peek_kind2(p) == "event":
                advance(p)
                if not efirst:
                    ast.ast_comma(ref_of(p.ast_buf))
                efirst = false
                parse_event_with_visibility(p, "public")
            else:
                skip_statement(p)
        ast.ast_array_end(ref_of(p.ast_buf))

        p.tokens.pos = body_start
        ast.ast_array_start(ref_of(p.ast_buf), "nested_types")
        var nfirst = true
        while p.tokens.pos < body_end and not is_eof(p):
            skip_newlines(p)
            if p.tokens.pos >= body_end:
                break
            p.pending_packed = false
            p.has_pending_alignment = false
            p.pending_attrs.clear()
            p.pending_attrs.push_byte('[')
            var attrs_first = true
            while check(p, "at"):
                advance(p)
                if check(p, "lbracket"):
                    advance(p)
                    while not check(p, "rbracket") and not is_eof(p):
                        if check(p, "identifier"):
                            let alx = peek_lexeme(p)
                            if not attrs_first:
                                p.pending_attrs.push_byte(',')
                            attrs_first = false
                            p.pending_attrs.append("{\"$mt_type\":\"AST:AttributeApplication\",\"name\":")
                            var aname = qname_single_json(alx)
                            p.pending_attrs.append(aname.as_str())
                            aname.release()
                            p.pending_attrs.append(",\"arguments\":[")
                            advance(p)
                            if alx == "packed":
                                p.pending_packed = true
                            var arg_first = true
                            if check(p, "lparen"):
                                advance(p)
                                while not check(p, "rparen") and not is_eof(p):
                                    if not arg_first:
                                        p.pending_attrs.push_byte(',')
                                    arg_first = false
                                    if check(p, "integer"):
                                        let ilex = peek_lexeme(p)
                                        var il = int_lit_json(ilex)
                                        p.pending_attrs.append(il.as_str())
                                        il.release()
                                        advance(p)
                                        if alx == "align" or alx == "alignment":
                                            let al = lexer_mod.parse_int(ilex)
                                            p.pending_alignment = ptr_uint<-al
                                            p.has_pending_alignment = true
                                    else:
                                        advance(p)
                                    if check(p, "comma"):
                                        advance(p)
                                if check(p, "rparen"):
                                    advance(p)
                            p.pending_attrs.append("],\"line\":null,\"column\":null}")
                            if check(p, "comma"):
                                advance(p)
                        else:
                            advance(p)
                    if check(p, "rbracket"):
                        advance(p)
                skip_newlines(p)
            p.pending_attrs.push_byte(']')
            let k = peek_kind(p)
            if k == "struct":
                if not nfirst:
                    ast.ast_comma(ref_of(p.ast_buf))
                nfirst = false
                parse_struct_with_visibility(p, "")
            else if k == "enum":
                if not nfirst:
                    ast.ast_comma(ref_of(p.ast_buf))
                nfirst = false
                parse_enum_with_visibility(p, "", false)
            else if k == "flags":
                if not nfirst:
                    ast.ast_comma(ref_of(p.ast_buf))
                nfirst = false
                parse_enum_with_visibility(p, "", true)
            else if k == "union":
                if not nfirst:
                    ast.ast_comma(ref_of(p.ast_buf))
                nfirst = false
                parse_union_with_visibility(p, "")
            else if k == "variant":
                if not nfirst:
                    ast.ast_comma(ref_of(p.ast_buf))
                nfirst = false
                parse_variant_with_visibility(p, "")
            else if k == "opaque":
                if not nfirst:
                    ast.ast_comma(ref_of(p.ast_buf))
                nfirst = false
                parse_opaque_with_visibility(p, "")
            else:
                skip_statement(p)
        ast.ast_array_end(ref_of(p.ast_buf))

        p.pending_packed = saved_packed
        p.has_pending_alignment = saved_has_align
        p.pending_alignment = saved_align
        p.pending_attrs.release()
        p.pending_attrs = saved_attrs

        p.tokens.pos = body_end
    else:
        ast.ast_array_start(ref_of(p.ast_buf), "events")
        ast.ast_array_end(ref_of(p.ast_buf))
        ast.ast_array_start(ref_of(p.ast_buf), "nested_types")
        ast.ast_array_end(ref_of(p.ast_buf))

    if check(p, "dedent"):
        advance(p)

    emit_attrs(p)
    ast.ast_bool(ref_of(p.ast_buf), "packed", p.pending_packed)
    p.pending_packed = false
    if p.has_pending_alignment:
        let al = p.pending_alignment
        ast.ast_key(ref_of(p.ast_buf), "alignment")
        fmt.append_ptr_uint(ref_of(p.ast_buf.buf), al)
        p.has_pending_alignment = false
    else:
        ast.ast_null(ref_of(p.ast_buf), "alignment")
    ast.ast_visibility(ref_of(p.ast_buf), "visibility", vis)
    ast.ast_raw(ref_of(p.ast_buf), "lifetime_params", lifetime_json.as_str())
    lifetime_json.release()
    ast.ast_null(ref_of(p.ast_buf), "line")
    ast.ast_null(ref_of(p.ast_buf), "column")
    ast.ast_close(ref_of(p.ast_buf))
    implements_json.release()

function backing_type_json(name: str) -> string_mod.String:
    var parts = vec_mod.Vec[str].create()
    parts.push(name)
    var nm = ast.name_json(parts)
    parts.release()
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:TypeRef\",\"name\":")
    r.append(nm.as_str())
    nm.release()
    r.append(",\"arguments\":[],\"nullable\":false,\"lifetime\":null,\"line\":null,\"column\":null,\"length\":null}")
    return r

function parse_enum_members_json(p: ref[Parser]) -> string_mod.String:
    var r = string_mod.String.create()
    r.push_byte('[')
    var first = true
    var failed = false
    var auto_value: ulong = 0
    skip_newlines(p)
    var safety: ptr_uint = 0
    while not check(p, "dedent") and not is_eof(p):
        safety += 1
        if safety > 100000:
            failed = true
            break
        let mname = peek_lexeme(p)
        advance(p)
        if not first:
            r.push_byte(',')
        first = false
        r.append("{\"$mt_type\":\"AST:EnumMember\",\"name\":")
        var ne = lexer_mod.json_escaped(mname)
        r.append(ne.as_str())
        ne.release()
        r.append(",\"value\":")
        if check(p, "equal"):
            advance(p)
            if check(p, "integer") and (peek_kind2(p) == "newline" or peek_kind2(p) == "dedent" or peek_kind2(p) == "eof"):
                let lex = peek_lexeme(p)
                var il = int_lit_json(lex)
                r.append(il.as_str())
                il.release()
                auto_value = lexer_mod.parse_int(lex) + 1
                advance(p)
            else:
                var v = parse_expr(p)
                r.append(v.as_str())
                v.release()
        else:
            var vbuf = string_mod.String.create()
            fmt.append_ulong(ref_of(vbuf), auto_value)
            r.append("{\"$mt_type\":\"AST:IntegerLiteral\",\"lexeme\":\"")
            r.append(vbuf.as_str())
            r.append("\",\"value\":")
            r.append(vbuf.as_str())
            r.push_byte('}')
            vbuf.release()
            auto_value += 1
        r.append(",\"line\":null,\"column\":null}")
        if check(p, "newline"):
            advance(p)
        else if not check(p, "dedent") and not is_eof(p):
            failed = true
            skip_to_stmt_end(p)
        skip_newlines(p)
    r.push_byte(']')
    if failed or p.stmt_failed:
        r.release()
        var empty = string_mod.String.create()
        empty.append("[]")
        return empty
    return r

function parse_enum_or_flags(p: ref[Parser], is_flags: bool) -> void:
    advance(p)
    let ename = peek_lexeme(p)
    advance(p)

    var backing = string_mod.String.create()
    backing.append("int")

    if check(p, "colon"):
        advance(p)
        if check(p, "identifier"):
            backing.clear()
            backing.append(peek_lexeme(p))
            advance(p)

    consume_nl(p)
    var members_json = string_mod.String.create()
    members_json.append("[]")
    if check(p, "indent"):
        advance(p)
        let body_start = p.tokens.pos
        var bdepth: ptr_uint = 1
        while not is_eof(p):
            if check(p, "indent"):
                bdepth += 1
                advance(p)
            else if check(p, "dedent"):
                bdepth -= 1
                if bdepth == 0:
                    break
                advance(p)
            else:
                advance(p)
        let body_end = p.tokens.pos
        p.tokens.pos = body_start
        p.stmt_failed = false
        members_json.release()
        members_json = parse_enum_members_json(p)
        if p.tokens.pos != body_end:
            members_json.release()
            members_json = string_mod.String.create()
            members_json.append("[]")
        p.tokens.pos = body_end
        if check(p, "dedent"):
            advance(p)

    let decl_type = if is_flags: "FlagsDecl" else: "EnumDecl"
    ast.ast_open(ref_of(p.ast_buf), decl_type)
    ast.ast_str(ref_of(p.ast_buf), "name", ename)
    var bt = backing_type_json(backing.as_str())
    ast.ast_raw(ref_of(p.ast_buf), "backing_type", bt.as_str())
    bt.release()
    ast.ast_raw(ref_of(p.ast_buf), "members", members_json.as_str())
    members_json.release()
    ast.ast_visibility(ref_of(p.ast_buf), "visibility", "")
    emit_attrs(p)
    ast.ast_null(ref_of(p.ast_buf), "line")
    ast.ast_null(ref_of(p.ast_buf), "column")
    ast.ast_close(ref_of(p.ast_buf))
    backing.release()

function parse_enum_with_visibility(p: ref[Parser], vis: str, is_flags: bool) -> void:
    advance(p)
    let ename = peek_lexeme(p)
    advance(p)

    var backing = string_mod.String.create()
    backing.append("int")
    if check(p, "colon"):
        advance(p)
        if check(p, "identifier"):
            backing.clear()
            backing.append(peek_lexeme(p))
            advance(p)

    consume_nl(p)
    var members_json = string_mod.String.create()
    members_json.append("[]")
    if check(p, "indent"):
        advance(p)
        let body_start = p.tokens.pos
        var bdepth: ptr_uint = 1
        while not is_eof(p):
            if check(p, "indent"):
                bdepth += 1
                advance(p)
            else if check(p, "dedent"):
                bdepth -= 1
                if bdepth == 0:
                    break
                advance(p)
            else:
                advance(p)
        let body_end = p.tokens.pos
        p.tokens.pos = body_start
        p.stmt_failed = false
        members_json.release()
        members_json = parse_enum_members_json(p)
        if p.tokens.pos != body_end:
            members_json.release()
            members_json = string_mod.String.create()
            members_json.append("[]")
        p.tokens.pos = body_end
        if check(p, "dedent"):
            advance(p)

    let decl_type = if is_flags: "FlagsDecl" else: "EnumDecl"
    ast.ast_open(ref_of(p.ast_buf), decl_type)
    ast.ast_str(ref_of(p.ast_buf), "name", ename)
    var bt = backing_type_json(backing.as_str())
    ast.ast_raw(ref_of(p.ast_buf), "backing_type", bt.as_str())
    bt.release()
    ast.ast_raw(ref_of(p.ast_buf), "members", members_json.as_str())
    members_json.release()
    ast.ast_visibility(ref_of(p.ast_buf), "visibility", vis)
    emit_attrs(p)
    ast.ast_null(ref_of(p.ast_buf), "line")
    ast.ast_null(ref_of(p.ast_buf), "column")
    ast.ast_close(ref_of(p.ast_buf))
    backing.release()

# ── union / variant / opaque / interface / extending ──────────────────────

function parse_union(p: ref[Parser]) -> void:
    parse_union_with_visibility(p, "")

function parse_union_with_visibility(p: ref[Parser], vis: str) -> void:
    advance(p)
    let uname = peek_lexeme(p)
    advance(p)

    var fields_json = string_mod.String.create()
    fields_json.append("[]")
    if check(p, "colon"):
        advance(p)
        consume_nl(p)
        if check(p, "indent"):
            advance(p)
            let body_start = p.tokens.pos
            var bdepth: ptr_uint = 1
            while not is_eof(p):
                if check(p, "indent"):
                    bdepth += 1
                    advance(p)
                else if check(p, "dedent"):
                    bdepth -= 1
                    if bdepth == 0:
                        break
                    advance(p)
                else:
                    advance(p)
            let body_end = p.tokens.pos
            p.tokens.pos = body_start
            fields_json.release()
            fields_json = parse_fields_json(p)
            if p.tokens.pos != body_end:
                fields_json.release()
                fields_json = string_mod.String.create()
                fields_json.append("[]")
            p.tokens.pos = body_end
            if check(p, "dedent"):
                advance(p)

    ast.ast_open(ref_of(p.ast_buf), "UnionDecl")
    ast.ast_str(ref_of(p.ast_buf), "name", uname)
    ast.ast_null(ref_of(p.ast_buf), "c_name")
    ast.ast_raw(ref_of(p.ast_buf), "fields", fields_json.as_str())
    fields_json.release()
    ast.ast_visibility(ref_of(p.ast_buf), "visibility", vis)
    emit_attrs(p)
    ast.ast_null(ref_of(p.ast_buf), "line")
    ast.ast_null(ref_of(p.ast_buf), "column")
    ast.ast_close(ref_of(p.ast_buf))

function parse_variant(p: ref[Parser]) -> void:
    parse_variant_with_visibility(p, "")

function parse_variant_arms_json(p: ref[Parser]) -> string_mod.String:
    var r = string_mod.String.create()
    r.push_byte('[')
    var first = true
    var failed = false
    skip_newlines(p)
    var safety: ptr_uint = 0
    while not check(p, "dedent") and not is_eof(p):
        safety += 1
        if safety > 100000:
            failed = true
            break
        let aname = peek_lexeme(p)
        advance(p)
        if not first:
            r.push_byte(',')
        first = false
        r.append("{\"$mt_type\":\"AST:VariantArm\",\"name\":")
        var ane = lexer_mod.json_escaped(aname)
        r.append(ane.as_str())
        ane.release()
        r.append(",\"fields\":[")
        if check(p, "lparen"):
            advance(p)
            var ffirst = true
            var fsafety: ptr_uint = 0
            while not check(p, "rparen") and not is_eof(p):
                fsafety += 1
                if fsafety > 100000:
                    failed = true
                    break
                let fname = peek_lexeme(p)
                advance(p)
                consume(p, "colon", "expected : in variant field")
                var ft = parse_type(p)
                if not ffirst:
                    r.push_byte(',')
                ffirst = false
                r.append("{\"$mt_type\":\"AST:Field\",\"name\":")
                var fne = lexer_mod.json_escaped(fname)
                r.append(fne.as_str())
                fne.release()
                r.append(",\"type\":")
                r.append(ft.as_str())
                ft.release()
                r.append(",\"attributes\":[],\"line\":null,\"column\":null}")
                if check(p, "comma"):
                    advance(p)
            consume(p, "rparen", "expected ) after variant fields")
        r.append("]}")
        if check(p, "newline"):
            advance(p)
        else if not check(p, "dedent") and not is_eof(p):
            failed = true
            skip_to_stmt_end(p)
        skip_newlines(p)
    r.push_byte(']')
    if failed or p.stmt_failed:
        r.release()
        var empty = string_mod.String.create()
        empty.append("[]")
        return empty
    return r

function parse_variant_with_visibility(p: ref[Parser], vis: str) -> void:
    advance(p)
    let vname = peek_lexeme(p)
    advance(p)

    if check(p, "lbracket"):
        advance(p)
        while not check(p, "rbracket") and not is_eof(p):
            advance(p)
        advance(p)

    var arms_json = string_mod.String.create()
    arms_json.append("[]")
    if check(p, "colon"):
        advance(p)
        consume_nl(p)
        if check(p, "indent"):
            advance(p)
            let body_start = p.tokens.pos
            var bdepth: ptr_uint = 1
            while not is_eof(p):
                if check(p, "indent"):
                    bdepth += 1
                    advance(p)
                else if check(p, "dedent"):
                    bdepth -= 1
                    if bdepth == 0:
                        break
                    advance(p)
                else:
                    advance(p)
            let body_end = p.tokens.pos
            p.tokens.pos = body_start
            p.stmt_failed = false
            arms_json.release()
            arms_json = parse_variant_arms_json(p)
            if p.tokens.pos != body_end:
                arms_json.release()
                arms_json = string_mod.String.create()
                arms_json.append("[]")
            p.tokens.pos = body_end
            if check(p, "dedent"):
                advance(p)

    ast.ast_open(ref_of(p.ast_buf), "VariantDecl")
    ast.ast_str(ref_of(p.ast_buf), "name", vname)
    ast.ast_array_start(ref_of(p.ast_buf), "type_params")
    ast.ast_array_end(ref_of(p.ast_buf))
    ast.ast_raw(ref_of(p.ast_buf), "arms", arms_json.as_str())
    arms_json.release()
    ast.ast_visibility(ref_of(p.ast_buf), "visibility", vis)
    emit_attrs(p)
    ast.ast_null(ref_of(p.ast_buf), "line")
    ast.ast_null(ref_of(p.ast_buf), "column")
    ast.ast_close(ref_of(p.ast_buf))

function parse_opaque(p: ref[Parser]) -> void:
    parse_opaque_with_visibility(p, "")

function parse_opaque_with_visibility(p: ref[Parser], vis: str) -> void:
    advance(p)
    let oname = peek_lexeme(p)
    advance(p)

    while check(p, "implements"):
        advance(p)
        while check(p, "identifier"):
            advance(p)
            if check(p, "and"):
                advance(p)
            else:
                break

    consume_nl(p)

    ast.ast_open(ref_of(p.ast_buf), "OpaqueDecl")
    ast.ast_str(ref_of(p.ast_buf), "name", oname)
    ast.ast_array_start(ref_of(p.ast_buf), "implements")
    ast.ast_array_end(ref_of(p.ast_buf))
    ast.ast_null(ref_of(p.ast_buf), "c_name")
    ast.ast_visibility(ref_of(p.ast_buf), "visibility", vis)
    ast.ast_null(ref_of(p.ast_buf), "line")
    ast.ast_null(ref_of(p.ast_buf), "column")
    ast.ast_close(ref_of(p.ast_buf))

function parse_interface(p: ref[Parser]) -> void:
    parse_interface_with_visibility(p, "")

function parse_interface_with_visibility(p: ref[Parser], vis: str) -> void:
    advance(p)
    let iname = peek_lexeme(p)
    advance(p)

    var iface_tp = parse_type_params_json(p)

    ast.ast_open(ref_of(p.ast_buf), "InterfaceDecl")
    ast.ast_str(ref_of(p.ast_buf), "name", iname)
    ast.ast_raw(ref_of(p.ast_buf), "type_params", iface_tp.as_str())
    iface_tp.release()
    parse_method_block(p, true)
    ast.ast_visibility(ref_of(p.ast_buf), "visibility", vis)
    ast.ast_null(ref_of(p.ast_buf), "line")
    ast.ast_null(ref_of(p.ast_buf), "column")
    ast.ast_close(ref_of(p.ast_buf))

function parse_extending(p: ref[Parser]) -> void:
    advance(p)
    var type_name = parse_type(p)

    ast.ast_open(ref_of(p.ast_buf), "ExtendingBlock")
    ast.ast_raw(ref_of(p.ast_buf), "type_name", type_name.as_str())
    type_name.release()
    parse_method_block(p, false)
    ast.ast_null(ref_of(p.ast_buf), "line")
    ast.ast_null(ref_of(p.ast_buf), "column")
    ast.ast_close(ref_of(p.ast_buf))

# Parses the indented method block of an interface/extending declaration and
# emits the "methods" array directly into p.ast_buf. Crash-safe: the block's
# matching dedent is found up front and the cursor is snapped to it regardless
# of how individual methods parse, so the outer declaration parse is never
# corrupted. Each method node is emitted with no early return between
# ast_open/ast_close, so the JSON is always well-formed.
function parse_method_block(p: ref[Parser], is_interface: bool) -> void:
    ast.ast_array_start(ref_of(p.ast_buf), "methods")
    if check(p, "colon"):
        advance(p)
        consume_nl(p)
        if check(p, "indent"):
            advance(p)
            let body_start = p.tokens.pos
            var bdepth: ptr_uint = 1
            while not is_eof(p):
                if check(p, "indent"):
                    bdepth += 1
                    advance(p)
                else if check(p, "dedent"):
                    bdepth -= 1
                    if bdepth == 0:
                        break
                    advance(p)
                else:
                    advance(p)
            let body_end = p.tokens.pos
            p.tokens.pos = body_start
            var first = true
            while p.tokens.pos < body_end and not is_eof(p):
                if check(p, "newline"):
                    advance(p)
                else:
                    let k = peek_kind(p)
                    if k != "public" and k != "async" and k != "editable" and k != "static" and k != "function":
                        break
                    if not first:
                        ast.ast_comma(ref_of(p.ast_buf))
                    first = false
                    parse_one_method(p, is_interface)
            p.tokens.pos = body_end
            if check(p, "dedent"):
                advance(p)
    else:
        consume_nl(p)
    ast.ast_array_end(ref_of(p.ast_buf))

# Parses a single interface/extending method and emits one node.
# Interface methods -> InterfaceMethodDecl (no type_params, no body, no visibility).
# Extending methods -> MethodDef (with type_params, body, visibility).
function parse_one_method(p: ref[Parser], is_interface: bool) -> void:
    var vis = ""
    if check(p, "public"):
        advance(p)
        vis = "public"

    var is_async = false
    if check(p, "async"):
        advance(p)
        is_async = true

    var kind = "plain"
    if check(p, "editable"):
        advance(p)
        kind = "editable"
    else if check(p, "static"):
        advance(p)
        kind = "static"

    if check(p, "function"):
        advance(p)

    let mname = peek_lexeme(p)
    advance(p)

    if is_interface:
        ast.ast_open(ref_of(p.ast_buf), "InterfaceMethodDecl")
    else:
        ast.ast_open(ref_of(p.ast_buf), "MethodDef")
    ast.ast_str(ref_of(p.ast_buf), "name", mname)

    if not is_interface:
        parse_type_params(p)

    parse_params_ast(p)

    var ret_type = string_mod.String.create()
    if check(p, "arrow"):
        advance(p)
        ret_type.release()
        ret_type = parse_type(p)
    if ret_type.len == 0:
        ast.ast_null(ref_of(p.ast_buf), "return_type")
    else:
        ast.ast_raw(ref_of(p.ast_buf), "return_type", ret_type.as_str())
    ret_type.release()

    if not is_interface:
        var body_json = string_mod.String.create()
        body_json.append("[]")
        if check(p, "colon"):
            advance(p)
            consume_nl(p)
            if check(p, "indent"):
                advance(p)
                let body_start = p.tokens.pos
                var bdepth: ptr_uint = 1
                while not is_eof(p):
                    if check(p, "indent"):
                        bdepth += 1
                        advance(p)
                    else if check(p, "dedent"):
                        bdepth -= 1
                        if bdepth == 0:
                            break
                        advance(p)
                    else:
                        advance(p)
                let body_end = p.tokens.pos
                p.tokens.pos = body_start
                p.stmt_failed = false
                body_json.release()
                body_json = parse_stmt_block_body(p)
                if p.stmt_failed or p.tokens.pos != body_end:
                    body_json.release()
                    body_json = string_mod.String.create()
                    body_json.append("[]")
                p.tokens.pos = body_end
                if check(p, "dedent"):
                    advance(p)
        else:
            consume_nl(p)
        ast.ast_raw(ref_of(p.ast_buf), "body", body_json.as_str())
        body_json.release()

    ast.ast_sym(ref_of(p.ast_buf), "kind", kind)
    ast.ast_bool(ref_of(p.ast_buf), "async", is_async)

    if not is_interface:
        ast.ast_visibility(ref_of(p.ast_buf), "visibility", vis)

    emit_attrs(p)
    ast.ast_null(ref_of(p.ast_buf), "line")
    ast.ast_null(ref_of(p.ast_buf), "column")
    ast.ast_close(ref_of(p.ast_buf))

# ── attribute / static_assert / event ─────────────────────────────────────

function parse_attribute(p: ref[Parser]) -> void:
    advance(p)

    var targets = string_mod.String.create()
    targets.push_byte('[')
    var tfirst = true
    if check(p, "lbracket"):
        advance(p)
        while not check(p, "rbracket") and not is_eof(p):
            let tname = peek_lexeme(p)
            advance(p)
            if not tfirst:
                targets.push_byte(',')
            tfirst = false
            targets.append("{\"$sym\":\"")
            targets.append(tname)
            targets.push_byte('"')
            targets.push_byte('}')
            if check(p, "comma"):
                advance(p)
        consume(p, "rbracket", "expected ] after attribute targets")
    targets.push_byte(']')

    let aname = peek_lexeme(p)
    advance(p)

    var params = string_mod.String.create()
    params.push_byte('[')
    var pfirst = true
    if check(p, "lparen"):
        advance(p)
        while not check(p, "rparen") and not is_eof(p):
            let pname = peek_lexeme(p)
            advance(p)
            consume(p, "colon", "expected : in attribute param")
            var ptype = parse_type(p)
            if not pfirst:
                params.push_byte(',')
            pfirst = false
            params.append("{\"$mt_type\":\"AST:Param\",\"name\":")
            var pe = lexer_mod.json_escaped(pname)
            params.append(pe.as_str())
            pe.release()
            params.append(",\"type\":")
            params.append(ptype.as_str())
            ptype.release()
            params.append(",\"line\":null,\"column\":null}")
            if check(p, "comma"):
                advance(p)
        consume(p, "rparen", "expected ) after attribute params")
    params.push_byte(']')

    consume_nl(p)

    ast.ast_open(ref_of(p.ast_buf), "AttributeDecl")
    ast.ast_str(ref_of(p.ast_buf), "name", aname)
    ast.ast_raw(ref_of(p.ast_buf), "targets", targets.as_str())
    targets.release()
    ast.ast_raw(ref_of(p.ast_buf), "params", params.as_str())
    params.release()
    ast.ast_visibility(ref_of(p.ast_buf), "visibility", "")
    ast.ast_null(ref_of(p.ast_buf), "line")
    ast.ast_null(ref_of(p.ast_buf), "column")
    ast.ast_close(ref_of(p.ast_buf))

function parse_static_assert(p: ref[Parser]) -> void:
    advance(p)
    consume(p, "lparen", "expected (")
    var cond = parse_expr(p)
    consume(p, "comma", "expected , in static_assert")
    var msg = parse_expr(p)
    consume(p, "rparen", "expected ) after static_assert")
    consume_nl(p)

    ast.ast_open(ref_of(p.ast_buf), "StaticAssert")
    ast.ast_raw(ref_of(p.ast_buf), "condition", cond.as_str())
    cond.release()
    ast.ast_raw(ref_of(p.ast_buf), "message", msg.as_str())
    msg.release()
    ast.ast_null(ref_of(p.ast_buf), "line")
    ast.ast_close(ref_of(p.ast_buf))

function parse_event(p: ref[Parser]) -> void:
    parse_event_with_visibility(p, "")

function parse_event_with_visibility(p: ref[Parser], vis: str) -> void:
    advance(p)
    let evname = peek_lexeme(p)
    advance(p)

    consume(p, "lbracket", "expected [")
    let cap_lex = peek_lexeme(p)
    advance(p)
    consume(p, "rbracket", "expected ]")

    var payload = string_mod.String.create()
    var has_payload = false
    if check(p, "lparen"):
        advance(p)
        payload.release()
        payload = parse_type(p)
        has_payload = true
        consume(p, "rparen", "expected ) after event payload")

    consume_nl(p)

    let cap = int<-lexer_mod.parse_int(cap_lex)
    ast.ast_open(ref_of(p.ast_buf), "EventDecl")
    ast.ast_str(ref_of(p.ast_buf), "name", evname)
    ast.ast_int(ref_of(p.ast_buf), "capacity", cap)
    if has_payload:
        ast.ast_raw(ref_of(p.ast_buf), "payload_type", payload.as_str())
    else:
        ast.ast_null(ref_of(p.ast_buf), "payload_type")
    payload.release()
    ast.ast_visibility(ref_of(p.ast_buf), "visibility", vis)
    emit_attrs(p)
    ast.ast_null(ref_of(p.ast_buf), "line")
    ast.ast_null(ref_of(p.ast_buf), "column")
    ast.ast_close(ref_of(p.ast_buf))

function emit_attrs(p: ref[Parser]) -> void:
    if p.pending_attrs.len > 0:
        ast.ast_raw(ref_of(p.ast_buf), "attributes", p.pending_attrs.as_str())
        p.pending_attrs.clear()
    else:
        ast.ast_array_start(ref_of(p.ast_buf), "attributes")
        ast.ast_array_end(ref_of(p.ast_buf))

# ── helpers ───────────────────────────────────────────────────────────────

function parse_type_params_json(p: ref[Parser]) -> string_mod.String:
    var r = string_mod.String.create()
    r.push_byte('[')
    if check(p, "lbracket"):
        advance(p)
        var first = true
        var safety: ptr_uint = 0
        while not check(p, "rbracket") and not is_eof(p):
            safety += 1
            if safety > 10000:
                break
            if check(p, "at"):
                advance(p)
                advance(p)
                if check(p, "comma"):
                    advance(p)
                continue
            let pname = peek_lexeme(p)
            advance(p)
            if not first:
                r.push_byte(',')
            first = false
            if check(p, "colon"):
                advance(p)
                var vt = parse_type(p)
                r.append("{\"$mt_type\":\"AST:ValueTypeParam\",\"name\":")
                var ne = lexer_mod.json_escaped(pname)
                r.append(ne.as_str())
                ne.release()
                r.append(",\"type\":")
                r.append(vt.as_str())
                vt.release()
                r.append(",\"line\":null,\"column\":null,\"length\":null}")
            else:
                r.append("{\"$mt_type\":\"AST:TypeParam\",\"name\":")
                var ne = lexer_mod.json_escaped(pname)
                r.append(ne.as_str())
                ne.release()
                r.append(",\"constraints\":[")
                if check(p, "implements"):
                    advance(p)
                    var cfirst = true
                    var csafety: ptr_uint = 0
                    while true:
                        csafety += 1
                        if csafety > 1000:
                            break
                        if not cfirst:
                            r.push_byte(',')
                        cfirst = false
                        r.append("{\"$mt_type\":\"AST:TypeParamConstraint\",\"kind\":{\"$sym\":\"interface\"},\"interface_ref\":")
                        var iq = parse_impl_qualname_json(p)
                        r.append(iq.as_str())
                        iq.release()
                        r.push_byte('}')
                        if check(p, "and"):
                            advance(p)
                        else:
                            break
                r.append("],\"line\":null,\"column\":null,\"length\":null}")
            if check(p, "comma"):
                advance(p)
        consume(p, "rbracket", "expected ] after type params")
    r.push_byte(']')
    return r

function parse_struct_params(p: ref[Parser], tp_json: ref[string_mod.String], lp_json: ref[string_mod.String]) -> void:
    tp_json.push_byte('[')
    lp_json.push_byte('[')
    var lp_first = true
    if check(p, "lbracket"):
        advance(p)
        var first = true
        var safety: ptr_uint = 0
        while not check(p, "rbracket") and not is_eof(p):
            safety += 1
            if safety > 10000:
                break
            if check(p, "at"):
                advance(p)
                let lname = peek_lexeme(p)
                advance(p)
                if not lp_first:
                    lp_json.push_byte(',')
                lp_first = false
                lp_json.push_byte('"')
                lp_json.push_byte('@')
                lp_json.append(lname)
                lp_json.push_byte('"')
                if check(p, "comma"):
                    advance(p)
                while not is_eof(p) and not check(p, "rbracket") and not check(p, "comma"):
                    advance(p)
                continue
            let pname = peek_lexeme(p)
            advance(p)
            if not first:
                tp_json.push_byte(',')
            first = false
            if check(p, "colon"):
                advance(p)
                var vt = parse_type(p)
                tp_json.append("{\"$mt_type\":\"AST:ValueTypeParam\",\"name\":")
                var ne = lexer_mod.json_escaped(pname)
                tp_json.append(ne.as_str())
                ne.release()
                tp_json.append(",\"type\":")
                tp_json.append(vt.as_str())
                vt.release()
                tp_json.append(",\"line\":null,\"column\":null,\"length\":null}")
            else:
                tp_json.append("{\"$mt_type\":\"AST:TypeParam\",\"name\":")
                var ne = lexer_mod.json_escaped(pname)
                tp_json.append(ne.as_str())
                ne.release()
                tp_json.append(",\"constraints\":[")
                if check(p, "implements"):
                    advance(p)
                    var cfirst = true
                    var csafety: ptr_uint = 0
                    while true:
                        csafety += 1
                        if csafety > 1000:
                            break
                        if not cfirst:
                            tp_json.push_byte(',')
                        cfirst = false
                        var qn = parse_impl_qualname_json(p)
                        tp_json.append(qn.as_str())
                        qn.release()
                        if check(p, "comma"):
                            advance(p)
                        else:
                            break
                tp_json.append("],\"line\":null,\"column\":null,\"length\":null}")
            if check(p, "comma"):
                advance(p)
        consume(p, "rbracket", "expected ] after struct params")
    tp_json.push_byte(']')
    lp_json.push_byte(']')

function parse_type_params(p: ref[Parser]) -> void:
    var tj = parse_type_params_json(p)
    ast.ast_raw(ref_of(p.ast_buf), "type_params", tj.as_str())
    tj.release()

function parse_params_skip(p: ref[Parser]) -> void:
    if check(p, "lparen"):
        advance(p)
        var paren_d: ptr_uint = 1
        while paren_d > 0 and not is_eof(p):
            if check(p, "lparen"):
                paren_d += 1
            else if check(p, "rparen"):
                paren_d -= 1
            advance(p)

function parse_params_ast(p: ref[Parser]) -> void:
    ast.ast_array_start(ref_of(p.ast_buf), "params")
    if check(p, "lparen"):
        advance(p)
        var first = true
        while not is_eof(p) and not check(p, "rparen"):
            if not first:
                ast.ast_comma(ref_of(p.ast_buf))
            first = false

            let pname = peek_lexeme(p)
            advance(p)
            var ptype = string_mod.String.create()
            if check(p, "colon"):
                advance(p)
                ptype.release()
                ptype = parse_type(p)

            ast.ast_open(ref_of(p.ast_buf), "Param")
            ast.ast_str(ref_of(p.ast_buf), "name", pname)
            if ptype.len == 0:
                ast.ast_null(ref_of(p.ast_buf), "type")
            else:
                ast.ast_raw(ref_of(p.ast_buf), "type", ptype.as_str())
            ptype.release()
            ast.ast_null(ref_of(p.ast_buf), "line")
            ast.ast_null(ref_of(p.ast_buf), "column")
            ast.ast_close(ref_of(p.ast_buf))

            if check(p, "comma"):
                advance(p)

        if check(p, "rparen"):
            advance(p)
    ast.ast_array_end(ref_of(p.ast_buf))

# ── type expression parser ────────────────────────────────────────────────

function int_lit_json(lexeme: str) -> string_mod.String:
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:IntegerLiteral\",\"lexeme\":")
    var e = lexer_mod.json_escaped(lexeme)
    r.append(e.as_str())
    e.release()
    r.append(",\"value\":")
    let v = lexer_mod.parse_int(lexeme)
    fmt.append_ulong(ref_of(r), v)
    r.push_byte('}')
    return r

function float_lit_json(lexeme: str) -> string_mod.String:
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:FloatLiteral\",\"lexeme\":")
    var e = lexer_mod.json_escaped(lexeme)
    r.append(e.as_str())
    e.release()
    r.append(",\"value\":")
    var fv = lexer_mod.float_lit_json(lexeme)
    r.append(fv.as_str())
    fv.release()
    r.push_byte('}')
    return r

function peek_kind2(p: ref[Parser]) -> str:
    let tok = p.tokens.tokens.get(p.tokens.pos + 1) else:
        return "eof"
    return unsafe: read(tok).kind

function peek_kind3(p: ref[Parser]) -> str:
    let tok = p.tokens.tokens.get(p.tokens.pos + 2) else:
        return "eof"
    return unsafe: read(tok).kind

function bool_lit_json(val: str) -> string_mod.String:
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:BooleanLiteral\",\"value\":")
    r.append(val)
    r.push_byte('}')
    return r

function null_lit_json() -> string_mod.String:
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:NullLiteral\",\"type\":null,\"line\":null,\"column\":null}")
    return r

# Parses a const/var initializer only when it is a single standalone literal
# (integer/float/bool/null) terminating the line; returns empty otherwise so the
# caller leaves the value null until the full expression parser lands.
function parse_simple_value(p: ref[Parser]) -> string_mod.String:
    let k = peek_kind(p)
    let nxt = peek_kind2(p)
    if not (nxt == "newline" or nxt == "dedent" or nxt == "eof"):
        return string_mod.String.create()
    if k == "integer":
        var r = int_lit_json(peek_lexeme(p))
        advance(p)
        return r
    if k == "float":
        var r = float_lit_json(peek_lexeme(p))
        advance(p)
        return r
    if k == "true":
        advance(p)
        return bool_lit_json("true")
    if k == "false":
        advance(p)
        return bool_lit_json("false")
    if k == "null":
        advance(p)
        return null_lit_json()
    return string_mod.String.create()

# ── expression parser ─────────────────────────────────────────────────────

function peek_lit(p: ref[Parser]) -> str:
    let tok = p.tokens.peek() else:
        return "null"
    return unsafe: read(tok).lit_json.as_str()

function make_binop(op: str, left: str, right: str) -> string_mod.String:
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:BinaryOp\",\"operator\":")
    var oe = lexer_mod.json_escaped(op)
    r.append(oe.as_str())
    oe.release()
    r.append(",\"left\":")
    r.append(left)
    r.append(",\"right\":")
    r.append(right)
    r.push_byte('}')
    return r

function make_unaryop(op: str, operand: str) -> string_mod.String:
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:UnaryOp\",\"operator\":")
    var oe = lexer_mod.json_escaped(op)
    r.append(oe.as_str())
    oe.release()
    r.append(",\"operand\":")
    r.append(operand)
    r.push_byte('}')
    return r

function qname_single_json(name: str) -> string_mod.String:
    var parts = vec_mod.Vec[str].create()
    parts.push(name)
    var r = ast.name_json(parts)
    parts.release()
    return r

function ident_json(name: str) -> string_mod.String:
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:Identifier\",\"name\":")
    var ne = lexer_mod.json_escaped(name)
    r.append(ne.as_str())
    ne.release()
    r.append(",\"line\":null,\"column\":null}")
    return r

function make_member(receiver: str, member: str) -> string_mod.String:
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:MemberAccess\",\"receiver\":")
    r.append(receiver)
    r.append(",\"member\":")
    var me = lexer_mod.json_escaped(member)
    r.append(me.as_str())
    me.release()
    r.append(",\"line\":null,\"column\":null}")
    return r

function make_index(receiver: str, index: str) -> string_mod.String:
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:IndexAccess\",\"receiver\":")
    r.append(receiver)
    r.append(",\"index\":")
    r.append(index)
    r.push_byte('}')
    return r

function make_call(callee: str, args: str) -> string_mod.String:
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:Call\",\"callee\":")
    r.append(callee)
    r.append(",\"arguments\":")
    r.append(args)
    r.push_byte('}')
    return r

function str_lit_json(p: ref[Parser], is_c: bool) -> string_mod.String:
    let lexeme = peek_lexeme(p)
    let val = peek_lit(p)
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:StringLiteral\",\"lexeme\":")
    var le = lexer_mod.json_escaped(lexeme)
    r.append(le.as_str())
    le.release()
    r.append(",\"value\":")
    r.append(val)
    r.append(",\"cstring\":")
    if is_c:
        r.append("true")
    else:
        r.append("false")
    r.push_byte('}')
    advance(p)
    return r

function char_lit_json(p: ref[Parser]) -> string_mod.String:
    let lexeme = peek_lexeme(p)
    let val = peek_lit(p)
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:CharLiteral\",\"lexeme\":")
    var le = lexer_mod.json_escaped(lexeme)
    r.append(le.as_str())
    le.release()
    r.append(",\"value\":")
    r.append(val)
    r.append(",\"line\":null,\"column\":null}")
    advance(p)
    return r

function op_prec(k: str) -> int:
    if k == "or":
        return 1
    if k == "and":
        return 2
    if k == "pipe":
        return 4
    if k == "caret":
        return 5
    if k == "amp":
        return 6
    if k == "equal_equal" or k == "bang_equal":
        return 7
    if k == "less" or k == "less_equal" or k == "greater" or k == "greater_equal":
        return 8
    if k == "shift_left" or k == "shift_right":
        return 9
    if k == "plus" or k == "minus":
        return 10
    if k == "star" or k == "slash" or k == "percent":
        return 11
    return -1

function parse_call_args(p: ref[Parser]) -> string_mod.String:
    var r = string_mod.String.create()
    r.push_byte('[')
    var first = true
    while not check(p, "rparen") and not is_eof(p):
        if not first:
            r.push_byte(',')
        first = false
        var argname: str = ""
        if check(p, "identifier") and peek_kind2(p) == "equal":
            argname = peek_lexeme(p)
            advance(p)
            advance(p)
        r.append("{\"$mt_type\":\"AST:Argument\",\"name\":")
        if argname == "":
            r.append("null")
        else:
            var ae = lexer_mod.json_escaped(argname)
            r.append(ae.as_str())
            ae.release()
        r.append(",\"value\":")
        var v = parse_expr(p)
        r.append(v.as_str())
        v.release()
        r.push_byte('}')
        if check(p, "comma"):
            advance(p)
    consume(p, "rparen", "expected ) after call arguments")
    r.push_byte(']')
    return r

function parse_paren_elem(p: ref[Parser]) -> string_mod.String:
    if check(p, "identifier") and peek_kind2(p) == "equal":
        let nm = peek_lexeme(p)
        advance(p)
        advance(p)
        var v = parse_expr(p)
        var r = string_mod.String.create()
        r.append("{\"$mt_type\":\"AST:Argument\",\"name\":")
        var ne = lexer_mod.json_escaped(nm)
        r.append(ne.as_str())
        ne.release()
        r.append(",\"value\":")
        r.append(v.as_str())
        v.release()
        r.push_byte('}')
        return r
    return parse_expr(p)

function parse_paren_or_tuple(p: ref[Parser]) -> string_mod.String:
    advance(p)
    var first = parse_paren_elem(p)
    if check(p, "comma"):
        var elems = string_mod.String.create()
        elems.push_byte('[')
        elems.append(first.as_str())
        first.release()
        while check(p, "comma"):
            advance(p)
            if check(p, "rparen"):
                break
            elems.push_byte(',')
            var e = parse_paren_elem(p)
            elems.append(e.as_str())
            e.release()
        elems.push_byte(']')
        consume(p, "rparen", "expected ) after tuple elements")
        var r = string_mod.String.create()
        r.append("{\"$mt_type\":\"AST:ExpressionList\",\"elements\":")
        r.append(elems.as_str())
        elems.release()
        r.append(",\"line\":null,\"column\":null}")
        return r
    consume(p, "rparen", "expected ) after expression")
    return first

function parse_primary_expr(p: ref[Parser]) -> string_mod.String:
    let k = peek_kind(p)
    if k == "size_of" or k == "align_of":
        let mt = if k == "size_of": "SizeofExpr" else: "AlignofExpr"
        advance(p)
        consume(p, "lparen", "expected ( after size_of/align_of")
        var t = parse_type(p)
        consume(p, "rparen", "expected ) after type")
        var r = string_mod.String.create()
        r.append("{\"$mt_type\":\"AST:")
        r.append(mt)
        r.append("\",\"type\":")
        r.append(t.as_str())
        t.release()
        r.push_byte('}')
        return r
    if k == "offset_of":
        advance(p)
        consume(p, "lparen", "expected ( after offset_of")
        var t = parse_type(p)
        consume(p, "comma", "expected , in offset_of")
        let field = peek_lexeme(p)
        advance(p)
        consume(p, "rparen", "expected ) after offset_of")
        var r = string_mod.String.create()
        r.append("{\"$mt_type\":\"AST:OffsetofExpr\",\"type\":")
        r.append(t.as_str())
        t.release()
        r.append(",\"field\":")
        var fe = lexer_mod.json_escaped(field)
        r.append(fe.as_str())
        fe.release()
        r.push_byte('}')
        return r
    if k == "integer":
        var r = int_lit_json(peek_lexeme(p))
        advance(p)
        return r
    if k == "float":
        var r = float_lit_json(peek_lexeme(p))
        advance(p)
        return r
    if k == "char_literal":
        return char_lit_json(p)
    if k == "string":
        return str_lit_json(p, false)
    if k == "cstring":
        return str_lit_json(p, true)
    if k == "true":
        advance(p)
        return bool_lit_json("true")
    if k == "false":
        advance(p)
        return bool_lit_json("false")
    if k == "null":
        advance(p)
        if check(p, "lbracket"):
            advance(p)
            var t = parse_type(p)
            consume(p, "rbracket", "expected ] after typed null")
            var r = string_mod.String.create()
            r.append("{\"$mt_type\":\"AST:NullLiteral\",\"type\":")
            r.append(t.as_str())
            t.release()
            r.append(",\"line\":null,\"column\":null}")
            return r
        return null_lit_json()
    if k == "lparen":
        return parse_paren_or_tuple(p)
    if k == "detach":
        advance(p)
        var det_expr = parse_expr(p)
        var r = string_mod.String.create()
        r.append("{\"$mt_type\":\"AST:DetachExpr\",\"body\":[{\"$mt_type\":\"AST:ExpressionStmt\",\"expression\":")
        r.append(det_expr.as_str())
        det_expr.release()
        r.append(",\"line\":null}]}")
        return r
    if k == "unsafe":
        advance(p)
        consume(p, "colon", "expected : after unsafe")
        var inner = parse_expr(p)
        var r = string_mod.String.create()
        r.append("{\"$mt_type\":\"AST:UnsafeExpr\",\"expression\":")
        r.append(inner.as_str())
        inner.release()
        r.append(",\"line\":null,\"column\":null,\"length\":null}")
        return r
    if k == "fstring":
        let lm = peek_lexeme(p)
        advance(p)
        return build_fstring_from_lexeme(lm)
    if k == "fields_of" or k == "field_of" or k == "attribute_of" or k == "attributes_of" or k == "callable_of" or k == "members_of":
        var r = ident_json(peek_lexeme(p))
        advance(p)
        return r
    if k != "identifier":
        p.stmt_failed = true
    var r = ident_json(peek_lexeme(p))
    advance(p)
    return r

function collect_known_generics(p: ref[Parser]) -> void:
    let n = p.tokens.tokens.len
    if n < 3:
        return
    var i: ptr_uint = 0
    while i + 2 < n:
        let t0 = p.tokens.tokens.get(i) else:
            break
        let k0 = unsafe: read(t0).kind
        if k0 == "function":
            let t1 = p.tokens.tokens.get(i + 1) else:
                break
            let t2 = p.tokens.tokens.get(i + 2) else:
                break
            let k1 = unsafe: read(t1).kind
            let k2 = unsafe: read(t2).kind
            if k1 == "identifier" and k2 == "lbracket":
                p.known_generics.push(unsafe: read(t1).lexeme)
        i += 1

function is_known_generic(p: ref[Parser], name: str) -> bool:
    var i: ptr_uint = 0
    while i < p.known_generics.len:
        let item = p.known_generics.at(i) else:
            break
        if item == name:
            return true
        i += 1
    return false

function is_builtin_spec(name: str) -> bool:
    if name == "array" or name == "reinterpret" or name == "span" or name == "zero":
        return true
    if name == "ptr" or name == "const_ptr" or name == "ref" or name == "adapt":
        return true
    if name == "equal" or name == "hash" or name == "order" or name == "default":
        return true
    return false

function is_capitalized(name: str) -> bool:
    if name.len == 0:
        return false
    let c = name.byte_at(0)
    return c >= 'A' and c <= 'Z'

function is_primitive_type(name: str) -> bool:
    if name == "int" or name == "uint" or name == "float" or name == "double":
        return true
    if name == "char" or name == "bool" or name == "byte" or name == "ubyte":
        return true
    if name == "short" or name == "ushort" or name == "long" or name == "ulong":
        return true
    if name == "usize" or name == "isize" or name == "ptr_uint" or name == "str" or name == "cstr":
        return true
    return false

function is_spec_target(p: ref[Parser], name: str) -> bool:
    if is_builtin_spec(name):
        return true
    if is_capitalized(name):
        return true
    return is_known_generic(p, name)

function make_specialization(callee: str, args: str) -> string_mod.String:
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:Specialization\",\"callee\":")
    r.append(callee)
    r.append(",\"arguments\":")
    r.append(args)
    r.push_byte('}')
    return r

function parse_spec_args_json(p: ref[Parser]) -> string_mod.String:
    var r = string_mod.String.create()
    r.push_byte('[')
    var first = true
    var safety: ptr_uint = 0
    while not check(p, "rbracket") and not is_eof(p):
        safety += 1
        if safety > 10000:
            break
        if not first:
            r.push_byte(',')
        first = false
        r.append("{\"$mt_type\":\"AST:TypeArgument\",\"value\":")
        if check(p, "integer"):
            var il = int_lit_json(peek_lexeme(p))
            r.append(il.as_str())
            il.release()
            advance(p)
        else if check(p, "float"):
            var fl = float_lit_json(peek_lexeme(p))
            r.append(fl.as_str())
            fl.release()
            advance(p)
        else:
            var t = parse_type(p)
            r.append(t.as_str())
            t.release()
        r.push_byte('}')
        if check(p, "comma"):
            advance(p)
    r.push_byte(']')
    return r

function parse_postfix_expr(p: ref[Parser]) -> string_mod.String:
    var recv_ident: str = ""
    if check(p, "identifier"):
        recv_ident = peek_lexeme(p)
    var expr = parse_primary_expr(p)
    while true:
        if check(p, "dot"):
            advance(p)
            let member = peek_lexeme(p)
            advance(p)
            var ne = make_member(expr.as_str(), member)
            expr.release()
            expr = ne
            recv_ident = member
        else if check(p, "lbracket"):
            advance(p)
            var is_spec = recv_ident != "" and is_spec_target(p, recv_ident)
            if not is_spec and check(p, "identifier"):
                let cl = peek_lexeme(p)
                if is_capitalized(cl) or is_primitive_type(cl):
                    is_spec = true
            if is_spec:
                var args = parse_spec_args_json(p)
                consume(p, "rbracket", "expected ] after specialization")
                var ne = make_specialization(expr.as_str(), args.as_str())
                expr.release()
                args.release()
                expr = ne
            else:
                var idx = parse_expr(p)
                if check(p, "rbracket"):
                    advance(p)
                    var ne = make_index(expr.as_str(), idx.as_str())
                    expr.release()
                    idx.release()
                    expr = ne
                else:
                    p.stmt_failed = true
                    idx.release()
                    var bd: ptr_uint = 1
                    while bd > 0 and not is_eof(p):
                        if check(p, "lbracket"):
                            bd += 1
                        else if check(p, "rbracket"):
                            bd -= 1
                        advance(p)
            recv_ident = ""
        else if check(p, "lparen"):
            advance(p)
            var args = parse_call_args(p)
            var ne = make_call(expr.as_str(), args.as_str())
            expr.release()
            args.release()
            expr = ne
            recv_ident = ""
        else if check(p, "question"):
            advance(p)
            var ne = make_unaryop("?", expr.as_str())
            expr.release()
            expr = ne
            recv_ident = ""
        else:
            break
    return expr

function is_cast_type(name: str) -> bool:
    if is_capitalized(name):
        return true
    if name == "int" or name == "uint" or name == "float" or name == "double":
        return true
    if name == "char" or name == "bool" or name == "byte" or name == "ubyte":
        return true
    if name == "short" or name == "ushort" or name == "long" or name == "ulong":
        return true
    if name == "usize" or name == "isize" or name == "ptr_uint":
        return true
    if name == "vec2" or name == "vec3" or name == "vec4" or name == "quat":
        return true
    if name == "ivec2" or name == "ivec3" or name == "ivec4" or name == "mat3" or name == "mat4":
        return true
    if name == "ptr" or name == "const_ptr" or name == "span" or name == "array" or name == "string":
        return true
    return false

function parse_proc_expr(p: ref[Parser]) -> string_mod.String:
    advance(p)
    consume(p, "lparen", "expected ( after proc")
    var params = string_mod.String.create()
    params.push_byte('[')
    var pfirst = true
    var psafety: ptr_uint = 0
    while not check(p, "rparen") and not is_eof(p):
        psafety += 1
        if psafety > 10000:
            break
        if not pfirst:
            params.push_byte(',')
        pfirst = false
        let pname = peek_lexeme(p)
        advance(p)
        consume(p, "colon", "expected : in proc param")
        var pt = parse_type(p)
        params.append("{\"$mt_type\":\"AST:Param\",\"name\":")
        var pe = lexer_mod.json_escaped(pname)
        params.append(pe.as_str())
        pe.release()
        params.append(",\"type\":")
        params.append(pt.as_str())
        pt.release()
        params.append(",\"line\":null,\"column\":null}")
        if check(p, "comma"):
            advance(p)
    params.push_byte(']')
    consume(p, "rparen", "expected ) after proc params")
    consume(p, "arrow", "expected -> in proc")
    var rtype = parse_type(p)
    var body = string_mod.String.create()
    if check(p, "colon") and peek_kind2(p) == "newline":
        body.release()
        body = parse_block(p)
        p.block_expr_done = true
    else:
        consume(p, "colon", "expected : before proc body")
        var e = parse_expr(p)
        body.append("[{\"$mt_type\":\"AST:ReturnStmt\",\"value\":")
        body.append(e.as_str())
        e.release()
        body.append(",\"line\":null,\"column\":null,\"length\":null}]")
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:ProcExpr\",\"params\":")
    r.append(params.as_str())
    params.release()
    r.append(",\"return_type\":")
    r.append(rtype.as_str())
    rtype.release()
    r.append(",\"body\":")
    r.append(body.as_str())
    body.release()
    r.push_byte('}')
    return r

function find_cast_arrow(p: ref[Parser], start: ptr_uint) -> ptr_uint:
    var i = start
    if i < p.tokens.tokens.len:
        let t1 = p.tokens.tokens.get(i) else:
            return 0
        if unsafe: read(t1).kind == "less":
            let t2 = p.tokens.tokens.get(i + 1) else:
                return 0
            return if unsafe: read(t2).kind == "minus": i else: 0
        if unsafe: read(t1).kind == "lbracket":
            var bd: ptr_uint = 1
            i += 1
            while i < p.tokens.tokens.len and bd > 0:
                let bt = p.tokens.tokens.get(i) else:
                    return 0
                let bk = unsafe: read(bt).kind
                if bk == "lbracket":
                    bd += 1
                else if bk == "rbracket":
                    bd -= 1
                i += 1
            if i < p.tokens.tokens.len and i + 1 < p.tokens.tokens.len:
                let tl = p.tokens.tokens.get(i) else:
                    return 0
                let tm = p.tokens.tokens.get(i + 1) else:
                    return 0
                return if unsafe: read(tl).kind == "less" and unsafe: read(tm).kind == "minus": i else: 0
    return 0

function parse_unary_expr(p: ref[Parser]) -> string_mod.String:
    if check(p, "identifier") and is_cast_type(peek_lexeme(p)):
        var is_simple = peek_kind2(p) == "less" and peek_kind3(p) == "minus"
        var arrow: ptr_uint = 0
        if not is_simple:
            arrow = find_cast_arrow(p, p.tokens.pos + 1)
        if is_simple or arrow > 0:
            var target_type = parse_type(p)
            consume(p, "less", "expected < in cast")
            consume(p, "minus", "expected - in cast")
            var operand = parse_unary_expr(p)
            var r = string_mod.String.create()
            r.append("{\"$mt_type\":\"AST:PrefixCast\",\"target_type\":")
            r.append(target_type.as_str())
            target_type.release()
            r.append(",\"expression\":")
            r.append(operand.as_str())
            operand.release()
            r.push_byte('}')
            return r
    if check(p, "await"):
        advance(p)
        var e = parse_unary_expr(p)
        var r = string_mod.String.create()
        r.append("{\"$mt_type\":\"AST:AwaitExpr\",\"expression\":")
        r.append(e.as_str())
        e.release()
        r.push_byte('}')
        return r
    if check(p, "not") or check(p, "minus") or check(p, "plus") or check(p, "tilde"):
        let op = peek_lexeme(p)
        advance(p)
        var operand = parse_unary_expr(p)
        var r = make_unaryop(op, operand.as_str())
        operand.release()
        return r
    return parse_postfix_expr(p)

function parse_binary(p: ref[Parser], min_prec: int) -> string_mod.String:
    var left = parse_unary_expr(p)
    while true:
        let prec = op_prec(peek_kind(p))
        if prec < min_prec:
            break
        let op = peek_lexeme(p)
        advance(p)
        var right = parse_binary(p, prec + 1)
        var nl = make_binop(op, left.as_str(), right.as_str())
        left.release()
        right.release()
        left = nl
    return left

function parse_range_expr(p: ref[Parser]) -> string_mod.String:
    var left = parse_binary(p, 1)
    if check(p, "dot_dot"):
        advance(p)
        var right = parse_binary(p, 1)
        var r = string_mod.String.create()
        r.append("{\"$mt_type\":\"AST:RangeExpr\",\"start_expr\":")
        r.append(left.as_str())
        left.release()
        r.append(",\"end_expr\":")
        r.append(right.as_str())
        right.release()
        r.append(",\"line\":null,\"column\":null}")
        return r
    return left

function parse_if_expr(p: ref[Parser]) -> string_mod.String:
    advance(p)
    var cond = parse_binary(p, 1)
    consume(p, "colon", "expected : in if expression")
    var then_e = parse_expr(p)
    consume(p, "else", "expected else in if expression")
    consume(p, "colon", "expected : after else")
    var else_e = parse_expr(p)
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:IfExpr\",\"condition\":")
    r.append(cond.as_str())
    cond.release()
    r.append(",\"then_expression\":")
    r.append(then_e.as_str())
    then_e.release()
    r.append(",\"else_expression\":")
    r.append(else_e.as_str())
    else_e.release()
    r.push_byte('}')
    return r

function parse_expr(p: ref[Parser]) -> string_mod.String:
    if check(p, "match"):
        return parse_match(p, true, false)
    if check(p, "proc"):
        return parse_proc_expr(p)
    if check(p, "unsafe"):
        advance(p)
        consume(p, "colon", "expected : after unsafe")
        var e = parse_expr(p)
        var r = string_mod.String.create()
        r.append("{\"$mt_type\":\"AST:UnsafeExpr\",\"expression\":")
        r.append(e.as_str())
        e.release()
        r.append(",\"line\":null,\"column\":null,\"length\":null}")
        return r
    if check(p, "if"):
        return parse_if_expr(p)
    return parse_range_expr(p)

# ── statement parser ──────────────────────────────────────────────────────

function placeholder_expr() -> string_mod.String:
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:NullLiteral\",\"type\":null,\"line\":null,\"column\":null}")
    return r

function skip_to_stmt_end(p: ref[Parser]) -> void:
    while not is_eof(p) and not check(p, "newline") and not check(p, "dedent"):
        advance(p)
    if check(p, "newline"):
        advance(p)

function skip_indented_block(p: ref[Parser]) -> void:
    if check(p, "indent"):
        advance(p)
        var depth: ptr_uint = 1
        while depth > 0 and not is_eof(p):
            if check(p, "indent"):
                depth += 1
            else if check(p, "dedent"):
                depth -= 1
            advance(p)

function skip_match(p: ref[Parser]) -> void:
    advance(p)
    while not is_eof(p) and not check(p, "colon") and not check(p, "newline"):
        skip_expression(p)
    if check(p, "colon"):
        advance(p)
        if check(p, "newline"):
            advance(p)
            skip_indented_block(p)
        else:
            while not is_eof(p) and not check(p, "newline"):
                advance(p)

function skip_proc(p: ref[Parser]) -> void:
    advance(p)
    if check(p, "lparen"):
        advance(p)
        var pd: ptr_uint = 1
        while pd > 0 and not is_eof(p):
            if check(p, "lparen"):
                pd += 1
            else if check(p, "rparen"):
                pd -= 1
            advance(p)
    while not is_eof(p) and not check(p, "colon") and not check(p, "newline"):
        advance(p)
    if check(p, "colon"):
        advance(p)
        if check(p, "newline"):
            advance(p)
            skip_indented_block(p)
        else:
            while not is_eof(p) and not check(p, "newline"):
                advance(p)

function is_assign_op(k: str) -> bool:
    if k == "equal":
        return true
    if k == "plus_equal" or k == "minus_equal" or k == "star_equal" or k == "slash_equal":
        return true
    if k == "percent_equal" or k == "amp_equal" or k == "pipe_equal" or k == "caret_equal":
        return true
    if k == "shift_left_equal" or k == "shift_right_equal":
        return true
    return false

function end_or_fail(p: ref[Parser]) -> void:
    if p.block_expr_done:
        p.block_expr_done = false
        return
    if check(p, "newline"):
        advance(p)
    else if check(p, "else") or check(p, "dedent") or is_eof(p):
        return
    else:
        p.stmt_failed = true
        skip_to_stmt_end(p)

function parse_stmt_block_body(p: ref[Parser]) -> string_mod.String:
    var r = string_mod.String.create()
    r.push_byte('[')
    skip_newlines(p)
    var first = true
    var safety: ptr_uint = 0
    while not check(p, "dedent") and not is_eof(p):
        safety += 1
        if safety > 200000:
            p.stmt_failed = true
            break
        if not first:
            r.push_byte(',')
        first = false
        var stmt = parse_statement(p)
        r.append(stmt.as_str())
        stmt.release()
        skip_newlines(p)
    r.push_byte(']')
    return r

function parse_block(p: ref[Parser]) -> string_mod.String:
    consume(p, "colon", "expected : before block")
    consume(p, "newline", "expected newline before block")
    consume(p, "indent", "expected indented block")
    var body = parse_stmt_block_body(p)
    consume(p, "dedent", "expected end of block")
    return body

function inline_block_body(p: ref[Parser]) -> bool:
    return check(p, "colon") and not (peek_kind2(p) == "newline")

function parse_block_or_inline(p: ref[Parser]) -> string_mod.String:
    if inline_block_body(p):
        consume(p, "colon", "expected : before inline body")
        var r = string_mod.String.create()
        r.push_byte('[')
        var stmt = parse_statement(p)
        r.append(stmt.as_str())
        stmt.release()
        r.push_byte(']')
        return r
    return parse_block(p)

function simple_stmt_json(mt: str) -> string_mod.String:
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:")
    r.append(mt)
    r.append("\",\"line\":null,\"column\":null,\"length\":null}")
    return r

function parse_return_stmt(p: ref[Parser]) -> string_mod.String:
    advance(p)
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:ReturnStmt\",\"value\":")
    if check(p, "newline") or check(p, "dedent") or is_eof(p):
        r.append("null")
        end_or_fail(p)
    else:
        var v = parse_expr(p)
        r.append(v.as_str())
        v.release()
        end_or_fail(p)
    r.append(",\"line\":null,\"column\":null,\"length\":null}")
    return r

function parse_local_decl(p: ref[Parser], kind: str) -> string_mod.String:
    advance(p)
    var is_destructure = false
    var dest_bindings = string_mod.String.create()

    if check(p, "lparen"):
        advance(p)
        dest_bindings.push_byte('[')
        var db_first = true
        while not check(p, "rparen") and not is_eof(p):
            let bname = peek_lexeme(p)
            advance(p)
            if not db_first:
                dest_bindings.push_byte(',')
            db_first = false
            var be = lexer_mod.json_escaped(bname)
            dest_bindings.append(be.as_str())
            be.release()
            if check(p, "colon"):
                advance(p)
                while not is_eof(p) and not check(p, "comma") and not check(p, "rparen"):
                    advance(p)
            if check(p, "comma"):
                advance(p)
        consume(p, "rparen", "expected ) after destructure pattern")
        dest_bindings.push_byte(']')
        is_destructure = true
    else if peek_kind2(p) == "lparen" or peek_kind2(p) == "dot":
        p.stmt_failed = true
        skip_to_stmt_end(p)
        dest_bindings.release()
        return simple_stmt_json("PassStmt")
    else:
        dest_bindings.append("null")

    var nm = string_mod.String.create()
    if not is_destructure:
        nm.append(peek_lexeme(p))
        advance(p)
    var ty = string_mod.String.create()
    if check(p, "colon"):
        advance(p)
        ty.release()
        ty = parse_type(p)
    var val = string_mod.String.create()
    var has_val = false
    var else_body = string_mod.String.create()
    var has_else = false
    var else_binding = string_mod.String.create()
    if check(p, "equal"):
        advance(p)
        val.release()
        val = parse_expr(p)
        has_val = true
        if check(p, "else"):
            advance(p)
            if check(p, "as"):
                advance(p)
                let bn = peek_lexeme(p)
                advance(p)
                else_binding.release()
                else_binding = ident_json(bn)
            else_body.release()
            else_body = parse_block(p)
            has_else = true
        else:
            end_or_fail(p)
    else:
        end_or_fail(p)
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:LocalDecl\",\"kind\":{\"$sym\":\"")
    r.append(kind)
    r.append("\"},\"name\":")
    if is_destructure:
        r.append("null")
    else:
        var ne = lexer_mod.json_escaped(nm.as_str())
        r.append(ne.as_str())
        ne.release()
    nm.release()
    r.append(",\"type\":")
    if ty.len == 0:
        r.append("null")
    else:
        r.append(ty.as_str())
    ty.release()
    r.append(",\"value\":")
    if has_val:
        r.append(val.as_str())
    else:
        r.append("null")
    val.release()
    r.append(",\"else_binding\":")
    if has_else and else_binding.len > 0:
        r.append(else_binding.as_str())
    else:
        r.append("null")
    else_binding.release()
    r.append(",\"else_body\":")
    if has_else:
        r.append(else_body.as_str())
    else:
        r.append("null")
    else_body.release()
    r.append(",\"line\":null,\"column\":null,\"recovered_else\":false,\"destructure_bindings\":")
    r.append(dest_bindings.as_str())
    dest_bindings.release()
    r.append(",\"destructure_type_name\":null}")
    return r

function parse_assign_or_expr_stmt(p: ref[Parser]) -> string_mod.String:
    var expr = parse_expr(p)
    if is_assign_op(peek_kind(p)):
        let op = peek_lexeme(p)
        advance(p)
        var val = parse_expr(p)
        end_or_fail(p)
        var r = string_mod.String.create()
        r.append("{\"$mt_type\":\"AST:Assignment\",\"target\":")
        r.append(expr.as_str())
        expr.release()
        r.append(",\"operator\":")
        var oe = lexer_mod.json_escaped(op)
        r.append(oe.as_str())
        oe.release()
        r.append(",\"value\":")
        r.append(val.as_str())
        val.release()
        r.append(",\"line\":null,\"column\":null}")
        return r
    end_or_fail(p)
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:ExpressionStmt\",\"expression\":")
    r.append(expr.as_str())
    expr.release()
    r.append(",\"line\":null}")
    return r

function parse_if_branch(p: ref[Parser]) -> string_mod.String:
    var cond = parse_binary(p, 1)
    var body = parse_block_or_inline(p)
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:IfBranch\",\"condition\":")
    r.append(cond.as_str())
    cond.release()
    r.append(",\"body\":")
    r.append(body.as_str())
    body.release()
    r.append(",\"line\":null,\"column\":null,\"length\":null}")
    return r

function parse_if_stmt(p: ref[Parser], is_inline: bool) -> string_mod.String:
    advance(p)
    var branches = string_mod.String.create()
    branches.push_byte('[')
    var b0 = parse_if_branch(p)
    branches.append(b0.as_str())
    b0.release()
    while check(p, "else") and peek_kind2(p) == "if":
        advance(p)
        advance(p)
        branches.push_byte(',')
        var bn = parse_if_branch(p)
        branches.append(bn.as_str())
        bn.release()
    branches.push_byte(']')
    var has_else = false
    var else_body = string_mod.String.create()
    if check(p, "else"):
        advance(p)
        else_body.release()
        else_body = parse_block_or_inline(p)
        has_else = true
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:IfStmt\",\"branches\":")
    r.append(branches.as_str())
    branches.release()
    r.append(",\"else_body\":")
    if has_else:
        r.append(else_body.as_str())
    else:
        r.append("null")
    else_body.release()
    r.append(",\"inline\":")
    if is_inline:
        r.append("true")
    else:
        r.append("false")
    r.append(",\"line\":null,\"else_line\":null,\"else_column\":null}")
    return r

function parse_while_stmt(p: ref[Parser], is_inline: bool) -> string_mod.String:
    advance(p)
    var cond = parse_expr(p)
    var body = parse_block(p)
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:WhileStmt\",\"condition\":")
    r.append(cond.as_str())
    cond.release()
    r.append(",\"body\":")
    r.append(body.as_str())
    body.release()
    r.append(",\"inline\":")
    if is_inline:
        r.append("true")
    else:
        r.append("false")
    r.append(",\"line\":null,\"column\":null,\"length\":null}")
    return r

function parse_for_stmt(p: ref[Parser], is_inline: bool, is_threaded: bool) -> string_mod.String:
    advance(p)
    var bindings = string_mod.String.create()
    bindings.push_byte('[')
    var bfirst = true
    while true:
        if not bfirst:
            bindings.push_byte(',')
        bfirst = false
        let bn = peek_lexeme(p)
        advance(p)
        bindings.append("{\"$mt_type\":\"AST:ForBinding\",\"name\":")
        var be = lexer_mod.json_escaped(bn)
        bindings.append(be.as_str())
        be.release()
        bindings.append(",\"line\":null,\"column\":null}")
        if check(p, "comma"):
            advance(p)
        else:
            break
    bindings.push_byte(']')
    consume(p, "in", "expected in in for loop")
    var iterables = string_mod.String.create()
    iterables.push_byte('[')
    var it0 = parse_expr(p)
    iterables.append(it0.as_str())
    it0.release()
    while check(p, "comma"):
        advance(p)
        iterables.push_byte(',')
        var itn = parse_expr(p)
        iterables.append(itn.as_str())
        itn.release()
    iterables.push_byte(']')
    var body = parse_block(p)
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:ForStmt\",\"bindings\":")
    r.append(bindings.as_str())
    bindings.release()
    r.append(",\"iterables\":")
    r.append(iterables.as_str())
    iterables.release()
    r.append(",\"body\":")
    r.append(body.as_str())
    body.release()
    r.append(",\"inline\":")
    if is_inline:
        r.append("true")
    else:
        r.append("false")
    r.append(",\"threaded\":")
    if is_threaded:
        r.append("true")
    else:
        r.append("false")
    r.append(",\"line\":null,\"column\":null}")
    return r

function parse_defer_stmt(p: ref[Parser]) -> string_mod.String:
    advance(p)
    var r = string_mod.String.create()
    if check(p, "colon"):
        var body = parse_block(p)
        r.append("{\"$mt_type\":\"AST:DeferStmt\",\"expression\":null,\"body\":")
        r.append(body.as_str())
        body.release()
        r.append(",\"line\":null,\"column\":null,\"length\":null}")
        return r
    var e = parse_expr(p)
    end_or_fail(p)
    r.append("{\"$mt_type\":\"AST:DeferStmt\",\"expression\":")
    r.append(e.as_str())
    e.release()
    r.append(",\"body\":null,\"line\":null,\"column\":null,\"length\":null}")
    return r

function parse_unsafe_block_stmt(p: ref[Parser]) -> string_mod.String:
    advance(p)
    var body = string_mod.String.create()
    if check(p, "colon") and peek_kind2(p) == "newline":
        body.release()
        body = parse_block(p)
    else:
        consume(p, "colon", "expected : after unsafe")
        body.push_byte('[')
        var stmt = parse_statement(p)
        body.append(stmt.as_str())
        stmt.release()
        body.push_byte(']')
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:UnsafeStmt\",\"body\":")
    r.append(body.as_str())
    body.release()
    r.append(",\"line\":null,\"column\":null,\"length\":null}")
    return r

function parse_match(p: ref[Parser], as_value: bool, is_inline: bool) -> string_mod.String:
    advance(p)
    var subject = parse_expr(p)
    var arms = string_mod.String.create()
    arms.push_byte('[')
    var arm_first = true
    var expr_form = as_value
    var form_decided = as_value

    if not check(p, "colon"):
        subject.release()
        arms.release()
        p.stmt_failed = true
        skip_to_stmt_end(p)
        if as_value:
            return placeholder_expr()
        return simple_stmt_json("PassStmt")
    advance(p)
    if check(p, "newline"):
        advance(p)
    if check(p, "indent"):
        advance(p)
    skip_newlines(p)
    var safety: ptr_uint = 0
    while not check(p, "dedent") and not is_eof(p):
        safety += 1
        if safety > 100000:
            p.stmt_failed = true
            break
        var pat_buf = string_mod.String.create()
        if check(p, "else"):
            advance(p)
            var pid = ident_json("_")
            pat_buf.append(pid.as_str())
            pid.release()
        else:
            var p0 = parse_binary(p, 5)
            pat_buf.append(p0.as_str())
            p0.release()
            while check(p, "pipe"):
                advance(p)
                pat_buf.push_byte(0x1E)
                var pn = parse_binary(p, 5)
                pat_buf.append(pn.as_str())
                pn.release()
        var binding_json = string_mod.String.create()
        binding_json.append("null")
        if check(p, "as"):
            advance(p)
            let bn = peek_lexeme(p)
            advance(p)
            binding_json.release()
            binding_json = lexer_mod.json_escaped(bn)
        if not form_decided:
            expr_form = check(p, "colon") and peek_kind2(p) != "newline"
            form_decided = true
        var payload = string_mod.String.create()
        if expr_form:
            consume(p, "colon", "expected : in match arm")
            payload.release()
            payload = parse_expr(p)
            end_or_fail(p)
        else:
            payload.release()
            payload = parse_block(p)
        let arm_mt = if expr_form: "MatchExprArm" else: "MatchArm"
        let payload_key = if expr_form: "value" else: "body"
        let ps = pat_buf.as_str()
        var seg_start: ptr_uint = 0
        var j: ptr_uint = 0
        while j <= ps.len:
            if j == ps.len or ps.byte_at(j) == 0x1E:
                let seg = ps.slice(seg_start, j - seg_start)
                if not arm_first:
                    arms.push_byte(',')
                arm_first = false
                arms.append("{\"$mt_type\":\"AST:")
                arms.append(arm_mt)
                arms.append("\",\"pattern\":")
                arms.append(seg)
                arms.append(",\"binding_name\":")
                arms.append(binding_json.as_str())
                arms.append(",\"binding_line\":null,\"binding_column\":null,\"")
                arms.append(payload_key)
                arms.append("\":")
                arms.append(payload.as_str())
                arms.push_byte('}')
                seg_start = j + 1
            j += 1
        pat_buf.release()
        binding_json.release()
        payload.release()
        skip_newlines(p)
    if check(p, "dedent"):
        advance(p)
    arms.push_byte(']')
    if expr_form:
        var me = string_mod.String.create()
        me.append("{\"$mt_type\":\"AST:MatchExpr\",\"expression\":")
        me.append(subject.as_str())
        subject.release()
        me.append(",\"arms\":")
        me.append(arms.as_str())
        arms.release()
        me.append(",\"line\":null,\"column\":null,\"length\":null}")
        if as_value:
            p.block_expr_done = true
            return me
        var stmt = string_mod.String.create()
        stmt.append("{\"$mt_type\":\"AST:ExpressionStmt\",\"expression\":")
        stmt.append(me.as_str())
        me.release()
        stmt.append(",\"line\":null}")
        return stmt
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:MatchStmt\",\"expression\":")
    r.append(subject.as_str())
    subject.release()
    r.append(",\"arms\":")
    r.append(arms.as_str())
    arms.release()
    r.append(",\"inline\":")
    if is_inline:
        r.append("true")
    else:
        r.append("false")
    r.append(",\"line\":null,\"column\":null,\"length\":null}")
    return r

function parse_when_stmt(p: ref[Parser]) -> string_mod.String:
    advance(p)
    var disc = parse_expr(p)
    var arms = string_mod.String.create()
    arms.push_byte('[')
    if check(p, "colon"):
        advance(p)
        consume(p, "newline", "expected newline after when")
        consume(p, "indent", "expected indented block")
        var afirst = true
        skip_newlines(p)
        var safety: ptr_uint = 0
        while not check(p, "dedent") and not is_eof(p):
            safety += 1
            if safety > 100000:
                break
            var pattern = parse_expr(p)
            var binding = string_mod.String.create()
            binding.append("null")
            if check(p, "as"):
                advance(p)
                let bn = peek_lexeme(p)
                advance(p)
                binding.release()
                binding = lexer_mod.json_escaped(bn)
            var body = parse_block(p)
            if not afirst:
                arms.push_byte(',')
            afirst = false
            arms.append("{\"$mt_type\":\"AST:WhenBranch\",\"pattern\":")
            arms.append(pattern.as_str())
            pattern.release()
            arms.append(",\"binding_name\":")
            arms.append(binding.as_str())
            binding.release()
            arms.append(",\"binding_line\":null,\"binding_column\":null,\"body\":")
            arms.append(body.as_str())
            body.release()
            arms.push_byte('}')
            skip_newlines(p)
        consume(p, "dedent", "expected end of when block")
    arms.push_byte(']')
    var else_body = string_mod.String.create()
    else_body.append("null")
    if check(p, "else"):
        advance(p)
        else_body.release()
        else_body = parse_block_or_inline(p)
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:WhenStmt\",\"discriminant\":")
    r.append(disc.as_str())
    disc.release()
    r.append(",\"branches\":")
    r.append(arms.as_str())
    arms.release()
    r.append(",\"else_body\":")
    r.append(else_body.as_str())
    else_body.release()
    r.append(",\"line\":null,\"column\":null,\"length\":null}")
    return r

function parse_statement(p: ref[Parser]) -> string_mod.String:
    let k = peek_kind(p)
    if k == "let":
        return parse_local_decl(p, "let")
    if k == "var":
        return parse_local_decl(p, "var")
    if k == "return":
        return parse_return_stmt(p)
    if k == "pass":
        advance(p)
        end_or_fail(p)
        return simple_stmt_json("PassStmt")
    if k == "break":
        advance(p)
        end_or_fail(p)
        return simple_stmt_json("BreakStmt")
    if k == "continue":
        advance(p)
        end_or_fail(p)
        return simple_stmt_json("ContinueStmt")
    if k == "if":
        return parse_if_stmt(p, false)
    if k == "while":
        return parse_while_stmt(p, false)
    if k == "for":
        return parse_for_stmt(p, false, false)
    if k == "parallel" and peek_kind2(p) == "for":
        advance(p)
        return parse_for_stmt(p, false, true)
    if k == "defer":
        return parse_defer_stmt(p)
    if k == "unsafe":
        return parse_unsafe_block_stmt(p)
    if k == "match":
        return parse_match(p, false, false)
    if k == "inline":
        advance(p)
        let ik = peek_kind(p)
        if ik == "for":
            return parse_for_stmt(p, true, false)
        if ik == "while":
            return parse_while_stmt(p, true)
        if ik == "match":
            return parse_match(p, false, true)
        if ik == "if":
            return parse_if_stmt(p, true)
        p.stmt_failed = true
        skip_statement(p)
        return simple_stmt_json("PassStmt")
    if k == "when":
        return parse_when_stmt(p)
    if k == "parallel":
        advance(p)
        var bodies = string_mod.String.create()
        bodies.push_byte('[')
        var bfirst = true
        if check(p, "colon"):
            advance(p)
            consume_nl(p)
            if check(p, "indent"):
                advance(p)
                skip_newlines(p)
                while not check(p, "dedent") and not is_eof(p):
                    if not bfirst:
                        bodies.push_byte(',')
                    bfirst = false
                    var body = string_mod.String.create()
                    body.push_byte('[')
                    var stmt = parse_statement(p)
                    body.append(stmt.as_str())
                    stmt.release()
                    body.push_byte(']')
                    bodies.append(body.as_str())
                    body.release()
                    skip_newlines(p)
                if check(p, "dedent"):
                    advance(p)
        else:
            consume_nl(p)
        bodies.push_byte(']')
        var r = string_mod.String.create()
        r.append("{\"$mt_type\":\"AST:ParallelBlockStmt\",\"bodies\":")
        r.append(bodies.as_str())
        bodies.release()
        r.append(",\"line\":null,\"column\":null}")
        return r
    if k == "gather":
        advance(p)
        var handles = string_mod.String.create()
        handles.push_byte('[')
        var hfirst = true
        while not check(p, "newline") and not check(p, "dedent") and not is_eof(p):
            let hn = peek_lexeme(p)
            advance(p)
            if not hfirst:
                handles.push_byte(',')
            hfirst = false
            handles.append("{\"$mt_type\":\"AST:Identifier\",\"name\":")
            var he = lexer_mod.json_escaped(hn)
            handles.append(he.as_str())
            he.release()
            handles.append(",\"line\":null,\"column\":null}")
            if check(p, "comma"):
                advance(p)
        handles.push_byte(']')
        end_or_fail(p)
        var r = string_mod.String.create()
        r.append("{\"$mt_type\":\"AST:GatherStmt\",\"handles\":")
        r.append(handles.as_str())
        handles.release()
        r.append(",\"line\":null,\"column\":null}")
        return r
    if k == "emit" or k == "static_assert":
        skip_statement(p)
        return simple_stmt_json("PassStmt")
    return parse_assign_or_expr_stmt(p)

function parse_type(p: ref[Parser]) -> string_mod.String:
    if check(p, "fn"):
        return parse_callable_type(p, "FunctionType")
    if check(p, "proc"):
        return parse_callable_type(p, "ProcType")
    if check(p, "dyn"):
        return parse_dyn_type(p)
    if check(p, "lparen"):
        return parse_tuple_type(p)

    if check(p, "at"):
        advance(p)
        let lt = peek_lexeme(p)
        advance(p)
        var atname = string_mod.String.create()
        atname.push_byte('@')
        atname.append(lt)
        var nameparts = vec_mod.Vec[str].create()
        nameparts.push(atname.as_str())
        var nm = ast.name_json(nameparts)
        nameparts.release()
        var r = string_mod.String.create()
        r.append("{\"$mt_type\":\"AST:TypeRef\",\"name\":")
        r.append(nm.as_str())
        nm.release()
        r.append(",\"arguments\":[],\"nullable\":false,\"lifetime\":null,\"line\":null,\"column\":null,\"length\":null}")
        atname.release()
        return r

    var parts = vec_mod.Vec[str].create()
    parts.push(peek_lexeme(p))
    advance(p)
    while check(p, "dot"):
        advance(p)
        parts.push(peek_lexeme(p))
        advance(p)

    let first_part = parts.at(0) else:
        fatal(c"parse: empty type name")
    let is_ref = parts.len == 1 and first_part == "ref"

    var args = string_mod.String.create()
    args.push_byte('[')
    var first_arg = true
    var lifetime = string_mod.String.create()
    if check(p, "lbracket"):
        advance(p)
        if is_ref and check(p, "at"):
            advance(p)
            lifetime.push_byte('@')
            lifetime.append(peek_lexeme(p))
            advance(p)
            consume(p, "comma", "expected , after lifetime")
        while not check(p, "rbracket") and not is_eof(p):
            if not first_arg:
                args.push_byte(',')
            first_arg = false
            args.append("{\"$mt_type\":\"AST:TypeArgument\",\"value\":")
            if check(p, "integer"):
                var il = int_lit_json(peek_lexeme(p))
                args.append(il.as_str())
                il.release()
                advance(p)
            else if check(p, "float"):
                var fl = float_lit_json(peek_lexeme(p))
                args.append(fl.as_str())
                fl.release()
                advance(p)
            else:
                var nested = parse_type(p)
                args.append(nested.as_str())
                nested.release()
            args.push_byte('}')
            if check(p, "comma"):
                advance(p)
        consume(p, "rbracket", "expected ] after type arguments")
    args.push_byte(']')

    let nullable = match_kind(p, "question")

    var nm = ast.name_json(parts)
    parts.release()
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:TypeRef\",\"name\":")
    r.append(nm.as_str())
    nm.release()
    r.append(",\"arguments\":")
    r.append(args.as_str())
    args.release()
    r.append(",\"nullable\":")
    if nullable:
        r.append("true")
    else:
        r.append("false")
    r.append(",\"lifetime\":")
    if lifetime.len == 0:
        r.append("null")
    else:
        var le = lexer_mod.json_escaped(lifetime.as_str())
        r.append(le.as_str())
        le.release()
    lifetime.release()
    r.append(",\"line\":null,\"column\":null,\"length\":null}")
    return r

function parse_callable_type(p: ref[Parser], mt: str) -> string_mod.String:
    advance(p)
    consume(p, "lparen", "expected ( after fn/proc")
    var params = string_mod.String.create()
    params.push_byte('[')
    var first = true
    while not check(p, "rparen") and not is_eof(p):
        if not first:
            params.push_byte(',')
        first = false
        let pname = peek_lexeme(p)
        advance(p)
        consume(p, "colon", "expected : in callable param")
        var ptype = parse_type(p)
        params.append("{\"$mt_type\":\"AST:Param\",\"name\":")
        var pe = lexer_mod.json_escaped(pname)
        params.append(pe.as_str())
        pe.release()
        params.append(",\"type\":")
        params.append(ptype.as_str())
        ptype.release()
        params.append(",\"line\":null,\"column\":null}")
        if check(p, "comma"):
            advance(p)
    params.push_byte(']')
    consume(p, "rparen", "expected ) after callable params")
    consume(p, "arrow", "expected -> in callable type")
    var rtype = parse_type(p)
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:")
    r.append(mt)
    r.append("\",\"params\":")
    r.append(params.as_str())
    params.release()
    r.append(",\"return_type\":")
    r.append(rtype.as_str())
    rtype.release()
    r.push_byte('}')
    return r

function parse_dyn_type(p: ref[Parser]) -> string_mod.String:
    advance(p)
    consume(p, "lbracket", "expected [ after dyn")
    var parts = vec_mod.Vec[str].create()
    parts.push(peek_lexeme(p))
    advance(p)
    while check(p, "dot"):
        advance(p)
        parts.push(peek_lexeme(p))
        advance(p)
    consume(p, "rbracket", "expected ] after dyn interface")
    let nullable = match_kind(p, "question")
    var nm = ast.name_json(parts)
    parts.release()
    var r = string_mod.String.create()
    r.append("{\"$mt_type\":\"AST:DynType\",\"interface\":")
    r.append(nm.as_str())
    nm.release()
    r.append(",\"nullable\":")
    if nullable:
        r.append("true")
    else:
        r.append("false")
    r.append(",\"line\":null,\"column\":null,\"length\":null}")
    return r

function parse_tuple_type(p: ref[Parser]) -> string_mod.String:
    advance(p)
    var first_t = parse_type(p)
    if check(p, "comma"):
        var elems = string_mod.String.create()
        elems.push_byte('[')
        elems.append(first_t.as_str())
        first_t.release()
        while check(p, "comma"):
            advance(p)
            elems.push_byte(',')
            var nt = parse_type(p)
            elems.append(nt.as_str())
            nt.release()
        elems.push_byte(']')
        consume(p, "rparen", "expected ) after tuple type")
        let nullable = match_kind(p, "question")
        var r = string_mod.String.create()
        r.append("{\"$mt_type\":\"AST:TupleType\",\"element_types\":")
        r.append(elems.as_str())
        elems.release()
        r.append(",\"nullable\":")
        if nullable:
            r.append("true")
        else:
            r.append("false")
        r.push_byte('}')
        return r
    consume(p, "rparen", "expected ) after type")
    return first_t

function parse_type_annotation_capture(p: ref[Parser]) -> string_mod.String:
    if check(p, "colon"):
        advance(p)
        return parse_type(p)
    return string_mod.String.create()

function parse_type_annotation(p: ref[Parser]) -> void:
    if check(p, "colon"):
        advance(p)
        if check(p, "identifier"):
            advance(p)
            if check(p, "lbracket"):
                advance(p)
                var bracket_d: ptr_uint = 1
                while bracket_d > 0 and not is_eof(p) and not check(p, "newline") and not check(p, "equal") and not check(p, "comma") and not check(p, "rparen"):
                    if check(p, "lbracket"):
                        bracket_d += 1
                    else if check(p, "rbracket"):
                        bracket_d -= 1
                    advance(p)
                advance(p)

function parse_type_ref(p: ref[Parser]) -> void:
    if check(p, "identifier"):
        advance(p)
        if check(p, "lbracket"):
            advance(p)
            var bracket_d: ptr_uint = 1
            while bracket_d > 0 and not is_eof(p) and not check(p, "newline") and not check(p, "colon") and not check(p, "rparen"):
                if check(p, "lbracket"):
                    bracket_d += 1
                else if check(p, "rbracket"):
                    bracket_d -= 1
                advance(p)
            advance(p)

function skip_statement(p: ref[Parser]) -> void:
    skip_newlines(p)
    if is_eof(p) or check(p, "dedent"):
        return

    if check(p, "indent"):
        advance(p)
        while not check(p, "dedent") and not is_eof(p):
            skip_statement(p)
        if check(p, "dedent"):
            advance(p)
        return

    if check(p, "if") or check(p, "while") or check(p, "for") or check(p, "match"):
        advance(p)
        while not is_eof(p) and not check(p, "newline") and not check(p, "colon"):
            skip_expression(p)
        if check(p, "colon"):
            advance(p)
            if check(p, "newline"):
                advance(p)
                if check(p, "indent"):
                    advance(p)
                    while not check(p, "dedent") and not is_eof(p):
                        skip_statement(p)
                    if check(p, "dedent"):
                        advance(p)
            else:
                while not is_eof(p) and not check(p, "newline") and not check(p, "dedent"):
                    skip_expression(p)
                if check(p, "newline"):
                    advance(p)
        if check(p, "else"):
            advance(p)
            if check(p, "if"):
                advance(p)
                while not is_eof(p) and not check(p, "newline") and not check(p, "colon"):
                    skip_expression(p)
            if check(p, "colon"):
                advance(p)
                if check(p, "newline"):
                    advance(p)
                    if check(p, "indent"):
                        advance(p)
                        while not check(p, "dedent") and not is_eof(p):
                            skip_statement(p)
                        if check(p, "dedent"):
                            advance(p)
                else:
                    while not is_eof(p) and not check(p, "newline") and not check(p, "dedent"):
                        skip_expression(p)
                    if check(p, "newline"):
                        advance(p)
        return

    if check(p, "return") or check(p, "break") or check(p, "continue") or check(p, "pass"):
        advance(p)
        skip_expression_past(p)
        return

    if check(p, "let") or check(p, "var"):
        advance(p)
        skip_expression_past(p)
        return

    if check(p, "defer"):
        advance(p)
        if check(p, "colon"):
            advance(p)
            consume_nl(p)
            if check(p, "indent"):
                advance(p)
                while not check(p, "dedent") and not is_eof(p):
                    skip_statement(p)
                if check(p, "dedent"):
                    advance(p)
        else:
            skip_expression_past(p)
        return

    if check(p, "unsafe"):
        advance(p)
        skip_expression_past(p)
        return

    if check(p, "when") or check(p, "inline") or check(p, "parallel") or check(p, "detach") or check(p, "gather") or check(p, "emit") or check(p, "event"):
        advance(p)
        skip_expression_past(p)
        return

    skip_expression_past(p)

function skip_expression_past(p: ref[Parser]) -> void:
    while not is_eof(p) and not check(p, "newline") and not check(p, "dedent"):
        skip_expression(p)

    if check(p, "newline"):
        advance(p)

function skip_expression(p: ref[Parser]) -> void:
    if is_eof(p):
        return

    if check(p, "lparen") or check(p, "lbracket"):
        advance(p)
        skip_until_close(p)
    else:
        advance(p)

function skip_until_close(p: ref[Parser]) -> void:
    var depth: ptr_uint = 1
    while depth > 0 and not is_eof(p):
        if check(p, "lparen") or check(p, "lbracket"):
            depth += 1
        else if check(p, "rparen") or check(p, "rbracket"):
            depth -= 1
        advance(p)

# ── standalone expression parser (used by f-string embedded expressions) ──

public function parse_standalone_expr(source: str) -> string_mod.String:
    var p = Parser(
        tokens = ts.TokenStream.from_source(source),
        ast_buf = ast.AstBuf(buf = string_mod.String.create(), first_field = true),
        known_generics = vec_mod.Vec[str].create(),
        pending_packed = false,
        pending_alignment = 0,
        has_pending_alignment = false,
        pending_attrs = string_mod.String.create(),
    )
    collect_known_generics(ref_of(p))
    skip_newlines(ref_of(p))
    var result = parse_expr(ref_of(p))
    p.ast_buf.buf.release()
    p.pending_attrs.release()
    return result

# ── public entry point ────────────────────────────────────────────────────

public function parse_to_ast_json(source: str, module_name: str) -> string_mod.String:
    var p = Parser(
        tokens = ts.TokenStream.from_source(source),
        ast_buf = ast.AstBuf(buf = string_mod.String.create(), first_field = true),
        known_generics = vec_mod.Vec[str].create(),
        pending_packed = false,
        pending_alignment = 0,
        has_pending_alignment = false,
        pending_attrs = string_mod.String.create(),
    )
    collect_known_generics(ref_of(p))
    return parse_source_file(ref_of(p), module_name)

function consume_nl(p: ref[Parser]) -> void:
    while not is_eof(p) and not check(p, "newline") and not check(p, "dedent"):
        advance(p)
    if check(p, "newline"):
        advance(p)

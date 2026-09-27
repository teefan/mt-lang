## Debug info handler — the `milkTea/debugInfo` request.  Renders the host's
## sections (`lib/milk_tea/tooling/debug_info_formatter.rb`):
##
##   Header        file path and content size
##   Tokens        every token: lexeme, kind, location, semantic class
##   Parse Errors  parser diagnostics
##   Workspace     open documents and index state (self-host addition)
##
## The host's AST / Facts / Bindings sections render Ruby object ids, binding ids
## and Ruby AST class names; docs/self-host-plan.md §0k records what matching
## them requires.

import std.fmt
import std.json as json
import std.string as string
import std.vec as vec

import mtc.lexer.lexer as lexer_mod
import mtc.lexer.token as token_mod
import mtc.lexer.token_kinds as tk
import mtc.lsp.protocol as proto
import mtc.lsp.semantic_tokens as semtok
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace
import mtc.parser.parser as parser
import mtc.parser.state as pstate


## The debug dump for the document named by the request's `textDocument.uri`.
public function build_debug_text(ws: ref[workspace.Workspace], uri: str) -> string.String:
    var text = string.String.create()
    if uri.len == 0:
        text.append("error: no textDocument.uri")
        return text

    var file_path = uri_ops.file_uri_to_path(uri) else:
        text.append("error: invalid uri ")
        text.append(uri)
        return text
    defer: file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        text.append("error: cannot read ")
        text.append(file_path.as_str())
        return text
    defer: content.release()
    let source = content.as_str()

    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer: lex_diags.release()
    var tokens = lexer_mod.lex_reporting(source, ref_of(lex_diags))
    defer: tokens.release()

    # The line count the host prints is `content.count("\n") + 1`; the lexer's
    # last line is the same number.
    append_header(ref_of(text), file_path.as_str(), source, last_token_line(ref_of(tokens)))

    var classes = semtok.semantic_class_entries(ws, file_path.as_str(), source)
    defer: classes.release()
    append_token_section(ref_of(text), source, ref_of(tokens), ref_of(classes))

    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: parse_diags.release()
    let _file = parser.parse_source(source, ref_of(parse_diags))
    append_parse_errors(ref_of(text), ref_of(parse_diags))

    append_workspace_section(ref_of(text), ws)
    return text


## `File: <path>` / `Content: <lines> lines, <bytes> bytes`.
function append_header(target: ref[string.String], path: str, source: str, line_count: ptr_uint) -> void:
    target.append("File: ")
    target.append(path)
    target.append("\nContent: ")
    target.append_format(f"#{line_count} lines, #{source.len} bytes")


## The line of the token stream's last token (the eof), i.e. the number of lines
## the host reports for the content.
function last_token_line(tokens: ref[vec.Vec[token_mod.Token]]) -> ptr_uint:
    let last_index = if tokens.len() > 0: tokens.len() - 1 else: 0
    let tp = tokens.get(last_index) else:
        return 1
    return unsafe: read(tp).line


## The token table: a header with the count and a per-kind histogram, then one
## aligned line per token.
function append_token_section(
    target: ref[string.String],
    source: str,
    tokens: ref[vec.Vec[token_mod.Token]],
    classes: ref[vec.Vec[semtok.SemanticClass]],
) -> void:
    target.append("\n\n── Tokens  ")
    target.append_format(f"#{tokens.len()}")
    target.append("  (")
    append_token_histogram(target, tokens)
    target.append(") ")
    append_rule(target, 50)

    let max_len = token_table_lexeme_width(tokens)
    var ti: ptr_uint = 0
    while ti < tokens.len():
        let tp = tokens.get(ti) else:
            break
        let tok = unsafe: read(tp)
        let lexeme = unsafe: token_mod.token_lexeme(tok, source)
        let end_col = if tok.kind == tk.TokenKind.eof: tok.column else: tok.column + lexeme.len - 1

        target.append("\n  ")
        append_left_aligned(target, tok.line, 3)
        target.append(":")
        var column_text = uint_to_str(tok.column)
        append_right_padded(target, column_text.as_str(), 3)
        column_text.release()
        target.append("  ")
        var inspected = ruby_inspect(lexeme)
        append_right_padded(target, inspected.as_str(), max_len + 2)
        inspected.release()
        target.append("  ")
        append_right_padded(target, token_mod.kind_name(tok.kind), 16)
        target.append("  Ln ")
        append_left_aligned(target, tok.line, 2)
        target.append("  Col ")
        append_left_aligned(target, tok.column, 3)
        target.append("-")
        target.append_format(f"#{end_col}")
        target.append("  ")
        append_right_padded(target, semtok.semantic_class_at(classes, tok.line, tok.column), 22)
        target.append("  ")
        if tok.kind == tk.TokenKind.eof:
            target.append("◄")
        ti += 1


## The widest lexeme in the table, capped at 28; indentation tokens carry no text
## and never set the width.
function token_table_lexeme_width(tokens: ref[vec.Vec[token_mod.Token]]) -> ptr_uint:
    var width: ptr_uint = 0
    var i: ptr_uint = 0
    while i < tokens.len():
        let tp = tokens.get(i) else:
            break
        let tok = unsafe: read(tp)
        if tok.kind != tk.TokenKind.newline and tok.kind != tk.TokenKind.indent and tok.kind != tk.TokenKind.dedent:
            let len = if tok.end_offset > tok.start_offset: tok.end_offset - tok.start_offset else: 0
            if len > width:
                width = len
        i += 1
    if width > 28:
        return 28
    return width


## `75 identifier, 36 newline, ...`: kinds by descending count, ties in the order
## they first appear in the token stream (the host's `group_by` order).
function append_token_histogram(target: ref[string.String], tokens: ref[vec.Vec[token_mod.Token]]) -> void:
    var kinds = vec.Vec[tk.TokenKind].create()
    defer: kinds.release()
    var counts = vec.Vec[ptr_uint].create()
    defer: counts.release()

    var i: ptr_uint = 0
    while i < tokens.len():
        let tp = tokens.get(i) else:
            break
        let kind = unsafe: read(tp).kind
        var ki: ptr_uint = 0
        var found = false
        while ki < kinds.len():
            let kp = kinds.get(ki) else:
                break
            if unsafe: read(kp) == kind:
                let cp = counts.get(ki) else:
                    break
                unsafe: read(cp) = read(cp) + 1
                found = true
                break
            ki += 1
        if not found:
            kinds.push(kind)
            counts.push(1)
        i += 1

    # Insertion sort by descending count: stable, so equal counts keep the order
    # their kind first appeared in.
    var a: ptr_uint = 1
    while a < kinds.len():
        let count_a = counts.get(a) else:
            break
        let kind_a = kinds.get(a) else:
            break
        let entry_count = unsafe: read(count_a)
        let entry_kind = unsafe: read(kind_a)
        var b = a
        while b > 0:
            let prev_ptr = counts.get(b - 1) else:
                break
            let prev_count = unsafe: read(prev_ptr)
            if prev_count >= entry_count:
                break
            let cur_count = counts.get(b) else:
                break
            let cur_kind = kinds.get(b) else:
                break
            let prev_kind_ptr = kinds.get(b - 1) else:
                break
            unsafe:
                read(cur_count) = prev_count
                read(cur_kind) = read(prev_kind_ptr)
            b -= 1
        let final_count = counts.get(b) else:
            break
        let final_kind = kinds.get(b) else:
            break
        unsafe:
            read(final_count) = entry_count
            read(final_kind) = entry_kind
        a += 1

    var h: ptr_uint = 0
    while h < kinds.len():
        if h > 0:
            target.append(", ")
        let count_ptr = counts.get(h) else:
            break
        let kind_ptr = kinds.get(h) else:
            break
        target.append_format(f"#{unsafe: read(count_ptr)}")
        target.append(" ")
        target.append(token_mod.kind_name(unsafe: read(kind_ptr)))
        h += 1


function append_parse_errors(target: ref[string.String], errors: ref[vec.Vec[pstate.ParseDiagnostic]]) -> void:
    target.append("\n\n── Parse Errors  ")
    target.append_format(f"#{errors.len()}")
    if errors.len() == 0:
        target.append(" ──")
        return
    target.append("  ")
    append_rule(target, 55)
    var i: ptr_uint = 0
    while i < errors.len():
        let ep = errors.get(i) else:
            break
        let e = unsafe: read(ep)
        target.append("\n  ERROR [Ln ")
        target.append_format(f"#{e.line}")
        target.append(", Col ")
        target.append_format(f"#{e.column}")
        target.append("]: ")
        fmt.append_cstr(target, e.message)
        i += 1


## Self-host addition: the workspace state the server holds (the host has no
## equivalent section).
function append_workspace_section(target: ref[string.String], ws: ref[workspace.Workspace]) -> void:
    target.append("\n\n── Workspace (self-host) ")
    append_rule(target, 44)
    target.append("\n  root: ")
    target.append(ws.root_path.as_str())
    target.append("\n  module roots: ")
    target.append_format(f"#{ws.module_roots.len()}")
    target.append("\n  open documents: ")
    target.append_format(f"#{ws.open_document_count()}")
    target.append("\n  index built: ")
    target.append(if ws.index_built: "yes" else: "no")
    target.append("\n  index entries: ")
    target.append_format(f"#{ws.index_entries()}")
    target.append("\n  open files:")
    var keys = ws.open_docs.keys()
    while true:
        let kp = keys.next() else:
            break
        target.append("\n    ")
        target.append(unsafe: read(kp).as_str())


## `"lexeme"` with the escapes Ruby's `String#inspect` produces.
function ruby_inspect(lexeme: str) -> string.String:
    var text = string.String.from_str(lexeme)
    var escaped = escape_all(text)
    text.release()
    var quoted = string.String.create()
    quoted.append("\"")
    quoted.append(escaped.as_str())
    escaped.release()
    quoted.append("\"")
    return quoted


function escape_all(text: string.String) -> string.String:
    var pairs = vec.Vec[string.String].create()
    defer: pairs.release()
    pairs.push(string.String.from_str("\\"))
    pairs.push(string.String.from_str("\""))
    pairs.push(string.String.from_str("\n"))
    pairs.push(string.String.from_str("\t"))
    pairs.push(string.String.from_str("\r"))
    var replacements = vec.Vec[string.String].create()
    defer: replacements.release()
    replacements.push(string.String.from_str("\\\\"))
    replacements.push(string.String.from_str("\\\""))
    replacements.push(string.String.from_str("\\n"))
    replacements.push(string.String.from_str("\\t"))
    replacements.push(string.String.from_str("\\r"))

    var current = string.String.from_str(text.as_str())
    var i: ptr_uint = 0
    while i < pairs.len():
        let needle = pairs.get(i) else:
            break
        let replacement = replacements.get(i) else:
            break
        var next = unsafe: current.replace(read(needle).as_str(), read(replacement).as_str())
        current.release()
        current = next
        i += 1
    return current


## `%3d`: right-aligned in `width`.
function append_left_aligned(target: ref[string.String], value: ptr_uint, width: ptr_uint) -> void:
    var digits: ptr_uint = 1
    var v = value
    while v >= 10:
        v /= 10
        digits += 1
    var pad = width
    while pad > digits:
        target.append(" ")
        pad -= 1
    target.append_format(f"#{value}")


## `%-Ns`: left-aligned in `width` (never truncating).
function append_right_padded(target: ref[string.String], value: str, width: ptr_uint) -> void:
    target.append(value)
    var pad = width
    while pad > value.len:
        target.append(" ")
        pad -= 1


function uint_to_str(value: ptr_uint) -> string.String:
    var text = string.String.create()
    text.append_format(f"#{value}")
    return text


function append_rule(target: ref[string.String], count: ptr_uint) -> void:
    var i: ptr_uint = 0
    while i < count:
        target.append("─")
        i += 1


public function handle_debug_info(ws: ref[workspace.Workspace], params: json.Value, id: json.Value) -> void:
    var text = build_debug_text(ws, debug_uri(params))
    defer: text.release()

    var result = json.create_object_value()
    let result_obj = result.as_object() else:
        proto.write_error(id, -32603, "debug info failed")
        return
    unsafe:
        read(result_obj).set("text", json.string_from_str(text.as_str()))
    proto.write_response(id, result)


## `params.textDocument.uri`, or "" when absent.
function debug_uri(params: json.Value) -> str:
    return proto.extract_text_doc_uri(params)

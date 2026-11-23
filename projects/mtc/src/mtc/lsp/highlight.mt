## Document highlight — same-file occurrences of the identifier under the
## cursor, returned as DocumentHighlight objects (kind 1 = Text).

import std.fmt
import std.json as json
import std.str
import std.string as string
import std.vec as vec

import mtc.lsp.cursor as cursor
import mtc.lsp.protocol as proto
import mtc.lsp.scope as scope_mod
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace
import mtc.parser.ast as ast


## Handle textDocument/documentHighlight.
public function handle_document_highlight(
    ws: ref[workspace.Workspace],
    uri: str,
    line: ptr_uint,
    character: ptr_uint,
    id: json.Value,
) -> void:
    var file_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_response_raw(id, "[]")
        return
    defer: file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        proto.write_response_raw(id, "[]")
        return
    defer: content.release()

    let source = content.as_str()
    let target = cursor.identifier_at(source, line, character) else:
        proto.write_response_raw(id, "[]")
        return

    var occurrences = cursor.identifier_occurrences(source, target.text)
    defer: occurrences.release()

    # A local's occurrences are scoped like the host's binding resolution: the
    # highlight must not light up a same-named local in an unrelated function
    # (`var v` in two demos).  Every other name keeps the whole-file rule.
    var scoped_line = Option[ptr_uint].none
    let doc = workspace.document_analysis_for(ws, file_path.as_str()) else:
        proto.write_response_raw(id, "null")
        return
    var ast_file = doc.ast_file
    var bindings = scope_mod.collect_bindings(source, ast_file)
    defer: bindings.release()
    scoped_line = scope_mod.local_binding_line(ref_of(bindings), target.text, line + 1)

    # The implicit receiver: the host binds `this` as a parameter of the
    # enclosing method, so only that method's occurrences answer.
    var this_span = Option[MethodSpan].none
    if target.text.equal("this"):
        this_span = enclosing_method_span(ast_file, line + 1)

    var json_text = string.String.create()
    defer: json_text.release()
    json_text.append("[")
    var emitted: ptr_uint = 0
    var oi: ptr_uint = 0
    while oi < occurrences.len():
        let op = occurrences.get(oi) else:
            break
        let occ = unsafe: read(op)
        match scoped_line:
            Option.some as binding_line:
                if not scope_mod.is_in_same_scope(ref_of(bindings), target.text, binding_line.value, occ.line):
                    oi += 1
                    continue
                # The host's arm lists the AST identifier nodes bound to the
                # binding; a named-argument label, a member name after a dot, a
                # call's callee and a destructuring pattern's name are not
                # identifiers it binds, so they never appear.
                if unbound_occurrence(source, occ.line, occ.column, occ.length):
                    oi += 1
                    continue
            Option.none:
                pass
        match this_span:
            Option.some as method_span:
                if occ.line < method_span.value.start or occ.line > method_span.value.end:
                    oi += 1
                    continue
            Option.none:
                pass
        if emitted > 0:
            json_text.append(",")
        emitted += 1
        let lz = if occ.line > 0: occ.line - 1 else: 0z
        let col = if occ.column > 0: occ.column - 1 else: 0z
        let out_col = ws.output_character_in(source, lz, col)
        let out_end = ws.output_character_in(source, lz, col + occ.length)
        json_text.append("{\"range\":{\"start\":{\"line\":")
        json_text.append_format(f"#{lz}")
        json_text.append(",\"character\":")
        json_text.append_format(f"#{out_col}")
        json_text.append("},\"end\":{\"line\":")
        json_text.append_format(f"#{lz}")
        json_text.append(",\"character\":")
        json_text.append_format(f"#{out_end}")
        json_text.append("}},\"kind\":1}")
        oi += 1
    json_text.append("]")
    proto.write_response_raw(id, json_text.as_str())


## The line span (1-based, inclusive) of the enclosing `extending` block's
## instance method — the scope the host binds `this` in.  None when the cursor
## is outside an `extending` block or in one of its `static` methods (which have
## no receiver).
public struct MethodSpan:
    start: ptr_uint
    end: ptr_uint


function enclosing_method_span(file: ast.SourceFile, target_line: ptr_uint) -> Option[MethodSpan]:
    var enclosing: ptr_uint = 0
    var enclosing_line: ptr_uint = 0
    var found = false
    var di: ptr_uint = 0
    while di < file.declarations.len:
        let line = scope_mod.decl_start_line(unsafe: read(file.declarations.data + di))
        if line > 0 and line <= target_line and line >= enclosing_line:
            enclosing_line = line
            enclosing = di
            found = true
        di += 1
    if not found:
        return Option[MethodSpan].none

    var decl: ast.Decl
    unsafe:
        decl = read(file.declarations.data + enclosing)
    match decl:
        ast.Decl.decl_extending_block as ext:
            var start: ptr_uint = 0
            var next_line: ptr_uint = 0
            var mi: ptr_uint = 0
            while mi < ext.methods.len:
                let method = unsafe: read(ext.methods.data + mi)
                if method.line <= target_line and method.method_kind != ast.MethodKind.mk_static:
                    start = method.line
                    next_line = 0
                    if mi + 1 < ext.methods.len:
                        next_line = unsafe: read(ext.methods.data + mi + 1).line
                mi += 1
            if start == 0:
                return Option[MethodSpan].none
            if next_line == 0:
                # The block's last method: the next top-level declaration bounds
                # the span, else the rest of the file.
                var dj: ptr_uint = 0
                while dj < file.declarations.len:
                    let line = scope_mod.decl_start_line(unsafe: read(file.declarations.data + dj))
                    if line > enclosing_line and (next_line == 0 or line < next_line):
                        next_line = line
                    dj += 1
            let end = if next_line > 0: next_line - 1 else: 1000000000z
            return Option[MethodSpan].some(value = MethodSpan(start = start, end = end))
        _:
            pass
    return Option[MethodSpan].none


## True when the identifier at 1-based (`line`, `column`) is an occurrence the
## host's binding resolution never binds: a member name after a dot, a call's
## callee, a named-argument label (`name = value` starting an argument) or a
## name inside a `let (a, b) = …` destructuring pattern.
function unbound_occurrence(source: str, line: ptr_uint, column: ptr_uint, length: ptr_uint) -> bool:
    let start = byte_offset_at(source, line, column)
    if start >= source.len or line == 0 or column == 0:
        return false
    let end = start + length

    # A member name: the previous significant byte is a dot.
    var before = start
    while before > 0 and is_space_byte(source.byte_at(before - 1)):
        before -= 1
    if before > 0 and source.byte_at(before - 1) == '.':
        return true

    # A callee: the next significant byte opens an argument list.
    var after = end
    while after < source.len and is_space_byte(source.byte_at(after)):
        after += 1
    if after < source.len and source.byte_at(after) == '(':
        return true

    # A named-argument label: `name = ` (not `==`) and the name starts an
    # argument (`(` or `,` before it, ignoring spaces).
    if after < source.len and source.byte_at(after) == '=' and (after + 1 >= source.len or source.byte_at(after + 1) != '='):
        if before > 0:
            let previous = source.byte_at(before - 1)
            if previous == '(' or previous == ',':
                return true

    # A destructuring pattern's name: the nearest unclosed `(` before the name is
    # introduced by `let` or `var` (`let (a, b) = …`), unlike a call's arguments.
    if before == 0:
        return false
    let previous = source.byte_at(before - 1)
    if previous != '(' and previous != ',':
        return false
    var paren = before
    while paren > 0 and source.byte_at(paren - 1) != '(' and source.byte_at(paren - 1) != ')':
        paren -= 1
    if paren == 0 or source.byte_at(paren - 1) != '(':
        return false
    var word_end = paren - 1
    while word_end > 0 and is_space_byte(source.byte_at(word_end - 1)):
        word_end -= 1
    var word_start = word_end
    while word_start > 0 and is_identifier_byte(source.byte_at(word_start - 1)):
        word_start -= 1
    let word = source.slice(word_start, word_end - word_start)
    return word.equal("let") or word.equal("var")


## The byte offset of 1-based (`line`, `column`) in `source`.
function byte_offset_at(source: str, line: ptr_uint, column: ptr_uint) -> ptr_uint:
    if line == 0 or column == 0:
        return source.len
    var current_line: ptr_uint = 1
    var offset: ptr_uint = 0
    while offset < source.len and current_line < line:
        if source.byte_at(offset) == '\n':
            current_line += 1
        offset += 1
    if offset >= source.len:
        return source.len
    return offset + (column - 1)


function is_space_byte(b: ubyte) -> bool:
    return b == ' ' or b == '\t' or b == '\r'


function is_identifier_byte(b: ubyte) -> bool:
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_'

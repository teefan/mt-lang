## Document link handler.  Scans string and cstring literals for relative
## file paths, checks whether the target file exists, and returns
## DocumentLink entries with optional resolve support showing the first
## line of the linked file as a tooltip.

import std.fmt
import std.fs as fs_mod
import std.json as json
import std.path as path_ops
import std.str
import std.string as string

import mtc.lexer.lexer as lexer
import mtc.lexer.token as tok
import mtc.lexer.token_kinds as tk
import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace


## Handle textDocument/documentLink.  Scans the document source for string
## and cstring literals that look like file paths and returns DocumentLink
## entries for ones that resolve to existing files.
public function handle_document_link(
    ws: ref[workspace.Workspace],
    params: json.Value,
    id: json.Value,
) -> void:
    let uri = proto.extract_text_doc_uri(params)
    if uri.len == 0:
        proto.write_error(id, -32602, "invalid params: missing textDocument.uri")
        return

    var file_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_error(id, -32602, "invalid uri")
        return
    defer file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        proto.write_response_raw(id, "[]")
        return
    defer content.release()

    let source = content.as_str()
    let dir = path_ops.dirname(file_path.as_str())

    var tokens = lexer.lex(source)
    defer tokens.release()

    var result = string.String.create()
    defer result.release()
    result.append("[")
    var first = true

    var ti: ptr_uint = 0
    while ti < tokens.len():
        let tp = tokens.get(ti) else:
            break
        let token = unsafe: read(tp)
        if token.kind == tk.TokenKind.string or token.kind == tk.TokenKind.cstring or token.kind == tk.TokenKind.fstring:
            let text = token_text(source, token)
            let cleaned = strip_quotes(token.kind, text)
            if looks_like_path(cleaned):
                var resolved = resolve_link(file_path.as_str(), dir, cleaned)
                if resolved.len() > 0:
                    var target_uri = build_file_uri(resolved.as_str())
                    if not first:
                        result.append(",")
                    first = false
                    let tok_len = token.end_offset - token.start_offset
                    append_link(ref_of(result), token.line, token.column, tok_len, target_uri.as_str())
                    resolved.release()
                    target_uri.release()
                else:
                    resolved.release()
        ti += 1

    result.append("]")
    proto.write_response_raw(id, result.as_str())


## Handle documentLink/resolve.  Adds a tooltip with the first line of
## the linked file.
public function handle_document_link_resolve(
    params: json.Value,
    id: json.Value,
) -> void:
    let target_uri = extract_string_field(params, "target")
    if target_uri.len == 0:
        proto.write_response(id, params)
        return

    var target_path = uri_ops.file_uri_to_path(target_uri) else:
        proto.write_response(id, params)
        return
    defer target_path.release()

    var tooltip = string.String.create()
    defer tooltip.release()

    match fs_mod.read_text(target_path.as_str()):
        Result.success as payload:
            var content = payload.value
            var start = content.as_str()
            var i: ptr_uint = 0
            while i < start.len:
                let b = start.byte_at(i)
                if b == '\n' or b == '\r':
                    tooltip.append(start.slice(0, i))
                    break
                i += 1
            if i >= start.len:
                tooltip.append(start)
            content.release()
        Result.failure:
            proto.write_response(id, params)
            return

    # Build response with tooltip added.
    var result_json = string.String.create()
    defer result_json.release()

    # Rebuild the params as a string, then inject tooltip.
    var base = string.String.create()
    defer base.release()
    base.append("{")
    append_field_str(ref_of(base), "target", target_uri, false)
    base.append(",\"tooltip\":\"")
    proto.append_escaped(ref_of(base), tooltip.as_str())
    base.append("\"}")

    proto.write_response_raw(id, base.as_str())


## Extract the text content of a token from the source, using lexer offsets.
function token_text(source: str, t: tok.Token) -> str:
    return tok.token_lexeme(t, source)


## Strip surrounding quotes from a string token.
function strip_quotes(kind: tk.TokenKind, text: str) -> str:
    if text.len < 2:
        return text
    if kind == tk.TokenKind.string or kind == tk.TokenKind.fstring:
        if text.byte_at(0) == '"' and text.byte_at(text.len - 1) == '"':
            return text.slice(1, text.len - 2)
    if kind == tk.TokenKind.cstring:
        if text.len >= 3 and text.byte_at(0) == 'c' and text.byte_at(1) == '"' and text.byte_at(text.len - 1) == '"':
            return text.slice(2, text.len - 3)
    return text


## True when a string literal looks like a relative file path.
function looks_like_path(text: str) -> bool:
    if text.len == 0 or text.len > 512:
        return false
    if text.starts_with("./") or text.starts_with("../"):
        return true
    if text.len >= 2:
        let first = ubyte<-text.byte_at(0)
        if (first >= 'a' and first <= 'z') or (first >= 'A' and first <= 'Z'):
            var i: ptr_uint = 1
            while i < text.len:
                let b = text.byte_at(i)
                if (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_':
                    i += 1
                    continue
                if b == '/' or b == '.':
                    return true
                return false
    return false


## Resolve a relative path against the document's directory.
## Returns an owned string.String that the caller must release, or
## an empty string.String when the target does not exist.
function resolve_link(file_path: str, dir: str, target: str) -> string.String:
    var joined = path_ops.join(dir, target)
    if fs_mod.exists(joined.as_str()):
        return joined
    joined.release()
    return string.String.create()


## Build a file:// URI from an absolute path.  Returns an owned
## string.String that the caller must release.
function build_file_uri(path: str) -> string.String:
    var uri = string.String.create()
    uri.append("file://")
    var i: ptr_uint = 0
    while i < path.len:
        let b = path.byte_at(i)
        if b == ' ':
            uri.append("%20")
        else if b == '%':
            uri.append("%25")
        else:
            uri.push_byte(b)
        i += 1
    return uri


## Extract a string field from a JSON object.  Returns "" when absent.
function extract_string_field(value: json.Value, field: str) -> str:
    let obj_ptr = value.as_object()
    if obj_ptr == null:
        return ""
    unsafe:
        let field_ptr = read(obj_ptr).get(field)
        if field_ptr == null:
            return ""
        let field_str = read(field_ptr).as_string() else:
            return ""
        return field_str


## Append a single DocumentLink entry to the JSON array.
function append_link(output: ref[string.String], line: ptr_uint, column: ptr_uint, length: ptr_uint, target_uri: str) -> void:
    output.append("{\"range\":{\"start\":{\"line\":")
    output.append_format(f"#{line - 1}")
    output.append(",\"character\":")
    output.append_format(f"#{column - 1}")
    output.append("},\"end\":{\"line\":")
    output.append_format(f"#{line - 1}")
    output.append(",\"character\":")
    output.append_format(f"#{(column - 1) + length}")
    output.append("}},\"target\":\"")
    proto.append_escaped(output, target_uri)
    output.append("\",\"tooltip\":\"")
    proto.append_escaped(output, target_uri)
    output.append("\"}")


## Append a string-valued JSON field.
function append_field_str(output: ref[string.String], name: str, value: str, first: bool) -> void:
    if not first:
        output.append(",")
    output.append("\"")
    output.append(name)
    output.append("\":\"")
    proto.append_escaped(output, value)
    output.append("\"")

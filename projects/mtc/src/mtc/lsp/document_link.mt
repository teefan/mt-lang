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
import std.vec as vec

import mtc.lexer.lexer as lexer_mod
import mtc.lexer.token as token_mod
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
    defer: file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        proto.write_response_raw(id, "[]")
        return
    defer: content.release()

    let source = content.as_str()
    let dir = path_ops.dirname(file_path.as_str())

    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer: lex_diags.release()
    var tokens = lexer_mod.lex_reporting(source, ref_of(lex_diags))
    defer: tokens.release()

    var result = string.String.create()
    defer: result.release()
    result.append("[")
    var first = true

    var ti: ptr_uint = 0
    while ti < tokens.len():
        let tp = tokens.get(ti) else:
            break
        let token = unsafe: read(tp)
        if (
            token.kind == tk.TokenKind.string
            or token.kind == tk.TokenKind.cstring
            or token.kind == tk.TokenKind.fstring
        ):
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

## Handle documentLink/resolve.  Echoes the link back with a `tooltip` of the
## form `"<path>\n<first line>"` (host `handle_document_link_resolve`); a link
## whose target is missing or unreadable comes back unchanged.

public function handle_document_link_resolve(
    params: json.Value,
    id: json.Value,
) -> void:
    let target_uri = extract_string_field(params, "target")
    if target_uri.len == 0 or not target_uri.starts_with("file://"):
        proto.write_response(id, params)
        return

    var target_path = uri_ops.file_uri_to_path(target_uri) else:
        proto.write_response(id, params)
        return
    defer: target_path.release()

    let obj_ptr = params.as_object()
    if obj_ptr == null:
        proto.write_response(id, params)
        return

    var first_line = read_first_line(target_path.as_str())
    if first_line.is_none():
        proto.write_response(id, params)
        return
    var line_text = first_line.unwrap()
    defer: line_text.release()
    let stripped = line_text.as_str().trim_ascii_whitespace()

    var tooltip = string.String.create()
    defer: tooltip.release()
    tooltip.append(target_path.as_str())
    if stripped.len > 0:
        tooltip.append("\n")
        tooltip.append(stripped)

    unsafe:
        read(obj_ptr).set("tooltip", json.string_from_str(tooltip.as_str()))

    proto.write_response(id, params)

## The first line of a text file, or none when it cannot be read.

function read_first_line(path: str) -> Option[string.String]:
    match fs_mod.read_text(path):
        Result.success as payload:
            var content = payload.value
            var line = string.String.create()
            let text = content.as_str()
            var i: ptr_uint = 0
            while i < text.len:
                let b = text.byte_at(i)
                if b == '\n' or b == '\r':
                    break
                i += 1
            line.append(text.slice(0, i))
            content.release()
            return Option[string.String].some(value = line)
        Result.failure:
            return Option[string.String].none

## Extract the text content of a token from the source, using lexer offsets.

function token_text(source: str, t: token_mod.Token) -> str:
    return token_mod.token_lexeme(t, source)

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

function append_link(
    output: ref[string.String],
    line: ptr_uint,
    column: ptr_uint,
    length: ptr_uint,
    target_uri: str
) -> void:
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
    output.append("\",\"tooltip\":\"Open linked file\"}")

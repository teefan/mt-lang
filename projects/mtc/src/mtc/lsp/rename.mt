## Rename — find all occurrences of an identifier and return a WorkspaceEdit.
##
## Text-based scan (same approach as references) with a single TextEdit per file.

import std.fmt
import std.fs as fs_mod
import std.json as json
import std.str
import std.string as string

import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops


## Handle textDocument/rename.
public function handle_rename(uri: str, line: ptr_uint, character: ptr_uint, new_name: str, id: json.Value) -> void:
    var file_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_response(id, json.null_value())
        return
    defer file_path.release()

    var content = string.String.create()
    defer content.release()
    var read_result = fs_mod.read_text(file_path.as_str())
    match read_result:
        Result.success as c:
            content.assign(c.value.as_str())
        Result.failure:
            proto.write_response(id, json.null_value())
            return

    let source = content.as_str()
    var byte_offset = utf16_to_byte_offset(source, line, character)
    var target_name = extract_identifier_at_offset(source, byte_offset)
    if target_name.len == 0:
        proto.write_response(id, json.null_value())
        return

    var edits_json = build_rename_edits_json(source, target_name, uri, new_name)
    proto.write_response_raw(id, edits_json.as_str())
    edits_json.release()


## Build a WorkspaceEdit JSON with changes for all occurrences of `old_name`.
function build_rename_edits_json(source: str, old_name: str, uri: str, new_name: str) -> string.String:
    var result = string.String.create()
    result.append("{\"changes\":{\"")
    append_escaped(ref_of(result), uri)
    result.append("\":[")
    var first = true
    var n: ptr_uint = 0
    var line: ptr_uint = 0
    var line_start: ptr_uint = 0
    while n < source.len:
        if source.byte_at(n) == 10:
            line += 1
            line_start = n + 1
            n += 1
            continue
        var matched = true
        var mi: ptr_uint = 0
        while mi < old_name.len:
            if n + mi >= source.len or source.byte_at(n + mi) != old_name.byte_at(mi):
                matched = false
                break
            mi += 1
        if matched:
            var before_ok = true
            if n > 0: before_ok = not is_ident_cont(source.byte_at(n - 1))
            var after_ok = true
            let after = n + old_name.len
            if after < source.len: after_ok = not is_ident_cont(source.byte_at(after))
            if before_ok and after_ok:
                if not first: result.append(",")
                first = false
                let col = n - line_start
                let lz = if line > 0: ptr_uint<-(int<-(line) - 1) else: 0z
                result.append("{\"range\":{\"start\":{\"line\":")
                result.append_format(f"#{lz}")
                result.append(",\"character\":")
                result.append_format(f"#{col}")
                result.append("},\"end\":{\"line\":")
                result.append_format(f"#{lz}")
                result.append(",\"character\":")
                result.append_format(f"#{col + old_name.len}")
                result.append("}},\"newText\":\"")
                append_escaped(ref_of(result), new_name)
                result.append("\"}")
            n += old_name.len
        else:
            n += 1
    result.append("]}}")
    return result


function is_ident_cont(ch: ubyte) -> bool:
    return (ch >= 65 and ch <= 90) or (ch >= 97 and ch <= 122) or ch == 95 or (ch >= 48 and ch <= 57)


function extract_identifier_at_offset(source: str, byte_offset: ptr_uint) -> str:
    if byte_offset >= source.len:
        return ""
    var pos = byte_offset
    if pos > 0 and not is_ident_cont(source.byte_at(pos)):
        pos -= 1
    var start = pos
    while start > 0 and is_ident_cont(source.byte_at(start - 1)):
        start -= 1
    var stop = pos
    while stop < source.len and is_ident_cont(source.byte_at(stop)):
        stop += 1
    if stop <= start:
        return ""
    return unsafe: str(data = ptr[char]<-source.data + start, len = stop - start)


function utf16_to_byte_offset(source: str, line: ptr_uint, character: ptr_uint) -> ptr_uint:
    var current_line: ptr_uint = 0
    var pos: ptr_uint = 0
    while pos < source.len and current_line < line:
        if source.byte_at(pos) == 10: current_line += 1
        pos += 1
    var remaining = character
    while pos < source.len and remaining > 0 and source.byte_at(pos) != 10:
        pos += 1
        remaining -= 1
    return pos


function append_escaped(output: ref[string.String], text: str) -> void:
    var i: ptr_uint = 0
    while i < text.len:
        let b = text.byte_at(i)
        if b == 34: output.append("\\\"") else if b == 92: output.append("\\\\") else: output.push_byte(b)
        i += 1

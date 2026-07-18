## Signature help — parameter hints on '(' in function calls.
##
## When the cursor is inside a function call's parentheses, resolves the
## function name via text-based extraction (same approach as navigation),
## looks up the FnSig in the semantic Analysis maps, and returns the
## parameter list as LSP SignatureHelp.

import std.fmt
import std.fs as fs_mod
import std.json as json
import std.str
import std.string as string
import std.vec as vec

import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types_mod
import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops


## Handle textDocument/signatureHelp.
public function handle_signature_help(uri: str, line: ptr_uint, character: ptr_uint, id: json.Value) -> void:
    var file_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_response(id, json.null_value())
        return
    defer file_path.release()

    var content = string.String.create()
    defer content.release()
    if not read_file_into(ref_of(content), file_path.as_str()):
        proto.write_response(id, json.null_value())
        return

    let source = content.as_str()
    var byte_offset = utf16_to_byte_offset(source, line, character)
    var func_name = extract_call_name_at_offset(source, byte_offset)
    if func_name.len == 0:
        proto.write_response(id, json.null_value())
        return

    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    var analysis = analyzer.check_source_file(ast_file)

    var sig_opt: Option[analyzer.FnSig]
    unsafe:
        let sig_ptr = analysis.functions.get(func_name)
        if sig_ptr != null:
            sig_opt = Option[analyzer.FnSig].some(value = read(sig_ptr))

    match sig_opt:
        Option.some as sig_payload:
            var sig = sig_payload.value
            var json_text = build_signature_help_json(ref_of(sig), func_name)
            proto.write_response_raw(id, json_text.as_str())
            json_text.release()
        Option.none:
            proto.write_response(id, json.null_value())


## Extract the function name when the cursor is inside a call expression like
## `foo(arg1, ...)`.  Scans left from the cursor to find the function name
## before the opening paren.
function extract_call_name_at_offset(source: str, byte_offset: ptr_uint) -> str:
    if byte_offset >= source.len:
        return ""
    # Find the nearest '(' to the left.
    var paren_depth: int = 0
    var pos: ptr_uint = byte_offset
    while pos > 0:
        pos -= 1
        let ch = source.byte_at(pos)
        if ch == 41:  # ')'
            paren_depth += 1
        else if ch == 40:  # '('
            if paren_depth == 0:
                # Found the opening paren.  Now scan left for the function name.
                var name_end = pos
                # Skip whitespace between name and '('.
                while name_end > 0 and is_space(source.byte_at(name_end - 1)):
                    name_end -= 1
                if name_end == 0:
                    return ""
                var name_start = name_end
                while name_start > 0 and is_ident_cont(source.byte_at(name_start - 1)):
                    name_start -= 1
                if name_start == name_end:
                    return ""
                return unsafe: str(data = ptr[char]<-source.data + name_start, len = name_end - name_start)
            else:
                paren_depth -= 1
    return ""


function is_space(ch: ubyte) -> bool:
    return ch == 32 or ch == 9 or ch == 10 or ch == 13


function is_ident_cont(ch: ubyte) -> bool:
    return (ch >= 65 and ch <= 90) or (ch >= 97 and ch <= 122) or ch == 95 or (ch >= 48 and ch <= 57)


## Build a SignatureHelp JSON string.
function build_signature_help_json(sig: ref[analyzer.FnSig], func_name: str) -> string.String:
    var result = string.String.create()
    result.append("{\"signatures\":[{\"label\":\"")
    result.append(func_name)
    result.append("(")
    var first = true
    var pi: ptr_uint = 0
    unsafe:
        while pi < read(sig).params.len:
            let param = read(read(sig).params.data + pi)
            if not first:
                result.append(", ")
            first = false
            result.append(param.name)
            result.append(": ")
            var type_name = types_mod.type_to_string(param.ty)
            result.append(type_name)
            pi += 1
    result.append(")\",\"parameters\":[")
    pi = 0
    first = true
    unsafe:
        while pi < read(sig).params.len:
            let param = read(read(sig).params.data + pi)
            if not first:
                result.append(",")
            first = false
            result.append("{\"label\":\"")
            result.append(param.name)
            result.append(": ")
            var type_name = types_mod.type_to_string(param.ty)
            result.append(type_name)
            result.append("\"}")
            pi += 1
    result.append("]}],\"activeSignature\":0,\"activeParameter\":0}")
    return result


function read_file_into(dest: ref[string.String], path: str) -> bool:
    var read_result = fs_mod.read_text(path)
    match read_result:
        Result.success as content:
            dest.assign(content.value.as_str())
            return true
        Result.failure:
            return false


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

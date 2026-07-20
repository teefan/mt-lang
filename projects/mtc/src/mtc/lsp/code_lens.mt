## Code lens handler.  Emits CodeLens entries for each function declaration
## in the document and resolves them to show reference counts via the
## workspace symbol index.

import std.fmt
import std.fs as fs_mod
import std.json as json
import std.str
import std.string as string
import std.vec as vec

import mtc.parser.ast as ast
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace
import mtc.lsp.workspace_index as idx


## LSP SymbolKind for codeLens data items.
const KIND_FUNCTION: int = 12
const KIND_METHOD:   int = 6


## Handle textDocument/codeLens.  Returns CodeLens entries for every
## function declaration in the document.
public function handle_code_lens(
    ws: ref[workspace.Workspace],
    uri: str,
    id: json.Value,
) -> void:
    var file_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_response(id, json.null_value())
        return
    defer file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        proto.write_response(id, json.null_value())
        return
    defer content.release()

    let source = content.as_str()
    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))

    var result = string.String.create()
    defer result.release()
    result.append("[")
    var first = true

    var di: ptr_uint = 0
    while di < ast_file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(ast_file.declarations.data + di)
        match decl:
            ast.Decl.decl_function as fun:
                append_lens(ref_of(result), fun.name, fun.line, file_path.as_str(), ref_of(first))
            ast.Decl.decl_foreign_function as ff:
                append_lens(ref_of(result), ff.name, ff.line, file_path.as_str(), ref_of(first))
            ast.Decl.decl_extending_block as ext:
                var mi: ptr_uint = 0
                while mi < ext.methods.len:
                    var mfn: ast.Method
                    unsafe:
                        mfn = read(ext.methods.data + mi)
                    append_lens(ref_of(result), mfn.name, mfn.line, file_path.as_str(), ref_of(first))
                    mi += 1
            _:
                pass
        di += 1

    result.append("]")
    proto.write_response_raw(id, result.as_str())


## Handle codeLens/resolve.  Counts references to the function across the
## workspace index and returns the count.
public function handle_code_lens_resolve(
    ws: ref[workspace.Workspace],
    params: json.Value,
    id: json.Value,
) -> void:
    let name = extract_string_field(params, "data")
    if name.len == 0:
        proto.write_response(id, params)
        return

    ws.build_index_if_needed()
    var count = count_references(name, ws)
    if count == 0:
        proto.write_response(id, params)
        return

    var result_json = string.String.create()
    defer result_json.release()
    result_json.append("{\"command\":{\"title\":\"")
    result_json.append_format(f"#{count} references")
    result_json.append("\",\"command\":\"\"}}")

    proto.write_response_raw(id, result_json.as_str())


## Count references to a named symbol across the workspace index.
## Searches all indexed .mt files for occurrences of the name.
function count_references(name: str, ws: ref[workspace.Workspace]) -> ptr_uint:
    var total: ptr_uint = 0
    var max_results: ptr_uint = 500
    var results = idx.query_index(ref_of(ws.index), "", max_results)
    defer results.release()

    var ri: ptr_uint = 0
    while ri < results.len():
        let rp = results.get(ri) else:
            break
        let ei = unsafe: read(rp)
        let ep = ws.index.entries.get(ei) else:
            break
        let entry = unsafe: read(ep)
        if entry.name.as_str().equal(name):
            let path = entry.path.as_str()
            match fs_mod.read_text(path):
                Result.success as payload:
                    var content = payload.value
                    total += count_occurrences(content.as_str(), name)
                    content.release()
                Result.failure:
                    pass
        ri += 1

    return total


## Count token-level occurrences of a name in source text.
function count_occurrences(source: str, name: str) -> ptr_uint:
    var count: ptr_uint = 0
    var i: ptr_uint = 0
    while i + name.len <= source.len:
        let b = source.byte_at(i)
        if (b & ubyte<-(0xC0)) == ubyte<-(0x80):
            i += 1
            continue
        if source.slice(i, name.len).equal(name):
            # Check word boundaries.
            var is_start = i == 0
            if i > 0:
                let before = source.byte_at(i - 1)
                is_start = not is_word_byte(before)
            var after = i + name.len
            var is_end = after >= source.len
            if after < source.len:
                let after_byte = source.byte_at(after)
                is_end = not is_word_byte(after_byte)
            if is_start and is_end:
                count += 1
        i += 1
    return count


## True when a byte is part of an identifier character.
function is_word_byte(b: ubyte) -> bool:
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or
        (b >= '0' and b <= '9') or b == '_'


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


## Append a single CodeLens entry for a named symbol.
function append_lens(
    output: ref[string.String],
    name: str,
    line: ptr_uint,
    path: str,
    first_var: ref[bool],
) -> void:
    if not unsafe: read(first_var):
        output.append(",")
    unsafe: read(first_var) = false

    let lz = if line > 0: line - 1 else: 0z
    output.append("{\"range\":{\"start\":{\"line\":")
    output.append_format(f"#{lz}")
    output.append(",\"character\":0},\"end\":{\"line\":")
    output.append_format(f"#{lz}")
    output.append(",\"character\":0}},\"data\":\"")
    proto.append_escaped(output, name)
    output.append("\",\"command\":{\"title\":\"references\",\"command\":\"\"}}")

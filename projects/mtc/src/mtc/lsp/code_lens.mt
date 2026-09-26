## Code lens handler.  Emits CodeLens entries for each function declaration
## in the document and resolves them to show reference counts via the
## workspace symbol index.

import std.fmt
import std.fs as fs_mod
import std.json as json
import std.log as log
import std.map as map_mod
import std.str
import std.string as string
import std.vec as vec

import mtc.parser.ast as ast
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.lsp.cursor as cursor
import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops
import mtc.lsp.utils as utils
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
    defer: file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        proto.write_response(id, json.null_value())
        return
    defer: content.release()

    let source = content.as_str()
    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))

    var result = string.String.create()
    defer: result.release()
    result.append("[")
    var first = true

    var di: ptr_uint = 0
    while di < ast_file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(ast_file.declarations.data + di)
        match decl:
            ast.Decl.decl_function as fun:
                append_lens(ref_of(result), uri, fun.name, fun.line, fun.column, ref_of(first))
            ast.Decl.decl_extern_function as ef:
                append_lens(
                    ref_of(result),
                    uri,
                    ef.name,
                    ef.line,
                    token_column(source, ef.line, ef.name),
                    ref_of(first)
                )
            ast.Decl.decl_foreign_function as ff:
                append_lens(
                    ref_of(result),
                    uri,
                    ff.name,
                    ff.line,
                    token_column(source, ff.line, ff.name),
                    ref_of(first)
                )
            ast.Decl.decl_interface as iface:
                var mi: ptr_uint = 0
                while mi < iface.interface_methods.len:
                    var mfn: ast.InterfaceMethod
                    unsafe:
                        mfn = read(iface.interface_methods.data + mi)
                    append_lens(ref_of(result), uri, mfn.name, mfn.line, mfn.column, ref_of(first))
                    mi += 1
            ast.Decl.decl_extending_block as ext:
                var mi: ptr_uint = 0
                while mi < ext.methods.len:
                    var mfn: ast.Method
                    unsafe:
                        mfn = read(ext.methods.data + mi)
                    append_lens(ref_of(result), uri, mfn.name, mfn.line, mfn.column, ref_of(first))
                    mi += 1
            _:
                pass
        di += 1

    result.append("]")
    proto.write_response_raw(id, result.as_str())


## Handle codeLens/resolve.  Counts references to the function across the
## workspace index and returns the lens with its command attached.
public function handle_code_lens_resolve(
    ws: ref[workspace.Workspace],
    params: json.Value,
    id: json.Value,
) -> void:
    let name = extract_nested_string(params, "data", "name")
    if name.len == 0:
        proto.write_response(id, params)
        return

    ws.build_index_if_needed()
    var count = count_references(name, ws)
    log.info(f"code_lens resolve: name=#{name} count=#{count}")
    if count == 0:
        proto.write_response(id, params)
        return

    let obj_ptr = params.as_object()
    if obj_ptr == null:
        proto.write_response(id, params)
        return

    var command = json.create_object_value()
    let command_ptr = command.as_object()
    if command_ptr == null:
        proto.write_response(id, params)
        return

    var title = string.String.create()
    defer: title.release()
    if count == 1:
        title.append("1 reference")
    else:
        title.append_format(f"#{count} references")
    unsafe:
        read(command_ptr).set("title", json.string_value(title))
        read(command_ptr).set("command", json.string_from_str(""))
        read(obj_ptr).set("command", command)

    proto.write_response(id, params)


## The 1-based column of `name` on `line` of `source`, or 0 when absent.
## Extern and foreign declarations do not carry a name column in the AST,
## so it is recovered from the token on the line, as the host does.
function token_column(source: str, line: ptr_uint, name: str) -> ptr_uint:
    match cursor.token_start_in_line(utils.source_line(source, line), name):
        Option.some as col:
            return col.value + 1
        Option.none:
            return 0


## Count references to a named symbol across the workspace index.
## Searches all indexed .mt files for occurrences of the name.
function count_references(name: str, ws: ref[workspace.Workspace]) -> ptr_uint:
    var total: ptr_uint = 0
    var max_results = ws.index.entries.len()
    var results = idx.query_index(ref_of(ws.index), "", max_results)
    defer: results.release()

    var seen = map_mod.Map[str, bool].create()
    defer: seen.release()

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
            if not seen.contains(path):
                seen.set(path, true)
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


## Extract `value[outer][inner]` when both levels are objects and the leaf is
## a string; "" otherwise.
function extract_nested_string(value: json.Value, outer: str, inner: str) -> str:
    let obj_ptr = value.as_object()
    if obj_ptr == null:
        return ""
    let outer_ptr = unsafe: read(obj_ptr).get_object(outer)
    if outer_ptr == null:
        return ""
    let inner_value = unsafe: read(outer_ptr).get_string(inner)
    match inner_value:
        Option.some as s:
            return s.value
        Option.none:
            return ""


## Append a single CodeLens entry for a named symbol.
function append_lens(
    output: ref[string.String],
    uri: str,
    name: str,
    line: ptr_uint,
    column: ptr_uint,
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
    output.append(",\"character\":0}},\"data\":{\"uri\":\"")
    proto.append_escaped(output, uri)
    output.append("\",\"name\":\"")
    proto.append_escaped(output, name)
    output.append("\",\"line\":")
    output.append_format(f"#{line}")
    output.append(",\"column\":")
    output.append_format(f"#{column}")
    output.append("}}")

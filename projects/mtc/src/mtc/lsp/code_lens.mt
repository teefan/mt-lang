## Code lens handler.  Emits CodeLens entries for each function declaration
## in the document and resolves them to show reference counts via the
## workspace symbol index.

import std.fmt
import std.json as json
import std.log as log
import std.str
import std.string as string
import std.vec as vec

import mtc.parser.ast as ast
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.lsp.cursor as cursor
import mtc.lsp.references as refs
import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops
import mtc.lsp.utils as utils
import mtc.lsp.workspace as workspace


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
    let parsed = workspace.parsed_analysis_for(ws, file_path.as_str(), source) else:
        proto.write_error(id, -32800, "code lens request failed: parse error")
        return
    var ast_file = parsed.ast_file

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

    let data_uri = extract_nested_string(params, "data", "uri")
    let data_line = extract_nested_number(params, "data", "line")
    var file_path = string.String.create()
    defer: file_path.release()
    if data_uri.len > 0:
        match uri_ops.file_uri_to_path(data_uri):
            Option.some as resolved_path:
                var path_value = resolved_path.value
                file_path.append(path_value.as_str())
                path_value.release()
            Option.none:
                pass

    ws.build_index_if_needed()
    let count = refs.count_declaration_references(ws, name, file_path.as_str(), data_line)
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
        read(command_ptr).set("title", json.string_from_str(title.as_str()))
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


## Extract `value[outer][inner]` as a non-negative integer (0 when absent).
function extract_nested_number(value: json.Value, outer: str, inner: str) -> ptr_uint:
    let obj_ptr = value.as_object()
    if obj_ptr == null:
        return 0
    let outer_ptr = unsafe: read(obj_ptr).get_object(outer)
    if outer_ptr == null:
        return 0
    let inner_value = unsafe: read(outer_ptr).get_number(inner)
    match inner_value:
        Option.some as n:
            if n.value < 0.0:
                return 0
            return ptr_uint<-int<-n.value
        Option.none:
            return 0


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

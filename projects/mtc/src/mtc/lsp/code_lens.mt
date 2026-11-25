## Code lens handler.  Emits CodeLens entries for each function declaration in
## the document — the host's token-pair symbol list, which also reaches the
## nested declarations of a `when` branch and the `emit`-expanded functions —
## and resolves them to show reference counts via the workspace symbol index.

import std.json as json
import std.log as log
import std.str
import std.string as string

import mtc.lsp.definition_index as defidx
import mtc.lsp.references as refs
import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace

## LSP SymbolKind for codeLens data items.
const KIND_FUNCTION: int = 12
const KIND_METHOD: int = 6


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

    var result = string.String.create()
    defer: result.release()
    result.append("[")
    var first = true

    # The host lists the document's *token-pair* function symbols
    # (`get_symbols` filtered to `function`), which also reaches the nested
    # declarations of a `when` branch and the `emit`-expanded functions an AST
    # walk over the top level misses.
    let symbols = defidx.symbols_for(ref_of(ws.definition_index), file_path.as_str(), source)
    var si: ptr_uint = 0
    while si < symbols.len:
        let symbol = unsafe: read(symbols.data + si)
        if symbol.kind == KIND_FUNCTION:
            append_lens(
                ref_of(result), uri, symbol.name.as_str(), symbol.line, symbol.column, ref_of(first))
        si += 1

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

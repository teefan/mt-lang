## Type hierarchy handler.  Supports prepareTypeHierarchy, supertypes, and
## subtypes requests.  Uses the semantic analysis `implemented_interfaces`
## map and the workspace symbol index for cross-file subtype scanning.

import std.fmt
import std.fs as fs_mod
import std.json as json
import std.str
import std.string as string
import std.vec as vec

import mtc.parser.ast as ast
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types
import mtc.lsp.cursor as cursor
import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace
import mtc.lsp.workspace_index as idx


## LSP SymbolKind values for type hierarchy items.
## Per LSP 3.17 spec: File=1, Module=2, Namespace=3, Package=4, Class=5,
## Method=6, Property=7, Field=8, Constructor=9, Enum=10, Interface=11,
## Function=12, Variable=13, Constant=14, String=15, Number=16, Boolean=17,
## Array=18, Object=19, Key=20, Null=21, EnumMember=22, Struct=23, Event=24,
## Operator=25, TypeParameter=26.
const KIND_STRUCT:    int = 23
const KIND_ENUM:      int = 13
const KIND_INTERFACE: int = 11
const KIND_CLASS:     int = 5


## Handle textDocument/prepareTypeHierarchy.  Finds a type symbol at the
## cursor position and returns a TypeHierarchyItem.
public function handle_prepare_type_hierarchy(
    ws: ref[workspace.Workspace],
    uri: str,
    line: ptr_uint,
    character: ptr_uint,
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
    var analysis = analyzer.check_source_file(ast_file)

    let token_opt = cursor.identifier_at(source, line, character)
    match token_opt:
        Option.none:
            proto.write_response(id, json.null_value())
            return
        Option.some as token_payload:
            let name = token_payload.value.text
            var kind: int = KIND_CLASS
            var found = false

            if analysis.structs.contains(name):
                found = true
                kind = KIND_STRUCT
            else if analysis.static_member_types.contains(name):
                found = true
                kind = KIND_ENUM
            else if analysis.interfaces.contains(name):
                found = true
                kind = KIND_INTERFACE

            if not found:
                proto.write_response(id, json.null_value())
                return

            var result = string.String.create()
            defer result.release()
            result.append("[")
            append_hierarchy_item(ref_of(result), name, kind, uri, token_payload.value.line, token_payload.value.column, token_payload.value.length)
            result.append("]")
            proto.write_response_raw(id, result.as_str())


## Handle typeHierarchy/supertypes.  For a given type, returns its direct
## interface implementations as supertype entries.
public function handle_supertypes(
    ws: ref[workspace.Workspace],
    params: json.Value,
    id: json.Value,
) -> void:
    let item_uri = extract_item_field(params, "uri")
    let name = extract_item_field(params, "name")
    if name.len == 0 or item_uri.len == 0:
        proto.write_response(id, json.null_value())
        return

    var file_path = uri_ops.file_uri_to_path(item_uri) else:
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
    var analysis = analyzer.check_source_file(ast_file)

    var result = string.String.create()
    defer result.release()
    result.append("[")
    var first = true

    let ifaces_ptr = analysis.implemented_interfaces.get(name)
    if ifaces_ptr != null:
        var si: ptr_uint = 0
        unsafe:
            while si < read(ifaces_ptr).len:
                let qn = read(read(ifaces_ptr).data + si)
                let iface_name = if qn.parts.len > 0: read(qn.parts.data + qn.parts.len - 1) else: ""
                if iface_name.len > 0:
                    if not first:
                        result.append(",")
                    first = false
                    append_hierarchy_item(ref_of(result), iface_name, KIND_INTERFACE, item_uri, 1, 0, iface_name.len)
                si += 1

    result.append("]")
    proto.write_response_raw(id, result.as_str())


## Handle typeHierarchy/subtypes.  Scans all workspace-indexed files for
## types that implement the target interface.
public function handle_subtypes(
    ws: ref[workspace.Workspace],
    params: json.Value,
    id: json.Value,
) -> void:
    let name = extract_item_field(params, "name")
    if name.len == 0:
        proto.write_response(id, json.null_value())
        return

    ws.build_index_if_needed()

    var result = string.String.create()
    defer result.release()
    result.append("[")
    var first = true
    var max_entries: ptr_uint = 500

    # Scan all indexed entries looking for types with matching implemented_interfaces.
    var ri: ptr_uint = 0
    while ri < ws.index.entries.len() and ri < max_entries:
        let ep = ws.index.entries.get(ri) else:
            break
        let entry = unsafe: read(ep)
        if entry.kind == KIND_STRUCT or entry.kind == KIND_ENUM or entry.kind == KIND_CLASS:
            let path = entry.path.as_str()
            let entry_name = entry.name.as_str()
            if entry_name.equal(name):
                ri += 1
                continue

            match fs_mod.read_text(path):
                Result.success as payload:
                    var content = payload.value
                    var parse_diags2 = vec.Vec[pstate.ParseDiagnostic].create()
                    defer parse_diags2.release()
                    var ast_file2 = parser.parse_source(content.as_str(), ref_of(parse_diags2))
                    var analysis2 = analyzer.check_source_file(ast_file2)

                    let ifaces_ptr = analysis2.implemented_interfaces.get(entry_name)
                    if ifaces_ptr != null:
                        var needs_check = false
                        var si: ptr_uint = 0
                        unsafe:
                            while si < read(ifaces_ptr).len:
                                let qn = read(read(ifaces_ptr).data + si)
                                let iface_name = if qn.parts.len > 0: read(qn.parts.data + qn.parts.len - 1) else: ""
                                if iface_name.equal(name):
                                    needs_check = true
                                    break
                                si += 1
                        if needs_check:
                            if not first:
                                result.append(",")
                            first = false
                            var target_uri = build_file_uri(path)
                            append_hierarchy_item(ref_of(result), entry_name, entry.kind, target_uri.as_str(), entry.line, 0, entry_name.len)
                            target_uri.release()
                    content.release()
                Result.failure:
                    pass
        ri += 1

    result.append("]")
    proto.write_response_raw(id, result.as_str())


## Extract a named field from a type hierarchy item JSON.
function extract_item_field(value: json.Value, field: str) -> str:
    let obj_ptr = value.as_object()
    if obj_ptr == null:
        # It might be an array — take the first element.
        let arr_ptr = value.as_array()
        if arr_ptr == null:
            return ""
        unsafe:
            let first_ptr = read(arr_ptr).get(0)
            if first_ptr == null:
                return ""
            let first_obj = read(first_ptr).as_object()
            if first_obj == null:
                return ""
            let f_ptr = read(first_obj).get(field)
            if f_ptr == null:
                return ""
            let f_str = read(f_ptr).as_string() else:
                return ""
            return f_str
    unsafe:
        let f_ptr = read(obj_ptr).get(field)
        if f_ptr == null:
            return ""
        let f_str = read(f_ptr).as_string() else:
            return ""
        return f_str


## Build a file:// URI from an absolute path.  Returns an owned string.String.
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


## Append a TypeHierarchyItem object to the JSON output.
function append_hierarchy_item(
    output: ref[string.String],
    name: str,
    kind: int,
    uri: str,
    line: ptr_uint,
    column: ptr_uint,
    length: ptr_uint,
) -> void:
    let lz = if line > 0: line - 1 else: 0z
    let colz = if column > 0: column - 1 else: 0z
    output.append("{\"name\":\"")
    proto.append_escaped(output, name)
    output.append("\",\"kind\":")
    output.append_format(f"#{kind}")
    output.append(",\"uri\":\"")
    proto.append_escaped(output, uri)
    output.append("\",\"range\":{\"start\":{\"line\":")
    output.append_format(f"#{lz}")
    output.append(",\"character\":")
    output.append_format(f"#{colz}")
    output.append("},\"end\":{\"line\":")
    output.append_format(f"#{lz}")
    output.append(",\"character\":")
    output.append_format(f"#{colz + length}")
    output.append("}},\"selectionRange\":{\"start\":{\"line\":")
    output.append_format(f"#{lz}")
    output.append(",\"character\":")
    output.append_format(f"#{colz}")
    output.append("},\"end\":{\"line\":")
    output.append_format(f"#{lz}")
    output.append(",\"character\":")
    output.append_format(f"#{colz + length}")
    output.append("}}}")

## Workspace symbols — search top-level declarations across every .mt file
## under the workspace roots.  Files are text-prefiltered by the query before
## parsing, so only candidate files pay the parse cost.  An empty query
## returns no results (the Ruby LSP returns all symbols via its workspace
## index; the self-host has no index yet).

import std.fmt
import std.fs as fs_mod
import std.json as json
import std.path as path_ops
import std.str
import std.string as string
import std.vec as vec

import mtc.parser.ast as ast
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.lsp.cursor as cursor
import mtc.lsp.protocol as proto
import mtc.lsp.workspace as workspace


## Result cap so a broad query cannot produce an unbounded response.
const MAX_RESULTS: ptr_uint = 200

## LSP SymbolKind values (same set as symbols.mt).
const KIND_FUNCTION:  int = 12
const KIND_STRUCT:    int = 23
const KIND_ENUM:      int = 10
const KIND_VARIABLE:  int = 13
const KIND_CONSTANT:  int = 14
const KIND_INTERFACE: int = 11
const KIND_CLASS:     int = 5


## Handle workspace/symbol.
public function handle_workspace_symbol(ws: ref[workspace.Workspace], query: str, id: json.Value) -> void:
    if query.len == 0:
        proto.write_response_raw(id, "[]")
        return

    var files = vec.Vec[string.String].create()
    defer release_strings(ref_of(files))

    var ri: ptr_uint = 0
    while ri < ws.module_roots.len():
        let root_ptr = ws.module_roots.get(ri) else:
            break
        unsafe:
            collect_mt_files(read(root_ptr).as_str(), ref_of(files))
        ri += 1

    var json_text = string.String.create()
    defer json_text.release()
    json_text.append("[")
    var emitted: ptr_uint = 0

    var fi: ptr_uint = 0
    while fi < files.len() and emitted < MAX_RESULTS:
        let fp = files.get(fi) else:
            break
        unsafe:
            append_file_symbols(ws, read(fp).as_str(), query, ref_of(json_text), ref_of(emitted))
        fi += 1

    json_text.append("]")
    proto.write_response_raw(id, json_text.as_str())


## Append matching top-level symbols from one file as SymbolInformation.
function append_file_symbols(
    ws: ref[workspace.Workspace],
    path: str,
    query: str,
    json_text: ref[string.String],
    emitted: ref[ptr_uint],
) -> void:
    var content = ws.document_source(path) else:
        return
    defer content.release()

    let source = content.as_str()
    # Cheap prefilter: the query must appear in the file text at all.
    if not contains_case_insensitive(source, query):
        return

    # URIs need absolute paths; canonicalize once per candidate file.
    var absolute_path = string.String.from_str(path)
    match fs_mod.canonicalize(path):
        Result.success as canonical:
            absolute_path.release()
            absolute_path = canonical.value
        Result.failure as failure_payload:
            var err = failure_payload.error
            err.release()
    defer absolute_path.release()

    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))

    var di: ptr_uint = 0
    while di < ast_file.declarations.len:
        if unsafe: read(emitted) >= MAX_RESULTS:
            return
        var decl: ast.Decl
        unsafe:
            decl = read(ast_file.declarations.data + di)
        let sym_path = absolute_path.as_str()
        match decl:
            ast.Decl.decl_function as f:
                emit_symbol(json_text, emitted, f.name, KIND_FUNCTION, sym_path, f.line, source, query)
            ast.Decl.decl_struct as s:
                emit_symbol(json_text, emitted, s.name, KIND_STRUCT, sym_path, s.line, source, query)
            ast.Decl.decl_union as u:
                emit_symbol(json_text, emitted, u.name, KIND_STRUCT, sym_path, u.line, source, query)
            ast.Decl.decl_enum as e:
                emit_symbol(json_text, emitted, e.name, KIND_ENUM, sym_path, e.line, source, query)
            ast.Decl.decl_flags as fl:
                emit_symbol(json_text, emitted, fl.name, KIND_ENUM, sym_path, fl.line, source, query)
            ast.Decl.decl_variant as vr:
                emit_symbol(json_text, emitted, vr.name, KIND_ENUM, sym_path, vr.line, source, query)
            ast.Decl.decl_interface as iface:
                emit_symbol(json_text, emitted, iface.name, KIND_INTERFACE, sym_path, iface.line, source, query)
            ast.Decl.decl_type_alias as ta:
                emit_symbol(json_text, emitted, ta.name, KIND_CLASS, sym_path, ta.line, source, query)
            ast.Decl.decl_opaque as op:
                emit_symbol(json_text, emitted, op.name, KIND_CLASS, sym_path, op.line, source, query)
            ast.Decl.decl_const as c:
                emit_symbol(json_text, emitted, c.name, KIND_CONSTANT, sym_path, c.line, source, query)
            ast.Decl.decl_var as v:
                emit_symbol(json_text, emitted, v.name, KIND_VARIABLE, sym_path, v.line, source, query)
            _:
                pass
        di += 1


function emit_symbol(
    json_text: ref[string.String],
    emitted: ref[ptr_uint],
    name: str,
    kind: int,
    path: str,
    line: ptr_uint,
    source: str,
    query: str,
) -> void:
    if not contains_case_insensitive(name, query):
        return
    if unsafe: read(emitted) >= MAX_RESULTS:
        return

    let lz = if line > 0: line - 1 else: 0z
    var start_char: ptr_uint = 0
    match cursor.token_start_in_line(cursor.source_line(source, line), name):
        Option.some as pos:
            start_char = pos.value
        Option.none:
            pass

    if unsafe: read(emitted) > 0:
        json_text.append(",")
    unsafe:
        read(emitted) = read(emitted) + 1

    json_text.append("{\"name\":\"")
    proto.append_escaped(json_text, name)
    json_text.append("\",\"kind\":")
    json_text.append_format(f"#{kind}")
    json_text.append(",\"location\":{\"uri\":\"file://")
    proto.append_escaped(json_text, path)
    json_text.append("\",\"range\":{\"start\":{\"line\":")
    json_text.append_format(f"#{lz}")
    json_text.append(",\"character\":")
    json_text.append_format(f"#{start_char}")
    json_text.append("},\"end\":{\"line\":")
    json_text.append_format(f"#{lz}")
    json_text.append(",\"character\":")
    json_text.append_format(f"#{start_char + name.len}")
    json_text.append("}}}}")


## Recursively collect .mt files, skipping build artifacts and vendored
## trees.
function collect_mt_files(dir: str, output: ref[vec.Vec[string.String]]) -> void:
    match fs_mod.list_entries(dir):
        Result.failure as failure_payload:
            var err = failure_payload.error
            err.release()
            return
        Result.success as payload:
            var entries = payload.value
            defer entries.release()

            var i: ptr_uint = 0
            while i < entries.len():
                match entries.get(i):
                    Option.none:
                        break
                    Option.some as entry_payload:
                        let name = entry_payload.value
                        if not skip_entry(name):
                            var child = path_ops.join(dir, name)
                            if fs_mod.is_directory(child.as_str()):
                                collect_mt_files(child.as_str(), output)
                                child.release()
                            else if name.ends_with(".mt"):
                                output.push(child)
                            else:
                                child.release()
                i += 1


function skip_entry(name: str) -> bool:
    return name.starts_with(".") or name.equal("build") or name.equal("tmp") or
        name.equal("third_party") or name.equal("node_modules") or name.equal("coverage") or
        name.equal("target")


function contains_case_insensitive(text: str, needle: str) -> bool:
    if needle.len == 0:
        return true
    if needle.len > text.len:
        return false
    let limit = text.len - needle.len
    var n: ptr_uint = 0
    while n <= limit:
        var matched = true
        var mi: ptr_uint = 0
        while mi < needle.len:
            if ascii_fold(text.byte_at(n + mi)) != ascii_fold(needle.byte_at(mi)):
                matched = false
                break
            mi += 1
        if matched:
            return true
        n += 1
    return false


function ascii_fold(value: ubyte) -> ubyte:
    if value >= 'A' and value <= 'Z':
        return value + ('a' - 'A')
    return value


function release_strings(values: ref[vec.Vec[string.String]]) -> void:
    var i: ptr_uint = 0
    while i < values.len():
        let vp = values.get(i) else:
            break
        unsafe:
            read(vp).release()
        i += 1
    values.release()

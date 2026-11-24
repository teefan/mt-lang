## Pull diagnostics handler.  Provides textDocument/diagnostic and
## workspace/diagnostic with fingerprint-based caching.  A source content
## hash acts as the fingerprint; when the client passes a matching
## previousResultId, the server returns `kind: "unchanged"` without
## recomputing diagnostics.

import std.fmt
import std.json as json
import std.str
import std.string as string
import std.vec as vec

import mtc.strings as strings
import mtc.lsp.diagnostics as diag
import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace



## The workspace report is bounded: indexed files in workspace order, plus any
## open document the index has not seen yet.  A larger workspace gets the first
## 500 files (the client can still pull individual documents).
const MAX_WORKSPACE_DIAGNOSTIC_FILES: ptr_uint = 500


## Handle textDocument/diagnostic.  Computes diagnostics for a single
## file and returns a pull-diagnostic report with result caching.
public function handle_document_diagnostic(
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
        proto.write_response_raw(id, "{\"kind\":\"full\",\"items\":[]}")
        return
    defer: content.release()

    let source = content.as_str()
    let current_hash = strings.fnv1a_hash(source)
    let previous_id = extract_previous_result_id(params)

    # Check cache hit.
    let cached_ptr = ws.diagnostic_cache_get(file_path.as_str())
    if cached_ptr != null:
        let cached = unsafe: read(cached_ptr)
        if cached.source_hash == current_hash:
            let cached_id = cached.result_id.as_str()
            if previous_id.equal(cached_id):
                var result_json = string.String.create()
                defer: result_json.release()
                result_json.append("{\"kind\":\"unchanged\",\"resultId\":\"")
                proto.append_escaped(ref_of(result_json), cached_id)
                result_json.append("\"}")
                proto.write_response_raw(id, result_json.as_str())
                return

    # Compute new diagnostics.
    var roots = ws.effective_module_roots_for(file_path.as_str())
    defer: roots.release()
    var diagnostics = diag.collect_diagnostics(ws, uri, file_path.as_str(), source)

    var diag_json = string.String.create()
    defer: diag_json.release()
    append_json_value_into(ref_of(diag_json), diagnostics)
    json.release_value(diagnostics)

    # Build a new result_id from the hash.
    var result_id = string.String.create()
    result_id.append_format(f"#{current_hash:x}")

    # Cache it.
    var cached_diag = string.String.from_str(diag_json.as_str())
    var cached_id = string.String.from_str(result_id.as_str())
    ws.diagnostic_cache_set(file_path.as_str(), current_hash, cached_id, cached_diag)

    var result_json = string.String.create()
    defer: result_json.release()
    result_json.append("{\"kind\":\"full\",\"resultId\":\"")
    proto.append_escaped(ref_of(result_json), result_id.as_str())
    result_json.append("\",\"items\":")
    result_json.append(diag_json.as_str())
    result_json.append("}")

    result_id.release()
    proto.write_response_raw(id, result_json.as_str())


## Handle workspace/diagnostic.  Reports the indexed workspace, not just open
## documents, reusing the same per-document cache as the single-document pull:
## a document whose fingerprint and `previousResultIds` entry still match is
## reported as `unchanged`.
public function handle_workspace_diagnostic(
    ws: ref[workspace.Workspace],
    params: json.Value,
    id: json.Value,
) -> void:
    ws.build_index_if_needed()
    var paths = workspace_diagnostic_paths(ws)
    defer: release_diagnostic_paths(ref_of(paths))

    let work_token = proto.extract_token(params, "workDoneToken")
    let partial_token = proto.extract_token(params, "partialResultToken")
    match work_token:
        Option.some as token:
            proto.write_progress_for(token.value, "begin", "Milk Tea", "Workspace diagnostics", -1)
        Option.none:
            pass

    match partial_token:
        Option.some as token:
            # Stream one document report per `$/progress` notification; the
            # final response carries no duplicate items.
            var pi: ptr_uint = 0
            while pi < paths.len():
                let path_ptr = paths.get(pi) else:
                    break
                pi += 1
                var item = string.String.create()
                var item_first = true
                append_workspace_document_report(ws, params, unsafe: read(path_ptr).as_str(), ref_of(item), ref_of(item_first))
                if item.len() > 0:
                    var chunk = string.String.create()
                    chunk.append("{\"items\":[")
                    chunk.append(item.as_str())
                    chunk.append("]}")
                    proto.write_partial_result(token.value, chunk.as_str())
                    chunk.release()
                item.release()
            proto.write_response_raw(id, "{\"items\":[]}")
        Option.none:
            var result_json = string.String.create()
            defer: result_json.release()
            result_json.append("{\"items\":[")
            var first = true
            var pi: ptr_uint = 0
            while pi < paths.len():
                let path_ptr = paths.get(pi) else:
                    break
                pi += 1
                append_workspace_document_report(ws, params, unsafe: read(path_ptr).as_str(), ref_of(result_json), ref_of(first))
            result_json.append("]}")
            proto.write_response_raw(id, result_json.as_str())

    match work_token:
        Option.some as token:
            proto.write_progress_for(token.value, "end", "", "", -1)
        Option.none:
            pass


## The indexed `.mt` files plus any open document the index has not seen.
function workspace_diagnostic_paths(ws: ref[workspace.Workspace]) -> vec.Vec[string.String]:
    var paths = vec.Vec[string.String].create()
    var i: ptr_uint = 0
    while i < ws.index.files.len() and paths.len() < MAX_WORKSPACE_DIAGNOSTIC_FILES:
        let file_ptr = ws.index.files.get(i) else:
            break
        i += 1
        let path = unsafe: read(file_ptr).path.as_str()
        if not diagnostic_path_present(ref_of(paths), path):
            paths.push(string.String.from_str(path))

    let open_paths = ws.open_paths_in_order()
    var oi: ptr_uint = 0
    while oi < open_paths.len and paths.len() < MAX_WORKSPACE_DIAGNOSTIC_FILES:
        let path = unsafe: read(open_paths.data + oi).as_str()
        oi += 1
        if not diagnostic_path_present(ref_of(paths), path):
            paths.push(string.String.from_str(path))
    return paths


function diagnostic_path_present(paths: ref[vec.Vec[string.String]], path: str) -> bool:
    var i: ptr_uint = 0
    while i < paths.len():
        let entry = paths.get(i) else:
            break
        if unsafe: read(entry).as_str().equal(path):
            return true
        i += 1
    return false


function release_diagnostic_paths(paths: ref[vec.Vec[string.String]]) -> void:
    var i: ptr_uint = 0
    while i < paths.len():
        let entry = paths.get(i) else:
            break
        unsafe: read(entry).release()
        i += 1
    paths.release()


## One workspace report item: full diagnostics or an `unchanged` cache hit.
function append_workspace_document_report(
    ws: ref[workspace.Workspace],
    params: json.Value,
    path: str,
    result_json: ref[string.String],
    first: ref[bool],
) -> void:
    var content = ws.document_source(path) else:
        return
    defer: content.release()
    let source = content.as_str()
    if source.len == 0:
        return

    let current_hash = strings.fnv1a_hash(source)
    let previous_id = previous_result_id_for(params, path)
    var hit = false
    var cached_id = string.String.create()
    defer: cached_id.release()
    let cached_ptr = ws.diagnostic_cache_get(path)
    if cached_ptr != null:
        let cached = unsafe: read(cached_ptr)
        if cached.source_hash == current_hash:
            cached_id.append(cached.result_id.as_str())
            if previous_id.equal(cached_id.as_str()):
                hit = true

    if not unsafe: read(first):
        result_json.append(",")
    unsafe: read(first) = false

    var doc_uri = string.String.from_str("file://")
    defer: doc_uri.release()
    doc_uri.append(path)
    result_json.append("{\"uri\":\"")
    proto.append_escaped(result_json, doc_uri.as_str())

    if hit:
        result_json.append("\",\"kind\":\"unchanged\",\"resultId\":\"")
        proto.append_escaped(result_json, cached_id.as_str())
        result_json.append("\",\"items\":[],\"version\":")
        append_version_or_null(ws, path, result_json)
        result_json.append("}")
        return

    var diagnostics = diag.collect_diagnostics(ws, doc_uri.as_str(), path, source)
    var diag_json = string.String.create()
    defer: diag_json.release()
    append_json_value_into(ref_of(diag_json), diagnostics)
    json.release_value(diagnostics)

    var result_id = string.String.create()
    defer: result_id.release()
    result_id.append_format(f"#{current_hash:x}")
    var cached_diag = string.String.from_str(diag_json.as_str())
    var owned_id = string.String.from_str(result_id.as_str())
    ws.diagnostic_cache_set(path, current_hash, owned_id, cached_diag)

    result_json.append("\",\"kind\":\"full\",\"resultId\":\"")
    proto.append_escaped(result_json, result_id.as_str())
    result_json.append("\",\"items\":")
    result_json.append(diag_json.as_str())
    result_json.append(",\"version\":")
    append_version_or_null(ws, path, result_json)
    result_json.append("}")


## Append a document's client version, or JSON null when it is not open.
function append_version_or_null(ws: ref[workspace.Workspace], path: str, output: ref[string.String]) -> void:
    match ws.document_version(path):
        Option.some as version:
            output.append_format(f"#{version.value}")
        Option.none:
            output.append("null")


## The `previousResultIds` value recorded for `path`, or "" when absent.  The
## client sends an array of `{uri, value}` entries.
function previous_result_id_for(params: json.Value, path: str) -> str:
    let obj_ptr = params.as_object() else:
        return ""
    unsafe:
        let prev_ptr = read(obj_ptr).get("previousResultIds")
        if prev_ptr == null:
            return ""
        let arr_ptr = read(prev_ptr).as_array() else:
            return ""
        var i: ptr_uint = 0
        while i < read(arr_ptr).len():
            let entry_ptr = read(arr_ptr).get(i) else:
                break
            let entry_obj = read(entry_ptr).as_object() else:
                i += 1
                continue
            let uri_ptr = read(entry_obj).get("uri")
            if uri_ptr != null:
                let uri_str = read(uri_ptr).as_string() else:
                    i += 1
                    continue
                if uri_matches_path(uri_str, path):
                    let value_ptr = read(entry_obj).get("value")
                    if value_ptr != null:
                        let value_str = read(value_ptr).as_string() else:
                            return ""
                        return value_str
            i += 1
    return ""


## True when a client URI refers to the given file path (the workspace keys
## documents by path).
function uri_matches_path(uri: str, path: str) -> bool:
    return uri.equal(path) or uri.ends_with(path)


## Compute an FNV-1a hash of a source string.  Used as the diagnostic
## fingerprint so identical source text always produces the same resultId.
## Extract the previousResultId field from pull diagnostic params.
function extract_previous_result_id(params: json.Value) -> str:
    let obj_ptr = params.as_object()
    if obj_ptr == null:
        return ""
    unsafe:
        let prev_ptr = read(obj_ptr).get("previousResultId")
        if prev_ptr == null:
            return ""
        let prev_str = read(prev_ptr).as_string() else:
            return ""
        return prev_str


## Serialize a json.Value into a string.String output buffer.  This is
## a dedicated copy of the serialization code so we don't have to go
## through json.render (which allocates a temporary String).
function append_json_value_into(output: ref[string.String], value: json.Value) -> void:
    if value.is_null():
        output.append("null")
        return
    match value.as_boolean():
        Option.some as b:
            if b.value:
                output.append("true")
            else:
                output.append("false")
            return
        Option.none:
            pass
    match value.as_number():
        Option.some as n:
            output.append_format(f"#{n.value}")
            return
        Option.none:
            pass
    match value.as_string():
        Option.some as s:
            output.append("\"")
            proto.append_escaped(output, s.value)
            output.append("\"")
            return
        Option.none:
            pass
    var obj_ptr = value.as_object()
    if obj_ptr != null:
        output.append("{")
        var first_entry = true
        var ei: ptr_uint = 0
        unsafe:
            while ei < read(obj_ptr).len():
                let entry_ptr = read(obj_ptr).entries.get(ei)
                if entry_ptr == null: break
                if not first_entry: output.append(",")
                first_entry = false
                let entry = read(entry_ptr)
                output.append("\"")
                proto.append_escaped(output, entry.key.as_str())
                output.append("\":")
                append_json_value_into(output, entry.value)
                ei += 1
        output.append("}")
        return
    var arr_ptr = value.as_array()
    if arr_ptr != null:
        output.append("[")
        var first_arr = true
        var ai: ptr_uint = 0
        unsafe:
            while ai < read(arr_ptr).len():
                let elem_ptr = read(arr_ptr).get(ai)
                if elem_ptr == null: break
                if not first_arr: output.append(",")
                first_arr = false
                append_json_value_into(output, read(elem_ptr))
                ai += 1
        output.append("]")
        return
    output.append("null")

## Pull diagnostics handler.  Provides textDocument/diagnostic and
## workspace/diagnostic with fingerprint-based caching.  A source content
## hash acts as the fingerprint; when the client passes a matching
## previousResultId, the server returns `kind: "unchanged"` without
## recomputing diagnostics.

import std.fmt
import std.json as json
import std.str
import std.string as string

import mtc.lsp.diagnostics as diag
import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace


const FNV_OFFSET: uint = 0x811C9DC5
const FNV_PRIME:  uint = 0x01000193


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
    defer file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        proto.write_response_raw(id, "{\"kind\":\"full\",\"items\":[]}")
        return
    defer content.release()

    let source = content.as_str()
    let current_hash = fnv1a_hash(source)
    let previous_id = extract_previous_result_id(params)

    # Check cache hit.
    let cached_ptr = ws.diagnostic_cache_get(file_path.as_str())
    if cached_ptr != null:
        let cached = unsafe: read(cached_ptr)
        if cached.source_hash == current_hash:
            let cached_id = cached.result_id.as_str()
            if previous_id.equal(cached_id):
                var result_json = string.String.create()
                defer result_json.release()
                result_json.append("{\"kind\":\"unchanged\",\"resultId\":\"")
                proto.append_escaped(ref_of(result_json), cached_id)
                result_json.append("\"}")
                proto.write_response_raw(id, result_json.as_str())
                return

    # Compute new diagnostics.
    var roots = ws.effective_module_roots_for(file_path.as_str())
    defer roots.release()
    var diagnostics = diag.collect_diagnostics(file_path.as_str(), roots.as_span())

    var diag_json = string.String.create()
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
    defer result_json.release()
    result_json.append("{\"kind\":\"full\",\"resultId\":\"")
    proto.append_escaped(ref_of(result_json), result_id.as_str())
    result_json.append("\",\"items\":")
    result_json.append(diag_json.as_str())
    result_json.append("}")

    result_id.release()
    proto.write_response_raw(id, result_json.as_str())


## Handle workspace/diagnostic.  Computes diagnostics for all open
## documents and returns a workspace diagnostic report.
public function handle_workspace_diagnostic(
    ws: ref[workspace.Workspace],
    params: json.Value,
    id: json.Value,
) -> void:
    var result_json = string.String.create()
    defer result_json.release()
    result_json.append("{\"items\":[")

    var doc_iter = ws.open_docs.keys()
    var first = true

    while true:
        let kp = doc_iter.next() else:
            break
        let path = unsafe: read(kp).as_str()
        let source_ptr = ws.open_docs.get(unsafe: read(kp))
        if source_ptr == null:
            continue

        let source = unsafe: read(source_ptr).as_str()
        let current_hash = fnv1a_hash(source)

        # Check cache.
        var hit = false
        let cached_ptr = ws.diagnostic_cache_get(path)
        if cached_ptr != null:
            let cached = unsafe: read(cached_ptr)
            if cached.source_hash == current_hash:
                hit = true

        if not hit:
            # Compute and cache.
            var roots = ws.effective_module_roots_for(path)
            defer roots.release()
            var diagnostics = diag.collect_diagnostics(path, roots.as_span())

            var diag_json = string.String.create()
            append_json_value_into(ref_of(diag_json), diagnostics)
            json.release_value(diagnostics)

            var result_id = string.String.create()
            result_id.append_format(f"#{current_hash:x}")

            var cached_diag = string.String.from_str(diag_json.as_str())
            var cached_id = string.String.from_str(result_id.as_str())
            ws.diagnostic_cache_set(path, current_hash, cached_id, cached_diag)

            if not first:
                result_json.append(",")
            first = false
            result_json.append("{\"uri\":\"file://")
            proto.append_escaped(ref_of(result_json), path)
            result_json.append("\",\"kind\":\"full\",\"resultId\":\"")
            proto.append_escaped(ref_of(result_json), result_id.as_str())
            result_json.append("\",\"items\":")
            result_json.append(diag_json.as_str())
            result_json.append("}")
            result_id.release()

    result_json.append("]}")
    proto.write_response_raw(id, result_json.as_str())


## Compute an FNV-1a hash of a source string.  Used as the diagnostic
## fingerprint so identical source text always produces the same resultId.
function fnv1a_hash(text: str) -> uint:
    var h = FNV_OFFSET
    var i: ptr_uint = 0
    while i < text.len:
        let b = uint<-text.byte_at(i)
        h = (h ^ b) * FNV_PRIME
        i += 1
    return h


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

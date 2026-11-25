## Workspace symbols — the host's `handle_workspace_symbol`: every document the
## server knows (`all_documents` = the indexed documents plus the open ones),
## each contributing its *token-pair* declaration symbols (the same extraction
## code lenses use), filtered by a case-insensitive name substring.  There is no
## result cap and no workspace-root filter: the host reports whatever its
## document set holds.

import std.json as json
import std.str
import std.string as string
import std.vec as vec

import mtc.lsp.definition_index as defidx
import mtc.lsp.protocol as proto
import mtc.lsp.workspace as workspace


public function handle_workspace_symbol(
    ws: ref[workspace.Workspace],
    query: str,
    params: json.Value,
    id: json.Value
) -> void:
    let work_token = proto.extract_token(params, "workDoneToken")
    let partial_token = proto.extract_token(params, "partialResultToken")
    match work_token:
        Option.some as token:
            proto.write_progress_for(token.value, "begin", "Milk Tea", "Workspace symbols", -1)
        Option.none:
            pass

    ws.build_index_if_needed()

    var json_text = string.String.create()
    defer: json_text.release()
    json_text.append("[")
    var first = true

    var emitted = vec.Vec[string.String].create()
    defer: release_paths(ref_of(emitted))

    # The walked workspace documents first, in the host's glob order (its
    # `@indexed_documents` — the index walk itself is filesystem order), then
    # the on-demand ones (the definition index's warm order), then the open
    # documents: the host's `@indexed_documents.keys + @open_documents.keys`,
    # deduplicated.
    append_indexed_paths(ws, query, json_text, first, emitted)
    append_document_symbols(ws, defidx.warmed_paths(ref_of(ws.definition_index)), query, json_text, first, emitted)
    append_document_symbols(ws, ws.open_paths_in_order(), query, json_text, first, emitted)

    json_text.append("]")
    match partial_token:
        Option.some as token:
            proto.write_partial_result(token.value, json_text.as_str())
            proto.write_response_raw(id, "[]")
        Option.none:
            proto.write_response_raw(id, json_text.as_str())

    match work_token:
        Option.some as token:
            proto.write_progress_for(token.value, "end", "", "", -1)
        Option.none:
            pass


## Emit the symbols of every workspace-walked file, in the host's
## `Dir.glob(**/*.mt).sort` order.
function append_indexed_paths(
    ws: ref[workspace.Workspace],
    query: str,
    json_text: ref[string.String],
    first: ref[bool],
    emitted: ref[vec.Vec[string.String]],
) -> void:
    var paths = vec.Vec[string.String].create()
    defer: release_paths(ref_of(paths))

    var i: ptr_uint = 0
    while i < ws.index.entries.len():
        let ep = ws.index.entries.get(i) else:
            break
        let path = unsafe: read(ep).path.as_str()
        i += 1
        if path.len == 0 or contains_path(ref_of(paths), path):
            continue
        paths.push(string.String.from_str(path))

    paths.sort()

    var pi: ptr_uint = 0
    while pi < paths.len():
        let path_ptr = paths.get(pi) else:
            break
        pi += 1
        let path = unsafe: read(path_ptr).as_str()
        emit_document_symbols(ws, path, query, json_text, first, emitted)


## Emit the symbols of every path in `paths`, skipping documents already
## emitted and symbols whose name does not contain `query`.
function append_document_symbols(
    ws: ref[workspace.Workspace],
    paths: span[string.String],
    query: str,
    json_text: ref[string.String],
    first: ref[bool],
    emitted: ref[vec.Vec[string.String]],
) -> void:
    var pi: ptr_uint = 0
    while pi < paths.len:
        let path = unsafe: read(paths.data + pi).as_str()
        pi += 1
        emit_document_symbols(ws, path, query, json_text, first, emitted)


## One document's symbols: read its current text, extract the token-pair
## declarations, and emit the entries matching `query`.
function emit_document_symbols(
    ws: ref[workspace.Workspace],
    path: str,
    query: str,
    json_text: ref[string.String],
    first: ref[bool],
    emitted: ref[vec.Vec[string.String]],
) -> void:
    if path.len == 0 or already_emitted(emitted, path):
        return
    var content = ws.document_source(path) else:
        return
    defer: content.release()
    emitted.push(string.String.from_str(path))

    let symbols = defidx.symbols_for(ref_of(ws.definition_index), path, content.as_str())
    var si: ptr_uint = 0
    while si < symbols.len:
        let symbol = unsafe: read(symbols.data + si)
        si += 1
        if query.len > 0 and not contains_case_insensitive(symbol.name.as_str(), query):
            continue
        var uri = string.String.create()
        uri.append("file://")
        uri.append(path)
        emit_symbol_json(ws, json_text, first, uri.as_str(), path, symbol)
        uri.release()


## The host's `format_symbol`: a `{name, kind, location}` entry at the symbol's
## own token.
function emit_symbol_json(
    ws: ref[workspace.Workspace],
    json_text: ref[string.String],
    first: ref[bool],
    uri: str,
    path: str,
    symbol: defidx.SymbolEntry,
) -> void:
    if not unsafe: read(first):
        json_text.append(",")
    unsafe: read(first) = false

    let lz = if symbol.line > 0: symbol.line - 1 else: 0z
    let byte_col = if symbol.column > 0: symbol.column - 1 else: 0z
    let colz = ws.output_character(path, lz, byte_col)
    let end_colz = ws.output_character(path, lz, byte_col + symbol.name.len())
    json_text.append("{\"name\":\"")
    proto.append_escaped(json_text, symbol.name.as_str())
    json_text.append("\",\"kind\":")
    json_text.append_format(f"#{symbol.kind}")
    json_text.append(",\"location\":{\"uri\":\"")
    proto.append_escaped(json_text, uri)
    json_text.append("\",\"range\":{\"start\":{\"line\":")
    json_text.append_format(f"#{lz}")
    json_text.append(",\"character\":")
    json_text.append_format(f"#{colz}")
    json_text.append("},\"end\":{\"line\":")
    json_text.append_format(f"#{lz}")
    json_text.append(",\"character\":")
    json_text.append_format(f"#{end_colz}")
    json_text.append("}}}}")


function already_emitted(emitted: ref[vec.Vec[string.String]], path: str) -> bool:
    var i: ptr_uint = 0
    while i < emitted.len():
        let entry = emitted.get(i) else:
            break
        if unsafe: read(entry).as_str().equal(path):
            return true
        i += 1
    return false


## True when `paths` already holds `path`.
function contains_path(paths: ref[vec.Vec[string.String]], path: str) -> bool:
    var i: ptr_uint = 0
    while i < paths.len():
        let entry = paths.get(i) else:
            break
        if unsafe: read(entry).as_str().equal(path):
            return true
        i += 1
    return false


function release_paths(paths: ref[vec.Vec[string.String]]) -> void:
    var i: ptr_uint = 0
    while i < paths.len():
        let entry = paths.get(i) else:
            break
        unsafe: read(entry).release()
        i += 1
    paths.release()


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

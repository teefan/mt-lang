## Workspace notification handlers with cache invalidation.
##
## Design: the self-host LSP caches minimally (diagnostics, semantic tokens,
## workspace symbols) so broad invalidation costs little.  Scanning each open
## document's import statements for selective clearing would be ~60 lines of
## code to avoid recomputing diagnostics for a handful of unaffected files.
## The tradeoff is deliberately kept simple.

import std.fmt
import std.json as json
import std.str
import std.string as string
import std.vec as vec

import mtc.lsp.definition_index as defidx
import mtc.lsp.protocol as proto
import mtc.lsp.refresh as refresh
import mtc.lsp.reference_index as refidx
import mtc.lsp.uri as uri_ops
import mtc.lsp.utils as utils
import mtc.lsp.workspace as workspace


## Handle workspace/didChangeConfiguration notification.  Applies the
## formatter mode (the only setting this server consumes) and clears all
## cached diagnostics so subsequent pulls recompute with updated settings.
public function handle_did_change_configuration(ws: ref[workspace.Workspace], params: json.Value) -> void:
    apply_format_mode_setting(ws, params)
    ws.diagnostic_cache_clear_all()
    refresh.request_after_change(ws)


## Apply `settings.milkTea.format.mode` (with the host's `milk_tea` / bare
## `format` fallbacks) to the workspace's formatter mode.  The host's
## `formatter_mode_from_settings`.
function apply_format_mode_setting(ws: ref[workspace.Workspace], params: json.Value) -> void:
    let params_obj = params.as_object() else:
        return
    let settings_ptr = unsafe: read(params_obj).get("settings")
    if settings_ptr == null:
        return
    var settings = unsafe: read(settings_ptr)

    var mode = nested_setting_string(settings, array[str, 3]("milkTea", "format", "mode").as_span())
    if mode.is_none():
        mode = nested_setting_string(settings, array[str, 3]("milk_tea", "format", "mode").as_span())
    if mode.is_none():
        mode = nested_setting_string(settings, array[str, 2]("format", "mode").as_span())
    match mode:
        Option.some as value:
            ws.format_mode.clear()
            ws.format_mode.append(value.value)
        Option.none:
            pass


## The string value at the nested `keys` path, or none when any segment is
## missing or the leaf is not a string.
function nested_setting_string(settings: json.Value, keys: span[str]) -> Option[str]:
    var current = settings
    var i: ptr_uint = 0
    while i < keys.len:
        let obj_ptr = current.as_object() else:
            return Option[str].none
        let key = unsafe: read(keys.data + i)
        let next_ptr = unsafe: read(obj_ptr).get(key)
        if next_ptr == null:
            return Option[str].none
        current = unsafe: read(next_ptr)
        i += 1
    return current.as_string()


## Handle workspace/didChangeWorkspaceFolders notification.  Updates the root
## set (existing roots minus removed, plus added), then re-roots the workspace
## so imports, labels and the symbol index see every folder.
public function handle_did_change_workspace_folders(ws: ref[workspace.Workspace], params: json.Value) -> void:
    let obj_ptr = params.as_object() else:
        return
    unsafe:
        let event_ptr = read(obj_ptr).get("event")
        if event_ptr == null:
            return
        let event_obj = read(event_ptr).as_object() else:
            return

        var removed = vec.Vec[string.String].create()
        defer: release_paths(ref_of(removed))
        var added = vec.Vec[string.String].create()
        defer: release_paths(ref_of(added))
        collect_folder_paths(event_obj, "removed", ref_of(removed))
        collect_folder_paths(event_obj, "added", ref_of(added))
        if removed.len() == 0 and added.len() == 0:
            return

        var next = vec.Vec[string.String].create()
        defer: release_paths(ref_of(next))
        var ri: ptr_uint = 0
        while ri < ws.roots.len():
            let root_ptr = ws.roots.get(ri) else:
                break
            ri += 1
            let root = read(root_ptr).as_str()
            if not path_list_contains(ref_of(removed), root) and not path_list_contains(ref_of(next), root):
                next.push(string.String.from_str(root))
        var ai: ptr_uint = 0
        while ai < added.len():
            let added_ptr = added.get(ai) else:
                break
            ai += 1
            let root = read(added_ptr).as_str()
            if not path_list_contains(ref_of(next), root):
                next.push(string.String.from_str(root))

        var views = vec.Vec[str].create()
        defer: views.release()
        var vi: ptr_uint = 0
        while vi < next.len():
            let path_ptr = next.get(vi) else:
                break
            views.push(read(path_ptr).as_str())
            vi += 1
        ws.set_roots(views.as_span())
        refresh.request_after_change(ws)


## Collect the `uri` paths of a workspace-folders array into `paths`.
function collect_folder_paths(event_obj: ptr[json.Object], field: str, paths: ref[vec.Vec[string.String]]) -> void:
    let folders_ptr = unsafe: read(event_obj).get(field)
    if folders_ptr == null:
        return
    let folders = unsafe: read(folders_ptr).as_array() else:
        return
    var i: ptr_uint = 0
    while i < unsafe: read(folders).len():
        let folder_ptr = unsafe: read(folders).get(i) else:
            break
        i += 1
        let folder_obj = unsafe: read(folder_ptr).as_object() else:
            continue
        let uri_ptr = unsafe: read(folder_obj).get("uri")
        if uri_ptr == null:
            continue
        let uri_str = unsafe: read(uri_ptr).as_string() else:
            continue
        match uri_ops.file_uri_to_path(uri_str):
            Option.some as path:
                paths.push(path.value)
            Option.none:
                pass


function path_list_contains(paths: ref[vec.Vec[string.String]], path: str) -> bool:
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


## Handle workspace/willRenameFiles.  It is a *request*: answer with a
## `WorkspaceEdit` that rewrites imports naming the old modules (or `null`),
## then move the index/cache entries so later queries see the new path.
public function handle_will_rename_files(ws: ref[workspace.Workspace], params: json.Value, id: json.Value) -> void:
    var pairs = vec.Vec[RenamePair].create()
    defer: release_rename_pairs(ref_of(pairs))
    collect_rename_pairs(ws, params, ref_of(pairs))

    ws.build_index_if_needed()
    var edit_json = build_rename_workspace_edit(ws, ref_of(pairs))
    defer: edit_json.release()

    move_renamed_documents(ws, params)
    ws.force_reindex()

    # A notification-form call still moves the index (the old corpus shape)
    # but must not emit an id:null response.
    if id.is_null():
        return
    if edit_json.len() == 0:
        proto.write_response(id, json.null_value())
    else:
        proto.write_response_raw(id, edit_json.as_str())


## One `{oldUri,newUri}` pair with both module names.
struct RenamePair:
    old_path: string.String
    new_path: string.String
    old_name: string.String
    new_name: string.String


function release_rename_pairs(pairs: ref[vec.Vec[RenamePair]]) -> void:
    var i: ptr_uint = 0
    while i < pairs.len():
        let entry = pairs.get(i) else:
            break
        unsafe:
            var pair = read(entry)
            pair.old_path.release()
            pair.new_path.release()
            pair.old_name.release()
            pair.new_name.release()
        i += 1
    pairs.release()


## Parse the request's `files` array into rename pairs with module names.
function collect_rename_pairs(
    ws: ref[workspace.Workspace],
    params: json.Value,
    pairs: ref[vec.Vec[RenamePair]]
) -> void:
    let obj_ptr = params.as_object() else:
        return
    unsafe:
        let files_ptr = read(obj_ptr).get("files")
        if files_ptr == null:
            return
        let files = read(files_ptr).as_array() else:
            return
        var i: ptr_uint = 0
        while i < read(files).len():
            let file_ptr = read(files).get(i) else:
                break
            i += 1
            let file_obj = read(file_ptr).as_object() else:
                continue
            let old_uri_ptr = read(file_obj).get("oldUri")
            if old_uri_ptr == null:
                continue
            let new_uri_ptr = read(file_obj).get("newUri")
            if new_uri_ptr == null:
                continue
            let old_uri = read(old_uri_ptr).as_string() else:
                continue
            let new_uri = read(new_uri_ptr).as_string() else:
                continue
            var old_path = uri_ops.file_uri_to_path(old_uri) else:
                continue
            var new_path = uri_ops.file_uri_to_path(new_uri) else:
                old_path.release()
                continue
            var old_name = module_name_for_rename(ws, old_path.as_str())
            var new_name = module_name_for_rename(ws, new_path.as_str())
            pairs.push(RenamePair(
                old_path = old_path,
                new_path = new_path,
                old_name = old_name,
                new_name = new_name,
            ))


## The dotted module name of `path` relative to the most specific module root
## that contains it.
function module_name_for_rename(ws: ref[workspace.Workspace], path: str) -> string.String:
    var roots = ws.effective_module_roots_for(path)
    defer: roots.release()
    let root_span = roots.as_span()
    var best_len: ptr_uint = 0
    var matched = false
    var i: ptr_uint = 0
    while i < root_span.len:
        let root = unsafe: read(root_span.data + i)
        if path_starts_with_dir(path, root) and root.len > best_len:
            best_len = root.len
            matched = true
        i += 1

    var name = string.String.create()
    if not matched:
        return name
    let relative = path.slice(best_len + 1, path.len - best_len - 1)
    var end = relative.len
    if end > 3 and relative.slice(end - 3, 3).equal(".mt"):
        end -= 3
    if end >= 6 and relative.slice(end - 6, 6).equal(".linux"):
        end -= 6
    else if end >= 8 and relative.slice(end - 8, 8).equal(".windows"):
        end -= 8
    else if end >= 6 and relative.slice(end - 6, 6).equal(".macos"):
        end -= 6
    var ci: ptr_uint = 0
    while ci < end:
        let b = relative.byte_at(ci)
        if b == '/':
            name.push_byte(46)
        else:
            name.push_byte(b)
        ci += 1
    return name


function path_starts_with_dir(path: str, dir: str) -> bool:
    if dir.len == 0 or path.len <= dir.len:
        return false
    if not path.slice(0, dir.len).equal(dir):
        return false
    return path.byte_at(dir.len) == '/'


## Build the `WorkspaceEdit` for every indexed file whose import path names a
## renamed module.  Returns an empty string when nothing changes.
function build_rename_workspace_edit(ws: ref[workspace.Workspace], pairs: ref[vec.Vec[RenamePair]]) -> string.String:
    var changes = string.String.create()
    defer: changes.release()
    var file_count: ptr_uint = 0
    var fi: ptr_uint = 0
    while fi < ws.index.files.len():
        let file_ptr = ws.index.files.get(fi) else:
            break
        fi += 1
        let path = unsafe: read(file_ptr).path.as_str()
        if path_is_renamed(path, pairs):
            continue
        var content = ws.document_source(path) else:
            continue
        defer: content.release()
        var lines = utils.split_lines(content.as_str())
        defer: lines.release()
        var edits = string.String.create()
        defer: edits.release()
        var edit_count: ptr_uint = 0
        var li: ptr_uint = 0
        while li < lines.len():
            let line_text = utils.line_at(ref_of(lines), li)
            let indent = utils.indent_of(line_text)
            let rest = line_text.slice(indent, line_text.len - indent)
            if not rest.starts_with("import "):
                li += 1
                continue
            let path_start = indent + 7
            var path_end = path_start
            while path_end < line_text.len:
                let b = line_text.byte_at(path_end)
                if b == ' ' or b == '\t' or b == '\r':
                    break
                path_end += 1
            let import_name = line_text.slice(path_start, path_end - path_start)
            let new_name = replacement_module(ref_of(pairs), import_name)
            if new_name.len > 0:
                if edit_count > 0:
                    edits.append(",")
                edit_count += 1
                let start_char = ws.output_character_in(content.as_str(), li, path_start)
                let end_char = ws.output_character_in(content.as_str(), li, path_end)
                edits.append("{\"range\":{\"start\":{\"line\":")
                edits.append_format(f"#{li}")
                edits.append(",\"character\":")
                edits.append_format(f"#{start_char}")
                edits.append("},\"end\":{\"line\":")
                edits.append_format(f"#{li}")
                edits.append(",\"character\":")
                edits.append_format(f"#{end_char}")
                edits.append("}},\"newText\":\"")
                proto.append_escaped(ref_of(edits), new_name)
                edits.append("\"}")
            li += 1

        if edit_count > 0:
            if file_count > 0:
                changes.append(",")
            file_count += 1
            changes.append("\"file://")
            proto.append_escaped(ref_of(changes), path)
            changes.append("\":[")
            changes.append(edits.as_str())
            changes.append("]")

    if file_count == 0:
        return string.String.create()
    var result = string.String.create()
    result.append("{\"changes\":{")
    result.append(changes.as_str())
    result.append("}}")
    return result


function path_is_renamed(path: str, pairs: ref[vec.Vec[RenamePair]]) -> bool:
    var i: ptr_uint = 0
    while i < pairs.len():
        let pair_ptr = pairs.get(i) else:
            break
        let pair = unsafe: read(pair_ptr)
        if path.equal(pair.old_path.as_str()) or path.equal(pair.new_path.as_str()):
            return true
        i += 1
    return false


## The new module name for `old_module`, or "" when it is not renamed.
function replacement_module(pairs: ref[vec.Vec[RenamePair]], old_module: str) -> str:
    var i: ptr_uint = 0
    while i < pairs.len():
        let pair_ptr = pairs.get(i) else:
            break
        let pair = unsafe: read(pair_ptr)
        if old_module.equal(pair.old_name.as_str()) and pair.new_name.len() > 0:
            return pair.new_name.as_str()
        i += 1
    return ""


## Walk the notification's `files` array and move each `{oldUri, newUri}` pair.
function move_renamed_documents(ws: ref[workspace.Workspace], params: json.Value) -> void:
    let obj_ptr = params.as_object() else:
        return
    unsafe:
        let files_ptr = read(obj_ptr).get("files")
        if files_ptr == null:
            return
        let files_arr = read(files_ptr).as_array()
        if files_arr == null:
            return
        var fi: ptr_uint = 0
        while fi < read(files_arr).len():
            let file_ptr = read(files_arr).get(fi)
            fi += 1
            if file_ptr == null:
                continue
            let file_obj = read(file_ptr).as_object()
            if file_obj == null:
                continue
            let old_uri_ptr = read(file_obj).get("oldUri")
            if old_uri_ptr == null:
                continue
            match read(old_uri_ptr).as_string():
                Option.some as old_uri:
                    let new_uri_ptr = read(file_obj).get("newUri")
                    if new_uri_ptr == null:
                        continue
                    match read(new_uri_ptr).as_string():
                        Option.some as new_uri:
                            var old_path = uri_ops.file_uri_to_path(old_uri.value) else:
                                continue
                            var new_path = uri_ops.file_uri_to_path(new_uri.value) else:
                                old_path.release()
                                continue
                            move_renamed_document(ws, old_path.as_str(), new_path.as_str())
                            old_path.release()
                            new_path.release()
                        Option.none:
                            pass
                Option.none:
                    pass


## Move one file's identifier and definition entries to the new path and drop
## the old path's entries and caches (the host's `rename_indexed_file`).  The
## new path is not a feature document of its own — the host answers no hover,
## symbol or reference request for it until the client opens it — but its
## content participates in the workspace scans through those entries.
function move_renamed_document(ws: ref[workspace.Workspace], old_path: str, new_path: str) -> void:
    var content = ws.document_source(old_path) else:
        drop_renamed_document(ws, old_path)
        return
    defer: content.release()
    refidx.note(ref_of(ws.reference_index), new_path, content.as_str())
    defidx.warm_names(ref_of(ws.definition_index), new_path, content.as_str())
    drop_renamed_document(ws, old_path)


## Drop the old path's per-file caches and index entries.
function drop_renamed_document(ws: ref[workspace.Workspace], old_path: str) -> void:
    ws.diagnostic_cache_clear(old_path)
    ws.semantic_token_cache_remove(old_path)
    defidx.forget(ref_of(ws.definition_index), old_path)
    refidx.forget(ref_of(ws.reference_index), old_path)


## Handle workspace/didChangeWatchedFiles notification.  Clears diagnostic and
## semantic-token caches, and re-indexes each changed path: a created or
## changed file joins (or updates in) the workspace symbol index on its next
## query, a deleted one drops out of it (the host's `apply_watched_file_change`
## plus its follow-up reindex).
public function handle_did_change_watched_files(ws: ref[workspace.Workspace], params: json.Value) -> void:
    ws.diagnostic_cache_clear_all()
    ws.semantic_token_cache_remove_all()
    note_watched_paths(ws, params)
    refresh.request_after_change(ws)


## Mark every `changes[].uri` path dirty for the workspace symbol index and
## drop its cross-file definition/reference entries.
function note_watched_paths(ws: ref[workspace.Workspace], params: json.Value) -> void:
    let obj_ptr = params.as_object() else:
        return
    let changes_ptr = unsafe: read(obj_ptr).get("changes")
    if changes_ptr == null:
        return
    let changes_arr = unsafe: read(changes_ptr).as_array() else:
        return
    var i: ptr_uint = 0
    while i < unsafe: read(changes_arr).len():
        let change_ptr = unsafe: read(changes_arr).get(i)
        if change_ptr != null:
            let change_obj = unsafe: read(change_ptr).as_object()
            if change_obj != null:
                let uri_ptr = unsafe: read(change_obj).get("uri")
                if uri_ptr != null:
                    match unsafe: read(uri_ptr).as_string():
                        Option.some as uri_str:
                            var path = uri_ops.file_uri_to_path(uri_str.value) else:
                                i += 1
                                continue
                            ws.mark_index_dirty(path.as_str())
                            defidx.forget(ref_of(ws.definition_index), path.as_str())
                            refidx.forget(ref_of(ws.reference_index), path.as_str())
                            path.release()
                        Option.none:
                            pass
        i += 1

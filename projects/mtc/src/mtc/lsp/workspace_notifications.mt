## Workspace notification handlers with cache invalidation.
##
## Design: the self-host LSP caches minimally (diagnostics, semantic tokens,
## workspace symbols) so broad invalidation costs little.  Scanning each open
## document's import statements for selective clearing would be ~60 lines of
## code to avoid recomputing diagnostics for a handful of unaffected files.
## The tradeoff is deliberately kept simple.

import std.json as json

import mtc.lsp.definition_index as defidx
import mtc.lsp.protocol as proto
import mtc.lsp.reference_index as refidx
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace


## Handle workspace/didChangeConfiguration notification.  Applies the
## formatter mode (the only setting this server consumes) and clears all
## cached diagnostics so subsequent pulls recompute with updated settings.
public function handle_did_change_configuration(ws: ref[workspace.Workspace], params: json.Value) -> void:
    apply_format_mode_setting(ws, params)
    ws.diagnostic_cache_clear_all()


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


## Handle workspace/didChangeWorkspaceFolders notification.  Clears
## caches and forces a workspace symbol index rebuild so symbols from
## new folder roots are discovered on the next query.
public function handle_did_change_workspace_folders(ws: ref[workspace.Workspace], params: json.Value) -> void:
    ws.diagnostic_cache_clear_all()
    ws.force_reindex()


## Handle workspace/willRenameFiles notification.  Clears caches for
## each renamed file's old path.  The client handles the didOpen/didClose
## transition separately — this just ensures lingering cache entries for
## the old path don't persist.
public function handle_will_rename_files(ws: ref[workspace.Workspace], params: json.Value) -> void:
    # Clear per-file caches for old paths and force index rebuild.
    invalidate_for_renamed_files(ws, params)
    ws.force_reindex()


## Handle workspace/didChangeWatchedFiles notification.  Clears diagnostic and
## semantic-token caches, and re-indexes each changed path: a created or
## changed file joins (or updates in) the workspace symbol index on its next
## query, a deleted one drops out of it (the host's `apply_watched_file_change`
## plus its follow-up reindex).
public function handle_did_change_watched_files(ws: ref[workspace.Workspace], params: json.Value) -> void:
    ws.diagnostic_cache_clear_all()
    ws.semantic_token_cache_remove_all()
    note_watched_paths(ws, params)


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


## Clear diagnostic and semantic token caches for old file paths in a
## willRenameFiles notification.  Walks the params.files array and
## clears per-URI caches for each oldUri.
function invalidate_for_renamed_files(ws: ref[workspace.Workspace], params: json.Value) -> void:
    let obj_ptr = params.as_object()
    if obj_ptr == null:
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
            if file_ptr != null:
                let file_obj = read(file_ptr).as_object()
                if file_obj != null:
                    let old_uri_ptr = read(file_obj).get("oldUri")
                    if old_uri_ptr != null:
                        match read(old_uri_ptr).as_string():
                            Option.some as old_str:
                                var old_path = uri_ops.file_uri_to_path(old_str.value) else:
                                    continue
                                ws.diagnostic_cache_clear(old_path.as_str())
                                ws.semantic_token_cache_remove(old_path.as_str())
                                old_path.release()
                            Option.none:
                                pass
            fi += 1

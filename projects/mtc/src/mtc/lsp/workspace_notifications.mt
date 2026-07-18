## Workspace notification handlers with cache invalidation.
##
## Design: the self-host LSP caches minimally (diagnostics, semantic tokens,
## workspace symbols) so broad invalidation costs little.  Scanning each open
## document's import statements for selective clearing would be ~60 lines of
## code to avoid recomputing diagnostics for a handful of unaffected files.
## The tradeoff is deliberately kept simple.

import std.json as json

import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace


## Handle workspace/didChangeConfiguration notification.  Clears all
## cached diagnostics so subsequent pulls recompute with updated settings.
public function handle_did_change_configuration(ws: ref[workspace.Workspace], params: json.Value) -> void:
    ws.diagnostic_cache_clear_all()


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


## Handle workspace/didChangeWatchedFiles notification.  Clears
## diagnostic caches so affected files are re-linted on next pull.
## The self-host's cache model (just two per-file caches) makes broad
## invalidation preferable to running the parser on every open document
## to determine selective import matches.
public function handle_did_change_watched_files(ws: ref[workspace.Workspace], params: json.Value) -> void:
    ws.diagnostic_cache_clear_all()
    ws.semantic_token_cache_remove_all()


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

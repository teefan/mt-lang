## Workspace-level notification handlers.  Handles didChangeConfiguration,
## didChangeWorkspaceFolders, willRenameFiles, and didChangeWatchedFiles.

import std.json as json

import mtc.lsp.workspace as workspace


## Handle workspace/didChangeConfiguration notification.  Clears cached
## diagnostics so subsequent pulls recompute with updated settings.
public function handle_did_change_configuration(ws: ref[workspace.Workspace], params: json.Value) -> void:
    ws.diagnostic_cache_clear_all()


## Handle workspace/didChangeWorkspaceFolders notification.
public function handle_did_change_workspace_folders(ws: ref[workspace.Workspace], params: json.Value) -> void:
    ws.diagnostic_cache_clear_all()


## Handle workspace/willRenameFiles notification.  The workspace index
## is rebuilt lazily on demand, so we just clear caches to force a
## fresh diagnostic pass on the renamed files.
public function handle_will_rename_files(ws: ref[workspace.Workspace], params: json.Value) -> void:
    pass


## Handle workspace/didChangeWatchedFiles notification.  Clears
## diagnostic caches so affected files are re-linted on next pull.
public function handle_did_change_watched_files(ws: ref[workspace.Workspace], params: json.Value) -> void:
    ws.diagnostic_cache_clear_all()

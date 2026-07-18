## Workspace-level notification handlers.  Handles didChangeConfiguration,
## didChangeWorkspaceFolders, willRenameFiles, and didChangeWatchedFiles.
## These are currently no-ops that acknowledge the notifications.

import std.json as json

import mtc.lsp.workspace as workspace


## Handle workspace/didChangeConfiguration notification.  Settings are
## preserved but not actively consumed in the current self-host server.
public function handle_did_change_configuration(ws: ref[workspace.Workspace], params: json.Value) -> void:
    pass


## Handle workspace/didChangeWorkspaceFolders notification.
public function handle_did_change_workspace_folders(ws: ref[workspace.Workspace], params: json.Value) -> void:
    pass


## Handle workspace/willRenameFiles notification.
public function handle_will_rename_files(ws: ref[workspace.Workspace], params: json.Value) -> void:
    pass


## Handle workspace/didChangeWatchedFiles notification.
public function handle_did_change_watched_files(ws: ref[workspace.Workspace], params: json.Value) -> void:
    pass

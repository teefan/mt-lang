## Lifecycle handlers — initialize, initialized, shutdown, exit.

import std.json as json
import std.string as string
import std.vec as vec

import mtc.cli_help as cli_help
import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace


## The semantic-token legend, mirroring the host's exactly (23 token types,
## 10 modifiers).  The indices are positional: `semantic_tokens.mt`'s TOKEN_*
## constants must match this order.
const TOKEN_TYPES_JSON: str = "\"tokenTypes\":[\"namespace\",\"type\",\"class\",\"enum\",\"interface\",\"struct\",\"typeParameter\",\"parameter\",\"variable\",\"property\",\"enumMember\",\"event\",\"function\",\"method\",\"macro\",\"keyword\",\"modifier\",\"comment\",\"string\",\"number\",\"regexp\",\"operator\",\"decorator\"]"
const TOKEN_MODIFIERS_JSON: str = "\"tokenModifiers\":[\"declaration\",\"definition\",\"readonly\",\"static\",\"deprecated\",\"abstract\",\"async\",\"modification\",\"documentation\",\"defaultLibrary\"]"


## Handle the `initialize` request.  The client's `rootUri` (or `rootPath`) is
## the workspace root, exactly as the host does — the CLI argument is only a
## fallback for clients that pass none.
public function handle_initialize(id: json.Value, params: json.Value, ws: ref[workspace.Workspace]) -> void:
    apply_client_root(params, ws)
    ws.pull_diagnostics_active = client_supports_pull_diagnostics(params)
    ws.client_watched_files_dynamic = client_supports_watched_files_registration(params)
    let position_encoding = client_position_encoding(params)
    ws.set_position_encoding(position_encoding.equal("utf-16"))
    ws.initialize_received = true

    var r = string.String.create()
    defer: r.release()

    r.append("{\"jsonrpc\":\"2.0\",\"id\":")
    proto.append_json_value(ref_of(r), id)

    # capabilities
    r.append(",\"result\":{\"capabilities\":{")
    r.append("\"positionEncoding\":\"")
    r.append(position_encoding)
    r.append("\"")
    r.append(",\"textDocumentSync\":{\"openClose\":true,\"change\":2,\"save\":{\"includeText\":true},\"willSaveWaitUntil\":true}")
    r.append(",\"definitionProvider\":true")
    r.append(",\"declarationProvider\":true")
    r.append(",\"typeDefinitionProvider\":true")
    r.append(",\"implementationProvider\":true")
    r.append(",\"hoverProvider\":true")
    r.append(",\"referencesProvider\":true")
    r.append(",\"documentHighlightProvider\":true")
    r.append(",\"documentSymbolProvider\":true")
    r.append(",\"workspaceSymbolProvider\":true")
    r.append(",\"documentFormattingProvider\":true")
    r.append(",\"documentOnTypeFormattingProvider\":{\"firstTriggerCharacter\":\"\\n\",\"moreTriggerCharacter\":[]}")
    r.append(",\"foldingRangeProvider\":true")
    r.append(",\"selectionRangeProvider\":true")
    r.append(",\"inlayHintProvider\":true")
    r.append(",\"completionProvider\":{\"triggerCharacters\":[\".\",\"(\",\" \"],\"resolveProvider\":true}")
    # signatureHelp: trigger on open-paren and comma
    r.append(",\"signatureHelpProvider\":{\"triggerCharacters\":[\"(\",\",\"],\"retriggerCharacters\":[\",\"]}")
    r.append(",\"renameProvider\":{\"prepareProvider\":true}")
    r.append(",\"codeActionProvider\":{\"codeActionKinds\":[\"quickfix\",\"source.fixAll\"]}")
    r.append(",\"executeCommandProvider\":{\"commands\":[\"mtc.restartServer\"]}")
    r.append(",\"documentRangeFormattingProvider\":true")
    r.append(",\"linkedEditingRangeProvider\":true")
    r.append(",\"documentLinkProvider\":{\"resolveProvider\":true}")
    r.append(",\"codeLensProvider\":{\"resolveProvider\":true}")
    r.append(",\"typeHierarchyProvider\":true")
    r.append(",\"callHierarchyProvider\":true")
    r.append(",\"diagnosticProvider\":{\"interFileDependencies\":true,\"workspaceDiagnostics\":true}")
    # semantic tokens: legend + full + range + delta
    r.append(",\"semanticTokensProvider\":{\"legend\":{")
    r.append(TOKEN_TYPES_JSON)
    r.append(",")
    r.append(TOKEN_MODIFIERS_JSON)
    r.append("},\"full\":{\"delta\":true},\"range\":true}")
    # workspace: folders + file operations + watched files
    r.append(",\"workspace\":{\"workspaceFolders\":{\"supported\":true,\"changeNotifications\":true},")
    r.append("\"fileOperations\":{\"willRename\":{\"filters\":[{\"pattern\":{\"glob\":\"**/*.mt\"},\"scheme\":\"file\"}]}}}")
    r.append("}")
    r.append(",\"serverInfo\":{\"name\":\"milk-tea\",\"version\":\"")
    r.append(cli_help.VERSION)
    r.append("\"}")
    r.append(",\"experimental\":{\"milkTea\":{\"documentContext\":true,\"debugInfo\":true}}")
    r.append("}}")

    proto.write_framed_json(r.as_str())


## Re-root the workspace from the client's `workspaceFolders`, or its
## `rootUri`/`rootPath` for a single-root client.
function apply_client_root(params: json.Value, ws: ref[workspace.Workspace]) -> void:
    let obj_ptr = params.as_object()
    if obj_ptr == null:
        return
    unsafe:
        let folders_ptr = read(obj_ptr).get("workspaceFolders")
        if folders_ptr != null and apply_workspace_folders(ws, folders_ptr):
            return
        let root_uri_ptr = read(obj_ptr).get("rootUri")
        if root_uri_ptr != null:
            let root_uri = read(root_uri_ptr).as_string() else:
                return
            if root_uri.len > 0:
                var path = uri_ops.file_uri_to_path(root_uri) else:
                    return
                defer: path.release()
                ws.set_root(path.as_str())
                return
        let root_path_ptr = read(obj_ptr).get("rootPath")
        if root_path_ptr != null:
            let root_path = read(root_path_ptr).as_string() else:
                return
            if root_path.len > 0:
                ws.set_root(root_path)


## Apply a non-empty `workspaceFolders` value; false leaves the caller to use
## `rootUri`/`rootPath` (a null array or one with no usable URI).
function apply_workspace_folders(ws: ref[workspace.Workspace], folders_value: ptr[json.Value]) -> bool:
    unsafe:
        let folders = read(folders_value).as_array() else:
            return false
        var folder_paths = vec.Vec[string.String].create()
        defer: release_owned_paths(ref_of(folder_paths))
        var fi: ptr_uint = 0
        while fi < read(folders).len():
            let folder_ptr = read(folders).get(fi) else:
                break
            fi += 1
            let folder_obj = read(folder_ptr).as_object() else:
                continue
            let uri_ptr = read(folder_obj).get("uri")
            if uri_ptr == null:
                continue
            let uri_str = read(uri_ptr).as_string() else:
                continue
            match uri_ops.file_uri_to_path(uri_str):
                Option.some as path:
                    folder_paths.push(path.value)
                Option.none:
                    pass
        if folder_paths.len() == 0:
            return false
        var views = vec.Vec[str].create()
        defer: views.release()
        var vi: ptr_uint = 0
        while vi < folder_paths.len():
            let path_ptr = folder_paths.get(vi) else:
                break
            views.push(read(path_ptr).as_str())
            vi += 1
        ws.set_roots(views.as_span())
        return true


## Release a vector of owned path strings.
function release_owned_paths(paths: ref[vec.Vec[string.String]]) -> void:
    var i: ptr_uint = 0
    while i < paths.len():
        let entry = paths.get(i) else:
            break
        unsafe: read(entry).release()
        i += 1
    paths.release()


## True when the client advertised dynamic registration for
## `workspace/didChangeWatchedFiles`.
function client_supports_watched_files_registration(params: json.Value) -> bool:
    let obj_ptr = params.as_object() else:
        return false
    unsafe:
        let caps_ptr = read(obj_ptr).get("capabilities")
        if caps_ptr == null:
            return false
        let caps_obj = read(caps_ptr).as_object() else:
            return false
        let workspace_ptr = read(caps_obj).get("workspace")
        if workspace_ptr == null:
            return false
        let workspace_obj = read(workspace_ptr).as_object() else:
            return false
        let watched_ptr = read(workspace_obj).get("didChangeWatchedFiles")
        if watched_ptr == null:
            return false
        let watched_obj = read(watched_ptr).as_object() else:
            return false
        let dynamic_ptr = read(watched_obj).get("dynamicRegistration")
        if dynamic_ptr == null:
            return false
        match read(dynamic_ptr).as_boolean():
            Option.some as flag:
                return flag.value
            Option.none:
                return false


## The position encoding this server will emit.  UTF-8 is chosen when the
## client offers it (it keeps the server's byte columns as the wire format);
## otherwise the LSP default, UTF-16, is selected and positions are converted
## at both boundaries.
function client_position_encoding(params: json.Value) -> str:
    let obj_ptr = params.as_object() else:
        return "utf-16"
    unsafe:
        let caps_ptr = read(obj_ptr).get("capabilities")
        if caps_ptr == null:
            return "utf-16"
        let caps_obj = read(caps_ptr).as_object() else:
            return "utf-16"
        let general_ptr = read(caps_obj).get("general")
        if general_ptr == null:
            return "utf-16"
        let general_obj = read(general_ptr).as_object() else:
            return "utf-16"
        let encodings_ptr = read(general_obj).get("positionEncodings")
        if encodings_ptr == null:
            return "utf-16"
        let encodings = read(encodings_ptr).as_array() else:
            return "utf-16"
        var i: ptr_uint = 0
        while i < read(encodings).len():
            let entry_ptr = read(encodings).get(i) else:
                break
            match read(entry_ptr).as_string():
                Option.some as encoding:
                    if encoding.value.equal("utf-8"):
                        return "utf-8"
                Option.none:
                    pass
            i += 1
    return "utf-16"


## Handle the `initialized` notification.
public function handle_initialized(ws: ref[workspace.Workspace]) -> void:
    ws.initialized = true


## True when the client advertised pull-diagnostics support
## (`textDocument.diagnostic`).  The host suppresses `publishDiagnostics` when it
## does; otherwise VS Code shows each diagnostic twice, once from the pull
## report and once from the push notification.
function client_supports_pull_diagnostics(params: json.Value) -> bool:
    let obj_ptr = params.as_object()
    if obj_ptr == null:
        return false
    unsafe:
        let caps_ptr = read(obj_ptr).get("capabilities")
        if caps_ptr == null:
            return false
        let caps_obj = read(caps_ptr).as_object() else:
            return false
        let td_ptr = read(caps_obj).get("textDocument")
        if td_ptr == null:
            return false
        let td_obj = read(td_ptr).as_object() else:
            return false
        let diagnostic_ptr = read(td_obj).get("diagnostic")
        if diagnostic_ptr == null:
            return false
        return not read(diagnostic_ptr).is_null()

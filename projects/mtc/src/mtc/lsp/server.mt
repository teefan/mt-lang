## LSP server — message loop, handler dispatch, and the `lsp` subcommand entry
## point.  Dispatches incoming JSON-RPC messages to the appropriate handler
## modules, manages the workspace lifetime, and coordinates per-message cleanup.

import std.json as json
import std.str
import std.string as string

import mtc.lsp.diagnostics as diag
import mtc.lsp.formatting as formatting
import mtc.lsp.lifecycle as lifecycle
import mtc.lsp.navigation as nav
import mtc.lsp.protocol as proto
import mtc.lsp.symbols as symbols
import mtc.lsp.text_docs as text_docs
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace


## Start the LSP server on stdio.  Blocks until shutdown or EOF.
public function run(args: span[str]) -> int:
    let root = workspace_root_from_args(args)
    var ws = workspace.Workspace.create(root)
    defer ws.release()

    var running = true
    while running:
        var msg_opt = proto.read_message()
        match msg_opt:
            Option.some as msg_payload:
                var msg = msg_payload.value
                defer msg.release()
                let method = msg.method.as_str()
                if method == "exit":
                    running = false
                dispatch_method(ws, method, msg)
            Option.none:
                running = false

    return 0


## Dispatch handler for a known method.
function dispatch_method(ws: ref[workspace.Workspace], method: str, msg: proto.Message) -> void:
    # Lifecycle
    if method == "initialize":
        lifecycle.handle_initialize(msg.id)
    else if method == "initialized":
        lifecycle.handle_initialized()
    else if method == "shutdown":
        var result = json.null_value()
        proto.write_response(msg.id, result)
    else if method == "exit":
        return

    # Text document sync
    else if method == "textDocument/didOpen":
        text_docs.handle_did_open(ws, msg.params)
    else if method == "textDocument/didChange":
        text_docs.handle_did_change(ws, msg.params)
    else if method == "textDocument/didClose":
        text_docs.handle_did_close(ws, msg.params)
    else if method == "textDocument/didSave":
        text_docs.handle_did_save(ws, msg.params)

    # Formatting (Tier 2)
    else if method == "textDocument/formatting":
        formatting.handle_formatting(ws, msg.params, msg.id)

    # Document symbols (Tier 2)
    else if method == "textDocument/documentSymbol":
        let uri = extract_text_doc_uri(msg.params)
        symbols.handle_document_symbols(uri, msg.id)

    # Navigation (Tier 2)
    else if method == "textDocument/definition":
        var pos = extract_position_params(msg.params)
        nav.handle_definition(pos.uri, pos.line, pos.character, msg.id)
    else if method == "textDocument/hover":
        var pos = extract_position_params(msg.params)
        nav.handle_hover(pos.uri, pos.line, pos.character, msg.id)
    else if method == "textDocument/references":
        var pos = extract_position_params(msg.params)
        nav.handle_references(pos.uri, pos.line, pos.character, msg.id)

    else:
        if not msg.id.is_null():
            proto.write_error(msg.id, -32601, "method not found")


## Extract the textDocument.uri from a generic params object.
function extract_text_doc_uri(params: json.Value) -> str:
    let obj_ptr = params.as_object()
    if obj_ptr == null:
        return ""
    unsafe:
        let text_doc_ptr = read(obj_ptr).get("textDocument")
        if text_doc_ptr == null:
            return ""
        let td_obj_ptr = read(text_doc_ptr).as_object()
        if td_obj_ptr == null:
            return ""
        let uri_val_ptr = read(td_obj_ptr).get("uri")
        if uri_val_ptr == null:
            return ""
        let uri_str = read(uri_val_ptr).as_string() else:
            return ""
        return uri_str


struct PositionParams:
    uri: str
    line: ptr_uint
    character: ptr_uint


## Extract textDocument/definition-like position params.
function extract_position_params(params: json.Value) -> PositionParams:
    let obj_ptr = params.as_object()
    if obj_ptr == null:
        return PositionParams(uri = "", line = 0z, character = 0z)

    var uri: str = ""
    var line: ptr_uint = 0
    var character: ptr_uint = 0
    unsafe:
        let text_doc_ptr = read(obj_ptr).get("textDocument")
        if text_doc_ptr != null:
            let td_obj_ptr = read(text_doc_ptr).as_object()
            if td_obj_ptr != null:
                let uri_val = read(td_obj_ptr).get("uri")
                if uri_val != null:
                    let s = read(uri_val).as_string() else:
                        return PositionParams(uri = "", line = 0z, character = 0z)
                    uri = s

        let pos_ptr = read(obj_ptr).get("position")
        if pos_ptr != null:
            let pos_obj_ptr = read(pos_ptr).as_object()
            if pos_obj_ptr != null:
                let line_val = read(pos_obj_ptr).get("line")
                if line_val != null:
                    let n = read(line_val).as_number() else:
                        return PositionParams(uri = "", line = 0z, character = 0z)
                    line = ptr_uint<-int<-n

                let char_val = read(pos_obj_ptr).get("character")
                if char_val != null:
                    let c = read(char_val).as_number() else:
                        return PositionParams(uri = "", line = 0z, character = 0z)
                    character = ptr_uint<-int<-c

    return PositionParams(uri = uri, line = line, character = character)


## Determine the workspace root from CLI arguments or the current directory.
function workspace_root_from_args(args: span[str]) -> str:
    if args.len >= 1:
        unsafe:
            return read(args.data + 0)

    return "."

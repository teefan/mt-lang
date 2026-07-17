## LSP server — message loop, handler dispatch, and the `lsp` subcommand entry
## point.  Dispatches incoming JSON-RPC messages to the appropriate handler
## modules, manages the workspace lifetime, and coordinates per-message cleanup.

import std.json as json
import std.string as string

import mtc.lsp.diagnostics as diag
import mtc.lsp.lifecycle as lifecycle
import mtc.lsp.protocol as proto
import mtc.lsp.text_docs as text_docs
import mtc.lsp.workspace as workspace


## Start the LSP server on stdio.  Blocks until shutdown or EOF.
## Reads messages in a synchronous `read → dispatch → respond` loop.
##
## `args` is the span of CLI arguments that follow `mtc lsp` (currently
## unused — the workspace root is inferred from the current directory).
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


## Dispatch handler for a known method.  Extracted from the loop so `exit`
## can be intercepted before normal dispatch.
function dispatch_method(ws: ref[workspace.Workspace], method: str, msg: proto.Message) -> void:
    if method == "initialize":
        lifecycle.handle_initialize(msg.id)
    else if method == "initialized":
        lifecycle.handle_initialized()
    else if method == "shutdown":
        var result = json.null_value()
        proto.write_response(msg.id, result)
    else if method == "exit":
        return
    else if method == "textDocument/didOpen":
        text_docs.handle_did_open(ws, msg.params)
    else if method == "textDocument/didChange":
        text_docs.handle_did_change(ws, msg.params)
    else if method == "textDocument/didClose":
        text_docs.handle_did_close(ws, msg.params)
    else if method == "textDocument/didSave":
        text_docs.handle_did_save(ws, msg.params)
    else:
        if not msg.id.is_null():
            proto.write_error(msg.id, -32601, "method not found")


## Determine the workspace root from CLI arguments or the current directory.
function workspace_root_from_args(args: span[str]) -> str:
    if args.len >= 1:
        unsafe:
            return read(args.data + 0)

    # Fall back: infer workspace root from the project directory containing std/.
    # Use "." as sentinel; workspace discovery will traverse upward.
    return "."

## LSP server — message loop, handler dispatch, and the `lsp` subcommand entry
## point.  Dispatches incoming JSON-RPC messages to the appropriate handler
## modules, manages the workspace lifetime, and coordinates per-message cleanup.

import std.json as json
import std.str
import std.string as string
import std.vec as vec

import mtc.lsp.call_hierarchy as call_hier
import mtc.lsp.code_actions as code_actions
import mtc.lsp.code_lens as code_lens
import mtc.lsp.completion as completion
import mtc.lsp.debug_info as debug_info
import mtc.lsp.diagnostics as diag
import mtc.lsp.document_context as doc_ctx
import mtc.lsp.document_link as doc_link
import mtc.lsp.execute_command as exec_cmd
import mtc.lsp.folding as folding
import mtc.lsp.formatting as formatting
import mtc.lsp.highlight as highlight
import mtc.lsp.inlay_hints as inlay
import mtc.lsp.lifecycle as lifecycle
import mtc.lsp.linked_editing_range as linked_range
import mtc.lsp.navigation as nav
import mtc.lsp.on_type_formatting as on_type
import mtc.lsp.protocol as proto
import mtc.lsp.rename as rename_mod
import mtc.lsp.selection as selection
import mtc.lsp.semantic_tokens as semtok
import mtc.lsp.signature_help as sighelp
import mtc.lsp.symbols as symbols
import mtc.lsp.text_docs as text_docs
import mtc.lsp.type_hierarchy as type_hier
import mtc.lsp.workspace as workspace
import mtc.lsp.workspace_symbols as wsym


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
                else:
                    running = dispatch_method(ws, method, msg)
            Option.none:
                running = false

    return 0


## Dispatch handler for a known method.  Returns false when the server
## should exit (e.g. after a restart command).
function dispatch_method(ws: ref[workspace.Workspace], method: str, msg: proto.Message) -> bool:
    # Lifecycle
    if method == "initialize":
        lifecycle.handle_initialize(msg.id)
    else if method == "initialized":
        lifecycle.handle_initialized()
    else if method == "shutdown":
        var result = json.null_value()
        proto.write_response(msg.id, result)
    else if method == "exit":
        return false

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
    else if method == "textDocument/rangeFormatting":
        formatting.handle_range_formatting(ws, msg.params, msg.id)

    # Document symbols (Tier 2)
    else if method == "textDocument/documentSymbol":
        let uri = extract_text_doc_uri(msg.params)
        symbols.handle_document_symbols(ws, uri, msg.id)

    # Navigation (Tier 2)
    else if method == "textDocument/definition" or method == "textDocument/declaration":
        var pos = extract_position_params(msg.params)
        nav.handle_definition(ws, pos.uri, pos.line, pos.character, msg.id)
    else if method == "textDocument/typeDefinition":
        var pos = extract_position_params(msg.params)
        nav.handle_type_definition(ws, pos.uri, pos.line, pos.character, msg.id)
    else if method == "textDocument/implementation":
        var pos = extract_position_params(msg.params)
        nav.handle_implementation(ws, pos.uri, pos.line, pos.character, msg.id)
    else if method == "textDocument/hover":
        var pos = extract_position_params(msg.params)
        nav.handle_hover(ws, pos.uri, pos.line, pos.character, msg.id)
    else if method == "textDocument/references":
        var pos = extract_position_params(msg.params)
        nav.handle_references(ws, pos.uri, pos.line, pos.character, msg.id)
    else if method == "textDocument/documentHighlight":
        var pos = extract_position_params(msg.params)
        highlight.handle_document_highlight(ws, pos.uri, pos.line, pos.character, msg.id)
    else if method == "textDocument/foldingRange":
        let uri = extract_text_doc_uri(msg.params)
        folding.handle_folding_range(ws, uri, msg.id)
    else if method == "textDocument/selectionRange":
        let uri = extract_text_doc_uri(msg.params)
        var positions = extract_selection_positions(msg.params)
        selection.handle_selection_range(ws, uri, positions.as_span(), msg.id)
        positions.release()
    else if method == "workspace/symbol":
        wsym.handle_workspace_symbol(ws, extract_query(msg.params), msg.id)

    # Code lens
    else if method == "textDocument/codeLens":
        let uri = extract_text_doc_uri(msg.params)
        code_lens.handle_code_lens(ws, uri, msg.id)
    else if method == "codeLens/resolve":
        code_lens.handle_code_lens_resolve(ws, msg.params, msg.id)

    # Type hierarchy
    else if method == "textDocument/prepareTypeHierarchy":
        var pos = extract_position_params(msg.params)
        type_hier.handle_prepare_type_hierarchy(ws, pos.uri, pos.line, pos.character, msg.id)
    else if method == "typeHierarchy/supertypes":
        type_hier.handle_supertypes(ws, msg.params, msg.id)
    else if method == "typeHierarchy/subtypes":
        type_hier.handle_subtypes(ws, msg.params, msg.id)

    # Call hierarchy
    else if method == "textDocument/prepareCallHierarchy":
        var pos = extract_position_params(msg.params)
        call_hier.handle_prepare_call_hierarchy(ws, pos.uri, pos.line, pos.character, msg.id)
    else if method == "callHierarchy/incomingCalls":
        call_hier.handle_incoming_calls(ws, msg.params, msg.id)
    else if method == "callHierarchy/outgoingCalls":
        call_hier.handle_outgoing_calls(ws, msg.params, msg.id)

    # Document links
    else if method == "textDocument/documentLink":
        doc_link.handle_document_link(ws, msg.params, msg.id)
    else if method == "documentLink/resolve":
        doc_link.handle_document_link_resolve(msg.params, msg.id)

    # Linked editing range
    else if method == "textDocument/linkedEditingRange":
        var pos = extract_position_params(msg.params)
        linked_range.handle_linked_editing_range(ws, pos.uri, pos.line, pos.character, msg.id)

    # Execute command
    else if method == "workspace/executeCommand":
        exec_cmd.handle_execute_command(msg.params, msg.id)
        # The restart command tells us to exit.
        let command_name = extract_command_name(msg.params)
        if command_name.equal("mtc.restartServer"):
            return false

    # Milk Tea custom extensions
    else if method == "milkTea/documentContext":
        doc_ctx.handle_document_context(ws, msg.params)
    else if method == "milkTea/debugInfo":
        debug_info.handle_debug_info(ws, msg.id)

    # Tier 3
    else if method == "textDocument/completion":
        var pos = extract_position_params(msg.params)
        completion.handle_completion(ws, pos.uri, pos.line, pos.character, msg.id)
    else if method == "completionItem/resolve":
        completion.handle_completion_resolve(ws, msg.params, msg.id)
    else if method == "textDocument/semanticTokens/full":
        let uri = extract_text_doc_uri(msg.params)
        semtok.handle_semantic_tokens(ws, uri, msg.id)
    else if method == "textDocument/semanticTokens/range":
        let uri = extract_text_doc_uri(msg.params)
        var range = extract_range_lines(msg.params)
        semtok.handle_semantic_tokens_range(ws, uri, range.start_line, range.end_line, msg.id)
    else if method == "textDocument/signatureHelp":
        var pos = extract_position_params(msg.params)
        sighelp.handle_signature_help(ws, pos.uri, pos.line, pos.character, msg.id)
    else if method == "textDocument/prepareRename":
        var pos = extract_position_params(msg.params)
        rename_mod.handle_prepare_rename(ws, pos.uri, pos.line, pos.character, msg.id)
    else if method == "textDocument/rename":
        var pos = extract_position_params(msg.params)
        let new_name_ptr = extract_new_name(msg.params)
        rename_mod.handle_rename(ws, pos.uri, pos.line, pos.character, new_name_ptr, msg.id)
    else if method == "textDocument/codeAction":
        let uri = extract_text_doc_uri(msg.params)
        code_actions.handle_code_actions(ws, uri, msg.params, msg.id)
    else if method == "textDocument/inlayHint":
        let uri = extract_text_doc_uri(msg.params)
        var range = extract_range_lines(msg.params)
        inlay.handle_inlay_hint(ws, uri, range.start_line, range.end_line, msg.id)
    else if method == "textDocument/onTypeFormatting":
        var pos = extract_position_params(msg.params)
        on_type.handle_on_type_formatting(ws, pos.uri, pos.line, extract_trigger_character(msg.params), msg.id)

    else:
        if not msg.id.is_null():
            proto.write_error(msg.id, -32601, "method not found")

    return true


## Extract the textDocument.uri from a generic params object.
function extract_text_doc_uri(params: json.Value) -> str:
    return proto.extract_text_doc_uri(params)


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


## Extract the newName field from a rename request params.
function extract_new_name(params: json.Value) -> str:
    let obj_ptr = params.as_object()
    if obj_ptr == null: return ""
    unsafe:
        let name_ptr = read(obj_ptr).get("newName")
        if name_ptr == null: return ""
        let name_str = read(name_ptr).as_string() else:
            return ""
        return name_str


## Extract the query string from workspace/symbol params.
function extract_query(params: json.Value) -> str:
    let obj_ptr = params.as_object()
    if obj_ptr == null: return ""
    unsafe:
        let query_ptr = read(obj_ptr).get("query")
        if query_ptr == null: return ""
        let query_str = read(query_ptr).as_string() else:
            return ""
        return query_str


## Extract selectionRange positions as a flat (line, character, ...) list.
function extract_selection_positions(params: json.Value) -> vec.Vec[ptr_uint]:
    var result = vec.Vec[ptr_uint].create()
    let obj_ptr = params.as_object()
    if obj_ptr == null:
        return result
    unsafe:
        let positions_ptr = read(obj_ptr).get("positions")
        if positions_ptr == null:
            return result
        let array_ptr = read(positions_ptr).as_array()
        if array_ptr == null:
            return result
        var i: ptr_uint = 0
        while i < read(array_ptr).len():
            let pos_ptr = read(array_ptr).get(i) else:
                break
            let pos_obj = read(pos_ptr).as_object()
            if pos_obj != null:
                result.push(number_field(pos_obj, "line"))
                result.push(number_field(pos_obj, "character"))
            i += 1
    return result


## Extract the start/end line pair from a range-carrying request params.
struct RangeLines:
    start_line: ptr_uint
    end_line: ptr_uint


function extract_range_lines(params: json.Value) -> RangeLines:
    var result = RangeLines(start_line = 0, end_line = 0)
    let obj_ptr = params.as_object()
    if obj_ptr == null:
        return result
    unsafe:
        let range_ptr = read(obj_ptr).get("range")
        if range_ptr == null:
            return result
        let range_obj = read(range_ptr).as_object()
        if range_obj == null:
            return result
        let start_ptr = read(range_obj).get("start")
        if start_ptr != null:
            let start_obj = read(start_ptr).as_object()
            if start_obj != null:
                result.start_line = number_field(start_obj, "line")
        let end_ptr = read(range_obj).get("end")
        if end_ptr != null:
            let end_obj = read(end_ptr).as_object()
            if end_obj != null:
                result.end_line = number_field(end_obj, "line")
    return result


## A non-negative numeric field of a JSON object, or 0 when absent.
function number_field(obj: ptr[json.Object], name: str) -> ptr_uint:
    unsafe:
        let field_ptr = read(obj).get(name)
        if field_ptr == null:
            return 0
        let value = read(field_ptr).as_number() else:
            return 0
        if value < 0.0:
            return 0
        return ptr_uint<-int<-value


## Extract the onTypeFormatting trigger character ("ch" field).
function extract_trigger_character(params: json.Value) -> str:
    let obj_ptr = params.as_object()
    if obj_ptr == null: return ""
    unsafe:
        let ch_ptr = read(obj_ptr).get("ch")
        if ch_ptr == null: return ""
        let ch_str = read(ch_ptr).as_string() else:
            return ""
        return ch_str


## Extract the "command" field from executeCommand params.
function extract_command_name(params: json.Value) -> str:
    let obj_ptr = params.as_object()
    if obj_ptr == null: return ""
    unsafe:
        let cmd_ptr = read(obj_ptr).get("command")
        if cmd_ptr == null: return ""
        let cmd_str = read(cmd_ptr).as_string() else:
            return ""
        return cmd_str

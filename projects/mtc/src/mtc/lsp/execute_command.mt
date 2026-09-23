## Execute command handler.  Currently supports the `mtc.restartServer`
## command that exits the server process so the client can restart it.

import std.json as json
import std.str

import mtc.lsp.protocol as proto


## Handle workspace/executeCommand.  Dispatches on the command name.
public function handle_execute_command(params: json.Value, id: json.Value) -> void:
    let command_name = extract_command(params)
    if command_name.equal("mtc.restartServer"):
        proto.write_response(id, json.null_value())
        # The caller (server.mt) must exit after this handler returns.
        return

    proto.write_error(id, -32601, "unknown command")


## Extract the "command" field from the executeCommand params.
function extract_command(params: json.Value) -> str:
    let obj_ptr = params.as_object()
    if obj_ptr == null:
        return ""
    unsafe:
        let cmd_ptr = read(obj_ptr).get("command")
        if cmd_ptr == null:
            return ""
        let cmd_str = read(cmd_ptr).as_string() else:
            return ""
        return cmd_str

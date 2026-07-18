## Lifecycle handlers — initialize, initialized, shutdown, exit.
##
## Response JSON is built via raw string formatting (protocol.mt's helpers)
## to avoid json.Object.set() copy semantics that would share heap Object
## pointers across Value copies.

import std.json as json
import std.string as string

import mtc.lsp.protocol as proto


## Pre-built result portion of the initialize response (after the id).
const INIT_RESULT: str = (
    ",\"result\":{\"capabilities\":{\"textDocumentSync\""
    ":{\"openClose\":true,\"change\":1,\"save\":true}}}}"
)


## Handle the `initialize` request.
public function handle_initialize(id: json.Value) -> void:
    var response_text = string.String.create()
    defer response_text.release()

    response_text.append("{\"jsonrpc\":\"2.0\"")
    response_text.append(",\"id\":")
    proto.append_json_value(ref_of(response_text), id)
    response_text.append(INIT_RESULT)

    proto.write_framed_json(response_text.as_str())


## Handle the `initialized` notification (no-op).
public function handle_initialized() -> void:
    pass

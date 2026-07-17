## Lifecycle handlers — initialize, initialized, shutdown, exit.

import std.json as json
import std.mem.arena as arena
import std.stdio as stdio
import std.str
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
    append_json_value(ref_of(response_text), id)
    response_text.append(INIT_RESULT)

    write_raw_response_frame(ref_of(response_text))


## Handle the `initialized` notification (no-op).
public function handle_initialized() -> void:
    pass


## Append a json.Value as its JSON representation.  Handles null, boolean,
## number, and string kinds.  Objects and arrays are rendered as {} / [].
function append_json_value(output: ref[string.String], value: json.Value) -> void:
    if value.is_null():
        output.append("null")
        return
    match value.as_boolean():
        Option.some as b:
            if b.value:
                output.append("true")
            else:
                output.append("false")
            return
        Option.none:
            pass
    match value.as_number():
        Option.some as n:
            output.append_format(f"#{n.value}")
            return
        Option.none:
            pass
    match value.as_string():
        Option.some as s:
            output.append("\"")
            append_escaped(output, s.value)
            output.append("\"")
            return
        Option.none:
            pass
    if value.as_object() != null:
        output.append("{}")
        return
    if value.as_array() != null:
        output.append("[]")
        return
    output.append("null")


## Append a str, escaping JSON-special characters.
function append_escaped(output: ref[string.String], text: str) -> void:
    var i: ptr_uint = 0
    while i < text.len:
        let b = text.byte_at(i)
        if b == 34:
            output.append("\\\"")
        else if b == 92:
            output.append("\\\\")
        else if b == 10:
            output.append("\\n")
        else if b == 13:
            output.append("\\r")
        else if b == 9:
            output.append("\\t")
        else:
            output.push_byte(b)
        i += 1


## Write a Content-Length-framed JSON body to stdout.  Duplicated from
## protocol.mt (which has the same function but isn't exported publicly)
## to avoid passing json.Value objects between modules.
function write_raw_response_frame(output: ref[string.String]) -> void:
    var text = output.as_str()
    var storage = arena.create(text.len + 64)
    defer storage.release()

    var header = string.String.create()
    defer header.release()
    header.append("Content-Length: ")
    header.append_format(f"#{text.len}")
    header.append("\r\n\r\n")

    stdio.print_format("%s%s", header.to_cstr(ref_of(storage)), storage.to_cstr(text))
    stdio.file_flush(null)

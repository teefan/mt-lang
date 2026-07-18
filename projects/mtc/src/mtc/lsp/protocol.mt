## JSON-RPC 2.0 transport over stdio with Content-Length framing.
##
## Reads LSP messages from stdin one character at a time via stdio.read_char()
## (libc-buffered getchar).  Parses JSON bodies with std.json.  Writes framed
## responses via stdio.print_format("%s", cstr) + stdio.file_flush(null).
##
## Response rendering (write_response, write_error, write_notification) uses
## raw string formatting rather than std.json Object construction.  This is
## deliberate: json.Object.set() copies json.Value structs by value, so both
## the caller's copy and the entry's copy share the same heap Object pointer.
## Cascaded release_value across the tree then double-frees.  Raw strings
## avoid the sharing entirely by serialising directly.

import std.fmt
import std.json as json
import std.stdio as stdio
import std.str
import std.string as string
import std.mem.arena as arena

const CR: ubyte = 13
const LF: ubyte = 10


public struct Message:
    jsonrpc: string.String
    id: json.Value
    method: string.String
    params: json.Value
    raw_body: string.String
    parsed_root: json.Value


## Read one header line (terminated by \r\n) from stdin.  Returns false on
## EOF before any byte was seen.
function read_header_line(line: ref[string.String]) -> bool:
    line.clear()
    var got_any = false
    while true:
        let raw = stdio.read_char()
        if raw < 0:
            return got_any
        got_any = true
        let ch = ubyte<-raw
        if ch == CR:
            let next_raw = stdio.read_char()
            if next_raw == LF or next_raw < 0:
                return true
            line.push_byte(ch)
            if next_raw >= 0:
                line.push_byte(ubyte<-next_raw)
        else:
            line.push_byte(ch)


## Parse Content-Length from a header line like "Content-Length: 1234".
## Returns none when the line is not a Content-Length header.
function parse_content_length(line: str) -> Option[ptr_uint]:
    let prefix = "Content-Length:"
    if line.len <= prefix.len or not line.starts_with(prefix):
        return Option[ptr_uint].none

    var value: ptr_uint = 0
    var index = prefix.len
    while index < line.len:
        let b = line.byte_at(index)
        if b > 47 and b < 58:
            value = value * 10 + ptr_uint<-(b - 48)
        else if b != 32:
            return Option[ptr_uint].none
        index += 1

    return Option[ptr_uint].some(value = value)


## Read exactly `count` body bytes from stdin into `body`.  Returns false on
## premature EOF.
function read_body_bytes(body: ref[string.String], count: ptr_uint) -> bool:
    body.clear()
    var remaining = count
    while remaining > 0:
        let raw = stdio.read_char()
        if raw < 0:
            return false
        body.push_byte(ubyte<-raw)
        remaining -= 1
    return true


## Read one JSON-RPC message from stdin.  Returns none on EOF / protocol error.
public function read_message() -> Option[Message]:
    var header_line = string.String.create()
    defer header_line.release()
    var body = string.String.create()
    defer body.release()

    # Read Content-Length header.
    var content_length: ptr_uint = 0
    var found_length = false
    while true:
        if not read_header_line(ref_of(header_line)):
            return Option[Message].none

        let length = parse_content_length(header_line.as_str())
        match length:
            Option.some as len_payload:
                content_length = len_payload.value
                found_length = true
            Option.none:
                pass

        # Header separator: empty line (\r\n only).
        if header_line.len() == 0:
            break

    if not found_length or content_length == 0:
        return Option[Message].none

    if not read_body_bytes(ref_of(body), content_length):
        return Option[Message].none

    let body_text = body.as_str()
    if body_text.len == 0:
        return Option[Message].none

    # Parse JSON body.
    var parsed = json.parse(body_text) else as error:
        var owned_error = error
        owned_error.release()
        return Option[Message].none

    let parsed_obj = parsed.as_object() else:
        json.release_value(parsed)
        return Option[Message].none

    # Owned copy of the raw body text so the Message keeps its own storage.
    var raw_body_owned = string.String.from_str(body_text)

    # Extract method, params, id from the parsed object into owned copies
    # so we can release the JSON tree without dangling str borrows.
    var owned_method = string.String.create()
    var owned_jsonrpc = string.String.create()
    var id_val = json.null_value()
    var params_val = json.null_value()

    unsafe:
        let method_opt = read(parsed_obj).get_string("method")
        match method_opt:
            Option.some as m:
                owned_method.assign(m.value)
            Option.none:
                pass

        let rpc_opt = read(parsed_obj).get_string("jsonrpc")
        match rpc_opt:
            Option.some as r:
                owned_jsonrpc.assign(r.value)
            Option.none:
                pass

        let id_opt = read(parsed_obj).get("id")
        if id_opt != null:
            id_val = read(id_opt)

        let params_opt = read(parsed_obj).get("params")
        if params_opt != null:
            params_val = read(params_opt)

    if owned_method.len() == 0:
        raw_body_owned.release()
        owned_method.release()
        owned_jsonrpc.release()
        json.release_value(parsed)
        return Option[Message].none

    return Option[Message].some(value = Message(
        jsonrpc = owned_jsonrpc,
        id = id_val,
        method = owned_method,
        params = params_val,
        raw_body = raw_body_owned,
        parsed_root = parsed
    ))


## Write a framed JSON-RPC body to stdout.  Flushes after write so the
## editor sees the response immediately.
public function write_framed_json(json_text: str) -> void:
    var storage = arena.create(json_text.len + 64)
    defer storage.release()

    var header = string.String.create()
    defer header.release()
    header.append("Content-Length: ")
    header.append_format(f"#{json_text.len}")
    header.append("\r\n\r\n")

    stdio.print_format("%s%s", header.to_cstr(ref_of(storage)), storage.to_cstr(json_text))
    stdio.file_flush(null)


## Write a successful JSON-RPC response where the result is a pre-built
## JSON string (avoids serialization through append_json_value, which does
## not recursively render object/array contents).
public function write_response_raw(id: json.Value, result_json: str) -> void:
    var response_text = string.String.create()
    defer response_text.release()
    response_text.append("{\"jsonrpc\":\"2.0\",\"id\":")
    append_json_value(ref_of(response_text), id)
    response_text.append(",\"result\":")
    response_text.append(result_json)
    response_text.append("}")
    write_framed_json(response_text.as_str())


## Write a successful JSON-RPC response with the given id and result.
public function write_response(id: json.Value, result: json.Value) -> void:
    var response_text = string.String.create()
    defer response_text.release()

    response_text.append("{\"jsonrpc\":\"2.0\",\"id\":")
    append_json_value(ref_of(response_text), id)
    response_text.append(",\"result\":")
    append_json_value(ref_of(response_text), result)
    response_text.append("}")

    write_framed_json(response_text.as_str())


## Write a JSON-RPC error response.
public function write_error(id: json.Value, code: int, message: str) -> void:
    var response_text = string.String.create()
    defer response_text.release()

    response_text.append("{\"jsonrpc\":\"2.0\",\"id\":")
    append_json_value(ref_of(response_text), id)
    response_text.append(",\"error\":{\"code\":")
    response_text.append_format(f"#{code}")
    response_text.append(",\"message\":\"")
    append_escaped(ref_of(response_text), message)
    response_text.append("\"}}")

    write_framed_json(response_text.as_str())


## Write a JSON-RPC notification (no id field).
public function write_notification(method: str, params: json.Value) -> void:
    var response_text = string.String.create()
    defer response_text.release()

    response_text.append("{\"jsonrpc\":\"2.0\",\"method\":\"")
    append_escaped(ref_of(response_text), method)
    response_text.append("\",\"params\":")
    append_json_value(ref_of(response_text), params)
    response_text.append("}")

    write_framed_json(response_text.as_str())


## Append a json.Value as its JSON representation.
public function append_json_value(output: ref[string.String], value: json.Value) -> void:
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
    var arr_ptr = value.as_array()
    if arr_ptr != null:
        output.append("[")
        var first = true
        var ai: ptr_uint = 0
        unsafe:
            while ai < read(arr_ptr).len():
                let elem_ptr = read(arr_ptr).get(ai)
                if elem_ptr == null: break
                if not first: output.append(",")
                first = false
                append_json_value(output, read(elem_ptr))
                ai += 1
        output.append("]")
        return
    output.append("null")


## Append a str, escaping JSON-special characters.
public function append_escaped(output: ref[string.String], text: str) -> void:
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


## Extract the textDocument.uri from a notification/request params object.
## Shared by text_docs, formatting, server, and diagnostics modules.
public function extract_text_doc_uri(params: json.Value) -> str:
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


extending Message:
    public editable function release() -> void:
        this.jsonrpc.release()
        this.method.release()
        this.raw_body.release()
        json.release_value(this.parsed_root)

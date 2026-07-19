## DAP protocol transport — Content-Length framed JSON-RPC-like messages over
## stdio.  Reads DAP messages from stdin one character at a time, parses JSON
## bodies with std.json, and writes framed responses.  Uses the same framing
## and parsing patterns as mtc.lsp.protocol.

import std.fmt
import std.json as json
import std.stdio as stdio
import std.str
import std.string as string
import std.mem.arena as arena

const CR: ubyte = 13
const LF: ubyte = 10


public struct Message:
    raw_body: string.String
    seq: ptr_uint
    msg_type: string.String
    command: string.String
    arguments: json.Value
    body: json.Value
    request_seq: ptr_uint
    success: bool
    message: string.String
    evt: string.String


## Read one header line (terminated by \r\n) from stdin.
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


## Parse Content-Length from a header line.  Returns none on no match.
function parse_content_length(line: str) -> Option[ptr_uint]:
    let prefix = "Content-Length:"
    if line.len <= prefix.len or not line.starts_with(prefix):
        return Option[ptr_uint].none
    var value: ptr_uint = 0
    var index = prefix.len
    while index < line.len:
        let b = line.byte_at(index)
        if b >= '0' and b <= '9':
            value = value * 10 + ptr_uint<-(b - '0')
        else if b != ' ':
            return Option[ptr_uint].none
        index += 1
    return Option[ptr_uint].some(value = value)


## Read exactly `count` bytes from stdin into `body`.
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


## Read one DAP message from stdin.  Returns none on EOF / protocol error.
public function read_message() -> Option[Message]:
    var header_line = string.String.create()
    defer header_line.release()
    var body = string.String.create()
    defer body.release()

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
        if header_line.len() == 0:
            break

    if not found_length or content_length == 0:
        return Option[Message].none
    if not read_body_bytes(ref_of(body), content_length):
        return Option[Message].none

    let body_text = body.as_str()
    if body_text.len == 0:
        return Option[Message].none

    var parsed = json.parse(body_text) else as error:
        var owned_error = error
        owned_error.release()
        return Option[Message].none

    let parsed_obj = parsed.as_object() else:
        json.release_value(parsed)
        return Option[Message].none

    var raw_body_owned = string.String.from_str(body_text)
    var msg = build_message(parsed_obj, raw_body_owned)
    json.release_value(parsed)
    return Option[Message].some(value = msg)


function build_message(obj: ptr[json.Object], raw_body: string.String) -> Message:
    var owned_type = string.String.create()
    var owned_command = string.String.create()
    var owned_evt = string.String.create()
    var owned_message = string.String.create()
    var seq: ptr_uint = 0
    var request_seq: ptr_uint = 0
    var success = true
    var arguments = json.null_value()
    var body_val = json.null_value()

    unsafe:
        let type_opt = read(obj).get_string("type")
        match type_opt:
            Option.some as t:
                owned_type.assign(t.value)
            Option.none:
                pass

        let seq_opt = read(obj).get("seq")
        if seq_opt != null:
            match read(seq_opt).as_number():
                Option.some as n:
                    seq = ptr_uint<-int<-n.value
                Option.none:
                    pass

        let cmd_opt = read(obj).get_string("command")
        match cmd_opt:
            Option.some as c:
                owned_command.assign(c.value)
            Option.none:
                pass

        let evt_opt = read(obj).get_string("event")
        match evt_opt:
            Option.some as e:
                owned_evt.assign(e.value)
            Option.none:
                pass

        let succ_opt = read(obj).get("success")
        if succ_opt != null:
            match read(succ_opt).as_boolean():
                Option.some as b:
                    success = b.value
                Option.none:
                    pass

        let req_seq_opt = read(obj).get("request_seq")
        if req_seq_opt != null:
            match read(req_seq_opt).as_number():
                Option.some as n:
                    request_seq = ptr_uint<-int<-n.value
                Option.none:
                    pass

        let msg_opt = read(obj).get_string("message")
        match msg_opt:
            Option.some as m:
                owned_message.assign(m.value)
            Option.none:
                pass

        let args_opt = read(obj).get("arguments")
        if args_opt != null:
            arguments = read(args_opt)

        let body_opt = read(obj).get("body")
        if body_opt != null:
            body_val = read(body_opt)

    return Message(
        raw_body = raw_body,
        seq = seq,
        msg_type = owned_type,
        command = owned_command,
        arguments = arguments,
        body = body_val,
        request_seq = request_seq,
        success = success,
        message = owned_message,
        evt = owned_evt,
    )


## Write a framed DAP message to stdout.  Flushes after write.
public function write_framed_json(json_text: str) -> void:
    var storage = arena.create(json_text.len + 64)
    defer storage.release()
    var header = string.String.create()
    header.append("Content-Length: ")
    header.append_format(f"#{json_text.len}")
    header.append("\r\n\r\n")
    stdio.print_format("%s%s", header.to_cstr(ref_of(storage)), storage.to_cstr(json_text))
    stdio.file_flush(null)
    header.release()


## JSON-escape and append a string value.
public function append_escaped(output: ref[string.String], text: str) -> void:
    var i: ptr_uint = 0
    while i < text.len:
        let b = text.byte_at(i)
        if b == '"':
            output.append("\\\"")
        else if b == '\\':
            output.append("\\\\")
        else if b == '\n':
            output.append("\\n")
        else if b == '\r':
            output.append("\\r")
        else if b == '\t':
            output.append("\\t")
        else:
            output.push_byte(b)
        i += 1

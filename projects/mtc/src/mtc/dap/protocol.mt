## DAP protocol transport — Content-Length framed JSON-RPC-like messages over
## raw file descriptors.  A `Framer` buffers bytes read from one descriptor and
## extracts complete messages; `mtc dap`'s libuv loop fills it from poll
## callbacks and drains it between loop turns.  The writer targets stdout.

import std.fmt
import std.json as json
import std.process as process
import std.stdio as stdio
import std.str
import std.string as string
import std.mem.arena as arena

const CR: ubyte = 13
const LF: ubyte = 10

public struct Message:
    raw_body: string.String
    parsed: json.Value
    seq: ptr_uint
    msg_type: string.String
    command: string.String
    arguments: json.Value
    body: json.Value
    request_seq: ptr_uint
    success: bool
    message: string.String
    evt: string.String

## A byte-buffered framer over one file descriptor.  `framer_fill` reads what
## the descriptor has now (never blocks); `framer_next` extracts the next
## complete message.  `eof` marks a closed descriptor, `malformed` a frame
## without a usable Content-Length or body.
public struct Framer:
    fd: int
    buffer: string.String
    start: ptr_uint
    eof: bool
    malformed: bool


public function framer_create(fd: int) -> Framer:
    return Framer(
        fd = fd,
        buffer = string.String.create(),
        start = 0,
        eof = false,
        malformed = false,
    )


public function framer_release(framer: ref[Framer]) -> void:
    framer.buffer.release()


## Read once from the descriptor into the buffer.  Returns true when bytes were
## appended; EOF or a read failure marks the framer (already-buffered frames
## are still parsed).
public function framer_fill(framer: ref[Framer]) -> bool:
    match process.read_fd(framer.fd, 0):
        Result.success as payload:
            var data = payload.value
            if data.has_data():
                framer.buffer.append(data.data.as_str())
                data.release()
                return true
            let closed = data.closed
            data.release()
            if closed:
                framer.eof = true
            return false
        Result.failure as failure:
            var error = failure.error
            error.release()
            framer.eof = true
            framer.malformed = true
            return false


## Extract the next complete message, or none when more bytes are needed.
public function framer_next(framer: ref[Framer]) -> Option[Message]:
    let buffered = framer.buffer.as_str()
    if framer.start >= buffered.len:
        return Option[Message].none

    let header_end = find_header_end(buffered, framer.start) else:
        return Option[Message].none

    let header_text = buffered.slice(framer.start, header_end - framer.start)
    let headers = parse_headers(header_text)
    if not headers.found or headers.length == 0:
        framer.malformed = true
        return Option[Message].none

    let body_start = header_end + 4
    if buffered.len < body_start + headers.length:
        return Option[Message].none

    let body_text = buffered.slice(body_start, headers.length)
    # Parse before compacting: `body_text` is a view into the buffer, and
    # `compact` releases the old storage.
    let message = message_from_body(body_text)
    framer.start = body_start + headers.length
    compact(framer)
    return message


## Parse Content-Length out of a header block.
struct HeaderParse:
    length: ptr_uint
    found: bool


function parse_headers(header_text: str) -> HeaderParse:
    var length: ptr_uint = 0
    var found = false
    var line_start: ptr_uint = 0
    while line_start < header_text.len:
        var line_end = line_start
        while line_end < header_text.len and header_text.byte_at(line_end) != CR:
            line_end += 1
        let line = header_text.slice(line_start, line_end - line_start)
        match parse_content_length(line):
            Option.some as value:
                length = value.value
                found = true
            Option.none:
                pass
        line_start = line_end
        if line_start < header_text.len and header_text.byte_at(line_start) == CR:
            line_start += 1
        if line_start < header_text.len and header_text.byte_at(line_start) == LF:
            line_start += 1
    return HeaderParse(length = length, found = found)


## Index of the `\r\n\r\n` that ends the header block, searched from `start`.
function find_header_end(text: str, start: ptr_uint) -> Option[ptr_uint]:
    var i = start
    while i + 3 < text.len:
        if (
            text.byte_at(i) == CR
            and text.byte_at(i + 1) == LF
            and text.byte_at(i + 2) == CR
            and text.byte_at(i + 3) == LF
        ):
            return Option[ptr_uint].some(value = i)
        i += 1
    return Option[ptr_uint].none


## Drop the consumed prefix once it dominates the buffer.
function compact(framer: ref[Framer]) -> void:
    if framer.start == 0:
        return
    if framer.start < framer.buffer.len() and framer.start < 4096:
        return
    let remaining = framer.buffer.as_str().slice(framer.start, framer.buffer.len() - framer.start)
    var copy = string.String.from_str(remaining)
    framer.buffer.release()
    framer.buffer = copy
    framer.start = 0


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


## Parse one JSON body into a Message (ownership: `build_message` takes the
## parsed tree and the raw body).
function message_from_body(body_text: str) -> Option[Message]:
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
    var msg = build_message(parsed_obj, raw_body_owned, parsed)
    return Option[Message].some(value = msg)


function build_message(obj: ptr[json.Object], raw_body: string.String, parsed: json.Value) -> Message:
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
    defer: storage.release()
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


## Release a Message and all owned fields, including the parsed JSON tree.
public function release_message(msg: ref[Message]) -> void:
    json.release_value(msg.parsed)
    msg.raw_body.release()
    msg.msg_type.release()
    msg.command.release()
    msg.message.release()
    msg.evt.release()

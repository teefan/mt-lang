import std.bytes as bytes
import std.fmt as fmt
import std.maybe as maybe
import std.mem.heap as heap
import std.net as net
import std.status as status
import std.str as text
import std.string as string
import std.vec as vec


public struct Error:
    message: string.String


public struct Header:
    name: string.String
    value: string.String


public struct Response:
    status_code: int
    reason: string.String
    headers: vec.Vec[Header]
    body: bytes.Bytes


struct ParsedUrl:
    host: string.String
    authority: string.String
    target: string.String
    port: int


struct ResponseHead:
    status_code: int
    reason: string.String
    headers: vec.Vec[Header]
    content_length: maybe.Maybe[ptr_uint]


function error_from_message(message: str) -> Error:
    return Error(message = string.String.from_str(message))


function error_from_net(net_error: net.Error) -> Error:
    return Error(message = net_error.message)


function status_error[T](message: str) -> status.Status[T, Error]:
    return status.Status[T, Error].err(error = error_from_message(message))


function status_net_error[T](net_error: net.Error) -> status.Status[T, Error]:
    return status.Status[T, Error].err(error = error_from_net(net_error))


function url_error[T](detail: str) -> status.Status[T, Error]:
    return status_error[T](f"invalid http url: #{detail}")


function response_error[T](detail: str) -> status.Status[T, Error]:
    return status_error[T](f"invalid http response: #{detail}")


function ascii_fold(value: ubyte) -> ubyte:
    if value >= ubyte<-65 and value <= ubyte<-90:
        return value + ubyte<-32

    return value


function ascii_case_equal(left: str, right: str) -> bool:
    if left.len != right.len:
        return false

    var index: ptr_uint = 0
    while index < left.len:
        if ascii_fold(left.byte_at(index)) != ascii_fold(right.byte_at(index)):
            return false
        index += 1

    return true


function find_byte_from(text_value: str, value: ubyte, start: ptr_uint) -> maybe.Maybe[ptr_uint]:
    var index = start
    while index < text_value.len:
        if text_value.byte_at(index) == value:
            return maybe.Maybe[ptr_uint].some(value = index)
        index += 1

    return maybe.Maybe[ptr_uint].none


function count_byte(text_value: str, value: ubyte) -> ptr_uint:
    var count: ptr_uint = 0
    var index: ptr_uint = 0
    while index < text_value.len:
        if text_value.byte_at(index) == value:
            count += 1
        index += 1

    return count


function parse_decimal(text_value: str) -> maybe.Maybe[ptr_uint]:
    if text_value.len == 0:
        return maybe.Maybe[ptr_uint].none

    var value: ptr_uint = 0
    var index: ptr_uint = 0
    while index < text_value.len:
        let current = text_value.byte_at(index)
        if current < ubyte<-48 or current > ubyte<-57:
            return maybe.Maybe[ptr_uint].none

        let digit = ptr_uint<-(current - ubyte<-48)
        if value > (heap.ptr_uint_max() - digit) / ptr_uint<-10:
            return maybe.Maybe[ptr_uint].none

        value = value * ptr_uint<-10 + digit
        index += 1

    return maybe.Maybe[ptr_uint].some(value = value)


function parse_port(text_value: str) -> maybe.Maybe[int]:
    match parse_decimal(text_value):
        maybe.Maybe.none:
            return maybe.Maybe[int].none
        maybe.Maybe.some as payload:
            if payload.value > ptr_uint<-65535:
                return maybe.Maybe[int].none

            return maybe.Maybe[int].some(value = int<-payload.value)


function parse_target(rest: str) -> status.Status[string.String, Error]:
    if rest.len == 0:
        return status.Status[string.String, Error].ok(value = string.String.from_str("/"))

    let fragment_index = find_byte_from(rest, ubyte<-35, 0)
    var target_text = rest
    match fragment_index:
        maybe.Maybe.none:
            pass
        maybe.Maybe.some as payload:
            target_text = rest.slice(0, payload.value)

    if target_text.len == 0:
        return status.Status[string.String, Error].ok(value = string.String.from_str("/"))

    let first = target_text.byte_at(0)
    if first == ubyte<-47:
        return status.Status[string.String, Error].ok(value = string.String.from_str(target_text))

    if first == ubyte<-63:
        var target = string.String.from_str("/")
        target.append(target_text)
        return status.Status[string.String, Error].ok(value = target)

    return url_error[string.String]("path must start with '/' or '?'")


function parse_url(url: str) -> status.Status[ParsedUrl, Error]:
    if url.starts_with("https://"):
        return url_error[ParsedUrl]("https is not supported yet")

    if not url.starts_with("http://"):
        return url_error[ParsedUrl]("URL must start with http://")

    let remainder = url.slice(7, url.len - 7)
    if remainder.len == 0:
        return url_error[ParsedUrl]("missing authority")

    var authority_end = remainder.len
    var index: ptr_uint = 0
    while index < remainder.len:
        let current = remainder.byte_at(index)
        if current == ubyte<-47 or current == ubyte<-63 or current == ubyte<-35:
            authority_end = index
            break
        index += 1

    let authority_text = remainder.slice(0, authority_end)
    if authority_text.len == 0:
        return url_error[ParsedUrl]("missing authority")

    if count_byte(authority_text, ubyte<-64) != 0:
        return url_error[ParsedUrl]("userinfo is not supported")

    var host_text = authority_text
    var port = 80
    if authority_text.byte_at(0) == ubyte<-91:
        var closing_bracket: ptr_uint = 0
        match find_byte_from(authority_text, ubyte<-93, 1):
            maybe.Maybe.none:
                return url_error[ParsedUrl]("missing closing ']' for IPv6 host")
            maybe.Maybe.some as payload:
                closing_bracket = payload.value

        if closing_bracket == 1:
            return url_error[ParsedUrl]("host is empty")

        host_text = authority_text.slice(1, closing_bracket - 1)
        if closing_bracket + 1 < authority_text.len:
            if authority_text.byte_at(closing_bracket + 1) != ubyte<-58:
                return url_error[ParsedUrl]("unexpected text after IPv6 host")

            let port_start = closing_bracket + 2
            let port_text = authority_text.slice(port_start, authority_text.len - port_start)
            match parse_port(port_text):
                maybe.Maybe.none:
                    return url_error[ParsedUrl]("invalid port")
                maybe.Maybe.some as payload:
                    port = payload.value
    else:
        let colon_count = count_byte(authority_text, ubyte<-58)
        if colon_count > 1:
            return url_error[ParsedUrl]("IPv6 hosts must be wrapped in []")

        if colon_count == 1:
            var colon_index: ptr_uint = 0
            match authority_text.find_byte(ubyte<-58):
                maybe.Maybe.none:
                    fatal(c"http.parse_url missing authority port separator")
                maybe.Maybe.some as payload:
                    colon_index = payload.value

            if colon_index == 0:
                return url_error[ParsedUrl]("host is empty")

            host_text = authority_text.slice(0, colon_index)
            let port_start = colon_index + 1
            let port_text = authority_text.slice(port_start, authority_text.len - port_start)
            match parse_port(port_text):
                maybe.Maybe.none:
                    return url_error[ParsedUrl]("invalid port")
                maybe.Maybe.some as payload:
                    port = payload.value

    if host_text.len == 0:
        return url_error[ParsedUrl]("host is empty")

    let rest = remainder.slice(authority_end, remainder.len - authority_end)
    let target_result = parse_target(rest)
    match target_result:
        status.Status.err as payload:
            return status.Status[ParsedUrl, Error].err(error = payload.error)
        status.Status.ok as payload:
            let target = payload.value
            return status.Status[ParsedUrl, Error].ok(
                value = ParsedUrl(
                    host = string.String.from_str(host_text),
                    authority = string.String.from_str(authority_text),
                    target = target,
                    port = port,
                )
            )


function build_get_request(url: ParsedUrl) -> string.String:
    var request = string.String.with_capacity(url.target.len + url.authority.len + 80)
    request.append("GET ")
    request.append(url.target.as_str())
    request.append(" HTTP/1.1\r\nHost: ")
    request.append(url.authority.as_str())
    request.append("\r\nConnection: close\r\nUser-Agent: milk-tea/std.http\r\n\r\n")
    return request


function find_crlf(text_value: str, start: ptr_uint) -> maybe.Maybe[ptr_uint]:
    if text_value.len < 2 or start + 1 >= text_value.len:
        return maybe.Maybe[ptr_uint].none

    var index = start
    while index + 1 < text_value.len:
        if text_value.byte_at(index) == ubyte<-13 and text_value.byte_at(index + 1) == ubyte<-10:
            return maybe.Maybe[ptr_uint].some(value = index)
        index += 1

    return maybe.Maybe[ptr_uint].none


function find_header_terminator(data: span[ubyte]) -> maybe.Maybe[ptr_uint]:
    if data.len < 4:
        return maybe.Maybe[ptr_uint].none

    var index: ptr_uint = 0
    while index + 3 < data.len:
        if unsafe: read(data.data + index) == ubyte<-13 and read(data.data + index + 1) == ubyte<-10 and read(data.data + index + 2) == ubyte<-13 and read(data.data + index + 3) == ubyte<-10:
            return maybe.Maybe[ptr_uint].some(value = index)
        index += 1

    return maybe.Maybe[ptr_uint].none


function parse_response_head(header_text: str) -> status.Status[ResponseHead, Error]:
    var line_end = header_text.len
    var header_index = header_text.len
    match find_crlf(header_text, 0):
        maybe.Maybe.none:
            pass
        maybe.Maybe.some as payload:
            line_end = payload.value
            header_index = line_end + 2

    let status_line = header_text.slice(0, line_end)
    if not status_line.starts_with("HTTP/1."):
        return response_error[ResponseHead]("unsupported HTTP version")

    var first_space: ptr_uint = 0
    match status_line.find_byte(ubyte<-32):
        maybe.Maybe.none:
            return response_error[ResponseHead]("missing status code")
        maybe.Maybe.some as payload:
            first_space = payload.value

    if first_space + 4 > status_line.len:
        return response_error[ResponseHead]("missing status code")

    let status_code_text = status_line.slice(first_space + 1, 3)
    var status_code = 0
    match parse_decimal(status_code_text):
        maybe.Maybe.none:
            return response_error[ResponseHead]("invalid status code")
        maybe.Maybe.some as payload:
            status_code = int<-payload.value

    var reason = string.String.create()
    if first_space + 4 < status_line.len:
        if status_line.byte_at(first_space + 4) != ubyte<-32:
            return response_error[ResponseHead]("status line must separate code and reason with a space")

        let reason_start = first_space + 5
        reason = string.String.from_str(status_line.slice(reason_start, status_line.len - reason_start))

    var head = ResponseHead(
        status_code = status_code,
        reason = reason,
        headers = vec.Vec[Header].create(),
        content_length = maybe.Maybe[ptr_uint].none,
    )

    var index = header_index
    while index < header_text.len:
        var next_line_end = header_text.len
        match find_crlf(header_text, index):
            maybe.Maybe.none:
                pass
            maybe.Maybe.some as payload:
                next_line_end = payload.value

        let line = header_text.slice(index, next_line_end - index)
        if line.len == 0:
            head.release()
            return response_error[ResponseHead]("unexpected blank header line")

        var separator: ptr_uint = 0
        match line.find_byte(ubyte<-58):
            maybe.Maybe.none:
                head.release()
                return response_error[ResponseHead]("header line is missing ':'")
            maybe.Maybe.some as payload:
                separator = payload.value

        if separator == 0:
            head.release()
            return response_error[ResponseHead]("header name is empty")

        let name_text = line.slice(0, separator)
        let value_start = separator + 1
        let value_text = line.slice(value_start, line.len - value_start).trim_ascii_whitespace()

        head.headers.push(Header(name = string.String.from_str(name_text), value = string.String.from_str(value_text)))

        if ascii_case_equal(name_text, "Content-Length"):
            match parse_decimal(value_text):
                maybe.Maybe.none:
                    head.release()
                    return response_error[ResponseHead]("Content-Length must be a decimal integer")
                maybe.Maybe.some as payload:
                    head.content_length = maybe.Maybe[ptr_uint].some(value = payload.value)

        if ascii_case_equal(name_text, "Transfer-Encoding") and ascii_case_equal(value_text, "chunked"):
            head.release()
            return response_error[ResponseHead]("chunked transfer encoding is not supported yet")

        if next_line_end == header_text.len:
            index = header_text.len
        else:
            index = next_line_end + 2

    return status.Status[ResponseHead, Error].ok(value = head)


async function read_body(stream: net.TcpStream, prefix: span[ubyte], content_length: maybe.Maybe[ptr_uint]) -> status.Status[bytes.Bytes, Error]:
    match content_length:
        maybe.Maybe.some as payload:
            let total_length = payload.value
            if prefix.len > total_length:
                return response_error[bytes.Bytes]("body exceeded Content-Length")

            var body = vec.Vec[ubyte].with_capacity(total_length)
            defer body.release()

            body.append_span(prefix)

            let remaining = total_length - prefix.len
            if remaining > 0:
                let chunk_result = await stream.read_exactly(remaining)
                match chunk_result:
                    status.Status.err as error_payload:
                        return status_net_error[bytes.Bytes](error_payload.error)
                    status.Status.ok as ok_payload:
                        var chunk = ok_payload.value
                        body.append_span(chunk.as_span())
                        chunk.release()

            return status.Status[bytes.Bytes, Error].ok(value = bytes.Bytes.copy(body.as_span()))
        maybe.Maybe.none:
            var body = vec.Vec[ubyte].with_capacity(prefix.len)
            defer body.release()

            body.append_span(prefix)

            while true:
                let chunk_result = await stream.read_once(4096)
                match chunk_result:
                    status.Status.err as error_payload:
                        return status_net_error[bytes.Bytes](error_payload.error)
                    status.Status.ok as ok_payload:
                        var chunk = ok_payload.value
                        if chunk.len == 0:
                            chunk.release()
                            break

                        body.append_span(chunk.as_span())
                        chunk.release()

            return status.Status[bytes.Bytes, Error].ok(value = bytes.Bytes.copy(body.as_span()))


async function read_response(stream: net.TcpStream) -> status.Status[Response, Error]:
    var received = vec.Vec[ubyte].create()
    defer received.release()

    var header_length: ptr_uint = 0
    var headers_ready = false
    while not headers_ready:
        let chunk_result = await stream.read_once(4096)
        match chunk_result:
            status.Status.err as error_payload:
                return status_net_error[Response](error_payload.error)
            status.Status.ok as ok_payload:
                var chunk = ok_payload.value
                if chunk.len == 0:
                    chunk.release()
                    return response_error[Response]("response ended before headers were complete")

                received.append_span(chunk.as_span())
                chunk.release()

                match find_header_terminator(received.as_span()):
                    maybe.Maybe.none:
                        continue
                    maybe.Maybe.some as payload:
                        header_length = payload.value
                        headers_ready = true

    let raw = received.as_span()
    let header_bytes = unsafe: span[ubyte](data = raw.data, len = header_length)
    var header_text = ""
    match text.utf8_byte_span_as_str(header_bytes):
        maybe.Maybe.none:
            return response_error[Response]("headers are not valid UTF-8")
        maybe.Maybe.some as payload:
            header_text = payload.value

    let head_result = parse_response_head(header_text)
    match head_result:
        status.Status.err as payload:
            return status.Status[Response, Error].err(error = payload.error)
        status.Status.ok as payload:
            var head = payload.value
            let body_start = header_length + 4
            let body_prefix = unsafe: span[ubyte](data = raw.data + body_start, len = raw.len - body_start)

            let body_result = await read_body(stream, body_prefix, head.content_length)
            match body_result:
                status.Status.err as body_error_payload:
                    head.release()
                    return status.Status[Response, Error].err(error = body_error_payload.error)
                status.Status.ok as body_payload:
                    let body = body_payload.value
                    return status.Status[Response, Error].ok(
                        value = Response(
                            status_code = head.status_code,
                            reason = head.reason,
                            headers = head.headers,
                            body = body,
                        )
                    )


methods Error:
    public editable function release() -> void:
        this.message.release()
        return


methods Header:
    public editable function release() -> void:
        this.name.release()
        this.value.release()
        return


methods Response:
    public editable function release() -> void:
        this.reason.release()

        var index: ptr_uint = 0
        while index < this.headers.len:
            let current = this.headers.get(index) else:
                fatal(c"http.Response.release missing header")

            var header = unsafe: read(current)
            header.release()
            index += 1

        this.headers.release()
        this.body.release()
        return


    public function header(name: str) -> maybe.Maybe[str]:
        var index: ptr_uint = 0
        while index < this.headers.len:
            let current = this.headers.get(index) else:
                fatal(c"http.Response.header missing header")

            let header_value = unsafe: read(current)
            if ascii_case_equal(header_value.name.as_str(), name):
                return maybe.Maybe[str].some(value = header_value.value.as_str())

            index += 1

        return maybe.Maybe[str].none


methods ParsedUrl:
    editable function release() -> void:
        this.host.release()
        this.authority.release()
        this.target.release()
        return


methods ResponseHead:
    editable function release() -> void:
        this.reason.release()

        var index: ptr_uint = 0
        while index < this.headers.len:
            let current = this.headers.get(index) else:
                fatal(c"http.ResponseHead.release missing header")

            var header = unsafe: read(current)
            header.release()
            index += 1

        this.headers.release()
        return


public async function get(url: str) -> status.Status[Response, Error]:
    let parsed_result = parse_url(url)
    match parsed_result:
        status.Status.err as payload:
            return status.Status[Response, Error].err(error = payload.error)
        status.Status.ok as payload:
            var parsed = payload.value
            defer parsed.release()

            var service = fmt.to_string_int(parsed.port)
            defer service.release()

            let address_result = await net.resolve_first(parsed.host.as_str(), service.as_str())
            match address_result:
                status.Status.err as address_error_payload:
                    return status_net_error[Response](address_error_payload.error)
                status.Status.ok as address_payload:
                    var address = address_payload.value
                    defer address.release()

                    let connect_result = await net.connect(address)
                    match connect_result:
                        status.Status.err as connect_error_payload:
                            return status_net_error[Response](connect_error_payload.error)
                        status.Status.ok as connect_payload:
                            var stream = connect_payload.value
                            defer stream.release()

                            var request = build_get_request(parsed)
                            defer request.release()

                            let write_result = await stream.write_bytes(text.as_byte_span(request.as_str()))
                            match write_result:
                                status.Status.err as write_error_payload:
                                    return status_net_error[Response](write_error_payload.error)
                                status.Status.ok as write_payload:
                                    if write_payload.value != request.len:
                                        return status_error[Response]("http request write did not send the full request")

                            return await read_response(stream)

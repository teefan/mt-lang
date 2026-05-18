import std.bytes as bytes
import std.fmt as fmt
import std.mem.heap as heap
import std.net as net
import std.str as text
import std.string as string
import std.vec as vec


public struct Error:
    message: string.String


public struct Header:
    name: string.String
    value: string.String


public struct RequestHeader:
    name: str
    value: str


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
    content_length: Option[ptr_uint]
    chunked: bool


function status_error(message: str) -> Error:
    var owned_message = string.String.with_capacity(message.len)
    var index: ptr_uint = 0
    while index < message.len:
        owned_message.push_byte(message.byte_at(index))
        index += 1
    return Error(message = owned_message)


function status_net_error(net_error: net.Error) -> Error:
    var owned_error = net_error
    let text_value = owned_error.message.as_str()
    var message = string.String.with_capacity(text_value.len)
    var index: ptr_uint = 0
    while index < text_value.len:
        message.push_byte(text_value.byte_at(index))
        index += 1
    owned_error.release()
    return Error(message = message)


function url_error(detail: str) -> Error:
    return status_error(f"invalid http url: #{detail}")


function response_error(detail: str) -> Error:
    return status_error(f"invalid http response: #{detail}")


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


function find_byte_from(text_value: str, value: ubyte, start: ptr_uint) -> Option[ptr_uint]:
    var index = start
    while index < text_value.len:
        if text_value.byte_at(index) == value:
            return Option[ptr_uint].some(value = index)
        index += 1

    return Option[ptr_uint].none


function count_byte(text_value: str, value: ubyte) -> ptr_uint:
    var count: ptr_uint = 0
    var index: ptr_uint = 0
    while index < text_value.len:
        if text_value.byte_at(index) == value:
            count += 1
        index += 1

    return count


function parse_decimal(text_value: str) -> Option[ptr_uint]:
    if text_value.len == 0:
        return Option[ptr_uint].none

    var value: ptr_uint = 0
    var index: ptr_uint = 0
    while index < text_value.len:
        let current = text_value.byte_at(index)
        if current < ubyte<-48 or current > ubyte<-57:
            return Option[ptr_uint].none

        let digit = ptr_uint<-(current - ubyte<-48)
        if value > (heap.ptr_uint_max() - digit) / ptr_uint<-10:
            return Option[ptr_uint].none

        value = value * ptr_uint<-10 + digit
        index += 1

    return Option[ptr_uint].some(value = value)


function parse_port(text_value: str) -> Option[int]:
    let parsed = parse_decimal(text_value) else:
        return Option[int].none

    if parsed > ptr_uint<-65535:
        return Option[int].none

    return Option[int].some(value = int<-parsed)


function parse_target(rest: str) -> Result[string.String, Error]:
    if rest.len == 0:
        return Result[string.String, Error].success(value = string.String.from_str("/"))

    let fragment_index = find_byte_from(rest, ubyte<-35, 0)
    var target_text = rest
    match fragment_index:
        Option.none:
            pass
        Option.some as payload:
            target_text = rest.slice(0, payload.value)

    if target_text.len == 0:
        return Result[string.String, Error].success(value = string.String.from_str("/"))

    let first = target_text.byte_at(0)
    if first == ubyte<-47:
        return Result[string.String, Error].success(value = string.String.from_str(target_text))

    if first == ubyte<-63:
        var target = string.String.from_str("/")
        target.append(target_text)
        return Result[string.String, Error].success(value = target)

    return Result[string.String, Error].failure(error = url_error("path must start with '/' or '?'") )


function parse_url(url: str) -> Result[ParsedUrl, Error]:
    if url.starts_with("https://"):
        return Result[ParsedUrl, Error].failure(error = url_error("https is not supported yet"))

    if not url.starts_with("http://"):
        return Result[ParsedUrl, Error].failure(error = url_error("URL must start with http://"))

    let remainder = url.slice(7, url.len - 7)
    if remainder.len == 0:
        return Result[ParsedUrl, Error].failure(error = url_error("missing authority"))

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
        return Result[ParsedUrl, Error].failure(error = url_error("missing authority"))

    if count_byte(authority_text, ubyte<-64) != 0:
        return Result[ParsedUrl, Error].failure(error = url_error("userinfo is not supported"))

    var host_text = authority_text
    var port = 80
    if authority_text.byte_at(0) == ubyte<-91:
        var closing_bracket: ptr_uint = 0
        match find_byte_from(authority_text, ubyte<-93, 1):
            Option.none:
                return Result[ParsedUrl, Error].failure(error = url_error("missing closing ']' for IPv6 host"))
            Option.some as payload:
                closing_bracket = payload.value

        if closing_bracket == 1:
            return Result[ParsedUrl, Error].failure(error = url_error("host is empty"))

        host_text = authority_text.slice(1, closing_bracket - 1)
        if closing_bracket + 1 < authority_text.len:
            if authority_text.byte_at(closing_bracket + 1) != ubyte<-58:
                return Result[ParsedUrl, Error].failure(error = url_error("unexpected text after IPv6 host"))

            let port_start = closing_bracket + 2
            let port_text = authority_text.slice(port_start, authority_text.len - port_start)
            match parse_port(port_text):
                Option.none:
                    return Result[ParsedUrl, Error].failure(error = url_error("invalid port"))
                Option.some as payload:
                    port = payload.value
    else:
        let colon_count = count_byte(authority_text, ubyte<-58)
        if colon_count > 1:
            return Result[ParsedUrl, Error].failure(error = url_error("IPv6 hosts must be wrapped in []"))

        if colon_count == 1:
            var colon_index: ptr_uint = 0
            match authority_text.find_byte(ubyte<-58):
                Option.none:
                    fatal(c"http.parse_url missing authority port separator")
                Option.some as payload:
                    colon_index = payload.value

            if colon_index == 0:
                return Result[ParsedUrl, Error].failure(error = url_error("host is empty"))

            host_text = authority_text.slice(0, colon_index)
            let port_start = colon_index + 1
            let port_text = authority_text.slice(port_start, authority_text.len - port_start)
            match parse_port(port_text):
                Option.none:
                    return Result[ParsedUrl, Error].failure(error = url_error("invalid port"))
                Option.some as payload:
                    port = payload.value

    if host_text.len == 0:
        return Result[ParsedUrl, Error].failure(error = url_error("host is empty"))

    let rest = remainder.slice(authority_end, remainder.len - authority_end)
    let target_result = parse_target(rest)
    match target_result:
        Result.failure as payload:
            return Result[ParsedUrl, Error].failure(error = payload.error)
        Result.success as payload:
            let target = payload.value
            return Result[ParsedUrl, Error].success(
                value = ParsedUrl(
                    host = string.String.from_str(host_text),
                    authority = string.String.from_str(authority_text),
                    target = target,
                    port = port,
                )
            )


function append_request_text(output: ref[vec.Vec[ubyte]], value: str) -> void:
    output.append_span(text.as_byte_span(value))


function append_request_header_line(output: ref[vec.Vec[ubyte]], name: str, value: str) -> void:
    append_request_text(output, name)
    append_request_text(output, ": ")
    append_request_text(output, value)
    append_request_text(output, "\r\n")


function valid_http_token(value: str) -> bool:
    if value.len == 0:
        return false

    var index: ptr_uint = 0
    while index < value.len:
        let current = value.byte_at(index)
        if current <= ubyte<-32 or current >= ubyte<-127 or current == ubyte<-58:
            return false
        index += 1

    return true


function valid_http_header_value(value: str) -> bool:
    var index: ptr_uint = 0
    while index < value.len:
        let current = value.byte_at(index)
        if current == ubyte<-13 or current == ubyte<-10:
            return false
        index += 1

    return true


function build_request(url: ParsedUrl, method: str, headers: span[RequestHeader], body: Option[span[ubyte]]) -> Result[vec.Vec[ubyte], Error]:
    if not valid_http_token(method):
        return Result[vec.Vec[ubyte], Error].failure(error = status_error("invalid http method"))

    var body_length: ptr_uint = 0
    match body:
        Option.none:
            pass
        Option.some as payload:
            body_length = payload.value.len

    var request = vec.Vec[ubyte].with_capacity(url.target.len + url.authority.len + method.len + body_length + 128)

    var has_host = false
    var has_connection = false
    var has_user_agent = false
    var content_length_seen = false

    var index: ptr_uint = 0
    while index < headers.len:
        let header = unsafe: read(headers.data + index)
        if not valid_http_token(header.name):
            request.release()
            return Result[vec.Vec[ubyte], Error].failure(error = status_error("request header name is invalid"))

        if not valid_http_header_value(header.value):
            request.release()
            return Result[vec.Vec[ubyte], Error].failure(error = status_error("request header value is invalid"))

        if ascii_case_equal(header.name, "Host"):
            has_host = true
        else if ascii_case_equal(header.name, "Connection"):
            has_connection = true
        else if ascii_case_equal(header.name, "User-Agent"):
            has_user_agent = true
        else if ascii_case_equal(header.name, "Content-Length"):
            if content_length_seen:
                request.release()
                return Result[vec.Vec[ubyte], Error].failure(error = status_error("request Content-Length must not be repeated"))

            let content_length = parse_decimal(header.value.trim_ascii_whitespace()) else:
                request.release()
                return Result[vec.Vec[ubyte], Error].failure(error = status_error("request Content-Length must be a decimal integer"))

            if content_length != body_length:
                request.release()
                return Result[vec.Vec[ubyte], Error].failure(error = status_error("request Content-Length does not match body length"))

            content_length_seen = true

        index += 1

    append_request_text(ref_of(request), method)
    append_request_text(ref_of(request), " ")
    append_request_text(ref_of(request), url.target.as_str())
    append_request_text(ref_of(request), " HTTP/1.1\r\n")

    if not has_host:
        append_request_header_line(ref_of(request), "Host", url.authority.as_str())

    if not has_connection:
        append_request_header_line(ref_of(request), "Connection", "close")

    if not has_user_agent:
        append_request_header_line(ref_of(request), "User-Agent", "milk-tea/std.http")

    if not content_length_seen:
        var content_length = fmt.to_string_ptr_uint(body_length)
        defer content_length.release()
        append_request_header_line(ref_of(request), "Content-Length", content_length.as_str())

    index = 0
    while index < headers.len:
        let header = unsafe: read(headers.data + index)
        append_request_header_line(ref_of(request), header.name, header.value)
        index += 1

    append_request_text(ref_of(request), "\r\n")

    match body:
        Option.none:
            pass
        Option.some as payload:
            request.append_span(payload.value)

    return Result[vec.Vec[ubyte], Error].success(value = request)


function find_crlf(text_value: str, start: ptr_uint) -> Option[ptr_uint]:
    if text_value.len < 2 or start + 1 >= text_value.len:
        return Option[ptr_uint].none

    var index = start
    while index + 1 < text_value.len:
        if text_value.byte_at(index) == ubyte<-13 and text_value.byte_at(index + 1) == ubyte<-10:
            return Option[ptr_uint].some(value = index)
        index += 1

    return Option[ptr_uint].none


function find_header_terminator(data: span[ubyte]) -> Option[ptr_uint]:
    if data.len < 4:
        return Option[ptr_uint].none

    var index: ptr_uint = 0
    while index + 3 < data.len:
        if unsafe: read(data.data + index) == ubyte<-13 and read(data.data + index + 1) == ubyte<-10 and read(data.data + index + 2) == ubyte<-13 and read(data.data + index + 3) == ubyte<-10:
            return Option[ptr_uint].some(value = index)
        index += 1

    return Option[ptr_uint].none


function find_crlf_bytes(data: span[ubyte], start: ptr_uint) -> Option[ptr_uint]:
    if data.len < 2 or start + 1 >= data.len:
        return Option[ptr_uint].none

    var index = start
    while index + 1 < data.len:
        if unsafe: read(data.data + index) == ubyte<-13 and read(data.data + index + 1) == ubyte<-10:
            return Option[ptr_uint].some(value = index)
        index += 1

    return Option[ptr_uint].none


function hexadecimal_digit_value(current: ubyte) -> Option[ptr_uint]:
    if current < ubyte<-48:
        return Option[ptr_uint].none

    if current <= ubyte<-57:
        return Option[ptr_uint].some(value = ptr_uint<-(current - ubyte<-48))

    if current < ubyte<-65:
        return Option[ptr_uint].none

    if current <= ubyte<-70:
        return Option[ptr_uint].some(value = ptr_uint<-(current - ubyte<-55))

    if current < ubyte<-97:
        return Option[ptr_uint].none

    if current <= ubyte<-102:
        return Option[ptr_uint].some(value = ptr_uint<-(current - ubyte<-87))

    return Option[ptr_uint].none


function parse_hexadecimal(text_value: str) -> Option[ptr_uint]:
    if text_value.len == 0:
        return Option[ptr_uint].none

    var value: ptr_uint = 0
    var index: ptr_uint = 0
    while index < text_value.len:
        let current = text_value.byte_at(index)
        let digit = hexadecimal_digit_value(current) else:
            return Option[ptr_uint].none

        if value > (heap.ptr_uint_max() - digit) / ptr_uint<-16:
            return Option[ptr_uint].none

        value = value * ptr_uint<-16 + digit
        index += 1

    return Option[ptr_uint].some(value = value)


function parse_chunk_size(text_value: str) -> Option[ptr_uint]:
    var size_text = text_value
    let extension = find_byte_from(text_value, ubyte<-59, 0) else:
        let parsed = parse_hexadecimal(size_text.trim_ascii_whitespace()) else:
            return Option[ptr_uint].none
        return Option[ptr_uint].some(value = parsed)

    size_text = text_value.slice(0, extension)
    let parsed = parse_hexadecimal(size_text.trim_ascii_whitespace()) else:
        return Option[ptr_uint].none
    return Option[ptr_uint].some(value = parsed)


function discard_buffer_prefix(buffer: ref[vec.Vec[ubyte]], count: ptr_uint) -> void:
    if count == 0:
        return

    if count >= buffer.len:
        buffer.clear()
        return

    let data = buffer.data else:
        fatal(c"http.discard_buffer_prefix missing storage")

    let remaining = buffer.len - count
    unsafe:
        let data_ptr = ptr[ubyte]<-data
        var index: ptr_uint = 0
        while index < remaining:
            read(data_ptr + index) = read(data_ptr + count + index)
            index += 1

    buffer.len = remaining
    return


function parse_response_head(header_text: str) -> Result[ResponseHead, Error]:
    var line_end = header_text.len
    var header_index = header_text.len
    match find_crlf(header_text, 0):
        Option.none:
            pass
        Option.some as payload:
            line_end = payload.value
            header_index = line_end + 2

    let status_line = header_text.slice(0, line_end)
    if not status_line.starts_with("HTTP/1."):
        return Result[ResponseHead, Error].failure(error = response_error("unsupported HTTP version"))

    var first_space: ptr_uint = 0
    match status_line.find_byte(ubyte<-32):
        Option.none:
            return Result[ResponseHead, Error].failure(error = response_error("missing status code"))
        Option.some as payload:
            first_space = payload.value

    if first_space + 4 > status_line.len:
        return Result[ResponseHead, Error].failure(error = response_error("missing status code"))

    let status_code_text = status_line.slice(first_space + 1, 3)
    var status_code = 0
    match parse_decimal(status_code_text):
        Option.none:
            return Result[ResponseHead, Error].failure(error = response_error("invalid status code"))
        Option.some as payload:
            status_code = int<-payload.value

    var reason = string.String.create()
    if first_space + 4 < status_line.len:
        if status_line.byte_at(first_space + 4) != ubyte<-32:
            return Result[ResponseHead, Error].failure(error = response_error("status line must separate code and reason with a space"))

        let reason_start = first_space + 5
        reason = string.String.from_str(status_line.slice(reason_start, status_line.len - reason_start))

    var head = ResponseHead(
        status_code = status_code,
        reason = reason,
        headers = vec.Vec[Header].create(),
        content_length = Option[ptr_uint].none,
        chunked = false,
    )

    var index = header_index
    while index < header_text.len:
        var next_line_end = header_text.len
        match find_crlf(header_text, index):
            Option.none:
                pass
            Option.some as payload:
                next_line_end = payload.value

        let line = header_text.slice(index, next_line_end - index)
        if line.len == 0:
            head.release()
            return Result[ResponseHead, Error].failure(error = response_error("unexpected blank header line"))

        var separator: ptr_uint = 0
        match line.find_byte(ubyte<-58):
            Option.none:
                head.release()
                return Result[ResponseHead, Error].failure(error = response_error("header line is missing ':'"))
            Option.some as payload:
                separator = payload.value

        if separator == 0:
            head.release()
            return Result[ResponseHead, Error].failure(error = response_error("header name is empty"))

        let name_text = line.slice(0, separator)
        let value_start = separator + 1
        let value_text = line.slice(value_start, line.len - value_start).trim_ascii_whitespace()

        head.headers.push(Header(name = string.String.from_str(name_text), value = string.String.from_str(value_text)))

        if ascii_case_equal(name_text, "Content-Length"):
            match parse_decimal(value_text):
                Option.none:
                    head.release()
                    return Result[ResponseHead, Error].failure(error = response_error("Content-Length must be a decimal integer"))
                Option.some as payload:
                    head.content_length = Option[ptr_uint].some(value = payload.value)

        if ascii_case_equal(name_text, "Transfer-Encoding"):
            if ascii_case_equal(value_text, "chunked"):
                head.chunked = true
            else:
                head.release()
                return Result[ResponseHead, Error].failure(error = response_error("unsupported Transfer-Encoding"))

        if next_line_end == header_text.len:
            index = header_text.len
        else:
            index = next_line_end + 2

    if head.chunked:
        head.content_length = Option[ptr_uint].none

    return Result[ResponseHead, Error].success(value = head)


async function read_chunked_body(stream: net.TcpStream, prefix: span[ubyte]) -> Result[bytes.Bytes, Error]:
    var body = vec.Vec[ubyte].with_capacity(prefix.len)
    defer body.release()

    var buffer = vec.Vec[ubyte].with_capacity(prefix.len + 64)
    defer buffer.release()
    buffer.append_span(prefix)

    var cursor: ptr_uint = 0
    while true:
        var line_end: ptr_uint = 0
        while true:
            match find_crlf_bytes(buffer.as_span(), cursor):
                Option.none:
                    if cursor > 0:
                        discard_buffer_prefix(ref_of(buffer), cursor)
                        cursor = 0

                    let chunk_result = await stream.read_once(4096)
                    match chunk_result:
                        Result.failure as error_payload:
                            return Result[bytes.Bytes, Error].failure(error = status_net_error(error_payload.error))
                        Result.success as ok_payload:
                            var chunk = ok_payload.value
                            if chunk.len == 0:
                                chunk.release()
                                return Result[bytes.Bytes, Error].failure(error = response_error("chunked response ended before chunk size"))

                            buffer.append_span(chunk.as_span())
                            chunk.release()
                            continue
                Option.some as payload:
                    line_end = payload.value
                    break

        let line_bytes = unsafe: span[ubyte](data = buffer.as_span().data + cursor, len = line_end - cursor)
        let line_text = text.utf8_byte_span_as_str(line_bytes) else:
            return Result[bytes.Bytes, Error].failure(error = response_error("chunk size line is not valid UTF-8"))

        let chunk_size = parse_chunk_size(line_text) else:
            return Result[bytes.Bytes, Error].failure(error = response_error("invalid chunk size"))

        cursor = line_end + 2

        if chunk_size == 0:
            while true:
                var trailer_end: ptr_uint = 0
                while true:
                    match find_crlf_bytes(buffer.as_span(), cursor):
                        Option.none:
                            if cursor > 0:
                                discard_buffer_prefix(ref_of(buffer), cursor)
                                cursor = 0

                            let chunk_result = await stream.read_once(4096)
                            match chunk_result:
                                Result.failure as error_payload:
                                    return Result[bytes.Bytes, Error].failure(error = status_net_error(error_payload.error))
                                Result.success as ok_payload:
                                    var chunk = ok_payload.value
                                    if chunk.len == 0:
                                        chunk.release()
                                        return Result[bytes.Bytes, Error].failure(error = response_error("chunked response ended before trailers were complete"))

                                    buffer.append_span(chunk.as_span())
                                    chunk.release()
                                    continue
                        Option.some as payload:
                            trailer_end = payload.value
                            break

                if trailer_end == cursor:
                    return Result[bytes.Bytes, Error].success(value = bytes.Bytes.copy(body.as_span()))

                cursor = trailer_end + 2

        while buffer.len - cursor < chunk_size + 2:
            if cursor > 0:
                discard_buffer_prefix(ref_of(buffer), cursor)
                cursor = 0

            let chunk_result = await stream.read_once(4096)
            match chunk_result:
                Result.failure as error_payload:
                    return Result[bytes.Bytes, Error].failure(error = status_net_error(error_payload.error))
                Result.success as ok_payload:
                    var chunk = ok_payload.value
                    if chunk.len == 0:
                        chunk.release()
                        return Result[bytes.Bytes, Error].failure(error = response_error("chunked response ended before chunk data"))

                    buffer.append_span(chunk.as_span())
                    chunk.release()

        let chunk_bytes = unsafe: span[ubyte](data = buffer.as_span().data + cursor, len = chunk_size)
        body.append_span(chunk_bytes)
        cursor += chunk_size

        let unread = buffer.as_span()
        if unsafe: read(unread.data + cursor) != ubyte<-13 or read(unread.data + cursor + 1) != ubyte<-10:
            return Result[bytes.Bytes, Error].failure(error = response_error("chunk data must end with CRLF"))

        cursor += 2


async function read_body(stream: net.TcpStream, prefix: span[ubyte], content_length: Option[ptr_uint], chunked: bool) -> Result[bytes.Bytes, Error]:
    if chunked:
        return await read_chunked_body(stream, prefix)

    match content_length:
        Option.some as payload:
            let total_length = payload.value
            if prefix.len > total_length:
                return Result[bytes.Bytes, Error].failure(error = response_error("body exceeded Content-Length"))

            var body = vec.Vec[ubyte].with_capacity(total_length)
            defer body.release()

            body.append_span(prefix)

            let remaining = total_length - prefix.len
            if remaining > 0:
                let chunk_result = await stream.read_exactly(remaining)
                match chunk_result:
                    Result.failure as error_payload:
                        return Result[bytes.Bytes, Error].failure(error = status_net_error(error_payload.error))
                    Result.success as ok_payload:
                        var chunk = ok_payload.value
                        body.append_span(chunk.as_span())
                        chunk.release()

            return Result[bytes.Bytes, Error].success(value = bytes.Bytes.copy(body.as_span()))
        Option.none:
            var body = vec.Vec[ubyte].with_capacity(prefix.len)
            defer body.release()

            body.append_span(prefix)

            while true:
                let chunk_result = await stream.read_once(4096)
                match chunk_result:
                    Result.failure as error_payload:
                        return Result[bytes.Bytes, Error].failure(error = status_net_error(error_payload.error))
                    Result.success as ok_payload:
                        var chunk = ok_payload.value
                        if chunk.len == 0:
                            chunk.release()
                            break

                        body.append_span(chunk.as_span())
                        chunk.release()

            return Result[bytes.Bytes, Error].success(value = bytes.Bytes.copy(body.as_span()))


async function read_response(stream: net.TcpStream) -> Result[Response, Error]:
    var received = vec.Vec[ubyte].create()
    defer received.release()

    var header_length: ptr_uint = 0
    var headers_ready = false
    while not headers_ready:
        let chunk_result = await stream.read_once(4096)
        match chunk_result:
            Result.failure as error_payload:
                return Result[Response, Error].failure(error = status_net_error(error_payload.error))
            Result.success as ok_payload:
                var chunk = ok_payload.value
                if chunk.len == 0:
                    chunk.release()
                    return Result[Response, Error].failure(error = response_error("response ended before headers were complete"))

                received.append_span(chunk.as_span())
                chunk.release()

                match find_header_terminator(received.as_span()):
                    Option.none:
                        continue
                    Option.some as payload:
                        header_length = payload.value
                        headers_ready = true

    let raw = received.as_span()
    let header_bytes = unsafe: span[ubyte](data = raw.data, len = header_length)
    let header_text = text.utf8_byte_span_as_str(header_bytes) else:
        return Result[Response, Error].failure(error = response_error("headers are not valid UTF-8"))

    let head_result = parse_response_head(header_text)
    match head_result:
        Result.failure as payload:
            return Result[Response, Error].failure(error = payload.error)
        Result.success as payload:
            var head = payload.value
            let body_start = header_length + 4
            let body_prefix = unsafe: span[ubyte](data = raw.data + body_start, len = raw.len - body_start)

            let body_result = await read_body(stream, body_prefix, head.content_length, head.chunked)
            match body_result:
                Result.failure as body_error_payload:
                    head.release()
                    return Result[Response, Error].failure(error = body_error_payload.error)
                Result.success as body_payload:
                    let body = body_payload.value
                    return Result[Response, Error].success(
                        value = Response(
                            status_code = head.status_code,
                            reason = head.reason,
                            headers = head.headers,
                            body = body,
                        )
                    )


extending Error:
    public mutable function release() -> void:
        this.message.release()
        return


extending Header:
    public mutable function release() -> void:
        this.name.release()
        this.value.release()
        return


extending Response:
    public mutable function release() -> void:
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


    public function header(name: str) -> Option[str]:
        var index: ptr_uint = 0
        while index < this.headers.len:
            let current = this.headers.get(index) else:
                fatal(c"http.Response.header missing header")

            let header_value = unsafe: read(current)
            if ascii_case_equal(header_value.name.as_str(), name):
                return Option[str].some(value = header_value.value.as_str())

            index += 1

        return Option[str].none


extending ParsedUrl:
    mutable function release() -> void:
        this.host.release()
        this.authority.release()
        this.target.release()
        return


extending ResponseHead:
    mutable function release() -> void:
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


public async function get(url: str) -> Result[Response, Error]:
    return await request(url, "GET", zero[span[RequestHeader]], Option[span[ubyte]].none)


public async function request(url: str, method: str, headers: span[RequestHeader], body: Option[span[ubyte]]) -> Result[Response, Error]:
    let parsed_result = parse_url(url)
    match parsed_result:
        Result.failure as payload:
            return Result[Response, Error].failure(error = payload.error)
        Result.success as payload:
            var parsed = payload.value
            defer parsed.release()

            let request_result = build_request(parsed, method, headers, body)
            match request_result:
                Result.failure as request_error_payload:
                    return Result[Response, Error].failure(error = request_error_payload.error)
                Result.success as request_payload:
                    var request_bytes = request_payload.value
                    defer request_bytes.release()

                    var service = fmt.to_string_int(parsed.port)
                    defer service.release()

                    let address_result = await net.resolve_first(parsed.host.as_str(), service.as_str())
                    match address_result:
                        Result.failure as address_error_payload:
                            return Result[Response, Error].failure(error = status_net_error(address_error_payload.error))
                        Result.success as address_payload:
                            var address = address_payload.value
                            defer address.release()

                            let connect_result = await net.connect(address)
                            match connect_result:
                                Result.failure as connect_error_payload:
                                    return Result[Response, Error].failure(error = status_net_error(connect_error_payload.error))
                                Result.success as connect_payload:
                                    var stream = connect_payload.value
                                    defer stream.release()

                                    let write_result = await stream.write_bytes(request_bytes.as_span())
                                    match write_result:
                                        Result.failure as write_error_payload:
                                            return Result[Response, Error].failure(error = status_net_error(write_error_payload.error))
                                        Result.success as write_payload:
                                            if write_payload.value != request_bytes.len:
                                                return Result[Response, Error].failure(error = status_error("http request write did not send the full request"))

                                    return await read_response(stream)

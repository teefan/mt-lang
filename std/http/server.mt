import std.bytes as bytes
import std.net as net
import std.str as text
import std.string as string
import std.url as url
import std.vec as vec


public struct Request:
    method: string.String
    path: string.String
    query: str
    headers: vec.Vec[HttpHeader]
    body: bytes.Bytes
    raw_url: string.String


public struct HttpHeader:
    name: string.String
    value: string.String


public struct Response:
    status_code: int
    reason: string.String
    headers: vec.Vec[HttpHeader]
    body: bytes.Bytes


public function request_method(request: Request) -> str:
    return request.method.as_str()


public function request_path(request: Request) -> str:
    return request.path.as_str()


public function request_query(request: Request) -> str:
    return request.query


public function request_query_param(request: Request, key: str) -> Option[str]:
    if request.query.len == 0:
        return Option[str].none

    let query_str = request.query
    var start: ptr_uint = 0
    while start < query_str.len:
        let amp = find_byte_from(query_str, 38, start)
        var end = query_str.len
        if amp < query_str.len:
            end = amp

        let pair = query_str.slice(start, end - start)

        let eq = pair.find_byte(61)
        match eq:
            Option.none:
                if pair.equal(key):
                    return Option[str].some(value = "")
            Option.some as e:
                let param_key = pair.slice(0, e.value)
                if param_key.equal(key):
                    let param_value = pair.slice(e.value + 1, pair.len - e.value - 1)

                    let decoded = url.percent_decode(param_value) else:
                        return Option[str].some(value = "")

                    return Option[str].some(value = decoded.as_str())

        if amp >= query_str.len:
            start = query_str.len
        else:
            start = amp + 1

    return Option[str].none


public function request_header(request: Request, name: str) -> Option[str]:
    var index: ptr_uint = 0
    while index < request.headers.len():
        let header = request.headers.get(index) else:
            fatal(c"http.server.request_header missing entry")

        unsafe:
            let h = read(header)
            if ascii_case_equal(h.name.as_str(), name):
                return Option[str].some(value = h.value.as_str())

        index += 1

    return Option[str].none


public function request_body_as_str(request: Request) -> Option[str]:
    return request.body.as_str()


public function create_response() -> Response:
    return Response(
        status_code = 200,
        reason = string.String.from_str("OK"),
        headers = vec.Vec[HttpHeader].create(),
        body = bytes.Bytes.empty()
    )


public function response_set_status(response: ref[Response], code: int, reason: str) -> void:
    response.status_code = code
    response.reason.assign(reason)


public function response_set_body(response: ref[Response], content: str) -> void:
    var body_data = bytes.Bytes.copy(text.as_byte_span(content))
    response.body.release()
    response.body = body_data


public function response_set_body_json(response: ref[Response], json_text: str) -> void:
    response_set_body(response, json_text)
    response_set_header(response, "Content-Type", "application/json")


public function response_set_header(response: ref[Response], name: str, value: str) -> void:
    var index: ptr_uint = 0
    while index < response.headers.len():
        let header = response.headers.get(index) else:
            break

        unsafe:
            if ascii_case_equal(read(header).name.as_str(), name):
                var existing = read(header).value
                existing.release()
                read(header).value = string.String.from_str(value)
                return

        index += 1

    response.headers.push(HttpHeader(
        name = string.String.from_str(name),
        value = string.String.from_str(value)
    ))


public function parse_request(raw_data: span[ubyte]) -> Result[Request, string.String]:
    let header_text = text.utf8_byte_span_as_str(raw_data) else:
        return Result[Request, string.String].failure(error = string.String.from_str("request is not valid UTF-8"))

    let header_end = find_header_terminator(raw_data)
    match header_end:
        Option.none:
            return Result[Request, string.String].failure(error = string.String.from_str("request headers incomplete"))
        Option.some as end_pos:
            let inner = text.utf8_byte_span_as_str(span[ubyte](data = raw_data.data, len = end_pos.value)) else:
                return Result[Request, string.String].failure(error = string.String.from_str("request headers not valid UTF-8"))
            let first_line_end = find_byte(inner, 10)
            var request_line = inner.slice(0, first_line_end)
            if request_line.ends_with("\r"):
                request_line = inner.slice(0, request_line.len - 1)

            let method_end = find_byte(request_line, 32)
            if method_end >= request_line.len:
                return Result[Request, string.String].failure(error = string.String.from_str("malformed request line"))

            let method = request_line.slice(0, method_end)

            var path_start = method_end + 1
            while path_start < request_line.len and request_line.byte_at(path_start) == 32:
                path_start += 1

            let path_end = find_byte_from(request_line, 32, path_start)
            var raw_url = request_line.slice(path_start, path_end - path_start)

            var path = raw_url
            var query: str = zero[str]
            let question = raw_url.find_byte(63)
            match question:
                Option.none:
                    pass
                Option.some as q:
                    path = raw_url.slice(0, q.value)
                    query = raw_url.slice(q.value + 1, raw_url.len - q.value - 1)

            var headers = vec.Vec[HttpHeader].create()

            let first_crlf = find_byte_from(inner, 13, first_line_end)
            if first_crlf < inner.len:
                var index = first_crlf + 2
                while index < inner.len:
                    if inner.byte_at(index) == 13:
                        break

                    let line_end = find_byte_from(inner, 13, index)
                    if line_end >= inner.len:
                        break

                    let line = inner.slice(index, line_end - index)

                    let colon = line.find_byte(58)
                    match colon:
                        Option.none:
                            break
                        Option.some as c:
                            let name_text = line.slice(0, c.value)
                            var value_start = c.value + 1
                            while value_start < line.len and line.byte_at(value_start) == 32:
                                value_start += 1
                            let value_text = line.slice(value_start, line.len - value_start)

                            headers.push(HttpHeader(
                                name = string.String.from_str(name_text),
                                value = string.String.from_str(value_text)
                            ))

                    index = line_end + 2

            var body_data = bytes.Bytes.empty()
            let body_start = end_pos.value + 4
            if body_start < raw_data.len:
                let body_span = unsafe: span[ubyte](data = raw_data.data + body_start, len = raw_data.len - body_start)
                body_data = bytes.Bytes.copy(body_span)

            return Result[Request, string.String].success(value = Request(
                method = string.String.from_str(method),
                path = string.String.from_str(path),
                query = query,
                headers = headers,
                body = body_data,
                raw_url = string.String.from_str(raw_url)
            ))


function find_header_terminator(data: span[ubyte]) -> Option[ptr_uint]:
    if data.len < 4:
        return Option[ptr_uint].none

    var index: ptr_uint = 0
    while index + 3 < data.len:
        if (
            unsafe: read(data.data + index) == 13
            and read(data.data + index + 1) == 10
            and read(data.data + index + 2) == 13
            and read(data.data + index + 3) == 10
        ):
            return Option[ptr_uint].some(value = index)
        index += 1

    return Option[ptr_uint].none


function find_byte(data: str, target: ubyte) -> ptr_uint:
    var index: ptr_uint = 0
    while index < data.len:
        if data.byte_at(index) == target:
            return index
        index += 1
    return data.len


function find_byte_from(data: str, target: ubyte, start: ptr_uint) -> ptr_uint:
    var index = start
    while index < data.len:
        if data.byte_at(index) == target:
            return index
        index += 1
    return data.len


function ascii_case_equal(left: str, right: str) -> bool:
    if left.len != right.len:
        return false

    var index: ptr_uint = 0
    while index < left.len:
        let a = left.byte_at(index)
        let b = right.byte_at(index)

        var lower_a = a
        if lower_a >= 65 and lower_a <= 90:
            lower_a += 32

        var lower_b = b
        if lower_b >= 65 and lower_b <= 90:
            lower_b += 32

        if lower_a != lower_b:
            return false
        index += 1

    return true


public async function write_response(stream: net.TcpStream, response: ref[Response]) -> Result[ptr_uint, net.Error]:
    var header_text = string.String.with_capacity(256)
    defer header_text.release()

    let reason_str = response.reason.as_str()
    var status_text = string.String.create()
    defer status_text.release()
    append_ptr_uint(ref_of(status_text), ptr_uint<-response.status_code)

    header_text.append("HTTP/1.1 ")
    header_text.append(status_text.as_str())
    header_text.push_byte(32)
    header_text.append(reason_str)
    header_text.append("\r\n")

    var body_len_text = string.String.create()
    defer body_len_text.release()
    append_ptr_uint(ref_of(body_len_text), response.body.len)

    var has_content_type = false
    var index: ptr_uint = 0
    while index < response.headers.len():
        let header = response.headers.get(index) else:
            fatal(c"http.server.write_response missing header")

        unsafe:
            let h = read(header)
            header_text.append(h.name.as_str())
            header_text.append(": ")
            header_text.append(h.value.as_str())
            header_text.append("\r\n")

            if ascii_case_equal(h.name.as_str(), "Content-Type"):
                has_content_type = true

        index += 1

    if not has_content_type:
        header_text.append("Content-Type: text/plain\r\n")

    header_text.append("Content-Length: ")
    header_text.append(body_len_text.as_str())
    header_text.append("\r\nConnection: close\r\n\r\n")

    let header_bytes = text.as_byte_span(header_text.as_str())
    let write_result = await stream.write_bytes(header_bytes)
    match write_result:
        Result.failure as payload:
            return Result[ptr_uint, net.Error].failure(error = payload.error)
        Result.success:
            if response.body.len > 0:
                let body_span = response.body.as_span()

                let body_result = await stream.write_bytes(body_span)
                match body_result:
                    Result.failure as payload:
                        return Result[ptr_uint, net.Error].failure(error = payload.error)
                    Result.success:
                        pass

            return Result[ptr_uint, net.Error].success(value = header_bytes.len + response.body.len)


function append_ptr_uint(target: ref[string.String], value: ptr_uint) -> void:
    var digits: array[ubyte, 32]
    var count: ptr_uint = 0
    if value == 0:
        target.push_byte(48)
        return

    var remaining = value
    while remaining != 0:
        let digit = remaining % 10
        digits[count] = ubyte<-(ptr_uint<-48 + digit)
        remaining = remaining / 10
        count += 1

    while count > 0:
        count -= 1
        target.push_byte(digits[count])


extending Request:
    public editable function release() -> void:
        this.method.release()
        this.path.release()
        this.raw_url.release()

        var index: ptr_uint = 0
        while index < this.headers.len():
            let header = this.headers.get(index) else:
                fatal(c"http.server.Request.release missing header")

            unsafe:
                var h = read(header)
                h.release()

            index += 1

        this.headers.release()
        this.body.release()


extending HttpHeader:
    public editable function release() -> void:
        this.name.release()
        this.value.release()


extending Response:
    public editable function release() -> void:
        this.reason.release()

        var index: ptr_uint = 0
        while index < this.headers.len():
            let header = this.headers.get(index) else:
                fatal(c"http.server.Response.release missing header")

            unsafe:
                var h = read(header)
                h.release()

            index += 1

        this.headers.release()
        this.body.release()

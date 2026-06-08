import std.bytes as bytes
import std.fmt as fmt
import std.fs as fs
import std.net as net
import std.path as path_ops
import std.stdio as stdio
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
    let body_data = bytes.Bytes.copy(text.as_byte_span(content))
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
    let _ = text.utf8_byte_span_as_str(raw_data) else:
        return Result[Request, string.String].failure(error = string.String.from_str("request is not valid UTF-8"))

    let header_end = find_header_terminator(raw_data)
    match header_end:
        Option.none:
            return Result[Request, string.String].failure(error = string.String.from_str("request headers incomplete"))
        Option.some as end_pos:
            let inner = text.utf8_byte_span_as_str(span[ubyte](data = raw_data.data, len = end_pos.value)) else:
                return Result[Request, string.String].failure(
                    error = string.String.from_str("request headers not valid UTF-8")
                )
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
            let raw_url = request_line.slice(path_start, path_end - path_start)

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

const DEFAULT_PORT: int = 8080
const READ_BUFFER_SIZE: ptr_uint = 4096


function parse_port(args: span[str]) -> int:
    var index: ptr_uint = 0
    while index < args.len:
        let arg = unsafe: read(args.data + index)
        if arg.equal("--port") or arg.equal("-p"):
            index += 1
            if index >= args.len:
                return 0

            let port_arg = unsafe: read(args.data + index)
            var port: int = 0
            var digit_index: ptr_uint = 0
            while digit_index < port_arg.len:
                let digit = int<-(port_arg.byte_at(digit_index)) - 48
                if digit < 0 or digit > 9:
                    return 0
                port = port * 10 + digit
                digit_index += 1

            if port > 0 and port < 65536:
                return port

            return 0

        index += 1

    return DEFAULT_PORT


function parse_serve_dir(args: span[str]) -> str:
    var index: ptr_uint = 0
    while index < args.len:
        let arg = unsafe: read(args.data + index)
        if arg.equal("--root") or arg.equal("-r"):
            index += 1
            if index >= args.len:
                break

            return unsafe: read(args.data + index)

        if arg.equal("--port") or arg.equal("-p"):
            index += 1
            if index >= args.len:
                break

            index += 1
            continue

        if not arg.starts_with("-"):
            return arg

        index += 1

    return "."


function guess_mime(file_path: str) -> str:
    let ext = path_ops.extension(file_path)
    match ext:
        Option.none:
            return "application/octet-stream"
        Option.some as e:
            if e.value.equal(".html") or e.value.equal(".htm"):
                return "text/html"
            if e.value.equal(".css"):
                return "text/css"
            if e.value.equal(".js"):
                return "application/javascript"
            if e.value.equal(".json"):
                return "application/json"
            if e.value.equal(".md"):
                return "text/markdown"
            if e.value.equal(".png"):
                return "image/png"
            if e.value.equal(".jpg") or e.value.equal(".jpeg"):
                return "image/jpeg"
            if e.value.equal(".gif"):
                return "image/gif"
            if e.value.equal(".svg"):
                return "image/svg+xml"
            if e.value.equal(".ico"):
                return "image/x-icon"
            if e.value.equal(".wasm"):
                return "application/wasm"
            if e.value.equal(".txt"):
                return "text/plain"
            if e.value.equal(".xml"):
                return "application/xml"
            if e.value.equal(".pdf"):
                return "application/pdf"
            if e.value.equal(".mp3"):
                return "audio/mpeg"
            if e.value.equal(".mp4"):
                return "video/mp4"
            return "application/octet-stream"


function has_header_end(data: span[ubyte]) -> bool:
    if data.len < 4:
        return false

    var index: ptr_uint = 0
    while index + 3 < data.len:
        if (
            unsafe: read(data.data + index) == 13
            and read(data.data + index + 1) == 10
            and read(data.data + index + 2) == 13
            and read(data.data + index + 3) == 10
        ):
            return true
        index += 1

    return false


async function send_error(stream: net.TcpStream, code: int, message: str) -> void:
    var code_str = fmt.to_string_int(code)
    defer code_str.release()
    let body_text = f"<html><body><h1>#{code_str.as_str()} #{message}</h1></body></html>\r\n"
    var body_len_str = fmt.to_string_ptr_uint(body_text.len)
    defer body_len_str.release()
    let header_text = f"HTTP/1.1 #{code_str.as_str()} #{message}\r\nContent-Type: text/html\r\nContent-Length: #{body_len_str.as_str()}\r\nConnection: close\r\n\r\n"
    await stream.write_bytes(text.as_byte_span(header_text))
    await stream.write_bytes(text.as_byte_span(body_text))


async function send_file_response(
    stream: net.TcpStream,
    code: int,
    message: str,
    content_type: str,
    body: span[ubyte],
    head_only: bool
) -> void:
    var code_str = fmt.to_string_int(code)
    defer code_str.release()
    var body_len_str = fmt.to_string_ptr_uint(body.len)
    defer body_len_str.release()
    let header_text = f"HTTP/1.1 #{code_str.as_str()} #{message}\r\nContent-Type: #{content_type}\r\nContent-Length: #{body_len_str.as_str()}\r\nConnection: close\r\n\r\n"
    await stream.write_bytes(text.as_byte_span(header_text))
    if not head_only:
        await stream.write_bytes(body)


function sorted_insert(
    names: ref[vec.Vec[string.String]],
    dir_flags: ref[vec.Vec[bool]],
    value: string.String,
    is_directory: bool
) -> void:
    var index: ptr_uint = 0
    while index < names.len():
        let existing_ptr = names.get(index) else:
            break
        let existing_flag_ptr = dir_flags.get(index) else:
            break

        unsafe:
            let existing_is_dir = read(existing_flag_ptr)
            let existing_name = read(existing_ptr).as_str()

            if is_directory and not existing_is_dir:
                break
            if not is_directory and existing_is_dir:
                index += 1
                continue

            let cmp = value.as_str().compare(existing_name)
            if cmp < 0:
                break

        index += 1

    if not names.insert(index, value):
        fatal(c"sorted_insert names insert failed")
    if not dir_flags.insert(index, is_directory):
        fatal(c"sorted_insert flags insert failed")


function html_escape(text_value: str) -> string.String:
    var result = string.String.with_capacity(text_value.len * 2)
    var index: ptr_uint = 0
    while index < text_value.len:
        let ch = text_value.byte_at(index)
        if ch == 38:
            result.append("&amp;")
        else if ch == 60:
            result.append("&lt;")
        else if ch == 62:
            result.append("&gt;")
        else if ch == 34:
            result.append("&quot;")
        else:
            result.push_byte(ch)
        index += 1

    return result


function release_string_vec(values: ref[vec.Vec[string.String]]) -> void:
    var index: ptr_uint = 0
    while index < values.len():
        let value_ptr = values.get(index) else:
            break
        unsafe:
            var v = read(value_ptr)
            v.release()
        index += 1

    values.release()


async function serve_directory_index(stream: net.TcpStream, dir_path: str, url_prefix: str, head_only: bool) -> void:
    let entries_result = fs.list_entries(dir_path)
    match entries_result:
        Result.failure:
            await send_error(stream, 500, "Internal Server Error")
            return
        Result.success as entries_ok:
            var entries = entries_ok.value
            defer entries.release()

            var names = vec.Vec[string.String].create()
            defer release_string_vec(ref_of(names))

            var is_dir = vec.Vec[bool].create()
            defer is_dir.release()

            var index: ptr_uint = 0
            while index < entries.len():
                match entries.get(index):
                    Option.some as entry_name:
                        let name_str = entry_name.value
                        var child_path = path_ops.join(dir_path, name_str)
                        defer child_path.release()
                        let dir_flag = fs.is_directory(child_path.as_str())
                        sorted_insert(ref_of(names), ref_of(is_dir), string.String.from_str(name_str), dir_flag)
                    Option.none:
                        pass
                index += 1

            var body = string.String.with_capacity(4096)
            defer body.release()

            var escaped_path = html_escape(url_prefix)
            defer escaped_path.release()

            body.append("<!DOCTYPE html>\n<html>\n<head><meta charset=\"utf-8\"><title>Index of ")
            body.append(escaped_path.as_str())
            body.append("</title></head>\n<body>\n<h1>Index of ")
            body.append(escaped_path.as_str())
            body.append("</h1>\n<hr>\n<pre>\n")

            if url_prefix.len > 0 and not url_prefix.equal("/"):
                body.append("<a href=\"../\">../</a>\n")

            index = 0
            while index < names.len():
                let name_ptr = names.get(index) else:
                    break
                let dir_flag_ptr = is_dir.get(index) else:
                    break

                unsafe:
                    let name_str = read(name_ptr).as_str()
                    let is_directory = read(dir_flag_ptr)

                    var line = string.String.with_capacity(name_str.len + 64)
                    defer line.release()

                    var escaped_name = html_escape(name_str)
                    defer escaped_name.release()

                    if is_directory:
                        line.append("<a href=\"")
                        line.append(escaped_name.as_str())
                        line.append("/\">")
                        line.append(escaped_name.as_str())
                        line.append("/</a>")
                    else:
                        line.append("<a href=\"")
                        line.append(escaped_name.as_str())
                        line.append("\">")
                        line.append(escaped_name.as_str())
                        line.append("</a>")

                    line.append("\n")
                    body.append(line.as_str())

                index += 1

            body.append("</pre>\n<hr>\n</body>\n</html>")

            let body_span = text.as_byte_span(body.as_str())
            await send_file_response(stream, 200, "OK", "text/html; charset=utf-8", body_span, head_only)


async function handle_connection(stream: net.TcpStream, serve_dir: str) -> void:
    var conn = stream
    defer conn.release()

    var buffer = vec.Vec[ubyte].with_capacity(READ_BUFFER_SIZE)
    defer buffer.release()

    var headers_done = false
    while not headers_done:
        let chunk_result = await conn.read_once(READ_BUFFER_SIZE)
        match chunk_result:
            Result.failure:
                return
            Result.success as chunk_ok:
                var chunk = chunk_ok.value
                buffer.append_span(chunk.as_span())
                chunk.release()
                headers_done = has_header_end(buffer.as_span())

    let raw = buffer.as_span()
    let header_text = text.utf8_byte_span_as_str(raw) else:
        await send_error(conn, 400, "Bad Request")
        return

    let first_line_end = find_byte_from_str(header_text, 10, 0)
    var request_line = header_text.slice(0, first_line_end)
    if request_line.ends_with("\r"):
        request_line = header_text.slice(0, request_line.len - 1)

    let method_end = find_byte_from_str(request_line, 32, 0)
    if method_end >= request_line.len:
        await send_error(conn, 400, "Bad Request")
        return

    let method = request_line.slice(0, method_end)

    var path_start = method_end + 1
    while path_start < request_line.len and request_line.byte_at(path_start) == 32:
        path_start += 1

    let path_end = find_byte_from_str(request_line, 32, path_start)
    var url_path = request_line.slice(path_start, path_end - path_start)

    if not method.equal("GET") and not method.equal("HEAD"):
        await send_error(conn, 405, "Method Not Allowed")
        return

    var url_prefix = url_path
    var path_is_root = false
    if url_path.starts_with("/"):
        var stripped = url_path.slice(1, url_path.len - 1)
        if stripped.len == 0:
            path_is_root = true
            url_path = "index.html"
        else:
            url_path = stripped

    var file_path = path_ops.join(serve_dir, url_path)
    defer file_path.release()

    let content_result = fs.read_bytes(file_path.as_str())
    match content_result:
        Result.success as content_ok:
            var content = content_ok.value
            defer content.release()

            let mime = guess_mime(file_path.as_str())
            await send_file_response(conn, 200, "OK", mime, content.as_span(), method.equal("HEAD"))
        Result.failure:
            if fs.is_directory(file_path.as_str()):
                await serve_directory_index(conn, file_path.as_str(), url_prefix, method.equal("HEAD"))
            else if path_is_root:
                await serve_directory_index(conn, serve_dir, url_prefix, method.equal("HEAD"))
            else:
                await send_error(conn, 404, "Not Found")


function find_byte_from_str(data: str, target: ubyte, start: ptr_uint) -> ptr_uint:
    var index = start
    while index < data.len:
        if data.byte_at(index) == target:
            return index
        index += 1
    return data.len


async function main(args: span[str]) -> void:
    var port = parse_port(args)
    if port <= 0:
        port = DEFAULT_PORT

    var serve_dir = parse_serve_dir(args)

    var port_str = fmt.to_string_int(port)
    defer port_str.release()

    stdio.print("Serving HTTP on http://0.0.0.0:%d (dir: %s)\n", port, serve_dir)

    let address = net.ipv4("0.0.0.0", port) else:
        stdio.print("failed to resolve address\n")
        return

    var listener = net.listen(address, 128) else:
        stdio.print("failed to listen\n")
        return

    defer listener.release()

    while true:
        let accept_result = await listener.accept()
        match accept_result:
            Result.failure as accept_error:
                var err = accept_error.error
                stdio.print("accept error: %s\n", err.message.as_str())
                err.release()
            Result.success as stream_ok:
                await handle_connection(stream_ok.value, serve_dir)

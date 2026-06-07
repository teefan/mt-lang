import std.async as aio
import std.bytes as bytes
import std.fmt as fmt
import std.fs as fs
import std.net as net
import std.path as path_ops
import std.stdio as stdio
import std.str as text
import std.string as string
import std.vec as vec


const DEFAULT_PORT: int = 8080
const DEFAULT_BACKLOG: int = 128


async function main(args: span[str]) -> void:
    var port = DEFAULT_PORT
    var serve_dir = "."

    if args.len > 0:
        serve_dir = unsafe: read(args.data)

    var port_str = fmt.to_string_int(port)
    defer port_str.release()

    stdio.print("Serving HTTP on 0.0.0.0 port %s (dir: %s)\n", port_str.as_str(), serve_dir)

    let addr_result = await net.resolve_first("0.0.0.0", port_str.as_str())
    match addr_result:
        Result.failure as payload:
            stdio.print("failed to resolve address\n")
            payload.error.release()
            return
        Result.success as ok:
            var addr = ok.value
            defer addr.release()

            let listen_result = net.listen(addr, DEFAULT_BACKLOG)
            match listen_result:
                Result.failure as payload:
                    stdio.print("failed to listen\n")
                    payload.error.release()
                    return
                Result.success as listen_ok:
                    var listener = listen_ok.value
                    defer listener.release()

                    while true:
                        let accept_result = await listener.accept()
                        match accept_result:
                            Result.failure as payload:
                                stdio.print("accept error\n")
                                payload.error.release()
                            Result.success as stream_ok:
                                var stream = stream_ok.value
                                defer stream.release()
                                await handle_connection(stream, serve_dir)


async function handle_connection(stream: net.TcpStream, serve_dir: str) -> void:

    var buffer = vec.Vec[ubyte].with_capacity(4096)
    defer buffer.release()

    var headers_done = false
    while not headers_done:
        let chunk_result = await stream.read_once(4096)
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
        await send_error(stream, 400, "Bad Request")
        return

    let first_line_end = find_byte(header_text, 10)
    var request_line = header_text.slice(0, first_line_end)
    if request_line.ends_with("\r"):
        request_line = header_text.slice(0, request_line.len - 1)

    let method_end = find_byte(request_line, 32)
    if method_end >= request_line.len:
        await send_error(stream, 400, "Bad Request")
        return

    let method = request_line.slice(0, method_end)

    var path_start = method_end + 1
    while path_start < request_line.len and request_line.byte_at(path_start) == 32:
        path_start += 1

    let path_end = find_byte_from(request_line, 32, path_start)
    var url_path = request_line.slice(path_start, path_end - path_start)

    if method != "GET" and method != "HEAD":
        await send_error(stream, 405, "Method Not Allowed")
        return

    if url_path.starts_with("/"):
        var stripped = url_path.slice(1, url_path.len - 1)
        if stripped.len == 0:
            url_path = "index.html"
        else:
            url_path = stripped

    var file_path = path_ops.join(serve_dir, url_path)
    defer file_path.release()

    let content_result = fs.read_bytes(file_path.as_str())
    match content_result:
        Result.failure:
            await send_error(stream, 404, "Not Found")
            return
        Result.success as content_ok:
            var content = content_ok.value
            defer content.release()

            let mime = guess_mime(file_path.as_str())
            await send_response(
                stream,
                200,
                "OK",
                mime,
                content.as_span(),
                method == "HEAD"
            )


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


function guess_mime(file_path: str) -> str:
    let ext = path_ops.extension(file_path)
    match ext:
        Option.none:
            return "application/octet-stream"
        Option.some as e:
            if e.value == ".html" or e.value == ".htm":
                return "text/html"
            if e.value == ".css":
                return "text/css"
            if e.value == ".js":
                return "application/javascript"
            if e.value == ".json":
                return "application/json"
            if e.value == ".md":
                return "text/markdown"
            if e.value == ".png":
                return "image/png"
            if e.value == ".jpg" or e.value == ".jpeg":
                return "image/jpeg"
            if e.value == ".gif":
                return "image/gif"
            if e.value == ".svg":
                return "image/svg+xml"
            if e.value == ".ico":
                return "image/x-icon"
            if e.value == ".wasm":
                return "application/wasm"
            if e.value == ".txt":
                return "text/plain"
            if e.value == ".xml":
                return "application/xml"
            if e.value == ".pdf":
                return "application/pdf"
            if e.value == ".mp3":
                return "audio/mpeg"
            if e.value == ".mp4":
                return "video/mp4"
            return "application/octet-stream"


async function send_error(stream: net.TcpStream, code: int, message: str) -> void:
    var code_str = fmt.to_string_int(code)
    defer code_str.release()

    let body = f"<html><body><h1>#{code_str.as_str()} #{message}</h1></body></html>\r\n"
    var body_len_str = fmt.to_string_ptr_uint(body.len)
    defer body_len_str.release()

    let header = f"HTTP/1.1 #{code_str.as_str()} #{message}\r\nContent-Type: text/html\r\nContent-Length: #{body_len_str.as_str()}\r\nConnection: close\r\n\r\n"
    await stream.write_bytes(text.as_byte_span(header))
    await stream.write_bytes(text.as_byte_span(body))


async function send_response(
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

    let header = f"HTTP/1.1 #{code_str.as_str()} #{message}\r\nContent-Type: #{content_type}\r\nContent-Length: #{body_len_str.as_str()}\r\nConnection: close\r\n\r\n"
    await stream.write_bytes(text.as_byte_span(header))

    if not head_only:
        await stream.write_bytes(body)

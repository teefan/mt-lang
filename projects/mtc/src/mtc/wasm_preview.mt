## The wasm preview HTTP server, mirroring `Run::WasmPreviewServer`
## (`lib/milk_tea/tooling/run.rb:11-208`): a tiny single-threaded static-file
## server bound to 127.0.0.1, serving one `.html` entry plus its `.js`/`.wasm`/
## `.data` sidecars with the COOP/COEP headers Emscripten's threaded runtime
## expects.  SIGINT/SIGTERM close the listener, completing any pending accept
## and letting `run` return 0 like the host's signal handler.

import std.async as aio
import std.async.libuv_runtime as aio_backend
import std.bytes as bytes
import std.c.libuv as libuv_c
import std.env as env
import std.fmt as fmt
import std.fs as fs
import std.libuv as libuv
import std.mem.heap as heap
import std.net as net
import std.path as path_ops
import std.process as process
import std.stdio as stdio
import std.str as text
import std.string as string
import std.terminal as terminal
import std.vec as vec


struct PreviewState:
    listener: ptr[net.TcpListener]?


## The signal callback and the coroutine run on the same libuv thread; a module
## flag avoids reading through the state pointer in the loop condition.
var preview_stop: bool = false


function signal_as_handle(handle: ptr[libuv.uv_signal_t]) -> ptr[libuv.uv_handle_t]:
    return unsafe: ptr[libuv.uv_handle_t]<-handle


## Close the listener from the libuv signal callback.  This completes a pending
## accept with a "listener released" failure, so the coroutine resumes and the
## serve loop exits.
function preview_signal_cb(handle: ptr[libuv.uv_signal_t], _signum: int) -> void:
    let data = libuv.handle_get_data(signal_as_handle(handle))
    if data == null:
        return

    preview_stop = true
    let state = unsafe: ptr[PreviewState]<-data
    unsafe:
        let listener = read(state).listener
        if listener != null:
            var released = read(listener)
            released.release()
            read(state).listener = null


function install_signal(loop: ptr[libuv.uv_loop_t], signum: int, state: ptr[PreviewState]) -> void:
    let size = libuv.handle_size(libuv_c.uv_handle_type.UV_SIGNAL)
    let raw = heap.must_alloc_zeroed_bytes(1, size)
    let handle = unsafe: ptr[libuv.uv_signal_t]<-raw
    if libuv.signal_init(loop, handle) != 0:
        return
    libuv.handle_set_data(signal_as_handle(handle), unsafe: ptr[void]<-state)
    let _ = libuv.signal_start(handle, preview_signal_cb, signum)


## Serve `root_dir` on 127.0.0.1:`port` (0 picks an ephemeral port).  Blocks
## until SIGINT/SIGTERM (or a listener failure).
public function serve_preview(root_dir: str, port: int) -> int:
    return aio.with_runtime[int](
        proc(runtime: aio.Runtime) -> int: serve_with_runtime(runtime, root_dir, port)
    )


## The outer accept loop is deliberately a *sync* driver: `wait_on` polls the
## runtime for one accept at a time and `run_on_proc` drives the per-connection
## coroutine.  A CPS `while` across multiple awaits was not robust here (the
## resume state machine could spin after the first connection); keeping only
## one coroutine per request avoids that class of bug.
function serve_with_runtime(runtime: aio.Runtime, root_dir: str, port: int) -> int:
    var address = net.ipv4("127.0.0.1", port) else:
        stdio.print_line("failed to resolve wasm preview address")
        return 1
    defer: address.release()

    var listener = net.listen_on(runtime, address, 128) else:
        stdio.print_line("failed to listen for wasm preview")
        return 1

    var bound = listener.local_address() else:
        stdio.print_line("failed to read wasm preview address")
        listener.release()
        return 1
    defer: bound.release()

    let actual_port = bound.port() else:
        stdio.print_line("failed to read wasm preview port")
        listener.release()
        return 1

    var entry = default_entry(root_dir)
    defer: entry.release()

    var url = string.String.create()
    defer: url.release()
    url.append("http://127.0.0.1:")
    var port_text = fmt.to_string_int(actual_port)
    defer: port_text.release()
    url.append(port_text.as_str())
    url.push_byte('/')
    url.append(entry.as_str())

    var message = string.String.create()
    defer: message.release()
    message.append("serving ")
    message.append(url.as_str())
    message.append(" (press Ctrl-C to stop)\n")
    stdio.print_format(c"%.*s", int<-(message.len), message.data)
    let _ = terminal.flush_stdout()
    open_browser(url.as_str())

    let loop = aio_backend.runtime_loop(runtime)
    let state = heap.must_alloc_zeroed[PreviewState](1)
    unsafe:
        read(state).listener = ptr_of(listener)
    preview_stop = false
    install_signal(loop, 2, state)
    install_signal(loop, 15, state)

    while not preview_stop:
        let accepted = aio.wait_on(runtime, listener.accept())
        match accepted:
            Result.failure as failure:
                var error = failure.error
                error.release()
                break
            Result.success as stream:
                var connection = stream.value
                aio.run_on_proc(
                    runtime, proc() -> Task[void]: handle_connection(connection, root_dir)
                )
                connection.release()

    let still_open = unsafe: read(state).listener != null
    unsafe:
        read(state).listener = null
    if still_open:
        listener.release()
    return 0


async function handle_connection(connection: net.TcpStream, root_dir: str) -> void:
    var buffer = vec.Vec[ubyte].create()
    defer: buffer.release()

    var headers_done = false
    while not headers_done:
        match await connection.read_once(4096):
            Result.failure:
                return
            Result.success as chunk_result:
                var chunk = chunk_result.value
                if chunk.len == 0:
                    chunk.release()
                    return
                buffer.append_span(chunk.as_span())
                chunk.release()
                headers_done = has_header_end(buffer.as_span())
                if buffer.len() > 65536:
                    return

    let request_text = text.utf8_byte_span_as_str(buffer.as_span()) else:
        await send_text(connection, 400, "Bad Request", "bad request\n", false)
        return

    let first_line_end = preview_find_byte(request_text, 10)
    if first_line_end >= request_text.len:
        await send_text(connection, 400, "Bad Request", "bad request\n", false)
        return

    var request_line = request_text.slice(0, first_line_end)
    if request_line.ends_with("\r"):
        request_line = request_line.slice(0, request_line.len - 1)

    let method_end = preview_find_byte(request_line, 32)
    if method_end >= request_line.len:
        await send_text(connection, 400, "Bad Request", "bad request\n", false)
        return
    let method = request_line.slice(0, method_end)

    var target_start = method_end + 1
    while target_start < request_line.len and request_line.byte_at(target_start) == 32:
        target_start += 1
    let target_end = preview_find_byte_from(request_line, 32, target_start)
    var target = request_line.slice(target_start, target_end - target_start)

    if not method.equal("GET") and not method.equal("HEAD"):
        await send_text(connection, 405, "Method Not Allowed", "method not allowed\n", false)
        return

    let question = preview_find_byte(target, 63)
    if question < target.len:
        target = target.slice(0, question)

    var relative = target
    if relative.starts_with("/"):
        relative = relative.slice(1, relative.len - 1)

    if relative.len == 0:
        var default_name = default_entry(root_dir)
        defer: default_name.release()
        relative = default_name.as_str()

    if not safe_relative_path(relative):
        await send_text(connection, 404, "Not Found", "not found\n", false)
        return

    var candidate = path_ops.join(root_dir, relative)
    defer: candidate.release()

    var root_real = fs.canonicalize(root_dir) else:
        await send_text(connection, 404, "Not Found", "not found\n", false)
        return
    defer: root_real.release()

    var candidate_real = fs.canonicalize(candidate.as_str()) else:
        await send_text(connection, 404, "Not Found", "not found\n", false)
        return
    defer: candidate_real.release()

    if not path_within(candidate_real.as_str(), root_real.as_str()):
        await send_text(connection, 404, "Not Found", "not found\n", false)
        return

    match fs.read_bytes(candidate_real.as_str()):
        Result.failure:
            await send_text(connection, 404, "Not Found", "not found\n", false)
        Result.success as body_result:
            var body = body_result.value
            defer: body.release()
            let content_type = mime_type(candidate_real.as_str())
            await send_response(
                connection, 200, "OK", content_type, body.as_span(), method.equal("HEAD")
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


function preview_find_byte(data: str, value: ubyte) -> ptr_uint:
    var index: ptr_uint = 0
    while index < data.len:
        if data.byte_at(index) == value:
            return index
        index += 1
    return data.len


function preview_find_byte_from(data: str, value: ubyte, start: ptr_uint) -> ptr_uint:
    var index = start
    while index < data.len:
        if data.byte_at(index) == value:
            return index
        index += 1
    return data.len


function safe_relative_path(path: str) -> bool:
    if path.len == 0 or path.starts_with("/"):
        return false
    var start: ptr_uint = 0
    var index: ptr_uint = 0
    while index <= path.len:
        if index == path.len or path.byte_at(index) == 47:
            let segment = path.slice(start, index - start)
            if segment.equal(".."):
                return false
            start = index + 1
        index += 1
    return true


function path_within(path: str, root: str) -> bool:
    if path.equal(root):
        return true
    var prefix = string.String.from_str(root)
    defer: prefix.release()
    prefix.push_byte('/')
    return path.starts_with(prefix.as_str())


function default_entry(root_dir: str) -> string.String:
    var entries = fs.list_entries(root_dir) else:
        return string.String.from_str("index.html")
    defer: entries.release()

    var best = string.String.create()
    var index: ptr_uint = 0
    while index < entries.len():
        let name = entries.get(index) else:
            break
        if name.ends_with(".html"):
            if best.len() == 0 or name.compare(best.as_str()) < 0:
                best.release()
                best = string.String.from_str(name)
        index += 1
    if best.len() > 0:
        return best
    best.release()
    return string.String.from_str("index.html")


function mime_type(path: str) -> str:
    if path.ends_with(".html"):
        return "text/html; charset=utf-8"
    if path.ends_with(".js"):
        return "text/javascript; charset=utf-8"
    if path.ends_with(".css"):
        return "text/css; charset=utf-8"
    if path.ends_with(".json"):
        return "application/json; charset=utf-8"
    if path.ends_with(".wasm"):
        return "application/wasm"
    if path.ends_with(".wav"):
        return "audio/wav"
    if path.ends_with(".png"):
        return "image/png"
    if path.ends_with(".ppm"):
        return "image/x-portable-pixmap"
    return "application/octet-stream"


async function send_text(
    connection: net.TcpStream,
    status: int,
    message: str,
    body: str,
    head_only: bool,
) -> void:
    await send_response(
        connection, status, message, "text/plain; charset=utf-8", text.as_byte_span(body), head_only
    )


async function send_response(
    connection: net.TcpStream,
    status: int,
    message: str,
    content_type: str,
    body: span[ubyte],
    head_only: bool,
) -> void:
    var status_text = fmt.to_string_int(status)
    defer: status_text.release()
    var length_text = fmt.to_string_ptr_uint(body.len)
    defer: length_text.release()

    var header = string.String.with_capacity(256)
    defer: header.release()
    header.append("HTTP/1.1 ")
    header.append(status_text.as_str())
    header.push_byte(32)
    header.append(message)
    header.append("\r\nContent-Type: ")
    header.append(content_type)
    header.append("\r\nContent-Length: ")
    header.append(length_text.as_str())
    header.append("\r\nCache-Control: no-cache\r\n")
    header.append("Cross-Origin-Opener-Policy: same-origin\r\n")
    header.append("Cross-Origin-Embedder-Policy: require-corp\r\n")
    header.append("Connection: close\r\n\r\n")

    let _ = await connection.write_bytes(text.as_byte_span(header.as_str()))
    if not head_only and body.len > 0:
        let _ = await connection.write_bytes(body)


## The host's `Run#open_browser` (linux `xdg-open`, windows `cmd /c start`).
## Runs in the sync setup, before the accept loop, so the detached process's
## own libuv loop cannot interfere with the preview runtime.
function open_browser(url: str) -> void:
    var command = vec.Vec[str].create()
    defer: command.release()
    if env.get("OS").is_some():
        command.push("cmd")
        command.push("/c")
        command.push("start")
        command.push("")
        command.push(url)
    else:
        command.push("xdg-open")
        command.push(url)
    match process.spawn_detached(command.as_span()):
        Result.success:
            pass
        Result.failure as failure:
            var error = failure.error
            error.release()

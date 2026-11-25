## Shared static-file HTTP helpers for the wasm preview and `docs` servers:
## response rendering (COOP/COEP/no-cache/close), request-header scanning, MIME
## mapping, and the libuv SIGINT/SIGTERM stop bridge.

import std.async.libuv_runtime as aio_backend
import std.c.libuv as libuv_c
import std.fmt as fmt
import std.libuv as libuv
import std.mem.heap as heap
import std.net as net
import std.str as text
import std.string as string

## The signal callback closes the listener; the accept loop checks `stopped`.
public struct ServerState:
    listener: ptr[net.TcpListener]?

var stop_requested: bool = false


public function create_state() -> ptr[ServerState]:
    return heap.must_alloc_zeroed[ServerState](1)


public function reset_stop() -> void:
    stop_requested = false


public function should_stop() -> bool:
    return stop_requested


function signal_as_handle(handle: ptr[libuv.uv_signal_t]) -> ptr[libuv.uv_handle_t]:
    return unsafe: ptr[libuv.uv_handle_t]<-handle


function stop_signal_cb(handle: ptr[libuv.uv_signal_t], _signum: int) -> void:
    let data = libuv.handle_get_data(signal_as_handle(handle)) else:
        return

    stop_requested = true
    let state = unsafe: ptr[ServerState]<-data
    unsafe:
        let listener = read(state).listener
        if listener != null:
            var released = read(listener)
            released.release()
            read(state).listener = null


function install_signal(loop: ptr[libuv.uv_loop_t], signum: int, state: ptr[ServerState]) -> void:
    let size = libuv.handle_size(libuv_c.uv_handle_type.UV_SIGNAL)
    let raw = heap.must_alloc_zeroed_bytes(1, size)
    let handle = unsafe: ptr[libuv.uv_signal_t]<-raw
    if libuv.signal_init(loop, handle) != 0:
        return
    libuv.handle_set_data(signal_as_handle(handle), unsafe: ptr[void]<-state)
    let _ = libuv.signal_start(handle, stop_signal_cb, signum)


## Install SIGINT/SIGTERM handlers on the active runtime's loop.
public function install_stop_signals(state: ptr[ServerState]) -> void:
    let loop = aio_backend.runtime_loop(aio_backend.current_runtime_handle())
    install_signal(loop, 2, state)
    install_signal(loop, 15, state)


## Release the listener unless a signal handler already did.
public function close_listener(state: ptr[ServerState], listener: ref[net.TcpListener]) -> void:
    let still_open = unsafe: read(state).listener != null
    unsafe:
        read(state).listener = null
    if still_open:
        read(listener).release()


public function has_header_end(data: span[ubyte]) -> bool:
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


public function find_byte(data: str, value: ubyte) -> ptr_uint:
    var index: ptr_uint = 0
    while index < data.len:
        if data.byte_at(index) == value:
            return index
        index += 1
    return data.len


public function find_byte_from(data: str, value: ubyte, start: ptr_uint) -> ptr_uint:
    var index = start
    while index < data.len:
        if data.byte_at(index) == value:
            return index
        index += 1
    return data.len


public function mime_type(path: str) -> str:
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


public async function send_redirect(connection: net.TcpStream, location: str) -> void:
    var header = string.String.with_capacity(location.len + 96)
    defer: header.release()
    header.append("HTTP/1.1 302 Found\r\nLocation: ")
    header.append(location)
    header.append("\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    let _ = await connection.write_bytes(text.as_byte_span(header.as_str()))


public async function send_text(
    connection: net.TcpStream,
    status: int,
    message: str,
    body: str,
    head_only: bool,
) -> void:
    await send_response(
        connection, status, message, "text/plain; charset=utf-8", text.as_byte_span(body), head_only
    )


public async function send_response(
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

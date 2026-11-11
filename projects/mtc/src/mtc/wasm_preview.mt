## The wasm preview HTTP server, mirroring `Run::WasmPreviewServer`
## (`lib/milk_tea/tooling/run.rb:11-208`): a tiny single-threaded static-file
## server bound to 127.0.0.1, serving one `.html` entry plus its `.js`/`.wasm`/
## `.data` sidecars with the COOP/COEP headers Emscripten's threaded runtime
## expects.  SIGINT/SIGTERM close the listener, completing any pending accept
## and letting `run` return 0 like the host's signal handler.

import std.async as aio
import std.fmt as fmt
import std.fs as fs
import std.net as net
import std.path as path_ops
import std.stdio as stdio
import std.str as text
import std.string as string
import std.terminal as terminal
import std.vec as vec

import mtc.browser as browser
import mtc.http_util as http_util


## Serve `root_dir` on 127.0.0.1:`port` (0 picks an ephemeral port).  Blocks
## until SIGINT/SIGTERM (or a listener failure).
public function serve_preview(root_dir: str, port: int) -> int:
    return aio.with_runtime[int](
        proc(runtime: aio.Runtime) -> int: serve_with_runtime(runtime, root_dir, port)
    )


## The outer accept loop is deliberately a *sync* driver: `wait_on` polls the
## runtime for one accept at a time and `run_on_proc` drives the per-connection
## coroutine.  A CPS `while` across repeated awaits was not robust here (the
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
    browser.open(url.as_str())

    let state = http_util.create_state()
    unsafe:
        read(state).listener = ptr_of(listener)
    http_util.reset_stop()
    http_util.install_stop_signals(state)

    while not http_util.should_stop():
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

    http_util.close_listener(state, ref_of(listener))
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
                headers_done = http_util.has_header_end(buffer.as_span())
                if buffer.len() > 65536:
                    return

    let request_text = text.utf8_byte_span_as_str(buffer.as_span()) else:
        await http_util.send_text(connection, 400, "Bad Request", "bad request\n", false)
        return

    let first_line_end = http_util.find_byte(request_text, 10)
    if first_line_end >= request_text.len:
        await http_util.send_text(connection, 400, "Bad Request", "bad request\n", false)
        return

    var request_line = request_text.slice(0, first_line_end)
    if request_line.ends_with("\r"):
        request_line = request_line.slice(0, request_line.len - 1)

    let method_end = http_util.find_byte(request_line, 32)
    if method_end >= request_line.len:
        await http_util.send_text(connection, 400, "Bad Request", "bad request\n", false)
        return
    let method = request_line.slice(0, method_end)

    var target_start = method_end + 1
    while target_start < request_line.len and request_line.byte_at(target_start) == 32:
        target_start += 1
    let target_end = http_util.find_byte_from(request_line, 32, target_start)
    var target = request_line.slice(target_start, target_end - target_start)

    if not method.equal("GET") and not method.equal("HEAD"):
        await http_util.send_text(connection, 405, "Method Not Allowed", "method not allowed\n", false)
        return

    let question = http_util.find_byte(target, 63)
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
        await http_util.send_text(connection, 404, "Not Found", "not found\n", false)
        return

    var candidate = path_ops.join(root_dir, relative)
    defer: candidate.release()

    var root_real = fs.canonicalize(root_dir) else:
        await http_util.send_text(connection, 404, "Not Found", "not found\n", false)
        return
    defer: root_real.release()

    var candidate_real = fs.canonicalize(candidate.as_str()) else:
        await http_util.send_text(connection, 404, "Not Found", "not found\n", false)
        return
    defer: candidate_real.release()

    if not path_within(candidate_real.as_str(), root_real.as_str()):
        await http_util.send_text(connection, 404, "Not Found", "not found\n", false)
        return

    match fs.read_bytes(candidate_real.as_str()):
        Result.failure:
            await http_util.send_text(connection, 404, "Not Found", "not found\n", false)
        Result.success as body_result:
            var body = body_result.value
            defer: body.release()
            let content_type = http_util.mime_type(candidate_real.as_str())
            await http_util.send_response(
                connection, 200, "OK", content_type, body.as_span(), method.equal("HEAD")
            )


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

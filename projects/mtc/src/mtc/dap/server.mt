## DAP server — a libuv event loop that multiplexes the client stdio and the
## debuggee child process (the lldb-dap adapter joins it in lldb_backend.mt).
## Poll callbacks only append bytes to framers; request dispatch, child draining
## and event emission happen between loop turns.

import std.libuv as libuv
import std.log as log
import std.mem.heap as heap
import std.process as process
import std.str
import std.string as string
import std.vec as vec

import mtc.dap.handlers as handlers
import mtc.dap.process_backend as backend
import mtc.dap.protocol as proto
import mtc.dap.session as session
import mtc.dap.wire as wire


const POLL_STDIN: int = 1
const POLL_ADAPTER: int = 2
const TIMER_INTERVAL_MS: ptr_uint = 100


## Per-handle callback context: which stream to fill (the callbacks are
## non-capturing functions, so the state travels through the handle data).
struct PollContext:
    kind: int
    state: ptr[LoopState]


## State shared with the poll callbacks.
struct LoopState:
    stdin_framer: ptr[proto.Framer]
    adapter_framer: ptr[proto.Framer]


## Entry point.  Parses the CLI flags, then runs the event loop until the
## client disconnects or the stream ends.
public function run(args: span[str]) -> int:
    var ses = session.create()
    defer: session.release(ref_of(ses))
    configure_backend(ref_of(ses), args)

    let state = unsafe: ptr[LoopState]<-heap.must_alloc[LoopState](1)
    unsafe:
        read(state) = LoopState(
            stdin_framer = alloc_framer(0),
            adapter_framer = alloc_framer(-1),
        )
    defer: release_loop_state(state)

    let loop = create_loop()
    let stdin_watch = watch_fd(loop, 0, POLL_STDIN, state)
    let timer = create_timer(loop)

    var child = zero[process.ChildProcess]
    var has_child = false

    var running = true
    while running:
        let _ = libuv.run(loop, libuv.uv_run_mode.UV_RUN_ONCE)
        drain_client_messages(ref_of(ses), state, ref_of(child), ref_of(has_child))
        drain_child(ref_of(ses), ref_of(child), ref_of(has_child))
        if ses.should_exit:
            running = false

    shutdown(ref_of(ses), ref_of(child), ref_of(has_child), stdin_watch, timer)
    return 0


## Parse the adapter flags into the session: `--backend` and `--adapter-path`
## (the VS Code extension sends both; `--adapter-path` precedes no other
## handling) and tolerate `--log-level`.
function configure_backend(ses: ref[session.Session], args: span[str]) -> void:
    var i: ptr_uint = 0
    while i < args.len:
        let arg = args[i]
        if arg.starts_with("--backend="):
            ses.backend_kind.release()
            ses.backend_kind = string.String.from_str(arg.slice(10, arg.len - 10))
        else if arg.equal("--backend") and i + 1 < args.len:
            ses.backend_kind.release()
            ses.backend_kind = string.String.from_str(args[i + 1])
            i += 1
        else if arg.starts_with("--adapter-path="):
            ses.adapter_path.release()
            ses.adapter_path = string.String.from_str(arg.slice(15, arg.len - 15))
        else if arg.equal("--adapter-path") and i + 1 < args.len:
            ses.adapter_path.release()
            ses.adapter_path = string.String.from_str(args[i + 1])
            i += 1
        else if arg.starts_with("--log-level="):
            pass
        else if arg.equal("--log-level") and i + 1 < args.len:
            i += 1
        i += 1

    if ses.backend_kind.as_str().equal("process"):
        return
    if ses.backend_kind.as_str().equal("lldb-dap"):
        var note = string.String.create()
        note.append("dap: the lldb-dap backend is not implemented yet; running the process backend")
        log.warn(note.as_str())
        note.release()
        return
    var unknown = string.String.create()
    unknown.append("dap: unsupported backend '")
    unknown.append(ses.backend_kind.as_str())
    unknown.append("'; running the process backend")
    log.warn(unknown.as_str())
    unknown.release()


## Allocate a framer for `fd` (heap-owned: the callbacks reach it through
## `LoopState`).
function alloc_framer(fd: int) -> ptr[proto.Framer]:
    let framer = heap.must_alloc[proto.Framer](1)
    unsafe:
        read(framer) = proto.framer_create(fd)
    return framer


function release_loop_state(state: ptr[LoopState]) -> void:
    unsafe:
        proto.framer_release(ref_of(read(read(state).stdin_framer)))
        proto.framer_release(ref_of(read(read(state).adapter_framer)))
        heap.release(read(state).stdin_framer)
        heap.release(read(state).adapter_framer)
    heap.release(state)


function create_loop() -> ptr[libuv.uv_loop_t]:
    let loop_size = libuv.loop_size()
    let loop = unsafe: ptr[libuv.uv_loop_t]<-heap.must_alloc_zeroed_bytes(1, loop_size)
    let status = libuv.loop_init(loop)
    if status != 0:
        fatal(c"dap: uv_loop_init failed")
    return loop


## Register a readable/disconnect poll handle for `fd`.
function watch_fd(loop: ptr[libuv.uv_loop_t], fd: int, kind: int, state: ptr[LoopState]) -> ptr[libuv.uv_poll_t]:
    let handle_size = libuv.handle_size(libuv.uv_handle_type.UV_POLL)
    let handle = unsafe: ptr[libuv.uv_poll_t]<-heap.must_alloc_zeroed_bytes(1, handle_size)
    let ctx = heap.must_alloc[PollContext](1)
    unsafe:
        read(ctx) = PollContext(kind = kind, state = state)
        libuv.handle_set_data(ptr[libuv.uv_handle_t]<-handle, ptr[void]<-ctx)
    if libuv.poll_init(loop, handle, fd) != 0:
        fatal(c"dap: uv_poll_init failed")
    let events = int<-(libuv.uv_poll_event.UV_READABLE | libuv.uv_poll_event.UV_DISCONNECT)
    if libuv.poll_start(handle, events, poll_callback) != 0:
        fatal(c"dap: uv_poll_start failed")
    return handle


## Poll callback: append available bytes to the stream's framer.
function poll_callback(handle: ptr[libuv.uv_poll_t], status: int, events: int) -> void:
    if status != 0:
        return
    let raw = libuv.handle_get_data(unsafe: ptr[libuv.uv_handle_t]<-handle) else:
        return
    let ctx = unsafe: ptr[PollContext]<-raw
    unsafe:
        let kind = read(ctx).kind
        if kind == POLL_STDIN:
            let framer = read(read(ctx).state).stdin_framer
            proto.framer_fill(ref_of(read(framer)))
        else if kind == POLL_ADAPTER:
            let framer = read(read(ctx).state).adapter_framer
            proto.framer_fill(ref_of(read(framer)))


## A repeating wake-up timer: the loop drains child output and deadlines on
## every turn, including when the client is idle.
function create_timer(loop: ptr[libuv.uv_loop_t]) -> ptr[libuv.uv_timer_t]:
    let handle_size = libuv.handle_size(libuv.uv_handle_type.UV_TIMER)
    let handle = unsafe: ptr[libuv.uv_timer_t]<-heap.must_alloc_zeroed_bytes(1, handle_size)
    if libuv.timer_init(loop, handle) != 0:
        fatal(c"dap: uv_timer_init failed")
    if libuv.timer_start(handle, timer_callback, TIMER_INTERVAL_MS, TIMER_INTERVAL_MS) != 0:
        fatal(c"dap: uv_timer_start failed")
    return handle


function timer_callback(handle: ptr[libuv.uv_timer_t]) -> void:
    pass


## Extract and dispatch every complete client message.
function drain_client_messages(
    ses: ref[session.Session],
    state: ptr[LoopState],
    child: ref[process.ChildProcess],
    has_child: ref[bool],
) -> void:
    let framer = unsafe: read(state).stdin_framer
    while true:
        let next = proto.framer_next(unsafe: ref_of(read(framer)))
        match next:
            Option.some as payload:
                if payload.value.command.len() > 0:
                    handlers.dispatch(ses, child, has_child, payload.value.command.as_str(), payload.value)
                proto.release_message(ref_of(payload.value))
            Option.none:
                break
    unsafe:
        if read(framer).eof or read(framer).malformed:
            ses.should_exit = true


## Forward the debuggee's stdout/stderr as output events and detect its exit.
function drain_child(
    ses: ref[session.Session],
    child: ref[process.ChildProcess],
    has_child: ref[bool],
) -> void:
    unsafe:
        if not read(has_child):
            return

    var more = true
    while more:
        var out_text = backend.poll_stdout(child, 0)
        if out_text.len() > 0:
            let seq = ses.reserve_seq()
            backend.write_output_event(seq, "stdout", out_text.as_str())
            out_text.release()
        else:
            out_text.release()
            more = false

    more = true
    while more:
        var err_text = backend.poll_stderr(child, 0)
        if err_text.len() > 0:
            let seq = ses.reserve_seq()
            backend.write_output_event(seq, "stderr", err_text.as_str())
            err_text.release()
        else:
            err_text.release()
            more = false

    match child.try_wait():
        Result.success as payload:
            match payload.value:
                Option.some as status:
                    let code = status.value.normalized_code()
                    ses.terminated = true
                    let tseq = ses.reserve_seq()
                    wire.write_event(tseq, "terminated", "{}")
                    var exit_body = string.String.create()
                    exit_body.append("{\"exitCode\":")
                    exit_body.append_format(f"#{code}")
                    exit_body.append("}")
                    let eseq = ses.reserve_seq()
                    wire.write_event(eseq, "exited", exit_body.as_str())
                    exit_body.release()
                    child.release()
                    unsafe: read(has_child) = false
                Option.none:
                    pass
        Result.failure:
            pass


## Stop the debuggee (if any), remove temp build dirs, and stop the handles.
function shutdown(
    ses: ref[session.Session],
    child: ref[process.ChildProcess],
    has_child: ref[bool],
    stdin_watch: ptr[libuv.uv_poll_t],
    timer: ptr[libuv.uv_timer_t],
) -> void:
    unsafe:
        if read(has_child):
            let _ = read(child).kill(handlers.SIGNAL_TERM)
            read(child).release()
            read(has_child) = false
    ses.cleanup_tmp_dirs()
    let _ = libuv.poll_stop(stdin_watch)
    let _ = libuv.timer_stop(timer)

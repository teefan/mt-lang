## DAP server — a libuv event loop that multiplexes the client stdio and the
## debuggee child process (the lldb-dap adapter joins it in lldb.mt).
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
import mtc.dap.lldb_backend as lldb
import mtc.dap.lldb_policy as lldb_policy
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
    backend: ptr[lldb.Backend]


## Entry point.  Parses the CLI flags, then runs the event loop until the
## client disconnects or the stream ends.
public function run(args: span[str]) -> int:
    var ses = session.create()
    defer: session.release(ref_of(ses))
    configure_backend(ref_of(ses), args)

    let state = unsafe: ptr[LoopState]<-heap.must_alloc[LoopState](1)
    let backend_ptr = heap.must_alloc[lldb.Backend](1)
    unsafe:
        read(backend_ptr) = lldb.create()
        read(state) = LoopState(
            stdin_framer = alloc_framer(0),
            backend = backend_ptr,
        )
    defer: release_loop_state(state)
    defer: release_backend(backend_ptr)

    let loop = create_loop()
    let stdin_watch_opt = watch_fd(loop, 0, POLL_STDIN, state)
    let stdin_watch = stdin_watch_opt else:
        # A non-pollable stdin (a regular file, /dev/null, or a closed stream):
        # the host's blocking reader sees EOF and exits cleanly, so an adapter
        # launched by hand or from a test harness must not abort.
        return 0
    let timer = create_timer(loop)

    var child = zero[process.ChildProcess]
    var has_child = false
    var adapter_watch: ptr[libuv.uv_poll_t]? = null

    var running = true
    while running:
        let _ = libuv.run(loop, libuv.uv_run_mode.UV_RUN_ONCE)
        let backend_ref = unsafe: ref_of(read(backend_ptr))
        if adapter_watch == null and backend_ref.running:
            if backend_ref.framer != null:
                match watch_fd(loop, backend_ref.child.stdout_fd, POLL_ADAPTER, state):
                    Option.some as adapter_handle:
                        adapter_watch = adapter_handle.value
                    Option.none:
                        adapter_watch = null
        drain_client_messages(ref_of(ses), state, backend_ref, ref_of(child), ref_of(has_child))
        lldb_policy.pump(ref_of(ses), backend_ref)
        drain_child(ref_of(ses), ref_of(child), ref_of(has_child))
        if ses.should_exit:
            running = false

    shutdown(ref_of(ses), backend_ptr, ref_of(child), ref_of(has_child), stdin_watch, timer, adapter_watch)
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

    if ses.backend_kind.as_str().equal("process") or ses.backend_kind.as_str().equal("lldb-dap"):
        return
    var unknown = string.String.create()
    unknown.append("dap: unsupported backend '")
    unknown.append(ses.backend_kind.as_str())
    unknown.append("'; running the process backend")
    log.debug(unknown.as_str())
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
        heap.release(read(state).stdin_framer)
    heap.release(state)


function release_backend(backend_ptr: ptr[lldb.Backend]) -> void:
    lldb.release(unsafe: ref_of(read(backend_ptr)))
    heap.release(backend_ptr)


function create_loop() -> ptr[libuv.uv_loop_t]:
    let loop_size = libuv.loop_size()
    let loop = unsafe: ptr[libuv.uv_loop_t]<-heap.must_alloc_zeroed_bytes(1, loop_size)
    let status = libuv.loop_init(loop)
    if status != 0:
        fatal(c"dap: uv_loop_init failed")
    return loop


## Register a readable/disconnect poll handle for `fd`.
function watch_fd(loop: ptr[libuv.uv_loop_t], fd: int, kind: int, state: ptr[LoopState]) -> Option[ptr[libuv.uv_poll_t]]:
    let handle_size = libuv.handle_size(libuv.uv_handle_type.UV_POLL)
    let handle = unsafe: ptr[libuv.uv_poll_t]<-heap.must_alloc_zeroed_bytes(1, handle_size)
    let ctx = heap.must_alloc[PollContext](1)
    unsafe:
        read(ctx) = PollContext(kind = kind, state = state)
        libuv.handle_set_data(ptr[libuv.uv_handle_t]<-handle, ptr[void]<-ctx)
    if libuv.poll_init(loop, handle, fd) != 0:
        # Not pollable with this backend (a regular file or a closed
        # descriptor): report the stream as absent and let the caller decide.
        heap.release(ctx)
        heap.release(handle)
        return Option[ptr[libuv.uv_poll_t]].none
    let events = int<-(libuv.uv_poll_event.UV_READABLE | libuv.uv_poll_event.UV_DISCONNECT)
    if libuv.poll_start(handle, events, poll_callback) != 0:
        fatal(c"dap: uv_poll_start failed")
    return Option[ptr[libuv.uv_poll_t]].some(value = handle)


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
            let backend_ptr = read(read(ctx).state).backend
            let framer = read(backend_ptr).framer
            if framer != null:
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
    lldb_backend_ref: ref[lldb.Backend],
    child: ref[process.ChildProcess],
    has_child: ref[bool],
) -> void:
    let framer = unsafe: read(state).stdin_framer
    while true:
        let next = proto.framer_next(unsafe: ref_of(read(framer)))
        match next:
            Option.some as payload:
                if payload.value.msg_type.as_str().equal("response"):
                    lldb_policy.handle_client_response(ses, lldb_backend_ref, payload.value)
                else if payload.value.command.len() > 0:
                    handlers.dispatch(ses, lldb_backend_ref, child, has_child, payload.value.command.as_str(), payload.value)
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


## Stop the debuggee and adapter (if any), remove temp build dirs, and stop the
## handles.
function shutdown(
    ses: ref[session.Session],
    backend_ptr: ptr[lldb.Backend],
    child: ref[process.ChildProcess],
    has_child: ref[bool],
    stdin_watch: ptr[libuv.uv_poll_t],
    timer: ptr[libuv.uv_timer_t],
    adapter_watch: ptr[libuv.uv_poll_t]?,
) -> void:
    let backend_ref = unsafe: ref_of(read(backend_ptr))
    lldb_policy.stop(ses, backend_ref)
    unsafe:
        if read(has_child):
            let _ = read(child).kill(handlers.SIGNAL_TERM)
            read(child).release()
            read(has_child) = false
    ses.cleanup_tmp_dirs()
    let _ = libuv.poll_stop(stdin_watch)
    let _ = libuv.timer_stop(timer)
    if adapter_watch != null:
        let _ = libuv.poll_stop(adapter_watch)

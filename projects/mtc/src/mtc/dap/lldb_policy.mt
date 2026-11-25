## lldb-dap bridge policy — the DAP handshake over lldb_backend.mt's transport:
## client initialize/launch/attach/configurationDone, adapter event handling
## (with the SIGSTOP pause rewrite and continued-event deduplication), reverse
## requests, timeouts and shutdown.  Ports `dap/server/lldb_backend.rb` plus the
## transport half's response routing from `dap/lldb_dap_backend.rb`.

import std.fs as fs_mod
import std.json as json
import std.path as path_ops
import std.process as process
import std.str
import std.string as string
import std.time as time
import std.vec as vec

import mtc.debug_map as debug_map
import mtc.dap.lldb_backend as lldb
import mtc.dap.protocol as proto
import mtc.dap.session as session
import mtc.dap.utilities as util
import mtc.dap.wire as wire

const REQUEST_TIMEOUT_SECONDS: ptr_uint = 5
const REVERSE_TIMEOUT_SECONDS: ptr_uint = 15


## Whether the session is talking to lldb-dap.
public function active(ses: ref[session.Session]) -> bool:
    return ses.backend_kind.as_str().equal("lldb-dap")


## Start the adapter and ask it to initialize, deferring the client's
## initialize response until the adapter answers.
public function initialize_backend(
    ses: ref[session.Session],
    backend: ref[lldb.Backend],
    seq: ptr_uint,
    req_seq: ptr_uint,
    arguments: json.Value,
) -> void:
    if not backend.running:
        var command = adapter_command(ses, arguments)
        defer: command.release()
        var argv = command_argv(ref_of(command))
        defer: argv.release()
        if not lldb.start(backend, argv.as_span()):
            wire.write_error(seq, req_seq, "lldb-dap adapter failed to start")
            return

    if backend.initialized:
        var caps = merged_capabilities(backend)
        defer: caps.release()
        wire.write_response_command(seq, req_seq, "initialize", caps.as_str())
        let event_seq = ses.reserve_seq()
        wire.write_event(event_seq, "initialized", "")
        return

    var init_args = initialize_arguments(arguments)
    defer: init_args.release()
    let _ = lldb.send(
        backend,
        "initialize",
        init_args.as_str(),
        req_seq,
        lldb.KIND_CLIENT_INIT,
        deadline_after(REQUEST_TIMEOUT_SECONDS),
    )


## Launch/attach against lldb-dap: start the adapter if needed, forward the
## start request, and write the client's response when the adapter answers.
public function start_debugging(
    ses: ref[session.Session],
    backend: ref[lldb.Backend],
    seq: ptr_uint,
    req_seq: ptr_uint,
    command: str,
    arguments: json.Value,
    runnable_path: str,
    stop_on_entry: bool,
) -> void:
    backend.stop_on_entry = stop_on_entry
    backend.auto_continue_after_config = command.equal("launch") and not stop_on_entry
    backend.has_stopped_thread = false
    backend.has_continued_signature = false
    load_debug_map(ses, runnable_path)

    if not backend.running:
        var adapter = adapter_command(ses, arguments)
        defer: adapter.release()
        var argv = command_argv(ref_of(adapter))
        defer: argv.release()
        if not lldb.start(backend, argv.as_span()):
            wire.write_error(seq, req_seq, "lldb-dap adapter failed to start")
            return

    var launch_args = backend_start_arguments(command, arguments, runnable_path)
    defer: launch_args.release()

    if not backend.initialized:
        backend.has_pending_start = true
        backend.pending_start_client_seq = req_seq
        backend.pending_start_command.assign(command)
        backend.pending_start_arguments.assign(launch_args.as_str())
        var init_args = initialize_arguments(arguments)
        defer: init_args.release()
        let _ = lldb.send(
            backend,
            "initialize",
            init_args.as_str(),
            req_seq,
            lldb.KIND_START_INIT,
            deadline_after(REQUEST_TIMEOUT_SECONDS),
        )
        return

    var caps = merged_capabilities(backend)
    defer: caps.release()
    let caps_seq = ses.reserve_seq()
    wire.write_event(caps_seq, "capabilities", caps.as_str())

    backend.start_pending = true
    let _ = lldb.send(
        backend,
        command,
        launch_args.as_str(),
        req_seq,
        lldb.KIND_START,
        deadline_after(REQUEST_TIMEOUT_SECONDS),
    )


## configurationDone: forward once the start request has answered.
public function configuration_done(
    ses: ref[session.Session],
    backend: ref[lldb.Backend],
    seq: ptr_uint,
    req_seq: ptr_uint,
) -> void:
    ses.configuration_done = true
    if backend.has_pending_start or (backend.start_pending and not backend.config_ready):
        backend.has_deferred_config = true
        backend.deferred_config_client_seq = req_seq
        return
    proceed_configuration(ses, backend, req_seq)


## Send a deferred configurationDone once the adapter is initialized (or the
## start request has already answered) and the launch request has been sent
## (the host's `backend_configuration_pending?` gate).
function flush_deferred_configuration(ses: ref[session.Session], backend: ref[lldb.Backend]) -> void:
    if not backend.has_deferred_config:
        return
    if backend.has_pending_start or (backend.start_pending and not backend.config_ready):
        return
    backend.has_deferred_config = false
    proceed_configuration(ses, backend, backend.deferred_config_client_seq)


## Send configurationDone to the adapter (then auto-continue when the launch
## asked for it).
function proceed_configuration(
    ses: ref[session.Session],
    backend: ref[lldb.Backend],
    client_seq: ptr_uint,
) -> void:
    if not backend.running:
        wire.write_error_command(ses.reserve_seq(), client_seq, "configurationDone", "lldb-dap backend is not running")
        return
    sync_breakpoints(ses, backend)
    let _ = lldb.send(
        backend,
        "configurationDone",
        "{}",
        client_seq,
        lldb.KIND_CONFIG_DONE,
        deadline_after(REQUEST_TIMEOUT_SECONDS),
    )


## Terminate via the adapter, with the host's disconnect fallback.
public function terminate(
    ses: ref[session.Session],
    backend: ref[lldb.Backend],
    seq: ptr_uint,
    req_seq: ptr_uint,
    arguments: json.Value,
) -> void:
    if not backend.running:
        wire.write_error(seq, req_seq, "lldb-dap backend is not running")
        return
    var args_text = render_value_text(arguments)
    defer: args_text.release()
    let _ = lldb.send(
        backend,
        "terminate",
        args_text.as_str(),
        req_seq,
        lldb.KIND_TERMINATE,
        deadline_after(REQUEST_TIMEOUT_SECONDS),
    )


## Disconnect: forward to the adapter, then stop it and exit.
public function disconnect(
    ses: ref[session.Session],
    backend: ref[lldb.Backend],
    seq: ptr_uint,
    req_seq: ptr_uint,
    arguments: json.Value,
) -> void:
    if not backend.running:
        wire.write_response(seq, req_seq, "{}")
        ses.cleanup_tmp_dirs()
        ses.should_exit = true
        return
    var args_text = render_value_text(arguments)
    defer: args_text.release()
    let _ = lldb.send(
        backend,
        "disconnect",
        args_text.as_str(),
        req_seq,
        lldb.KIND_DISCONNECT,
        deadline_after(REQUEST_TIMEOUT_SECONDS),
    )


## Forward a command the client sent straight to the adapter.
public function forward_command(
    ses: ref[session.Session],
    backend: ref[lldb.Backend],
    seq: ptr_uint,
    req_seq: ptr_uint,
    command: str,
    arguments: json.Value,
) -> void:
    if not backend.running:
        wire.write_error(seq, req_seq, "lldb-dap backend is not running")
        return
    var args_text = render_value_text(arguments)
    defer: args_text.release()
    let _ = lldb.send(
        backend,
        command,
        args_text.as_str(),
        req_seq,
        lldb.KIND_FORWARD,
        deadline_after(REQUEST_TIMEOUT_SECONDS),
    )


## Drain adapter messages and expire deadlines; called once per loop turn.
public function pump(ses: ref[session.Session], backend: ref[lldb.Backend]) -> void:
    if not backend.running:
        return

    drain_adapter_stderr(backend)

    while true:
        if not backend.running:
            return
        let framer = backend.framer
        if framer == null:
            return
        let next = proto.framer_next(unsafe: ref_of(read(framer)))
        match next:
            Option.some as payload:
                route_adapter_message(ses, backend, payload.value)
                proto.release_message(ref_of(payload.value))
            Option.none:
                break

    if not backend.running:
        return
    let framer = backend.framer
    if framer == null:
        return
    unsafe:
        if read(framer).eof or read(framer).malformed:
            fail_pending(ses, backend, "backend closed")
            clear_pending_client(backend)
            lldb.stop(backend)
            return

    expire_pendings(ses, backend)
    expire_reverse(ses, backend)


## Route one adapter message by type.
function route_adapter_message(ses: ref[session.Session], backend: ref[lldb.Backend], msg: proto.Message) -> void:
    if msg.msg_type.as_str().equal("response"):
        handle_response(ses, backend, msg)
    else if msg.msg_type.as_str().equal("event"):
        handle_event(ses, backend, msg)
    else if msg.msg_type.as_str().equal("request"):
        forward_reverse_request(ses, backend, msg)


function drain_adapter_stderr(backend: ref[lldb.Backend]) -> void:
    while true:
        match process.read_fd(backend.child.stderr_fd, 0):
            Result.success as payload:
                var data = payload.value
                let had_data = data.has_data()
                data.release()
                if not had_data:
                    return
            Result.failure as failure:
                var error = failure.error
                error.release()
                return


## One adapter response: resolve the pending request and act by kind.
function handle_response(ses: ref[session.Session], backend: ref[lldb.Backend], msg: proto.Message) -> void:
    let pending_opt = lldb.take_pending(backend, msg.request_seq)
    match pending_opt:
        Option.none:
            return
        Option.some as taken:
            var pending = taken.value
            dispatch_response(ses, backend, pending, msg)
            pending.command.release()
            pending.arguments_text.release()


function dispatch_response(
    ses: ref[session.Session],
    backend: ref[lldb.Backend],
    pending: lldb.PendingRequest,
    msg: proto.Message,
) -> void:
    var body_text = render_value_text(msg.body)
    defer: body_text.release()

    if pending.kind == lldb.KIND_CLIENT_INIT:
        if msg.success:
            backend.initialized = true
            backend.capabilities_text.assign(body_text.as_str())
            var caps = merged_capabilities(backend)
            defer: caps.release()
            wire.write_response_command(ses.reserve_seq(), pending.client_seq, "initialize", caps.as_str())
            let event_seq = ses.reserve_seq()
            wire.write_event(event_seq, "initialized", "")
        else:
            var message = backend_error_message(msg)
            defer: message.release()
            wire.write_error_command(ses.reserve_seq(), pending.client_seq, "initialize", message.as_str())
        return

    if pending.kind == lldb.KIND_START_INIT:
        if msg.success:
            backend.initialized = true
            backend.capabilities_text.assign(body_text.as_str())
            var caps = merged_capabilities(backend)
            defer: caps.release()
            let caps_seq = ses.reserve_seq()
            wire.write_event(caps_seq, "capabilities", caps.as_str())
            backend.start_pending = true
            let _ = lldb.send(
                backend,
                backend.pending_start_command.as_str(),
                backend.pending_start_arguments.as_str(),
                backend.pending_start_client_seq,
                lldb.KIND_START,
                deadline_after(REQUEST_TIMEOUT_SECONDS),
            )
            backend.has_pending_start = false
            flush_deferred_configuration(ses, backend)
        else:
            backend.has_pending_start = false
            var message = backend_error_message(msg)
            defer: message.release()
            wire.write_error_command(ses.reserve_seq(), pending.client_seq, pending.command.as_str(), message.as_str())
        return

    if pending.kind == lldb.KIND_START:
        backend.start_pending = false
        if msg.success:
            wire.write_response_command(
                ses.reserve_seq(),
                pending.client_seq,
                pending.command.as_str(),
                body_text.as_str()
            )
        else:
            var message = backend_error_message(msg)
            defer: message.release()
            wire.write_error_command(ses.reserve_seq(), pending.client_seq, pending.command.as_str(), message.as_str())
        flush_deferred_configuration(ses, backend)
        return

    if pending.kind == lldb.KIND_CONFIG_DONE:
        if not msg.success:
            var message = backend_error_message(msg)
            defer: message.release()
            wire.write_error_command(ses.reserve_seq(), pending.client_seq, "configurationDone", message.as_str())
            return
        if backend.auto_continue_after_config:
            backend.auto_continue_after_config = false
            var continue_args = continue_arguments(backend)
            defer: continue_args.release()
            let _ = lldb.send(
                backend,
                "continue",
                continue_args.as_str(),
                pending.client_seq,
                lldb.KIND_AUTO_CONTINUE,
                deadline_after(REQUEST_TIMEOUT_SECONDS),
            )
            return
        wire.write_response_command(ses.reserve_seq(), pending.client_seq, "configurationDone", body_text.as_str())
        return

    if pending.kind == lldb.KIND_AUTO_CONTINUE:
        if msg.success:
            wire.write_response_command(ses.reserve_seq(), pending.client_seq, "configurationDone", body_text.as_str())
        else:
            var message = backend_error_message(msg)
            defer: message.release()
            wire.write_error_command(ses.reserve_seq(), pending.client_seq, "configurationDone", message.as_str())
        return

    if pending.kind == lldb.KIND_FORWARD:
        if msg.success:
            rewrite_forward_response(ses, pending, ref_of(body_text))
            wire.write_response_command(
                ses.reserve_seq(),
                pending.client_seq,
                pending.command.as_str(),
                body_text.as_str()
            )
        else:
            var message = backend_error_message(msg)
            defer: message.release()
            wire.write_error_command(ses.reserve_seq(), pending.client_seq, pending.command.as_str(), message.as_str())
        return

    if pending.kind == lldb.KIND_SYNC_BREAKPOINTS:
        if msg.success:
            emit_breakpoint_changes(ses, pending, msg)
        return

    if pending.kind == lldb.KIND_PAUSE_STACK:
        var diagnostic = pause_diagnostic_text(pending.arg_a, msg)
        defer: diagnostic.release()
        var body = string.String.create()
        defer: body.release()
        body.append("{\"category\":\"console\",\"output\":\"")
        proto.append_escaped(ref_of(body), diagnostic.as_str())
        body.append("\\n\"}")
        wire.write_event(ses.reserve_seq(), "output", body.as_str())
        return

    if pending.kind == lldb.KIND_MODULES:
        if msg.success:
            load_debug_map_from_modules(ses, msg.body)
        if backend.has_deferred_stack:
            backend.has_deferred_stack = false
            let deferred_args = backend.deferred_stack_arguments.as_str()
            let deferred_seq = backend.deferred_stack_client_seq
            let _ = lldb.send(
                backend,
                "stackTrace",
                deferred_args,
                deferred_seq,
                lldb.KIND_FORWARD,
                deadline_after(REQUEST_TIMEOUT_SECONDS),
            )
        return

    if pending.kind == lldb.KIND_TERMINATE:
        if msg.success:
            wire.write_response_command(ses.reserve_seq(), pending.client_seq, "terminate", body_text.as_str())
            return
        var message = backend_error_message(msg)
        if terminate_unsupported(message.as_str()):
            message.release()
            var args_text = string.String.from_str("{}")
            defer: args_text.release()
            let _ = lldb.send(
                backend,
                "disconnect",
                args_text.as_str(),
                pending.client_seq,
                lldb.KIND_DISCONNECT,
                deadline_after(REQUEST_TIMEOUT_SECONDS),
            )
            return
        defer: message.release()
        wire.write_error_command(ses.reserve_seq(), pending.client_seq, "terminate", message.as_str())
        return

    if pending.kind == lldb.KIND_DISCONNECT:
        if msg.success:
            wire.write_response_command(ses.reserve_seq(), pending.client_seq, "disconnect", body_text.as_str())
        else:
            var message = backend_error_message(msg)
            defer: message.release()
            wire.write_error_command(ses.reserve_seq(), pending.client_seq, "disconnect", message.as_str())
        finalize_disconnect(ses, backend)
        return


## Stop the adapter, clean the temp builds and exit the server.
function finalize_disconnect(ses: ref[session.Session], backend: ref[lldb.Backend]) -> void:
    fail_pending(ses, backend, "backend closed")
    clear_pending_client(backend)
    lldb.stop(backend)
    ses.cleanup_tmp_dirs()
    ses.should_exit = true


## One adapter event: state bookkeeping, rewriting and forwarding.
function handle_event(ses: ref[session.Session], backend: ref[lldb.Backend], msg: proto.Message) -> void:
    let event_name = msg.evt.as_str()

    if event_name.equal("initialized"):
        backend.config_ready = true
        flush_deferred_configuration(ses, backend)
        return

    if event_name.equal("stopped"):
        let paused = backend.pause_requested
        var body_text = event_body_text(msg.body)
        defer: body_text.release()
        if backend.pause_requested:
            var rewritten = rewrite_stopped_body(msg.body)
            if rewritten.len() > 0:
                body_text.release()
                body_text = rewritten
            else:
                rewritten.release()
        backend.has_stopped_thread = false
        match number_field(msg.body, "threadId"):
            Option.some as thread_id:
                backend.stopped_thread_id = thread_id.value
                backend.has_stopped_thread = true
            Option.none:
                pass
        backend.pause_requested = false
        backend.has_continued_signature = false
        let seq = ses.reserve_seq()
        wire.write_event(seq, "stopped", body_text.as_str())
        if paused and backend.has_stopped_thread:
            request_pause_diagnostics(ses, backend)
        return

    if event_name.equal("continued"):
        var thread_id: ptr_uint = 0
        var has_thread = false
        match number_field(msg.body, "threadId"):
            Option.some as found:
                thread_id = found.value
                has_thread = true
            Option.none:
                pass
        let all = bool_field(msg.body, "allThreadsContinued")
        if (
            backend.has_continued_signature
            and backend.last_continued_thread == thread_id
            and backend.last_continued_all == all
        ):
            return
        backend.has_continued_signature = true
        backend.last_continued_thread = thread_id
        backend.last_continued_all = all
        backend.has_stopped_thread = false
        backend.pause_requested = false
        var body_text = event_body_text(msg.body)
        defer: body_text.release()
        let seq = ses.reserve_seq()
        wire.write_event(seq, "continued", body_text.as_str())
        return

    if event_name.equal("terminated") or event_name.equal("exited"):
        backend.has_stopped_thread = false
        backend.pause_requested = false
        backend.has_continued_signature = false
        var body_text = event_body_text(msg.body)
        defer: body_text.release()
        let seq = ses.reserve_seq()
        wire.write_event(seq, event_name, body_text.as_str())
        ses.terminated = true
        return

    var body_text = event_body_text(msg.body)
    defer: body_text.release()
    let seq = ses.reserve_seq()
    wire.write_event(seq, event_name, body_text.as_str())


## Forward an adapter request to the client and remember it.
function forward_reverse_request(ses: ref[session.Session], backend: ref[lldb.Backend], msg: proto.Message) -> void:
    let client_seq = ses.reserve_seq()
    var args_text = render_value_text(msg.arguments)
    defer: args_text.release()
    wire.write_request(client_seq, msg.command.as_str(), args_text.as_str())
    backend.pending_client.push(lldb.PendingClientRequest(
        client_seq = client_seq,
        adapter_seq = msg.seq,
        command = string.String.from_str(msg.command.as_str()),
        deadline = deadline_after(REVERSE_TIMEOUT_SECONDS),
    ))


## A client response to a forwarded reverse request.
public function handle_client_response(
    ses: ref[session.Session],
    backend: ref[lldb.Backend],
    msg: proto.Message
) -> void:
    let pending_opt = lldb.take_pending_client(backend, msg.request_seq)
    match pending_opt:
        Option.none:
            return
        Option.some as taken:
            var pending = taken.value
            defer: pending.command.release()
            var body_text = render_value_text(msg.body)
            defer: body_text.release()
            lldb.send_response_to_adapter(
                backend,
                pending.adapter_seq,
                pending.command.as_str(),
                msg.success,
                body_text.as_str(),
                msg.message.as_str(),
            )


## Expire adapter requests whose deadline passed.
function expire_pendings(ses: ref[session.Session], backend: ref[lldb.Backend]) -> void:
    let now = ptr_uint<-time.now()
    var expired = vec.Vec[ptr_uint].create()
    defer: expired.release()
    var i: ptr_uint = 0
    while i < backend.pending.len():
        unsafe:
            let entry = backend.pending.get(i)
            if entry != null and read(entry).deadline <= now:
                expired.push(read(entry).adapter_seq)
        i += 1

    var k: ptr_uint = 0
    while k < expired.len():
        let seq_ptr = expired.get(k)
        if seq_ptr != null:
            match lldb.take_pending(backend, unsafe: read(seq_ptr)):
                Option.some as taken:
                    var pending = taken.value
                    if pending.client_seq != 0:
                        var message = string.String.from_str("backend request timed out: ")
                        message.append(pending.command.as_str())
                        wire.write_error_command(
                            ses.reserve_seq(),
                            pending.client_seq,
                            pending.command.as_str(),
                            message.as_str()
                        )
                        message.release()
                    if pending.kind == lldb.KIND_START:
                        backend.start_pending = false
                        flush_deferred_configuration(ses, backend)
                    pending.command.release()
                    pending.arguments_text.release()
                Option.none:
                    pass
        k += 1


## Expire client responses the adapter is waiting on.
function expire_reverse(ses: ref[session.Session], backend: ref[lldb.Backend]) -> void:
    let now = ptr_uint<-time.now()
    var expired = vec.Vec[ptr_uint].create()
    defer: expired.release()
    var i: ptr_uint = 0
    while i < backend.pending_client.len():
        unsafe:
            let entry = backend.pending_client.get(i)
            if entry != null and read(entry).deadline <= now:
                expired.push(read(entry).client_seq)
        i += 1

    var k: ptr_uint = 0
    while k < expired.len():
        let seq_ptr = expired.get(k)
        if seq_ptr != null:
            match lldb.take_pending_client(backend, unsafe: read(seq_ptr)):
                Option.some as taken:
                    var pending = taken.value
                    var message = string.String.from_str("client request timed out after 15.0s: ")
                    message.append(pending.command.as_str())
                    lldb.send_response_to_adapter(
                        backend,
                        pending.adapter_seq,
                        pending.command.as_str(),
                        false,
                        "",
                        message.as_str(),
                    )
                    message.release()
                    pending.command.release()
                Option.none:
                    pass
        k += 1


## Fail every pending adapter request with `reason` (backend closed).
function fail_pending(ses: ref[session.Session], backend: ref[lldb.Backend], reason: str) -> void:
    var i: ptr_uint = 0
    while i < backend.pending.len():
        unsafe:
            let entry = backend.pending.get(i)
            if entry != null:
                let client_seq = read(entry).client_seq
                if client_seq != 0:
                    wire.write_error_command(ses.reserve_seq(), client_seq, read(entry).command.as_str(), reason)
                read(entry).command.release()
                read(entry).arguments_text.release()
        i += 1
    backend.pending.clear()
    backend.start_pending = false
    backend.has_deferred_config = false


function clear_pending_client(backend: ref[lldb.Backend]) -> void:
    var i: ptr_uint = 0
    while i < backend.pending_client.len():
        unsafe:
            let entry = backend.pending_client.get(i)
            if entry != null:
                read(entry).command.release()
        i += 1
    backend.pending_client.clear()


## Stop everything (server shutdown).
public function stop(ses: ref[session.Session], backend: ref[lldb.Backend]) -> void:
    if backend.running:
        fail_pending(ses, backend, "backend closed")
        clear_pending_client(backend)
    lldb.stop(backend)

# =============================================================================
#  Adapter command + argument builders
# =============================================================================

## The adapter argv: the launch's `adapterPath`, else the CLI `--adapter-path`,
## else `lldb-dap` from PATH; a `.rb` path runs under ruby (the host's rule).
function adapter_command(ses: ref[session.Session], arguments: json.Value) -> vec.Vec[string.String]:
    var command = vec.Vec[string.String].create()
    var path_text = string_arg(arguments, "adapterPath")
    if path_text.len == 0 and ses.adapter_path.len() > 0:
        path_text = ses.adapter_path.as_str()
    if path_text.len == 0:
        command.push(string.String.from_str("lldb-dap"))
    else if path_text.ends_with(".rb"):
        command.push(string.String.from_str("ruby"))
        command.push(string.String.from_str(path_text))
    else:
        command.push(string.String.from_str(path_text))
    return command


## A `span[str]` argv view over an owned command vector (valid while it lives).
function command_argv(command: ref[vec.Vec[string.String]]) -> vec.Vec[str]:
    var argv = vec.Vec[str].create()
    var i: ptr_uint = 0
    while i < command.len():
        let item = command.get(i)
        if item != null:
            unsafe: argv.push(read(item).as_str())
        i += 1
    return argv


## The adapter initialize arguments: the client's merge on top of the host's
## fixed identity/path settings.
function initialize_arguments(arguments: json.Value) -> string.String:
    var result = string.String.with_capacity(256)
    result.append("{\"adapterID\":\"milk-tea\",\"clientID\":\"milk-tea\",\"linesStartAt1\":true,\"columnsStartAt1\":true,\"pathFormat\":\"path\"")
    let obj = arguments.as_object()
    if obj != null:
        unsafe:
            let entries = read(obj).entries
            var i: ptr_uint = 0
            while i < entries.len():
                let entry = entries.get(i) else:
                    break
                let key = read(entry).key.as_str()
                if not fixed_initialize_key(key):
                    result.append(",\"")
                    proto.append_escaped(ref_of(result), key)
                    result.append("\":")
                    append_rendered(ref_of(result), read(entry).value)
                i += 1
    result.append("}")
    return result


function fixed_initialize_key(key: str) -> bool:
    return key.equal("adapterID") or key.equal("clientID") or key.equal("linesStartAt1") or key.equal("columnsStartAt1") or key.equal("pathFormat")


## The start request's arguments: the client's minus client-only keys, with the
## resolved program and the forced `stopOnEntry` for launch (host
## `backend_start_arguments`).
function backend_start_arguments(command: str, arguments: json.Value, runnable_path: str) -> string.String:
    var result = string.String.with_capacity(256)
    result.append("{")
    var first = true
    let obj = arguments.as_object()
    var client_stop_on_entry = false
    var has_client_stop_on_entry = false
    if obj != null:
        unsafe:
            let entries = read(obj).entries
            var i: ptr_uint = 0
            while i < entries.len():
                let entry = entries.get(i) else:
                    break
                let key = read(entry).key.as_str()
                if key.equal("stopOnEntry"):
                    match read(entry).value.as_boolean():
                        Option.some as value:
                            client_stop_on_entry = value.value
                            has_client_stop_on_entry = true
                        Option.none:
                            pass
                else if not client_only_key(key):
                    if not first:
                        result.append(",")
                    first = false
                    result.append("\"")
                    proto.append_escaped(ref_of(result), key)
                    result.append("\":")
                    append_rendered(ref_of(result), read(entry).value)
                i += 1
    if runnable_path.len > 0:
        if not first:
            result.append(",")
        first = false
        result.append("\"program\":\"")
        proto.append_escaped(ref_of(result), runnable_path)
        result.append("\"")
    if command.equal("launch"):
        if not first:
            result.append(",")
        first = false
        result.append("\"stopOnEntry\":true")
    else if has_client_stop_on_entry:
        if not first:
            result.append(",")
        first = false
        if client_stop_on_entry:
            result.append("\"stopOnEntry\":true")
        else:
            result.append("\"stopOnEntry\":false")
    result.append("}")
    return result


function client_only_key(key: str) -> bool:
    return key.equal("backend") or key.equal("adapterPath") or key.equal("program") or key.equal("stopOnEntry")


## The auto-continue arguments: the known stopped thread when there is one.
function continue_arguments(backend: ref[lldb.Backend]) -> string.String:
    if backend.has_stopped_thread:
        var result = string.String.create()
        result.append("{\"threadId\":")
        result.append_format(f"#{backend.stopped_thread_id}")
        result.append("}")
        return result
    return string.String.from_str("{}")

# =============================================================================
#  Capabilities and body/arg helpers
# =============================================================================

## The static capabilities merged with the adapter's own initialize response
## (the host's `effective_adapter_capabilities`).
public function merged_capabilities(backend: ref[lldb.Backend]) -> string.String:
    var result = string.String.with_capacity(512)
    result.append("{")

    var static_parsed = json.parse(session.ADAPTER_CAPABILITIES) else as error:
        var parse_error = error
        parse_error.release()
        result.append("}")
        return result
    defer: json.release_value(static_parsed)

    var backend_value = json.null_value()
    defer: json.release_value(backend_value)
    var has_backend = false
    if backend.capabilities_text.len() > 0:
        match json.parse(backend.capabilities_text.as_str()):
            Result.success as payload:
                backend_value = payload.value
                has_backend = true
            Result.failure as failure:
                var parse_error = failure.error
                parse_error.release()

    let static_obj = static_parsed.as_object()
    if static_obj != null:
        unsafe:
            let entries = read(static_obj).entries
            var first = true
            var i: ptr_uint = 0
            while i < entries.len():
                let entry = entries.get(i) else:
                    break
                let key = read(entry).key.as_str()
                if not first:
                    result.append(",")
                first = false
                result.append("\"")
                proto.append_escaped(ref_of(result), key)
                result.append("\":")
                append_capability(ref_of(result), key, read(entry).value, backend, has_backend)
                i += 1

    if has_backend:
        let backend_obj = backend_value.as_object()
        if backend_obj != null:
            unsafe:
                let entries = read(backend_obj).entries
                var i: ptr_uint = 0
                while i < entries.len():
                    let entry = entries.get(i) else:
                        break
                    let key = read(entry).key.as_str()
                    var static_has = false
                    if static_obj != null:
                        unsafe: static_has = read(static_obj).get(key) != null
                    if not static_has:
                        result.append(",\"")
                        proto.append_escaped(ref_of(result), key)
                        result.append("\":")
                        append_rendered(ref_of(result), read(entry).value)
                    i += 1

    result.append("}")
    return result


## Emit one capability value: the adapter's when present (with the
## setVariable/setExpression equivalence), the static one otherwise.
function append_capability(
    target: ref[string.String],
    key: str,
    static_value: json.Value,
    backend: ref[lldb.Backend],
    has_backend: bool,
) -> void:
    if has_backend and backend.capabilities_text.len() > 0:
        var caps_parsed = json.parse(backend.capabilities_text.as_str()) else as error:
            var parse_error = error
            parse_error.release()
            append_rendered(target, static_value)
            return
        defer: json.release_value(caps_parsed)
        let caps_obj = caps_parsed.as_object()
        if caps_obj != null:
            unsafe:
                if key.equal("supportsSetVariable") and (capability_true(
                    caps_obj,
                    "supportsSetExpression"
                ) or capability_true(caps_obj, "supportsSetVariable")):
                    target.append("true")
                    return
                let value_ptr = read(caps_obj).get(key)
                if value_ptr != null:
                    append_rendered(target, read(value_ptr))
                    return
    append_rendered(target, static_value)


function capability_true(obj: ptr[json.Object], key: str) -> bool:
    unsafe:
        match read(obj).get_boolean(key):
            Option.some as value:
                return value.value
            Option.none:
                return false


## Render a JSON value for embedding; an empty string means "no body".
function render_value_text(value: json.Value) -> string.String:
    if value.is_null():
        return string.String.create()
    match json.render(value):
        Result.success as rendered:
            return rendered.value
        Result.failure as failure:
            var error = failure.error
            error.release()
            return string.String.create()


function append_rendered(target: ref[string.String], value: json.Value) -> void:
    var text = render_value_text(value)
    defer: text.release()
    if text.len() > 0:
        target.append(text.as_str())
    else:
        target.append("null")


## The event's body text (empty when the event has none).
function event_body_text(body: json.Value) -> string.String:
    return render_value_text(body)


## Rewrite a SIGSTOP exception stop into the host's pause shape; empty when the
## body is not one.
function rewrite_stopped_body(body: json.Value) -> string.String:
    let obj = body.as_object()
    if obj == null:
        return string.String.create()
    unsafe:
        let reason = read(obj).get_string("reason")
        var is_exception = false
        match reason:
            Option.some as text:
                is_exception = text.value.equal("exception")
            Option.none:
                pass
        if not is_exception:
            return string.String.create()
        var has_sigstop = false
        match read(obj).get_string("description"):
            Option.some as text:
                if text.value.contains_substring("SIGSTOP"):
                    has_sigstop = true
            Option.none:
                pass
        if not has_sigstop:
            match read(obj).get_string("text"):
                Option.some as text:
                    if text.value.contains_substring("SIGSTOP"):
                        has_sigstop = true
                Option.none:
                    pass
        if not has_sigstop:
            return string.String.create()

        var result = string.String.create()
        result.append("{")
        var first = true
        let entries = read(obj).entries
        var i: ptr_uint = 0
        while i < entries.len():
            let entry = entries.get(i) else:
                break
            let key = read(entry).key.as_str()
            if not (key.equal("reason") or key.equal("description") or key.equal("text")):
                if not first:
                    result.append(",")
                first = false
                result.append("\"")
                proto.append_escaped(ref_of(result), key)
                result.append("\":")
                append_rendered(ref_of(result), read(entry).value)
            i += 1
        if not first:
            result.append(",")
        result.append("\"reason\":\"pause\"")
        match read(obj).get_string("description"):
            Option.some:
                result.append(",\"description\":\"Paused\"")
            Option.none:
                pass
        match read(obj).get_string("text"):
            Option.some:
                result.append(",\"text\":\"Paused\"")
            Option.none:
                pass
        result.append("}")
        return result


## The host's `backend_error_message`.
function backend_error_message(msg: proto.Message) -> string.String:
    if msg.message.len() > 0:
        return string.String.from_str(msg.message.as_str())
    let obj = msg.body.as_object()
    if obj != null:
        unsafe:
            let error_obj = read(obj).get_object("error")
            if error_obj != null:
                match read(error_obj).get_string("format"):
                    Option.some as text:
                        return string.String.from_str(text.value)
                    Option.none:
                        pass
                match read(error_obj).get_string("message"):
                    Option.some as text:
                        return string.String.from_str(text.value)
                    Option.none:
                        pass
    return string.String.from_str("backend request failed")


function terminate_unsupported(message: str) -> bool:
    var lowered = lowercase_copy(message)
    defer: lowered.release()
    return lowered.as_str().contains_substring("unknown request") or lowered.as_str().contains_substring("unsupported command")


function lowercase_copy(text: str) -> string.String:
    var result = string.String.with_capacity(text.len)
    var i: ptr_uint = 0
    while i < text.len:
        let b = text.byte_at(i)
        if b >= 'A' and b <= 'Z':
            result.push_byte(b + 32)
        else:
            result.push_byte(b)
        i += 1
    return result


function deadline_after(seconds: ptr_uint) -> ptr_uint:
    return ptr_uint<-time.now() + seconds

# =============================================================================
#  Debug-map rewrites, breakpoint sync and pause diagnostics
# =============================================================================

## Load the runnable's debug-map sidecar (launch/attach); tolerant when absent.
public function load_debug_map(ses: ref[session.Session], runnable_path: str) -> void:
    ses.clear_debug_map()
    if runnable_path.len == 0:
        return
    match debug_map.load_for_binary(runnable_path):
        Option.some as loaded:
            ses.set_debug_map(loaded.value)
        Option.none:
            pass


## stackTrace forwarding with the modules fallback (the host's
## `maybe_load_debug_map_from_backend_modules`).
public function stack_trace(
    ses: ref[session.Session],
    backend: ref[lldb.Backend],
    seq: ptr_uint,
    req_seq: ptr_uint,
    arguments: json.Value,
) -> void:
    if not backend.running:
        wire.write_error(seq, req_seq, "lldb-dap backend is not running")
        return
    if ses.debug_map == null and capability_flag(backend, "supportsModulesRequest"):
        backend.has_deferred_stack = true
        backend.deferred_stack_client_seq = req_seq
        var args_text = render_value_text(arguments)
        backend.deferred_stack_arguments.assign(args_text.as_str())
        args_text.release()
        let _ = lldb.send(backend, "modules", "{}", 0, lldb.KIND_MODULES, deadline_after(REQUEST_TIMEOUT_SECONDS))
        return
    var args_text = render_value_text(arguments)
    defer: args_text.release()
    let _ = lldb.send(
        backend,
        "stackTrace",
        args_text.as_str(),
        req_seq,
        lldb.KIND_FORWARD,
        deadline_after(REQUEST_TIMEOUT_SECONDS),
    )


## setVariable with the host's fallbacks: prefer the adapter's setVariable,
## else setExpression through the scope's frame, else the host's error.
public function request_set_variable(
    ses: ref[session.Session],
    backend: ref[lldb.Backend],
    seq: ptr_uint,
    req_seq: ptr_uint,
    arguments: json.Value,
) -> void:
    if not backend.running:
        wire.write_error(seq, req_seq, "lldb-dap backend is not running")
        return

    if capability_flag(backend, "supportsSetVariable"):
        var args_text = rewrite_set_variable_arguments(ses, arguments)
        defer: args_text.release()
        let _ = lldb.send(
            backend,
            "setVariable",
            args_text.as_str(),
            req_seq,
            lldb.KIND_FORWARD,
            deadline_after(REQUEST_TIMEOUT_SECONDS)
        )
        return

    if capability_flag(backend, "supportsSetExpression"):
        let reference = number_field(arguments, "variablesReference")
        var frame_id: ptr_uint = 0
        var function_ptr: ptr[debug_map.DebugFunction]? = null
        match reference:
            Option.some as found:
                let context = ses.variable_contexts.get(found.value)
                if context != null:
                    unsafe:
                        frame_id = read(context).frame_id
                        if read(context).has_function:
                            function_ptr = read(context).function
            Option.none:
                pass
        if frame_id == 0:
            wire.write_error(seq, req_seq, "setVariable requires a scope frame context")
            return
        var name = string.String.from_str(string_arg(arguments, "name"))
        if function_ptr != null:
            let entry = source_variable_entry(ses, function_ptr, name.as_str())
            if entry != null:
                name.release()
                name = string.String.from_str(unsafe: read(entry).linkage_name.as_str())
        var value = rewrite_expression_for_frame(ses, string_arg(arguments, "value"), frame_id)
        var result = string.String.with_capacity(128)
        result.append("{\"expression\":")
        append_json_string(ref_of(result), name.as_str())
        result.append(",\"value\":")
        append_json_string(ref_of(result), value.as_str())
        result.append(",\"frameId\":")
        result.append_format(f"#{frame_id}")
        if has_key(arguments, "format"):
            result.append(",\"format\":")
            let format_obj = arguments.as_object()
            if format_obj != null:
                unsafe:
                    let format_ptr = read(format_obj).get("format")
                    if format_ptr != null:
                        append_rendered(ref_of(result), read(format_ptr))
        result.append("}")
        let _ = lldb.send_as(
            backend,
            "setExpression",
            "setVariable",
            result.as_str(),
            req_seq,
            lldb.KIND_FORWARD,
            deadline_after(REQUEST_TIMEOUT_SECONDS),
            0,
        )
        result.release()
        name.release()
        value.release()
        return

    wire.write_error(seq, req_seq, "setVariable is not supported by the lldb-dap backend")


## Request-side argument rewriting for the forwarded commands (nil when the
## command has no rewrite).
public function rewrite_request_arguments(
    ses: ref[session.Session],
    command: str,
    arguments: json.Value
) -> string.String:
    if ses.debug_map == null:
        return render_value_text(arguments)
    if command.equal("evaluate"):
        return rewrite_expression_arguments(ses, arguments, false)
    if command.equal("setExpression"):
        return rewrite_expression_arguments(ses, arguments, true)
    if command.equal("dataBreakpointInfo"):
        return rewrite_data_breakpoint_arguments(ses, arguments)
    return render_value_text(arguments)


## Collect and forward a source's breakpoints to the adapter, then emit the
## host's `breakpoint changed` events when each answer arrives.
function sync_breakpoints(ses: ref[session.Session], backend: ref[lldb.Backend]) -> void:
    if backend.breakpoints_synced:
        return
    backend.breakpoints_synced = true
    var iter = ses.breakpoints_by_source.entries()
    while iter.next():
        let entry = iter.current()
        unsafe:
            var args = build_sync_arguments(read(entry.key).as_str(), ref_of(read(entry.value)))
            let _ = lldb.send(
                backend,
                "setBreakpoints",
                args.as_str(),
                0,
                lldb.KIND_SYNC_BREAKPOINTS,
                deadline_after(REQUEST_TIMEOUT_SECONDS),
            )
            args.release()


function build_sync_arguments(source_path: str, breakpoints: ref[vec.Vec[session.Breakpoint]]) -> string.String:
    var result = string.String.with_capacity(128)
    result.append("{\"source\":{\"path\":")
    append_json_string(ref_of(result), source_path)
    result.append("},\"breakpoints\":[")
    var first = true
    var i: ptr_uint = 0
    while i < breakpoints.len():
        unsafe:
            let breakpoint = breakpoints.get(i)
            if breakpoint != null:
                if not first:
                    result.append(",")
                first = false
                result.append("{\"line\":")
                result.append_format(f"#{read(breakpoint).line}")
                result.append("}")
        i += 1
    result.append("]}")
    return result


## Emit `breakpoint changed` events for a sync answer.  The host compares the
## stored entry's symbol-keyed fields with the adapter's string-keyed answer,
## so every breakpoint whose adapter answer carries `verified` produces an
## event; the self reproduces that observable behavior.
function emit_breakpoint_changes(ses: ref[session.Session], pending: lldb.PendingRequest, msg: proto.Message) -> void:
    var source_path = source_path_from_arguments(pending.arguments_text.as_str())
    defer: source_path.release()
    if source_path.len() == 0:
        return

    var key = string.String.from_str(source_path.as_str())
    let local_ptr = ses.breakpoints_by_source.get(key)
    key.release()
    if local_ptr == null:
        return
    let local = unsafe: read(local_ptr)

    let body = msg.body.as_object()
    if body == null:
        return
    unsafe:
        let backend_bps = read(body).get_array("breakpoints")
        if backend_bps == null:
            return
        var i: ptr_uint = 0
        while i < local.len() and i < read(backend_bps).len():
            let local_bp = local.get(i)
            let backend_bp = read(backend_bps).get(i)
            if local_bp != null and backend_bp != null:
                let backend_obj = read(backend_bp).as_object()
                if backend_obj != null:
                    let backend_line = read(backend_obj).get_number("line")
                    let backend_verified = read(backend_obj).get("verified")
                    var skip = false
                    match backend_line:
                        Option.some as line_value:
                            if ptr_uint<-int<-line_value.value == read(local_bp).line and backend_verified == null:
                                skip = true
                        Option.none:
                            pass
                    if not skip:
                        var event_body = string.String.with_capacity(128)
                        event_body.append("{\"reason\":\"changed\",\"breakpoint\":{\"id\":")
                        event_body.append_format(f"#{read(local_bp).id}")
                        event_body.append(",\"verified\":")
                        var verified_json = false
                        if backend_verified != null:
                            match read(backend_verified).as_boolean():
                                Option.some as verified_value:
                                    verified_json = verified_value.value
                                Option.none:
                                    pass
                        if verified_json:
                            event_body.append("true")
                        else:
                            event_body.append("false")
                        event_body.append(",\"line\":")
                        match backend_line:
                            Option.some as line_value:
                                event_body.append_format(f"#{ptr_uint<-int<-line_value.value}")
                            Option.none:
                                event_body.append("null")
                        event_body.append(",\"source\":{\"path\":")
                        append_json_string(ref_of(event_body), source_path.as_str())
                        event_body.append("}}}")
                        wire.write_event(ses.reserve_seq(), "breakpoint", event_body.as_str())
                        event_body.release()
            i += 1


## Forward a command whose arguments the debug map rewrites first
## (evaluate / setExpression / dataBreakpointInfo).
public function forward_rewritten(
    ses: ref[session.Session],
    backend: ref[lldb.Backend],
    seq: ptr_uint,
    req_seq: ptr_uint,
    command: str,
    arguments: json.Value,
) -> void:
    if not backend.running:
        wire.write_error(seq, req_seq, "lldb-dap backend is not running")
        return
    var args_text = rewrite_request_arguments(ses, command, arguments)
    defer: args_text.release()
    let _ = lldb.send(
        backend,
        command,
        args_text.as_str(),
        req_seq,
        lldb.KIND_FORWARD,
        deadline_after(REQUEST_TIMEOUT_SECONDS),
    )


## setBreakpoints: store the request; answer locally while the start request
## is in flight (the host's `backend_configuration_pending?`), else forward.
public function set_breakpoints(
    ses: ref[session.Session],
    backend: ref[lldb.Backend],
    seq: ptr_uint,
    req_seq: ptr_uint,
    arguments: json.Value,
) -> void:
    var source_path = breakpoint_source_path(arguments)
    defer: source_path.release()
    var lines = breakpoint_lines(arguments)
    defer: lines.release()
    ses.set_source_breakpoints(source_path.as_str(), lines.as_span())

    if backend.start_pending and not backend.config_ready:
        var body = local_breakpoints_body(ses, source_path.as_str())
        defer: body.release()
        wire.write_response(seq, req_seq, body.as_str())
        return

    if not backend.running:
        wire.write_error(seq, req_seq, "lldb-dap backend is not running")
        return
    var args_text = render_value_text(arguments)
    defer: args_text.release()
    let _ = lldb.send(
        backend,
        "setBreakpoints",
        args_text.as_str(),
        req_seq,
        lldb.KIND_FORWARD,
        deadline_after(REQUEST_TIMEOUT_SECONDS),
    )


function breakpoint_source_path(arguments: json.Value) -> string.String:
    let obj = arguments.as_object()
    if obj == null:
        return string.String.create()
    unsafe:
        let source = read(obj).get_object("source")
        if source != null:
            match read(source).get_string("path"):
                Option.some as found:
                    return string.String.from_str(found.value)
                Option.none:
                    pass
    return string.String.create()


function breakpoint_lines(arguments: json.Value) -> vec.Vec[ptr_uint]:
    var lines = vec.Vec[ptr_uint].create()
    let obj = arguments.as_object()
    if obj == null:
        return lines
    unsafe:
        let bps = read(obj).get_array("breakpoints")
        if bps != null:
            var i: ptr_uint = 0
            while i < read(bps).len():
                let bp = read(bps).get(i)
                if bp != null:
                    let bp_obj = read(bp).as_object()
                    if bp_obj != null:
                        match read(bp_obj).get_number("line"):
                            Option.some as found:
                                lines.push(ptr_uint<-int<-found.value)
                            Option.none:
                                pass
                i += 1
            return lines
        let raw_lines = read(obj).get_array("lines")
        if raw_lines != null:
            var i: ptr_uint = 0
            while i < read(raw_lines).len():
                let item = read(raw_lines).get(i)
                if item != null:
                    match read(item).as_number():
                        Option.some as found:
                            lines.push(ptr_uint<-int<-found.value)
                        Option.none:
                            pass
                i += 1
    return lines


## The locally stored breakpoints as the host's pending-phase response.
function local_breakpoints_body(ses: ref[session.Session], source_path: str) -> string.String:
    var result = string.String.with_capacity(128)
    result.append("{\"breakpoints\":[")
    var key = string.String.from_str(source_path)
    let stored = ses.breakpoints_by_source.get(key)
    key.release()
    if stored != null:
        unsafe:
            let entries = read(stored)
            var first = true
            var i: ptr_uint = 0
            while i < entries.len():
                let bp = entries.get(i)
                if bp != null:
                    if not first:
                        result.append(",")
                    first = false
                    result.append("{\"id\":")
                    result.append_format(f"#{read(bp).id}")
                    result.append(",\"line\":")
                    result.append_format(f"#{read(bp).line}")
                    result.append(",\"verified\":true}")
                i += 1
    result.append("]}")
    return result


## Ask for a stack summary after a pause (the host's
## `emit_pause_diagnostic_async`).
function request_pause_diagnostics(ses: ref[session.Session], backend: ref[lldb.Backend]) -> void:
    if not backend.has_stopped_thread:
        return
    var args = string.String.with_capacity(64)
    args.append("{\"threadId\":")
    args.append_format(f"#{backend.stopped_thread_id}")
    args.append(",\"startFrame\":0,\"levels\":8}")
    let _ = lldb.send_as(
        backend,
        "stackTrace",
        "stackTrace",
        args.as_str(),
        0,
        lldb.KIND_PAUSE_STACK,
        deadline_after(REQUEST_TIMEOUT_SECONDS),
        backend.stopped_thread_id,
    )
    args.release()


## The pause summary text (the host's `pause_diagnostic_output`).
function pause_diagnostic_text(thread_id: ptr_uint, msg: proto.Message) -> string.String:
    if not msg.success:
        var message = backend_error_message(msg)
        var result = string.String.create()
        result.append("[milk-tea dap] pause focus unavailable thread=")
        result.append_format(f"#{thread_id}")
        result.append(": ")
        result.append(message.as_str())
        message.release()
        return result

    let body = msg.body.as_object()
    var frames: ptr[json.Array]? = null
    if body != null:
        unsafe: frames = read(body).get_array("stackFrames")
    if frames == null or unsafe: read(frames).len() == 0:
        var result = string.String.create()
        result.append("[milk-tea dap] pause focus unavailable thread=")
        result.append_format(f"#{thread_id}")
        result.append(": no stack frames")
        return result

    unsafe:
        let first_frame_ptr = read(frames).get(0)
        if first_frame_ptr == null:
            return string.String.create()
        let raw_frame = read(first_frame_ptr)
        var informative: ptr_uint = read(frames).len()
        var i: ptr_uint = 0
        while i < read(frames).len():
            let frame_ptr = read(frames).get(i)
            if frame_ptr != null and informative_pause_frame(read(frame_ptr)):
                informative = i
                break
            i += 1

        if informative >= read(frames).len():
            var result = string.String.create()
            result.append("[milk-tea dap] pause top frame thread=")
            result.append_format(f"#{thread_id}")
            result.append(": ")
            var summary = pause_frame_summary(raw_frame, true)
            result.append(summary.as_str())
            summary.release()
            return result

        var result = string.String.create()
        result.append("[milk-tea dap] pause focus thread=")
        result.append_format(f"#{thread_id}")
        result.append(": ")
        var count: ptr_uint = 0
        var index = informative
        while index < read(frames).len() and count < 3:
            let frame_ptr = read(frames).get(index)
            if frame_ptr != null:
                if count > 0:
                    result.append(" <- ")
                var summary = pause_frame_summary(read(frame_ptr), false)
                result.append(summary.as_str())
                summary.release()
                count += 1
            index += 1
        if informative > 0:
            result.append(" raw=")
            var summary = pause_frame_summary(raw_frame, true)
            result.append(summary.as_str())
            summary.release()
        return result


function informative_pause_frame(frame: json.Value) -> bool:
    let obj = frame.as_object()
    if obj == null:
        return false
    unsafe:
        var name = ""
        match read(obj).get_string("name"):
            Option.some as found:
                name = found.value
            Option.none:
                pass
        if name.len == 0:
            return false
        if name.starts_with("___lldb_unnamed_symbol_"):
            return false
        if name.equal("clock_nanosleep") or name.equal("__nanosleep") or name.equal("nanosleep"):
            return false

        var source_path = ""
        let source = read(obj).get_object("source")
        if source != null:
            match read(source).get_string("path"):
                Option.some as found:
                    source_path = found.value
                Option.none:
                    pass
        if source_path.starts_with("/usr/src/debug/"):
            return true
        if source_path.len > 0 and not source_path.starts_with("/usr/lib/") and not source_path.starts_with("/lib/"):
            return true
        return true


function pause_frame_summary(frame: json.Value, include_ip: bool) -> string.String:
    let obj = frame.as_object()
    var name = string.String.from_str("(anonymous)")
    var ip = string.String.create()
    var path = string.String.create()
    var source_name = string.String.create()
    var location_source = string.String.create()
    var location = string.String.create()
    if obj != null:
        unsafe:
            match read(obj).get_string("name"):
                Option.some as found:
                    name.release()
                    name = string.String.from_str(found.value)
                Option.none:
                    pass
            match read(obj).get_string("instructionPointerReference"):
                Option.some as found:
                    ip.assign(found.value)
                Option.none:
                    pass
            let source = read(obj).get_object("source")
            if source != null:
                match read(source).get_string("path"):
                    Option.some as found:
                        path.assign(found.value)
                    Option.none:
                        pass
                match read(source).get_string("name"):
                    Option.some as found:
                        source_name.assign(found.value)
                    Option.none:
                        pass
            var line: ptr_uint = 0
            match read(obj).get_number("line"):
                Option.some as found:
                    if found.value > 0.0:
                        line = ptr_uint<-int<-found.value
                Option.none:
                    pass

            if path.len() > 0 and not path.as_str().contains_substring("`"):
                location_source.assign(path.as_str())
            else if source_name.len() > 0:
                location_source.assign(source_name.as_str())
            else if path.len() > 0:
                location_source.assign(path.as_str())
            else:
                location_source.assign(ip.as_str())

            if location_source.len() == 0:
                location.assign("(unknown)")
            else:
                var suffix = string.String.create()
                suffix.append(":")
                suffix.append_format(f"#{line}")
                if line > 0 and not location_source.as_str().contains_substring(suffix.as_str()):
                    location.assign(location_source.as_str())
                    location.append(suffix.as_str())
                else:
                    location.assign(location_source.as_str())
                suffix.release()

    var result = string.String.create()
    result.append(name.as_str())
    result.append(" @ ")
    result.append(location.as_str())
    if include_ip and ip.len() > 0 and not location.as_str().equal(ip.as_str()):
        result.append(" ip=")
        result.append(ip.as_str())
    name.release()
    ip.release()
    path.release()
    source_name.release()
    location_source.release()
    location.release()
    return result


## The `modules` fallback: try each reported module's sidecar.
function load_debug_map_from_modules(ses: ref[session.Session], body: json.Value) -> void:
    if ses.debug_map != null:
        return
    let obj = body.as_object()
    if obj == null:
        return
    unsafe:
        let modules = read(obj).get_array("modules")
        if modules == null:
            return
        var i: ptr_uint = 0
        while i < read(modules).len():
            let module_ptr = read(modules).get(i)
            if module_ptr != null:
                let module_obj = read(module_ptr).as_object()
                if module_obj != null:
                    var candidate = ""
                    match read(module_obj).get_string("path"):
                        Option.some as found:
                            candidate = found.value
                        Option.none:
                            match read(module_obj).get_string("symbolFilePath"):
                                Option.some as found:
                                    candidate = found.value
                                Option.none:
                                    pass
                    if candidate.len > 0:
                        var absolute = util.absolute_path(candidate)
                        defer: absolute.release()
                        match debug_map.load_for_binary(absolute.as_str()):
                            Option.some as loaded:
                                ses.set_debug_map(loaded.value)
                                return
                            Option.none:
                                pass
            i += 1

# =============================================================================
#  Response and argument rewriters
# =============================================================================

## Rewrite a forwarded response's body text for the debug map (stackTrace
## frames, scope references, variable names).
function rewrite_forward_response(
    ses: ref[session.Session],
    pending: lldb.PendingRequest,
    body: ref[string.String]
) -> void:
    if ses.debug_map == null:
        return
    let command = pending.command.as_str()
    if command.equal("stackTrace"):
        rewrite_stack_trace_body(ses, body)
    else if command.equal("scopes"):
        rewrite_scopes_body(ses, pending, body)
    else if command.equal("variables"):
        rewrite_variables_body(ses, pending, body)


function rewrite_stack_trace_body(ses: ref[session.Session], body: ref[string.String]) -> void:
    match json.parse(body.as_str()):
        Result.failure as failure:
            var error = failure.error
            error.release()
        Result.success as parsed:
            defer: json.release_value(parsed.value)
            let obj = parsed.value.as_object()
            if obj != null:
                unsafe:
                    let frames = read(obj).get_array("stackFrames")
                    if frames != null:
                        ses.frame_functions.clear()
                        var i: ptr_uint = 0
                        while i < read(frames).len():
                            let frame_ptr = read(frames).get(i)
                            if frame_ptr != null:
                                let frame_obj = read(frame_ptr).as_object()
                                if frame_obj != null:
                                    match read(frame_obj).get_string("name"):
                                        Option.some as name:
                                            let map_ptr = ses.debug_map
                                            if map_ptr != null:
                                                let entry_fn = debug_map.function_for_c_name(
                                                    ref_of(read(map_ptr)),
                                                    name.value
                                                )
                                                if entry_fn != null:
                                                    read(frame_obj).set(
                                                        "name",
                                                        json.string_from_str(read(entry_fn).name.as_str())
                                                    )
                                                    match number_field_from_object(frame_obj, "id"):
                                                        Option.some as frame_id:
                                                            ses.frame_functions.set(frame_id.value, entry_fn)
                                                        Option.none:
                                                            pass
                                        Option.none:
                                            pass
                            i += 1
            var rendered = json.render(parsed.value)
            match rendered:
                Result.success as text:
                    body.assign(text.value.as_str())
                    text.value.release()
                Result.failure as failure:
                    var error = failure.error
                    error.release()


function rewrite_scopes_body(ses: ref[session.Session], pending: lldb.PendingRequest, body: ref[string.String]) -> void:
    var frame_id: ptr_uint = 0
    var has_frame = false
    match json.parse(pending.arguments_text.as_str()):
        Result.success as parsed:
            defer: json.release_value(parsed.value)
            match number_field(parsed.value, "frameId"):
                Option.some as found:
                    frame_id = found.value
                    has_frame = true
                Option.none:
                    pass
        Result.failure as failure:
            var error = failure.error
            error.release()
    if not has_frame:
        return

    var function_ptr: ptr[debug_map.DebugFunction]? = null
    let recorded = ses.frame_functions.get(frame_id)
    if recorded != null:
        function_ptr = unsafe: read(recorded)

    match json.parse(body.as_str()):
        Result.failure as failure:
            var error = failure.error
            error.release()
        Result.success as parsed:
            defer: json.release_value(parsed.value)
            let obj = parsed.value.as_object()
            if obj != null:
                unsafe:
                    let scopes = read(obj).get_array("scopes")
                    if scopes != null:
                        var i: ptr_uint = 0
                        while i < read(scopes).len():
                            let scope_ptr = read(scopes).get(i)
                            if scope_ptr != null:
                                let scope_obj = read(scope_ptr).as_object()
                                if scope_obj != null:
                                    var reference: ptr_uint = 0
                                    var has_reference = false
                                    match number_field_from_object(scope_obj, "variablesReference"):
                                        Option.some as found:
                                            reference = found.value
                                            has_reference = true
                                        Option.none:
                                            pass
                                    if has_reference:
                                        var is_locals = false
                                        match read(scope_obj).get_string("name"):
                                            Option.some as name:
                                                is_locals = name.value.equal("Locals")
                                            Option.none:
                                                pass
                                        ses.variable_contexts.set(reference, session.VariableContext(
                                            frame_id = frame_id,

                                            function = function_ptr,
                                            has_function = is_locals and function_ptr != null,
                                        ))
                            i += 1
            var rendered = json.render(parsed.value)
            match rendered:
                Result.success as text:
                    body.assign(text.value.as_str())
                    text.value.release()
                Result.failure as failure:
                    var error = failure.error
                    error.release()


function rewrite_variables_body(
    ses: ref[session.Session],
    pending: lldb.PendingRequest,
    body: ref[string.String]
) -> void:
    var reference: ptr_uint = 0
    var has_reference = false
    match json.parse(pending.arguments_text.as_str()):
        Result.success as parsed:
            defer: json.release_value(parsed.value)
            match number_field(parsed.value, "variablesReference"):
                Option.some as found:
                    reference = found.value
                    has_reference = true
                Option.none:
                    pass
        Result.failure as failure:
            var error = failure.error
            error.release()
    if not has_reference:
        return

    let context = ses.variable_contexts.get(reference)
    if context == null or not unsafe: read(context).has_function:
        return
    let function_ptr = unsafe: read(context).function

    match json.parse(body.as_str()):
        Result.failure as failure:
            var error = failure.error
            error.release()
        Result.success as parsed:
            defer: json.release_value(parsed.value)
            let obj = parsed.value.as_object()
            if obj == null:
                return
            unsafe:
                let variables = read(obj).get_array("variables")
                if variables == null:
                    return
                var result = string.String.with_capacity(256)
                result.append("{\"variables\":[")
                var first = true
                var i: ptr_uint = 0
                while i < read(variables).len():
                    let variable_ptr = read(variables).get(i)
                    if variable_ptr != null:
                        let variable_obj = read(variable_ptr).as_object()
                        if variable_obj != null:
                            var raw_name = ""
                            match read(variable_obj).get_string("name"):
                                Option.some as name:
                                    raw_name = name.value
                                Option.none:
                                    pass
                            var keep = true
                            let map_ptr = ses.debug_map
                            if map_ptr != null and function_ptr != null:
                                let entry = debug_map.variable_for(
                                    ref_of(read(map_ptr)),
                                    read(function_ptr).linkage_name.as_str(),
                                    raw_name
                                )
                                if entry != null:
                                    read(variable_obj).set("name", json.string_from_str(read(entry).name.as_str()))
                                else if raw_name.starts_with("__mt_"):
                                    keep = false
                            if keep:
                                if not first:
                                    result.append(",")
                                first = false
                                append_rendered(ref_of(result), read(variable_ptr))
                    i += 1
                result.append("]}")
                body.assign(result.as_str())
                result.release()


## evaluate/setExpression argument rewriting (expression and optionally value).
function rewrite_expression_arguments(
    ses: ref[session.Session],
    arguments: json.Value,
    include_value: bool
) -> string.String:
    var frame_id: ptr_uint = 0
    match number_field(arguments, "frameId"):
        Option.some as found:
            frame_id = found.value
        Option.none:
            pass
    var expression = rewrite_expression_for_frame(ses, string_arg(arguments, "expression"), frame_id)
    var value = string.String.create()
    if include_value:
        value = rewrite_expression_for_frame(ses, string_arg(arguments, "value"), frame_id)
    var result = render_replaced_two(
        arguments,
        "expression",
        expression.as_str(),
        include_value,
        "value",
        value.as_str()
    )
    expression.release()
    value.release()
    return result


function rewrite_set_variable_arguments(ses: ref[session.Session], arguments: json.Value) -> string.String:
    var function_ptr: ptr[debug_map.DebugFunction]? = null
    match number_field(arguments, "variablesReference"):
        Option.some as found:
            let context = ses.variable_contexts.get(found.value)
            if context != null and unsafe: read(context).has_function:
                function_ptr = unsafe: read(context).function
        Option.none:
            pass
    var name = string.String.from_str(string_arg(arguments, "name"))
    if function_ptr != null:
        let entry = source_variable_entry(ses, function_ptr, name.as_str())
        if entry != null:
            name.release()
            name = string.String.from_str(unsafe: read(entry).linkage_name.as_str())
    var frame_id: ptr_uint = 0
    match number_field(arguments, "frameId"):
        Option.some as found:
            frame_id = found.value
        Option.none:
            pass
    var value = rewrite_expression_for_frame(ses, string_arg(arguments, "value"), frame_id)
    var result = render_replaced_two(arguments, "name", name.as_str(), true, "value", value.as_str())
    name.release()
    value.release()
    return result


function rewrite_data_breakpoint_arguments(ses: ref[session.Session], arguments: json.Value) -> string.String:
    var name = string.String.from_str(string_arg(arguments, "name"))
    if has_key(arguments, "variablesReference"):
        match number_field(arguments, "variablesReference"):
            Option.some as found:
                let context = ses.variable_contexts.get(found.value)
                if context != null and unsafe: read(context).has_function:
                    let function_ptr = unsafe: read(context).function
                    if function_ptr != null:
                        let entry = source_variable_entry(ses, function_ptr, name.as_str())
                        if entry != null:
                            name.release()
                            name = string.String.from_str(unsafe: read(entry).linkage_name.as_str())
            Option.none:
                pass
    else:
        var frame_id: ptr_uint = 0
        match number_field(arguments, "frameId"):
            Option.some as found:
                frame_id = found.value
            Option.none:
                pass
        var rewritten = rewrite_expression_for_frame(ses, name.as_str(), frame_id)
        name.release()
        name = rewritten
    var result = render_replaced_two(arguments, "name", name.as_str(), false, "", "")
    name.release()
    return result


## Rewrite identifiers through the function's variable map (the host's
## `rewrite_expression_for_function`).
function rewrite_expression_for_frame(ses: ref[session.Session], expression: str, frame_id: ptr_uint) -> string.String:
    if expression.len == 0:
        return string.String.from_str(expression)
    let function_ptr = ses.frame_functions.get(frame_id)
    if function_ptr == null:
        return string.String.from_str(expression)
    let map_ptr = ses.debug_map
    if map_ptr == null:
        return string.String.from_str(expression)

    unsafe:
        let function_value = read(read(function_ptr))
        let linkage = function_value.linkage_name.as_str()
        var result = string.String.with_capacity(expression.len + 16)
        var index: ptr_uint = 0
        while index < expression.len:
            let ch = expression.byte_at(index)
            if ch == '"' or ch == '\'':
                index = copy_quoted_segment(expression, index, ref_of(result))
                continue
            if identifier_start_char(ch):
                let start = index
                index += 1
                while index < expression.len and identifier_continue_char(expression.byte_at(index)):
                    index += 1
                let identifier = expression.slice(start, index - start)
                if accessor_identifier(expression, start):
                    result.append(identifier)
                else:
                    let entry = debug_map.source_variable_for(ref_of(read(map_ptr)), linkage, identifier)
                    if entry != null:
                        result.append(read(entry).linkage_name.as_str())
                    else:
                        result.append(identifier)
                continue
            result.push_byte(ch)
            index += 1
        return result


function copy_quoted_segment(expression: str, index: ptr_uint, target: ref[string.String]) -> ptr_uint:
    let quote = expression.byte_at(index)
    target.push_byte(quote)
    var i = index + 1
    while i < expression.len:
        let ch = expression.byte_at(i)
        target.push_byte(ch)
        i += 1
        if ch == 92 and i < expression.len:
            target.push_byte(expression.byte_at(i))
            i += 1
            continue
        if ch == quote:
            break
    return i


function accessor_identifier(expression: str, index: ptr_uint) -> bool:
    var previous: ptr_int = ptr_int<-index - 1
    while previous >= 0 and whitespace_char(expression.byte_at(ptr_uint<-previous)):
        previous -= 1
    if previous < 0:
        return false
    if expression.byte_at(ptr_uint<-previous) == '.':
        return true
    if expression.byte_at(ptr_uint<-previous) != '>':
        return false
    previous -= 1
    while previous >= 0 and whitespace_char(expression.byte_at(ptr_uint<-previous)):
        previous -= 1
    return previous >= 0 and expression.byte_at(ptr_uint<-previous) == '-'


function identifier_start_char(value: ubyte) -> bool:
    return (value >= 'A' and value <= 'Z') or (value >= 'a' and value <= 'z') or value == '_'


function identifier_continue_char(value: ubyte) -> bool:
    return identifier_start_char(value) or (value >= '0' and value <= '9')


function whitespace_char(value: ubyte) -> bool:
    return value == 32 or value == 9 or value == 10 or value == 13


## The source path recorded in a setBreakpoints request's arguments.
function source_path_from_arguments(arguments_text: str) -> string.String:
    match json.parse(arguments_text):
        Result.failure as failure:
            var error = failure.error
            error.release()
        Result.success as parsed:
            defer: json.release_value(parsed.value)
            let obj = parsed.value.as_object()
            if obj != null:
                unsafe:
                    let source = read(obj).get_object("source")
                    if source != null:
                        match read(source).get_string("path"):
                            Option.some as found:
                                return string.String.from_str(found.value)
                            Option.none:
                                pass
    return string.String.create()


## The variable entry for a source name through the debug map.
function source_variable_entry(
    ses: ref[session.Session],
    function_ptr: ptr[debug_map.DebugFunction],
    source_name: str
) -> ptr[debug_map.DebugEntry]?:
    let map_ptr = ses.debug_map
    if map_ptr == null:
        return null
    return debug_map.source_variable_for(
        unsafe: ref_of(read(map_ptr)),
        unsafe: read(function_ptr).linkage_name.as_str(),
        source_name
    )


## Render request arguments with up to two keys replaced by rewritten values.
function render_replaced_two(
    arguments: json.Value,
    key_a: str,
    replacement_a: str,
    include_b: bool,
    key_b: str,
    replacement_b: str,
) -> string.String:
    let obj = arguments.as_object()
    if obj == null:
        return string.String.create()
    var result = string.String.with_capacity(128)
    result.append("{")
    var first = true
    unsafe:
        let entries = read(obj).entries
        var i: ptr_uint = 0
        while i < entries.len():
            let entry = entries.get(i) else:
                break
            let key = read(entry).key.as_str()
            let skip = key.equal(key_a) or (include_b and key.equal(key_b))
            if not skip:
                if not first:
                    result.append(",")
                first = false
                result.append("\"")
                proto.append_escaped(ref_of(result), key)
                result.append("\":")
                append_rendered(ref_of(result), read(entry).value)
            i += 1
    if has_key(arguments, key_a):
        if not first:
            result.append(",")
        first = false
        result.append("\"")
        proto.append_escaped(ref_of(result), key_a)
        result.append("\":")
        append_json_string(ref_of(result), replacement_a)
    if include_b and has_key(arguments, key_b):
        if not first:
            result.append(",")
        first = false
        result.append("\"")
        proto.append_escaped(ref_of(result), key_b)
        result.append("\":")
        append_json_string(ref_of(result), replacement_b)
    result.append("}")
    return result


function append_json_string(target: ref[string.String], text: str) -> void:
    target.append("\"")
    proto.append_escaped(target, text)
    target.append("\"")


function has_key(value: json.Value, key: str) -> bool:
    let obj = value.as_object()
    if obj == null:
        return false
    unsafe:
        return read(obj).get(key) != null


## `number_field` for an object pointer (the accessors below work on Values).
function number_field_from_object(obj: ptr[json.Object], key: str) -> Option[ptr_uint]:
    unsafe:
        let field_ptr = read(obj).get(key)
        if field_ptr == null:
            return Option[ptr_uint].none
        match read(field_ptr).as_number():
            Option.some as found:
                return Option[ptr_uint].some(value = ptr_uint<-int<-found.value)
            Option.none:
                return Option[ptr_uint].none


## One adapter capability from its initialize response.
function capability_flag(backend: ref[lldb.Backend], key: str) -> bool:
    if backend.capabilities_text.len() == 0:
        return false
    match json.parse(backend.capabilities_text.as_str()):
        Result.success as parsed:
            defer: json.release_value(parsed.value)
            let obj = parsed.value.as_object()
            if obj != null:
                unsafe:
                    match read(obj).get_boolean(key):
                        Option.some as value:
                            return value.value
                        Option.none:
                            pass
        Result.failure as failure:
            var error = failure.error
            error.release()
    return false

## Syntactic absolute path (`File.expand_path`).
# =============================================================================
#  Small JSON accessors (the handlers module's helpers are module-private)
# =============================================================================

function string_arg(value: json.Value, name: str) -> str:
    let obj_ptr = value.as_object()
    if obj_ptr == null:
        return ""
    unsafe:
        let field_ptr = read(obj_ptr).get(name)
        if field_ptr == null:
            return ""
        match read(field_ptr).as_string():
            Option.some as found:
                return found.value
            Option.none:
                return ""


function number_field(value: json.Value, name: str) -> Option[ptr_uint]:
    let obj_ptr = value.as_object()
    if obj_ptr == null:
        return Option[ptr_uint].none
    unsafe:
        let field_ptr = read(obj_ptr).get(name)
        if field_ptr == null:
            return Option[ptr_uint].none
        match read(field_ptr).as_number():
            Option.some as found:
                return Option[ptr_uint].some(value = ptr_uint<-int<-found.value)
            Option.none:
                return Option[ptr_uint].none


function bool_field(value: json.Value, name: str) -> bool:
    let obj_ptr = value.as_object()
    if obj_ptr == null:
        return false
    unsafe:
        let field_ptr = read(obj_ptr).get(name)
        if field_ptr == null:
            return false
        match read(field_ptr).as_boolean():
            Option.some as found:
                return found.value
            Option.none:
                return false

## lldb-dap bridge policy — the DAP handshake over lldb_backend.mt's transport:
## client initialize/launch/attach/configurationDone, adapter event handling
## (with the SIGSTOP pause rewrite and continued-event deduplication), reverse
## requests, timeouts and shutdown.  Ports `dap/server/lldb_backend.rb` plus the
## transport half's response routing from `dap/lldb_dap_backend.rb`.

import std.json as json
import std.process as process
import std.str
import std.string as string
import std.time as time
import std.vec as vec

import mtc.dap.lldb_backend as lldb
import mtc.dap.protocol as proto
import mtc.dap.session as session
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
    if backend.start_pending:
        backend.has_deferred_config = true
        backend.deferred_config_client_seq = req_seq
        return
    proceed_configuration(ses, backend, req_seq)


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

    let framer = backend.framer
    if framer == null:
        return
    while true:
        let next = proto.framer_next(unsafe: ref_of(read(framer)))
        match next:
            Option.some as payload:
                route_adapter_message(ses, backend, payload.value)
                proto.release_message(ref_of(payload.value))
            Option.none:
                break

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
        else:
            backend.has_pending_start = false
            var message = backend_error_message(msg)
            defer: message.release()
            wire.write_error_command(ses.reserve_seq(), pending.client_seq, pending.command.as_str(), message.as_str())
        return

    if pending.kind == lldb.KIND_START:
        backend.start_pending = false
        if msg.success:
            wire.write_response_command(ses.reserve_seq(), pending.client_seq, pending.command.as_str(), body_text.as_str())
        else:
            var message = backend_error_message(msg)
            defer: message.release()
            wire.write_error_command(ses.reserve_seq(), pending.client_seq, pending.command.as_str(), message.as_str())
        if backend.has_deferred_config:
            backend.has_deferred_config = false
            proceed_configuration(ses, backend, backend.deferred_config_client_seq)
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
            wire.write_response_command(ses.reserve_seq(), pending.client_seq, pending.command.as_str(), body_text.as_str())
        else:
            var message = backend_error_message(msg)
            defer: message.release()
            wire.write_error_command(ses.reserve_seq(), pending.client_seq, pending.command.as_str(), message.as_str())
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
        return

    if event_name.equal("stopped"):
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
        if backend.has_continued_signature and backend.last_continued_thread == thread_id and backend.last_continued_all == all:
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
public function handle_client_response(ses: ref[session.Session], backend: ref[lldb.Backend], msg: proto.Message) -> void:
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
                        wire.write_error_command(ses.reserve_seq(), pending.client_seq, pending.command.as_str(), message.as_str())
                        message.release()
                    if pending.kind == lldb.KIND_START:
                        backend.start_pending = false
                    pending.command.release()
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
                if key.equal("supportsSetVariable") and (capability_true(caps_obj, "supportsSetExpression") or capability_true(caps_obj, "supportsSetVariable")):
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

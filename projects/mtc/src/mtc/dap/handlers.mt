## DAP request handlers — dispatches incoming DAP commands.  Handles 15
## full implementations with 8 error responses for unsupported operations.

import std.fmt
import std.fs as fs_mod
import std.json as json
import std.path as path_ops
import std.str
import std.string as string
import std.vec as vec

import std.process as process
import mtc.dap.process_backend as backend
import mtc.dap.protocol as proto
import mtc.dap.session as ses_mod
import mtc.dap.utilities as util
import mtc.dap.wire as wire


public const SIGNAL_STOP:   int = 19
public const SIGNAL_CONT:   int = 18
public const SIGNAL_TERM:   int = 15

const CAPABILITIES: str = "{\"supportsConfigurationDoneRequest\":true,\"supportsFunctionBreakpoints\":true,\"supportsConditionalBreakpoints\":false,\"supportsHitConditionalBreakpoints\":false,\"supportsEvaluateForHovers\":false,\"supportsSetVariable\":false,\"supportTerminateDebuggee\":true,\"supportsTerminateRequest\":true,\"supportsLoadedSourcesRequest\":true,\"exceptionBreakpointFilters\":[],\"supportsPauseRequest\":true}"


## Dispatch a DAP request to the appropriate handler based on the command.
public function dispatch(
    ses: ref[ses_mod.Session],
    child: ref[process.ChildProcess],
    has_child: ref[bool],
    command: str,
    msg: proto.Message,
) -> void:
    let seq = ses.reserve_seq()

    if command == "initialize":
        handle_initialize(ses, seq, msg)
    else if command == "launch":
        handle_launch(ses, child, has_child, seq, msg)
    else if command == "attach":
        wire.write_error(seq, msg.seq, "attach requires the lldb-dap backend")

    else if command == "setBreakpoints":
        handle_set_breakpoints(ses, seq, msg)
    else if command == "setFunctionBreakpoints":
        handle_set_function_breakpoints(seq, msg.seq)
    else if command == "setExceptionBreakpoints":
        handle_set_exception_breakpoints(seq, msg.seq)
    else if command == "configurationDone":
        handle_configuration_done(ses, child, has_child, seq, msg.seq)

    else if command == "threads":
        handle_threads(seq, msg.seq)
    else if command == "stackTrace":
        handle_stack_trace(ses, seq, msg)
    else if command == "scopes":
        handle_scopes(seq, msg.seq)
    else if command == "variables":
        handle_variables(seq, msg.seq)

    else if command == "continue":
        handle_continue(ses, child, has_child, seq, msg.seq)
    else if command == "next":
        wire.write_error(seq, msg.seq, "next is not supported by the process backend")
    else if command == "stepIn":
        wire.write_error(seq, msg.seq, "stepIn is not supported by the process backend")
    else if command == "stepOut":
        wire.write_error(seq, msg.seq, "stepOut is not supported by the process backend")
    else if command == "pause":
        handle_pause(ses, child, has_child, seq, msg.seq)
    else if command == "terminate":
        handle_terminate(ses, child, has_child, seq, msg.seq)
    else if command == "disconnect":
        handle_disconnect(ses, child, has_child, seq, msg.seq)

    else if command == "evaluate":
        wire.write_error(seq, msg.seq, "evaluate is not supported by the process backend")
    else if command == "source":
        handle_source(seq, msg)
    else if command == "loadedSources":
        wire.write_response(seq, msg.seq, "{\"sources\":[]}")
    else if command == "cancel":
        wire.write_response(seq, msg.seq, "{}")
    else if command == "restart":
        wire.write_error(seq, msg.seq, "restart is not supported by the process backend")
    else if command == "setVariable":
        wire.write_error(seq, msg.seq, "setVariable is not supported by the process backend")
    else if command == "setExpression":
        wire.write_error(seq, msg.seq, "setExpression is not supported by the process backend")
    else if command == "dataBreakpointInfo":
        wire.write_error(seq, msg.seq, "dataBreakpointInfo is not supported by the process backend")
    else:
        wire.write_error(seq, msg.seq, "unsupported command")


## Initialize — returns capabilities + initialized event.
function handle_initialize(ses: ref[ses_mod.Session], seq: ptr_uint, msg: proto.Message) -> void:
    wire.write_response(seq, msg.seq, CAPABILITIES)

    let init_seq = ses.reserve_seq()
    wire.write_event(init_seq, "initialized", "{}")


## Launch — builds .mt and stores runnable path.
function handle_launch(ses: ref[ses_mod.Session], child: ref[process.ChildProcess], has_child: ref[bool], seq: ptr_uint, msg: proto.Message) -> void:
    let program = extract_string_arg(msg.arguments, "program")
    if program.len == 0:
        wire.write_error(seq, msg.seq, "launch requires a non-empty 'program' argument")
        return

    var resolved = util.resolve_launch_program(program)
    if not resolved.ok:
        wire.write_error(seq, msg.seq, resolved.error.as_str())
        util.release_launch_resolved(ref_of(resolved))
        return

    if resolved.tmp_dir.len() > 0:
        ses.remember_tmp_dir(resolved.tmp_dir.as_str())

    ses.program_path.release()
    ses.runnable_path.release()
    ses.program_path = string.String.from_str(program)
    ses.runnable_path = string.String.from_str(resolved.runnable_path.as_str())
    ses.stop_on_entry = bool_arg(msg.arguments, "stopOnEntry", true)
    ses.launched = true
    ses.runtime_started = false
    ses.entry_stop_emitted = false
    load_program_args(ses, msg.arguments)

    util.release_launch_resolved(ref_of(resolved))

    wire.write_response(seq, msg.seq, "{}")

    # The host announces the launched process (`launch.rb`), so the client can
    # show it in the call stack / process picker.
    let pseq = ses.reserve_seq()
    var process_body = string.String.create()
    process_body.append("{\"name\":\"")
    let base = path_basename(ses.program_path.as_str())
    proto.append_escaped(ref_of(process_body), base)
    process_body.append("\",\"startMethod\":\"launch\",\"isLocalProcess\":true}")
    wire.write_event(pseq, "process", process_body.as_str())
    process_body.release()


## The last path segment (`/tmp/x/main` -> `main`).
function path_basename(path: str) -> str:
    var idx: ptr_uint = 0
    var last: ptr_uint = 0
    while idx < path.len:
        if path.byte_at(idx) == 47:
            last = idx + 1
        idx += 1
    if last >= path.len:
        return path
    return path.slice(last, path.len - last)


## setBreakpoints — registers line breakpoints (unverified for process backend).
function handle_set_breakpoints(ses: ref[ses_mod.Session], seq: ptr_uint, msg: proto.Message) -> void:
    var requested = extract_line_breakpoints(msg.arguments)
    defer: requested.release()

    var r = string.String.create()
    defer: r.release()
    r.append("{\"breakpoints\":[")

    var fi: ptr_uint = 0
    while fi < requested.len():
        let lp = requested.get(fi)
        if lp == null:
            break
        let line = unsafe: util.read_ptr(lp)
        if fi > 0: r.append(",")
        let bp_id = ses.reserve_breakpoint_id()
        r.append("{\"id\":")
        r.append_format(f"#{bp_id}")
        r.append(",\"line\":")
        r.append_format(f"#{line}")
        r.append(",\"verified\":false,\"message\":\"Process backend runs without a debugger\"}")
        fi += 1

    r.append("]}")
    wire.write_response(seq, msg.seq, r.as_str())


## setFunctionBreakpoints — registers function breakpoints.
function handle_set_function_breakpoints(seq: ptr_uint, req_seq: ptr_uint) -> void:
    wire.write_response(seq, req_seq, "{\"breakpoints\":[]}")


## setExceptionBreakpoints — no-op acknowledgment.
function handle_set_exception_breakpoints(seq: ptr_uint, req_seq: ptr_uint) -> void:
    wire.write_response(seq, req_seq, "{}")


## configurationDone — marks configuration complete, then starts the program
## (or stops at entry), mirroring the host's `maybe_start_or_stop_on_entry`.
function handle_configuration_done(
    ses: ref[ses_mod.Session],
    child: ref[process.ChildProcess],
    has_child: ref[bool],
    seq: ptr_uint,
    req_seq: ptr_uint,
) -> void:
    ses.configuration_done = true
    wire.write_response(seq, req_seq, "{}")
    maybe_start_or_stop_on_entry(ses, child, has_child)


## Threads — single main thread.
function handle_threads(seq: ptr_uint, req_seq: ptr_uint) -> void:
    wire.write_response(seq, req_seq, "{\"threads\":[{\"id\":1,\"name\":\"main\"}]}")


## StackTrace — single entry frame.
function handle_stack_trace(ses: ref[ses_mod.Session], seq: ptr_uint, msg: proto.Message) -> void:
    let source_path = ses.program_path.as_str()
    let base = path_ops.basename(source_path)
    var r = string.String.create()
    defer: r.release()
    r.append("{\"stackFrames\":[{\"id\":1,\"name\":\"main\",\"line\":1,\"column\":1,\"source\":{\"name\":\"")
    proto.append_escaped(ref_of(r), base)
    r.append("\",\"path\":\"")
    proto.append_escaped(ref_of(r), source_path)
    r.append("\"}}],\"totalFrames\":1}")
    wire.write_response(seq, msg.seq, r.as_str())


## Scopes — single Locals scope.
function handle_scopes(seq: ptr_uint, req_seq: ptr_uint) -> void:
    wire.write_response(seq, req_seq, "{\"scopes\":[{\"name\":\"Locals\",\"variablesReference\":1,\"expensive\":false}]}")


## Variables — empty for process backend.
function handle_variables(seq: ptr_uint, req_seq: ptr_uint) -> void:
    wire.write_response(seq, req_seq, "{\"variables\":[]}")


## Continue — starts the program if needed (after an entry stop), resumes a
## paused one, and emits the continued event.
function handle_continue(ses: ref[ses_mod.Session], child: ref[process.ChildProcess], has_child: ref[bool], seq: ptr_uint, req_seq: ptr_uint) -> void:
    start_runtime(ses, child, has_child)
    continue_runtime_if_paused(ses, child, has_child)
    wire.write_response(seq, req_seq, "{\"allThreadsContinued\":true}")
    let cont_seq = ses.reserve_seq()
    wire.write_event(cont_seq, "continued", "{\"threadId\":1,\"allThreadsContinued\":true}")


## Pause — SIGSTOPs the running program and emits the stopped event.
function handle_pause(ses: ref[ses_mod.Session], child: ref[process.ChildProcess], has_child: ref[bool], seq: ptr_uint, req_seq: ptr_uint) -> void:
    if not pause_runtime_if_running(ses, child, has_child):
        wire.write_error(seq, req_seq, "pause failed: process is not running")
        return
    wire.write_response(seq, req_seq, "{}")
    let stop_seq = ses.reserve_seq()
    wire.write_event(stop_seq, "stopped", "{\"reason\":\"pause\",\"threadId\":1,\"allThreadsStopped\":true}")


## Terminate — SIGTERMs a running program (its exit emits the events); when no
## program was started, closes the session with terminated + exited.
function handle_terminate(
    ses: ref[ses_mod.Session],
    child: ref[process.ChildProcess],
    has_child: ref[bool],
    seq: ptr_uint,
    req_seq: ptr_uint,
) -> void:
    terminate_runtime_if_running(ses, child, has_child)
    wire.write_response(seq, req_seq, "{}")
    if ses.runtime_started:
        return
    ses.terminated = true
    let tseq = ses.reserve_seq()
    wire.write_event(tseq, "terminated", "{}")
    let eseq = ses.reserve_seq()
    wire.write_event(eseq, "exited", "{\"exitCode\":0}")
    ses.cleanup_tmp_dirs()
    ses.should_exit = true


## Disconnect — terminates the program (if running) and exits the server.
function handle_disconnect(
    ses: ref[ses_mod.Session],
    child: ref[process.ChildProcess],
    has_child: ref[bool],
    seq: ptr_uint,
    req_seq: ptr_uint,
) -> void:
    wire.write_response(seq, req_seq, "{}")
    terminate_runtime_if_running(ses, child, has_child)
    if not ses.runtime_started:
        ses.terminated = true
        let tseq = ses.reserve_seq()
        wire.write_event(tseq, "terminated", "{}")
        let eseq = ses.reserve_seq()
        wire.write_event(eseq, "exited", "{\"exitCode\":0}")
    ses.cleanup_tmp_dirs()
    ses.should_exit = true


## Source — reads a file from disk.
function handle_source(seq: ptr_uint, msg: proto.Message) -> void:
    let source_path = extract_nested_arg(msg.arguments, "source", "path")
    if source_path.len == 0:
        wire.write_error(seq, msg.seq, "source missing path")
        return
    match fs_mod.read_text(source_path):
        Result.success as payload:
            var content = payload.value
            var r = string.String.create()
            defer: r.release()
            r.append("{\"content\":\"")
            proto.append_escaped(ref_of(r), content.as_str())
            r.append("\"}")
            wire.write_response(seq, msg.seq, r.as_str())
            content.release()
        Result.failure:
            wire.write_error(seq, msg.seq, "source file not found")


## Start the program (once) when configuration is done and no entry stop was
## requested.  The host starts it in `maybe_start_or_stop_on_entry`; the self
## defers to `configurationDone` the same way.
function maybe_start_or_stop_on_entry(
    ses: ref[ses_mod.Session],
    child: ref[process.ChildProcess],
    has_child: ref[bool],
) -> void:
    if not ses.launched or not ses.configuration_done or ses.runtime_started:
        return
    if ses.stop_on_entry:
        if ses.entry_stop_emitted:
            return
        let stop_seq = ses.reserve_seq()
        wire.write_event(stop_seq, "stopped", "{\"reason\":\"entry\",\"threadId\":1,\"allThreadsStopped\":true}")
        ses.entry_stop_emitted = true
    else:
        start_runtime(ses, child, has_child)


## Spawn the debuggee: the runnable path plus the launch `args`, with the
## program's directory as cwd (the host's `start_runtime_if_needed`).
function start_runtime(
    ses: ref[ses_mod.Session],
    child: ref[process.ChildProcess],
    has_child: ref[bool],
) -> void:
    if ses.runtime_started:
        return
    if ses.runnable_path.len() == 0:
        return
    ses.runtime_started = true

    var command = vec.Vec[str].create()
    defer: command.release()
    command.push(ses.runnable_path.as_str())
    var ai: ptr_uint = 0
    while ai < ses.program_args.len():
        let arg = ses.program_args.get(ai)
        if arg != null:
            unsafe: command.push(read(arg).as_str())
        ai += 1

    let cwd = runtime_working_directory(ses)
    match process.spawn_in(command.as_span(), cwd):
        Result.success as spawned:
            unsafe:
                read(child) = spawned.value
                read(has_child) = true
                let _ = read(child).close_stdin()
        Result.failure as failure:
            var error = failure.error
            ses.terminated = true
            var note = string.String.from_str("DAP runtime error: ")
            note.append(error.message.as_str())
            note.append("\n")
            error.release()
            let oseq = ses.reserve_seq()
            backend.write_output_event(oseq, "stderr", note.as_str())
            note.release()
            let tseq = ses.reserve_seq()
            wire.write_event(tseq, "terminated", "{}")
            let eseq = ses.reserve_seq()
            wire.write_event(eseq, "exited", "{\"exitCode\":1}")


## The program's directory first, the runnable's otherwise (host
## `start_runtime_if_needed`'s chdir rule).
function runtime_working_directory(ses: ref[ses_mod.Session]) -> str:
    if ses.program_path.len() > 0:
        return path_ops.dirname(ses.program_path.as_str())
    return path_ops.dirname(ses.runnable_path.as_str())


## SIGCONT when the program is paused.
function continue_runtime_if_paused(
    ses: ref[ses_mod.Session],
    child: ref[process.ChildProcess],
    has_child: ref[bool],
) -> void:
    if not ses.runtime_paused:
        return
    ses.runtime_paused = false
    unsafe:
        if read(has_child):
            let _ = read(child).kill(SIGNAL_CONT)


## SIGSTOP a running program; false when none is running.
function pause_runtime_if_running(
    ses: ref[ses_mod.Session],
    child: ref[process.ChildProcess],
    has_child: ref[bool],
) -> bool:
    if not ses.runtime_started:
        return false
    unsafe:
        if not read(has_child):
            return false
        let _ = read(child).kill(SIGNAL_STOP)
    ses.runtime_paused = true
    return true


## SIGTERM a running program (the exit is observed by the event loop).
function terminate_runtime_if_running(
    ses: ref[ses_mod.Session],
    child: ref[process.ChildProcess],
    has_child: ref[bool],
) -> void:
    if not ses.runtime_started:
        return
    unsafe:
        if read(has_child):
            let _ = read(child).kill(SIGNAL_TERM)
    ses.runtime_paused = false


## Replace the stored program arguments from a launch request's `args` array.
function load_program_args(ses: ref[ses_mod.Session], args: json.Value) -> void:
    var ai: ptr_uint = 0
    while ai < ses.program_args.len():
        let existing = ses.program_args.get(ai)
        if existing != null:
            unsafe: read(existing).release()
        ai += 1
    ses.program_args.clear()

    let obj_ptr = args.as_object()
    if obj_ptr == null:
        return
    unsafe:
        let arr = read(obj_ptr).get_array("args")
        if arr == null:
            return
        var i: ptr_uint = 0
        while i < read(arr).len():
            let item = read(arr).get(i)
            if item != null:
                match read(item).as_string():
                    Option.some as text:
                        ses.program_args.push(string.String.from_str(text.value))
                    Option.none:
                        pass
            i += 1


## Extract a string argument from a JSON value.  Returns "" when absent.
function extract_string_arg(value: json.Value, name: str) -> str:
    let obj_ptr = value.as_object()
    if obj_ptr == null: return ""
    unsafe:
        let field_ptr = read(obj_ptr).get(name)
        if field_ptr == null: return ""
        let s = read(field_ptr).as_string()
        match s:
            Option.some as val:
                return val.value
            Option.none:
                return ""


## Extract a bool argument from a JSON value, returning default when absent.
function bool_arg(value: json.Value, name: str, default: bool) -> bool:
    let obj_ptr = value.as_object()
    if obj_ptr == null: return default
    unsafe:
        let field_ptr = read(obj_ptr).get(name)
        if field_ptr == null: return default
        match read(field_ptr).as_boolean():
            Option.some as b:
                return b.value
            Option.none:
                return default


## Extract line numbers from a breakpoints JSON array.
function extract_line_breakpoints(args: json.Value) -> vec.Vec[ptr_uint]:
    var result = vec.Vec[ptr_uint].create()
    let obj_ptr = args.as_object()
    if obj_ptr == null: return result
    unsafe:
        let bp_ptr = read(obj_ptr).get("breakpoints")
        if bp_ptr != null:
            let bp_arr = read(bp_ptr).as_array()
            if bp_arr != null:
                var fi: ptr_uint = 0
                while fi < read(bp_arr).len():
                    let elem_ptr = read(bp_arr).get(fi)
                    if elem_ptr != null:
                        let elem_obj = read(elem_ptr).as_object()
                        if elem_obj != null:
                            let line_ptr = read(elem_obj).get("line")
                            if line_ptr != null:
                                match read(line_ptr).as_number():
                                    Option.some as n:
                                        result.push(ptr_uint<-int<-n.value)
                                    Option.none:
                                        pass
                    fi += 1
            return result
        let lines_ptr = read(obj_ptr).get("lines")
        if lines_ptr != null:
            let lines_arr = read(lines_ptr).as_array()
            if lines_arr != null:
                var fi: ptr_uint = 0
                while fi < read(lines_arr).len():
                    let elem_ptr = read(lines_arr).get(fi)
                    if elem_ptr != null:
                        match read(elem_ptr).as_number():
                            Option.some as n:
                                result.push(ptr_uint<-int<-n.value)
                            Option.none:
                                pass
                    fi += 1
    return result


## Extract a nested string field from a JSON object.
function extract_nested_arg(args: json.Value, outer: str, inner: str) -> str:
    let obj_ptr = args.as_object()
    if obj_ptr == null: return ""
    unsafe:
        let outer_ptr = read(obj_ptr).get(outer)
        if outer_ptr == null: return ""
        let outer_obj = read(outer_ptr).as_object()
        if outer_obj == null: return ""
        let s = read(outer_obj).get_string(inner)
        match s:
            Option.some as val:
                return val.value
            Option.none:
                return ""

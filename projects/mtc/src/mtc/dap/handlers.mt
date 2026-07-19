## DAP request handlers — dispatches incoming DAP commands.  Handles 15
## full implementations with 8 error responses for unsupported operations.

import std.fmt
import std.fs as fs_mod
import std.json as json
import std.path as path_ops
import std.str
import std.string as string
import std.vec as vec

import mtc.dap.protocol as proto
import mtc.dap.session as ses_mod
import mtc.dap.utilities as util
import mtc.dap.wire as wire


const CAPABILITIES: str = "{\"supportsConfigurationDoneRequest\":true,\"supportsFunctionBreakpoints\":true,\"supportsConditionalBreakpoints\":false,\"supportsHitConditionalBreakpoints\":false,\"supportsEvaluateForHovers\":false,\"supportsSetVariable\":false,\"supportTerminateDebuggee\":true,\"supportsTerminateRequest\":true,\"supportsLoadedSourcesRequest\":true,\"exceptionBreakpointFilters\":[],\"supportsPauseRequest\":true}"


## Dispatch a DAP request to the appropriate handler based on the command.
public function dispatch(
    ses: ref[ses_mod.Session],
    
    
    command: str,
    msg: proto.Message,
) -> void:
    let seq = ses.reserve_seq()

    if command == "initialize":
        handle_initialize(ses, seq, msg)
    else if command == "launch":
        handle_launch(ses, seq, msg)
    else if command == "attach":
        wire.write_error(seq, msg.seq, "attach requires the lldb-dap backend")

    else if command == "setBreakpoints":
        handle_set_breakpoints(ses, seq, msg)
    else if command == "setFunctionBreakpoints":
        handle_set_function_breakpoints(seq, msg.seq)
    else if command == "setExceptionBreakpoints":
        handle_set_exception_breakpoints(seq, msg.seq)
    else if command == "configurationDone":
        handle_configuration_done(ses, seq, msg.seq)

    else if command == "threads":
        handle_threads(seq, msg.seq)
    else if command == "stackTrace":
        handle_stack_trace(ses, seq, msg)
    else if command == "scopes":
        handle_scopes(seq, msg.seq)
    else if command == "variables":
        handle_variables(seq, msg.seq)

    else if command == "continue":
        handle_continue(ses, seq, msg.seq)
    else if command == "next":
        wire.write_error(seq, msg.seq, "next is not supported by the process backend")
    else if command == "stepIn":
        wire.write_error(seq, msg.seq, "stepIn is not supported by the process backend")
    else if command == "stepOut":
        wire.write_error(seq, msg.seq, "stepOut is not supported by the process backend")
    else if command == "pause":
        handle_pause(ses, seq, msg.seq)
    else if command == "terminate":
        handle_terminate(ses,  seq, msg.seq)
    else if command == "disconnect":
        handle_disconnect(ses,  seq, msg.seq)

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
    else:
        wire.write_error(seq, msg.seq, "unsupported command")


## Initialize — returns capabilities + initialized event.
function handle_initialize(ses: ref[ses_mod.Session], seq: ptr_uint, msg: proto.Message) -> void:
    wire.write_response(seq, msg.seq, CAPABILITIES)

    let init_seq = ses.reserve_seq()
    wire.write_event(init_seq, "initialized", "{}")


## Launch — builds .mt and stores runnable path.
function handle_launch(ses: ref[ses_mod.Session], seq: ptr_uint, msg: proto.Message) -> void:
    let program = extract_string_arg(msg.arguments, "program")
    if program.len == 0:
        wire.write_error(seq, msg.seq, "launch requires a non-empty 'program' argument")
        return

    var resolved = util.resolve_launch_program(program)
    if not resolved.ok:
        wire.write_error(seq, msg.seq, resolved.error.as_str())
        util.release_launch_resolved(ref_of(resolved))
        return

    let stop = bool_arg(msg.arguments, "stopOnEntry", true)

    ses.program_path.release()
    ses.runnable_path.release()
    ses.program_path = string.String.from_str(program)
    ses.runnable_path = string.String.from_str(resolved.runnable_path.as_str())
    ses.stop_on_entry = stop
    ses.launched = true

    util.release_launch_resolved(ref_of(resolved))
    wire.write_response(seq, msg.seq, "{}")


## setBreakpoints — registers line breakpoints (unverified for process backend).
function handle_set_breakpoints(ses: ref[ses_mod.Session], seq: ptr_uint, msg: proto.Message) -> void:
    var requested = extract_line_breakpoints(msg.arguments)
    defer requested.release()

    var r = string.String.create()
    defer r.release()
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


## configurationDone — marks config as complete.
function handle_configuration_done(ses: ref[ses_mod.Session], seq: ptr_uint, req_seq: ptr_uint) -> void:
    ses.configuration_done = true
    wire.write_response(seq, req_seq, "{}")

    if ses.stop_on_entry:
        let stop_seq = ses.reserve_seq()
        wire.write_event(stop_seq, "stopped", "{\"reason\":\"entry\",\"threadId\":1,\"allThreadsStopped\":true}")


## Threads — single main thread.
function handle_threads(seq: ptr_uint, req_seq: ptr_uint) -> void:
    wire.write_response(seq, req_seq, "{\"threads\":[{\"id\":1,\"name\":\"main\"}]}")


## StackTrace — single entry frame.
function handle_stack_trace(ses: ref[ses_mod.Session], seq: ptr_uint, msg: proto.Message) -> void:
    let source_path = ses.program_path.as_str()
    let base = path_ops.basename(source_path)
    var r = string.String.create()
    defer r.release()
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


## Continue — acknowledges and sends continued event.
function handle_continue(ses: ref[ses_mod.Session], seq: ptr_uint, req_seq: ptr_uint) -> void:
    wire.write_response(seq, req_seq, "{\"allThreadsContinued\":true}")
    let cont_seq = ses.reserve_seq()
    wire.write_event(cont_seq, "continued", "{\"threadId\":1,\"allThreadsContinued\":true}")


## Pause — acknowledges and sends stopped event.
function handle_pause(ses: ref[ses_mod.Session], seq: ptr_uint, req_seq: ptr_uint) -> void:
    wire.write_response(seq, req_seq, "{}")
    let stop_seq = ses.reserve_seq()
    wire.write_event(stop_seq, "stopped", "{\"reason\":\"pause\",\"threadId\":1,\"allThreadsStopped\":true}")


## Terminate — kills child process.
function handle_terminate(
    ses: ref[ses_mod.Session],
    
    
    seq: ptr_uint,
    req_seq: ptr_uint,
) -> void:
    terminate_process(ses)
    wire.write_response(seq, req_seq, "{}")


## Disconnect — terminates process and exits server.
function handle_disconnect(
    ses: ref[ses_mod.Session],
    
    
    seq: ptr_uint,
    req_seq: ptr_uint,
) -> void:
    terminate_process(ses)
    wire.write_response(seq, req_seq, "{}")
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
            defer r.release()
            r.append("{\"content\":\"")
            proto.append_escaped(ref_of(r), content.as_str())
            r.append("\"}")
            wire.write_response(seq, msg.seq, r.as_str())
            content.release()
        Result.failure:
            wire.write_error(seq, msg.seq, "source file not found")


## Terminate the session gracefully.
function terminate_process(
    ses: ref[ses_mod.Session],
) -> void:
    if not ses.terminated:
        ses.terminated = true
        let tseq = ses.reserve_seq()
        wire.write_event(tseq, "terminated", "{}")
        let eseq = ses.reserve_seq()
        wire.write_event(eseq, "exited", "{\"exitCode\":0}")


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

## Dereference a ptr[
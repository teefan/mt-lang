## DAP server — JSON-RPC style message loop over stdin/stdout.  Reads DAP
## messages, dispatches to handlers, and polls child process I/O between
## dispatches.

import std.process as process
import std.str
import std.log as log
import std.string as string

import mtc.dap.handlers as handlers
import mtc.dap.process_backend as backend
import mtc.dap.protocol as proto
import mtc.dap.session as session
import mtc.dap.wire as wire


## Entry point.  Starts the DAP message loop.
public function run(args: span[str]) -> int:
    announce_backend(args)
    var ses = session.create()
    defer: session.release(ref_of(ses))

    var child = zero[process.ChildProcess]
    var has_child = false

    var running = true
    while running:
        # Poll child process output before blocking on client input.
        if has_child:
            poll_child(ref_of(ses), ref_of(child), ref_of(has_child))

        var msg_opt = proto.read_message()
        match msg_opt:
            Option.some as payload:
                if payload.value.command.len() > 0:
                    handlers.dispatch(
                        ref_of(ses),
                        ref_of(child),
                        ref_of(has_child),
                        payload.value.command.as_str(),
                        payload.value,
                    )
                proto.release_message(ref_of(payload.value))
            Option.none:
                running = false

        if ses.should_exit:
            running = false

        if has_child:
            poll_child(ref_of(ses), ref_of(child), ref_of(has_child))

    return 0


## The self-host adapter implements the `process` backend only.  The VS Code
## extension's default is `lldb-dap`, so say so instead of silently running the
## process backend (and so the log shows why stepping is unavailable).
function announce_backend(args: span[str]) -> void:
    var requested = "process"
    var i: ptr_uint = 0
    while i < args.len:
        let arg = args[i]
        if arg.starts_with("--backend="):
            requested = arg.slice(10, arg.len - 10)
            break
        if arg.equal("--backend") and i + 1 < args.len:
            requested = args[i + 1]
            break
        i += 1
    if requested.equal("process"):
        return
    var msg = string.String.create()
    msg.append("dap: backend '")
    msg.append(requested)
    msg.append("' is not implemented; running the process backend (no stepping, evaluate or variables)")
    log.warn(msg.as_str())
    msg.release()


## Poll child stdout/stderr and check for exit.
function poll_child(
    ses: ref[session.Session],
    child: ref[process.ChildProcess],
    has_child: ref[bool],
) -> void:
    var out_text = backend.poll_stdout(child, 0)
    if out_text.len() > 0:
        let seq = ses.reserve_seq()
        backend.write_output_event(seq, "stdout", out_text.as_str())
        out_text.release()
    else:
        out_text.release()

    var err_text = backend.poll_stderr(child, 0)
    if err_text.len() > 0:
        let seq = ses.reserve_seq()
        backend.write_output_event(seq, "stderr", err_text.as_str())
        err_text.release()
    else:
        err_text.release()

    # Check if child exited.
    match child.try_wait():
        Result.success as payload:
            match payload.value:
                Option.some as status:
                    let code = status.value.normalized_code()
                    let eseq = ses.reserve_seq()
                    # Build the body explicitly: `{{` is not an f-string escape in
                    # Milk Tea, it is two literal braces, which emitted
                    # `body:{{"exitCode":0}}` and broke clients parsing the frame.
                    var exit_body = string.String.create()
                    exit_body.append("{\"exitCode\":")
                    exit_body.append_format(f"#{code}")
                    exit_body.append("}")
                    wire.write_event(eseq, "exited", exit_body.as_str())
                    exit_body.release()
                    let tseq = ses.reserve_seq()
                    wire.write_event(tseq, "terminated", "{}")
                    ses.terminated = true
                    child.release()
                    unsafe: read(has_child) = false
                Option.none:
                    pass
        Result.failure:
            pass

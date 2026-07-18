## DAP server — JSON-RPC style message loop over stdin/stdout.  Reads DAP
## messages, dispatches to handlers, and polls child process I/O between
## dispatches.

import std.json as json
import std.process as process
import std.str
import std.string as string

import mtc.dap.handlers as handlers
import mtc.dap.protocol as proto
import mtc.dap.session as session
import mtc.dap.process_backend as backend


## Entry point.  Starts the DAP message loop.
public function run(args: span[str]) -> int:
    var ses = session.create()
    defer session.release(ref_of(ses))

    var child = zero[process.ChildProcess]
    var has_child = false

    var running = true
    while running:
        var msg_opt = proto.read_message()
        match msg_opt:
            Option.some as payload:
                var msg = payload.value

                if msg.command.len() > 0:
                    handlers.dispatch(ref_of(ses), ref_of(child), ref_of(has_child), msg.command.as_str(), msg)

                if ses.should_exit:
                    release_msg(ref_of(msg))
                    running = false
                else:
                    release_msg(ref_of(msg))

                if has_child:
                    poll_output(ref_of(ses), ref_of(child))
            Option.none:
                running = false

    return 0


## Poll child stdout/err for new output and forward as DAP events.
function poll_output(ses: ref[session.Session], child: ref[process.ChildProcess]) -> void:
    var out_text = backend.poll_stdout(child, 0)
    if out_text.len() > 0:
        let out_seq = ses.reserve_seq()
        backend.write_output_event(out_seq, "stdout", out_text.as_str())
        out_text.release()
    else:
        out_text.release()

    var err_text = backend.poll_stderr(child, 0)
    if err_text.len() > 0:
        let err_seq = ses.reserve_seq()
        backend.write_output_event(err_seq, "stderr", err_text.as_str())
        err_text.release()
    else:
        err_text.release()


## Release a DapMessage and its owned fields.
function release_msg(msg: ref[proto.DapMessage]) -> void:
    msg.raw_body.release()
    msg.msg_type.release()
    msg.command.release()
    msg.message.release()
    msg.dap_event.release()
    json.release_value(msg.parsed)

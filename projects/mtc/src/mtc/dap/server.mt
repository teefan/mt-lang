## DAP server — JSON-RPC style message loop over stdin/stdout.  Reads DAP
## messages, dispatches to handlers, and polls child process I/O between
## dispatches.

import std.json as json
import std.str
import std.string as string

import mtc.dap.handlers as handlers
import mtc.dap.protocol as proto
import mtc.dap.session as session


## Entry point.  Starts the DAP message loop.
public function run(args: span[str]) -> int:
    var ses = session.create()
    defer session.release(ref_of(ses))

    var running = true
    while running:
        var msg_opt = proto.read_message()
        match msg_opt:
            Option.some as payload:
                if payload.value.command.len() > 0:
                    handlers.dispatch(ref_of(ses), payload.value.command.as_str(), payload.value)
                proto.release_message(ref_of(payload.value))
            Option.none:
                running = false

        if ses.should_exit:
            running = false

    return 0


## Release a Message and its owned fields (called by the Option destructor).
function release_msg(msg: ref[proto.Message]) -> void:
    json.release_value(msg.parsed)
    msg.raw_body.release()
    msg.msg_type.release()
    msg.command.release()
    msg.message.release()
    msg.evt.release()

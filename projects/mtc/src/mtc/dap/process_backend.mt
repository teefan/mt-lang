## DAP process backend — I/O helpers for the debuggee child process.
## Polls stdout and stderr via std.process non-blocking reads and
## forwards output as DAP events.

import std.process as process
import std.str
import std.string as string
import std.vec as vec

import mtc.dap.protocol as proto
import mtc.dap.wire as wire


## Poll child process stdout for new output.  Returns output text when
## available, "" otherwise.
public function poll_stdout(child: ref[process.ChildProcess], timeout_ms: int) -> string.String:
    match child.read_stdout(timeout_ms):
        Result.success as payload:
            var data = payload.value
            if data.ready and data.has_data():
                return data.data
            data.release()
        Result.failure:
            pass
    return string.String.create()


## Poll child process stderr for new output.
public function poll_stderr(child: ref[process.ChildProcess], timeout_ms: int) -> string.String:
    match child.read_stderr(timeout_ms):
        Result.success as payload:
            var data = payload.value
            if data.ready and data.has_data():
                return data.data
            data.release()
        Result.failure:
            pass
    return string.String.create()


## Send an output event to the DAP client.
public function write_output_event(seq: ptr_uint, category: str, text: str) -> void:
    var body = string.String.create()
    defer body.release()
    body.append("{\"category\":\"")
    proto.append_escaped(ref_of(body), category)
    body.append("\",\"output\":\"")
    proto.append_escaped(ref_of(body), text)
    body.append("\"}")
    wire.write_event(seq, "output", body.as_str())

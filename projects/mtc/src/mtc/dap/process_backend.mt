## DAP process backend — launches, monitors, and controls a debuggee
## child process via std.process primitives.  Non-blocking I/O polling
## with SIGSTOP/SIGCONT for pause/continue.

import std.process as process
import std.str
import std.string as string
import std.vec as vec

import mtc.dap.protocol as proto
import mtc.dap.wire as wire


const SIGNAL_STOP:   int = 19
const SIGNAL_CONT:   int = 18
const SIGNAL_TERM:   int = 15


## Handle child process launch.  Spawns the runnable binary and stores
## process state in the session.
public function spawn_process(runnable_path: str, args: span[str], pid: ref[int]) -> Result[process.ChildProcess, process.ProcessError]:
    var command = vec.Vec[str].create()
    command.push(runnable_path)
    var ai: ptr_uint = 0
    while ai < args.len:
        unsafe:
            command.push(read(args.data + ai))
        ai += 1
    unsafe:
        var sp = span[str](data = ptr[str]<-command.data, len = command.len)
        let result = process.spawn(sp)
        command.release()
        return result


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

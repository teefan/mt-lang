## DAP session state with extending methods for sequence generation
## and state management.

import std.map as map_mod
import std.str
import std.string as string
import std.vec as vec


public struct Breakpoint:
    id: ptr_uint
    line: ptr_uint
    verified: bool
    message: string.String


public struct FunctionBreakpoint:
    id: ptr_uint
    name: string.String
    verified: bool


public struct Session:
    next_seq: ptr_uint
    next_breakpoint_id: ptr_uint
    thread_id: ptr_uint
    initialized: bool
    configuration_done: bool
    launched: bool
    terminated: bool
    should_exit: bool
    program_path: string.String
    runnable_path: string.String
    program_args: vec.Vec[string.String]
    stop_on_entry: bool
    runtime_started: bool
    runtime_pid: int
    runtime_paused: bool
    breakpoints_by_source: map_mod.Map[string.String, vec.Vec[Breakpoint]]
    function_breakpoints: vec.Vec[FunctionBreakpoint]


extending Session:
    public editable function reserve_seq() -> ptr_uint:
        let s = this.next_seq
        this.next_seq = s + 1
        return s


    public editable function reserve_breakpoint_id() -> ptr_uint:
        let id = this.next_breakpoint_id
        this.next_breakpoint_id = id + 1
        return id


public function create() -> Session:
    return Session(
        next_seq = 1,
        next_breakpoint_id = 1,
        thread_id = 1,
        initialized = false,
        configuration_done = false,
        launched = false,
        terminated = false,
        should_exit = false,
        program_path = string.String.create(),
        runnable_path = string.String.create(),
        program_args = vec.Vec[string.String].create(),
        stop_on_entry = true,
        runtime_started = false,
        runtime_pid = 0,
        runtime_paused = false,
        breakpoints_by_source = map_mod.Map[string.String, vec.Vec[Breakpoint]].create(),
        function_breakpoints = vec.Vec[FunctionBreakpoint].create(),
    )


public function release(ses: ref[Session]) -> void:
    ses.program_path.release()
    ses.runnable_path.release()
    var ai: ptr_uint = 0
    while ai < ses.program_args.len():
        let p = ses.program_args.get(ai)
        if p != null:
            unsafe: read(p).release()
        ai += 1
    ses.program_args.release()
    var entries_iter = ses.breakpoints_by_source.entries()
    while entries_iter.next():
        let entry = entries_iter.current()
        unsafe:
            var bps = read(entry.value)
            var bi: ptr_uint = 0
            while bi < bps.len():
                let bp_ptr = bps.get(bi)
                if bp_ptr != null:
                    read(bp_ptr).message.release()
                bi += 1
    ses.breakpoints_by_source.release()
    var fi: ptr_uint = 0
    while fi < ses.function_breakpoints.len():
        let fp = ses.function_breakpoints.get(fi)
        if fp != null:
            unsafe: read(fp).name.release()
        fi += 1
    ses.function_breakpoints.release()

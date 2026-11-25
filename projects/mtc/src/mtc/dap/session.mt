## DAP session state with extending methods for sequence generation
## and state management.

import std.fs as fs_mod
import std.map as map_mod
import std.mem.heap as heap
import std.str
import std.string as string
import std.vec as vec

import mtc.debug_map as debug_map

## The adapter's static capabilities (advertised for the process backend and
## merged with lldb-dap's own response by the bridge).
public const ADAPTER_CAPABILITIES: str = "{\"supportsConfigurationDoneRequest\":true,\"supportsFunctionBreakpoints\":true,\"supportsConditionalBreakpoints\":false,\"supportsHitConditionalBreakpoints\":false,\"supportsEvaluateForHovers\":false,\"supportsSetVariable\":false,\"supportTerminateDebuggee\":true,\"supportsTerminateRequest\":true,\"supportsLoadedSourcesRequest\":true,\"exceptionBreakpointFilters\":[],\"supportsPauseRequest\":true}"

public struct Breakpoint:
    id: ptr_uint
    line: ptr_uint
    verified: bool
    message: string.String

public struct FunctionBreakpoint:
    id: ptr_uint
    name: string.String
    verified: bool

## Where a variablesReference came from: its frame and (for a Locals scope)
## the function whose C names the bridge rewrites.
public struct VariableContext:
    frame_id: ptr_uint
    function: ptr[debug_map.DebugFunction]?
    has_function: bool

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
    entry_stop_emitted: bool
    backend_kind: string.String
    adapter_path: string.String
    breakpoints_by_source: map_mod.Map[string.String, vec.Vec[Breakpoint]]
    function_breakpoints: vec.Vec[FunctionBreakpoint]
    tmp_dirs: vec.Vec[string.String]
    debug_map: ptr[debug_map.DebugMap]?
    frame_functions: map_mod.Map[ptr_uint, ptr[debug_map.DebugFunction]]
    variable_contexts: map_mod.Map[ptr_uint, VariableContext]


extending Session:
    public editable function reserve_seq() -> ptr_uint:
        let s = this.next_seq
        this.next_seq = s + 1
        return s


    public editable function reserve_breakpoint_id() -> ptr_uint:
        let id = this.next_breakpoint_id
        this.next_breakpoint_id = id + 1
        return id

    ## Remember a temporary directory for cleanup on terminate/disconnect.
    public editable function remember_tmp_dir(dir: str) -> void:
        this.tmp_dirs.push(string.String.from_str(dir))

    ## Remove every remembered temporary directory (the host's
    ## `cleanup_tmp_dirs`).
    public editable function cleanup_tmp_dirs() -> void:
        var i: ptr_uint = 0
        while i < this.tmp_dirs.len():
            let dir_ptr = this.tmp_dirs.get(i)
            if dir_ptr != null:
                unsafe:
                    match fs_mod.remove_tree(read(dir_ptr).as_str()):
                        Result.success:
                            pass
                        Result.failure as failure:
                            var error = failure.error
                            error.release()
                    read(dir_ptr).release()
            i += 1
        this.tmp_dirs.clear()

    ## Replace a source's stored breakpoints with fresh ids, in order (the
    ## host's `set_breakpoints`).
    public editable function set_source_breakpoints(source_path: str, lines: span[ptr_uint]) -> void:
        var entries = vec.Vec[Breakpoint].create()
        var i: ptr_uint = 0
        while i < lines.len:
            let line = unsafe: read(lines.data + i)
            entries.push(Breakpoint(
                id = this.reserve_breakpoint_id(),
                line = line,
                verified = true,
                message = string.String.create(),
            ))
            i += 1
        var key = string.String.from_str(source_path)
        match this.breakpoints_by_source.set(key, entries):
            Option.some as previous:
                release_breakpoints(ref_of(previous.value))
            Option.none:
                pass

    ## Install a freshly loaded debug map (releasing the previous one).
    public editable function set_debug_map(loaded: debug_map.DebugMap) -> void:
        this.clear_debug_map()
        let stored = heap.must_alloc[debug_map.DebugMap](1)
        unsafe:
            read(stored) = loaded
        this.debug_map = stored

    ## Drop the map and its frame/variable-reference caches.
    public editable function clear_debug_map() -> void:
        let existing = this.debug_map
        if existing != null:
            unsafe:
                debug_map.release(ref_of(read(existing)))
                heap.release(existing)
        this.debug_map = null
        this.frame_functions.release()
        this.frame_functions = map_mod.Map[ptr_uint, ptr[debug_map.DebugFunction]].create()
        this.variable_contexts.release()
        this.variable_contexts = map_mod.Map[ptr_uint, VariableContext].create()


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
        entry_stop_emitted = false,
        backend_kind = string.String.from_str("process"),
        adapter_path = string.String.create(),
        breakpoints_by_source = map_mod.Map[string.String, vec.Vec[Breakpoint]].create(),
        function_breakpoints = vec.Vec[FunctionBreakpoint].create(),
        tmp_dirs = vec.Vec[string.String].create(),
        debug_map = null,
        frame_functions = map_mod.Map[ptr_uint, ptr[debug_map.DebugFunction]].create(),
        variable_contexts = map_mod.Map[ptr_uint, VariableContext].create(),
    )


public function release(ses: ref[Session]) -> void:
    ses.program_path.release()
    ses.runnable_path.release()
    ses.backend_kind.release()
    ses.adapter_path.release()
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

    var ti: ptr_uint = 0
    while ti < ses.tmp_dirs.len():
        let dir_ptr = ses.tmp_dirs.get(ti)
        if dir_ptr != null:
            unsafe: read(dir_ptr).release()
        ti += 1
    ses.tmp_dirs.release()

    ses.clear_debug_map()
    ses.frame_functions.release()
    ses.variable_contexts.release()


## Release a stored breakpoint vector and every entry's message.
function release_breakpoints(entries: ref[vec.Vec[Breakpoint]]) -> void:
    var i: ptr_uint = 0
    while i < entries.len():
        unsafe:
            let entry = entries.get(i)
            if entry != null:
                read(entry).message.release()
        i += 1
    entries.release()

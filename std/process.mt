import std.c.process as c
import std.mem.arena as arena
import std.mem.heap as heap
import std.str as text
import std.string as string
import std.vec as vec

public struct EnvironmentEntry:
    name: str
    value: str

public struct ExitStatus:
    exit_code: long
    term_signal: int

public struct CaptureResult:
    stdout: string.String
    stderr: string.String
    status: ExitStatus

public struct ProcessError:
    code: int
    message: string.String

public struct ReadResult:
    ready: bool
    closed: bool
    data: string.String

public struct ChildProcess:
    pid: int
    stdin_fd: int
    stdout_fd: int
    stderr_fd: int

public struct PtyProcess:
    pid: int
    master_fd: int

struct PreparedCommand:
    storage: arena.Arena
    file: cstr
    args: ptr[ptr[char]]
    env: ptr[ptr[char]]?
    cwd: cstr?


function take_owned_string(data: ptr[char]?, len: ptr_uint) -> string.String:
    if data == null:
        if len != 0:
            fatal(c"process.take_owned_string missing storage")

        return string.String.create()

    return unsafe: string.String(data = ptr[ubyte]<-data, len = len, capacity = len, owns_storage = true)


function safe_text_view(value: string.String) -> Option[str]:
    return text.utf8_byte_span_as_str(unsafe: span[ubyte](data = ptr[ubyte]<-value.data, len = value.len))


function empty_environment() -> span[EnvironmentEntry]:
    return zero[span[EnvironmentEntry]]


## Returns the parent process's environment entries. Each entry is a
## "NAME=VALUE" string parsed from the POSIX `environ` array. Entries
## with empty names (broken entries) are silently skipped.
public function parent_environment() -> vec.Vec[EnvironmentEntry]:
    var result = vec.Vec[EnvironmentEntry].create()
    let count = c.mt_process_environ_length()
    if count == 0:
        return result
    result.reserve(count)
    unsafe:
        let raw_ptr_opt = c.mt_process_environ_accessor()
        if raw_ptr_opt == null:
            return result
        let env_array = read(raw_ptr_opt)
        var i: ptr_uint = 0
        while i < count:
            let entry_cstr = read(env_array + i)
            let len = find_null_byte(entry_cstr, 0)
            if len == 0:
                i += 1
                continue
            var eq_pos: ptr_uint = 0
            while eq_pos < len and read(entry_cstr + eq_pos) != 61:
                eq_pos += 1
            if eq_pos == 0 or eq_pos >= len:
                i += 1
                continue
            var nname = string.String.create()
            nname.reserve(eq_pos)
            var ni: ptr_uint = 0
            while ni < eq_pos:
                nname.push_byte(ubyte<-(unsafe: read(entry_cstr + ni)))
                ni += 1
            var nvalue = string.String.create()
            let vlen = len - eq_pos - 1
            if vlen > 0:
                nvalue.reserve(vlen)
                var vi: ptr_uint = 0
                while vi < vlen:
                    nvalue.push_byte(ubyte<-(unsafe: read(entry_cstr + eq_pos + 1 + vi)))
                    vi += 1
            result.push(EnvironmentEntry(
                name = nname.as_str(),
                value = nvalue.as_str()
            ))
            i += 1
    return result


## Scan `data` (pointer to a NUL-terminated buffer) from `start` for the
## first 0 byte. Returns the byte offset at which the NUL was found.
function find_null_byte(data: ptr[char], start: ptr_uint) -> ptr_uint:
    var i = start
    unsafe:
        while read(data + i) != 0:
            i += 1
    return i


## Like `capture` but inherits the parent environment and merges
## `extra_env` entries (extra entries override parent entries with the
## same name). When `extra_env` is empty, identical to `capture`.
public function capture_inheriting_env(
    command: span[str],
    cwd: Option[str],
    extra_env: span[EnvironmentEntry]
) -> Result[CaptureResult, ProcessError]:
    if extra_env.len == 0:
        return capture_internal(command, cwd, empty_environment())
    var env_vec = parent_environment()
    merge_environment(ref_of(env_vec), extra_env)
    let env_span = env_vec.as_span()
    let result = capture_internal(command, cwd, env_span)
    env_vec.release()
    return result


## Like `spawn` but inherits the parent environment and merges
## `extra_env` entries.
public function spawn_inheriting_env(
    command: span[str],
    cwd: Option[str],
    extra_env: span[EnvironmentEntry]
) -> Result[ChildProcess, ProcessError]:
    if extra_env.len == 0:
        return spawn_internal(command, cwd, empty_environment())
    var env_vec = parent_environment()
    merge_environment(ref_of(env_vec), extra_env)
    let env_span = env_vec.as_span()
    let result = spawn_internal(command, cwd, env_span)
    env_vec.release()
    return result


## Merge `extra` entries into `base`, overwriting base entries that share
## the same name. New entries (names not in base) are appended.
function merge_environment(base: ref[vec.Vec[EnvironmentEntry]], extra: span[EnvironmentEntry]) -> void:
    var ei: ptr_uint = 0
    while ei < extra.len:
        let entry = unsafe: read(extra.data + ei)
        var found = false
        var bi: ptr_uint = 0
        while bi < base.len():
            let bp = base.get(bi) else:
                break
            if unsafe: read(bp).name.equal(entry.name):
                unsafe: read(bp) = entry
                found = true
                break
            bi += 1
        if not found:
            base.push(entry)
        ei += 1


function pointer_storage_bytes(count: ptr_uint) -> ptr_uint:
    let pointer_size = size_of(ptr[char])
    if heap.mul_overflows(count, pointer_size):
        fatal(c"process pointer storage overflow")

    return count * pointer_size


function clear_pointer_slot(slot: ptr[ptr[char]]) -> void:
    let slot_bytes = size_of(ptr[char])
    var index: ptr_uint = 0
    unsafe:
        let buffer = ptr[ubyte]<-slot
        while index < slot_bytes:
            read(buffer + index) = 0
            index += 1


function total_storage_bytes(command: span[str], cwd: Option[str], env: span[EnvironmentEntry]) -> ptr_uint:
    var total = pointer_storage_bytes(command.len + 1)
    if env.len != 0:
        total += pointer_storage_bytes(env.len + 1)

    var index: ptr_uint = 0
    while index < command.len:
        let value = unsafe: read(command.data + index)
        if total > heap.ptr_uint_max - (value.len + 1):
            fatal(c"process command storage overflow")
        total += value.len + 1
        index += 1

    match cwd:
        Option.some as payload:
            if total > heap.ptr_uint_max - (payload.value.len + 1):
                fatal(c"process cwd storage overflow")
            total += payload.value.len + 1
        Option.none:
            pass

    index = 0
    while index < env.len:
        let entry = unsafe: read(env.data + index)
        if total > heap.ptr_uint_max - (entry.name.len + 1):
            fatal(c"process env storage overflow")
        total += entry.name.len + 1
        if total > heap.ptr_uint_max - (entry.value.len + 1):
            fatal(c"process env storage overflow")
        total += entry.value.len + 1
        index += 1

    return total


function write_environment_value(space: ref[arena.Arena], entry: EnvironmentEntry) -> cstr:
    let size_bytes = entry.name.len + entry.value.len + 2
    let memory = space.alloc_bytes(size_bytes) else:
        fatal(c"process env storage exhausted")

    unsafe:
        let buffer = ptr[char]<-memory
        if entry.name.len != 0:
            heap.copy_bytes(ptr[ubyte]<-buffer, ptr[ubyte]<-entry.name.data, entry.name.len)
        read(ptr[ubyte]<-buffer + entry.name.len) = 61
        if entry.value.len != 0:
            heap.copy_bytes(ptr[ubyte]<-buffer + entry.name.len + 1, ptr[ubyte]<-entry.value.data, entry.value.len)
        read(buffer + entry.name.len + 1 + entry.value.len) = zero[char]
        return cstr<-buffer


function prepare_command(
    command: span[str],
    cwd: Option[str],
    env: span[EnvironmentEntry]
) -> Result[PreparedCommand, ProcessError]:
    if command.len == 0:
        return Result[PreparedCommand, ProcessError].failure(error= ProcessError(
            code = -1,
            message = string.String.from_str("process command cannot be empty")
        ))

    let total_bytes = total_storage_bytes(command, cwd, env)
    var storage = arena.create_aligned(total_bytes, align_of(ptr[char]))

    let allocated_args = storage.alloc[ptr[char]](command.len + 1) else:
        fatal(c"process args storage exhausted")

    let args_ptr = unsafe: allocated_args

    var env_ptr: ptr[ptr[char]]? = null
    var env_storage: ptr[ptr[char]]? = null
    if env.len != 0:
        let allocated = storage.alloc[ptr[char]](env.len + 1) else:
            fatal(c"process env pointer storage exhausted")

        let allocated_ptr = unsafe: allocated
        env_ptr = allocated_ptr
        env_storage = allocated_ptr

    var index: ptr_uint = 0
    while index < command.len:
        let value = unsafe: read(command.data + index)
        unsafe: read(args_ptr + index) = ptr[char]<-storage.to_cstr(value)
        index += 1

    unsafe: clear_pointer_slot(args_ptr + command.len)

    if env.len != 0:
        let allocated_ptr = env_storage else:
            fatal(c"process env pointer storage missing")

        let env_storage_ptr = unsafe: allocated_ptr
        index = 0
        while index < env.len:
            let entry = unsafe: read(env.data + index)
            unsafe: read(env_storage_ptr + index) = ptr[char]<-write_environment_value(ref_of(storage), entry)
            index += 1

        unsafe: clear_pointer_slot(env_storage_ptr + env.len)

    let file = unsafe: cstr<-read(args_ptr)
    var prepared_cwd: cstr? = null
    match cwd:
        Option.some as payload:
            prepared_cwd = storage.to_cstr(payload.value)
        Option.none:
            pass

    return Result[PreparedCommand, ProcessError].success(
        value= PreparedCommand(storage = storage, file = file, args = args_ptr, env = env_ptr, cwd = prepared_cwd)
    )


function take_process_error(raw: c.mt_process_error) -> ProcessError:
    if raw.message_data == null and raw.message_len == 0:
        return ProcessError(code = raw.code, message = string.String.from_str("process failed"))

    return ProcessError(code = raw.code, message = take_owned_string(raw.message_data, raw.message_len))


function simple_process_error(message: str) -> ProcessError:
    return ProcessError(code = -1, message = string.String.from_str(message))


function take_read_result(raw: c.mt_process_read_result) -> ReadResult:
    return ReadResult(ready = raw.ready, closed = raw.closed, data = take_owned_string(raw.data, raw.len))


function take_wait_status(raw: c.mt_process_wait_result) -> ExitStatus:
    return ExitStatus(exit_code = raw.exit_status, term_signal = raw.term_signal)


function close_fd_quiet(fd: int) -> void:
    if fd < 0:
        return

    var raw_error = zero[c.mt_process_error]
    c.mt_process_close_fd(fd, raw_error)


function close_fd_checked(fd: int) -> Result[bool, ProcessError]:
    if fd < 0:
        return Result[bool, ProcessError].success(value= true)

    var raw_error = zero[c.mt_process_error]
    let status = c.mt_process_close_fd(fd, raw_error)
    if status != 0:
        return Result[bool, ProcessError].failure(error= take_process_error(raw_error))

    return Result[bool, ProcessError].success(value= true)


function read_fd_internal(fd: int, timeout_ms: int) -> Result[ReadResult, ProcessError]:
    if fd < 0:
        return Result[ReadResult, ProcessError].failure(error= simple_process_error("process stream is closed"))

    var raw_result = zero[c.mt_process_read_result]
    var raw_error = zero[c.mt_process_error]
    let status = c.mt_process_read_fd(fd, timeout_ms, raw_result, raw_error)
    if status != 0:
        return Result[ReadResult, ProcessError].failure(error= take_process_error(raw_error))

    return Result[ReadResult, ProcessError].success(value= take_read_result(raw_result))


function write_fd_internal(fd: int, value: str) -> Result[ptr_uint, ProcessError]:
    if fd < 0:
        return Result[ptr_uint, ProcessError].failure(error= simple_process_error("process stream is closed"))

    var data: const_ptr[char]? = null
    if value.len != 0:
        data = unsafe: const_ptr[char]<-value.data

    var written: ptr_uint = 0
    var raw_error = zero[c.mt_process_error]
    let status = c.mt_process_write_fd(fd, data, value.len, written, raw_error)
    if status != 0:
        return Result[ptr_uint, ProcessError].failure(error= take_process_error(raw_error))

    return Result[ptr_uint, ProcessError].success(value= written)


function wait_internal(pid: int, non_blocking: bool) -> Result[Option[ExitStatus], ProcessError]:
    if pid <= 0:
        return Result[Option[ExitStatus], ProcessError].failure(error= simple_process_error("process pid is invalid"))

    var raw_result = zero[c.mt_process_wait_result]
    var raw_error = zero[c.mt_process_error]
    var status = 0
    if non_blocking:
        status = c.mt_process_try_wait(pid, raw_result, raw_error)
    else:
        status = c.mt_process_wait(pid, raw_result, raw_error)

    if status != 0:
        return Result[Option[ExitStatus], ProcessError].failure(error= take_process_error(raw_error))

    if not raw_result.ready:
        return Result[Option[ExitStatus], ProcessError].success(value= Option[ExitStatus].none)

    return Result[
        Option[ExitStatus],
        ProcessError
    ].success(value= Option[ExitStatus].some(value= take_wait_status(raw_result)))


function kill_internal(pid: int, signal: int) -> Result[bool, ProcessError]:
    if pid <= 0:
        return Result[bool, ProcessError].failure(error= simple_process_error("process pid is invalid"))

    var raw_error = zero[c.mt_process_error]
    let status = c.mt_process_kill(pid, signal, raw_error)
    if status != 0:
        return Result[bool, ProcessError].failure(error= take_process_error(raw_error))

    return Result[bool, ProcessError].success(value= true)


function resize_pty_internal(fd: int, columns: int, rows: int) -> Result[bool, ProcessError]:
    if fd < 0:
        return Result[bool, ProcessError].failure(error= simple_process_error("process stream is closed"))

    var raw_error = zero[c.mt_process_error]
    let status = c.mt_process_pty_resize(fd, columns, rows, raw_error)
    if status != 0:
        return Result[bool, ProcessError].failure(error= take_process_error(raw_error))

    return Result[bool, ProcessError].success(value= true)


function spawn_internal(
    command: span[str],
    cwd: Option[str],
    env: span[EnvironmentEntry]
) -> Result[ChildProcess, ProcessError]:
    let prepared_result = prepare_command(command, cwd, env)
    match prepared_result:
        Result.failure as payload:
            return Result[ChildProcess, ProcessError].failure(error= payload.error)
        Result.success as payload:
            var prepared = payload.value
            defer prepared.release()

            var raw_handle = zero[c.mt_process_spawn_handle]
            var raw_error = zero[c.mt_process_error]
            let status = c.mt_process_spawn_interactive(
                prepared.file,
                prepared.args,
                prepared.env,
                prepared.cwd,
                raw_handle,
                raw_error
            )
            if status != 0:
                return Result[ChildProcess, ProcessError].failure(error= take_process_error(raw_error))

            return Result[ChildProcess, ProcessError].success(
                value= ChildProcess(
                    pid = raw_handle.pid,
                    stdin_fd = raw_handle.stdin_fd,
                    stdout_fd = raw_handle.stdout_fd,
                    stderr_fd = raw_handle.stderr_fd
                )
            )


function spawn_pty_internal(
    command: span[str],
    cwd: Option[str],
    env: span[EnvironmentEntry],
    columns: int,
    rows: int
) -> Result[PtyProcess, ProcessError]:
    if columns <= 0 or rows <= 0:
        return Result[PtyProcess, ProcessError].failure(error= simple_process_error("pty size must be positive"))

    let prepared_result = prepare_command(command, cwd, env)
    match prepared_result:
        Result.failure as payload:
            return Result[PtyProcess, ProcessError].failure(error= payload.error)
        Result.success as payload:
            var prepared = payload.value
            defer prepared.release()

            var raw_handle = zero[c.mt_process_pty_handle]
            var raw_error = zero[c.mt_process_error]
            let status = c.mt_process_spawn_pty(
                prepared.file,
                prepared.args,
                prepared.env,
                prepared.cwd,
                columns,
                rows,
                raw_handle,
                raw_error
            )
            if status != 0:
                return Result[PtyProcess, ProcessError].failure(error= take_process_error(raw_error))

            return Result[PtyProcess, ProcessError].success(value= PtyProcess(
                pid = raw_handle.pid,
                master_fd = raw_handle.master_fd
            ))


function capture_internal(
    command: span[str],
    cwd: Option[str],
    env: span[EnvironmentEntry]
) -> Result[CaptureResult, ProcessError]:
    let prepared_result = prepare_command(command, cwd, env)
    match prepared_result:
        Result.failure as payload:
            return Result[CaptureResult, ProcessError].failure(error= payload.error)
        Result.success as payload:
            var prepared = payload.value
            defer prepared.release()

            var raw_result = zero[c.mt_process_capture_result]
            var raw_error = zero[c.mt_process_error]
            let status_code = c.mt_process_capture(
                prepared.file,
                prepared.args,
                prepared.env,
                prepared.cwd,
                raw_result,
                raw_error
            )
            if status_code != 0:
                return Result[CaptureResult, ProcessError].failure(error= take_process_error(raw_error))

            return Result[CaptureResult, ProcessError].success(
                value= CaptureResult(
                    stdout = take_owned_string(raw_result.stdout_data, raw_result.stdout_len),
                    stderr = take_owned_string(raw_result.stderr_data, raw_result.stderr_len),
                    status = ExitStatus(exit_code = raw_result.exit_status, term_signal = raw_result.term_signal)
                )
            )


function spawn_detached_internal(
    command: span[str],
    cwd: Option[str],
    env: span[EnvironmentEntry]
) -> Result[int, ProcessError]:
    let prepared_result = prepare_command(command, cwd, env)
    match prepared_result:
        Result.failure as payload:
            return Result[int, ProcessError].failure(error= payload.error)
        Result.success as payload:
            var prepared = payload.value
            defer prepared.release()

            var pid: int = 0
            var raw_error = zero[c.mt_process_error]
            let status_code = c.mt_process_spawn_detached(
                prepared.file,
                prepared.args,
                prepared.env,
                prepared.cwd,
                pid,
                raw_error
            )
            if status_code != 0:
                return Result[int, ProcessError].failure(error= take_process_error(raw_error))

            return Result[int, ProcessError].success(value= pid)


extending ExitStatus:
    public function success() -> bool:
        return this.exit_code == 0 and this.term_signal == 0


    public function normalized_code() -> int:
        if this.term_signal != 0:
            return 128 + this.term_signal

        return int<-this.exit_code


extending CaptureResult:
    public function success() -> bool:
        return this.status.success()


    public function stdout_text() -> Option[str]:
        return safe_text_view(this.stdout)


    public function stderr_text() -> Option[str]:
        return safe_text_view(this.stderr)


    public editable function release() -> void:
        this.stdout.release()
        this.stderr.release()


extending ReadResult:
    public function text() -> Option[str]:
        return safe_text_view(this.data)


    public function has_data() -> bool:
        return this.data.len != 0


    public editable function release() -> void:
        this.data.release()


extending ChildProcess:
    public function read_stdout(timeout_ms: int) -> Result[ReadResult, ProcessError]:
        return read_fd_internal(this.stdout_fd, timeout_ms)


    public function read_stderr(timeout_ms: int) -> Result[ReadResult, ProcessError]:
        return read_fd_internal(this.stderr_fd, timeout_ms)


    public function write_stdin(value: str) -> Result[ptr_uint, ProcessError]:
        return write_fd_internal(this.stdin_fd, value)


    public editable function close_stdin() -> Result[bool, ProcessError]:
        match close_fd_checked(this.stdin_fd):
            Result.failure as payload:
                return Result[bool, ProcessError].failure(error= payload.error)
            Result.success as payload:
                this.stdin_fd = -1
                return Result[bool, ProcessError].success(value= payload.value)


    public editable function close_stdout() -> Result[bool, ProcessError]:
        match close_fd_checked(this.stdout_fd):
            Result.failure as payload:
                return Result[bool, ProcessError].failure(error= payload.error)
            Result.success as payload:
                this.stdout_fd = -1
                return Result[bool, ProcessError].success(value= payload.value)


    public editable function close_stderr() -> Result[bool, ProcessError]:
        match close_fd_checked(this.stderr_fd):
            Result.failure as payload:
                return Result[bool, ProcessError].failure(error= payload.error)
            Result.success as payload:
                this.stderr_fd = -1
                return Result[bool, ProcessError].success(value= payload.value)


    public editable function wait() -> Result[ExitStatus, ProcessError]:
        let wait_result = wait_internal(this.pid, false)
        match wait_result:
            Result.failure as payload:
                return Result[ExitStatus, ProcessError].failure(error= payload.error)
            Result.success as payload:
                match payload.value:
                    Option.some as status_payload:
                        this.pid = 0
                        return Result[ExitStatus, ProcessError].success(value= status_payload.value)
                    Option.none:
                        return Result[
                            ExitStatus,
                            ProcessError
                        ].failure(error= simple_process_error("process wait returned no status"))


    public editable function try_wait() -> Result[Option[ExitStatus], ProcessError]:
        let wait_result = wait_internal(this.pid, true)
        match wait_result:
            Result.failure as payload:
                return Result[Option[ExitStatus], ProcessError].failure(error= payload.error)
            Result.success as payload:
                match payload.value:
                    Option.some as status_payload:
                        this.pid = 0
                        return Result[
                            Option[ExitStatus],
                            ProcessError
                        ].success(value= Option[ExitStatus].some(value= status_payload.value))
                    Option.none:
                        return Result[Option[ExitStatus], ProcessError].success(value= Option[ExitStatus].none)


    public function kill(signal: int) -> Result[bool, ProcessError]:
        return kill_internal(this.pid, signal)


    public editable function release() -> void:
        close_fd_quiet(this.stdin_fd)
        close_fd_quiet(this.stdout_fd)
        close_fd_quiet(this.stderr_fd)
        this.stdin_fd = -1
        this.stdout_fd = -1
        this.stderr_fd = -1


extending PtyProcess:
    public function read(timeout_ms: int) -> Result[ReadResult, ProcessError]:
        return read_fd_internal(this.master_fd, timeout_ms)


    public function write(value: str) -> Result[ptr_uint, ProcessError]:
        return write_fd_internal(this.master_fd, value)


    public function resize(columns: int, rows: int) -> Result[bool, ProcessError]:
        return resize_pty_internal(this.master_fd, columns, rows)


    public editable function close() -> Result[bool, ProcessError]:
        match close_fd_checked(this.master_fd):
            Result.failure as payload:
                return Result[bool, ProcessError].failure(error= payload.error)
            Result.success as payload:
                this.master_fd = -1
                return Result[bool, ProcessError].success(value= payload.value)


    public editable function wait() -> Result[ExitStatus, ProcessError]:
        let wait_result = wait_internal(this.pid, false)
        match wait_result:
            Result.failure as payload:
                return Result[ExitStatus, ProcessError].failure(error= payload.error)
            Result.success as payload:
                match payload.value:
                    Option.some as status_payload:
                        this.pid = 0
                        return Result[ExitStatus, ProcessError].success(value= status_payload.value)
                    Option.none:
                        return Result[
                            ExitStatus,
                            ProcessError
                        ].failure(error= simple_process_error("process wait returned no status"))


    public editable function try_wait() -> Result[Option[ExitStatus], ProcessError]:
        let wait_result = wait_internal(this.pid, true)
        match wait_result:
            Result.failure as payload:
                return Result[Option[ExitStatus], ProcessError].failure(error= payload.error)
            Result.success as payload:
                match payload.value:
                    Option.some as status_payload:
                        this.pid = 0
                        return Result[
                            Option[ExitStatus],
                            ProcessError
                        ].success(value= Option[ExitStatus].some(value= status_payload.value))
                    Option.none:
                        return Result[Option[ExitStatus], ProcessError].success(value= Option[ExitStatus].none)


    public function kill(signal: int) -> Result[bool, ProcessError]:
        return kill_internal(this.pid, signal)


    public editable function release() -> void:
        close_fd_quiet(this.master_fd)
        this.master_fd = -1


extending ProcessError:
    public editable function release() -> void:
        this.message.release()


extending PreparedCommand:
    editable function release() -> void:
        this.storage.release()


public function capture(command: span[str]) -> Result[CaptureResult, ProcessError]:
    return capture_internal(command, Option[str].none, empty_environment())


public function capture_in(command: span[str], cwd: str) -> Result[CaptureResult, ProcessError]:
    return capture_internal(command, Option[str].some(value= cwd), empty_environment())


public function capture_with_env(
    command: span[str],
    cwd: Option[str],
    env: span[EnvironmentEntry]
) -> Result[CaptureResult, ProcessError]:
    return capture_internal(command, cwd, env)


public function spawn(command: span[str]) -> Result[ChildProcess, ProcessError]:
    return spawn_internal(command, Option[str].none, empty_environment())


public function spawn_in(command: span[str], cwd: str) -> Result[ChildProcess, ProcessError]:
    return spawn_internal(command, Option[str].some(value= cwd), empty_environment())


public function spawn_with_env(
    command: span[str],
    cwd: Option[str],
    env: span[EnvironmentEntry]
) -> Result[ChildProcess, ProcessError]:
    return spawn_internal(command, cwd, env)


public function spawn_pty(command: span[str], columns: int, rows: int) -> Result[PtyProcess, ProcessError]:
    return spawn_pty_internal(command, Option[str].none, empty_environment(), columns, rows)


public function spawn_pty_in(command: span[str], cwd: str, columns: int, rows: int) -> Result[PtyProcess, ProcessError]:
    return spawn_pty_internal(command, Option[str].some(value= cwd), empty_environment(), columns, rows)


public function spawn_pty_with_env(
    command: span[str],
    cwd: Option[str],
    env: span[EnvironmentEntry],
    columns: int,
    rows: int
) -> Result[PtyProcess, ProcessError]:
    return spawn_pty_internal(command, cwd, env, columns, rows)


public function spawn_detached(command: span[str]) -> Result[int, ProcessError]:
    return spawn_detached_internal(command, Option[str].none, empty_environment())


public function spawn_detached_in(command: span[str], cwd: str) -> Result[int, ProcessError]:
    return spawn_detached_internal(command, Option[str].some(value= cwd), empty_environment())


public function spawn_detached_with_env(
    command: span[str],
    cwd: Option[str],
    env: span[EnvironmentEntry]
) -> Result[int, ProcessError]:
    return spawn_detached_internal(command, cwd, env)

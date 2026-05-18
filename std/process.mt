import std.c.process as c
import std.mem.arena as arena
import std.mem.heap as heap
import std.str as text
import std.string as string


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

    return unsafe: string.String(data = ptr[ubyte]<-data, len = len, capacity = len)


function safe_text_view(value: string.String) -> Option[str]:
    return text.utf8_byte_span_as_str(unsafe: span[ubyte](data = ptr[ubyte]<-value.data, len = value.len))


function empty_environment() -> span[EnvironmentEntry]:
    return zero[span[EnvironmentEntry]]


function pointer_storage_bytes(count: ptr_uint) -> ptr_uint:
    let pointer_size = ptr_uint<-size_of(ptr[char])
    if heap.mul_overflows(count, pointer_size):
        fatal(c"process pointer storage overflow")

    return count * pointer_size


function clear_pointer_slot(slot: ptr[ptr[char]]) -> void:
    let slot_bytes = ptr_uint<-size_of(ptr[char])
    var index: ptr_uint = 0
    unsafe:
        let buffer = ptr[ubyte]<-slot
        while index < slot_bytes:
            read(buffer + index) = ubyte<-0
            index += 1


function total_storage_bytes(command: span[str], cwd: Option[str], env: span[EnvironmentEntry]) -> ptr_uint:
    var total = pointer_storage_bytes(command.len + 1)
    if env.len != 0:
        total += pointer_storage_bytes(env.len + 1)

    var index: ptr_uint = 0
    while index < command.len:
        let value = unsafe: read(command.data + index)
        if total > heap.ptr_uint_max() - (value.len + 1):
            fatal(c"process command storage overflow")
        total += value.len + 1
        index += 1

    match cwd:
        Option.some as payload:
            if total > heap.ptr_uint_max() - (payload.value.len + 1):
                fatal(c"process cwd storage overflow")
            total += payload.value.len + 1
        Option.none:
            pass

    index = 0
    while index < env.len:
        let entry = unsafe: read(env.data + index)
        if total > heap.ptr_uint_max() - (entry.name.len + 1):
            fatal(c"process env storage overflow")
        total += entry.name.len + 1
        if total > heap.ptr_uint_max() - (entry.value.len + 1):
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
        read(ptr[ubyte]<-buffer + entry.name.len) = ubyte<-61
        if entry.value.len != 0:
            heap.copy_bytes(ptr[ubyte]<-buffer + entry.name.len + 1, ptr[ubyte]<-entry.value.data, entry.value.len)
        read(buffer + entry.name.len + 1 + entry.value.len) = zero[char]
        return cstr<-buffer


function prepare_command(command: span[str], cwd: Option[str], env: span[EnvironmentEntry]) -> Result[PreparedCommand, ProcessError]:
    if command.len == 0:
        return Result[PreparedCommand, ProcessError].failure(error= ProcessError(code = -1, message = string.String.from_str("process command cannot be empty")))

    let total_bytes = total_storage_bytes(command, cwd, env)
    var storage = arena.create_aligned(total_bytes, ptr_uint<-align_of(ptr[char]))

    let allocated_args = storage.alloc[ptr[char]](command.len + 1) else:
        fatal(c"process args storage exhausted")

    let args_ptr = unsafe: ptr[ptr[char]]<-allocated_args

    var env_ptr: ptr[ptr[char]]? = null
    var env_storage: ptr[ptr[char]]? = null
    if env.len != 0:
        let allocated = storage.alloc[ptr[char]](env.len + 1) else:
            fatal(c"process env pointer storage exhausted")

        let allocated_ptr = unsafe: ptr[ptr[char]]<-allocated
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

        let env_storage_ptr = unsafe: ptr[ptr[char]]<-allocated_ptr
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


function capture_internal(command: span[str], cwd: Option[str], env: span[EnvironmentEntry]) -> Result[CaptureResult, ProcessError]:
    let prepared_result = prepare_command(command, cwd, env)
    match prepared_result:
        Result.failure as payload:
            return Result[CaptureResult, ProcessError].failure(error= payload.error)
        Result.success as payload:
            var prepared = payload.value
            defer prepared.release()

            var raw_result = zero[c.mt_process_capture_result]
            var raw_error = zero[c.mt_process_error]
            let status_code = unsafe: c.mt_process_capture(prepared.file, prepared.args, prepared.env, prepared.cwd, raw_result, raw_error)
            if status_code != 0:
                return Result[CaptureResult, ProcessError].failure(error= take_process_error(raw_error))

            return Result[CaptureResult, ProcessError].success(
                value= CaptureResult(
                    stdout = take_owned_string(raw_result.stdout_data, raw_result.stdout_len),
                    stderr = take_owned_string(raw_result.stderr_data, raw_result.stderr_len),
                    status = ExitStatus(exit_code = raw_result.exit_status, term_signal = raw_result.term_signal),
                )
            )


function spawn_detached_internal(command: span[str], cwd: Option[str], env: span[EnvironmentEntry]) -> Result[int, ProcessError]:
    let prepared_result = prepare_command(command, cwd, env)
    match prepared_result:
        Result.failure as payload:
            return Result[int, ProcessError].failure(error= payload.error)
        Result.success as payload:
            var prepared = payload.value
            defer prepared.release()

            var pid: int = 0
            var raw_error = zero[c.mt_process_error]
            let status_code = unsafe: c.mt_process_spawn_detached(prepared.file, prepared.args, prepared.env, prepared.cwd, pid, raw_error)
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


    public mutable function release() -> void:
        this.stdout.release()
        this.stderr.release()


extending ProcessError:
    public mutable function release() -> void:
        this.message.release()


extending PreparedCommand:
    mutable function release() -> void:
        this.storage.release()


public function capture(command: span[str]) -> Result[CaptureResult, ProcessError]:
    return capture_internal(command, Option[str].none, empty_environment())


public function capture_in(command: span[str], cwd: str) -> Result[CaptureResult, ProcessError]:
    return capture_internal(command, Option[str].some(value= cwd), empty_environment())


public function capture_with_env(command: span[str], cwd: Option[str], env: span[EnvironmentEntry]) -> Result[CaptureResult, ProcessError]:
    return capture_internal(command, cwd, env)


public function spawn_detached(command: span[str]) -> Result[int, ProcessError]:
    return spawn_detached_internal(command, Option[str].none, empty_environment())


public function spawn_detached_in(command: span[str], cwd: str) -> Result[int, ProcessError]:
    return spawn_detached_internal(command, Option[str].some(value= cwd), empty_environment())


public function spawn_detached_with_env(command: span[str], cwd: Option[str], env: span[EnvironmentEntry]) -> Result[int, ProcessError]:
    return spawn_detached_internal(command, cwd, env)

import std.async as aio
import std.async.libuv_runtime as aio_backend
import std.bytes as bytes
import std.c.tls as c
import std.fmt as fmt
import std.libuv as libuv
import std.mem.arena as arena
import std.mem.heap as heap
import std.net as net
import std.str as text
import std.string as string
import std.vec as vec

type NativeHandle = libuv.uv_handle_t
type NativePollHandle = libuv.uv_poll_t

const tls_io_ready: int = 0
const tls_io_want_read: int = 1
const tls_io_want_write: int = 2
const tls_io_eof: int = 3


public struct Error:
    code: int
    message: string.String


public struct Stream:
    state: ptr[StreamState]?


struct StreamState:
    client: ptr[c.mt_tls_client]?
    tcp: net.TcpStream
    fd: int
    pending_operation: bool


struct PollState:
    ready: bool
    status_code: int
    revents: int
    error: Error
    error_owned: bool
    waiter_frame: ptr[void]?
    waiter: fn(frame: ptr[void]) -> void
    waiter_registered: bool
    handle: ptr[NativePollHandle]?
    closing: bool
    closed: bool
    released: bool


function take_owned_string(data: ptr[char]?, len: ptr_uint) -> string.String:
    if data == null:
        if len != 0:
            fatal(c"tls.take_owned_string missing storage")

        return string.String.create()

    return unsafe: string.String(data = ptr[ubyte]<-data, len = len, capacity = len, owns_storage = true)


function take_owned_bytes(data: ptr[ubyte]?, len: ptr_uint) -> bytes.Bytes:
    if data == null:
        if len != 0:
            fatal(c"tls.take_owned_bytes missing storage")

        return bytes.Bytes.empty()

    return bytes.Bytes(data = data, len = len)


function take_error(raw: c.mt_tls_error, fallback: str) -> Error:
    if raw.message_data == null and raw.message_len == 0:
        return Error(code = raw.code, message = string.String.from_str(fallback))

    return Error(code = raw.code, message = take_owned_string(raw.message_data, raw.message_len))


function take_net_error(raw: net.Error) -> Error:
    return Error(code = raw.code, message = raw.message)


function empty_error() -> Error:
    return Error(code = 0, message = string.String.create())


function tls_error(message: str) -> Error:
    return Error(code = -1, message = string.String.from_str(message))


function libuv_error(code: int) -> Error:
    return Error(code = code, message = string.String.from_str(text.cstr_as_str(libuv.strerror(code))))


function release_socket_addresses(values: ref[vec.Vec[net.SocketAddress]]) -> void:
    var index: ptr_uint = 0
    while index < values.len:
        let current = values.get(index) else:
            fatal(c"tls release_socket_addresses missing value")

        var address = unsafe: read(current)
        address.release()
        index += 1

    values.release()


function poll_state(frame: ptr[void]) -> ptr[PollState]:
    return unsafe: ptr[PollState]<-frame


function poll_as_handle(handle: ptr[NativePollHandle]) -> ptr[NativeHandle]:
    return unsafe: ptr[NativeHandle]<-handle


function handle_as_poll(handle: ptr[NativeHandle]) -> ptr[NativePollHandle]:
    return unsafe: ptr[NativePollHandle]<-handle


function noop_waiter(frame: ptr[void]) -> void:
    unsafe: ptr[void]<-frame


function poll_task(state: ptr[PollState]) -> Task[Result[int, Error]]:
    return unsafe: Task[Result[int, Error]](
            frame = ptr[void]<-state,
            ready = poll_ready,
            set_waiter = poll_set_waiter,
            release = poll_release,
            take_result = poll_take_result,
        )


function release_poll_error(state: ptr[PollState]) -> void:
    unsafe:
        if state.error_owned:
            state.error.release()
            state.error = empty_error()
            state.error_owned = false


function poll_close_callback(handle: ptr[NativeHandle]) -> void:
    let state_raw = libuv.handle_get_data(handle) else:
        unsafe: heap.release_bytes(ptr[void]<-handle_as_poll(handle))
        return

    let state = unsafe: ptr[PollState]<-state_raw
    unsafe:
        heap.release_bytes(ptr[void]<-handle_as_poll(handle))
        state.handle = null
        state.closed = true

        if state.released:
            release_poll_error(state)
            heap.release(state)


function close_poll_handle(state: ptr[PollState]) -> void:
    unsafe:
        let poll = state.handle else:
            state.closed = true
            return

        if state.closing or state.closed:
            return

        state.closing = true
        libuv.poll_stop(poll)
        libuv.close(poll_as_handle(poll), poll_close_callback)


function finish_poll_success(state: ptr[PollState], revents: int) -> void:
    unsafe:
        release_poll_error(state)
        state.ready = true
        state.status_code = 0
        state.revents = revents
        close_poll_handle(state)

        if state.waiter_registered:
            state.waiter(ptr[void]<-state.waiter_frame)


function finish_poll_failure(state: ptr[PollState], error: Error, status_code: int) -> void:
    unsafe:
        release_poll_error(state)
        state.ready = true
        state.status_code = status_code
        state.revents = 0
        state.error = error
        state.error_owned = true
        close_poll_handle(state)

        if state.waiter_registered:
            state.waiter(ptr[void]<-state.waiter_frame)


function poll_ready(frame: ptr[void]) -> bool:
    return unsafe: poll_state(frame).ready


function poll_set_waiter(frame: ptr[void], waiter_frame: ptr[void], waiter: fn(frame: ptr[void]) -> void) -> void:
    let state = poll_state(frame)
    unsafe:
        if state.ready:
            waiter(waiter_frame)
            return

        state.waiter_frame = waiter_frame
        state.waiter = waiter
        state.waiter_registered = true


function poll_release(frame: ptr[void]) -> void:
    let state = poll_state(frame)

    unsafe:
        if state.closed:
            release_poll_error(state)
            heap.release(state)
            return

        state.released = true
        if state.handle == null:
            release_poll_error(state)
            heap.release(state)
            return

    close_poll_handle(state)


function poll_take_result(frame: ptr[void]) -> Result[int, Error]:
    let state = poll_state(frame)
    unsafe:
        if state.status_code == 0:
            return Result[int, Error].success(value = state.revents)

        var error = state.error
        state.error = empty_error()
        state.error_owned = false
        return Result[int, Error].failure(error = error)


function poll_callback(handle: ptr[NativePollHandle], status_code: int, events: int) -> void:
    let state_raw = libuv.handle_get_data(poll_as_handle(handle)) else:
        return

    let state = unsafe: ptr[PollState]<-state_raw
    if status_code != 0:
        finish_poll_failure(state, libuv_error(status_code), status_code)
        return

    finish_poll_success(state, events)


function alloc_poll_handle() -> ptr[NativePollHandle]:
    let handle_size = libuv.handle_size(libuv.uv_handle_type.UV_POLL)
    return unsafe: ptr[NativePollHandle]<-heap.must_alloc_zeroed_bytes(1, handle_size)


function poll_events_for_status(status_code: int) -> int:
    if status_code == tls_io_want_read:
        return libuv.uv_poll_event.UV_READABLE | libuv.uv_poll_event.UV_DISCONNECT

    if status_code == tls_io_want_write:
        return libuv.uv_poll_event.UV_WRITABLE

    fatal(c"tls.poll_events_for_status requires WANT_READ or WANT_WRITE")


function poll_on(runtime: aio.Runtime, fd: int, events: int) -> Task[Result[int, Error]]:
    let loop = aio_backend.runtime_loop(runtime)
    let state = heap.must_alloc_zeroed[PollState](1)
    let poll = alloc_poll_handle()

    unsafe:
        state.ready = false
        state.status_code = 0
        state.revents = 0
        state.error = empty_error()
        state.error_owned = false
        state.waiter_frame = null
        state.waiter = noop_waiter
        state.waiter_registered = false
        state.handle = poll
        state.closing = false
        state.closed = false
        state.released = false

    let init_status = libuv.poll_init(loop, poll, fd)
    if init_status != 0:
        unsafe:
            heap.release_bytes(ptr[void]<-poll)
            state.handle = null
            state.closed = true
        finish_poll_failure(state, libuv_error(init_status), init_status)
        return poll_task(state)

    unsafe:
        libuv.handle_set_data(poll_as_handle(poll), ptr[void]<-state)

    let start_status = libuv.poll_start(poll, events, poll_callback)
    if start_status != 0:
        finish_poll_failure(state, libuv_error(start_status), start_status)

    return poll_task(state)


async function wait_for_io(runtime: aio.Runtime, fd: int, status_code: int) -> Result[bool, Error]:
    let poll_result = await poll_on(runtime, fd, poll_events_for_status(status_code))
    match poll_result:
        Result.failure as payload:
            return Result[bool, Error].failure(error = payload.error)
        Result.success as payload:
            unsafe: payload.value
            return Result[bool, Error].success(value = true)


function begin_stream_operation(state_raw: ptr[StreamState]?) -> Result[ptr[StreamState], Error]:
    let state = state_raw else:
        return Result[ptr[StreamState], Error].failure(error = tls_error("tls stream is released"))

    unsafe:
        if state.client == null:
            return Result[ptr[StreamState], Error].failure(error = tls_error("tls stream is released"))

        if state.pending_operation:
            return Result[ptr[StreamState], Error].failure(error = tls_error("tls stream already has a pending operation"))

        state.pending_operation = true

    return Result[ptr[StreamState], Error].success(value = state)


function end_stream_operation(state: ptr[StreamState]) -> void:
    unsafe: state.pending_operation = false


async function handshake_on(runtime: aio.Runtime, state_raw: ptr[StreamState]?) -> Result[bool, Error]:
    let begin_result = begin_stream_operation(state_raw)
    match begin_result:
        Result.failure as payload:
            return Result[bool, Error].failure(error = payload.error)
        Result.success as payload:
            let state = payload.value
            defer end_stream_operation(state)

            while true:
                let client = unsafe: read(state).client else:
                    return Result[bool, Error].failure(error = tls_error("tls stream is released"))

                var raw_error = zero[c.mt_tls_error]
                let status_code = c.mt_tls_client_handshake(client, raw_error)
                if status_code == tls_io_ready:
                    return Result[bool, Error].success(value = true)

                if status_code == tls_io_want_read or status_code == tls_io_want_write:
                    let wait_result = await wait_for_io(runtime, unsafe: read(state).fd, status_code)
                    match wait_result:
                        Result.failure as wait_error_payload:
                            return Result[bool, Error].failure(error = wait_error_payload.error)
                        Result.success as wait_payload:
                            unsafe: wait_payload.value
                            continue

                if status_code == tls_io_eof:
                    return Result[bool, Error].failure(error = tls_error("tls stream closed during handshake"))

                return Result[bool, Error].failure(error = take_error(raw_error, "tls connect failed"))


async function write_on(runtime: aio.Runtime, state_raw: ptr[StreamState]?, content: span[ubyte]) -> Result[ptr_uint, Error]:
    if content.len == 0:
        return Result[ptr_uint, Error].success(value = 0)

    let begin_result = begin_stream_operation(state_raw)
    match begin_result:
        Result.failure as payload:
            return Result[ptr_uint, Error].failure(error = payload.error)
        Result.success as payload:
            let state = payload.value
            defer end_stream_operation(state)

            var offset: ptr_uint = 0
            while offset < content.len:
                let client = unsafe: read(state).client else:
                    return Result[ptr_uint, Error].failure(error = tls_error("tls stream is released"))

                var transferred: ptr_uint = 0
                var raw_error = zero[c.mt_tls_error]
                let status_code = c.mt_tls_client_write(client, unsafe: content.data + offset, content.len - offset, transferred, raw_error)
                if status_code == tls_io_ready:
                    if transferred == 0:
                        return Result[ptr_uint, Error].failure(error = tls_error("tls write made no progress"))

                    offset += transferred
                    continue

                if status_code == tls_io_want_read or status_code == tls_io_want_write:
                    let wait_result = await wait_for_io(runtime, unsafe: read(state).fd, status_code)
                    match wait_result:
                        Result.failure as wait_error_payload:
                            return Result[ptr_uint, Error].failure(error = wait_error_payload.error)
                        Result.success as wait_payload:
                            unsafe: wait_payload.value
                            continue

                if status_code == tls_io_eof:
                    return Result[ptr_uint, Error].failure(error = tls_error("tls stream closed during write"))

                return Result[ptr_uint, Error].failure(error = take_error(raw_error, "tls write failed"))

            return Result[ptr_uint, Error].success(value = offset)


async function read_once_on(runtime: aio.Runtime, state_raw: ptr[StreamState]?, max_bytes: ptr_uint) -> Result[bytes.Bytes, Error]:
    if max_bytes == 0:
        return Result[bytes.Bytes, Error].failure(error = tls_error("tls read requires max_bytes > 0"))

    let begin_result = begin_stream_operation(state_raw)
    match begin_result:
        Result.failure as payload:
            return Result[bytes.Bytes, Error].failure(error = payload.error)
        Result.success as payload:
            let state = payload.value
            defer end_stream_operation(state)

            let buffer = heap.must_alloc[ubyte](max_bytes)
            while true:
                let client = unsafe: read(state).client else:
                    unsafe: heap.release(buffer)
                    return Result[bytes.Bytes, Error].failure(error = tls_error("tls stream is released"))

                var transferred: ptr_uint = 0
                var raw_error = zero[c.mt_tls_error]
                let status_code = c.mt_tls_client_read(client, buffer, max_bytes, transferred, raw_error)
                if status_code == tls_io_ready:
                    if transferred == 0:
                        unsafe: heap.release(buffer)
                        return Result[bytes.Bytes, Error].success(value = bytes.Bytes.empty())

                    return Result[bytes.Bytes, Error].success(value = bytes.Bytes(data = buffer, len = transferred))

                if status_code == tls_io_eof:
                    unsafe: heap.release(buffer)
                    return Result[bytes.Bytes, Error].success(value = bytes.Bytes.empty())

                if status_code == tls_io_want_read or status_code == tls_io_want_write:
                    let wait_result = await wait_for_io(runtime, unsafe: read(state).fd, status_code)
                    match wait_result:
                        Result.failure as wait_error_payload:
                            unsafe: heap.release(buffer)
                            return Result[bytes.Bytes, Error].failure(error = wait_error_payload.error)
                        Result.success as wait_payload:
                            unsafe: wait_payload.value
                            continue

                unsafe: heap.release(buffer)
                return Result[bytes.Bytes, Error].failure(error = take_error(raw_error, "tls read failed"))


async function shutdown_on(runtime: aio.Runtime, state_raw: ptr[StreamState]?) -> Result[bool, Error]:
    let begin_result = begin_stream_operation(state_raw)
    match begin_result:
        Result.failure as payload:
            return Result[bool, Error].failure(error = payload.error)
        Result.success as payload:
            let state = payload.value
            defer end_stream_operation(state)

            while true:
                let client = unsafe: read(state).client else:
                    return Result[bool, Error].failure(error = tls_error("tls stream is released"))

                var raw_error = zero[c.mt_tls_error]
                let status_code = c.mt_tls_client_shutdown(client, raw_error)
                if status_code == tls_io_ready:
                    return Result[bool, Error].success(value = true)

                if status_code == tls_io_want_read or status_code == tls_io_want_write:
                    let wait_result = await wait_for_io(runtime, unsafe: read(state).fd, status_code)
                    match wait_result:
                        Result.failure as wait_error_payload:
                            return Result[bool, Error].failure(error = wait_error_payload.error)
                        Result.success as wait_payload:
                            unsafe: wait_payload.value
                            continue

                return Result[bool, Error].failure(error = take_error(raw_error, "tls shutdown failed"))


public async function connect_on(runtime: aio.Runtime, host: str, port: int) -> Result[Stream, Error]:
    var service = fmt.to_string_int(port)
    defer service.release()

    let addresses_result = await net.resolve_all_on(runtime, host, service.as_str())
    match addresses_result:
        Result.failure as payload:
            return Result[Stream, Error].failure(error = take_net_error(payload.error))
        Result.success as payload:
            var addresses = payload.value
            defer release_socket_addresses(ref_of(addresses))

            var last_error = tls_error("tls connect failed")
            var last_error_owned = true
            defer:
                if last_error_owned:
                    last_error.release()

            var index: ptr_uint = 0
            while index < addresses.len:
                let current = addresses.get(index) else:
                    fatal(c"tls.connect_on missing resolved address")

                let connect_result = await net.connect_on(runtime, unsafe: read(current))
                match connect_result:
                    Result.failure as connect_error_payload:
                        if last_error_owned:
                            last_error.release()
                        last_error = take_net_error(connect_error_payload.error)
                        last_error_owned = true
                    Result.success as connect_payload:
                        if last_error_owned:
                            last_error.release()
                            last_error_owned = false
                        return await client_on(runtime, host, connect_payload.value)

                index += 1

            last_error_owned = false
            return Result[Stream, Error].failure(error = last_error)


public function connect(host: str, port: int) -> Task[Result[Stream, Error]]:
    return connect_on(aio.current_runtime(), host, port)


public async function client_on(runtime: aio.Runtime, host: str, transport: net.TcpStream) -> Result[Stream, Error]:
    var owned_transport = transport

    let fd_result = owned_transport.socket_fd()
    match fd_result:
        Result.failure as payload:
            owned_transport.release()
            return Result[Stream, Error].failure(error = take_net_error(payload.error))
        Result.success as payload:
            var raw_client: ptr[c.mt_tls_client]? = null
            var host_storage = arena.create(host.len + 1)
            defer host_storage.release()

            var raw_error = zero[c.mt_tls_error]
            let create_status = c.mt_tls_client_create(host_storage.to_cstr(host), payload.value, raw_client, raw_error)
            if create_status != 0:
                owned_transport.release()
                return Result[Stream, Error].failure(error = take_error(raw_error, "tls connect failed"))

            let live_client = raw_client else:
                owned_transport.release()
                return Result[Stream, Error].failure(error = tls_error("tls connect failed"))

            let state = heap.must_alloc_zeroed[StreamState](1)
            unsafe:
                state.client = live_client
                state.tcp = owned_transport
                state.fd = payload.value
                state.pending_operation = false

            var stream = Stream(state = state)
            let handshake_result = await handshake_on(runtime, state)
            match handshake_result:
                Result.failure as handshake_payload:
                    stream.release()
                    return Result[Stream, Error].failure(error = handshake_payload.error)
                Result.success as handshake_payload:
                    unsafe: handshake_payload.value
                    return Result[Stream, Error].success(value = stream)


public function client(host: str, transport: net.TcpStream) -> Task[Result[Stream, Error]]:
    return client_on(aio.current_runtime(), host, transport)


extending Error:
    public mutable function release() -> void:
        this.message.release()
        return


extending Stream:
    public mutable function release() -> void:
        let state = this.state else:
            return

        unsafe:
            if state.pending_operation:
                fatal(c"tls stream released with a pending operation")

            let client = state.client
            if client != null[ptr[c.mt_tls_client]]:
                c.mt_tls_client_release(client)
                state.client = null

            var transport = state.tcp
            transport.release()
            state.tcp = zero[net.TcpStream]

        heap.release(state)
        this.state = null


    public function write_bytes(content: span[ubyte]) -> Task[Result[ptr_uint, Error]]:
        return write_on(aio.current_runtime(), this.state, content)


    public function read_once(max_bytes: ptr_uint) -> Task[Result[bytes.Bytes, Error]]:
        return read_once_on(aio.current_runtime(), this.state, max_bytes)


    public function shutdown() -> Task[Result[bool, Error]]:
        return shutdown_on(aio.current_runtime(), this.state)


public function exchange(host: str, port: int, request: span[ubyte]) -> Result[bytes.Bytes, Error]:
    var host_storage = arena.create(host.len + 1)
    defer host_storage.release()

    var raw_response = zero[c.mt_tls_bytes]
    var raw_error = zero[c.mt_tls_error]
    let status_code = c.mt_tls_exchange(host_storage.to_cstr(host), port, request.data, request.len, raw_response, raw_error)
    if status_code != 0:
        return Result[bytes.Bytes, Error].failure(error = take_error(raw_error, "tls exchange failed"))

    return Result[bytes.Bytes, Error].success(value = take_owned_bytes(raw_response.data, raw_response.len))

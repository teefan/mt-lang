import std.async as aio
import std.async.libuv_runtime as aio_backend
import std.c.libuv as libuv_c
import std.libuv as libuv
import std.mem.arena as arena
import std.mem.heap as heap
import std.status as status
import std.str as text
import std.string as string


const address_name_capacity: ptr_uint = 128


public type NativeSocketStorage = libuv.sockaddr_storage
public type NativeTcpHandle = libuv.uv_tcp_t
public type NativeUdpHandle = libuv.uv_udp_t

type NativeHandle = libuv.uv_handle_t
type NativeStreamHandle = libuv.uv_stream_t
type NativeConnectRequest = libuv.uv_connect_t


public struct TcpStream:
    handle: ptr[NativeTcpHandle]?


public struct TcpListener:
    handle: ptr[NativeTcpHandle]?


public struct Error:
    code: int
    message: string.String


public enum AddressKind: int
    ipv4 = 4
    ipv6 = 6


public struct SocketAddress:
    storage: ptr[NativeSocketStorage]?
    len: ptr_uint
    kind: AddressKind


struct ResolveState:
    ready: bool
    status_code: int
    result: status.Status[SocketAddress, Error]
    result_owned: bool
    waiter_frame: ptr[void]?
    waiter: fn(frame: ptr[void]) -> void
    waiter_registered: bool
    req: ptr[libuv.uv_getaddrinfo_t]?
    storage: arena.Arena
    node: cstr?
    service: cstr?
    released: bool


struct ConnectState:
    ready: bool
    status_code: int
    result: status.Status[TcpStream, Error]
    result_owned: bool
    waiter_frame: ptr[void]?
    waiter: fn(frame: ptr[void]) -> void
    waiter_registered: bool
    req: ptr[NativeConnectRequest]?
    handle: ptr[NativeTcpHandle]?
    released: bool


struct ListenerState:
    handle: ptr[NativeTcpHandle]?
    pending_connections: int
    pending_error_code: int
    accept_state: ptr[AcceptState]?


struct AcceptState:
    ready: bool
    status_code: int
    result: status.Status[TcpStream, Error]
    result_owned: bool
    waiter_frame: ptr[void]?
    waiter: fn(frame: ptr[void]) -> void
    waiter_registered: bool
    listener: ptr[ListenerState]?


function noop_waiter(frame: ptr[void]) -> void:
    unsafe: ptr[void]<-frame
    return


function resolve_state(frame: ptr[void]) -> ptr[ResolveState]:
    return unsafe: ptr[ResolveState]<-frame


function req_as_base(req: ptr[libuv.uv_getaddrinfo_t]) -> ptr[libuv.uv_req_t]:
    return unsafe: ptr[libuv.uv_req_t]<-req


function connect_state(frame: ptr[void]) -> ptr[ConnectState]:
    return unsafe: ptr[ConnectState]<-frame


function connect_req_as_base(req: ptr[NativeConnectRequest]) -> ptr[libuv.uv_req_t]:
    return unsafe: ptr[libuv.uv_req_t]<-req


function accept_state(frame: ptr[void]) -> ptr[AcceptState]:
    return unsafe: ptr[AcceptState]<-frame


function sockaddr_storage_as_sockaddr(storage: ptr[NativeSocketStorage]) -> ptr[libuv.sockaddr]:
    return unsafe: ptr[libuv.sockaddr]<-storage


function sockaddr_as_sockaddr_in(address: ptr[libuv.sockaddr]) -> ptr[libuv.sockaddr_in]:
    return unsafe: ptr[libuv.sockaddr_in]<-address


function sockaddr_as_sockaddr_in6(address: ptr[libuv.sockaddr]) -> ptr[libuv.sockaddr_in6]:
    return unsafe: ptr[libuv.sockaddr_in6]<-address


function tcp_as_handle(handle: ptr[NativeTcpHandle]) -> ptr[NativeHandle]:
    return unsafe: ptr[NativeHandle]<-handle


function handle_as_tcp(handle: ptr[NativeHandle]) -> ptr[NativeTcpHandle]:
    return unsafe: ptr[NativeTcpHandle]<-handle


function tcp_as_stream(handle: ptr[NativeTcpHandle]) -> ptr[NativeStreamHandle]:
    return unsafe: ptr[NativeStreamHandle]<-handle


function stream_as_handle(stream: ptr[NativeStreamHandle]) -> ptr[NativeHandle]:
    return unsafe: ptr[NativeHandle]<-stream


function alloc_tcp_handle() -> ptr[NativeTcpHandle]:
    let handle_size = libuv.handle_size(libuv.uv_handle_type.UV_TCP)
    return unsafe: ptr[NativeTcpHandle]<-heap.must_alloc_zeroed_bytes(1, handle_size)


function alloc_connect_request() -> ptr[NativeConnectRequest]:
    let req_size = libuv.req_size(libuv.uv_req_type.UV_CONNECT)
    return unsafe: ptr[NativeConnectRequest]<-heap.must_alloc_zeroed_bytes(1, req_size)


function tcp_close_callback(handle: ptr[NativeHandle]) -> void:
    unsafe: heap.release_bytes(ptr[void]<-handle_as_tcp(handle))
    return


function close_tcp_handle(handle: ptr[NativeTcpHandle]) -> void:
    if libuv.is_closing(tcp_as_handle(handle)) != 0:
        return

    libuv.close(tcp_as_handle(handle), tcp_close_callback)
    return


function take_owned_message(message: str) -> string.String:
    return string.String.from_str(message)


function libuv_error(code: int) -> Error:
    return Error(code = code, message = take_owned_message(text.cstr_as_str(libuv.strerror(code))))


function net_error(message: str) -> Error:
    return Error(code = -1, message = take_owned_message(message))


function invalid_address_error(message: str) -> Error:
    return net_error(message)


function socket_address_from_sockaddr(address: ptr[libuv.sockaddr]?, length: ptr_uint) -> status.Status[SocketAddress, Error]:
    let live_address = address else:
        return status.Status[SocketAddress, Error].err(error= invalid_address_error("resolver returned null address"))

    let ipv4_size = ptr_uint<-size_of(libuv.sockaddr_in)
    let ipv6_size = ptr_uint<-size_of(libuv.sockaddr_in6)
    let storage = heap.must_alloc_zeroed[NativeSocketStorage](1)

    var result = SocketAddress(storage = storage, len = 0, kind = AddressKind.ipv4)
    if length == ipv4_size:
        unsafe:
            let source = ptr[ubyte]<-sockaddr_as_sockaddr_in(live_address)
            let target = ptr[ubyte]<-storage
            heap.copy_bytes(target, source, ipv4_size)
        result.len = ipv4_size
        result.kind = AddressKind.ipv4
        return status.Status[SocketAddress, Error].ok(value= result)

    if length == ipv6_size:
        unsafe:
            let source = ptr[ubyte]<-sockaddr_as_sockaddr_in6(live_address)
            let target = ptr[ubyte]<-storage
            heap.copy_bytes(target, source, ipv6_size)
        result.len = ipv6_size
        result.kind = AddressKind.ipv6
        return status.Status[SocketAddress, Error].ok(value= result)

    heap.release(storage)
    return status.Status[SocketAddress, Error].err(error= invalid_address_error("unsupported socket address family"))


function socket_address_to_string_result(address: SocketAddress) -> status.Status[string.String, Error]:
    let storage_ptr = address.storage else:
        return status.Status[string.String, Error].err(error= invalid_address_error("socket address is released"))

    var buffer: array[char, address_name_capacity] = zero[array[char, address_name_capacity]]
    var status_code: int = 0
    if address.kind == AddressKind.ipv4:
        var value = unsafe: read(ptr[libuv.sockaddr_in]<-storage_ptr)
        status_code = libuv.ip4_name(ptr_of(value), ptr_of(buffer[0]), address_name_capacity)
    else:
        var value = unsafe: read(ptr[libuv.sockaddr_in6]<-storage_ptr)
        status_code = libuv.ip6_name(ptr_of(value), ptr_of(buffer[0]), address_name_capacity)

    if status_code != 0:
        return status.Status[string.String, Error].err(error= libuv_error(status_code))

    return status.Status[string.String, Error].ok(value= string.String.from_str(text.chars_as_str(ptr_of(buffer[0]))))


function tcp_socket_address_from_getsockname(handle: ptr[NativeTcpHandle]?) -> status.Status[SocketAddress, Error]:
    let live_handle = handle else:
        return status.Status[SocketAddress, Error].err(error= net_error("tcp handle is released"))

    var raw = zero[NativeSocketStorage]
    var name_length = int<-size_of(NativeSocketStorage)
    let status_code = libuv_c.uv_tcp_getsockname(
            live_handle,
            sockaddr_storage_as_sockaddr(unsafe: ptr[NativeSocketStorage]<-ptr_of(raw)),
            ptr_of(name_length),
        )
    if status_code != 0:
        return status.Status[SocketAddress, Error].err(error= libuv_error(status_code))

    return socket_address_from_sockaddr(sockaddr_storage_as_sockaddr(unsafe: ptr[NativeSocketStorage]<-ptr_of(raw)), ptr_uint<-name_length)


function tcp_socket_address_from_getpeername(handle: ptr[NativeTcpHandle]?) -> status.Status[SocketAddress, Error]:
    let live_handle = handle else:
        return status.Status[SocketAddress, Error].err(error= net_error("tcp handle is released"))

    var raw = zero[NativeSocketStorage]
    var name_length = int<-size_of(NativeSocketStorage)
    let status_code = libuv_c.uv_tcp_getpeername(
            live_handle,
            sockaddr_storage_as_sockaddr(unsafe: ptr[NativeSocketStorage]<-ptr_of(raw)),
            ptr_of(name_length),
        )
    if status_code != 0:
        return status.Status[SocketAddress, Error].err(error= libuv_error(status_code))

    return socket_address_from_sockaddr(sockaddr_storage_as_sockaddr(unsafe: ptr[NativeSocketStorage]<-ptr_of(raw)), ptr_uint<-name_length)


function resolve_ready(frame: ptr[void]) -> bool:
    return unsafe: read(resolve_state(frame)).ready


function resolve_set_waiter(frame: ptr[void], waiter_frame: ptr[void], waiter: fn(frame: ptr[void]) -> void) -> void:
    let state = resolve_state(frame)
    unsafe:
        read(state).waiter_frame = waiter_frame
        read(state).waiter = waiter
        read(state).waiter_registered = true
    return


function resolve_release(frame: ptr[void]) -> void:
    let state = resolve_state(frame)

    unsafe:
        if read(state).released:
            return
        read(state).released = true

    unsafe:
        if read(state).result_owned:
            var result_value = read(state).result
            match result_value:
                status.Status.ok as payload:
                    var address = payload.value
                    address.release()
                status.Status.err as payload:
                    var error = payload.error
                    error.release()

        var storage = read(state).storage
        storage.release()

        heap.release(state)
    return


function resolve_take_result(frame: ptr[void]) -> status.Status[SocketAddress, Error]:
    let state = resolve_state(frame)
    let result_value = unsafe: read(state).result
    unsafe: read(state).result_owned = false
    return result_value


function resolve_task(state: ptr[ResolveState]) -> Task[status.Status[SocketAddress, Error]]:
    return unsafe: Task[status.Status[SocketAddress, Error]](
            frame = ptr[void]<-state,
            ready = resolve_ready,
            set_waiter = resolve_set_waiter,
            release = resolve_release,
            take_result = resolve_take_result,
        )


function connect_ready(frame: ptr[void]) -> bool:
    return unsafe: read(connect_state(frame)).ready


function connect_set_waiter(frame: ptr[void], waiter_frame: ptr[void], waiter: fn(frame: ptr[void]) -> void) -> void:
    let state = connect_state(frame)
    unsafe:
        if read(state).ready:
            waiter(waiter_frame)
            return

        read(state).waiter_frame = waiter_frame
        read(state).waiter = waiter
        read(state).waiter_registered = true
    return


function connect_cleanup_and_release(state: ptr[ConnectState]) -> void:
    unsafe:
        if read(state).req != null[ptr[NativeConnectRequest]]:
            heap.release_bytes(ptr[void]<-read(state).req)
            read(state).req = null

        if read(state).result_owned:
            var result_value = read(state).result
            match result_value:
                status.Status.ok as payload:
                    var stream = payload.value
                    stream.release()
                status.Status.err as payload:
                    var error = payload.error
                    error.release()
            read(state).result_owned = false

        if read(state).handle != null[ptr[NativeTcpHandle]]:
            close_tcp_handle(unsafe: ptr[NativeTcpHandle]<-read(state).handle)
            read(state).handle = null

        heap.release(state)
    return


function connect_release(frame: ptr[void]) -> void:
    let state = connect_state(frame)
    if unsafe: read(state).ready:
        connect_cleanup_and_release(state)
        return

    unsafe: read(state).released = true
    return


function connect_take_result(frame: ptr[void]) -> status.Status[TcpStream, Error]:
    let state = connect_state(frame)
    let result_value = unsafe: read(state).result
    unsafe: read(state).result_owned = false
    return result_value


function connect_task(state: ptr[ConnectState]) -> Task[status.Status[TcpStream, Error]]:
    return unsafe: Task[status.Status[TcpStream, Error]](
            frame = ptr[void]<-state,
            ready = connect_ready,
            set_waiter = connect_set_waiter,
            release = connect_release,
            take_result = connect_take_result,
        )


function finish_connect(state: ptr[ConnectState], result_value: status.Status[TcpStream, Error], status_code: int) -> void:
    var waiter: fn(frame: ptr[void]) -> void = noop_waiter
    var waiter_frame: ptr[void]? = null
    var notify = false
    var released = false

    unsafe:
        read(state).result = result_value
        read(state).result_owned = true
        read(state).status_code = status_code
        read(state).ready = true
        released = read(state).released
        if read(state).waiter_registered:
            waiter = read(state).waiter
            waiter_frame = read(state).waiter_frame
            read(state).waiter_registered = false
            notify = true

    if notify and waiter_frame != null[ptr[void]]:
        waiter(unsafe: ptr[void]<-waiter_frame)

    if released:
        connect_cleanup_and_release(state)
    return


function connect_callback(req: ptr[NativeConnectRequest], status_code: int) -> void:
    let state_raw = libuv.req_get_data(connect_req_as_base(req)) else:
        unsafe: heap.release_bytes(ptr[void]<-req)
        return

    let state = unsafe: ptr[ConnectState]<-state_raw
    unsafe:
        heap.release_bytes(ptr[void]<-req)
        read(state).req = null

    if status_code != 0:
        let handle = unsafe: read(state).handle
        if handle != null[ptr[NativeTcpHandle]]:
            close_tcp_handle(unsafe: ptr[NativeTcpHandle]<-handle)
            unsafe: read(state).handle = null

        finish_connect(state, status.Status[TcpStream, Error].err(error= libuv_error(status_code)), status_code)
        return

    let handle = unsafe: read(state).handle else:
        finish_connect(state, status.Status[TcpStream, Error].err(error= net_error("tcp connect completed without a handle")), -1)
        return

    unsafe: read(state).handle = null
    finish_connect(state, status.Status[TcpStream, Error].ok(value= TcpStream(handle = handle)), 0)


function accept_ready(frame: ptr[void]) -> bool:
    return unsafe: read(accept_state(frame)).ready


function accept_set_waiter(frame: ptr[void], waiter_frame: ptr[void], waiter: fn(frame: ptr[void]) -> void) -> void:
    let state = accept_state(frame)
    unsafe:
        if read(state).ready:
            waiter(waiter_frame)
            return

        read(state).waiter_frame = waiter_frame
        read(state).waiter = waiter
        read(state).waiter_registered = true
    return


function accept_cleanup_and_release(state: ptr[AcceptState]) -> void:
    unsafe:
        if read(state).result_owned:
            var result_value = read(state).result
            match result_value:
                status.Status.ok as payload:
                    var stream = payload.value
                    stream.release()
                status.Status.err as payload:
                    var error = payload.error
                    error.release()
            read(state).result_owned = false

        heap.release(state)
    return


function accept_release(frame: ptr[void]) -> void:
    let state = accept_state(frame)
    if unsafe: read(state).ready:
        accept_cleanup_and_release(state)
        return

    let listener = unsafe: read(state).listener
    if listener != null[ptr[ListenerState]]:
        let live_listener = unsafe: ptr[ListenerState]<-listener
        if unsafe: read(live_listener).accept_state == state:
            unsafe: read(live_listener).accept_state = null

    unsafe: read(state).listener = null
    heap.release(state)
    return


function accept_take_result(frame: ptr[void]) -> status.Status[TcpStream, Error]:
    let state = accept_state(frame)
    let result_value = unsafe: read(state).result
    unsafe: read(state).result_owned = false
    return result_value


function accept_task(state: ptr[AcceptState]) -> Task[status.Status[TcpStream, Error]]:
    return unsafe: Task[status.Status[TcpStream, Error]](
            frame = ptr[void]<-state,
            ready = accept_ready,
            set_waiter = accept_set_waiter,
            release = accept_release,
            take_result = accept_take_result,
        )


function finish_accept(state: ptr[AcceptState], result_value: status.Status[TcpStream, Error], status_code: int) -> void:
    var waiter: fn(frame: ptr[void]) -> void = noop_waiter
    var waiter_frame: ptr[void]? = null
    var notify = false

    unsafe:
        read(state).result = result_value
        read(state).result_owned = true
        read(state).status_code = status_code
        read(state).ready = true
        read(state).listener = null
        if read(state).waiter_registered:
            waiter = read(state).waiter
            waiter_frame = read(state).waiter_frame
            read(state).waiter_registered = false
            notify = true

    if notify and waiter_frame != null[ptr[void]]:
        waiter(unsafe: ptr[void]<-waiter_frame)
    return


function listener_close_callback(handle: ptr[NativeHandle]) -> void:
    let state_raw = libuv.handle_get_data(handle) else:
        unsafe: heap.release_bytes(ptr[void]<-handle_as_tcp(handle))
        return

    let listener = unsafe: ptr[ListenerState]<-state_raw
    let pending_accept = unsafe: read(listener).accept_state
    if pending_accept != null[ptr[AcceptState]]:
        unsafe: read(listener).accept_state = null
        finish_accept(unsafe: ptr[AcceptState]<-pending_accept, status.Status[TcpStream, Error].err(error= net_error("listener closed")), -1)

    unsafe:
        heap.release_bytes(ptr[void]<-handle_as_tcp(handle))
        read(listener).handle = null
        heap.release(listener)
    return


function perform_listener_accept(listener: ptr[ListenerState], state: ptr[AcceptState]) -> void:
    let server_handle = unsafe: read(listener).handle else:
        finish_accept(state, status.Status[TcpStream, Error].err(error= net_error("listener is released")), -1)
        return

    let client_handle = alloc_tcp_handle()
    let init_status = libuv.tcp_init(libuv.handle_get_loop(tcp_as_handle(server_handle)), client_handle)
    if init_status != 0:
        unsafe: heap.release_bytes(ptr[void]<-client_handle)
        finish_accept(state, status.Status[TcpStream, Error].err(error= libuv_error(init_status)), init_status)
        return

    let accept_status = libuv.accept(tcp_as_stream(server_handle), tcp_as_stream(client_handle))
    if accept_status != 0:
        close_tcp_handle(client_handle)
        finish_accept(state, status.Status[TcpStream, Error].err(error= libuv_error(accept_status)), accept_status)
        return

    finish_accept(state, status.Status[TcpStream, Error].ok(value= TcpStream(handle = client_handle)), 0)


function listener_connection_callback(server: ptr[NativeStreamHandle], status_code: int) -> void:
    let state_raw = libuv.handle_get_data(stream_as_handle(server)) else:
        return

    let listener = unsafe: ptr[ListenerState]<-state_raw
    let pending_accept = unsafe: read(listener).accept_state
    if status_code != 0:
        if pending_accept != null[ptr[AcceptState]]:
            unsafe: read(listener).accept_state = null
            finish_accept(unsafe: ptr[AcceptState]<-pending_accept, status.Status[TcpStream, Error].err(error= libuv_error(status_code)), status_code)
        else:
            unsafe: read(listener).pending_error_code = status_code
        return

    if pending_accept != null[ptr[AcceptState]]:
        unsafe: read(listener).accept_state = null
        perform_listener_accept(listener, unsafe: ptr[AcceptState]<-pending_accept)
        return

    unsafe: read(listener).pending_connections += 1


function accept_impl(handle: ptr[NativeTcpHandle]?) -> Task[status.Status[TcpStream, Error]]:
    let state = heap.must_alloc_zeroed[AcceptState](1)
    unsafe:
        read(state).ready = false
        read(state).status_code = 0
        read(state).result = status.Status[TcpStream, Error].ok(value= zero[TcpStream])
        read(state).result_owned = false
        read(state).waiter_frame = null
        read(state).waiter = noop_waiter
        read(state).waiter_registered = false
        read(state).listener = null

    let live_handle = handle else:
        finish_accept(state, status.Status[TcpStream, Error].err(error= net_error("listener is released")), -1)
        return accept_task(state)

    if libuv.is_closing(tcp_as_handle(live_handle)) != 0:
        finish_accept(state, status.Status[TcpStream, Error].err(error= net_error("listener is closing")), -1)
        return accept_task(state)

    let state_raw = libuv.handle_get_data(tcp_as_handle(live_handle)) else:
        finish_accept(state, status.Status[TcpStream, Error].err(error= net_error("listener state is unavailable")), -1)
        return accept_task(state)

    let listener = unsafe: ptr[ListenerState]<-state_raw
    unsafe: read(state).listener = listener

    let pending_error_code = unsafe: read(listener).pending_error_code
    if pending_error_code != 0:
        unsafe:
            read(listener).pending_error_code = 0
            read(state).listener = null
        finish_accept(state, status.Status[TcpStream, Error].err(error= libuv_error(pending_error_code)), pending_error_code)
        return accept_task(state)

    if unsafe: read(listener).accept_state != null[ptr[AcceptState]]:
        unsafe: read(state).listener = null
        finish_accept(state, status.Status[TcpStream, Error].err(error= net_error("listener already has a pending accept")), -1)
        return accept_task(state)

    if unsafe: read(listener).pending_connections > 0:
        unsafe: read(listener).pending_connections -= 1
        perform_listener_accept(listener, state)
        return accept_task(state)

    unsafe: read(listener).accept_state = state
    return accept_task(state)


function finish_resolve(state: ptr[ResolveState], result_value: status.Status[SocketAddress, Error], status_code: int) -> void:
    var waiter: fn(frame: ptr[void]) -> void = noop_waiter
    var waiter_frame: ptr[void]? = null
    var notify = false

    unsafe:
        read(state).result = result_value
        read(state).result_owned = true
        read(state).status_code = status_code
        read(state).ready = true
        if read(state).waiter_registered:
            waiter = read(state).waiter
            waiter_frame = read(state).waiter_frame
            read(state).waiter_registered = false
            notify = true

    if notify and waiter_frame != null[ptr[void]]:
        waiter(unsafe: ptr[void]<-waiter_frame)
    return


function resolve_callback(req: ptr[libuv.uv_getaddrinfo_t], status_code: int, result_ptr: ptr[libuv.addrinfo]) -> void:
    let maybe_result = unsafe: ptr[libuv.addrinfo]?<-result_ptr

    let state_raw = libuv.req_get_data(req_as_base(req)) else:
        if maybe_result != null[ptr[libuv.addrinfo]]:
            libuv.freeaddrinfo(result_ptr)
        return

    let state = unsafe: ptr[ResolveState]<-state_raw
    unsafe: read(state).req = null

    if status_code != 0:
        if maybe_result != null[ptr[libuv.addrinfo]]:
            libuv.freeaddrinfo(result_ptr)
        finish_resolve(state, status.Status[SocketAddress, Error].err(error= libuv_error(status_code)), status_code)
        return

    if maybe_result == null[ptr[libuv.addrinfo]]:
        finish_resolve(state, status.Status[SocketAddress, Error].err(error= invalid_address_error("resolver returned no addresses")), -1)
        return

    let ai = unsafe: read(result_ptr)
    let address_result = socket_address_from_sockaddr(ai.ai_addr, ptr_uint<-ai.ai_addrlen)
    libuv.freeaddrinfo(result_ptr)
    finish_resolve(state, address_result, 0)


function resolve_on_impl(runtime: aio.Runtime, node: str, service: str) -> Task[status.Status[SocketAddress, Error]]:
    let loop = aio_backend.runtime_loop(runtime)
    let state = heap.must_alloc_zeroed[ResolveState](1)

    let req_size = libuv.req_size(libuv.uv_req_type.UV_GETADDRINFO)
    let req = unsafe: ptr[libuv.uv_getaddrinfo_t]<-heap.must_alloc_zeroed_bytes(1, req_size)
    var storage = arena.create(node.len + service.len + 2)
    let node_cstr = storage.to_cstr(node)
    let service_cstr = storage.to_cstr(service)

    unsafe:
        read(state).ready = false
        read(state).status_code = 0
        read(state).result = status.Status[SocketAddress, Error].ok(value= zero[SocketAddress])
        read(state).result_owned = false
        read(state).waiter_frame = null
        read(state).waiter = noop_waiter
        read(state).waiter_registered = false
        read(state).req = req
        read(state).storage = storage
        read(state).node = node_cstr
        read(state).service = service_cstr
        read(state).released = false
        libuv.req_set_data(req_as_base(req), ptr[void]<-state)

    let queue_status = libuv.getaddrinfo(loop, req, resolve_callback, unsafe: read(state).node, unsafe: read(state).service, null[const_ptr[libuv.addrinfo]])
    if queue_status != 0:
        unsafe:
            heap.release(req)
            read(state).req = null
        finish_resolve(state, status.Status[SocketAddress, Error].err(error= libuv_error(queue_status)), queue_status)

    return resolve_task(state)


function connect_on_impl(runtime: aio.Runtime, address: SocketAddress) -> Task[status.Status[TcpStream, Error]]:
    let state = heap.must_alloc_zeroed[ConnectState](1)
    unsafe:
        read(state).ready = false
        read(state).status_code = 0
        read(state).result = status.Status[TcpStream, Error].ok(value= zero[TcpStream])
        read(state).result_owned = false
        read(state).waiter_frame = null
        read(state).waiter = noop_waiter
        read(state).waiter_registered = false
        read(state).req = null
        read(state).handle = null
        read(state).released = false

    let storage = address.storage else:
        finish_connect(state, status.Status[TcpStream, Error].err(error= invalid_address_error("socket address is released")), -1)
        return connect_task(state)

    let handle = alloc_tcp_handle()
    let init_status = libuv.tcp_init(aio_backend.runtime_loop(runtime), handle)
    if init_status != 0:
        unsafe: heap.release_bytes(ptr[void]<-handle)
        finish_connect(state, status.Status[TcpStream, Error].err(error= libuv_error(init_status)), init_status)
        return connect_task(state)

    let req = alloc_connect_request()
    unsafe:
        read(state).req = req
        read(state).handle = handle
        libuv.req_set_data(connect_req_as_base(req), ptr[void]<-state)

    let queue_status = libuv.tcp_connect(req, handle, sockaddr_storage_as_sockaddr(storage), connect_callback)
    if queue_status != 0:
        unsafe:
            heap.release_bytes(ptr[void]<-req)
            read(state).req = null
            read(state).handle = null
        close_tcp_handle(handle)
        finish_connect(state, status.Status[TcpStream, Error].err(error= libuv_error(queue_status)), queue_status)

    return connect_task(state)


function listen_on_impl(runtime: aio.Runtime, address: SocketAddress, backlog: int) -> status.Status[TcpListener, Error]:
    let storage = address.storage else:
        return status.Status[TcpListener, Error].err(error= invalid_address_error("socket address is released"))

    let handle = alloc_tcp_handle()
    let init_status = libuv.tcp_init(aio_backend.runtime_loop(runtime), handle)
    if init_status != 0:
        unsafe: heap.release_bytes(ptr[void]<-handle)
        return status.Status[TcpListener, Error].err(error= libuv_error(init_status))

    let bind_status = libuv.tcp_bind(handle, sockaddr_storage_as_sockaddr(storage), 0)
    if bind_status != 0:
        close_tcp_handle(handle)
        return status.Status[TcpListener, Error].err(error= libuv_error(bind_status))

    let listen_status = libuv.listen(tcp_as_stream(handle), backlog, listener_connection_callback)
    if listen_status != 0:
        close_tcp_handle(handle)
        return status.Status[TcpListener, Error].err(error= libuv_error(listen_status))

    let listener_state = heap.must_alloc_zeroed[ListenerState](1)
    unsafe:
        read(listener_state).handle = handle
        read(listener_state).pending_connections = 0
        read(listener_state).pending_error_code = 0
        read(listener_state).accept_state = null
        libuv.handle_set_data(tcp_as_handle(handle), ptr[void]<-listener_state)

    return status.Status[TcpListener, Error].ok(value= TcpListener(handle = handle))


methods Error:
    public editable function release() -> void:
        this.message.release()
        return


methods SocketAddress:
    public editable function release() -> void:
        heap.release(this.storage)
        this.storage = null
        this.len = 0
        return


    public function host() -> status.Status[string.String, Error]:
        return socket_address_to_string_result(this)


methods TcpStream:
    public editable function release() -> void:
        let handle = this.handle else:
            return

        this.handle = null
        close_tcp_handle(handle)
        return


    public function local_address() -> status.Status[SocketAddress, Error]:
        return tcp_socket_address_from_getsockname(this.handle)


    public function peer_address() -> status.Status[SocketAddress, Error]:
        return tcp_socket_address_from_getpeername(this.handle)


methods TcpListener:
    public editable function release() -> void:
        let handle = this.handle else:
            return

        let state_raw = libuv.handle_get_data(tcp_as_handle(handle))
        if state_raw != null[ptr[void]]:
            let listener = unsafe: ptr[ListenerState]<-state_raw
            let pending_accept = unsafe: read(listener).accept_state
            if pending_accept != null[ptr[AcceptState]]:
                unsafe: read(listener).accept_state = null
                finish_accept(unsafe: ptr[AcceptState]<-pending_accept, status.Status[TcpStream, Error].err(error= net_error("listener released")), -1)

        this.handle = null
        if libuv.is_closing(tcp_as_handle(handle)) == 0:
            libuv.close(tcp_as_handle(handle), listener_close_callback)
        return


    public function accept() -> Task[status.Status[TcpStream, Error]]:
        return accept_impl(this.handle)


    public function local_address() -> status.Status[SocketAddress, Error]:
        return tcp_socket_address_from_getsockname(this.handle)


public function ipv4(ip: str, port: int) -> status.Status[SocketAddress, Error]:
    var raw = zero[libuv.sockaddr_in]
    let status_code = libuv.ip4_addr(ip, port, raw)
    if status_code != 0:
        return status.Status[SocketAddress, Error].err(error= libuv_error(status_code))

    return socket_address_from_sockaddr(sockaddr_storage_as_sockaddr(unsafe: ptr[NativeSocketStorage]<-ptr_of(raw)), ptr_uint<-size_of(libuv.sockaddr_in))


public function ipv6(ip: str, port: int) -> status.Status[SocketAddress, Error]:
    var raw = zero[libuv.sockaddr_in6]
    let status_code = libuv.ip6_addr(ip, port, raw)
    if status_code != 0:
        return status.Status[SocketAddress, Error].err(error= libuv_error(status_code))

    return socket_address_from_sockaddr(sockaddr_storage_as_sockaddr(unsafe: ptr[NativeSocketStorage]<-ptr_of(raw)), ptr_uint<-size_of(libuv.sockaddr_in6))


public function resolve_first_on(runtime: aio.Runtime, node: str, service: str) -> Task[status.Status[SocketAddress, Error]]:
    return resolve_on_impl(runtime, node, service)


public function resolve_first(node: str, service: str) -> Task[status.Status[SocketAddress, Error]]:
    return resolve_first_on(aio.current_runtime(), node, service)


public function connect_on(runtime: aio.Runtime, address: SocketAddress) -> Task[status.Status[TcpStream, Error]]:
    return connect_on_impl(runtime, address)


public function connect(address: SocketAddress) -> Task[status.Status[TcpStream, Error]]:
    return connect_on(aio.current_runtime(), address)


public function listen_on(runtime: aio.Runtime, address: SocketAddress, backlog: int) -> status.Status[TcpListener, Error]:
    return listen_on_impl(runtime, address, backlog)


public function listen(address: SocketAddress, backlog: int) -> status.Status[TcpListener, Error]:
    return listen_on(aio.current_runtime(), address, backlog)

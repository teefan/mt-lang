import std.async as aio
import std.async.libuv_runtime as aio_backend
import std.bytes as bytes
import std.c.libuv as libuv_c
import std.cstring as cstring
import std.libuv as libuv
import std.mem.arena as arena
import std.mem.heap as heap
import std.str as text
import std.string as string
import std.vec as vec


const address_name_capacity: ptr_uint = 128


public type NativeSocketStorage = libuv.sockaddr_storage
public type NativeTcpHandle = libuv.uv_tcp_t
public type NativeUdpHandle = libuv.uv_udp_t

type NativeHandle = libuv.uv_handle_t
type NativeStreamHandle = libuv.uv_stream_t
type NativeConnectRequest = libuv.uv_connect_t
type NativeWriteRequest = libuv.uv_write_t
type NativeShutdownRequest = libuv.uv_shutdown_t
type NativeUdpSendRequest = libuv.uv_udp_send_t
type NativeBuffer = libuv.uv_buf_t


public struct TcpStream:
    handle: ptr[NativeTcpHandle]?


public struct TcpListener:
    handle: ptr[NativeTcpHandle]?


public struct UdpSocket:
    handle: ptr[NativeUdpHandle]?


public struct UdpDatagram:
    data: bytes.Bytes
    source: SocketAddress


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
    result: Result[SocketAddress, Error]
    result_owned: bool
    waiter_frame: ptr[void]?
    waiter: fn(frame: ptr[void]) -> void
    waiter_registered: bool
    req: ptr[libuv.uv_getaddrinfo_t]?
    storage: arena.Arena
    node: cstr?
    service: cstr?
    released: bool


struct ResolveAllState:
    ready: bool
    status_code: int
    result: Result[vec.Vec[SocketAddress], Error]
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
    result: Result[TcpStream, Error]
    result_owned: bool
    waiter_frame: ptr[void]?
    waiter: fn(frame: ptr[void]) -> void
    waiter_registered: bool
    req: ptr[NativeConnectRequest]?
    handle: ptr[NativeTcpHandle]?
    destination: SocketAddress
    destination_owned: bool
    released: bool


struct ListenerState:
    handle: ptr[NativeTcpHandle]?
    pending_connections: int
    pending_error_code: int
    accept_state: ptr[AcceptState]?


struct AcceptState:
    ready: bool
    status_code: int
    result: Result[TcpStream, Error]
    result_owned: bool
    waiter_frame: ptr[void]?
    waiter: fn(frame: ptr[void]) -> void
    waiter_registered: bool
    listener: ptr[ListenerState]?


struct TcpStreamState:
    handle: ptr[NativeTcpHandle]?
    read_state: ptr[ReadState]?


struct WriteState:
    ready: bool
    status_code: int
    result: Result[ptr_uint, Error]
    result_owned: bool
    waiter_frame: ptr[void]?
    waiter: fn(frame: ptr[void]) -> void
    waiter_registered: bool
    req: ptr[NativeWriteRequest]?
    buffers: ptr[NativeBuffer]?
    data: bytes.Bytes
    released: bool


struct ReadState:
    ready: bool
    status_code: int
    result: Result[bytes.Bytes, Error]
    result_owned: bool
    waiter_frame: ptr[void]?
    waiter: fn(frame: ptr[void]) -> void
    waiter_registered: bool
    stream: ptr[TcpStreamState]?
    max_bytes: ptr_uint
    buffer: ptr[ubyte]?
    received_bytes: ptr_uint
    exact: bool
    released: bool


struct ShutdownState:
    ready: bool
    status_code: int
    result: Result[bool, Error]
    result_owned: bool
    waiter_frame: ptr[void]?
    waiter: fn(frame: ptr[void]) -> void
    waiter_registered: bool
    req: ptr[NativeShutdownRequest]?
    released: bool


struct UdpSocketState:
    handle: ptr[NativeUdpHandle]?
    receive_state: ptr[UdpReceiveState]?


struct UdpSendState:
    ready: bool
    status_code: int
    result: Result[ptr_uint, Error]
    result_owned: bool
    waiter_frame: ptr[void]?
    waiter: fn(frame: ptr[void]) -> void
    waiter_registered: bool
    req: ptr[NativeUdpSendRequest]?
    buffers: ptr[NativeBuffer]?
    data: bytes.Bytes
    destination: SocketAddress
    destination_owned: bool
    released: bool


struct UdpReceiveState:
    ready: bool
    status_code: int
    result: Result[UdpDatagram, Error]
    result_owned: bool
    waiter_frame: ptr[void]?
    waiter: fn(frame: ptr[void]) -> void
    waiter_registered: bool
    socket: ptr[UdpSocketState]?
    max_bytes: ptr_uint
    released: bool


function noop_waiter(frame: ptr[void]) -> void:
    unsafe: ptr[void]<-frame


function resolve_state(frame: ptr[void]) -> ptr[ResolveState]:
    return unsafe: ptr[ResolveState]<-frame


function resolve_all_state(frame: ptr[void]) -> ptr[ResolveAllState]:
    return unsafe: ptr[ResolveAllState]<-frame


function req_as_base(req: ptr[libuv.uv_getaddrinfo_t]) -> ptr[libuv.uv_req_t]:
    return unsafe: ptr[libuv.uv_req_t]<-req


function connect_state(frame: ptr[void]) -> ptr[ConnectState]:
    return unsafe: ptr[ConnectState]<-frame


function connect_req_as_base(req: ptr[NativeConnectRequest]) -> ptr[libuv.uv_req_t]:
    return unsafe: ptr[libuv.uv_req_t]<-req


function accept_state(frame: ptr[void]) -> ptr[AcceptState]:
    return unsafe: ptr[AcceptState]<-frame


function write_state(frame: ptr[void]) -> ptr[WriteState]:
    return unsafe: ptr[WriteState]<-frame


function stream_read_state(frame: ptr[void]) -> ptr[ReadState]:
    return unsafe: ptr[ReadState]<-frame


function shutdown_state(frame: ptr[void]) -> ptr[ShutdownState]:
    return unsafe: ptr[ShutdownState]<-frame


function udp_send_state(frame: ptr[void]) -> ptr[UdpSendState]:
    return unsafe: ptr[UdpSendState]<-frame


function udp_receive_state(frame: ptr[void]) -> ptr[UdpReceiveState]:
    return unsafe: ptr[UdpReceiveState]<-frame


function write_req_as_base(req: ptr[NativeWriteRequest]) -> ptr[libuv.uv_req_t]:
    return unsafe: ptr[libuv.uv_req_t]<-req


function shutdown_req_as_base(req: ptr[NativeShutdownRequest]) -> ptr[libuv.uv_req_t]:
    return unsafe: ptr[libuv.uv_req_t]<-req


function udp_send_req_as_base(req: ptr[NativeUdpSendRequest]) -> ptr[libuv.uv_req_t]:
    return unsafe: ptr[libuv.uv_req_t]<-req


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


function udp_as_handle(handle: ptr[NativeUdpHandle]) -> ptr[NativeHandle]:
    return unsafe: ptr[NativeHandle]<-handle


function handle_as_udp(handle: ptr[NativeHandle]) -> ptr[NativeUdpHandle]:
    return unsafe: ptr[NativeUdpHandle]<-handle


function alloc_tcp_handle() -> ptr[NativeTcpHandle]:
    let handle_size = libuv.handle_size(libuv.uv_handle_type.UV_TCP)
    return unsafe: ptr[NativeTcpHandle]<-heap.must_alloc_zeroed_bytes(1, handle_size)


function alloc_connect_request() -> ptr[NativeConnectRequest]:
    let req_size = libuv.req_size(libuv.uv_req_type.UV_CONNECT)
    return unsafe: ptr[NativeConnectRequest]<-heap.must_alloc_zeroed_bytes(1, req_size)


function alloc_write_request() -> ptr[NativeWriteRequest]:
    let req_size = libuv.req_size(libuv.uv_req_type.UV_WRITE)
    return unsafe: ptr[NativeWriteRequest]<-heap.must_alloc_zeroed_bytes(1, req_size)


function alloc_shutdown_request() -> ptr[NativeShutdownRequest]:
    let req_size = libuv.req_size(libuv.uv_req_type.UV_SHUTDOWN)
    return unsafe: ptr[NativeShutdownRequest]<-heap.must_alloc_zeroed_bytes(1, req_size)


function alloc_udp_handle() -> ptr[NativeUdpHandle]:
    let handle_size = libuv.handle_size(libuv.uv_handle_type.UV_UDP)
    return unsafe: ptr[NativeUdpHandle]<-heap.must_alloc_zeroed_bytes(1, handle_size)


function alloc_udp_send_request() -> ptr[NativeUdpSendRequest]:
    let req_size = libuv.req_size(libuv.uv_req_type.UV_UDP_SEND)
    return unsafe: ptr[NativeUdpSendRequest]<-heap.must_alloc_zeroed_bytes(1, req_size)


function tcp_close_callback(handle: ptr[NativeHandle]) -> void:
    unsafe: heap.release_bytes(ptr[void]<-handle_as_tcp(handle))


function close_tcp_handle(handle: ptr[NativeTcpHandle]) -> void:
    if libuv.is_closing(tcp_as_handle(handle)) != 0:
        return

    libuv.close(tcp_as_handle(handle), tcp_close_callback)


function udp_close_callback(handle: ptr[NativeHandle]) -> void:
    unsafe: heap.release_bytes(ptr[void]<-handle_as_udp(handle))


function close_raw_udp_handle(handle: ptr[NativeUdpHandle]) -> void:
    if libuv.is_closing(udp_as_handle(handle)) != 0:
        return

    libuv.close(udp_as_handle(handle), udp_close_callback)


function release_uv_buffer(buffer: NativeBuffer) -> void:
    unsafe: heap.release_bytes(ptr[void]<-buffer.base)


function attach_tcp_stream(handle: ptr[NativeTcpHandle]) -> TcpStream:
    let state = heap.must_alloc_zeroed[TcpStreamState](1)
    unsafe:
        read(state).handle = handle
        read(state).read_state = null
        libuv.handle_set_data(tcp_as_handle(handle), ptr[void]<-state)
    return TcpStream(handle = handle)


function attach_udp_socket(handle: ptr[NativeUdpHandle]) -> UdpSocket:
    let state = heap.must_alloc_zeroed[UdpSocketState](1)
    unsafe:
        read(state).handle = handle
        read(state).receive_state = null
        libuv.handle_set_data(udp_as_handle(handle), ptr[void]<-state)
    return UdpSocket(handle = handle)


function duplicate_socket_address(address: SocketAddress) -> Result[SocketAddress, Error]:
    let storage = address.storage else:
        return Result[SocketAddress, Error].failure(error= invalid_address_error("socket address is released"))

    return socket_address_from_sockaddr(sockaddr_storage_as_sockaddr(storage), address.len)


function ipv4_socket_family() -> ushort:
    var raw = zero[libuv.sockaddr_in]
    let status_code = libuv.ip4_addr("0.0.0.0", 0, raw)
    if status_code != 0:
        fatal(c"std.net internal failed to determine AF_INET")

    return raw.sin_family


function ipv6_socket_family() -> ushort:
    var raw = zero[libuv.sockaddr_in6]
    let status_code = libuv.ip6_addr("::", 0, raw)
    if status_code != 0:
        fatal(c"std.net internal failed to determine AF_INET6")

    return raw.sin6_family


function socket_address_from_unknown_sockaddr(address: const_ptr[libuv.sockaddr]?) -> Result[SocketAddress, Error]:
    let live_address = address else:
        return Result[SocketAddress, Error].failure(error= invalid_address_error("socket address is missing"))

    let family = unsafe: read(live_address).sa_family
    if family == ipv4_socket_family():
        return socket_address_from_sockaddr(unsafe: ptr[libuv.sockaddr]?<-address, ptr_uint<-size_of(libuv.sockaddr_in))

    if family == ipv6_socket_family():
        return socket_address_from_sockaddr(unsafe: ptr[libuv.sockaddr]?<-address, ptr_uint<-size_of(libuv.sockaddr_in6))

    return Result[SocketAddress, Error].failure(error= invalid_address_error("unsupported socket address family"))


function take_owned_message(message: str) -> string.String:
    return string.String.from_str(message)


function libuv_error(code: int) -> Error:
    return Error(code = code, message = take_owned_message(text.cstr_as_str(libuv.strerror(code))))


function net_error(message: str) -> Error:
    return Error(code = -1, message = take_owned_message(message))


function invalid_address_error(message: str) -> Error:
    return net_error(message)


function socket_address_from_sockaddr(address: ptr[libuv.sockaddr]?, length: ptr_uint) -> Result[SocketAddress, Error]:
    let live_address = address else:
        return Result[SocketAddress, Error].failure(error= invalid_address_error("resolver returned null address"))

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
        return Result[SocketAddress, Error].success(value= result)

    if length == ipv6_size:
        unsafe:
            let source = ptr[ubyte]<-sockaddr_as_sockaddr_in6(live_address)
            let target = ptr[ubyte]<-storage
            heap.copy_bytes(target, source, ipv6_size)
        result.len = ipv6_size
        result.kind = AddressKind.ipv6
        return Result[SocketAddress, Error].success(value= result)

    heap.release(storage)
    return Result[SocketAddress, Error].failure(error= invalid_address_error("unsupported socket address family"))


function socket_address_to_string_result(address: SocketAddress) -> Result[string.String, Error]:
    let storage_ptr = address.storage else:
        return Result[string.String, Error].failure(error= invalid_address_error("socket address is released"))

    var buffer: array[char, address_name_capacity] = zero[array[char, address_name_capacity]]
    if address.kind == AddressKind.ipv4:
        var value = unsafe: read(ptr[libuv.sockaddr_in]<-storage_ptr)
        let status_code = libuv.ip4_name(ptr_of(value), ptr_of(buffer[0]), address_name_capacity)
        if status_code != 0:
            return Result[string.String, Error].failure(error= libuv_error(status_code))
    else:
        var value = unsafe: read(ptr[libuv.sockaddr_in6]<-storage_ptr)
        let status_code = libuv.ip6_name(ptr_of(value), ptr_of(buffer[0]), address_name_capacity)
        if status_code != 0:
            return Result[string.String, Error].failure(error= libuv_error(status_code))

    return Result[string.String, Error].success(value= string.String.from_str(text.chars_as_str(ptr_of(buffer[0]))))


function tcp_socket_address_from_getsockname(handle: ptr[NativeTcpHandle]?) -> Result[SocketAddress, Error]:
    let live_handle = handle else:
        return Result[SocketAddress, Error].failure(error= net_error("tcp handle is released"))

    var raw = zero[NativeSocketStorage]
    var name_length = int<-size_of(NativeSocketStorage)
    let status_code = libuv_c.uv_tcp_getsockname(
            live_handle,
            sockaddr_storage_as_sockaddr(unsafe: ptr[NativeSocketStorage]<-ptr_of(raw)),
            ptr_of(name_length),
        )
    if status_code != 0:
        return Result[SocketAddress, Error].failure(error= libuv_error(status_code))

    return socket_address_from_sockaddr(sockaddr_storage_as_sockaddr(unsafe: ptr[NativeSocketStorage]<-ptr_of(raw)), ptr_uint<-name_length)


function tcp_socket_address_from_getpeername(handle: ptr[NativeTcpHandle]?) -> Result[SocketAddress, Error]:
    let live_handle = handle else:
        return Result[SocketAddress, Error].failure(error= net_error("tcp handle is released"))

    var raw = zero[NativeSocketStorage]
    var name_length = int<-size_of(NativeSocketStorage)
    let status_code = libuv_c.uv_tcp_getpeername(
            live_handle,
            sockaddr_storage_as_sockaddr(unsafe: ptr[NativeSocketStorage]<-ptr_of(raw)),
            ptr_of(name_length),
        )
    if status_code != 0:
        return Result[SocketAddress, Error].failure(error= libuv_error(status_code))

    return socket_address_from_sockaddr(sockaddr_storage_as_sockaddr(unsafe: ptr[NativeSocketStorage]<-ptr_of(raw)), ptr_uint<-name_length)


function tcp_socket_fd(handle: ptr[NativeTcpHandle]?) -> Result[int, Error]:
    let live_handle = handle else:
        return Result[int, Error].failure(error= net_error("tcp handle is released"))

    var fd = zero[libuv.uv_os_fd_t]
    let status_code = libuv.fileno(tcp_as_handle(live_handle), fd)
    if status_code != 0:
        return Result[int, Error].failure(error= libuv_error(status_code))

    return Result[int, Error].success(value= int<-fd)


function udp_socket_address_from_getsockname(handle: ptr[NativeUdpHandle]?) -> Result[SocketAddress, Error]:
    let live_handle = handle else:
        return Result[SocketAddress, Error].failure(error= net_error("udp handle is released"))

    var raw = zero[NativeSocketStorage]
    var name_length = int<-size_of(NativeSocketStorage)
    let status_code = libuv_c.uv_udp_getsockname(
            live_handle,
            sockaddr_storage_as_sockaddr(unsafe: ptr[NativeSocketStorage]<-ptr_of(raw)),
            ptr_of(name_length),
        )
    if status_code != 0:
        return Result[SocketAddress, Error].failure(error= libuv_error(status_code))

    return socket_address_from_sockaddr(sockaddr_storage_as_sockaddr(unsafe: ptr[NativeSocketStorage]<-ptr_of(raw)), ptr_uint<-name_length)


function udp_socket_address_from_getpeername(handle: ptr[NativeUdpHandle]?) -> Result[SocketAddress, Error]:
    let live_handle = handle else:
        return Result[SocketAddress, Error].failure(error= net_error("udp handle is released"))

    var raw = zero[NativeSocketStorage]
    var name_length = int<-size_of(NativeSocketStorage)
    let status_code = libuv_c.uv_udp_getpeername(
            live_handle,
            sockaddr_storage_as_sockaddr(unsafe: ptr[NativeSocketStorage]<-ptr_of(raw)),
            ptr_of(name_length),
        )
    if status_code != 0:
        return Result[SocketAddress, Error].failure(error= libuv_error(status_code))

    return socket_address_from_sockaddr(sockaddr_storage_as_sockaddr(unsafe: ptr[NativeSocketStorage]<-ptr_of(raw)), ptr_uint<-name_length)


function udp_connect_impl(handle: ptr[NativeUdpHandle]?, destination: SocketAddress) -> Result[bool, Error]:
    let live_handle = handle else:
        return Result[bool, Error].failure(error= net_error("udp socket is released"))

    if libuv.is_closing(udp_as_handle(live_handle)) != 0:
        return Result[bool, Error].failure(error= net_error("udp socket is closing"))

    let storage = destination.storage else:
        return Result[bool, Error].failure(error= invalid_address_error("socket address is released"))

    let status_code = libuv.udp_connect(live_handle, sockaddr_storage_as_sockaddr(storage))
    if status_code != 0:
        return Result[bool, Error].failure(error= libuv_error(status_code))

    return Result[bool, Error].success(value= true)


function resolve_ready(frame: ptr[void]) -> bool:
    return unsafe: read(resolve_state(frame)).ready


function resolve_set_waiter(frame: ptr[void], waiter_frame: ptr[void], waiter: fn(frame: ptr[void]) -> void) -> void:
    let state = resolve_state(frame)
    unsafe:
        read(state).waiter_frame = waiter_frame
        read(state).waiter = waiter
        read(state).waiter_registered = true


function resolve_release(frame: ptr[void]) -> void:
    let state = resolve_state(frame)

    unsafe:
        if read(state).released:
            return
        read(state).released = true

    unsafe:
        if read(state).result_owned:
            let result_value = read(state).result
            match result_value:
                Result.success as payload:
                    var address = payload.value
                    address.release()
                Result.failure as payload:
                    var error = payload.error
                    error.release()

        var storage = read(state).storage
        storage.release()

        heap.release(state)


function resolve_take_result(frame: ptr[void]) -> Result[SocketAddress, Error]:
    let state = resolve_state(frame)
    let result_value = unsafe: read(state).result
    unsafe: read(state).result_owned = false
    return result_value


function resolve_task(state: ptr[ResolveState]) -> Task[Result[SocketAddress, Error]]:
    return unsafe: Task[Result[SocketAddress, Error]](
            frame = ptr[void]<-state,
            ready = resolve_ready,
            set_waiter = resolve_set_waiter,
            release = resolve_release,
            take_result = resolve_take_result,
        )


function release_socket_addresses(values: ref[vec.Vec[SocketAddress]]) -> void:
    var index: ptr_uint = 0
    while index < values.len:
        let current = values.get(index) else:
            fatal(c"std.net release_socket_addresses missing value")

        var address = unsafe: read(current)
        address.release()
        index += 1

    values.release()


function resolve_all_ready(frame: ptr[void]) -> bool:
    return unsafe: read(resolve_all_state(frame)).ready


function resolve_all_set_waiter(frame: ptr[void], waiter_frame: ptr[void], waiter: fn(frame: ptr[void]) -> void) -> void:
    let state = resolve_all_state(frame)
    unsafe:
        read(state).waiter_frame = waiter_frame
        read(state).waiter = waiter
        read(state).waiter_registered = true


function resolve_all_release(frame: ptr[void]) -> void:
    let state = resolve_all_state(frame)

    unsafe:
        if read(state).released:
            return
        read(state).released = true

    unsafe:
        if read(state).result_owned:
            let result_value = read(state).result
            match result_value:
                Result.success as payload:
                    var addresses = payload.value
                    release_socket_addresses(ref_of(addresses))
                Result.failure as payload:
                    var error = payload.error
                    error.release()

        var storage = read(state).storage
        storage.release()

        heap.release(state)


function resolve_all_take_result(frame: ptr[void]) -> Result[vec.Vec[SocketAddress], Error]:
    let state = resolve_all_state(frame)
    let result_value = unsafe: read(state).result
    unsafe: read(state).result_owned = false
    return result_value


function resolve_all_task(state: ptr[ResolveAllState]) -> Task[Result[vec.Vec[SocketAddress], Error]]:
    return unsafe: Task[Result[vec.Vec[SocketAddress], Error]](
            frame = ptr[void]<-state,
            ready = resolve_all_ready,
            set_waiter = resolve_all_set_waiter,
            release = resolve_all_release,
            take_result = resolve_all_take_result,
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


function connect_cleanup_and_release(state: ptr[ConnectState]) -> void:
    unsafe:
        if read(state).req != null[ptr[NativeConnectRequest]]:
            heap.release_bytes(ptr[void]<-read(state).req)
            read(state).req = null

        if read(state).destination_owned:
            var destination = read(state).destination
            destination.release()
            read(state).destination_owned = false

        if read(state).result_owned:
            let result_value = read(state).result
            match result_value:
                Result.success as payload:
                    var stream = payload.value
                    stream.release()
                Result.failure as payload:
                    var error = payload.error
                    error.release()
            read(state).result_owned = false

        if read(state).handle != null[ptr[NativeTcpHandle]]:
            close_tcp_handle(unsafe: ptr[NativeTcpHandle]<-read(state).handle)
            read(state).handle = null

        heap.release(state)


function connect_release(frame: ptr[void]) -> void:
    let state = connect_state(frame)
    if unsafe: read(state).ready:
        connect_cleanup_and_release(state)
        return

    unsafe: read(state).released = true


function connect_take_result(frame: ptr[void]) -> Result[TcpStream, Error]:
    let state = connect_state(frame)
    let result_value = unsafe: read(state).result
    unsafe: read(state).result_owned = false
    return result_value


function connect_task(state: ptr[ConnectState]) -> Task[Result[TcpStream, Error]]:
    return unsafe: Task[Result[TcpStream, Error]](
            frame = ptr[void]<-state,
            ready = connect_ready,
            set_waiter = connect_set_waiter,
            release = connect_release,
            take_result = connect_take_result,
        )


function finish_connect(state: ptr[ConnectState], result_value: Result[TcpStream, Error], status_code: int) -> void:
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

    if unsafe: read(state).released:
        connect_cleanup_and_release(state)


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

        finish_connect(state, Result[TcpStream, Error].failure(error= libuv_error(status_code)), status_code)
        return

    let handle = unsafe: read(state).handle else:
        finish_connect(state, Result[TcpStream, Error].failure(error= net_error("tcp connect completed without a handle")), -1)
        return

    unsafe: read(state).handle = null
    finish_connect(state, Result[TcpStream, Error].success(value= attach_tcp_stream(handle)), 0)


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


function accept_cleanup_and_release(state: ptr[AcceptState]) -> void:
    unsafe:
        if read(state).result_owned:
            let result_value = read(state).result
            match result_value:
                Result.success as payload:
                    var stream = payload.value
                    stream.release()
                Result.failure as payload:
                    var error = payload.error
                    error.release()
            read(state).result_owned = false

        heap.release(state)


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


function accept_take_result(frame: ptr[void]) -> Result[TcpStream, Error]:
    let state = accept_state(frame)
    let result_value = unsafe: read(state).result
    unsafe: read(state).result_owned = false
    return result_value


function accept_task(state: ptr[AcceptState]) -> Task[Result[TcpStream, Error]]:
    return unsafe: Task[Result[TcpStream, Error]](
            frame = ptr[void]<-state,
            ready = accept_ready,
            set_waiter = accept_set_waiter,
            release = accept_release,
            take_result = accept_take_result,
        )


function finish_accept(state: ptr[AcceptState], result_value: Result[TcpStream, Error], status_code: int) -> void:
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


function listener_close_callback(handle: ptr[NativeHandle]) -> void:
    let state_raw = libuv.handle_get_data(handle) else:
        unsafe: heap.release_bytes(ptr[void]<-handle_as_tcp(handle))
        return

    let listener = unsafe: ptr[ListenerState]<-state_raw
    let pending_accept = unsafe: read(listener).accept_state
    if pending_accept != null[ptr[AcceptState]]:
        unsafe: read(listener).accept_state = null
        finish_accept(unsafe: ptr[AcceptState]<-pending_accept, Result[TcpStream, Error].failure(error= net_error("listener closed")), -1)

    unsafe:
        heap.release_bytes(ptr[void]<-handle_as_tcp(handle))
        read(listener).handle = null
        heap.release(listener)


function perform_listener_accept(listener: ptr[ListenerState], state: ptr[AcceptState]) -> void:
    let server_handle = unsafe: read(listener).handle else:
        finish_accept(state, Result[TcpStream, Error].failure(error= net_error("listener is released")), -1)
        return

    let client_handle = alloc_tcp_handle()
    let init_status = libuv.tcp_init(libuv.handle_get_loop(tcp_as_handle(server_handle)), client_handle)
    if init_status != 0:
        unsafe: heap.release_bytes(ptr[void]<-client_handle)
        finish_accept(state, Result[TcpStream, Error].failure(error= libuv_error(init_status)), init_status)
        return

    let accept_status = libuv.accept(tcp_as_stream(server_handle), tcp_as_stream(client_handle))
    if accept_status != 0:
        close_tcp_handle(client_handle)
        finish_accept(state, Result[TcpStream, Error].failure(error= libuv_error(accept_status)), accept_status)
        return

    finish_accept(state, Result[TcpStream, Error].success(value= attach_tcp_stream(client_handle)), 0)


function listener_connection_callback(server: ptr[NativeStreamHandle], status_code: int) -> void:
    let state_raw = libuv.handle_get_data(stream_as_handle(server)) else:
        return

    let listener = unsafe: ptr[ListenerState]<-state_raw
    let pending_accept = unsafe: read(listener).accept_state
    if status_code != 0:
        if pending_accept != null[ptr[AcceptState]]:
            unsafe: read(listener).accept_state = null
            finish_accept(unsafe: ptr[AcceptState]<-pending_accept, Result[TcpStream, Error].failure(error= libuv_error(status_code)), status_code)
        else:
            unsafe: read(listener).pending_error_code = status_code
        return

    if pending_accept != null[ptr[AcceptState]]:
        unsafe: read(listener).accept_state = null
        perform_listener_accept(listener, unsafe: ptr[AcceptState]<-pending_accept)
        return

    unsafe: read(listener).pending_connections += 1


function accept_impl(handle: ptr[NativeTcpHandle]?) -> Task[Result[TcpStream, Error]]:
    let state = heap.must_alloc_zeroed[AcceptState](1)
    unsafe:
        read(state).ready = false
        read(state).status_code = 0
        read(state).result = Result[TcpStream, Error].success(value= zero[TcpStream])
        read(state).result_owned = false
        read(state).waiter_frame = null
        read(state).waiter = noop_waiter
        read(state).waiter_registered = false
        read(state).listener = null

    let live_handle = handle else:
        finish_accept(state, Result[TcpStream, Error].failure(error= net_error("listener is released")), -1)
        return accept_task(state)

    if libuv.is_closing(tcp_as_handle(live_handle)) != 0:
        finish_accept(state, Result[TcpStream, Error].failure(error= net_error("listener is closing")), -1)
        return accept_task(state)

    let state_raw = libuv.handle_get_data(tcp_as_handle(live_handle)) else:
        finish_accept(state, Result[TcpStream, Error].failure(error= net_error("listener state is unavailable")), -1)
        return accept_task(state)

    let listener = unsafe: ptr[ListenerState]<-state_raw
    unsafe: read(state).listener = listener

    let pending_error_code = unsafe: read(listener).pending_error_code
    if pending_error_code != 0:
        unsafe:
            read(listener).pending_error_code = 0
            read(state).listener = null
        finish_accept(state, Result[TcpStream, Error].failure(error= libuv_error(pending_error_code)), pending_error_code)
        return accept_task(state)

    if unsafe: read(listener).accept_state != null[ptr[AcceptState]]:
        unsafe: read(state).listener = null
        finish_accept(state, Result[TcpStream, Error].failure(error= net_error("listener already has a pending accept")), -1)
        return accept_task(state)

    if unsafe: read(listener).pending_connections > 0:
        unsafe: read(listener).pending_connections -= 1
        perform_listener_accept(listener, state)
        return accept_task(state)

    unsafe: read(listener).accept_state = state
    return accept_task(state)


function tcp_stream_close_callback(handle: ptr[NativeHandle]) -> void:
    let state_raw = libuv.handle_get_data(handle) else:
        unsafe: heap.release_bytes(ptr[void]<-handle_as_tcp(handle))
        return

    let stream = unsafe: ptr[TcpStreamState]<-state_raw
    let pending_read = unsafe: read(stream).read_state
    if pending_read != null[ptr[ReadState]]:
        unsafe:
            read(stream).read_state = null
            read(ptr[ReadState]<-pending_read).stream = null
        finish_stream_read(unsafe: ptr[ReadState]<-pending_read, Result[bytes.Bytes, Error].failure(error= net_error("tcp stream closed")), -1)

    unsafe:
        heap.release_bytes(ptr[void]<-handle_as_tcp(handle))
        read(stream).handle = null
        heap.release(stream)


function close_tcp_stream_handle(handle: ptr[NativeTcpHandle]) -> void:
    if libuv.is_closing(tcp_as_handle(handle)) != 0:
        return

    let state_raw = libuv.handle_get_data(tcp_as_handle(handle))
    if state_raw == null[ptr[void]]:
        close_tcp_handle(handle)
        return

    libuv.close(tcp_as_handle(handle), tcp_stream_close_callback)


function write_ready(frame: ptr[void]) -> bool:
    return unsafe: read(write_state(frame)).ready


function write_set_waiter(frame: ptr[void], waiter_frame: ptr[void], waiter: fn(frame: ptr[void]) -> void) -> void:
    let state = write_state(frame)
    unsafe:
        if read(state).ready:
            waiter(waiter_frame)
            return

        read(state).waiter_frame = waiter_frame
        read(state).waiter = waiter
        read(state).waiter_registered = true


function write_cleanup_and_release(state: ptr[WriteState]) -> void:
    unsafe:
        if read(state).req != null[ptr[NativeWriteRequest]]:
            heap.release_bytes(ptr[void]<-read(state).req)
            read(state).req = null

        if read(state).buffers != null[ptr[NativeBuffer]]:
            heap.release(read(state).buffers)
            read(state).buffers = null

        var stored_data = read(state).data
        stored_data.release()
        read(state).data = bytes.Bytes.empty()

        if read(state).result_owned:
            let result_value = read(state).result
            match result_value:
                Result.success as ok_payload:
                    unsafe: ptr_uint<-ok_payload.value
                Result.failure as error_payload:
                    var error = error_payload.error
                    error.release()
            read(state).result_owned = false

        heap.release(state)


function write_release(frame: ptr[void]) -> void:
    let state = write_state(frame)
    if unsafe: read(state).ready:
        write_cleanup_and_release(state)
        return

    unsafe: read(state).released = true


function write_take_result(frame: ptr[void]) -> Result[ptr_uint, Error]:
    let state = write_state(frame)
    let result_value = unsafe: read(state).result
    unsafe: read(state).result_owned = false
    return result_value


function write_task(state: ptr[WriteState]) -> Task[Result[ptr_uint, Error]]:
    return unsafe: Task[Result[ptr_uint, Error]](
            frame = ptr[void]<-state,
            ready = write_ready,
            set_waiter = write_set_waiter,
            release = write_release,
            take_result = write_take_result,
        )


function finish_write(state: ptr[WriteState], result_value: Result[ptr_uint, Error], status_code: int, owns_error: bool) -> void:
    var waiter: fn(frame: ptr[void]) -> void = noop_waiter
    var waiter_frame: ptr[void]? = null
    var notify = false

    unsafe:
        read(state).result = result_value
        read(state).result_owned = owns_error
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

    if unsafe: read(state).released:
        write_cleanup_and_release(state)


function write_callback(req: ptr[NativeWriteRequest], status_code: int) -> void:
    let state_raw = libuv.req_get_data(write_req_as_base(req)) else:
        unsafe: heap.release_bytes(ptr[void]<-req)
        return

    let state = unsafe: ptr[WriteState]<-state_raw
    let written = unsafe: read(state).data.len
    unsafe:
        heap.release_bytes(ptr[void]<-req)
        read(state).req = null

        if read(state).buffers != null[ptr[NativeBuffer]]:
            heap.release(read(state).buffers)
            read(state).buffers = null

        var payload = read(state).data
        payload.release()
        read(state).data = bytes.Bytes.empty()

    if status_code != 0:
        finish_write(state, Result[ptr_uint, Error].failure(error= libuv_error(status_code)), status_code, true)
        return

    finish_write(state, Result[ptr_uint, Error].success(value= written), 0, false)


function write_on_impl(handle: ptr[NativeTcpHandle]?, content: span[ubyte]) -> Task[Result[ptr_uint, Error]]:
    let state = heap.must_alloc_zeroed[WriteState](1)
    unsafe:
        read(state).ready = false
        read(state).status_code = 0
        read(state).result = Result[ptr_uint, Error].success(value= 0)
        read(state).result_owned = false
        read(state).waiter_frame = null
        read(state).waiter = noop_waiter
        read(state).waiter_registered = false
        read(state).req = null
        read(state).buffers = null
        read(state).data = bytes.Bytes.empty()
        read(state).released = false

    let live_handle = handle else:
        finish_write(state, Result[ptr_uint, Error].failure(error= net_error("tcp stream is released")), -1, true)
        return write_task(state)

    if libuv.is_closing(tcp_as_handle(live_handle)) != 0:
        finish_write(state, Result[ptr_uint, Error].failure(error= net_error("tcp stream is closing")), -1, true)
        return write_task(state)

    if content.len == 0:
        finish_write(state, Result[ptr_uint, Error].success(value= 0), 0, false)
        return write_task(state)

    let copied = bytes.Bytes.copy(content)
    let copied_data = copied.data else:
        finish_write(state, Result[ptr_uint, Error].failure(error= net_error("tcp write missing storage")), -1, true)
        return write_task(state)

    let req = alloc_write_request()
    let buffers = heap.must_alloc_zeroed[NativeBuffer](1)
    unsafe:
        read(state).req = req
        read(state).buffers = buffers
        read(state).data = copied
        read(buffers) = libuv.buf_init(ptr[char]<-copied_data, uint<-copied.len)
        libuv.req_set_data(write_req_as_base(req), ptr[void]<-state)

    let queue_status = libuv.write(req, tcp_as_stream(live_handle), buffers, 1, write_callback)
    if queue_status != 0:
        unsafe:
            heap.release_bytes(ptr[void]<-req)
            read(state).req = null
            heap.release(buffers)
            read(state).buffers = null
            var payload = read(state).data
            payload.release()
            read(state).data = bytes.Bytes.empty()
        finish_write(state, Result[ptr_uint, Error].failure(error= libuv_error(queue_status)), queue_status, true)
        return write_task(state)

    return write_task(state)


function stream_read_ready(frame: ptr[void]) -> bool:
    return unsafe: read(stream_read_state(frame)).ready


function stream_read_set_waiter(frame: ptr[void], waiter_frame: ptr[void], waiter: fn(frame: ptr[void]) -> void) -> void:
    let state = stream_read_state(frame)
    unsafe:
        if read(state).ready:
            waiter(waiter_frame)
            return

        read(state).waiter_frame = waiter_frame
        read(state).waiter = waiter
        read(state).waiter_registered = true


function stream_read_reset_buffer(state: ptr[ReadState]) -> void:
    let buffer = unsafe: read(state).buffer
    if buffer != null[ptr[ubyte]]:
        heap.release(buffer)

    unsafe:
        read(state).buffer = null
        read(state).received_bytes = 0


function stream_read_take_payload(state: ptr[ReadState]) -> bytes.Bytes:
    let received_bytes = unsafe: read(state).received_bytes
    if received_bytes == 0:
        stream_read_reset_buffer(state)
        return bytes.Bytes.empty()

    let buffer = unsafe: read(state).buffer else:
        fatal(c"std.net tcp read buffer missing storage")

    unsafe:
        read(state).buffer = null
        read(state).received_bytes = 0
    return bytes.Bytes(data = buffer, len = received_bytes)


function stop_stream_read(stream: ptr[TcpStreamState], state: ptr[ReadState], stream_handle: ptr[NativeStreamHandle]) -> void:
    unsafe:
        if read(stream).read_state == state:
            read(stream).read_state = null
        read(state).stream = null

    libuv.read_stop(stream_handle)


function stream_read_cleanup_and_release(state: ptr[ReadState]) -> void:
    unsafe:
        if read(state).buffer != null[ptr[ubyte]]:
            heap.release(read(state).buffer)
            read(state).buffer = null
            read(state).received_bytes = 0

        if read(state).result_owned:
            let result_value = read(state).result
            match result_value:
                Result.success as payload:
                    var payload_data = payload.value
                    payload_data.release()
                Result.failure as payload:
                    var error = payload.error
                    error.release()
            read(state).result_owned = false

        heap.release(state)


function stream_read_release(frame: ptr[void]) -> void:
    let state = stream_read_state(frame)
    if unsafe: read(state).ready:
        stream_read_cleanup_and_release(state)
        return

    unsafe: read(state).released = true

    let stream = unsafe: read(state).stream
    if stream != null[ptr[TcpStreamState]]:
        let live_stream = unsafe: ptr[TcpStreamState]<-stream
        let handle = unsafe: read(live_stream).handle
        unsafe:
            if read(live_stream).read_state == state:
                read(live_stream).read_state = null
            read(state).stream = null

        if handle != null[ptr[NativeTcpHandle]]:
            libuv.read_stop(tcp_as_stream(unsafe: ptr[NativeTcpHandle]<-handle))

    finish_stream_read(state, Result[bytes.Bytes, Error].failure(error= net_error("tcp read released")), -1)


function stream_read_take_result(frame: ptr[void]) -> Result[bytes.Bytes, Error]:
    let state = stream_read_state(frame)
    let result_value = unsafe: read(state).result
    unsafe: read(state).result_owned = false
    return result_value


function stream_read_task(state: ptr[ReadState]) -> Task[Result[bytes.Bytes, Error]]:
    return unsafe: Task[Result[bytes.Bytes, Error]](
            frame = ptr[void]<-state,
            ready = stream_read_ready,
            set_waiter = stream_read_set_waiter,
            release = stream_read_release,
            take_result = stream_read_take_result,
        )


function finish_stream_read(state: ptr[ReadState], result_value: Result[bytes.Bytes, Error], status_code: int) -> void:
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

    if unsafe: read(state).released:
        stream_read_cleanup_and_release(state)


function stream_read_alloc_callback(handle: ptr[NativeHandle], suggested_size: ptr_uint, buf: ptr[NativeBuffer]) -> void:
    let state_raw = libuv.handle_get_data(handle) else:
        let storage = unsafe: ptr[char]<-heap.must_alloc_zeroed_bytes(1, 1)
        unsafe: read(buf) = libuv.buf_init(storage, 0)
        return

    let stream = unsafe: ptr[TcpStreamState]<-state_raw
    let pending_read = unsafe: read(stream).read_state
    if pending_read == null[ptr[ReadState]]:
        let storage = unsafe: ptr[char]<-heap.must_alloc_zeroed_bytes(1, 1)
        unsafe: read(buf) = libuv.buf_init(storage, 0)
        return

    let state = unsafe: ptr[ReadState]<-pending_read
    var capacity = suggested_size
    let remaining = unsafe: read(state).max_bytes - read(state).received_bytes
    if remaining < capacity:
        capacity = remaining

    if capacity == 0:
        capacity = 1

    let storage = unsafe: ptr[char]<-heap.must_alloc_zeroed_bytes(1, capacity)
    unsafe: read(buf) = libuv.buf_init(storage, uint<-capacity)


function stream_read_callback(stream_handle: ptr[NativeStreamHandle], nread: ptr_int, buf: const_ptr[NativeBuffer]) -> void:
    let raw_buffer = unsafe: read(buf)

    let state_raw = libuv.handle_get_data(stream_as_handle(stream_handle)) else:
        release_uv_buffer(raw_buffer)
        return

    let stream = unsafe: ptr[TcpStreamState]<-state_raw
    let pending_read = unsafe: read(stream).read_state
    if pending_read == null[ptr[ReadState]]:
        release_uv_buffer(raw_buffer)
        return

    let state = unsafe: ptr[ReadState]<-pending_read
    if nread == 0:
        release_uv_buffer(raw_buffer)
        return

    if nread < 0:
        release_uv_buffer(raw_buffer)
        stop_stream_read(stream, state, stream_handle)
        if nread == ptr_int<-libuv._EOF:
            let exact = unsafe: read(state).exact
            let total_received = unsafe: read(state).received_bytes
            let max_bytes = unsafe: read(state).max_bytes
            if exact and total_received < max_bytes:
                stream_read_reset_buffer(state)
                finish_stream_read(state, Result[bytes.Bytes, Error].failure(error= net_error("tcp stream ended before requested bytes were read")), int<-nread)
                return

            finish_stream_read(state, Result[bytes.Bytes, Error].success(value= stream_read_take_payload(state)), 0)
            return

        stream_read_reset_buffer(state)
        finish_stream_read(state, Result[bytes.Bytes, Error].failure(error= libuv_error(int<-nread)), int<-nread)
        return

    let destination = unsafe: read(state).buffer else:
        release_uv_buffer(raw_buffer)
        stop_stream_read(stream, state, stream_handle)
        finish_stream_read(state, Result[bytes.Bytes, Error].failure(error= net_error("tcp read buffer missing storage")), -1)
        return

    let chunk_len = ptr_uint<-nread
    let received_bytes = unsafe: read(state).received_bytes
    unsafe:
        heap.copy_bytes(ptr[ubyte]<-destination + received_bytes, ptr[ubyte]<-raw_buffer.base, chunk_len)
        read(state).received_bytes = received_bytes + chunk_len

    release_uv_buffer(raw_buffer)

    let exact = unsafe: read(state).exact
    let total_received = unsafe: read(state).received_bytes
    let max_bytes = unsafe: read(state).max_bytes
    if (not exact) or total_received == max_bytes:
        stop_stream_read(stream, state, stream_handle)
        finish_stream_read(state, Result[bytes.Bytes, Error].success(value= stream_read_take_payload(state)), 0)


function read_impl(handle: ptr[NativeTcpHandle]?, max_bytes: ptr_uint, exact: bool) -> Task[Result[bytes.Bytes, Error]]:
    let state = heap.must_alloc_zeroed[ReadState](1)
    unsafe:
        read(state).ready = false
        read(state).status_code = 0
        read(state).result = Result[bytes.Bytes, Error].success(value= bytes.Bytes.empty())
        read(state).result_owned = false
        read(state).waiter_frame = null
        read(state).waiter = noop_waiter
        read(state).waiter_registered = false
        read(state).stream = null
        read(state).max_bytes = max_bytes
        read(state).buffer = null
        read(state).received_bytes = 0
        read(state).exact = exact
        read(state).released = false

    if max_bytes == 0:
        finish_stream_read(state, Result[bytes.Bytes, Error].failure(error= net_error("tcp read requires max_bytes > 0")), -1)
        return stream_read_task(state)

    let live_handle = handle else:
        finish_stream_read(state, Result[bytes.Bytes, Error].failure(error= net_error("tcp stream is released")), -1)
        return stream_read_task(state)

    if libuv.is_closing(tcp_as_handle(live_handle)) != 0:
        finish_stream_read(state, Result[bytes.Bytes, Error].failure(error= net_error("tcp stream is closing")), -1)
        return stream_read_task(state)

    let stream_raw = libuv.handle_get_data(tcp_as_handle(live_handle)) else:
        finish_stream_read(state, Result[bytes.Bytes, Error].failure(error= net_error("tcp stream state is unavailable")), -1)
        return stream_read_task(state)

    let stream = unsafe: ptr[TcpStreamState]<-stream_raw
    if unsafe: read(stream).read_state != null[ptr[ReadState]]:
        finish_stream_read(state, Result[bytes.Bytes, Error].failure(error= net_error("tcp stream already has a pending read")), -1)
        return stream_read_task(state)

    let buffer = heap.must_alloc[ubyte](max_bytes)
    unsafe:
        read(state).buffer = buffer
        read(state).stream = stream
        read(stream).read_state = state

    let start_status = libuv.read_start(tcp_as_stream(live_handle), stream_read_alloc_callback, stream_read_callback)
    if start_status != 0:
        unsafe:
            read(stream).read_state = null
            read(state).stream = null
        finish_stream_read(state, Result[bytes.Bytes, Error].failure(error= libuv_error(start_status)), start_status)
        return stream_read_task(state)

    return stream_read_task(state)


function read_once_impl(handle: ptr[NativeTcpHandle]?, max_bytes: ptr_uint) -> Task[Result[bytes.Bytes, Error]]:
    return read_impl(handle, max_bytes, false)


function read_exactly_impl(handle: ptr[NativeTcpHandle]?, byte_count: ptr_uint) -> Task[Result[bytes.Bytes, Error]]:
    return read_impl(handle, byte_count, true)


function shutdown_ready(frame: ptr[void]) -> bool:
    return unsafe: read(shutdown_state(frame)).ready


function shutdown_set_waiter(frame: ptr[void], waiter_frame: ptr[void], waiter: fn(frame: ptr[void]) -> void) -> void:
    let state = shutdown_state(frame)
    unsafe:
        if read(state).ready:
            waiter(waiter_frame)
            return

        read(state).waiter_frame = waiter_frame
        read(state).waiter = waiter
        read(state).waiter_registered = true


function shutdown_cleanup_and_release(state: ptr[ShutdownState]) -> void:
    unsafe:
        if read(state).req != null[ptr[NativeShutdownRequest]]:
            heap.release_bytes(ptr[void]<-read(state).req)
            read(state).req = null

        if read(state).result_owned:
            let result_value = read(state).result
            match result_value:
                Result.success as payload:
                    unsafe: bool<-payload.value
                Result.failure as payload:
                    var error = payload.error
                    error.release()
            read(state).result_owned = false

        heap.release(state)


function shutdown_release(frame: ptr[void]) -> void:
    let state = shutdown_state(frame)
    if unsafe: read(state).ready:
        shutdown_cleanup_and_release(state)
        return

    unsafe: read(state).released = true


function shutdown_take_result(frame: ptr[void]) -> Result[bool, Error]:
    let state = shutdown_state(frame)
    let result_value = unsafe: read(state).result
    unsafe: read(state).result_owned = false
    return result_value


function shutdown_task(state: ptr[ShutdownState]) -> Task[Result[bool, Error]]:
    return unsafe: Task[Result[bool, Error]](
            frame = ptr[void]<-state,
            ready = shutdown_ready,
            set_waiter = shutdown_set_waiter,
            release = shutdown_release,
            take_result = shutdown_take_result,
        )


function finish_shutdown(state: ptr[ShutdownState], result_value: Result[bool, Error], status_code: int, owns_error: bool) -> void:
    var waiter: fn(frame: ptr[void]) -> void = noop_waiter
    var waiter_frame: ptr[void]? = null
    var notify = false

    unsafe:
        read(state).result = result_value
        read(state).result_owned = owns_error
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

    if unsafe: read(state).released:
        shutdown_cleanup_and_release(state)


function shutdown_callback(req: ptr[NativeShutdownRequest], status_code: int) -> void:
    let state_raw = libuv.req_get_data(shutdown_req_as_base(req)) else:
        unsafe: heap.release_bytes(ptr[void]<-req)
        return

    let state = unsafe: ptr[ShutdownState]<-state_raw
    unsafe:
        heap.release_bytes(ptr[void]<-req)
        read(state).req = null

    if status_code != 0:
        finish_shutdown(state, Result[bool, Error].failure(error= libuv_error(status_code)), status_code, true)
        return

    finish_shutdown(state, Result[bool, Error].success(value= true), 0, false)


function shutdown_impl(handle: ptr[NativeTcpHandle]?) -> Task[Result[bool, Error]]:
    let state = heap.must_alloc_zeroed[ShutdownState](1)
    unsafe:
        read(state).ready = false
        read(state).status_code = 0
        read(state).result = Result[bool, Error].success(value= false)
        read(state).result_owned = false
        read(state).waiter_frame = null
        read(state).waiter = noop_waiter
        read(state).waiter_registered = false
        read(state).req = null
        read(state).released = false

    let live_handle = handle else:
        finish_shutdown(state, Result[bool, Error].failure(error= net_error("tcp stream is released")), -1, true)
        return shutdown_task(state)

    if libuv.is_closing(tcp_as_handle(live_handle)) != 0:
        finish_shutdown(state, Result[bool, Error].failure(error= net_error("tcp stream is closing")), -1, true)
        return shutdown_task(state)

    let req = alloc_shutdown_request()
    unsafe:
        read(state).req = req
        libuv.req_set_data(shutdown_req_as_base(req), ptr[void]<-state)

    let queue_status = libuv.shutdown(req, tcp_as_stream(live_handle), shutdown_callback)
    if queue_status != 0:
        unsafe:
            heap.release_bytes(ptr[void]<-req)
            read(state).req = null
        finish_shutdown(state, Result[bool, Error].failure(error= libuv_error(queue_status)), queue_status, true)
        return shutdown_task(state)

    return shutdown_task(state)


function udp_socket_close_callback(handle: ptr[NativeHandle]) -> void:
    let state_raw = libuv.handle_get_data(handle) else:
        unsafe: heap.release_bytes(ptr[void]<-handle_as_udp(handle))
        return

    let socket = unsafe: ptr[UdpSocketState]<-state_raw
    let pending_receive = unsafe: read(socket).receive_state
    if pending_receive != null[ptr[UdpReceiveState]]:
        unsafe:
            read(socket).receive_state = null
            read(ptr[UdpReceiveState]<-pending_receive).socket = null
        finish_udp_receive(unsafe: ptr[UdpReceiveState]<-pending_receive, Result[UdpDatagram, Error].failure(error= net_error("udp socket closed")), -1)

    unsafe:
        heap.release_bytes(ptr[void]<-handle_as_udp(handle))
        read(socket).handle = null
        heap.release(socket)


function close_udp_socket_handle(handle: ptr[NativeUdpHandle]) -> void:
    if libuv.is_closing(udp_as_handle(handle)) != 0:
        return

    let state_raw = libuv.handle_get_data(udp_as_handle(handle))
    if state_raw == null[ptr[void]]:
        close_raw_udp_handle(handle)
        return

    libuv.close(udp_as_handle(handle), udp_socket_close_callback)


function udp_send_ready(frame: ptr[void]) -> bool:
    return unsafe: read(udp_send_state(frame)).ready


function udp_send_set_waiter(frame: ptr[void], waiter_frame: ptr[void], waiter: fn(frame: ptr[void]) -> void) -> void:
    let state = udp_send_state(frame)
    unsafe:
        if read(state).ready:
            waiter(waiter_frame)
            return

        read(state).waiter_frame = waiter_frame
        read(state).waiter = waiter
        read(state).waiter_registered = true


function udp_send_cleanup_and_release(state: ptr[UdpSendState]) -> void:
    unsafe:
        if read(state).req != null[ptr[NativeUdpSendRequest]]:
            heap.release_bytes(ptr[void]<-read(state).req)
            read(state).req = null

        if read(state).buffers != null[ptr[NativeBuffer]]:
            heap.release(read(state).buffers)
            read(state).buffers = null

        var stored_data = read(state).data
        stored_data.release()
        read(state).data = bytes.Bytes.empty()

        if read(state).destination_owned:
            var destination = read(state).destination
            destination.release()
            read(state).destination_owned = false

        if read(state).result_owned:
            let result_value = read(state).result
            match result_value:
                Result.success as ok_payload:
                    unsafe: ptr_uint<-ok_payload.value
                Result.failure as error_payload:
                    var error = error_payload.error
                    error.release()
            read(state).result_owned = false

        heap.release(state)


function udp_send_release(frame: ptr[void]) -> void:
    let state = udp_send_state(frame)
    if unsafe: read(state).ready:
        udp_send_cleanup_and_release(state)
        return

    unsafe: read(state).released = true


function udp_send_take_result(frame: ptr[void]) -> Result[ptr_uint, Error]:
    let state = udp_send_state(frame)
    let result_value = unsafe: read(state).result
    unsafe: read(state).result_owned = false
    return result_value


function udp_send_task(state: ptr[UdpSendState]) -> Task[Result[ptr_uint, Error]]:
    return unsafe: Task[Result[ptr_uint, Error]](
            frame = ptr[void]<-state,
            ready = udp_send_ready,
            set_waiter = udp_send_set_waiter,
            release = udp_send_release,
            take_result = udp_send_take_result,
        )


function finish_udp_send(state: ptr[UdpSendState], result_value: Result[ptr_uint, Error], status_code: int, owns_error: bool) -> void:
    var waiter: fn(frame: ptr[void]) -> void = noop_waiter
    var waiter_frame: ptr[void]? = null
    var notify = false

    unsafe:
        read(state).result = result_value
        read(state).result_owned = owns_error
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

    if unsafe: read(state).released:
        udp_send_cleanup_and_release(state)


function udp_send_callback(req: ptr[NativeUdpSendRequest], status_code: int) -> void:
    let state_raw = libuv.req_get_data(udp_send_req_as_base(req)) else:
        unsafe: heap.release_bytes(ptr[void]<-req)
        return

    let state = unsafe: ptr[UdpSendState]<-state_raw
    let sent = unsafe: read(state).data.len
    unsafe:
        heap.release_bytes(ptr[void]<-req)
        read(state).req = null

        if read(state).buffers != null[ptr[NativeBuffer]]:
            heap.release(read(state).buffers)
            read(state).buffers = null

        var payload = read(state).data
        payload.release()
        read(state).data = bytes.Bytes.empty()

        if read(state).destination_owned:
            var destination = read(state).destination
            destination.release()
            read(state).destination_owned = false

    if status_code != 0:
        finish_udp_send(state, Result[ptr_uint, Error].failure(error= libuv_error(status_code)), status_code, true)
        return

    finish_udp_send(state, Result[ptr_uint, Error].success(value= sent), 0, false)


function udp_send_impl(handle: ptr[NativeUdpHandle]?, content: span[ubyte], destination: SocketAddress, use_destination: bool) -> Task[Result[ptr_uint, Error]]:
    let state = heap.must_alloc_zeroed[UdpSendState](1)
    unsafe:
        read(state).ready = false
        read(state).status_code = 0
        read(state).result = Result[ptr_uint, Error].success(value= 0)
        read(state).result_owned = false
        read(state).waiter_frame = null
        read(state).waiter = noop_waiter
        read(state).waiter_registered = false
        read(state).req = null
        read(state).buffers = null
        read(state).data = bytes.Bytes.empty()
        read(state).destination = zero[SocketAddress]
        read(state).destination_owned = false
        read(state).released = false

    let live_handle = handle else:
        finish_udp_send(state, Result[ptr_uint, Error].failure(error= net_error("udp socket is released")), -1, true)
        return udp_send_task(state)

    if libuv.is_closing(udp_as_handle(live_handle)) != 0:
        finish_udp_send(state, Result[ptr_uint, Error].failure(error= net_error("udp socket is closing")), -1, true)
        return udp_send_task(state)

    if content.len == 0:
        finish_udp_send(state, Result[ptr_uint, Error].success(value= 0), 0, false)
        return udp_send_task(state)

    if use_destination:
        match duplicate_socket_address(destination):
            Result.failure as payload:
                let error = payload.error
                finish_udp_send(state, Result[ptr_uint, Error].failure(error= error), error.code, true)
                return udp_send_task(state)
            Result.success as payload:
                unsafe:
                    read(state).destination = payload.value
                    read(state).destination_owned = true

    let copied = bytes.Bytes.copy(content)
    let copied_data = copied.data else:
        finish_udp_send(state, Result[ptr_uint, Error].failure(error= net_error("udp send missing storage")), -1, true)
        return udp_send_task(state)

    var remote_address: const_ptr[libuv.sockaddr]? = null[const_ptr[libuv.sockaddr]]
    if use_destination:
        let destination_storage = unsafe: read(state).destination.storage else:
            var payload = copied
            payload.release()
            finish_udp_send(state, Result[ptr_uint, Error].failure(error= invalid_address_error("socket address is released")), -1, true)
            return udp_send_task(state)

        remote_address = sockaddr_storage_as_sockaddr(destination_storage)

    let req = alloc_udp_send_request()
    let buffers = heap.must_alloc_zeroed[NativeBuffer](1)
    unsafe:
        read(state).req = req
        read(state).buffers = buffers
        read(state).data = copied
        read(buffers) = libuv.buf_init(ptr[char]<-copied_data, uint<-copied.len)
        libuv.req_set_data(udp_send_req_as_base(req), ptr[void]<-state)

    let queue_status = libuv.udp_send(req, live_handle, buffers, 1, remote_address, udp_send_callback)
    if queue_status != 0:
        unsafe:
            heap.release_bytes(ptr[void]<-req)
            read(state).req = null
            heap.release(buffers)
            read(state).buffers = null
            var payload = read(state).data
            payload.release()
            read(state).data = bytes.Bytes.empty()
            if read(state).destination_owned:
                var target = read(state).destination
                target.release()
                read(state).destination_owned = false
        finish_udp_send(state, Result[ptr_uint, Error].failure(error= libuv_error(queue_status)), queue_status, true)
        return udp_send_task(state)

    return udp_send_task(state)


function udp_send_to_impl(handle: ptr[NativeUdpHandle]?, content: span[ubyte], destination: SocketAddress) -> Task[Result[ptr_uint, Error]]:
    return udp_send_impl(handle, content, destination, true)


function udp_send_connected_impl(handle: ptr[NativeUdpHandle]?, content: span[ubyte]) -> Task[Result[ptr_uint, Error]]:
    return udp_send_impl(handle, content, zero[SocketAddress], false)


function udp_receive_ready(frame: ptr[void]) -> bool:
    return unsafe: read(udp_receive_state(frame)).ready


function udp_receive_set_waiter(frame: ptr[void], waiter_frame: ptr[void], waiter: fn(frame: ptr[void]) -> void) -> void:
    let state = udp_receive_state(frame)
    unsafe:
        if read(state).ready:
            waiter(waiter_frame)
            return

        read(state).waiter_frame = waiter_frame
        read(state).waiter = waiter
        read(state).waiter_registered = true


function udp_receive_cleanup_and_release(state: ptr[UdpReceiveState]) -> void:
    unsafe:
        if read(state).result_owned:
            let result_value = read(state).result
            match result_value:
                Result.success as payload:
                    var datagram = payload.value
                    datagram.data.release()
                    datagram.source.release()
                Result.failure as payload:
                    var error = payload.error
                    error.release()
            read(state).result_owned = false

        heap.release(state)


function udp_receive_release(frame: ptr[void]) -> void:
    let state = udp_receive_state(frame)
    if unsafe: read(state).ready:
        udp_receive_cleanup_and_release(state)
        return

    unsafe: read(state).released = true

    let socket = unsafe: read(state).socket
    if socket != null[ptr[UdpSocketState]]:
        let live_socket = unsafe: ptr[UdpSocketState]<-socket
        let handle = unsafe: read(live_socket).handle
        unsafe:
            if read(live_socket).receive_state == state:
                read(live_socket).receive_state = null
            read(state).socket = null

        if handle != null[ptr[NativeUdpHandle]]:
            libuv.udp_recv_stop(unsafe: ptr[NativeUdpHandle]<-handle)

    finish_udp_receive(state, Result[UdpDatagram, Error].failure(error= net_error("udp receive released")), -1)


function udp_receive_take_result(frame: ptr[void]) -> Result[UdpDatagram, Error]:
    let state = udp_receive_state(frame)
    let result_value = unsafe: read(state).result
    unsafe: read(state).result_owned = false
    return result_value


function udp_receive_task(state: ptr[UdpReceiveState]) -> Task[Result[UdpDatagram, Error]]:
    return unsafe: Task[Result[UdpDatagram, Error]](
            frame = ptr[void]<-state,
            ready = udp_receive_ready,
            set_waiter = udp_receive_set_waiter,
            release = udp_receive_release,
            take_result = udp_receive_take_result,
        )


function finish_udp_receive(state: ptr[UdpReceiveState], result_value: Result[UdpDatagram, Error], status_code: int) -> void:
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

    if unsafe: read(state).released:
        udp_receive_cleanup_and_release(state)


function udp_receive_alloc_callback(handle: ptr[NativeHandle], suggested_size: ptr_uint, buf: ptr[NativeBuffer]) -> void:
    let state_raw = libuv.handle_get_data(handle) else:
        let storage = unsafe: ptr[char]<-heap.must_alloc_zeroed_bytes(1, 1)
        unsafe: read(buf) = libuv.buf_init(storage, 0)
        return

    let socket = unsafe: ptr[UdpSocketState]<-state_raw
    let pending_receive = unsafe: read(socket).receive_state
    if pending_receive == null[ptr[UdpReceiveState]]:
        let storage = unsafe: ptr[char]<-heap.must_alloc_zeroed_bytes(1, 1)
        unsafe: read(buf) = libuv.buf_init(storage, 0)
        return

    let state = unsafe: ptr[UdpReceiveState]<-pending_receive
    var capacity = suggested_size
    let max_bytes = unsafe: read(state).max_bytes
    if max_bytes < capacity:
        capacity = max_bytes

    if capacity == 0:
        capacity = 1

    let storage = unsafe: ptr[char]<-heap.must_alloc_zeroed_bytes(1, capacity)
    unsafe: read(buf) = libuv.buf_init(storage, uint<-capacity)


function udp_receive_callback(handle: ptr[NativeUdpHandle], nread: ptr_int, buf: const_ptr[NativeBuffer], addr: const_ptr[libuv.sockaddr], flags_: uint) -> void:
    let raw_buffer = unsafe: read(buf)

    let state_raw = libuv.handle_get_data(udp_as_handle(handle)) else:
        release_uv_buffer(raw_buffer)
        return

    let socket = unsafe: ptr[UdpSocketState]<-state_raw
    let pending_receive = unsafe: read(socket).receive_state
    if pending_receive == null[ptr[UdpReceiveState]]:
        release_uv_buffer(raw_buffer)
        return

    let state = unsafe: ptr[UdpReceiveState]<-pending_receive
    if nread == 0:
        release_uv_buffer(raw_buffer)
        return

    unsafe:
        read(socket).receive_state = null
        read(state).socket = null

    libuv.udp_recv_stop(handle)

    if nread < 0:
        release_uv_buffer(raw_buffer)
        finish_udp_receive(state, Result[UdpDatagram, Error].failure(error= libuv_error(int<-nread)), int<-nread)
        return

    if (flags_ & uint<-libuv.uv_udp_flags.UV_UDP_PARTIAL) != 0:
        release_uv_buffer(raw_buffer)
        finish_udp_receive(state, Result[UdpDatagram, Error].failure(error= net_error("udp datagram truncated")), -1)
        return

    let source_result = socket_address_from_unknown_sockaddr(addr)
    var payload = bytes.Bytes.copy(unsafe: span[ubyte](data = ptr[ubyte]<-raw_buffer.base, len = ptr_uint<-nread))
    release_uv_buffer(raw_buffer)

    match source_result:
        Result.failure as payload_error:
            let error = payload_error.error
            payload.release()
            finish_udp_receive(state, Result[UdpDatagram, Error].failure(error= error), error.code)
            return
        Result.success as payload_source:
            finish_udp_receive(state, Result[UdpDatagram, Error].success(value= UdpDatagram(data = payload, source = payload_source.value)), 0)
            return


function recv_from_impl(handle: ptr[NativeUdpHandle]?, max_bytes: ptr_uint) -> Task[Result[UdpDatagram, Error]]:
    let state = heap.must_alloc_zeroed[UdpReceiveState](1)
    unsafe:
        read(state).ready = false
        read(state).status_code = 0
        read(state).result = Result[UdpDatagram, Error].success(value= zero[UdpDatagram])
        read(state).result_owned = false
        read(state).waiter_frame = null
        read(state).waiter = noop_waiter
        read(state).waiter_registered = false
        read(state).socket = null
        read(state).max_bytes = max_bytes
        read(state).released = false

    if max_bytes == 0:
        finish_udp_receive(state, Result[UdpDatagram, Error].failure(error= net_error("udp receive requires max_bytes > 0")), -1)
        return udp_receive_task(state)

    let live_handle = handle else:
        finish_udp_receive(state, Result[UdpDatagram, Error].failure(error= net_error("udp socket is released")), -1)
        return udp_receive_task(state)

    if libuv.is_closing(udp_as_handle(live_handle)) != 0:
        finish_udp_receive(state, Result[UdpDatagram, Error].failure(error= net_error("udp socket is closing")), -1)
        return udp_receive_task(state)

    let socket_raw = libuv.handle_get_data(udp_as_handle(live_handle)) else:
        finish_udp_receive(state, Result[UdpDatagram, Error].failure(error= net_error("udp socket state is unavailable")), -1)
        return udp_receive_task(state)

    let socket = unsafe: ptr[UdpSocketState]<-socket_raw
    if unsafe: read(socket).receive_state != null[ptr[UdpReceiveState]]:
        finish_udp_receive(state, Result[UdpDatagram, Error].failure(error= net_error("udp socket already has a pending receive")), -1)
        return udp_receive_task(state)

    unsafe:
        read(state).socket = socket
        read(socket).receive_state = state

    let start_status = libuv.udp_recv_start(live_handle, udp_receive_alloc_callback, udp_receive_callback)
    if start_status != 0:
        unsafe:
            read(socket).receive_state = null
            read(state).socket = null
        finish_udp_receive(state, Result[UdpDatagram, Error].failure(error= libuv_error(start_status)), start_status)
        return udp_receive_task(state)

    return udp_receive_task(state)


async function recv_impl(handle: ptr[NativeUdpHandle]?, max_bytes: ptr_uint) -> Result[bytes.Bytes, Error]:
    let received = await recv_from_impl(handle, max_bytes)
    match received:
        Result.failure as payload:
            return Result[bytes.Bytes, Error].failure(error= payload.error)
        Result.success as payload:
            var datagram = payload.value
            let data = datagram.data
            datagram.data = bytes.Bytes.empty()
            datagram.source.release()
            return Result[bytes.Bytes, Error].success(value= data)


function udp_bind_on_impl(runtime: aio.Runtime, address: SocketAddress) -> Result[UdpSocket, Error]:
    let storage = address.storage else:
        return Result[UdpSocket, Error].failure(error= invalid_address_error("socket address is released"))

    let handle = alloc_udp_handle()
    let init_status = libuv.udp_init(aio_backend.runtime_loop(runtime), handle)
    if init_status != 0:
        unsafe: heap.release_bytes(ptr[void]<-handle)
        return Result[UdpSocket, Error].failure(error= libuv_error(init_status))

    let bind_status = libuv.udp_bind(handle, sockaddr_storage_as_sockaddr(storage), 0)
    if bind_status != 0:
        close_raw_udp_handle(handle)
        return Result[UdpSocket, Error].failure(error= libuv_error(bind_status))

    return Result[UdpSocket, Error].success(value= attach_udp_socket(handle))


function finish_resolve(state: ptr[ResolveState], result_value: Result[SocketAddress, Error], status_code: int) -> void:
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


function finish_resolve_all(state: ptr[ResolveAllState], result_value: Result[vec.Vec[SocketAddress], Error], status_code: int) -> void:
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
        finish_resolve(state, Result[SocketAddress, Error].failure(error= libuv_error(status_code)), status_code)
        return

    if maybe_result == null[ptr[libuv.addrinfo]]:
        finish_resolve(state, Result[SocketAddress, Error].failure(error= invalid_address_error("resolver returned no addresses")), -1)
        return

    let ai = unsafe: read(result_ptr)
    let address_result = socket_address_from_sockaddr(ai.ai_addr, ptr_uint<-ai.ai_addrlen)
    libuv.freeaddrinfo(result_ptr)
    finish_resolve(state, address_result, 0)


function resolve_all_callback(req: ptr[libuv.uv_getaddrinfo_t], status_code: int, result_ptr: ptr[libuv.addrinfo]) -> void:
    let maybe_result = unsafe: ptr[libuv.addrinfo]?<-result_ptr

    let state_raw = libuv.req_get_data(req_as_base(req)) else:
        if maybe_result != null[ptr[libuv.addrinfo]]:
            libuv.freeaddrinfo(result_ptr)
        return

    let state = unsafe: ptr[ResolveAllState]<-state_raw
    unsafe: read(state).req = null

    if status_code != 0:
        if maybe_result != null[ptr[libuv.addrinfo]]:
            libuv.freeaddrinfo(result_ptr)
        finish_resolve_all(state, Result[vec.Vec[SocketAddress], Error].failure(error= libuv_error(status_code)), status_code)
        return

    if maybe_result == null[ptr[libuv.addrinfo]]:
        finish_resolve_all(state, Result[vec.Vec[SocketAddress], Error].failure(error= invalid_address_error("resolver returned no addresses")), -1)
        return

    var addresses = vec.Vec[SocketAddress].create()
    var current: ptr[libuv.addrinfo]? = maybe_result
    while true:
        if current == null:
            break

        let live_current = unsafe: ptr[libuv.addrinfo]<-current
        let ai = unsafe: read(live_current)
        let address_result = socket_address_from_sockaddr(ai.ai_addr, ptr_uint<-ai.ai_addrlen)
        match address_result:
            Result.failure as payload:
                libuv.freeaddrinfo(result_ptr)
                release_socket_addresses(ref_of(addresses))
                finish_resolve_all(state, Result[vec.Vec[SocketAddress], Error].failure(error= payload.error), -1)
                return
            Result.success as payload:
                addresses.push(payload.value)

        current = ai.ai_next

    libuv.freeaddrinfo(result_ptr)

    if addresses.len == 0:
        addresses.release()
        finish_resolve_all(state, Result[vec.Vec[SocketAddress], Error].failure(error= invalid_address_error("resolver returned no addresses")), -1)
        return

    finish_resolve_all(state, Result[vec.Vec[SocketAddress], Error].success(value= addresses), 0)


function resolve_on_impl(runtime: aio.Runtime, node: str, service: str) -> Task[Result[SocketAddress, Error]]:
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
        read(state).result = Result[SocketAddress, Error].success(value= zero[SocketAddress])
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
        finish_resolve(state, Result[SocketAddress, Error].failure(error= libuv_error(queue_status)), queue_status)

    return resolve_task(state)


function resolve_all_on_impl(runtime: aio.Runtime, node: str, service: str) -> Task[Result[vec.Vec[SocketAddress], Error]]:
    let loop = aio_backend.runtime_loop(runtime)
    let state = heap.must_alloc_zeroed[ResolveAllState](1)

    let req_size = libuv.req_size(libuv.uv_req_type.UV_GETADDRINFO)
    let req = unsafe: ptr[libuv.uv_getaddrinfo_t]<-heap.must_alloc_zeroed_bytes(1, req_size)
    var storage = arena.create(node.len + service.len + 2)
    let node_cstr = storage.to_cstr(node)
    let service_cstr = storage.to_cstr(service)

    unsafe:
        read(state).ready = false
        read(state).status_code = 0
        read(state).result = Result[vec.Vec[SocketAddress], Error].success(value= vec.Vec[SocketAddress].create())
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

    let queue_status = libuv.getaddrinfo(loop, req, resolve_all_callback, unsafe: read(state).node, unsafe: read(state).service, null[const_ptr[libuv.addrinfo]])
    if queue_status != 0:
        unsafe:
            heap.release(req)
            read(state).req = null
        finish_resolve_all(state, Result[vec.Vec[SocketAddress], Error].failure(error= libuv_error(queue_status)), queue_status)

    return resolve_all_task(state)


function connect_on_impl(runtime: aio.Runtime, address: SocketAddress) -> Task[Result[TcpStream, Error]]:
    let state = heap.must_alloc_zeroed[ConnectState](1)
    unsafe:
        read(state).ready = false
        read(state).status_code = 0
        read(state).result = Result[TcpStream, Error].success(value= zero[TcpStream])
        read(state).result_owned = false
        read(state).waiter_frame = null
        read(state).waiter = noop_waiter
        read(state).waiter_registered = false
        read(state).req = null
        read(state).handle = null
        read(state).destination = zero[SocketAddress]
        read(state).destination_owned = false
        read(state).released = false

    match duplicate_socket_address(address):
        Result.failure as payload:
            let error = payload.error
            finish_connect(state, Result[TcpStream, Error].failure(error= error), error.code)
            return connect_task(state)
        Result.success as payload:
            unsafe:
                read(state).destination = payload.value
                read(state).destination_owned = true

    let handle = alloc_tcp_handle()
    let init_status = libuv.tcp_init(aio_backend.runtime_loop(runtime), handle)
    if init_status != 0:
        unsafe: heap.release_bytes(ptr[void]<-handle)
        finish_connect(state, Result[TcpStream, Error].failure(error= libuv_error(init_status)), init_status)
        return connect_task(state)

    let req = alloc_connect_request()
    unsafe:
        read(state).req = req
        read(state).handle = handle
        libuv.req_set_data(connect_req_as_base(req), ptr[void]<-state)

    let destination_storage = unsafe: read(state).destination.storage else:
        unsafe:
            heap.release_bytes(ptr[void]<-req)
            read(state).req = null
            read(state).handle = null
        close_tcp_handle(handle)
        finish_connect(state, Result[TcpStream, Error].failure(error= invalid_address_error("socket address is released")), -1)
        return connect_task(state)

    let queue_status = libuv.tcp_connect(req, handle, sockaddr_storage_as_sockaddr(destination_storage), connect_callback)
    if queue_status != 0:
        unsafe:
            heap.release_bytes(ptr[void]<-req)
            read(state).req = null
            read(state).handle = null
        close_tcp_handle(handle)
        finish_connect(state, Result[TcpStream, Error].failure(error= libuv_error(queue_status)), queue_status)

    return connect_task(state)


function listen_on_impl(runtime: aio.Runtime, address: SocketAddress, backlog: int) -> Result[TcpListener, Error]:
    let storage = address.storage else:
        return Result[TcpListener, Error].failure(error= invalid_address_error("socket address is released"))

    let handle = alloc_tcp_handle()
    let init_status = libuv.tcp_init(aio_backend.runtime_loop(runtime), handle)
    if init_status != 0:
        unsafe: heap.release_bytes(ptr[void]<-handle)
        return Result[TcpListener, Error].failure(error= libuv_error(init_status))

    let bind_status = libuv.tcp_bind(handle, sockaddr_storage_as_sockaddr(storage), 0)
    if bind_status != 0:
        close_tcp_handle(handle)
        return Result[TcpListener, Error].failure(error= libuv_error(bind_status))

    let listen_status = libuv.listen(tcp_as_stream(handle), backlog, listener_connection_callback)
    if listen_status != 0:
        close_tcp_handle(handle)
        return Result[TcpListener, Error].failure(error= libuv_error(listen_status))

    let listener_state = heap.must_alloc_zeroed[ListenerState](1)
    unsafe:
        read(listener_state).handle = handle
        read(listener_state).pending_connections = 0
        read(listener_state).pending_error_code = 0
        read(listener_state).accept_state = null
        libuv.handle_set_data(tcp_as_handle(handle), ptr[void]<-listener_state)

    return Result[TcpListener, Error].success(value= TcpListener(handle = handle))


extending Error:
    public mutable function release() -> void:
        this.message.release()


extending SocketAddress:
    public mutable function release() -> void:
        heap.release(this.storage)
        this.storage = null
        this.len = 0


    public function copy() -> Result[SocketAddress, Error]:
        let storage = this.storage else:
            return Result[SocketAddress, Error].failure(error= invalid_address_error("socket address is released"))

        return socket_address_from_sockaddr(sockaddr_storage_as_sockaddr(storage), this.len)


    public function equal(other: SocketAddress) -> bool:
        if this.len != other.len:
            return false

        let left = this.storage else:
            return false

        let right = other.storage else:
            return false

        return cstring.compare_bytes(
                unsafe: const_ptr[void]<-left,
                unsafe: const_ptr[void]<-right,
                this.len,
            ) == 0


    public function host() -> Result[string.String, Error]:
        return socket_address_to_string_result(this)


extending UdpDatagram:
    public mutable function release() -> void:
        this.data.release()
        this.source.release()


extending TcpStream:
    public mutable function release() -> void:
        let handle = this.handle else:
            return

        this.handle = null
        close_tcp_stream_handle(handle)


    public function local_address() -> Result[SocketAddress, Error]:
        return tcp_socket_address_from_getsockname(this.handle)


    public function peer_address() -> Result[SocketAddress, Error]:
        return tcp_socket_address_from_getpeername(this.handle)


    public function socket_fd() -> Result[int, Error]:
        return tcp_socket_fd(this.handle)


    public function write_bytes(content: span[ubyte]) -> Task[Result[ptr_uint, Error]]:
        return write_on_impl(this.handle, content)


    public function read_once(max_bytes: ptr_uint) -> Task[Result[bytes.Bytes, Error]]:
        return read_once_impl(this.handle, max_bytes)


    public function read_exactly(byte_count: ptr_uint) -> Task[Result[bytes.Bytes, Error]]:
        return read_exactly_impl(this.handle, byte_count)


    public function shutdown() -> Task[Result[bool, Error]]:
        return shutdown_impl(this.handle)


extending TcpListener:
    public mutable function release() -> void:
        let handle = this.handle else:
            return

        let state_raw = libuv.handle_get_data(tcp_as_handle(handle))
        if state_raw != null[ptr[void]]:
            let listener = unsafe: ptr[ListenerState]<-state_raw
            let pending_accept = unsafe: read(listener).accept_state
            if pending_accept != null[ptr[AcceptState]]:
                unsafe: read(listener).accept_state = null
                finish_accept(unsafe: ptr[AcceptState]<-pending_accept, Result[TcpStream, Error].failure(error= net_error("listener released")), -1)

        this.handle = null
        if libuv.is_closing(tcp_as_handle(handle)) == 0:
            libuv.close(tcp_as_handle(handle), listener_close_callback)


    public function accept() -> Task[Result[TcpStream, Error]]:
        return accept_impl(this.handle)


    public function local_address() -> Result[SocketAddress, Error]:
        return tcp_socket_address_from_getsockname(this.handle)


extending UdpSocket:
    public mutable function release() -> void:
        let handle = this.handle else:
            return

        this.handle = null
        close_udp_socket_handle(handle)


    public function local_address() -> Result[SocketAddress, Error]:
        return udp_socket_address_from_getsockname(this.handle)


    public function peer_address() -> Result[SocketAddress, Error]:
        return udp_socket_address_from_getpeername(this.handle)


    public function connect(destination: SocketAddress) -> Result[bool, Error]:
        return udp_connect_impl(this.handle, destination)


    public function send(content: span[ubyte]) -> Task[Result[ptr_uint, Error]]:
        return udp_send_connected_impl(this.handle, content)


    public function send_to(content: span[ubyte], destination: SocketAddress) -> Task[Result[ptr_uint, Error]]:
        return udp_send_to_impl(this.handle, content, destination)


    public function recv(max_bytes: ptr_uint) -> Task[Result[bytes.Bytes, Error]]:
        return recv_impl(this.handle, max_bytes)


    public function recv_from(max_bytes: ptr_uint) -> Task[Result[UdpDatagram, Error]]:
        return recv_from_impl(this.handle, max_bytes)


public function ipv4(ip: str, port: int) -> Result[SocketAddress, Error]:
    var raw = zero[libuv.sockaddr_in]
    let status_code = libuv.ip4_addr(ip, port, raw)
    if status_code != 0:
        return Result[SocketAddress, Error].failure(error= libuv_error(status_code))

    return socket_address_from_sockaddr(sockaddr_storage_as_sockaddr(unsafe: ptr[NativeSocketStorage]<-ptr_of(raw)), ptr_uint<-size_of(libuv.sockaddr_in))


public function ipv6(ip: str, port: int) -> Result[SocketAddress, Error]:
    var raw = zero[libuv.sockaddr_in6]
    let status_code = libuv.ip6_addr(ip, port, raw)
    if status_code != 0:
        return Result[SocketAddress, Error].failure(error= libuv_error(status_code))

    return socket_address_from_sockaddr(sockaddr_storage_as_sockaddr(unsafe: ptr[NativeSocketStorage]<-ptr_of(raw)), ptr_uint<-size_of(libuv.sockaddr_in6))


public function resolve_first_on(runtime: aio.Runtime, node: str, service: str) -> Task[Result[SocketAddress, Error]]:
    return resolve_on_impl(runtime, node, service)


public function resolve_first(node: str, service: str) -> Task[Result[SocketAddress, Error]]:
    return resolve_first_on(aio.current_runtime(), node, service)


public function resolve_all_on(runtime: aio.Runtime, node: str, service: str) -> Task[Result[vec.Vec[SocketAddress], Error]]:
    return resolve_all_on_impl(runtime, node, service)


public function resolve_all(node: str, service: str) -> Task[Result[vec.Vec[SocketAddress], Error]]:
    return resolve_all_on(aio.current_runtime(), node, service)


public function connect_on(runtime: aio.Runtime, address: SocketAddress) -> Task[Result[TcpStream, Error]]:
    return connect_on_impl(runtime, address)


public function connect(address: SocketAddress) -> Task[Result[TcpStream, Error]]:
    return connect_on(aio.current_runtime(), address)


public function listen_on(runtime: aio.Runtime, address: SocketAddress, backlog: int) -> Result[TcpListener, Error]:
    return listen_on_impl(runtime, address, backlog)


public function listen(address: SocketAddress, backlog: int) -> Result[TcpListener, Error]:
    return listen_on(aio.current_runtime(), address, backlog)


public function udp_bind_on(runtime: aio.Runtime, address: SocketAddress) -> Result[UdpSocket, Error]:
    return udp_bind_on_impl(runtime, address)


public function udp_bind(address: SocketAddress) -> Result[UdpSocket, Error]:
    return udp_bind_on(aio.current_runtime(), address)

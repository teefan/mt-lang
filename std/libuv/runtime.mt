module std.libuv.runtime

import std.c.libuv as c
import std.c.libuv_runtime as helper
import std.c.libuv_system as sys
import std.libuv as uv
import std.mem.heap as heap
import std.status as status
import std.str as text

public struct Loop:
    raw: ptr[uv.uv_loop_t]
    storage: ptr[void]?

public struct Handle[T]:
    raw: ptr[T]
    storage: ptr[void]?

public struct Request[T]:
    raw: ptr[T]
    storage: ptr[void]?

struct IPv4Address:
    raw: ptr[sys.sockaddr_in]
    storage: ptr[void]?


foreign function ip_4_addr_str(ip: str as cstr, port: int, addr: ptr[sys.sockaddr_in]) -> int = c.uv_ip4_addr
foreign function fs_mkstemp_str(loop: ptr[uv.uv_loop_t], request: ptr[uv.uv_fs_t], tpl: str as cstr, callback: fn(arg0: ptr[uv.uv_fs_t]) -> void) -> int = c.uv_fs_mkstemp
foreign function fs_open_str(loop: ptr[uv.uv_loop_t], request: ptr[uv.uv_fs_t], path: str as cstr, flag_bits: int, mode: int, callback: fn(arg0: ptr[uv.uv_fs_t]) -> void) -> int = c.uv_fs_open
foreign function fs_unlink_str(loop: ptr[uv.uv_loop_t], request: ptr[uv.uv_fs_t], path: str as cstr, callback: fn(arg0: ptr[uv.uv_fs_t]) -> void) -> int = c.uv_fs_unlink


public function noop_close(handle: ptr[uv.uv_handle_t]) -> void:
    return


public function succeeded(status: int) -> bool:
    return status >= 0


public function failed(status: int) -> bool:
    return status < 0


function alloc_handle[T](kind: c.uv_handle_type) -> Handle[T]:
    let storage = heap.must_alloc_zeroed_bytes(1, uv.handle_size(kind))
    return unsafe: Handle[T](raw = ptr[T]<-storage, storage = storage)


function alloc_request[T](kind: c.uv_req_type) -> Request[T]:
    let storage = heap.must_alloc_zeroed_bytes(1, uv.req_size(kind))
    return unsafe: Request[T](raw = ptr[T]<-storage, storage = storage)


function release_ipv4_address(address: ref[IPv4Address]) -> void:
    heap.release_bytes(address.storage)
    address.storage = null
    return


function create_ipv4_address(ip: str, port: int) -> status.Status[IPv4Address, int]:
    let storage = heap.must_alloc_zeroed_bytes(1, helper.mt_libuv_sockaddr_in_size())
    unsafe:
        let raw_addr = ptr[sys.sockaddr_in]<-storage
        let code = ip_4_addr_str(ip, port, raw_addr)
        if failed(code):
            heap.release_bytes(storage)
            return status.Status[IPv4Address, int].err(error= code)
        return status.Status[IPv4Address, int].ok(value= IPv4Address(raw = raw_addr, storage = storage))


function ipv4_sockaddr(address: IPv4Address) -> ptr[sys.sockaddr]:
    return unsafe: ptr[sys.sockaddr]<-address.raw


function ipv4_const_sockaddr(address: IPv4Address) -> const_ptr[sys.sockaddr]:
    return unsafe: const_ptr[sys.sockaddr]<-address.raw


function byte_buffer(data: span[ubyte]) -> uv.uv_buf_t:
    return unsafe: uv.buf_init(ptr[char]<-data.data, uint<-data.len)


public function create_loop() -> status.Status[Loop, int]:
    let storage = heap.must_alloc_zeroed_bytes(1, uv.loop_size())
    unsafe:
        let raw_loop = ptr[uv.uv_loop_t]<-storage
        let code = uv.loop_init(raw_loop)
        if failed(code):
            heap.release_bytes(storage)
            return status.Status[Loop, int].err(error= code)
        return status.Status[Loop, int].ok(value= Loop(raw = raw_loop, storage = storage))


public function loop_ptr(loop: Loop) -> ptr[uv.uv_loop_t]:
    return loop.raw


public function loop_run(loop: Loop, mode: uv.uv_run_mode) -> int:
    return uv.run(loop.raw, mode)


public function loop_run_default(loop: Loop) -> int:
    return uv.run(loop.raw, c.uv_run_mode.UV_RUN_DEFAULT)


public function loop_run_once(loop: Loop) -> int:
    return uv.run(loop.raw, c.uv_run_mode.UV_RUN_ONCE)


public function loop_run_nowait(loop: Loop) -> int:
    return uv.run(loop.raw, c.uv_run_mode.UV_RUN_NOWAIT)


public function loop_stop(loop: Loop) -> void:
    uv.stop(loop.raw)
    return


public function loop_release(loop: ref[Loop]) -> int:
    let status = uv.loop_close(loop.raw)
    if failed(status):
        return status

    heap.release_bytes(loop.storage)
    loop.storage = null
    return status


public function handle_ptr[T](handle: Handle[T]) -> ptr[T]:
    return handle.raw


public function handle_release[T](handle: ref[Handle[T]]) -> void:
    heap.release_bytes(handle.storage)
    handle.storage = null
    return


public function handle_close[T](handle: Handle[T], close_cb: fn(arg0: ptr[uv.uv_handle_t]) -> void) -> void:
    unsafe: uv.close(ptr[uv.uv_handle_t]<-handle.raw, close_cb)
    return


public function close_raw_handle[T](handle: ptr[T], close_cb: fn(arg0: ptr[uv.uv_handle_t]) -> void) -> void:
    unsafe: uv.close(ptr[uv.uv_handle_t]<-handle, close_cb)
    return


public function handle_close_noop[T](handle: Handle[T]) -> void:
    handle_close(handle, noop_close)
    return


public function close_raw_handle_noop[T](handle: ptr[T]) -> void:
    close_raw_handle(handle, noop_close)
    return


public function request_ptr[T](request: Request[T]) -> ptr[T]:
    return request.raw


public function request_release[T](request: ref[Request[T]]) -> void:
    heap.release_bytes(request.storage)
    request.storage = null
    return


public function create_timer(loop: Loop) -> status.Status[Handle[uv.uv_timer_t], int]:
    var timer = alloc_handle[uv.uv_timer_t](c.uv_handle_type.UV_TIMER)
    let code = uv.timer_init(loop.raw, timer.raw)
    if failed(code):
        handle_release[uv.uv_timer_t](ref_of(timer))
        return status.Status[Handle[uv.uv_timer_t], int].err(error= code)
    return status.Status[Handle[uv.uv_timer_t], int].ok(value= timer)


public function timer_start_once(timer: Handle[uv.uv_timer_t], timeout: ptr_uint, callback: fn(arg0: ptr[uv.uv_timer_t]) -> void) -> int:
    return uv.timer_start(timer.raw, callback, timeout, 0)


public function timer_start_repeat(timer: Handle[uv.uv_timer_t], timeout: ptr_uint, repeat: ptr_uint, callback: fn(arg0: ptr[uv.uv_timer_t]) -> void) -> int:
    return uv.timer_start(timer.raw, callback, timeout, repeat)


public function timer_stop(timer: Handle[uv.uv_timer_t]) -> int:
    return uv.timer_stop(timer.raw)


public function create_work_request() -> Request[uv.uv_work_t]:
    return alloc_request[uv.uv_work_t](c.uv_req_type.UV_WORK)


public function queue_work(loop: Loop, request: Request[uv.uv_work_t], work_cb: fn(arg0: ptr[uv.uv_work_t]) -> void, after_work_cb: fn(arg0: ptr[uv.uv_work_t], arg1: int) -> void) -> int:
    return uv.queue_work(loop.raw, request.raw, work_cb, after_work_cb)


public function create_tcp(loop: Loop) -> status.Status[Handle[uv.uv_tcp_t], int]:
    var tcp = alloc_handle[uv.uv_tcp_t](c.uv_handle_type.UV_TCP)
    let code = uv.tcp_init(loop.raw, tcp.raw)
    if failed(code):
        handle_release[uv.uv_tcp_t](ref_of(tcp))
        return status.Status[Handle[uv.uv_tcp_t], int].err(error= code)
    return status.Status[Handle[uv.uv_tcp_t], int].ok(value= tcp)


public function create_connect_request() -> Request[uv.uv_connect_t]:
    return alloc_request[uv.uv_connect_t](c.uv_req_type.UV_CONNECT)


public function tcp_stream(tcp: Handle[uv.uv_tcp_t]) -> ptr[uv.uv_stream_t]:
    return unsafe: ptr[uv.uv_stream_t]<-tcp.raw


public function tcp_listen(tcp: Handle[uv.uv_tcp_t], backlog: int, callback: fn(arg0: ptr[uv.uv_stream_t], arg1: int) -> void) -> int:
    return uv.listen(tcp_stream(tcp), backlog, callback)


public function tcp_accept(server: Handle[uv.uv_tcp_t], client: Handle[uv.uv_tcp_t]) -> int:
    return uv.accept(tcp_stream(server), tcp_stream(client))


public function tcp_bind_ipv4(tcp: Handle[uv.uv_tcp_t], ip: str, port: int, flag_bits: uint) -> int:
    let address = create_ipv4_address(ip, port)
    match address:
        status.Status.err as payload:
            return payload.error
        status.Status.ok as payload:
            var ipv4 = payload.value
            defer release_ipv4_address(ref_of(ipv4))
            let code = uv.tcp_bind(tcp.raw, ipv4_const_sockaddr(ipv4), flag_bits)
            return code
    return -1


public function tcp_local_port(tcp: Handle[uv.uv_tcp_t]) -> status.Status[int, int]:
    let storage = heap.must_alloc_zeroed_bytes(1, helper.mt_libuv_sockaddr_in_size())
    unsafe:
        let raw_addr = ptr[sys.sockaddr_in]<-storage
        var name_len: int = int<-helper.mt_libuv_sockaddr_in_size()
        let code = uv.tcp_getsockname(tcp.raw, ptr[sys.sockaddr]<-raw_addr, ptr_of(name_len))
        if failed(code):
            heap.release_bytes(storage)
            return status.Status[int, int].err(error= code)

        let port = helper.mt_libuv_sockaddr_in_port(raw_addr)
        heap.release_bytes(storage)
        return status.Status[int, int].ok(value= port)


public function tcp_connect_ipv4(request: Request[uv.uv_connect_t], tcp: Handle[uv.uv_tcp_t], ip: str, port: int, callback: fn(arg0: ptr[uv.uv_connect_t], arg1: int) -> void) -> int:
    let address = create_ipv4_address(ip, port)
    match address:
        status.Status.err as payload:
            return payload.error
        status.Status.ok as payload:
            var ipv4 = payload.value
            defer release_ipv4_address(ref_of(ipv4))
            let code = uv.tcp_connect(request.raw, tcp.raw, ipv4_const_sockaddr(ipv4), callback)
            return code
    return -1


public function create_fs_request() -> Request[uv.uv_fs_t]:
    return alloc_request[uv.uv_fs_t](c.uv_req_type.UV_FS)


public function fs_cleanup(request: Request[uv.uv_fs_t]) -> void:
    uv.fs_req_cleanup(request.raw)
    return


public function fs_result(request: Request[uv.uv_fs_t]) -> ptr_int:
    return uv.fs_get_result(request.raw)


public function fs_path(request: Request[uv.uv_fs_t]) -> str:
    return text.cstr_as_str(uv.fs_get_path(request.raw))


public function fs_mkstemp(loop: Loop, request: Request[uv.uv_fs_t], tpl: str, callback: fn(arg0: ptr[uv.uv_fs_t]) -> void) -> int:
    return fs_mkstemp_str(loop.raw, request.raw, tpl, callback)


public function fs_open(loop: Loop, request: Request[uv.uv_fs_t], path: str, flag_bits: int, mode: int, callback: fn(arg0: ptr[uv.uv_fs_t]) -> void) -> int:
    return fs_open_str(loop.raw, request.raw, path, flag_bits, mode, callback)


public function fs_write(loop: Loop, request: Request[uv.uv_fs_t], file: int, data: span[ubyte], offset: ptr_int, callback: fn(arg0: ptr[uv.uv_fs_t]) -> void) -> int:
    var buffer = byte_buffer(data)
    return uv.fs_write(loop.raw, request.raw, file, ptr_of(buffer), 1, offset, callback)


public function fs_read(loop: Loop, request: Request[uv.uv_fs_t], file: int, data: span[ubyte], offset: ptr_int, callback: fn(arg0: ptr[uv.uv_fs_t]) -> void) -> int:
    var buffer = byte_buffer(data)
    return uv.fs_read(loop.raw, request.raw, file, ptr_of(buffer), 1, offset, callback)


public function fs_close(loop: Loop, request: Request[uv.uv_fs_t], file: int, callback: fn(arg0: ptr[uv.uv_fs_t]) -> void) -> int:
    return uv.fs_close(loop.raw, request.raw, file, callback)


public function fs_unlink(loop: Loop, request: Request[uv.uv_fs_t], path: str, callback: fn(arg0: ptr[uv.uv_fs_t]) -> void) -> int:
    return fs_unlink_str(loop.raw, request.raw, path, callback)

module std.libuv.runtime

import std.c.libuv as c
import std.c.libuv_runtime as helper
import std.c.libuv_system as sys
import std.libuv as uv
import std.mem.arena as arena
import std.mem.heap as heap
import std.str as text

pub struct Loop:
    raw: ptr[uv.uv_loop_t]
    storage: ptr[void]?

pub struct Handle[T]:
    raw: ptr[T]
    storage: ptr[void]?

pub struct Request[T]:
    raw: ptr[T]
    storage: ptr[void]?

struct IPv4Address:
    raw: ptr[sys.sockaddr_in]
    storage: ptr[void]?

pub def noop_close(handle: ptr[uv.uv_handle_t]) -> void:
    return

pub def succeeded(status: i32) -> bool:
    return status >= 0

pub def failed(status: i32) -> bool:
    return status < 0

def alloc_handle[T](kind: c.uv_handle_type) -> Handle[T]:
    let storage = heap.must_alloc_zeroed_bytes(1, uv.handle_size(kind))
    unsafe:
        return Handle[T](raw = ptr[T]<-storage, storage = storage)

def alloc_request[T](kind: c.uv_req_type) -> Request[T]:
    let storage = heap.must_alloc_zeroed_bytes(1, uv.req_size(kind))
    unsafe:
        return Request[T](raw = ptr[T]<-storage, storage = storage)

def release_ipv4_address(address: ref[IPv4Address]) -> void:
    heap.release_bytes(address.storage)
    address.storage = null
    return

def create_ipv4_address(ip: str, port: i32, scratch: ref[arena.Arena]) -> Result[IPv4Address, i32]:
    let storage = heap.must_alloc_zeroed_bytes(1, helper.mt_libuv_sockaddr_in_size())
    unsafe:
        let raw_addr = ptr[sys.sockaddr_in]<-storage
        let status = uv.ip_4_addr(scratch.to_cstr(ip), port, raw_addr)
        if failed(status):
            heap.release_bytes(storage)
            return err(status)
        return ok(IPv4Address(raw = raw_addr, storage = storage))

def ipv4_sockaddr(address: IPv4Address) -> ptr[sys.sockaddr]:
    unsafe:
        return ptr[sys.sockaddr]<-address.raw

def ipv4_const_sockaddr(address: IPv4Address) -> const_ptr[sys.sockaddr]:
    unsafe:
        return const_ptr[sys.sockaddr]<-address.raw

def byte_buffer(data: span[u8]) -> uv.uv_buf_t:
    unsafe:
        return uv.buf_init(ptr[char]<-data.data, u32<-data.len)

pub def create_loop() -> Result[Loop, i32]:
    let storage = heap.must_alloc_zeroed_bytes(1, uv.loop_size())
    unsafe:
        let raw_loop = ptr[uv.uv_loop_t]<-storage
        let status = uv.loop_init(raw_loop)
        if failed(status):
            heap.release_bytes(storage)
            return err(status)
        return ok(Loop(raw = raw_loop, storage = storage))

pub def loop_ptr(loop: Loop) -> ptr[uv.uv_loop_t]:
    return loop.raw

pub def loop_run(loop: Loop, mode: uv.uv_run_mode) -> i32:
    return uv.run(loop.raw, mode)

pub def loop_run_default(loop: Loop) -> i32:
    return uv.run(loop.raw, c.uv_run_mode.UV_RUN_DEFAULT)

pub def loop_run_once(loop: Loop) -> i32:
    return uv.run(loop.raw, c.uv_run_mode.UV_RUN_ONCE)

pub def loop_run_nowait(loop: Loop) -> i32:
    return uv.run(loop.raw, c.uv_run_mode.UV_RUN_NOWAIT)

pub def loop_stop(loop: Loop) -> void:
    uv.stop(loop.raw)
    return

pub def loop_release(loop: ref[Loop]) -> i32:
    let status = uv.loop_close(loop.raw)
    if failed(status):
        return status

    heap.release_bytes(loop.storage)
    loop.storage = null
    return status

pub def handle_ptr[T](handle: Handle[T]) -> ptr[T]:
    return handle.raw

pub def handle_release[T](handle: ref[Handle[T]]) -> void:
    heap.release_bytes(handle.storage)
    handle.storage = null
    return

pub def handle_close[T](handle: Handle[T], close_cb: fn(arg0: ptr[uv.uv_handle_t]) -> void) -> void:
    unsafe:
        uv.close(ptr[uv.uv_handle_t]<-handle.raw, close_cb)
    return

pub def close_raw_handle[T](handle: ptr[T], close_cb: fn(arg0: ptr[uv.uv_handle_t]) -> void) -> void:
    unsafe:
        uv.close(ptr[uv.uv_handle_t]<-handle, close_cb)
    return

pub def handle_close_noop[T](handle: Handle[T]) -> void:
    handle_close(handle, noop_close)
    return

pub def close_raw_handle_noop[T](handle: ptr[T]) -> void:
    close_raw_handle(handle, noop_close)
    return

pub def request_ptr[T](request: Request[T]) -> ptr[T]:
    return request.raw

pub def request_release[T](request: ref[Request[T]]) -> void:
    heap.release_bytes(request.storage)
    request.storage = null
    return

pub def create_timer(loop: Loop) -> Result[Handle[uv.uv_timer_t], i32]:
    var timer = alloc_handle[uv.uv_timer_t](c.uv_handle_type.UV_TIMER)
    let status = uv.timer_init(loop.raw, timer.raw)
    if failed(status):
        handle_release[uv.uv_timer_t](ref_of(timer))
        return err(status)
    return ok(timer)

pub def timer_start_once(timer: Handle[uv.uv_timer_t], timeout: usize, callback: fn(arg0: ptr[uv.uv_timer_t]) -> void) -> i32:
    return uv.timer_start(timer.raw, callback, timeout, 0)

pub def timer_start_repeat(timer: Handle[uv.uv_timer_t], timeout: usize, repeat: usize, callback: fn(arg0: ptr[uv.uv_timer_t]) -> void) -> i32:
    return uv.timer_start(timer.raw, callback, timeout, repeat)

pub def timer_stop(timer: Handle[uv.uv_timer_t]) -> i32:
    return uv.timer_stop(timer.raw)

pub def create_work_request() -> Request[uv.uv_work_t]:
    return alloc_request[uv.uv_work_t](c.uv_req_type.UV_WORK)

pub def queue_work(loop: Loop, request: Request[uv.uv_work_t], work_cb: fn(arg0: ptr[uv.uv_work_t]) -> void, after_work_cb: fn(arg0: ptr[uv.uv_work_t], arg1: i32) -> void) -> i32:
    return uv.queue_work(loop.raw, request.raw, work_cb, after_work_cb)

pub def create_tcp(loop: Loop) -> Result[Handle[uv.uv_tcp_t], i32]:
    var tcp = alloc_handle[uv.uv_tcp_t](c.uv_handle_type.UV_TCP)
    let status = uv.tcp_init(loop.raw, tcp.raw)
    if failed(status):
        handle_release[uv.uv_tcp_t](ref_of(tcp))
        return err(status)
    return ok(tcp)

pub def create_connect_request() -> Request[uv.uv_connect_t]:
    return alloc_request[uv.uv_connect_t](c.uv_req_type.UV_CONNECT)

pub def tcp_stream(tcp: Handle[uv.uv_tcp_t]) -> ptr[uv.uv_stream_t]:
    unsafe:
        return ptr[uv.uv_stream_t]<-tcp.raw

pub def tcp_listen(tcp: Handle[uv.uv_tcp_t], backlog: i32, callback: fn(arg0: ptr[uv.uv_stream_t], arg1: i32) -> void) -> i32:
    return uv.listen(tcp_stream(tcp), backlog, callback)

pub def tcp_accept(server: Handle[uv.uv_tcp_t], client: Handle[uv.uv_tcp_t]) -> i32:
    return uv.accept(tcp_stream(server), tcp_stream(client))

pub def tcp_bind_ipv4(tcp: Handle[uv.uv_tcp_t], ip: str, port: i32, flag_bits: u32, scratch: ref[arena.Arena]) -> i32:
    let address = create_ipv4_address(ip, port, scratch)
    if not address.is_ok:
        return address.error

    var ipv4 = address.value
    defer release_ipv4_address(ref_of(ipv4))
    let status = uv.tcp_bind(tcp.raw, ipv4_const_sockaddr(ipv4), flag_bits)
    return status

pub def tcp_local_port(tcp: Handle[uv.uv_tcp_t]) -> Result[i32, i32]:
    let storage = heap.must_alloc_zeroed_bytes(1, helper.mt_libuv_sockaddr_in_size())
    unsafe:
        let raw_addr = ptr[sys.sockaddr_in]<-storage
        var name_len: i32 = i32<-helper.mt_libuv_sockaddr_in_size()
        let status = uv.tcp_getsockname(tcp.raw, ptr[sys.sockaddr]<-raw_addr, ptr_of(ref_of(name_len)))
        if failed(status):
            heap.release_bytes(storage)
            return err(status)

        let port = helper.mt_libuv_sockaddr_in_port(raw_addr)
        heap.release_bytes(storage)
        return ok(port)

pub def tcp_connect_ipv4(request: Request[uv.uv_connect_t], tcp: Handle[uv.uv_tcp_t], ip: str, port: i32, callback: fn(arg0: ptr[uv.uv_connect_t], arg1: i32) -> void, scratch: ref[arena.Arena]) -> i32:
    let address = create_ipv4_address(ip, port, scratch)
    if not address.is_ok:
        return address.error

    var ipv4 = address.value
    defer release_ipv4_address(ref_of(ipv4))
    let status = uv.tcp_connect(request.raw, tcp.raw, ipv4_const_sockaddr(ipv4), callback)
    return status

pub def create_fs_request() -> Request[uv.uv_fs_t]:
    return alloc_request[uv.uv_fs_t](c.uv_req_type.UV_FS)

pub def fs_cleanup(request: Request[uv.uv_fs_t]) -> void:
    uv.fs_req_cleanup(request.raw)
    return

pub def fs_result(request: Request[uv.uv_fs_t]) -> isize:
    return uv.fs_get_result(request.raw)

pub def fs_path(request: Request[uv.uv_fs_t]) -> str:
    return text.cstr_as_str(uv.fs_get_path(request.raw))

pub def fs_mkstemp(loop: Loop, request: Request[uv.uv_fs_t], tpl: str, callback: fn(arg0: ptr[uv.uv_fs_t]) -> void, scratch: ref[arena.Arena]) -> i32:
    return uv.fs_mkstemp(loop.raw, request.raw, scratch.to_cstr(tpl), callback)

pub def fs_open(loop: Loop, request: Request[uv.uv_fs_t], path: str, flag_bits: i32, mode: i32, callback: fn(arg0: ptr[uv.uv_fs_t]) -> void, scratch: ref[arena.Arena]) -> i32:
    return uv.fs_open(loop.raw, request.raw, scratch.to_cstr(path), flag_bits, mode, callback)

pub def fs_write(loop: Loop, request: Request[uv.uv_fs_t], file: i32, data: span[u8], offset: isize, callback: fn(arg0: ptr[uv.uv_fs_t]) -> void) -> i32:
    var buffer = byte_buffer(data)
    return uv.fs_write(loop.raw, request.raw, file, ptr_of(ref_of(buffer)), 1, offset, callback)

pub def fs_read(loop: Loop, request: Request[uv.uv_fs_t], file: i32, data: span[u8], offset: isize, callback: fn(arg0: ptr[uv.uv_fs_t]) -> void) -> i32:
    var buffer = byte_buffer(data)
    return uv.fs_read(loop.raw, request.raw, file, ptr_of(ref_of(buffer)), 1, offset, callback)

pub def fs_close(loop: Loop, request: Request[uv.uv_fs_t], file: i32, callback: fn(arg0: ptr[uv.uv_fs_t]) -> void) -> i32:
    return uv.fs_close(loop.raw, request.raw, file, callback)

pub def fs_unlink(loop: Loop, request: Request[uv.uv_fs_t], path: str, callback: fn(arg0: ptr[uv.uv_fs_t]) -> void, scratch: ref[arena.Arena]) -> i32:
    return uv.fs_unlink(loop.raw, request.raw, scratch.to_cstr(path), callback)

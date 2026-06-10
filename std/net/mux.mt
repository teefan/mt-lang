import std.async as aio
import std.binary as bin
import std.bytes as bytes
import std.deque as deque
import std.mem.heap as heap
import std.net as net
import std.net.session as sess
import std.vec as vec

public const flag_reliable: ubyte = 0x01
public const flag_fragmented: ubyte = 0x04

public const meta_channel: ubyte = 0xFF
public const type_peer_joined: ushort = 0xFFFE
public const type_peer_left: ushort = 0xFFFD

const wire_header_size: ptr_uint = 4
const fragment_header_size: ptr_uint = 6

public struct MuxedSendOptions:
    reliable: bool
    fragmented: bool

public struct MuxedConfig:
    fragment_size: ptr_uint
    fragment_timeout_frames: uint

public struct MuxedMessage:
    peer_id: uint
    channel_id: ubyte
    type_id: ushort
    msg_flags: ubyte
    payload: bytes.Bytes

public struct MuxedConnection:
    conn: sess.Connection
    config: MuxedConfig
    event_queue: deque.Deque[MuxedMessage]
    frag_buffers: vec.Vec[FragBuffer]
    next_group_id: ushort
    current_frame: uint

public struct MuxedSession:
    session: sess.Session
    config: MuxedConfig
    event_queue: deque.Deque[MuxedMessage]
    frag_buffers: vec.Vec[FragBuffer]
    next_group_id: ushort
    current_frame: uint

struct FragBuffer:
    group_id: ushort
    peer_id: uint
    channel_id: ubyte
    type_id: ushort
    msg_flags: ubyte
    total: ushort
    received_count: ushort
    received_bits: uint
    data: bytes.Bytes
    last_frame: uint

struct WireHeader:
    channel_id: ubyte
    type_id: ushort
    msg_flags: ubyte


extending MuxedSendOptions:
    public function to_flags() -> ubyte:
        var send_flags: ubyte = 0
        if this.reliable:
            send_flags |= flag_reliable
        if this.fragmented:
            send_flags |= flag_fragmented
        return send_flags


extending MuxedConfig:
    public static function default() -> MuxedConfig:
        return MuxedConfig(
            fragment_size = 1000,
            fragment_timeout_frames = 120
        )


extending MuxedMessage:
    public editable function release() -> void:
        this.payload.release()


public function mux_connect_on(
    runtime: aio.Runtime,
    local_address: net.SocketAddress,
    remote_address: net.SocketAddress,
    config: MuxedConfig
) -> Result[MuxedConnection, net.Error]:
    let payload_size = config.fragment_size + wire_header_size + fragment_header_size + 32
    let session_config = sess.Config.default(payload_size)
    let conn_result = sess.connect_on(runtime, local_address, remote_address, session_config)
    match conn_result:
        Result.failure as p:
            return Result[MuxedConnection, net.Error].failure(
                error = p.error
            )
        Result.success as p:
            var conn = MuxedConnection(
                conn = p.value,
                config = config,
                event_queue = deque.Deque[MuxedMessage].create(),
                frag_buffers = vec.Vec[FragBuffer].create(),
                next_group_id = 1,
                current_frame = 0
            )
            return Result[MuxedConnection, net.Error].success(value = conn)


public async function mux_connect(
    local_address: net.SocketAddress,
    remote_address: net.SocketAddress,
    config: MuxedConfig
) -> Result[MuxedConnection, net.Error]:
    match mux_connect_on(aio.current_runtime(), local_address, remote_address, config):
        Result.failure as p:
            return Result[MuxedConnection, net.Error].failure(error = p.error)
        Result.success as p:
            var mux_conn = p.value
            match await mux_conn.connect_to_peer():
                Result.failure as cp:
                    mux_conn.release()
                    return Result[MuxedConnection, net.Error].failure(error = cp.error)
                Result.success:
                    return Result[MuxedConnection, net.Error].success(value = mux_conn)


public function mux_listen_on(
    runtime: aio.Runtime,
    local_address: net.SocketAddress,
    config: MuxedConfig
) -> Result[MuxedSession, net.Error]:
    let payload_size = config.fragment_size + wire_header_size + fragment_header_size + 32
    let session_config = sess.Config.default(payload_size)
    let listen_result = sess.listen_on(runtime, local_address, session_config)
    match listen_result:
        Result.failure as p:
            return Result[MuxedSession, net.Error].failure(
                error = p.error
            )
        Result.success as p:
            return Result[MuxedSession, net.Error].success(value = MuxedSession(
                session = p.value,
                config = config,
                event_queue = deque.Deque[MuxedMessage].create(),
                frag_buffers = vec.Vec[FragBuffer].create(),
                next_group_id = 1,
                current_frame = 0
            ))


public function mux_listen(
    local_address: net.SocketAddress,
    config: MuxedConfig
) -> Result[MuxedSession, net.Error]:
    return mux_listen_on(aio.current_runtime(), local_address, config)


extending MuxedConnection:
    public editable function release() -> void:
        release_frag_buffers(ref_of(this.frag_buffers))
        this.frag_buffers.release()
        release_event_queue(ref_of(this.event_queue))
        this.event_queue.release()
        this.conn.release()


    public function state() -> sess.ConnectionState:
        return this.conn.state()


    public function local_address() -> Result[net.SocketAddress, net.Error]:
        return this.conn.local_address()


    public function peer_address() -> Result[net.SocketAddress, net.Error]:
        return this.conn.peer_address()


    public async editable function connect_to_peer() -> Result[bool, net.Error]:
        match await this.conn.connect_to_peer():
            Result.failure as p:
                return Result[bool, net.Error].failure(error = p.error)
            Result.success as p:
                return Result[bool, net.Error].success(value = p.value)


    public async editable function tick(frame: uint) -> Result[bool, net.Error]:
        this.current_frame = frame
        let conn_result = await this.conn.tick(frame)
        drain_incoming_conn(ref_of(this))
        prune_frag_buffers(ref_of(this.frag_buffers), frame, this.config.fragment_timeout_frames)
        match conn_result:
            Result.failure as p:
                return Result[bool, net.Error].failure(error = p.error)
            Result.success as p:
                return Result[bool, net.Error].success(value = p.value)


    public editable function try_recv() -> Option[MuxedMessage]:
        return this.event_queue.pop_front()


    public async editable function recv() -> Result[Option[MuxedMessage], net.Error]:
        while true:
            let ev = this.try_recv()
            match ev:
                Option.some as p:
                    return Result[Option[MuxedMessage], net.Error].success(
                        value = Option[MuxedMessage].some(value = p.value)
                    )
                Option.none:
                    let sess_result = await this.conn.recv()
                    match sess_result:
                        Result.failure as p:
                            return Result[Option[MuxedMessage], net.Error].failure(
                                error = p.error
                            )
                        Result.success as sess_p:
                            match sess_p.value:
                                Option.none:
                                    pass
                                Option.some as msg_p:
                                    var msg = msg_p.value
                                    demux_conn(ref_of(this), ref_of(msg), this.current_frame)
                                    let queued = this.try_recv()
                                    match queued:
                                        Option.some as q:
                                            return Result[Option[MuxedMessage], net.Error].success(
                                                value = Option[MuxedMessage].some(value = q.value)
                                            )
                                        Option.none:
                                            pass


    public async editable function mux_send(
        channel_id: ubyte,
        type_id: ushort,
        data: span[ubyte],
        send_flags: ubyte
    ) -> Result[bool, net.Error]:
        if (send_flags & flag_fragmented) != 0 and data.len > this.config.fragment_size:
            return await send_fragmented_conn(ref_of(this), channel_id, type_id, data, send_flags)
        return await send_single_conn(ref_of(this), channel_id, type_id, data, send_flags)


    public async editable function disconnect() -> Result[bool, net.Error]:
        match await this.conn.disconnect_peer():
            Result.failure as p:
                return Result[bool, net.Error].failure(error = p.error)
            Result.success as p:
                return Result[bool, net.Error].success(value = p.value)


extending MuxedSession:
    public editable function release() -> void:
        release_frag_buffers(ref_of(this.frag_buffers))
        this.frag_buffers.release()
        release_event_queue(ref_of(this.event_queue))
        this.event_queue.release()
        this.session.release()


    public function local_address() -> Result[net.SocketAddress, net.Error]:
        return this.session.local_address()


    public function peer_count() -> ptr_uint:
        return this.session.peer_count()


    public async editable function tick(frame: uint) -> Result[bool, net.Error]:
        this.current_frame = frame
        let sess_result = await this.session.tick(frame)
        drain_incoming_session(ref_of(this))
        prune_frag_buffers(ref_of(this.frag_buffers), frame, this.config.fragment_timeout_frames)
        match sess_result:
            Result.failure as p:
                return Result[bool, net.Error].failure(error = p.error)
            Result.success as p:
                return Result[bool, net.Error].success(value = p.value)


    public editable function try_recv() -> Option[MuxedMessage]:
        return this.event_queue.pop_front()


    public async editable function recv() -> Result[Option[MuxedMessage], net.Error]:
        while true:
            let ev = this.try_recv()
            match ev:
                Option.some as p:
                    return Result[Option[MuxedMessage], net.Error].success(
                        value = Option[MuxedMessage].some(value = p.value)
                    )
                Option.none:
                    let sess_result = await this.session.recv()
                    match sess_result:
                        Result.failure as p:
                            return Result[Option[MuxedMessage], net.Error].failure(
                                error = p.error
                            )
                        Result.success as sess_p:
                            match sess_p.value:
                                Option.none:
                                    pass
                                Option.some as msg_p:
                                    var msg = msg_p.value
                                    demux_session(ref_of(this), ref_of(msg), this.current_frame)
                                    let queued = this.try_recv()
                                    match queued:
                                        Option.some as q:
                                            return Result[Option[MuxedMessage], net.Error].success(
                                                value = Option[MuxedMessage].some(value = q.value)
                                            )
                                        Option.none:
                                            pass


    public async editable function mux_send(
        peer_id: uint,
        channel_id: ubyte,
        type_id: ushort,
        data: span[ubyte],
        send_flags: ubyte
    ) -> Result[bool, net.Error]:
        if (send_flags & flag_fragmented) != 0 and data.len > this.config.fragment_size:
            return await send_fragmented_session(ref_of(this), peer_id, channel_id, type_id, data, send_flags)
        return await send_single_session(ref_of(this), peer_id, channel_id, type_id, data, send_flags)


    public async editable function kick(peer_id: uint, reason: ubyte) -> Result[bool, net.Error]:
        match await this.session.kick(peer_id, reason):
            Result.failure as p:
                return Result[bool, net.Error].failure(error = p.error)
            Result.success as p:
                return Result[bool, net.Error].success(value = p.value)


function encode_frame(channel_id: ubyte, type_id: ushort, msg_flags: ubyte, payload: span[ubyte]) -> bytes.Bytes:
    var w = bin.Writer.with_capacity(wire_header_size + payload.len)
    w.write_ubyte(channel_id)
    w.write_ushort(type_id)
    w.write_ubyte(msg_flags)
    w.write_bytes(payload)
    return w.finish()


function encode_fragment_frame(
    channel_id: ubyte,
    type_id: ushort,
    msg_flags: ubyte,
    group_id: ushort,
    frag_index: ushort,
    total: ushort,
    payload: span[ubyte]
) -> bytes.Bytes:
    var w = bin.Writer.with_capacity(wire_header_size + fragment_header_size + payload.len)
    w.write_ubyte(channel_id)
    w.write_ushort(type_id)
    w.write_ubyte(msg_flags | flag_fragmented)
    w.write_ushort(group_id)
    w.write_ushort(frag_index)
    w.write_ushort(total)
    w.write_bytes(payload)
    return w.finish()


async function send_single_conn(
    mux: ref[MuxedConnection],
    channel_id: ubyte,
    type_id: ushort,
    data: span[ubyte],
    send_flags: ubyte
) -> Result[bool, net.Error]:
    var frame = encode_frame(channel_id, type_id, send_flags, data)
    defer frame.release()
    if (send_flags & flag_reliable) != 0:
        let result = await mux.conn.send_reliable(frame.as_span(), 0)
        return result
    let result = await mux.conn.send(frame.as_span())
    return result


async function send_single_session(
    mux: ref[MuxedSession],
    peer_id: uint,
    channel_id: ubyte,
    type_id: ushort,
    data: span[ubyte],
    send_flags: ubyte
) -> Result[bool, net.Error]:
    var frame = encode_frame(channel_id, type_id, send_flags, data)
    defer frame.release()
    if (send_flags & flag_reliable) != 0:
        let result = await mux.session.send_reliable(peer_id, frame.as_span(), 0)
        return result
    let result = await mux.session.send(peer_id, frame.as_span())
    return result


async function send_fragmented_conn(
    mux: ref[MuxedConnection],
    channel_id: ubyte,
    type_id: ushort,
    data: span[ubyte],
    send_flags: ubyte
) -> Result[bool, net.Error]:
    let group_id = mux.next_group_id
    mux.next_group_id += 1
    let frag_flags = send_flags | flag_fragmented
    let chunk_size = mux.config.fragment_size
    var total: ushort = 0
    var remaining = data.len
    while remaining > 0:
        let chunk_len = if remaining < chunk_size: remaining else: chunk_size
        if chunk_len == 0:
            break
        total += 1
        remaining -= chunk_len

    remaining = data.len
    var offset: ptr_uint = 0
    var frag_index: ushort = 0
    while remaining > 0:
        let chunk_len = if remaining < chunk_size: remaining else: chunk_size
        if chunk_len == 0:
            break
        let chunk = unsafe: span[ubyte](data = data.data + offset, len = chunk_len)
        var frame = encode_fragment_frame(channel_id, type_id, frag_flags, group_id, frag_index, total, chunk)
        defer frame.release()
        if (send_flags & flag_reliable) != 0:
            let _ = await mux.conn.send_reliable(frame.as_span(), 0)
        else:
            let _ = await mux.conn.send(frame.as_span())
        offset += chunk_len
        remaining -= chunk_len
        frag_index += 1
    return Result[bool, net.Error].success(value = true)


async function send_fragmented_session(
    mux: ref[MuxedSession],
    peer_id: uint,
    channel_id: ubyte,
    type_id: ushort,
    data: span[ubyte],
    send_flags: ubyte
) -> Result[bool, net.Error]:
    let group_id = mux.next_group_id
    mux.next_group_id += 1
    let frag_flags = send_flags | flag_fragmented
    let chunk_size = mux.config.fragment_size
    var total: ushort = 0
    var remaining = data.len
    while remaining > 0:
        let chunk_len = if remaining < chunk_size: remaining else: chunk_size
        if chunk_len == 0:
            break
        total += 1
        remaining -= chunk_len

    remaining = data.len
    var offset: ptr_uint = 0
    var frag_index: ushort = 0
    while remaining > 0:
        let chunk_len = if remaining < chunk_size: remaining else: chunk_size
        if chunk_len == 0:
            break
        let chunk = unsafe: span[ubyte](data = data.data + offset, len = chunk_len)
        var frame = encode_fragment_frame(channel_id, type_id, frag_flags, group_id, frag_index, total, chunk)
        defer frame.release()
        if (send_flags & flag_reliable) != 0:
            let _ = await mux.session.send_reliable(peer_id, frame.as_span(), 0)
        else:
            let _ = await mux.session.send(peer_id, frame.as_span())
        offset += chunk_len
        remaining -= chunk_len
        frag_index += 1
    return Result[bool, net.Error].success(value = true)


function decode_wire_header(data: span[ubyte]) -> Result[WireHeader, net.Error]:
    if data.len < wire_header_size:
        return Result[WireHeader, net.Error].failure(error = net.net_error("mux payload too short"))
    var r = bin.reader(data)
    let channel_id = r.read_ubyte() else:
        return Result[WireHeader, net.Error].failure(error = net.net_error("mux malformed header"))
    let type_id = r.read_ushort() else:
        return Result[WireHeader, net.Error].failure(error = net.net_error("mux malformed header"))
    let wire_flags = r.read_ubyte() else:
        return Result[WireHeader, net.Error].failure(error = net.net_error("mux malformed header"))
    return Result[WireHeader, net.Error].success(value = WireHeader(
        channel_id = channel_id,
        type_id = type_id,
        msg_flags = wire_flags
    ))


function drain_incoming_conn(mux: ref[MuxedConnection]) -> void:
    while true:
        let ev = mux.conn.try_recv()
        match ev:
            Option.none:
                break
            Option.some as p:
                var e = p.value
                demux_conn(mux, ref_of(e), mux.current_frame)


function drain_incoming_session(mux: ref[MuxedSession]) -> void:
    while true:
        let ev = mux.session.try_recv()
        match ev:
            Option.none:
                break
            Option.some as p:
                var e = p.value
                demux_session(mux, ref_of(e), mux.current_frame)


function demux_conn(mux: ref[MuxedConnection], ev: ref[sess.PeerEvent], frame: uint) -> void:
    if ev.kind == sess.PeerEventKind.peer_joined:
        mux.event_queue.push_back(MuxedMessage(
            peer_id = ev.peer_id,
            channel_id = meta_channel,
            type_id = type_peer_joined,
            msg_flags = 0,
            payload = bytes.Bytes.empty()
        ))
        ev.release()
        return

    if ev.kind == sess.PeerEventKind.peer_left:
        mux.event_queue.push_back(MuxedMessage(
            peer_id = ev.peer_id,
            channel_id = meta_channel,
            type_id = type_peer_left,
            msg_flags = 0,
            payload = bytes.Bytes.empty()
        ))
        ev.release()
        return

    if ev.kind != sess.PeerEventKind.user_data:
        ev.release()
        return

    let data = ev.payload.as_span()
    if data.len < wire_header_size:
        ev.release()
        return

    let header_result = decode_wire_header(data)
    match header_result:
        Result.failure:
            ev.release()
            return
        Result.success as hp:
            let h = hp.value
            if (h.msg_flags & flag_fragmented) != 0:
                handle_fragment_conn(mux, h, data, frame)
            else:
                let payload_len = data.len - wire_header_size
                var payload = bytes.Bytes.empty()
                if payload_len > 0:
                    unsafe:
                        payload = bytes.Bytes.copy(span[ubyte](data = data.data + wire_header_size, len = payload_len))
                mux.event_queue.push_back(MuxedMessage(
                    peer_id = ev.peer_id,
                    channel_id = h.channel_id,
                    type_id = h.type_id,
                    msg_flags = h.msg_flags,
                    payload = payload
                ))
            ev.release()


function demux_session(mux: ref[MuxedSession], ev: ref[sess.PeerEvent], frame: uint) -> void:
    if ev.kind == sess.PeerEventKind.peer_joined:
        mux.event_queue.push_back(MuxedMessage(
            peer_id = ev.peer_id,
            channel_id = meta_channel,
            type_id = type_peer_joined,
            msg_flags = 0,
            payload = bytes.Bytes.empty()
        ))
        ev.release()
        return

    if ev.kind == sess.PeerEventKind.peer_left:
        mux.event_queue.push_back(MuxedMessage(
            peer_id = ev.peer_id,
            channel_id = meta_channel,
            type_id = type_peer_left,
            msg_flags = 0,
            payload = bytes.Bytes.empty()
        ))
        ev.release()
        return

    if ev.kind != sess.PeerEventKind.user_data:
        ev.release()
        return

    let data = ev.payload.as_span()
    if data.len < wire_header_size:
        ev.release()
        return

    let header_result = decode_wire_header(data)
    match header_result:
        Result.failure:
            ev.release()
            return
        Result.success as hp:
            let h = hp.value
            if (h.msg_flags & flag_fragmented) != 0:
                handle_fragment_session(mux, h, data, frame, ev.peer_id)
            else:
                let payload_len = data.len - wire_header_size
                var payload = bytes.Bytes.empty()
                if payload_len > 0:
                    unsafe:
                        payload = bytes.Bytes.copy(span[ubyte](data = data.data + wire_header_size, len = payload_len))
                mux.event_queue.push_back(MuxedMessage(
                    peer_id = ev.peer_id,
                    channel_id = h.channel_id,
                    type_id = h.type_id,
                    msg_flags = h.msg_flags,
                    payload = payload
                ))
            ev.release()


function handle_fragment_conn(mux: ref[MuxedConnection], h: WireHeader, data: span[ubyte], frame: uint) -> void:
    if data.len < wire_header_size + fragment_header_size:
        return
    unsafe:
        let group_lo = ushort<-read(data.data + wire_header_size)
        let group_hi = ushort<-read(data.data + wire_header_size + 1)
        let group_id = group_lo | (group_hi << 8)
        let index_lo = ushort<-read(data.data + wire_header_size + 2)
        let index_hi = ushort<-read(data.data + wire_header_size + 3)
        let frag_index = index_lo | (index_hi << 8)
        let total_lo = ushort<-read(data.data + wire_header_size + 4)
        let total_hi = ushort<-read(data.data + wire_header_size + 5)
        let total = total_lo | (total_hi << 8)
        assemble_fragment(
            ref_of(mux.frag_buffers),
            ref_of(mux.event_queue),
            mux.config,
            h,
            group_id,
            frag_index,
            total,
            data,
            frame,
            0
        )


function handle_fragment_session(
    mux: ref[MuxedSession],
    h: WireHeader,
    data: span[ubyte],
    frame: uint,
    peer_id: uint
) -> void:
    if data.len < wire_header_size + fragment_header_size:
        return
    unsafe:
        let group_lo = ushort<-read(data.data + wire_header_size)
        let group_hi = ushort<-read(data.data + wire_header_size + 1)
        let group_id = group_lo | (group_hi << 8)
        let index_lo = ushort<-read(data.data + wire_header_size + 2)
        let index_hi = ushort<-read(data.data + wire_header_size + 3)
        let frag_index = index_lo | (index_hi << 8)
        let total_lo = ushort<-read(data.data + wire_header_size + 4)
        let total_hi = ushort<-read(data.data + wire_header_size + 5)
        let total = total_lo | (total_hi << 8)
        assemble_fragment(
            ref_of(mux.frag_buffers),
            ref_of(mux.event_queue),
            mux.config,
            h,
            group_id,
            frag_index,
            total,
            data,
            frame,
            peer_id
        )


function assemble_fragment(
    buffers: ref[vec.Vec[FragBuffer]],
    queue: ref[deque.Deque[MuxedMessage]],
    config: MuxedConfig,
    h: WireHeader,
    group_id: ushort,
    frag_index: ushort,
    total: ushort,
    data: span[ubyte],
    frame: uint,
    peer_id: uint
) -> void:
    let payload_start = wire_header_size + fragment_header_size
    if data.len <= payload_start:
        return
    let payload_len = data.len - payload_start
    if frag_index >= total:
        return

    let buf_index = find_frag_buffer(buffers, peer_id, group_id)
    if buf_index < 0:
        var full_size = ptr_uint<-total * config.fragment_size
        var buf = bytes.Bytes.empty()
        if full_size > 0:
            let buf_data = heap.must_alloc[ubyte](full_size)
            var fill: ptr_uint = 0
            while fill < full_size:
                unsafe: read(buf_data + fill) = 0
                fill += 1
            buf = bytes.Bytes(data = buf_data, len = full_size)
        buffers.push(FragBuffer(
            group_id = group_id,
            peer_id = peer_id,
            channel_id = h.channel_id,
            type_id = h.type_id,
            msg_flags = h.msg_flags,
            total = total,
            received_count = 1,
            received_bits = uint<-(1 << (uint<-frag_index)),
            data = buf,
            last_frame = frame
        ))
        let dest_start = ptr_uint<-frag_index * config.fragment_size
        if dest_start + payload_len <= full_size:
            unsafe:
                copy_bytes(ptr[ubyte]<-buf.data, dest_start, data, payload_start, payload_len)
        return

    let buf_ptr = buffers.get(ptr_uint<-buf_index) else:
        return
    let bit_flag: uint = 1 << uint<-frag_index
    if (unsafe: read(buf_ptr).received_bits & bit_flag) != 0:
        return

    unsafe: read(buf_ptr).received_count += 1
    unsafe: read(buf_ptr).received_bits |= bit_flag
    unsafe: read(buf_ptr).last_frame = frame
    let dest_start = ptr_uint<-frag_index * config.fragment_size
    let full_size = ptr_uint<-total * config.fragment_size
    if dest_start + payload_len <= full_size:
        unsafe:
            copy_bytes(ptr[ubyte]<-read(buf_ptr).data.data, dest_start, data, payload_start, payload_len)

    if unsafe: read(buf_ptr).received_count == unsafe: read(buf_ptr).total:
        var final_data = bytes.Bytes.empty()
        if full_size > 0:
            let copy_src = unsafe: read(buf_ptr).data.data
            unsafe:
                final_data = bytes.Bytes.copy(span[ubyte](data = ptr[ubyte]<-copy_src, len = full_size))
        queue.push_back(MuxedMessage(
            peer_id = peer_id,
            channel_id = h.channel_id,
            type_id = h.type_id,
            msg_flags = h.msg_flags,
            payload = final_data
        ))
        unsafe: read(buf_ptr).data.release()
        buffers.remove(ptr_uint<-buf_index)


function copy_bytes(
    dest: ptr[ubyte],
    dest_offset: ptr_uint,
    src_data: span[ubyte],
    src_offset: ptr_uint,
    count: ptr_uint
) -> void:
    unsafe:
        var i: ptr_uint = 0
        while i < count:
            read(dest + dest_offset + i) = read(src_data.data + src_offset + i)
            i += 1


function find_frag_buffer(buffers: ref[vec.Vec[FragBuffer]], peer_id: uint, group_id: ushort) -> int:
    var index: ptr_uint = 0
    while index < buffers.len():
        let buf_ptr = buffers.get(index) else:
            return -1
        if unsafe: read(buf_ptr).group_id == group_id and unsafe: read(buf_ptr).peer_id == peer_id:
            return int<-index
        index += 1
    return -1


function prune_frag_buffers(buffers: ref[vec.Vec[FragBuffer]], frame: uint, timeout_frames: uint) -> void:
    var index: int = int<-(buffers.len())
    index -= 1
    while index >= 0:
        let buf_ptr = buffers.get(ptr_uint<-index) else:
            return
        if frame > unsafe: read(buf_ptr).last_frame + timeout_frames:
            unsafe: read(buf_ptr).data.release()
            buffers.remove(ptr_uint<-index)
        index -= 1


function release_frag_buffers(buffers: ref[vec.Vec[FragBuffer]]) -> void:
    var index: ptr_uint = 0
    while index < buffers.len():
        let buf_ptr = buffers.get(index) else:
            return
        unsafe: read(buf_ptr).data.release()
        index += 1
    buffers.clear()


function release_event_queue(queue: ref[deque.Deque[MuxedMessage]]) -> void:
    while true:
        let msg = queue.pop_front()
        match msg:
            Option.none:
                break
            Option.some as p:
                var m = p.value
                m.release()

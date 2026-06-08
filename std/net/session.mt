import std.async as aio
import std.binary as bin
import std.bytes as bytes
import std.crypto as crypto
import std.deque as deque
import std.net as net
import std.net.channel as chan
import std.string as string
import std.vec as vec

const msg_type_user: ubyte = 0x00
const msg_type_connect_request: ubyte = 0x01
const msg_type_connect_accept: ubyte = 0x02
const msg_type_connect_reject: ubyte = 0x03
const msg_type_heartbeat: ubyte = 0x04
const msg_type_heartbeat_ack: ubyte = 0x05
const msg_type_disconnect: ubyte = 0x06

const reject_reason_version: ubyte = 1
const reject_reason_full: ubyte = 2
const reject_reason_refused: ubyte = 3
const disconnect_reason_local: ubyte = 1
const disconnect_reason_timeout: ubyte = 2
const disconnect_reason_remote: ubyte = 3

const connect_request_payload_bytes: ptr_uint = 12
const connect_accept_payload_bytes: ptr_uint = 4
const heartbeat_payload_bytes: ptr_uint = 4

public enum ConnectionState: int
    disconnected = 0
    connecting = 1
    connected = 2

public struct Error:
    code: int
    message: string.String

public struct Config:
    max_payload_bytes: ptr_uint
    protocol_version: uint
    heartbeat_interval: uint
    heartbeat_timeout: uint
    resend_after_frames: uint
    max_pending_reliable: ptr_uint

public enum PeerEventKind: ubyte
    user_data = 0
    peer_joined = 1
    peer_left = 2

public struct PeerEvent:
    kind: PeerEventKind
    peer_id: uint
    payload: bytes.Bytes
    reliable: bool
    reason: ubyte

extending PeerEvent:
    public editable function release() -> void:
        if this.kind == PeerEventKind.user_data:
            this.payload.release()

type ChanMessageTask = Task[Result[Option[chan.Message], chan.Error]]
type ChanHostMessageTask = Task[Result[Option[chan.HostMessage], chan.Error]]

public struct Connection:
    channel: chan.Channel
    state: ConnectionState
    protocol_version: uint
    heartbeat_interval: uint
    heartbeat_timeout: uint
    frame_since_last_recv: uint
    ping_rtt_frames: uint
    last_heartbeat_sent: uint
    pending_recv: Option[ChanMessageTask]
    event_queue: deque.Deque[PeerEvent]
    outgoing: deque.Deque[OutgoingMessage]

public struct PeerConnection:
    peer_id: uint
    channel_state: ConnectionState
    frame_since_last_recv: uint
    last_heartbeat_sent: uint
    heartbeat_ack_received: bool

public struct Session:
    host: chan.Host
    config: Config
    next_peer_id: uint
    peers: vec.Vec[PeerConnection]
    pending_recv: Option[ChanHostMessageTask]
    event_queue: deque.Deque[PeerEvent]
    outgoing: deque.Deque[OutgoingMessage]

struct OutgoingMessage:
    address: net.SocketAddress
    payload: bytes.Bytes
    reliable: bool


function session_error(code: int, message: str) -> Error:
    return Error(code = code, message = string.String.from_str(message))


function chan_to_session_error(source: chan.Error) -> Error:
    return Error(code = source.code, message = source.message)


function build_connect_request(version: uint, key: ulong) -> bytes.Bytes:
    var w = bin.Writer.with_capacity(1 + connect_request_payload_bytes)
    w.write_u8(msg_type_connect_request)
    w.write_u32(version)
    w.write_u64(key)
    return w.finish()


function build_connect_accept(peer_id: uint) -> bytes.Bytes:
    var w = bin.Writer.with_capacity(1 + connect_accept_payload_bytes)
    w.write_u8(msg_type_connect_accept)
    w.write_u32(peer_id)
    return w.finish()


function build_connect_reject(reason: ubyte) -> bytes.Bytes:
    var w = bin.Writer.with_capacity(2)
    w.write_u8(msg_type_connect_reject)
    w.write_u8(reason)
    return w.finish()


function build_heartbeat(frame: uint) -> bytes.Bytes:
    var w = bin.Writer.with_capacity(1 + heartbeat_payload_bytes)
    w.write_u8(msg_type_heartbeat)
    w.write_u32(frame)
    return w.finish()


function build_heartbeat_ack(frame: uint) -> bytes.Bytes:
    var w = bin.Writer.with_capacity(1 + heartbeat_payload_bytes)
    w.write_u8(msg_type_heartbeat_ack)
    w.write_u32(frame)
    return w.finish()


function build_disconnect(reason: ubyte) -> bytes.Bytes:
    var w = bin.Writer.with_capacity(2)
    w.write_u8(msg_type_disconnect)
    w.write_u8(reason)
    return w.finish()


function build_user_data(payload: span[ubyte]) -> bytes.Bytes:
    var w = bin.Writer.with_capacity(1 + payload.len)
    w.write_u8(msg_type_user)
    w.write_bytes(payload)
    return w.finish()


function generate_handshake_key() -> ulong:
    let key_result = crypto.random_bytes(8)
    match key_result:
        Result.failure:
            return 12345678901234567890
        Result.success as payload:
            var rand = payload.value
            var reader = bin.reader(rand.as_span())
            match reader.read_u64():
                Result.failure:
                    rand.release()
                    return 12345678901234567890
                Result.success as read_payload:
                    let value = read_payload.value
                    rand.release()
                    return value


function decode_u32_at(data: span[ubyte], offset: ptr_uint) -> uint:
    unsafe:
        return uint<-read(data.data + offset) |
            (uint<-read(data.data + offset + 1) << 8) |
            (uint<-read(data.data + offset + 2) << 16) |
            (uint<-read(data.data + offset + 3) << 24)


function channel_config_for(config: Config) -> chan.Config:
    return chan.Config(
        max_payload_bytes = config.max_payload_bytes + 1,
        max_pending_reliable = config.max_pending_reliable,
        resend_after_frames = config.resend_after_frames
    )


extending Error:
    public editable function release() -> void:
        this.message.release()


extending Config:
    public static function default(max_payload_bytes: ptr_uint) -> Config:
        return Config(
            max_payload_bytes = max_payload_bytes,
            protocol_version = 1,
            heartbeat_interval = 60,
            heartbeat_timeout = 300,
            resend_after_frames = 5,
            max_pending_reliable = 32
        )


public function connect_on(
    runtime: aio.Runtime,
    local_address: net.SocketAddress,
    remote_address: net.SocketAddress,
    config: Config
) -> Result[Connection, Error]:
    let channel_config = channel_config_for(config)
    let channel_result = chan.bind_connect_on(runtime, local_address, remote_address, channel_config)
    match channel_result:
        Result.failure as payload:
            return Result[Connection, Error].failure(error = chan_to_session_error(payload.error))
        Result.success as payload:
            var conn = Connection(
                channel = payload.value,
                state = ConnectionState.disconnected,
                protocol_version = config.protocol_version,
                heartbeat_interval = config.heartbeat_interval,
                heartbeat_timeout = config.heartbeat_timeout,
                frame_since_last_recv = 0,
                ping_rtt_frames = 0,
                last_heartbeat_sent = 0,
                pending_recv = Option[ChanMessageTask].none,
                event_queue = deque.Deque[PeerEvent].create(),
                outgoing = deque.Deque[OutgoingMessage].create()
            )
            conn.event_queue = deque.Deque[PeerEvent].create()
            conn.outgoing = deque.Deque[OutgoingMessage].create()
            return Result[Connection, Error].success(value = conn)


public function connect(
    local_address: net.SocketAddress,
    remote_address: net.SocketAddress,
    config: Config
) -> Result[Connection, Error]:
    return connect_on(aio.current_runtime(), local_address, remote_address, config)


public function listen_on(
    runtime: aio.Runtime,
    local_address: net.SocketAddress,
    config: Config
) -> Result[Session, Error]:
    let channel_config = channel_config_for(config)
    let channel_result = chan.listen_on(runtime, local_address, channel_config)
    match channel_result:
        Result.failure as payload:
            return Result[Session, Error].failure(error = chan_to_session_error(payload.error))
        Result.success as payload:
            var session = Session(
                host = payload.value,
                config = config,
                next_peer_id = 1,
                peers = vec.Vec[PeerConnection].create(),
                pending_recv = Option[ChanHostMessageTask].none,
                event_queue = deque.Deque[PeerEvent].create(),
                outgoing = deque.Deque[OutgoingMessage].create()
            )
            session.event_queue = deque.Deque[PeerEvent].create()
            session.outgoing = deque.Deque[OutgoingMessage].create()
            return Result[Session, Error].success(value = session)


public function listen(local_address: net.SocketAddress, config: Config) -> Result[Session, Error]:
    return listen_on(aio.current_runtime(), local_address, config)


extending Connection:
    public editable function release() -> void:
        this.pending_recv = Option[ChanMessageTask].none
        drain_release_outgoing_conn(ref_of(this))
        this.outgoing.release()
        drain_release_events(ref_of(this.event_queue))
        this.event_queue.release()
        this.channel.release()


    public function state() -> ConnectionState:
        return this.state


    public function local_address() -> Result[net.SocketAddress, net.Error]:
        return this.channel.local_address()


    public function peer_address() -> Result[net.SocketAddress, net.Error]:
        return this.channel.peer_address()


    public function ping_rtt_frames() -> uint:
        return this.ping_rtt_frames


    public editable function start_recv() -> void:
        start_recv_if_idle(ref_of(this))


    public async editable function tick(frame: uint) -> Result[bool, Error]:
        start_recv_if_idle(ref_of(this))

        if this.state == ConnectionState.connected:
            if frame >= this.last_heartbeat_sent + this.heartbeat_interval:
                var hb = build_heartbeat(frame)
                defer hb.release()
                let send_result = await this.channel.send(hb.as_span())
                match send_result:
                    Result.failure:
                        pass
                    Result.success:
                        pass
                this.last_heartbeat_sent = frame

            this.frame_since_last_recv += 1
            if this.frame_since_last_recv >= this.heartbeat_timeout:
                this.state = ConnectionState.disconnected

        let channel_tick_result = await this.channel.tick(frame)
        match channel_tick_result:
            Result.failure:
                pass
            Result.success:
                pass

        await aio.sleep(1)

        process_pending_recv_conn(ref_of(this))
        await drain_outgoing_conn(ref_of(this))

        return Result[bool, Error].success(value = this.state == ConnectionState.connected)


    public editable function try_recv() -> Option[PeerEvent]:
        return this.event_queue.pop_front()


    public async editable function recv() -> Result[Option[PeerEvent], Error]:
        while true:
            let ev = this.try_recv()
            match ev:
                Option.some as payload:
                    return Result[Option[PeerEvent], Error].success(
                        value = Option[PeerEvent].some(value = payload.value)
                    )
                Option.none:
                    process_pending_recv_conn(ref_of(this))
                    await drain_outgoing_conn(ref_of(this))
                    let ready = this.try_recv()
                    match ready:
                        Option.some as ready_payload:
                            return Result[Option[PeerEvent], Error].success(
                                value = Option[PeerEvent].some(value = ready_payload.value)
                            )
                        Option.none:
                            let recv_result = await this.channel.recv()
                            match recv_result:
                                Result.failure as payload:
                                    return Result[Option[PeerEvent], Error].failure(
                                        error = chan_to_session_error(payload.error)
                                    )
                                Result.success as recv_payload:
                                    let msg_opt = recv_payload.value
                                    match msg_opt:
                                        Option.none:
                                            pass
                                        Option.some as msg_payload:
                                            var msg = msg_payload.value
                                            handle_incoming_conn(ref_of(this), ref_of(msg))
                                            await drain_outgoing_conn(ref_of(this))
                                            let ev2 = this.try_recv()
                                            match ev2:
                                                Option.some as p2:
                                                    return Result[Option[PeerEvent], Error].success(
                                                        value = Option[PeerEvent].some(value = p2.value)
                                                    )
                                                Option.none:
                                                    pass


    public async editable function send(data: span[ubyte]) -> Result[bool, Error]:
        if this.state != ConnectionState.connected:
            return Result[bool, Error].failure(error = session_error(-2, "session not connected"))

        var framed = build_user_data(data)
        defer framed.release()
        let send_result = await this.channel.send(framed.as_span())
        match send_result:
            Result.failure as payload:
                return Result[bool, Error].failure(error = chan_to_session_error(payload.error))
            Result.success:
                return Result[bool, Error].success(value = true)


    public async editable function send_reliable(data: span[ubyte], frame: uint) -> Result[bool, Error]:
        if this.state != ConnectionState.connected:
            return Result[bool, Error].failure(error = session_error(-2, "session not connected"))

        var framed = build_user_data(data)
        defer framed.release()
        let send_result = await this.channel.send_reliable(framed.as_span(), frame)
        match send_result:
            Result.failure as payload:
                return Result[bool, Error].failure(error = chan_to_session_error(payload.error))
            Result.success:
                return Result[bool, Error].success(value = true)


    public async editable function connect_to_peer() -> Result[bool, Error]:
        if this.state != ConnectionState.disconnected:
            return Result[bool, Error].failure(error = session_error(-3, "session already connected or connecting"))

        this.state = ConnectionState.connecting
        start_recv_if_idle(ref_of(this))

        var req = build_connect_request(this.protocol_version, generate_handshake_key())
        defer req.release()
        let send_result = await this.channel.send_reliable(req.as_span(), this.last_heartbeat_sent)
        match send_result:
            Result.failure as send_payload:
                this.state = ConnectionState.disconnected
                return Result[bool, Error].failure(error = chan_to_session_error(send_payload.error))
            Result.success:
                this.frame_since_last_recv = 0
                return Result[bool, Error].success(value = true)


    public async editable function disconnect_peer() -> Result[bool, Error]:
        if this.state != ConnectionState.connected:
            return Result[bool, Error].failure(error = session_error(-4, "session not connected"))

        var d = build_disconnect(disconnect_reason_local)
        defer d.release()
        let send_result = await this.channel.send_reliable(d.as_span(), 0)
        this.state = ConnectionState.disconnected
        match send_result:
            Result.failure:
                return Result[bool, Error].success(value = true)
            Result.success:
                return Result[bool, Error].success(value = true)


function start_recv_if_idle(conn: ref[Connection]) -> void:
    match conn.pending_recv:
        Option.some:
            return
        Option.none:
            conn.pending_recv = Option[ChanMessageTask].some(
                value = conn.channel.recv()
            )


function process_pending_recv_conn(conn: ref[Connection]) -> void:
    match conn.pending_recv:
        Option.none:
            return
        Option.some as task_opt:
            let task = task_opt.value
            if not aio.completed(task):
                return
            let result = aio.result(task)
            conn.pending_recv = Option[ChanMessageTask].none
            start_recv_if_idle(conn)
            match result:
                Result.failure:
                    return
                Result.success as result_payload:
                    let msg_opt = result_payload.value
                    match msg_opt:
                        Option.none:
                            pass
                        Option.some as msg_payload:
                            var msg = msg_payload.value
                            handle_incoming_conn(conn, ref_of(msg))


function handle_incoming_conn(conn: ref[Connection], msg: ref[chan.Message]) -> void:
    let span = msg.payload.as_span()
    if span.len == 0:
        msg.release()
        return

    let tag = unsafe: read(span.data)

    if tag == msg_type_user:
        conn.frame_since_last_recv = 0
        let payload_len = span.len - 1
        var payload = bytes.Bytes.empty()
        if payload_len > 0:
            unsafe:
                payload = bytes.Bytes.copy(span[ubyte](data = span.data + 1, len = payload_len))
        conn.event_queue.push_back(PeerEvent(
            kind = PeerEventKind.user_data,
            peer_id = 0,
            payload = payload,
            reliable = msg.reliable,
            reason = 0
        ))
        msg.release()
        return

    if tag == msg_type_heartbeat:
        conn.frame_since_last_recv = 0
        let hb_span = unsafe: span[ubyte](data = span.data + 1, len = span.len - 1)
        if hb_span.len >= 4:
            let echoed = decode_u32_at(hb_span, 0)
            var ack = build_heartbeat_ack(echoed)
            let peer_addr_result = conn.channel.peer_address()
            match peer_addr_result:
                Result.success as peer_addr:
                    conn.outgoing.push_back(OutgoingMessage(
                        address = peer_addr.value,
                        payload = ack,
                        reliable = false
                    ))
                Result.failure:
                    ack.release()
        msg.release()
        return

    if tag == msg_type_heartbeat_ack:
        conn.frame_since_last_recv = 0
        let echo_span = unsafe: span[ubyte](data = span.data + 1, len = span.len - 1)
        if echo_span.len >= 4:
            let echoed = decode_u32_at(echo_span, 0)
            if conn.last_heartbeat_sent > echoed:
                conn.ping_rtt_frames = conn.last_heartbeat_sent - echoed
        msg.release()
        return

    if tag == msg_type_connect_accept:
        conn.frame_since_last_recv = 0
        conn.state = ConnectionState.connected
        msg.release()
        return

    if tag == msg_type_connect_reject:
        conn.state = ConnectionState.disconnected
        msg.release()
        return

    if tag == msg_type_disconnect:
        conn.state = ConnectionState.disconnected
        msg.release()
        return

    msg.release()


async function drain_outgoing_conn(conn: ref[Connection]) -> Result[bool, Error]:
    while true:
        let msg = conn.outgoing.pop_front()
        match msg:
            Option.none:
                return Result[bool, Error].success(value = true)
            Option.some as payload:
                var outgoing = payload.value
                defer outgoing.release()
                if outgoing.reliable:
                    let _ = await conn.channel.send_reliable(
                        outgoing.payload.as_span(),
                        0
                    )
                else:
                    let _ = await conn.channel.send(
                        outgoing.payload.as_span()
                    )


extending OutgoingMessage:
    public editable function release() -> void:
        this.address.release()
        this.payload.release()


extending Session:
    public editable function release() -> void:
        this.pending_recv = Option[ChanHostMessageTask].none
        drain_release_outgoing(ref_of(this))
        this.outgoing.release()
        drain_release_events(ref_of(this.event_queue))
        this.event_queue.release()
        this.peers.release()
        this.host.release()


    public function local_address() -> Result[net.SocketAddress, net.Error]:
        return this.host.local_address()


    public function peer_count() -> ptr_uint:
        return this.peers.len()


    public editable function start_recv() -> void:
        start_recv_if_idle_session(ref_of(this))


    public async editable function tick(frame: uint) -> Result[bool, Error]:
        start_recv_if_idle_session(ref_of(this))

        var peer_index: ptr_uint = 0
        while peer_index < this.peers.len():
            let peer_ptr = this.peers.get(peer_index) else:
                fatal(c"session peer missing storage")

            if unsafe: read(peer_ptr).channel_state == ConnectionState.connected:
                if frame >= unsafe: read(peer_ptr).last_heartbeat_sent + this.config.heartbeat_interval:
                    var hb = build_heartbeat(frame)
                    defer hb.release()
                    let peer_id = unsafe: read(peer_ptr).peer_id
                    let peer_address_result = find_peer_address(ref_of(this), peer_id)
                    match peer_address_result:
                        Result.success as addr_payload:
                            var addr = addr_payload.value
                            defer addr.release()
                            let send_result = await this.host.send(addr, hb.as_span())
                            match send_result:
                                Result.failure:
                                    pass
                                Result.success:
                                    pass
                        Result.failure:
                            pass
                    unsafe: read(peer_ptr).last_heartbeat_sent = frame

                unsafe: read(peer_ptr).frame_since_last_recv += 1
                if unsafe: read(peer_ptr).frame_since_last_recv >= this.config.heartbeat_timeout:
                    unsafe: read(peer_ptr).channel_state = ConnectionState.disconnected
                    this.event_queue.push_back(PeerEvent(
                        kind = PeerEventKind.peer_left,
                        peer_id = unsafe: read(peer_ptr).peer_id,
                        payload = bytes.Bytes.empty(),
                        reliable = false,
                        reason = disconnect_reason_timeout
                    ))

            peer_index += 1

        let host_tick_result = await this.host.tick(frame)
        match host_tick_result:
            Result.failure:
                pass
            Result.success:
                pass

        await aio.sleep(1)

        process_pending_recv_session(ref_of(this))
        await drain_outgoing_session(ref_of(this))

        let connected_count = connected_peer_count(ref_of(this))
        return Result[bool, Error].success(value = connected_count > 0)


    public editable function try_recv() -> Option[PeerEvent]:
        return this.event_queue.pop_front()


    public async editable function recv() -> Result[Option[PeerEvent], Error]:
        while true:
            let ev = this.try_recv()
            match ev:
                Option.some as payload:
                    return Result[Option[PeerEvent], Error].success(
                        value = Option[PeerEvent].some(value = payload.value)
                    )
                Option.none:
                    process_pending_recv_session(ref_of(this))
                    await drain_outgoing_session(ref_of(this))
                    let ready = this.try_recv()
                    match ready:
                        Option.some as ready_payload:
                            return Result[Option[PeerEvent], Error].success(
                                value = Option[PeerEvent].some(value = ready_payload.value)
                            )
                        Option.none:
                            let recv_result = await this.host.recv()
                            match recv_result:
                                Result.failure as payload:
                                    return Result[Option[PeerEvent], Error].failure(
                                        error = chan_to_session_error(payload.error)
                                    )
                                Result.success as recv_payload:
                                    let msg_opt = recv_payload.value
                                    match msg_opt:
                                        Option.none:
                                            pass
                                        Option.some as msg_payload:
                                            var msg = msg_payload.value
                                            handle_incoming_session(ref_of(this), ref_of(msg))
                                            await drain_outgoing_session(ref_of(this))
                                            let ev2 = this.try_recv()
                                            match ev2:
                                                Option.some as p2:
                                                    return Result[Option[PeerEvent], Error].success(
                                                        value = Option[PeerEvent].some(value = p2.value)
                                                    )
                                                Option.none:
                                                    pass


    public async editable function send(peer_id: uint, data: span[ubyte]) -> Result[bool, Error]:
        let peer_address_result = find_peer_address(ref_of(this), peer_id)
        match peer_address_result:
            Result.failure as payload:
                return Result[bool, Error].failure(error = payload.error)
            Result.success as payload:
                var address = payload.value
                defer address.release()
                var framed = build_user_data(data)
                defer framed.release()
                let send_result = await this.host.send(address, framed.as_span())
                match send_result:
                    Result.failure as send_payload:
                        return Result[bool, Error].failure(error = chan_to_session_error(send_payload.error))
                    Result.success:
                        return Result[bool, Error].success(value = true)


    public async editable function send_reliable(peer_id: uint, data: span[ubyte], frame: uint) -> Result[bool, Error]:
        let peer_address_result = find_peer_address(ref_of(this), peer_id)
        match peer_address_result:
            Result.failure as payload:
                return Result[bool, Error].failure(error = payload.error)
            Result.success as payload:
                var address = payload.value
                defer address.release()
                var framed = build_user_data(data)
                defer framed.release()
                let send_result = await this.host.send_reliable(address, framed.as_span(), frame)
                match send_result:
                    Result.failure as send_payload:
                        return Result[bool, Error].failure(error = chan_to_session_error(send_payload.error))
                    Result.success:
                        return Result[bool, Error].success(value = true)


    public async editable function kick(peer_id: uint, reason: ubyte) -> Result[bool, Error]:
        let peer_address_result = find_peer_address(ref_of(this), peer_id)
        match peer_address_result:
            Result.failure as payload:
                return Result[bool, Error].failure(error = payload.error)
            Result.success as payload:
                var address = payload.value
                defer address.release()
                var d = build_disconnect(reason)
                defer d.release()
                let send_result = await this.host.send_reliable(address, d.as_span(), 0)
                match send_result:
                    Result.failure:
                        pass
                    Result.success:
                        pass
                mark_peer_disconnected(ref_of(this), peer_id)
                this.event_queue.push_back(PeerEvent(
                    kind = PeerEventKind.peer_left,
                    peer_id = peer_id,
                    reason = reason
                ))
                return Result[bool, Error].success(value = true)


function find_peer_address(session: ref[Session], peer_id: uint) -> Result[net.SocketAddress, Error]:
    var peer_index: ptr_uint = 0
    while peer_index < session.peers.len():
        let peer_ptr = session.peers.get(peer_index) else:
            fatal(c"session peer missing storage in address lookup")

        if unsafe: read(peer_ptr).peer_id == peer_id:
            var host_peer_index: ptr_uint = 0
            let host_peers = session.host.peers
            while host_peer_index < host_peers.len():
                let host_peer_ptr = host_peers.get(host_peer_index) else:
                    fatal(c"session host peer missing storage")
                if host_peer_index == peer_index:
                    let copy_result = unsafe: read(host_peer_ptr).address.copy()
                    match copy_result:
                        Result.failure as copy_err:
                            let copy_message = copy_err.error.message.as_str()
                            return Result[net.SocketAddress, Error].failure(
                                error = session_error(-5, copy_message)
                            )
                        Result.success as addr_payload:
                            return Result[net.SocketAddress, Error].success(value = addr_payload.value)
                host_peer_index += 1
        peer_index += 1

    return Result[net.SocketAddress, Error].failure(error = session_error(-6, "session peer not found"))


function start_recv_if_idle_session(session: ref[Session]) -> void:
    match session.pending_recv:
        Option.some:
            return
        Option.none:
            session.pending_recv = Option[ChanHostMessageTask].some(
                value = session.host.recv()
            )


function process_pending_recv_session(session: ref[Session]) -> void:
    match session.pending_recv:
        Option.none:
            return
        Option.some as task_opt:
            let task = task_opt.value
            if not aio.completed(task):
                return
            let result = aio.result(task)
            session.pending_recv = Option[ChanHostMessageTask].none
            start_recv_if_idle_session(session)
            match result:
                Result.failure:
                    return
                Result.success as result_payload:
                    let msg_opt = result_payload.value
                    match msg_opt:
                        Option.none:
                            pass
                        Option.some as msg_payload:
                            var msg = msg_payload.value
                            handle_incoming_session(session, ref_of(msg))


function handle_incoming_session(session: ref[Session], msg: ref[chan.HostMessage]) -> void:
    let span = msg.payload.as_span()
    if span.len == 0:
        msg.release()
        return

    let tag = unsafe: read(span.data)

    if tag == msg_type_connect_request:
        handle_connect_request(session, msg, span)
        return

    if tag == msg_type_user:
        let peer_result = find_peer_by_address(session, msg.source)
        match peer_result:
            Result.failure:
                msg.release()
                return
            Result.success as peer_payload:
                let peer_id = peer_payload.value
                update_peer_last_recv(session, peer_id)
                let payload_len = span.len - 1
                var payload = bytes.Bytes.empty()
                if payload_len > 0:
                    unsafe:
                        payload = bytes.Bytes.copy(span[ubyte](data = span.data + 1, len = payload_len))
                session.event_queue.push_back(PeerEvent(
                    kind = PeerEventKind.user_data,
                    peer_id = peer_id,
                    payload = payload,
                    reliable = msg.reliable,
                    reason = 0
                ))
                msg.release()
                return

    if tag == msg_type_heartbeat:
        let peer_result = find_peer_by_address(session, msg.source)
        match peer_result:
            Result.success as peer_payload:
                update_peer_last_recv(session, peer_payload.value)
                let hb_span = unsafe: span[ubyte](data = span.data + 1, len = span.len - 1)
                if hb_span.len >= 4:
                    let echoed = decode_u32_at(hb_span, 0)
                    var ack = build_heartbeat_ack(echoed)
                    let addr_result = msg.source.copy()
                    match addr_result:
                        Result.success as addr_payload:
                            session.outgoing.push_back(OutgoingMessage(
                                address = addr_payload.value,
                                payload = ack,
                                reliable = false
                            ))
                        Result.failure:
                            ack.release()
            Result.failure:
                pass
        msg.release()
        return

    if tag == msg_type_heartbeat_ack:
        let peer_result = find_peer_by_address(session, msg.source)
        match peer_result:
            Result.success as peer_payload:
                update_peer_last_recv(session, peer_payload.value)
                mark_peer_heartbeat_ack(session, peer_payload.value)
            Result.failure:
                pass
        msg.release()
        return

    if tag == msg_type_disconnect:
        let peer_result = find_peer_by_address(session, msg.source)
        match peer_result:
            Result.success as peer_payload:
                let peer_id = peer_payload.value
                mark_peer_disconnected(session, peer_id)
                session.event_queue.push_back(PeerEvent(
                    kind = PeerEventKind.peer_left,
                    peer_id = peer_id,
                    reason = disconnect_reason_remote
                ))
            Result.failure:
                pass
        msg.release()
        return

    msg.release()


function handle_connect_request(session: ref[Session], msg: ref[chan.HostMessage], span: span[ubyte]) -> void:
    let req_span = unsafe: span[ubyte](data = span.data + 1, len = span.len - 1)
    if req_span.len < 4:
        msg.release()
        return

    let client_version = decode_u32_at(req_span, 0)
    if client_version != session.config.protocol_version:
        var reject = build_connect_reject(reject_reason_version)
        let addr_result = msg.source.copy()
        match addr_result:
            Result.success as addr_payload:
                session.outgoing.push_back(OutgoingMessage(
                    address = addr_payload.value,
                    payload = reject,
                    reliable = true
                ))
            Result.failure:
                reject.release()
        msg.release()
        return

    let peer_id = session.next_peer_id
    session.next_peer_id += 1

    var accept = build_connect_accept(peer_id)
    let addr_result = msg.source.copy()
    match addr_result:
        Result.success as addr_payload:
            session.outgoing.push_back(OutgoingMessage(
                address = addr_payload.value,
                payload = accept,
                reliable = true
            ))
        Result.failure:
            accept.release()
    msg.release()

    session.peers.push(PeerConnection(
        peer_id = peer_id,
        channel_state = ConnectionState.connected,
        frame_since_last_recv = 0,
        last_heartbeat_sent = 0,
        heartbeat_ack_received = false
    ))

    session.event_queue.push_back(PeerEvent(
        kind = PeerEventKind.peer_joined,
        peer_id = peer_id
    ))


function find_peer_by_address(session: ref[Session], address: net.SocketAddress) -> Result[uint, Error]:
    var index: ptr_uint = 0
    while index < session.host.peers.len():
        let host_peer_ptr = session.host.peers.get(index) else:
            fatal(c"session host peer missing storage")

        let same_address = unsafe: read(host_peer_ptr).address.equal(address)
        if same_address:
            if index < session.peers.len():
                let session_peer_ptr = session.peers.get(index) else:
                    return Result[uint, Error].failure(error = session_error(-6, "session peer not found"))
                return Result[uint, Error].success(value = unsafe: read(session_peer_ptr).peer_id)
            return Result[uint, Error].failure(error = session_error(-6, "session peer not found"))
        index += 1

    return Result[uint, Error].failure(error = session_error(-6, "session peer not found"))


async function drain_outgoing_session(session: ref[Session]) -> Result[bool, Error]:
    while true:
        let msg = session.outgoing.pop_front()
        match msg:
            Option.none:
                return Result[bool, Error].success(value = true)
            Option.some as payload:
                var outgoing = payload.value
                defer outgoing.release()
                if outgoing.reliable:
                    let send_result = await session.host.send_reliable(
                        outgoing.address,
                        outgoing.payload.as_span(),
                        0
                    )
                    match send_result:
                        Result.failure:
                            pass
                        Result.success:
                            pass
                else:
                    let send_result = await session.host.send(
                        outgoing.address,
                        outgoing.payload.as_span()
                    )
                    match send_result:
                        Result.failure:
                            pass
                        Result.success:
                            pass


function drain_release_outgoing(session: ref[Session]) -> void:
    while true:
        let msg = session.outgoing.pop_front()
        match msg:
            Option.none:
                break
            Option.some as payload:
                var outgoing = payload.value
                outgoing.release()


function drain_release_outgoing_conn(conn: ref[Connection]) -> void:
    while true:
        let msg = conn.outgoing.pop_front()
        match msg:
            Option.none:
                break
            Option.some as payload:
                var outgoing = payload.value
                outgoing.release()


function drain_release_events(queue: ref[deque.Deque[PeerEvent]]) -> void:
    while true:
        let ev = queue.pop_front()
        match ev:
            Option.none:
                break
            Option.some as payload:
                var pe = payload.value
                if pe.kind == PeerEventKind.user_data:
                    pe.payload.release()


function mark_peer_disconnected(session: ref[Session], peer_id: uint) -> void:
    var index: ptr_uint = 0
    while index < session.peers.len():
        let peer_ptr = session.peers.get(index) else:
            return
        if unsafe: read(peer_ptr).peer_id == peer_id:
            unsafe: read(peer_ptr).channel_state = ConnectionState.disconnected
            return
        index += 1


function connected_peer_count(session: ref[Session]) -> ptr_uint:
    var count: ptr_uint = 0
    var index: ptr_uint = 0
    while index < session.peers.len():
        let peer_ptr = session.peers.get(index) else:
            return count
        if unsafe: read(peer_ptr).channel_state == ConnectionState.connected:
            count += 1
        index += 1
    return count


function update_peer_last_recv(session: ref[Session], peer_id: uint) -> void:
    var index: ptr_uint = 0
    while index < session.peers.len():
        let peer_ptr = session.peers.get(index) else:
            return
        if unsafe: read(peer_ptr).peer_id == peer_id:
            unsafe: read(peer_ptr).frame_since_last_recv = 0
            return
        index += 1


function mark_peer_heartbeat_ack(session: ref[Session], peer_id: uint) -> void:
    var index: ptr_uint = 0
    while index < session.peers.len():
        let peer_ptr = session.peers.get(index) else:
            return
        if unsafe: read(peer_ptr).peer_id == peer_id:
            unsafe: read(peer_ptr).heartbeat_ack_received = true
            return
        index += 1

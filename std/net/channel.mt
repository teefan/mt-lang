import std.async as aio
import std.bytes as bytes
import std.net as net
import std.string as string
import std.vec as vec

const header_magic: uint = 0x4D545331
const header_bytes: ptr_uint = 17
const reliable_flag: ubyte = 1
const ack_only_flag: ubyte = 2
const ack_window_size: ptr_uint = 32
const max_uint_value: ulong = 0xFFFFFFFF
const half_sequence_range: uint = 0x80000000

public struct Config:
    max_payload_bytes: ptr_uint
    max_pending_reliable: ptr_uint
    resend_after_frames: uint

public struct Message:
    sequence: uint
    reliable: bool
    payload: bytes.Bytes

public struct HostMessage:
    source: net.SocketAddress
    sequence: uint
    reliable: bool
    payload: bytes.Bytes

public struct Channel:
    socket: net.UdpSocket
    config: Config
    protocol: ProtocolState

public struct Host:
    socket: net.UdpSocket
    config: Config
    peers: vec.Vec[PeerState]

struct PacketHeader:
    sequence: uint
    ack: uint
    ack_bits: uint
    packet_flags: ubyte

struct PendingReliable:
    sequence: uint
    payload: bytes.Bytes
    last_sent_frame: uint

struct ProtocolState:
    next_sequence: uint
    received_initialized: bool
    received_sequence: uint
    received_mask: uint
    pending_reliable: vec.Vec[PendingReliable]

struct PeerState:
    address: net.SocketAddress
    protocol: ProtocolState


function encode_uint(value: uint) -> array[ubyte, 4]:
    return array[ubyte, 4](
        ubyte<-((value >> 24) & 255),
        ubyte<-((value >> 16) & 255),
        ubyte<-((value >> 8) & 255),
        ubyte<-(value & 255)
    )


function decode_uint(data: span[ubyte], offset: ptr_uint) -> uint:
    return (
            ((uint<-data[offset]) << 24)
            | ((uint<-data[offset + 1]) << 16)
            | ((uint<-data[offset + 2]) << 8)
            | (uint<-data[offset + 3])
        )


function sequence_gap(newer: uint, older: uint) -> uint:
    if newer >= older:
        return newer - older

    return uint<-((ulong<-newer) + (max_uint_value - ulong<-older) + 1)


function sequence_more_recent(left: uint, right: uint) -> bool:
    let forward_gap = sequence_gap(left, right)
    return forward_gap != 0 and forward_gap < half_sequence_range


function sequence_is_acked(sequence: uint, ack: uint, ack_bits: uint) -> bool:
    if sequence == ack:
        return true

    if sequence_more_recent(sequence, ack):
        return false

    let distance = sequence_gap(ack, sequence)
    if distance == 0 or distance > uint<-ack_window_size:
        return false

    let mask = (1u) << (distance - 1)
    return (ack_bits & mask) != 0


function create_protocol_state() -> ProtocolState:
    return ProtocolState(
            next_sequence = 0,
            received_initialized = false,
            received_sequence = 0,
            received_mask = 0,
            pending_reliable = vec.Vec[PendingReliable].create()
        )


function release_protocol_state(protocol: ptr[ProtocolState]) -> void:
    while true:
        let removed = unsafe: read(protocol).pending_reliable.pop()
        if removed.is_none():
            break
        var entry = removed.unwrap()
        entry.payload.release()

    unsafe: read(protocol).pending_reliable.release()


function release_peer_state(peer: ptr[PeerState]) -> void:
    let protocol = unsafe: ptr[ProtocolState]<-ptr_of(read(peer).protocol)
    release_protocol_state(protocol)
    unsafe: read(peer).address.release()


function allocate_sequence(protocol: ptr[ProtocolState]) -> uint:
    let sequence = unsafe: read(protocol).next_sequence
    unsafe: read(protocol).next_sequence += 1
    return sequence


function pending_window_limit(config: Config) -> ptr_uint:
    if config.max_pending_reliable < ack_window_size:
        return config.max_pending_reliable

    return ack_window_size


function build_packet(
    sequence: uint,
    ack: uint,
    ack_bits: uint,
    packet_flags: ubyte,
    content: span[ubyte]
) -> bytes.Bytes:
    var buffer = vec.Vec[ubyte].with_capacity(header_bytes + content.len)
    defer buffer.release()

    buffer.append_array(encode_uint(header_magic))
    buffer.append_array(encode_uint(sequence))
    buffer.append_array(encode_uint(ack))
    buffer.append_array(encode_uint(ack_bits))
    buffer.push(packet_flags)
    buffer.append_span(content)
    return bytes.Bytes.copy(buffer.as_span())


function decode_header(packet: bytes.Bytes) -> Result[PacketHeader, net.Error]:
    if packet.len < header_bytes:
        return Result[PacketHeader, net.Error].failure(error = net.Error(
            code = -1,
            message = string.String.from_str("udp channel packet is too small")
        ))

    let packet_span = packet.as_span()
    let magic = decode_uint(packet_span, 0)
    if magic != header_magic:
        return Result[PacketHeader, net.Error].failure(error = net.Error(
            code = -1,
            message = string.String.from_str("udp channel packet has an invalid header")
        ))

    return Result[PacketHeader, net.Error].success(value = PacketHeader(
            sequence = decode_uint(packet_span, 4),
            ack = decode_uint(packet_span, 8),
            ack_bits = decode_uint(packet_span, 12),
            packet_flags = packet_span[16]
        ))


function copy_payload(packet: bytes.Bytes) -> bytes.Bytes:
    if packet.len == header_bytes:
        return bytes.Bytes.empty()

    let packet_span = packet.as_span()
    unsafe:
        return bytes.Bytes.copy(span[ubyte](
            data = packet_span.data + header_bytes,
            len = packet_span.len - header_bytes
        ))


function remove_acked_pending(protocol: ptr[ProtocolState], ack: uint, ack_bits: uint) -> void:
    var index: ptr_uint = 0
    while true:
        let pending_len = unsafe: read(protocol).pending_reliable.len()
        if index >= pending_len:
            break

        let entry_ptr = unsafe: read(protocol).pending_reliable.get(index) else:
            fatal(c"udp channel pending entry missing storage")

        if sequence_is_acked(unsafe: read(entry_ptr).sequence, ack, ack_bits):
            let removed = unsafe: read(protocol).pending_reliable.remove(index)
            var entry = removed.expect("udp channel pending entry removal failed")
            entry.payload.release()
            continue

        index += 1


function mark_received(protocol: ptr[ProtocolState], sequence: uint) -> bool:
    let received_initialized = unsafe: read(protocol).received_initialized
    if not received_initialized:
        unsafe:
            read(protocol).received_initialized = true
            read(protocol).received_sequence = sequence
            read(protocol).received_mask = 0
        return true

    let current_sequence = unsafe: read(protocol).received_sequence
    if sequence == current_sequence:
        return false

    if sequence_more_recent(sequence, current_sequence):
        let distance = sequence_gap(sequence, current_sequence)
        if distance > uint<-ack_window_size:
            unsafe: read(protocol).received_mask = 0
        else:
            if distance < uint<-ack_window_size:
                unsafe: read(protocol).received_mask = read(protocol).received_mask << distance
            else:
                unsafe: read(protocol).received_mask = 0

            unsafe: read(protocol).received_mask |= (1) << (distance - 1)

        unsafe: read(protocol).received_sequence = sequence
        return true

    let current_mask = unsafe: read(protocol).received_mask
    let distance = sequence_gap(current_sequence, sequence)
    if distance == 0 or distance > uint<-ack_window_size:
        return false

    let mask = (1u) << (distance - 1)
    if (current_mask & mask) != 0:
        return false

    unsafe: read(protocol).received_mask |= mask
    return true


async function send_connected_packet(
    socket: net.UdpSocket,
    protocol: ptr[ProtocolState],
    sequence: uint,
    packet_flags: ubyte,
    content: span[ubyte]
) -> Result[bool, net.Error]:
    var ack: uint = 0
    var ack_bits: uint = 0
    let received_initialized = unsafe: read(protocol).received_initialized
    if received_initialized:
        ack = unsafe: read(protocol).received_sequence
        ack_bits = unsafe: read(protocol).received_mask

    var framed = build_packet(sequence, ack, ack_bits, packet_flags, content)
    defer framed.release()

    (await socket.send(framed.as_span()))?
    return Result[bool, net.Error].success(value = true)


async function send_packet_to(
    socket: net.UdpSocket,
    destination: net.SocketAddress,
    protocol: ptr[ProtocolState],
    sequence: uint,
    packet_flags: ubyte,
    content: span[ubyte]
) -> Result[bool, net.Error]:
    var ack: uint = 0
    var ack_bits: uint = 0
    let received_initialized = unsafe: read(protocol).received_initialized
    if received_initialized:
        ack = unsafe: read(protocol).received_sequence
        ack_bits = unsafe: read(protocol).received_mask

    var framed = build_packet(sequence, ack, ack_bits, packet_flags, content)
    defer framed.release()

    (await socket.send_to(framed.as_span(), destination))?
    return Result[bool, net.Error].success(value = true)


async function send_connected_ack_only(socket: net.UdpSocket, protocol: ptr[ProtocolState]) -> Result[bool, net.Error]:
    let sequence = allocate_sequence(protocol)
    return await send_connected_packet(socket, protocol, sequence, ack_only_flag, bytes.Bytes.empty().as_span())


async function send_ack_only_to(
    socket: net.UdpSocket,
    destination: net.SocketAddress,
    protocol: ptr[ProtocolState]
) -> Result[bool, net.Error]:
    let sequence = allocate_sequence(protocol)
    return await send_packet_to(socket, destination, protocol, sequence, ack_only_flag, bytes.Bytes.empty().as_span())


function find_peer_index(host: ref[Host], address: net.SocketAddress) -> Option[ptr_uint]:
    var index: ptr_uint = 0
    while index < host.peers.len():
        let peer_ptr = host.peers.get(index) else:
            fatal(c"udp channel host peer missing storage")

        let same_address = unsafe: read(peer_ptr).address.equal(address)
        if same_address:
            return Option[ptr_uint].some(value = index)

        index += 1

    return Option[ptr_uint].none


function get_or_create_peer(host: ref[Host], address: net.SocketAddress) -> Result[ptr[PeerState], net.Error]:
    match find_peer_index(host, address):
        Option.some as payload:
            let peer_ptr = host.peers.get(payload.value) else:
                fatal(c"udp channel host peer lookup missing storage")
            return Result[ptr[PeerState], net.Error].success(value = peer_ptr)
        Option.none:
            let addr = address.copy()?
            host.peers.push(PeerState(address = addr, protocol = create_protocol_state()))
            let peer_ptr = host.peers.last() else:
                fatal(c"udp channel host peer insertion missing storage")
            return Result[ptr[PeerState], net.Error].success(value = peer_ptr)


public function wrap_connected(socket: net.UdpSocket, config: Config) -> Channel:
    return Channel(socket = socket, config = config, protocol = create_protocol_state())


public function connect_on(
    runtime: aio.Runtime,
    local_address: net.SocketAddress,
    remote_address: net.SocketAddress,
    config: Config
) -> Result[Channel, net.Error]:
    var socket = net.udp_bind_on(runtime, local_address)?
    match socket.connect(remote_address):
        Result.failure as connect_payload:
            socket.release()
            return Result[Channel, net.Error].failure(error = connect_payload.error)
        Result.success as connect_payload:
            if not connect_payload.value:
                socket.release()
                return Result[Channel, net.Error].failure(error = net.Error(
                    code = -1,
                    message = string.String.from_str("udp connect did not complete")
                ))
            return Result[Channel, net.Error].success(value = wrap_connected(socket, config))


public function connect(
    local_address: net.SocketAddress,
    remote_address: net.SocketAddress,
    config: Config
) -> Result[Channel, net.Error]:
    return connect_on(aio.current_runtime(), local_address, remote_address, config)


public function listen_on(
    runtime: aio.Runtime,
    local_address: net.SocketAddress,
    config: Config
) -> Result[Host, net.Error]:
    let socket = net.udp_bind_on(runtime, local_address)?
    return Result[Host, net.Error].success(value = Host(
        socket = socket,
        config = config,
        peers = vec.Vec[PeerState].create()
    ))


public function listen(local_address: net.SocketAddress, config: Config) -> Result[Host, net.Error]:
    return listen_on(aio.current_runtime(), local_address, config)


extending Config:
    public static function default(max_payload_bytes: ptr_uint) -> Config:
        return Config(
            max_payload_bytes = max_payload_bytes,
            max_pending_reliable = ack_window_size,
            resend_after_frames = 5
        )


extending Message:
    public editable function release() -> void:
        this.payload.release()


extending HostMessage:
    public editable function release() -> void:
        this.payload.release()
        this.source.release()


extending Channel:
    public editable function release() -> void:
        let protocol = unsafe: ptr[ProtocolState]<-ptr_of(this.protocol)
        release_protocol_state(protocol)
        this.socket.release()


    public function local_address() -> Result[net.SocketAddress, net.Error]:
        return this.socket.local_address()


    public function peer_address() -> Result[net.SocketAddress, net.Error]:
        return this.socket.peer_address()


    public function pending_reliable_len() -> ptr_uint:
        return this.protocol.pending_reliable.len()


    public async editable function send(content: span[ubyte]) -> Result[uint, net.Error]:
        if content.len > this.config.max_payload_bytes:
            return Result[uint, net.Error].failure(error = net.Error(
                code = -2,
                message = string.String.from_str("udp channel payload exceeds configured maximum")
            ))

        let protocol = unsafe: ptr[ProtocolState]<-ptr_of(this.protocol)
        let sequence = allocate_sequence(protocol)
        (await send_connected_packet(this.socket, protocol, sequence, 0, content))?
        return Result[uint, net.Error].success(value = sequence)


    public async editable function send_reliable(content: span[ubyte], frame: uint) -> Result[uint, net.Error]:
        if content.len > this.config.max_payload_bytes:
            return Result[uint, net.Error].failure(error = net.Error(
                code = -2,
                message = string.String.from_str("udp channel payload exceeds configured maximum")
            ))

        let protocol = unsafe: ptr[ProtocolState]<-ptr_of(this.protocol)
        let pending_len = unsafe: read(protocol).pending_reliable.len()
        if pending_len >= pending_window_limit(this.config):
            return Result[uint, net.Error].failure(error = net.Error(
                code = -3,
                message = string.String.from_str("udp channel reliable window is full")
            ))

        let sequence = allocate_sequence(protocol)
        (await send_connected_packet(this.socket, protocol, sequence, reliable_flag, content))?
        unsafe: read(protocol).pending_reliable.push(PendingReliable(
            sequence = sequence,
            payload = bytes.Bytes.copy(content),
            last_sent_frame = frame
        ))
        return Result[uint, net.Error].success(value = sequence)


    public async editable function recv() -> Result[Option[Message], net.Error]:
        var packet = (await this.socket.recv(this.config.max_payload_bytes + header_bytes))?
        defer packet.release()

        let header = decode_header(packet)?
        let protocol = unsafe: ptr[ProtocolState]<-ptr_of(this.protocol)
        remove_acked_pending(protocol, header.ack, header.ack_bits)
        let is_new = mark_received(protocol, header.sequence)
        let is_reliable = (header.packet_flags & reliable_flag) != 0
        if is_reliable:
            (await send_connected_ack_only(this.socket, protocol))?

        if (header.packet_flags & ack_only_flag) != 0:
            return Result[Option[Message], net.Error].success(value = Option[Message].none)

        if not is_new:
            return Result[Option[Message], net.Error].success(value = Option[Message].none)

        return Result[Option[Message], net.Error].success(value = Option[Message].some(value = Message(
                sequence = header.sequence,
                reliable = is_reliable,
                payload = copy_payload(packet)
            )))


    public async editable function tick(frame: uint) -> Result[ptr_uint, net.Error]:
        let protocol = unsafe: ptr[ProtocolState]<-ptr_of(this.protocol)
        var resent: ptr_uint = 0
        var index: ptr_uint = 0
        while true:
            let pending_len = unsafe: read(protocol).pending_reliable.len()
            if index >= pending_len:
                break

            let entry_ptr = unsafe: read(protocol).pending_reliable.get(index) else:
                fatal(c"udp channel pending entry missing storage")

            let last_sent_frame = unsafe: read(entry_ptr).last_sent_frame
            if sequence_gap(frame, last_sent_frame) < this.config.resend_after_frames:
                index += 1
                continue

            (await send_connected_packet(
                this.socket,
                protocol,
                unsafe: read(entry_ptr).sequence,
                reliable_flag,
                unsafe: read(entry_ptr).payload.as_span()
            ))?
            unsafe: read(entry_ptr).last_sent_frame = frame
            resent += 1

            index += 1

        return Result[ptr_uint, net.Error].success(value = resent)


extending Host:
    public editable function release() -> void:
        while true:
            let removed = this.peers.pop()
            if removed.is_none():
                break
            var peer = removed.unwrap()
            let peer_ptr = unsafe: ptr[PeerState]<-ptr_of(peer)
            release_peer_state(peer_ptr)

        this.peers.release()
        this.socket.release()


    public function local_address() -> Result[net.SocketAddress, net.Error]:
        return this.socket.local_address()


    public function peer_count() -> ptr_uint:
        return this.peers.len()


    public function pending_reliable_len() -> ptr_uint:
        var total: ptr_uint = 0
        var index: ptr_uint = 0
        while index < this.peers.len():
            let peer_ptr = this.peers.get(index) else:
                fatal(c"udp channel host peer missing storage")

            let protocol = unsafe: ptr[ProtocolState]<-ptr_of(read(peer_ptr).protocol)
            total += unsafe: read(protocol).pending_reliable.len()
            index += 1

        return total


    public async editable function send(
        destination: net.SocketAddress,
        content: span[ubyte]
    ) -> Result[uint, net.Error]:
        if content.len > this.config.max_payload_bytes:
            return Result[uint, net.Error].failure(error = net.Error(
                code = -2,
                message = string.String.from_str("udp channel payload exceeds configured maximum")
            ))

        let peer_ptr = get_or_create_peer(ref_of(this), destination)?
        let protocol = unsafe: ptr[ProtocolState]<-ptr_of(read(peer_ptr).protocol)
        let sequence = allocate_sequence(protocol)
        (await send_packet_to(
            this.socket,
            unsafe: read(peer_ptr).address,
            protocol,
            sequence,
            0,
            content
        ))?
        return Result[uint, net.Error].success(value = sequence)


    public async editable function send_reliable(
        destination: net.SocketAddress,
        content: span[ubyte],
        frame: uint
    ) -> Result[uint, net.Error]:
        if content.len > this.config.max_payload_bytes:
            return Result[uint, net.Error].failure(error = net.Error(
                code = -2,
                message = string.String.from_str("udp channel payload exceeds configured maximum")
            ))

        let peer_ptr = get_or_create_peer(ref_of(this), destination)?
        let protocol = unsafe: ptr[ProtocolState]<-ptr_of(read(peer_ptr).protocol)
        let pending_len = unsafe: read(protocol).pending_reliable.len()
        if pending_len >= pending_window_limit(this.config):
            return Result[uint, net.Error].failure(error = net.Error(
                code = -3,
                message = string.String.from_str("udp channel reliable window is full")
            ))

        let sequence = allocate_sequence(protocol)
        (await send_packet_to(
            this.socket,
            unsafe: read(peer_ptr).address,
            protocol,
            sequence,
            reliable_flag,
            content
        ))?
        unsafe: read(protocol).pending_reliable.push(PendingReliable(
            sequence = sequence,
            payload = bytes.Bytes.copy(content),
            last_sent_frame = frame
        ))
        return Result[uint, net.Error].success(value = sequence)


    public async editable function recv() -> Result[Option[HostMessage], net.Error]:
        var datagram = (await this.socket.recv_from(this.config.max_payload_bytes + header_bytes))?

        let header_result = decode_header(datagram.data)
        match header_result:
            Result.failure as header_payload:
                datagram.release()
                return Result[Option[HostMessage], net.Error].failure(error = header_payload.error)
            Result.success as header_payload:
                let peer_result = get_or_create_peer(ref_of(this), datagram.source)
                match peer_result:
                    Result.failure as peer_payload:
                        datagram.release()
                        return Result[Option[HostMessage], net.Error].failure(error = peer_payload.error)
                    Result.success as peer_payload:
                        let peer_ptr = peer_payload.value
                        let protocol = unsafe: ptr[ProtocolState]<-ptr_of(read(peer_ptr).protocol)
                        let header = header_payload.value
                        remove_acked_pending(protocol, header.ack, header.ack_bits)
                        let is_new = mark_received(protocol, header.sequence)
                        let is_reliable = (header.packet_flags & reliable_flag) != 0
                        if is_reliable:
                            let ack_result = await send_ack_only_to(this.socket, datagram.source, protocol)
                            match ack_result:
                                Result.failure as ack_payload:
                                    datagram.release()
                                    return Result[
                                        Option[HostMessage],
                                        net.Error
                                    ].failure(error = ack_payload.error)
                                Result.success as ack_payload:
                                    ack_payload.value

                        if (header.packet_flags & ack_only_flag) != 0:
                            datagram.release()
                            return Result[
                                Option[HostMessage],
                                net.Error
                            ].success(value = Option[HostMessage].none)

                        if not is_new:
                            datagram.release()
                            return Result[
                                Option[HostMessage],
                                net.Error
                            ].success(value = Option[HostMessage].none)

                        let payload = copy_payload(datagram.data)
                        datagram.data.release()
                        return Result[
                            Option[HostMessage],
                            net.Error
                        ].success(value = Option[HostMessage].some(value = HostMessage(
                                source = datagram.source,
                                sequence = header.sequence,
                                reliable = is_reliable,
                                payload = payload
                            )))


    public async editable function tick(frame: uint) -> Result[ptr_uint, net.Error]:
        var resent: ptr_uint = 0
        var peer_index: ptr_uint = 0
        while peer_index < this.peers.len():
            let peer_ptr = this.peers.get(peer_index) else:
                fatal(c"udp channel host peer missing storage")

            let protocol = unsafe: ptr[ProtocolState]<-ptr_of(read(peer_ptr).protocol)
            var index: ptr_uint = 0
            while true:
                let pending_len = unsafe: read(protocol).pending_reliable.len()
                if index >= pending_len:
                    break

                let entry_ptr = unsafe: read(protocol).pending_reliable.get(index) else:
                    fatal(c"udp channel pending entry missing storage")

                let last_sent_frame = unsafe: read(entry_ptr).last_sent_frame
                if sequence_gap(frame, last_sent_frame) < this.config.resend_after_frames:
                    index += 1
                    continue

                (await send_packet_to(
                    this.socket,
                    unsafe: read(peer_ptr).address,
                    protocol,
                    unsafe: read(entry_ptr).sequence,
                    reliable_flag,
                    unsafe: read(entry_ptr).payload.as_span()
                ))?
                unsafe: read(entry_ptr).last_sent_frame = frame
                resent += 1

                index += 1

            peer_index += 1

        return Result[ptr_uint, net.Error].success(value = resent)

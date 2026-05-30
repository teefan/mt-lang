import std.multiplayer.protocol as protocol
import std.multiplayer.registry as registry
import std.multiplayer.wire as wire
import std.bytes as bytes
import std.vec as vec

const rpc_header_bytes: ptr_uint = 9

public struct OutgoingRpc:
    descriptor: registry.RpcDescriptor
    context: protocol.RpcContext
    payload_size: ptr_uint

public struct IncomingRpc:
    descriptor: registry.RpcDescriptor
    context: protocol.RpcContext
    payload_size: ptr_uint

public struct DispatchError:
    code: protocol.ErrorCode
    message: str

public struct RpcDispatchRoute:
    descriptor: registry.RpcDescriptor
    handler: fn(message: IncomingRpc) -> Result[bool, DispatchError]

public struct RpcDispatchTable:
    routes: vec.Vec[RpcDispatchRoute]

public struct IncomingRpcPacket:
    header: protocol.RpcPacketHeader
    context: protocol.RpcContext
    payload: bytes.Bytes


extending RpcDispatchTable:
    public static function create() -> RpcDispatchTable:
        return RpcDispatchTable(routes = vec.Vec[RpcDispatchRoute].create())


    public function route_count() -> ptr_uint:
        return this.routes.len()


    public mutable function release() -> void:
        this.routes.release()


    public mutable function register_route(
        descriptor: registry.RpcDescriptor,
        handler: fn(message: IncomingRpc) -> Result[bool, DispatchError],
    ) -> Result[bool, protocol.Error]:
        if find_route(this.routes.as_span(), descriptor) != null:
            return Result[bool, protocol.Error].failure(
                error = protocol.error(
                    protocol.ErrorCode.already_registered,
                    "rpc dispatch route is already registered"
                )
            )

        this.routes.push(RpcDispatchRoute(
            descriptor = descriptor,
            handler = handler
        ))
        return Result[bool, protocol.Error].success(value = true)


    public function dispatch(message: IncomingRpc) -> Result[bool, DispatchError]:
        return dispatch_with_routes(this.routes.as_span(), message)


public function encode_outgoing(message: OutgoingRpc) -> Result[OutgoingRpc, protocol.Error]:
    let _ = validate_outgoing(message) else as validation_error:
        return Result[OutgoingRpc, protocol.Error].failure(
            error = validation_error,
        )

    return Result[OutgoingRpc, protocol.Error].success(value = message)


public function decode_incoming(message: IncomingRpc) -> Result[IncomingRpc, protocol.Error]:
    let _ = validate_incoming(message) else as validation_error:
        return Result[IncomingRpc, protocol.Error].failure(
            error = validation_error,
        )

    return Result[IncomingRpc, protocol.Error].success(value = message)


public function dispatch(message: IncomingRpc) -> Result[bool, DispatchError]:
    var table = RpcDispatchTable.create()
    defer table.release()
    return table.dispatch(message)


public function dispatch_with_routes(
    routes: span[RpcDispatchRoute],
    message: IncomingRpc,
) -> Result[bool, DispatchError]:
    let _ = decode_incoming(message) else as decode_error:
        return Result[bool, DispatchError].failure(
            error = dispatch_error(decode_error.code, decode_error.message),
        )

    if message.descriptor.require_owner and not sender_present(message.context.sender):
        return Result[bool, DispatchError].failure(
            error = dispatch_error(
                protocol.ErrorCode.invalid_argument,
                "rpc dispatch requires a sender when descriptor requires owner"
            )
        )

    let route = find_route(routes, message.descriptor) else:
        return Result[bool, DispatchError].failure(
            error = dispatch_error(
                protocol.ErrorCode.not_registered,
                "rpc dispatch route is not registered",
            ),
        )

    unsafe:
        let handler = read(route).handler
        return handler(message)


public function dispatch_typed_payload(
    target: callable_handle,
    context: protocol.RpcContext,
    payload: span[ubyte],
) -> Result[bool, DispatchError]:
    fatal(c"std.multiplayer.rpc.dispatch_typed_payload is compiler-lowered and must be called with callable_of(name), RpcContext, and rpc payload bytes")


public function context_satisfies_owner_requirement(
    require_owner: bool,
    context: protocol.RpcContext,
) -> bool:
    if not require_owner:
        return true

    return sender_present(context.sender)


public function encode_header(header: protocol.RpcPacketHeader) -> array[ubyte, 9]:
    let channel = wire.encode_u32_be(header.channel)
    let payload_size = wire.encode_u32_be(uint<-header.payload_size)
    return array[ubyte, 9](
        channel[0],
        channel[1],
        channel[2],
        channel[3],
        ubyte<-header.direction,
        payload_size[0],
        payload_size[1],
        payload_size[2],
        payload_size[3]
    )


public function decode_header(input: span[ubyte]) -> Result[protocol.RpcPacketHeader, protocol.Error]:
    if input.len < rpc_header_bytes:
        return Result[protocol.RpcPacketHeader, protocol.Error].failure(
            error = protocol.error(protocol.ErrorCode.invalid_argument, "rpc packet is too small")
        )

    let direction = decode_direction(input[4]) else as direction_error:
        return Result[protocol.RpcPacketHeader, protocol.Error].failure(
            error = direction_error,
        )

    return Result[protocol.RpcPacketHeader, protocol.Error].success(
        value = protocol.RpcPacketHeader(
            channel = wire.decode_u32_be(input, 0),
            direction = direction,
            payload_size = ptr_uint<-wire.decode_u32_be(input, 5)
        )
    )


public function build_payload(header: protocol.RpcPacketHeader, payload: span[ubyte]) -> bytes.Bytes:
    var combined = vec.Vec[ubyte].with_capacity(rpc_header_bytes + payload.len)
    defer combined.release()

    combined.append_array(encode_header(header))
    combined.append_span(payload)
    let combined_span = combined.as_span()
    return bytes.Bytes.copy(combined_span)


public function enqueue_incoming(
    queue: ref[vec.Vec[IncomingRpcPacket]],
    sender: Option[protocol.ConnectionId],
    channel: uint,
    direction: protocol.RpcDirection,
    payload: span[ubyte],
) -> Result[bool, protocol.Error]:
    let header = decode_header(payload) else as header_error:
        return Result[bool, protocol.Error].failure(error = header_error)

    if header.channel != channel:
        return Result[bool, protocol.Error].failure(
            error = protocol.error(protocol.ErrorCode.invalid_argument, "rpc channel does not match transport channel")
        )

    if header.direction != direction:
        return Result[bool, protocol.Error].failure(
            error = protocol.error(
                protocol.ErrorCode.invalid_argument,
                "rpc direction does not match transport context"
            )
        )

    unsafe:
        let body_len = payload.len - rpc_header_bytes
        if header.payload_size != body_len:
            return Result[bool, protocol.Error].failure(
                error = protocol.error(protocol.ErrorCode.invalid_argument, "rpc payload size does not match header")
            )

        let body = span[ubyte](data = payload.data + rpc_header_bytes, len = body_len)
        queue.push(IncomingRpcPacket(
            header = header,
            context = protocol.RpcContext(sender = sender, tick = 0),
            payload = bytes.Bytes.copy(body)
        ))

    return Result[bool, protocol.Error].success(value = true)


public function dequeue_incoming(queue: ref[vec.Vec[IncomingRpcPacket]]) -> Option[IncomingRpcPacket]:
    if queue.len() == 0:
        return Option[IncomingRpcPacket].none

    match queue.remove(0):
        Option.some as payload:
            return Option[IncomingRpcPacket].some(value = payload.value)
        Option.none:
            return Option[IncomingRpcPacket].none


public function release_queue(queue: ref[vec.Vec[IncomingRpcPacket]]) -> void:
    while true:
        match queue.pop():
            Option.some as payload:
                var packet = payload.value
                packet.payload.release()
            Option.none:
                queue.release()
                return


extending IncomingRpcPacket:
    public mutable function release() -> void:
        this.payload.release()


function decode_direction(raw: ubyte) -> Result[protocol.RpcDirection, protocol.Error]:
    if raw == ubyte<-protocol.RpcDirection.client_to_server:
        return Result[protocol.RpcDirection, protocol.Error].success(value = protocol.RpcDirection.client_to_server)
    if raw == ubyte<-protocol.RpcDirection.server_to_owner:
        return Result[protocol.RpcDirection, protocol.Error].success(value = protocol.RpcDirection.server_to_owner)
    if raw == ubyte<-protocol.RpcDirection.server_to_connection:
        return Result[protocol.RpcDirection, protocol.Error].success(value = protocol.RpcDirection.server_to_connection)
    if raw == ubyte<-protocol.RpcDirection.server_to_observers:
        return Result[protocol.RpcDirection, protocol.Error].success(value = protocol.RpcDirection.server_to_observers)
    if raw == ubyte<-protocol.RpcDirection.server_to_all:
        return Result[protocol.RpcDirection, protocol.Error].success(value = protocol.RpcDirection.server_to_all)

    return Result[protocol.RpcDirection, protocol.Error].failure(
        error = protocol.error(protocol.ErrorCode.invalid_argument, "rpc direction value is invalid")
    )


function find_route(
    routes: span[RpcDispatchRoute],
    descriptor: registry.RpcDescriptor,
) -> ptr[RpcDispatchRoute]?:
    var index: ptr_uint = 0
    while index < routes.len:
        unsafe:
            let route = routes.data + index
            if same_rpc_descriptor(read(route).descriptor, descriptor):
                return route
        index += 1

    return null


function same_rpc_descriptor(
    left: registry.RpcDescriptor,
    right: registry.RpcDescriptor,
) -> bool:
    return left.schema_hash == right.schema_hash and left.name == right.name


function validate_outgoing(message: OutgoingRpc) -> Result[bool, protocol.Error]:
    return validate_payload_size(message.payload_size)


function validate_incoming(message: IncomingRpc) -> Result[bool, protocol.Error]:
    let _ = validate_payload_size(message.payload_size) else as payload_error:
        return Result[bool, protocol.Error].failure(error = payload_error)

    if message.payload_size != message.descriptor.payload_size:
        return Result[bool, protocol.Error].failure(
            error = protocol.error(
                protocol.ErrorCode.invalid_argument,
                "rpc payload size does not match descriptor payload_size"
            )
        )

    if message.descriptor.decode_payload_binding != registry.expected_rpc_decode_payload_binding(message.descriptor):
        return Result[bool, protocol.Error].failure(
            error = protocol.error(
                protocol.ErrorCode.invalid_argument,
                "rpc descriptor decode_payload binding mismatch"
            )
        )

    if message.descriptor.dispatch_typed_binding != registry.expected_rpc_dispatch_typed_binding(message.descriptor):
        return Result[bool, protocol.Error].failure(
            error = protocol.error(
                protocol.ErrorCode.invalid_argument,
                "rpc descriptor dispatch_typed binding mismatch"
            )
        )

    if (
        message.descriptor.direction == protocol.RpcDirection.client_to_server
        and not sender_present(message.context.sender)
    ):
        return Result[bool, protocol.Error].failure(
            error = protocol.error(
                protocol.ErrorCode.invalid_argument,
                "incoming client_to_server rpc requires sender connection"
            )
        )

    return Result[bool, protocol.Error].success(value = true)


function validate_payload_size(payload_size: ptr_uint) -> Result[bool, protocol.Error]:
    if payload_size > 0xffffffff:
        return Result[bool, protocol.Error].failure(
            error = protocol.error(protocol.ErrorCode.invalid_argument, "rpc payload size exceeds 32-bit wire header")
        )

    return Result[bool, protocol.Error].success(value = true)


function dispatch_error(code: protocol.ErrorCode, message: str) -> DispatchError:
    return DispatchError(code = code, message = message)


function sender_present(sender: Option[protocol.ConnectionId]) -> bool:
    match sender:
        Option.some:
            return true
        Option.none:
            return false

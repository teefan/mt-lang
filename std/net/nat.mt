import std.net as net
import std.net.stun as stun
import std.string as string

const google_primary: str = "stun.l.google.com"
const google_alternate: str = "stun1.l.google.com"
const google_port: int = 19302

const err_resolve: int = -1
const err_bind: int = -2
const err_discover: int = -3
const err_blocked: int = -4

public enum NatType: ubyte
    blocked = 0
    open_internet = 1
    cone = 2
    symmetric = 3

public struct NatResult:
    nat_type: NatType
    public_address: net.SocketAddress

public struct Error:
    code: int
    message: string.String


extending Error:
    public editable function release() -> void:
        this.message.release()


extending NatResult:
    public editable function release() -> void:
        this.public_address.release()


function nat_error(code: int, msg: str) -> Error:
    return Error(code = code, message = string.String.from_str(msg))


public async function detect(
    socket: net.UdpSocket,
    primary_server: net.SocketAddress,
    alternate_server: net.SocketAddress
) -> Result[NatResult, Error]:
    let primary_result = await stun.resolve_public_address(socket, primary_server)
    match primary_result:
        Result.failure:
            return Result[NatResult, Error].failure(
                error = nat_error(err_blocked, "UDP blocked or STUN unreachable")
            )
        Result.success as pr:
            var public_1 = pr.value
            defer public_1.release()

            let local_result = socket.local_address()
            match local_result:
                Result.failure:
                    return Result[NatResult, Error].failure(
                        error = nat_error(err_bind, "failed to get local address")
                    )
                Result.success as lp:
                    if public_1.public_address.equal(lp.value):
                        return Result[NatResult, Error].success(
                            value = NatResult(
                                nat_type = NatType.open_internet,
                                public_address = public_1.public_address
                            )
                        )

                    let alt_result_output = await stun.resolve_public_address(socket, alternate_server)
                    match alt_result_output:
                        Result.failure:
                            return Result[NatResult, Error].failure(
                                error = nat_error(err_discover, "alternate STUN probe failed")
                            )
                        Result.success as ar:
                            var public_2 = ar.value
                            defer public_2.release()

                            if not public_1.public_address.equal(public_2.public_address):
                                return Result[NatResult, Error].success(
                                    value = NatResult(
                                        nat_type = NatType.symmetric,
                                        public_address = public_1.public_address
                                    )
                                )

                            return Result[NatResult, Error].success(
                                value = NatResult(
                                    nat_type = NatType.cone,
                                    public_address = public_1.public_address
                                )
                            )


public async function detect_default(
    socket: net.UdpSocket
) -> Result[NatResult, Error]:
    let primary_result = net.ipv4(google_primary, google_port)
    match primary_result:
        Result.failure:
            return Result[NatResult, Error].failure(
                error = nat_error(err_resolve, "failed to resolve primary STUN server")
            )
        Result.success as pp:
            var primary = pp.value
            defer primary.release()

            let alt_result = net.ipv4(google_alternate, google_port)
            match alt_result:
                Result.failure:
                    return Result[NatResult, Error].failure(
                        error = nat_error(err_resolve, "failed to resolve alternate STUN server")
                    )
                Result.success as ap:
                    var alternate = ap.value
                    defer alternate.release()

                    return await detect(socket, primary, alternate)

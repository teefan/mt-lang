import std.async as aio
import std.net as net
import std.net.discovery as net_disc
import std.net.manager as mgr
import std.vec as vec
import std.stdio as stdio

const GAME_PORT: int = 12345

async function main() -> int:
    stdio.print("HOST: creating server\n")

    match net.ipv4("0.0.0.0", GAME_PORT):
        Result.failure:
            stdio.print("FAIL: addr\n")
            return -1
        Result.success as addr_p:
            let config = mgr.NetworkConfig.default(ptr_uint<-1400)
            match mgr.create_server(addr_p.value, config):
                Result.failure:
                    stdio.print("FAIL: server\n")
                    return -2
                Result.success as mgr_p:
                    var host_mgr = mgr_p.value
                    stdio.print("HOST: listening\n")

                    stdio.print("HOST: starting announce\n")
                    var _announce = net_disc.announce(GAME_PORT, ubyte<-4, "Test")

                    stdio.print("CLIENT: discovering\n")
                    match await net_disc.discover(GAME_PORT, uint<-120):
                        Result.failure:
                            stdio.print("FAIL: discover\n")
                            host_mgr.release()
                            return -3
                        Result.success as servers_p:
                            var servers = servers_p.value
                            defer servers.release()

                            if servers.len() == ptr_uint<-0:
                                stdio.print("FAIL: no servers\n")
                                host_mgr.release()
                                return -4

                            let first_ptr = servers.get(ptr_uint<-0) else:
                                stdio.print("FAIL: get server\n")
                                host_mgr.release()
                                return -5

                            let info = unsafe: read(first_ptr)
                            stdio.print("CLIENT: found server\n")

                            match net.ipv4("127.0.0.1", 0):
                                Result.failure:
                                    stdio.print("FAIL: local addr\n")
                                    host_mgr.release()
                                    return -6
                                Result.success as la_p:
                                    match net.ipv4("127.0.0.1", info.game_port):
                                        Result.failure:
                                            stdio.print("FAIL: remote addr\n")
                                            host_mgr.release()
                                            return -7
                                        Result.success as sa_p:
                                            let cli_cfg = mgr.NetworkConfig.default(ptr_uint<-1400)
                                            match mgr.create_client(la_p.value, sa_p.value, cli_cfg):
                                                Result.failure:
                                                    stdio.print("FAIL: client\n")
                                                    host_mgr.release()
                                                    return -8
                                                Result.success as cli_p:
                                                    var client_mgr = cli_p.value
                                                    stdio.print("CLIENT: connecting\n")

                                                    var host_ok = false
                                                    var client_ok = false
                                                    var frame: uint = 0
                                                    while frame < 600:
                                                        let _ = await host_mgr.tick(frame)
                                                        while true:
                                                            let ev = host_mgr.try_recv()
                                                            match ev:
                                                                Option.some as ev_p:
                                                                    if ev_p.value.kind == mgr.NetworkEventKind.player_joined:
                                                                        stdio.print("HOST: joined ticks=%d\n", uint<-frame)
                                                                        host_ok = true
                                                                Option.none:
                                                                    break

                                                        let _ = await client_mgr.tick(frame)
                                                        while true:
                                                            let ev = client_mgr.try_recv()
                                                            match ev:
                                                                Option.some as ev_p:
                                                                    if ev_p.value.kind == mgr.NetworkEventKind.connected:
                                                                        stdio.print("CLIENT: connected id=%d\n", uint<-ev_p.value.player_id)
                                                                        client_ok = true
                                                                Option.none:
                                                                    break

                                                        if host_ok and client_ok:
                                                            stdio.print("SUCCESS\n")
                                                            client_mgr.release()
                                                            host_mgr.release()
                                                            return 0

                                                        frame += 1

                                                    stdio.print("FAIL: timeout\n")
                                                    client_mgr.release()
                                                    host_mgr.release()
                                                    return -9

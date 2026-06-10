import std.stdio as stdio
import std.net as net
import std.net.lobby as lobby
import std.net.mux as mux
import std.string as string
import std.vec as vec
import std.bytes as bytes
import std.async as aio

struct Game:
    host: lobby.LobbyHost

struct App:
    game: Option[Game]

async function tick_app(app: ref[App], frame: uint) -> bool:
    match app.game:
        Option.some as hg:
            var game = hg.value
            await game.host.tick(frame)
            var found = false
            var i: uint = 0
            while i < 10:
                let ev = game.host.try_recv()
                match ev:
                    Option.some as evp:
                        var e = evp.value
                        defer e.release()
                        if e.kind == lobby.LobbyEventKind.player_joined:
                            stdio.print("HOST: joined! ticks=%d\n", uint<-(frame))
                            found = true
                    Option.none:
                        break
                i += 1
            if found:
                game.host.release()
                app.game = Option[Game].none
                return true
            app.game = Option[Game].some(value = game)
            return false
        Option.none:
            return false

async function main() -> int:
    stdio.print("=== Creating host ===\n")

    match net.ipv4("0.0.0.0", 12345):
        Result.failure:
            stdio.print("FAIL: host bind\n")
            return -1
        Result.success as bp:
            var server_addr = bp.value
            defer server_addr.release()
            let config = mux.MuxedConfig.default()
            let info = lobby.LobbyInfo(
                name = string.String.from_str("Test"),
                player_count = 0,
                max_players = 2,
                player_names = vec.Vec[string.String].create(),
                game_data = bytes.Bytes.empty()
            )
            match lobby.create_lobby(server_addr, info, config):
                Result.failure:
                    stdio.print("FAIL: lobby create\n")
                    return -2
                Result.success as lp:
                    var app = App(game = Option[Game].some(value = Game(host = lp.value)))
                    stdio.print("HOST OK\n")

                    stdio.print("=== Creating client ===\n")

                    match net.ipv4("127.0.0.1", 12345):
                        Result.failure:
                            stdio.print("FAIL: client addr\n")
                            return -3
                        Result.success as remote:
                            var remote_addr = remote.value
                            defer remote_addr.release()
                            match net.ipv4("0.0.0.0", 0):
                                Result.failure:
                                    stdio.print("FAIL: client bind\n")
                                    return -4
                                Result.success as local:
                                    var local_addr = local.value
                                    defer local_addr.release()
                                    match await lobby.join_lobby(local_addr, remote_addr, "P", config):
                                        Result.failure:
                                            stdio.print("FAIL: join\n")
                                            return -5
                                        Result.success as jp:
                                            var client = jp.value
                                            defer client.release()
                                            stdio.print("CLIENT OK\n")

                                            var frame: uint = 0
                                            var host_done = false
                                            var done_frame: uint = 0
                                            while true:
                                                if not host_done:
                                                    host_done = await tick_app(ref_of(app), frame)
                                                    if host_done:
                                                        done_frame = frame
                                                await client.tick(frame)
                                                var j: uint = 0
                                                while j < 10:
                                                    let ev = client.try_recv()
                                                    match ev:
                                                        Option.some as evp:
                                                            var e = evp.value
                                                            defer e.release()
                                                            if e.kind == lobby.LobbyEventKind.joined:
                                                                stdio.print("CLIENT: joined at ticks=%d\n", uint<-(frame))
                                                        Option.none:
                                                            break
                                                    j += 1
                                                frame += 1
                                                if host_done and frame > done_frame + 1:
                                                    stdio.print("=== SUCCESS ===\n")
                                                    return 0
                                                if frame > 1200:
                                                    stdio.print("TIMEOUT\n")
                                                    return -6

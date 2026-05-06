module examples.idiomatic.steamworks.persona_name

import std.c.libc as libc
import std.io as io
import std.steamworks as steam
import std.str as text


def main(argc: int, argv: ptr[ptr[char]]) -> int:
    if argc < 2:
        if not io.write_error_line("Usage: persona_name APP_ID"):
            return 1
        return 2

    var raw_app_id: cstr = c""
    unsafe:
        raw_app_id = cstr<-read(argv + ptr_uint<-1)

    let parsed_app_id = libc.atoi(raw_app_id)
    if parsed_app_id <= 0:
        if not io.write_error_line("APP_ID must be a positive integer"):
            return 3
        return 4

    let app_id = steam.AppId_t<-parsed_app_id
    if steam.restart_app_if_necessary(app_id):
        return 0

    if not steam.init():
        if not io.write_error_line("SteamAPI_Init failed. Launch through Steam or provide steam_appid.txt."):
            return 5
        return 6

    defer steam.shutdown()

    let friends = steam.friends()
    let persona_name = steam.friends_get_persona_name(friends)
    if not io.println(f"Steam persona -> #{text.cstr_as_str(persona_name)}"):
        return 7

    return 0

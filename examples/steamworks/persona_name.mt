module examples.steamworks.persona_name

import std.c.libc as libc
import std.c.stdio as stdio
import std.c.steamworks as steam


function usage() -> int:
    stdio.printf(c"Usage: persona_name APP_ID\n")
    return 2


function main(argc: int, argv: ptr[ptr[char]]) -> int:
    if argc < 2:
        return usage()

    var raw_app_id: cstr = c""
    unsafe:
        raw_app_id = cstr<-read(argv + ptr_uint<-1)

    let parsed_app_id = libc.atoi(raw_app_id)
    if parsed_app_id <= 0:
        stdio.printf(c"APP_ID must be a positive integer\n")
        return 4

    let app_id = steam.AppId_t<-parsed_app_id
    if steam.SteamAPI_RestartAppIfNecessary(app_id):
        return 0

    if not steam.SteamAPI_Init():
        stdio.printf(c"SteamAPI_Init failed. Launch through Steam or provide steam_appid.txt.\n")
        return 6

    defer steam.SteamAPI_Shutdown()

    let friends = steam.SteamAPI_SteamFriends()
    let persona_name = steam.SteamAPI_ISteamFriends_GetPersonaName(friends)
    stdio.printf(c"Steam persona -> %s\n", persona_name)
    return 0

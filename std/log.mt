module std.log

import std.fmt as fmt
import std.io as io
import std.mem.arena as arena
import std.string as string

pub enum Level: u8
    debug = 1
    info = 2
    warn = 3
    error = 4

pub def level_name(level: Level) -> str:
    match level:
        Level.debug:
            return "debug"
        Level.info:
            return "info"
        Level.warn:
            return "warn"
        Level.error:
            return "error"

pub def write(level: Level, message: str, scratch: ref[arena.Arena]) -> bool:
    var line = string.create()
    defer string.release(addr(line))

    fmt.append_str(addr(line), "[")
    fmt.append_str(addr(line), level_name(level))
    fmt.append_str(addr(line), "] ")
    fmt.append_str(addr(line), message)
    let ok = io.write_error_line(string.as_str(line))
    return ok

pub def debug(message: str, scratch: ref[arena.Arena]) -> bool:
    return write(Level.debug, message, scratch)

pub def info(message: str, scratch: ref[arena.Arena]) -> bool:
    return write(Level.info, message, scratch)

pub def warn(message: str, scratch: ref[arena.Arena]) -> bool:
    return write(Level.warn, message, scratch)

pub def error(message: str, scratch: ref[arena.Arena]) -> bool:
    return write(Level.error, message, scratch)

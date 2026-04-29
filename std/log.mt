module std.log

import std.fmt as fmt
import std.io as io
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

pub def write(level: Level, message: str) -> bool:
    var line = string.String.create()
    defer line.release()

    fmt.append_str(addr(line), "[")
    fmt.append_str(addr(line), level_name(level))
    fmt.append_str(addr(line), "] ")
    fmt.append_str(addr(line), message)
    let ok = io.write_error_line(line.as_str())
    return ok

pub def debug(message: str) -> bool:
    return write(Level.debug, message)

pub def info(message: str) -> bool:
    return write(Level.info, message)

pub def warn(message: str) -> bool:
    return write(Level.warn, message)

pub def error(message: str) -> bool:
    return write(Level.error, message)

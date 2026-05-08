module std.log

import std.fmt as fmt
import std.io as io
import std.string as string

public enum Level: ubyte
    debug = 1
    info = 2
    warn = 3
    error = 4


public function level_name(level: Level) -> str:
    match level:
        Level.debug:
            return "debug"
        Level.info:
            return "info"
        Level.warn:
            return "warn"
        Level.error:
            return "error"


public function write(level: Level, message: str) -> bool:
    var line = string.String.create()
    defer line.release()

    fmt.append_str(ref_of(line), "[")
    fmt.append_str(ref_of(line), level_name(level))
    fmt.append_str(ref_of(line), "] ")
    fmt.append_str(ref_of(line), message)
    let ok = io.write_error_line(line.as_str())
    return ok


public function debug(message: str) -> bool:
    return write(Level.debug, message)


public function info(message: str) -> bool:
    return write(Level.info, message)


public function warn(message: str) -> bool:
    return write(Level.warn, message)


public function error(message: str) -> bool:
    return write(Level.error, message)

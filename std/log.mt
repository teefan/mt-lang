import std.string as string
import std.terminal as terminal

public enum Level: int
    trace = 0
    debug = 1
    info = 2
    warn = 3
    error = 4
    fatal = 5

var global_level: Level = Level.trace


public function set_level(level: Level) -> void:
    global_level = level


public function level() -> Level:
    return global_level


function level_label(level: Level) -> str:
    return match level:
        Level.trace: "TRACE"
        Level.debug: "DEBUG"
        Level.info: "INFO "
        Level.warn: "WARN "
        Level.error: "ERROR"
        Level.fatal: "FATAL"


public function log(level: Level, message: str) -> void:
    if int<-level < int<-global_level:
        return
    var output = string.String.create()
    defer output.release()
    output.append("[")
    output.append(level_label(level))
    output.append("] ")
    output.append(message)
    output.push_byte(10)
    let _ = terminal.write_stderr(output.as_str())
    terminal.flush_stderr()


public function trace(message: str) -> void:
    log(Level.trace, message)


public function debug(message: str) -> void:
    log(Level.debug, message)


public function info(message: str) -> void:
    log(Level.info, message)


public function warn(message: str) -> void:
    log(Level.warn, message)


public function error(message: str) -> void:
    log(Level.error, message)


public function fatal_message(message: str) -> void:
    log(Level.fatal, message)
    fatal(c"fatal log")

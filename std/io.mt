module std.io

import std.fmt as fmt
import std.c.unistd as unistd
import std.string as string

const stdout_fd: i32 = 1
const stderr_fd: i32 = 2

def write_fd(fd: i32, text: str) -> bool:
    if text.len == 0:
        return true

    unsafe:
        let written = unistd.write(fd, ptr[void]<-text.data, text.len)
        return written == i64<-text.len

pub def write(text: str) -> bool:
    return write_fd(stdout_fd, text)

pub def write_line(text: str) -> bool:
    if not write(text):
        return false
    return write("\n")

pub def write_error(text: str) -> bool:
    return write_fd(stderr_fd, text)

pub def write_error_line(text: str) -> bool:
    if not write_error(text):
        return false
    return write_error("\n")

pub def print(text: str) -> bool:
    return write(text)

pub def println(text: str) -> bool:
    return write_line(text)

def print_formatted(text: ref[string.String]) -> bool:
    let ok = write(text.as_str())
    text.release()
    return ok

def println_formatted(text: ref[string.String]) -> bool:
    let ok = write_line(text.as_str())
    text.release()
    return ok

def write_error_formatted(text: ref[string.String]) -> bool:
    let ok = write_error(text.as_str())
    text.release()
    return ok

def write_error_line_formatted(text: ref[string.String]) -> bool:
    let ok = write_error_line(text.as_str())
    text.release()
    return ok

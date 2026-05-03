extern module std.c.unistd:
    include "unistd.h"

    type ssize_t = i64

    extern def write(fd: i32, buf: ptr[void], count: usize) -> ssize_t

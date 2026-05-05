extern module std.c.unistd:
    include "unistd.h"

    type ssize_t = long

    extern def write(fd: int, buf: ptr[void], count: ptr_uint) -> ssize_t

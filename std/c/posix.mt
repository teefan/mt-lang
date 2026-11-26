# POSIX process primitives used by the watch loop.  Kept separate from the
# bindgen-generated `std/c/libc.mt` so regenerating libc cannot drop them.

external

include "unistd.h"
include "sys/wait.h"

external function fork() -> int
external function waitpid(__pid: int, __stat_loc: ptr[int], __options: int) -> int

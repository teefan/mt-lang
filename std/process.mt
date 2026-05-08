module std.process

import std.libc as libc
import std.maybe as maybe
import std.str as text_ops


pub def arg_count(argc: int) -> ptr_uint:
    if argc <= 0:
        return 0
    return ptr_uint<-argc


pub def arg(argc: int, argv: ptr[cstr], index: ptr_uint) -> maybe.Maybe[str]:
    if index >= arg_count(argc):
        return maybe.Maybe[str].none

    unsafe:
        return maybe.Maybe[str].some(value= text_ops.cstr_as_str(read(argv + index)))


pub def env(name: str) -> maybe.Maybe[str]:
    return text_ops.nullable_cstr_as_str(libc.get_env(name))


pub def env_exists(name: str) -> bool:
    return maybe.is_some(env(name))


pub def exit(status: int) -> void:
    libc.exit(status)
    return

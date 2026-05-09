module std.process

import std.libc as libc
import std.maybe as maybe
import std.str as text_ops


public function arg_count(argc: int) -> ptr_uint:
    if argc <= 0:
        return 0
    return ptr_uint<-argc


public function arg(argc: int, argv: ptr[cstr], index: ptr_uint) -> maybe.Maybe[str]:
    if index >= arg_count(argc):
        return maybe.Maybe[str].none

    return unsafe: maybe.Maybe[str].some(value= text_ops.cstr_as_str(read(argv + index)))


public function env(name: str) -> maybe.Maybe[str]:
    return text_ops.nullable_cstr_as_str(libc.get_env(name))


public function env_exists(name: str) -> bool:
    return maybe.is_some(env(name))


public function exit(status: int) -> void:
    libc.exit(status)
    return

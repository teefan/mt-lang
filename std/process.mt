module std.process

import std.libc as libc
import std.option as option
import std.str as text_ops


pub def arg_count(argc: int) -> ptr_uint:
    if argc <= 0:
        return 0
    return ptr_uint<-argc


pub def arg(argc: int, argv: ptr[cstr], index: ptr_uint) -> option.Option[str]:
    if index >= arg_count(argc):
        return option.none[str]()

    unsafe:
        return option.some[str](text_ops.cstr_as_str(read(argv + index)))


pub def env(name: str) -> option.Option[str]:
    return text_ops.nullable_cstr_as_str(libc.get_env(name))


pub def env_exists(name: str) -> bool:
    return option.is_some[str](env(name))


pub def exit(status: int) -> void:
    libc.exit(status)
    return

module std.process

import std.c.libc as libc
import std.mem.arena as arena
import std.option as option

pub def cstr_len(text: cstr) -> usize:
    var count: usize = 0
    unsafe:
        let data = cast[ptr[char]](text)
        while deref(data + count) != zero[char]():
            count += 1
    return count

pub def cstr_as_str(text: cstr) -> str:
    unsafe:
        return str(data = cast[ptr[char]](text), len = cstr_len(text))

pub def arg_count(argc: i32) -> usize:
    if argc <= 0:
        return 0
    return cast[usize](argc)

pub def arg(argc: i32, argv: ptr[cstr], index: usize) -> option.Option[str]:
    if index >= arg_count(argc):
        return option.none[str]()

    unsafe:
        return option.some[str](cstr_as_str(deref(argv + index)))

pub def env(name: str, scratch: ref[arena.Arena]) -> option.Option[str]:
    let mark = value(scratch).mark()
    defer value(scratch).reset(mark)

    let c_name = value(scratch).to_cstr(name)
    let value_ptr: ptr[char]? = libc.getenv(c_name)
    if value_ptr == null:
        return option.none[str]()

    unsafe:
        return option.some[str](cstr_as_str(cast[cstr](value_ptr)))

pub def env_exists(name: str, scratch: ref[arena.Arena]) -> bool:
    return option.is_some[str](env(name, scratch))

pub def exit(status: i32) -> void:
    libc.exit(status)
    return

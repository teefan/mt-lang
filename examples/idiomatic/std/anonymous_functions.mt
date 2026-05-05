module examples.idiomatic.std.anonymous_functions

import std.io as io


def apply(callback: proc(value: int) -> int, value: int) -> int:
    return callback(value)


def main() -> int:
    let times_two = proc(value: int) -> int:
        return value * 2

    let offset = 5
    let add_offset = proc(value: int) -> int:
        return value + offset

    if not io.println("anonymous functions and closures"):
        return 1
    if not io.println(f"times_two(3) = #{apply(times_two, 3)}"):
        return 2
    if not io.println(f"add_offset(3) = #{apply(add_offset, 3)}"):
        return 3

    return 0

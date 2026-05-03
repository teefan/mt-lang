module examples.idiomatic.std.anonymous_functions

import std.io as io


def apply(callback: proc(value: i32) -> i32, value: i32) -> i32:
    return callback(value)


def main() -> i32:
    let double = proc(value: i32) -> i32:
        return value * 2

    let offset = 5
    let add_offset = proc(value: i32) -> i32:
        return value + offset

    if not io.println("anonymous functions and closures"):
        return 1
    if not io.println(f"double(3) = #{apply(double, 3)}"):
        return 2
    if not io.println(f"add_offset(3) = #{apply(add_offset, 3)}"):
        return 3

    return 0

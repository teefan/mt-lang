module examples.idiomatic.std.string_interpolation

import std.fmt as fmt
import std.io as io
import std.string as string

# Demonstrates a declared `str` initialized from interpolation.


def print_declared_header(user: str, count: i32) -> bool:
    let header: str = f"declared-str -> user=#{user} count=#{count}"
    return io.println(header)


def main() -> i32:
    let user: str = "milk-tea"
    let count: i32 = 3
    let ratio: f64 = 0.625

    # Direct interpolation to io.println.
    if not io.println(f"direct -> user=#{user} count=#{count} ratio=#{ratio} ok=#{count > 0}"):
        return 1
    if not print_declared_header(user, count):
        return 2

    # Interpolation into an owned std.string.String value.
    var message = fmt.string(f"owned -> user=#{user} next=#{count + 1} triple=#{count * 3}")
    defer message.release()

    if message.count() == 0:
        return 3
    if not io.println(message.as_str()):
        return 4

    let state = if count >= 3: "busy" else: "idle"
    if not io.println(f"expr -> state=#{state} math=#{count * count}"):
        return 5

    return 0

module examples.idiomatic.std.io_printing

import std.io as io

def main() -> i32:
    let count: i32 = 7
    let angle: f32 = 45.5
    let ratio: f64 = 0.25

    if not io.print("stdout raw -> "):
        return 1
    if not io.println("Milk Tea"):
        return 2
    if not io.println(f"stdout fmt -> count=#{count} ok=#{true} angle=#{angle} ratio=#{ratio}"):
        return 3
    if not io.write_error("stderr raw -> "):
        return 4
    if not io.write_error_line("warning path"):
        return 5
    if not io.write_error_line(f"stderr fmt -> count=#{count} angle=#{angle} ratio=#{ratio}"):
        return 6

    return 0

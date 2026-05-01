module examples.idiomatic.std.format_specifiers

import std.io as io

def main() -> i32:
    let pi: f64 = 3.14159265358979
    let ratio: f64 = 1.0 / 3.0
    let small: f32 = 0.00123

    # Float precision specifiers
    io.println(f"pi:.0 -> #{pi:.0}")
    io.println(f"pi:.2 -> #{pi:.2}")
    io.println(f"pi:.5 -> #{pi:.5}")
    io.println(f"ratio:.4 -> #{ratio:.4}")
    io.println(f"small:.6 -> #{small:.6}")

    # Mix precision with ordinary interpolation
    let label = "euler"
    let e: f64 = 2.71828182845
    io.println(f"mixed -> #{label}=#{e:.3}")

    return 0

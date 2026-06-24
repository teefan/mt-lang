# In-language tests for std.fmt (migrated from
# test/std/std_fmt_log_test.rb, run by `mtc test`).

import std.testing as t
import std.fmt as fmt
import std.mem.arena as arena
import std.string as string

struct Point:
    x: int
    y: int

extending Point:
    function format_len() -> ptr_uint:
        return f"(#{this.x}, #{this.y})".len

    function append_format(output: ref[string.String]) -> void:
        fmt.append_format(output, f"(#{this.x}, #{this.y})")


function byte_at(text: str, index: ptr_uint) -> int:
    unsafe:
        return int<-ubyte<-read(text.data + index)


function size(text: str) -> ptr_uint:
    return text.len


@[test]
function test_fmt_basic_formatting() -> t.Check:
    var scratch = arena.create(64)
    defer scratch.release()
    var output = string.String.create()
    defer output.release()

    fmt.append_str(ref_of(output), "n=")
    fmt.append_int(ref_of(output), -42)
    fmt.append_str(ref_of(output), " ok=")
    fmt.append_bool(ref_of(output), true)
    fmt.append_str(ref_of(output), " size=")
    fmt.append_ptr_uint(ref_of(output), 17)
    fmt.append_str(ref_of(output), " u=")
    fmt.append_uint(ref_of(output), uint<-7)
    fmt.append_str(ref_of(output), " tail=")
    fmt.append_cstr(ref_of(output), scratch.to_cstr(" raw"))

    let view = output.as_str()
    t.expect(view.len == 35z, "formatted length == 35")?
    let total = int<-view.len + byte_at(view, 34)
    return t.expect_equal_int(total, 154)


@[test]
function test_fmt_format_literals() -> t.Check:
    var scratch = arena.create(64)
    defer scratch.release()
    let delta: short = -42
    let small: ubyte = 7
    let ticks: ulong = 9
    var output = fmt.format(f"n=#{delta} ok=#{true} small=#{small} ticks=#{ticks} raw=#{scratch.to_cstr("wow")}")
    defer output.release()
    return t.expect_equal_int(int<-output.len(), 37)


@[test]
function test_fmt_direct_string_sink_format_literals() -> t.Check:
    let value = 7
    var output = string.String.create()
    defer output.release()
    output.assign(f"value=#{value}")
    output.append(f" ok=#{true}")
    return t.expect_equal_int(int<-output.len(), 15)


@[test]
function test_fmt_explicit_builder_format_sinks() -> t.Check:
    var scratch = arena.create(64)
    defer scratch.release()
    let value: uint = 26
    let ratio: double = 3.5
    var output = string.String.from_str("seed")
    defer output.release()

    fmt.append_format(ref_of(output), f" hex=#{value:x} oct=#{value:o}")
    t.expect(output.as_str() == "seed hex=1a oct=32", "hex/oct append")?

    fmt.assign_format(ref_of(output), f"ratio=#{ratio:.2} ok=#{true}")
    t.expect(output.as_str() == "ratio=3.50 ok=true", "ratio assign")?

    output.append_format(f" raw=#{scratch.to_cstr("wow")} bin=#{value:b}")
    t.expect(output.as_str() == "ratio=3.50 ok=true raw=wow bin=11010", "raw/bin append")?

    output.assign_format(f"HEX=#{value:X}")
    return t.expect(output.as_str() == "HEX=1A", "HEX assign")


@[test]
function test_fmt_preserves_aliasing() -> t.Check:
    var output = string.String.from_str("abc")
    defer output.release()

    output.assign_format(f"#{output.as_str()}x")
    t.expect(output.as_str() == "abcx", "aliased assign")?

    output.append_format(f"|#{output.as_str()}")
    return t.expect(output.as_str() == "abcx|abcx", "aliased append")


@[test]
function test_fmt_str_buffer_format_sinks() -> t.Check:
    let value: uint = 26
    let ratio: double = 3.5
    var buffer: str_buffer[64]

    buffer.assign_format(f"#{value:x}")
    t.expect(buffer.as_str() == "1a", "buffer hex assign")?

    buffer.append_format(f"|#{ratio:.2}")
    t.expect(buffer.as_str() == "1a|3.50", "buffer ratio append")?

    buffer.assign("abc")
    buffer.assign_format(f"#{buffer.as_str()}x")
    t.expect(buffer.as_str() == "abcx", "buffer aliased assign")?

    buffer.append_format(f"|#{buffer.as_cstr()}")
    return t.expect(buffer.as_str() == "abcx|abcx", "buffer aliased append")


@[test]
function test_fmt_custom_format_hooks() -> t.Check:
    let point = Point(x = 2, y = 3)
    let text = f"point=#{point}"
    t.expect(text == "point=(2, 3)", "custom hook in f-string")?

    var output = string.String.create()
    defer output.release()
    output.append_format(f"[#{point}]")
    t.expect(output.as_str() == "[(2, 3)]", "custom hook append")?

    fmt.assign_format(ref_of(output), f"#{point}!")
    t.expect(output.as_str() == "(2, 3)!", "custom hook assign")?

    var buffer: str_buffer[64]
    buffer.assign_format(f"<#{point}>")
    return t.expect(buffer.as_str() == "<(2, 3)>", "custom hook buffer")


@[test]
function test_fmt_float_format_literals() -> t.Check:
    let ratio: float = 2.5
    let scale: double = 0.125
    var output = fmt.format(f"ratio=#{ratio} scale=#{scale}")
    defer output.release()
    return t.expect_equal_int(int<-output.len(), 21)


@[test]
function test_fmt_general_format_string_expressions() -> t.Check:
    let count = 7
    let text = f"count=#{count}"
    t.expect(size(f"ok=#{true}") != 0z, "format expr non-empty")?
    return t.expect_equal_int(int<-text.len, 7)

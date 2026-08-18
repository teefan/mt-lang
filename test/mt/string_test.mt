# In-language tests for std.string (run by `mtc test`).

import std.string as string

@[test]
function test_string_from_str_round_trips() -> void:
    var s = string.String.from_str("milk")
    expect_eq(s.as_str(), "milk")
    s.release()


@[test]
function test_string_append_concatenates() -> void:
    var s = string.String.create()
    s.append("milk")
    s.append("tea")
    expect_eq(s.as_str(), "milktea")
    s.release()


@[test]
function test_string_equal_compares_contents() -> void:
    var a = string.String.from_str("abc")
    var b = string.String.from_str("abc")
    let same = a.equal(b)
    a.release()
    b.release()
    expect(same, "equal strings should compare equal")


@[test]
function test_string_shrink_to_fit() -> void:
    var s = string.String.with_capacity(128)
    defer: s.release()
    s.append("hello")
    s.append(" world")
    expect(s.capacity() >= 128z, "capacity inflated")
    expect(s.len() == 11z, "len == 11")

    s.shrink_to_fit()
    expect(s.capacity() == 11z, "capacity == len")
    expect_eq(s.as_str(), "hello world")

    s.clear()
    s.shrink_to_fit()
    expect(s.capacity() == 0z, "capacity zero after clear + shrink")
    expect(s.is_empty())

    s.append("x")
    expect(s.capacity() == 4z, "auto-grow to base 4 after zeroed shrink")

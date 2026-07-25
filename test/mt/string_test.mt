# In-language tests for std.string (run by `mtc test`).

import std.testing as t
import std.string as string

@[test]
function test_string_from_str_round_trips() -> t.Check:
    var s = string.String.from_str("milk")
    let result = t.expect_equal_str(s.as_str(), "milk")
    s.release()
    return result


@[test]
function test_string_append_concatenates() -> t.Check:
    var s = string.String.create()
    s.append("milk")
    s.append("tea")
    let result = t.expect_equal_str(s.as_str(), "milktea")
    s.release()
    return result


@[test]
function test_string_equal_compares_contents() -> t.Check:
    var a = string.String.from_str("abc")
    var b = string.String.from_str("abc")
    let same = a.equal(b)
    a.release()
    b.release()
    return t.expect(same, "equal strings should compare equal")


@[test]
function test_string_shrink_to_fit() -> t.Check:
    var s = string.String.with_capacity(128)
    defer s.release()
    s.append("hello")
    s.append(" world")
    t.expect(s.capacity() >= 128z, "capacity inflated")?
    t.expect(s.len() == 11z, "len == 11")?

    s.shrink_to_fit()
    t.expect(s.capacity() == 11z, "capacity == len")?
    t.expect_equal_str(s.as_str(), "hello world")?

    s.clear()
    s.shrink_to_fit()
    t.expect(s.capacity() == 0z, "capacity zero after clear + shrink")?
    t.expect_true(s.is_empty())?

    s.append("x")
    return t.expect(s.capacity() == 4z, "auto-grow to base 4 after zeroed shrink")

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

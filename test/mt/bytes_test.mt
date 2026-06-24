# In-language tests for std.bytes (migrated from
# test/std/std_bytes_test.rb, run by `mtc test`).

import std.testing as t
import std.bytes as bytes

@[test]
function test_empty_has_zero_len() -> t.Check:
    let empty = bytes.Bytes.empty()
    return t.expect(empty.as_span().len == 0, "empty bytes should have zero length")


@[test]
function test_copy_without_aliasing() -> t.Check:
    var source = array[ubyte, 3](65, 66, 67)
    var owned = bytes.Bytes.copy(unsafe: span[ubyte](data = ptr_of(source[0]), len = 3))
    source[0] = 90
    let text_result = owned.as_str()
    var result = t.ok()
    match text_result:
        Option.none:
            result = t.fail("expected Option.some, got Option.none")
        Option.some as payload:
            result = t.expect_equal_str(payload.value, "ABC")

    owned.release()
    return result


@[test]
function test_invalid_utf8_returns_none() -> t.Check:
    var source = array[ubyte, 1](ubyte<-0xFF)
    var owned = bytes.Bytes.copy(unsafe: span[ubyte](data = ptr_of(source[0]), len = 1))
    let text_result = owned.as_str()
    let result = t.expect_none[str](text_result)
    owned.release()
    return result

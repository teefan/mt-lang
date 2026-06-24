# In-language tests for std.ctype (migrated from
# test/std/std_ctype_test.rb, run by `mtc test`).

import std.testing as t
import std.ctype as ctype


@[test]
function test_is_alpha() -> t.Check:
    t.expect_true(ctype.is_alpha(65))?
    return t.expect_false(ctype.is_alpha(49))


@[test]
function test_is_digit() -> t.Check:
    return t.expect_true(ctype.is_digit(53))


@[test]
function test_is_space() -> t.Check:
    return t.expect_true(ctype.is_space(32))


@[test]
function test_is_punct() -> t.Check:
    return t.expect_true(ctype.is_punct(33))


@[test]
function test_is_xdigit() -> t.Check:
    t.expect_true(ctype.is_xdigit(70))?
    return t.expect_false(ctype.is_xdigit(71))


@[test]
function test_to_lower() -> t.Check:
    return t.expect_equal_int(ctype.to_lower(81), 113)


@[test]
function test_to_upper() -> t.Check:
    return t.expect_equal_int(ctype.to_upper(109), 77)

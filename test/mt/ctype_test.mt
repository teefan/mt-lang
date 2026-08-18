# In-language tests for std.ctype (migrated from
# test/std/std_ctype_test.rb, run by `mtc test`).

import std.ctype as ctype


@[test]
function test_is_alpha() -> void:
    expect(ctype.is_alpha(65))
    expect(not ctype.is_alpha(49))


@[test]
function test_is_digit() -> void:
    expect(ctype.is_digit(53))


@[test]
function test_is_space() -> void:
    expect(ctype.is_space(32))


@[test]
function test_is_punct() -> void:
    expect(ctype.is_punct(33))


@[test]
function test_is_xdigit() -> void:
    expect(ctype.is_xdigit(70))
    expect(not ctype.is_xdigit(71))


@[test]
function test_to_lower() -> void:
    expect_eq(ctype.to_lower(81), 113)


@[test]
function test_to_upper() -> void:
    expect_eq(ctype.to_upper(109), 77)

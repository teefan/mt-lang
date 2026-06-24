# Example: @[test]-annotated tests discovered and run by `mtc test`.
#
# Run:
#   mtc test test/examples/testing_attr_demo.mt
#
# Expected output (exit code 0):
#   ok   - test_arithmetic
#   ok   - test_booleans
#   ok   - test_strings
#   ok   - test_options
#   passed=4 failed=0 skipped=0
#
# `mtc test` discovers every @[test] function (which must take no parameters
# and return t.Check), synthesizes a runner that drives them through
# std.testing, and reports results. No `main` is needed.

import std.testing as t

@[test]
function test_arithmetic() -> t.Check:
    t.expect(2 + 2 == 4, "addition broke")?
    t.expect_equal_int(6 * 7, 42)?
    t.expect_true(10 > 3)?
    t.expect_false(1 > 2)?
    return t.ok()


@[test]
function test_booleans() -> t.Check:
    t.expect_equal_bool(1 < 2, true)?
    t.expect_equal_bool(2 < 1, false)?
    return t.ok()


@[test]
function test_strings() -> t.Check:
    t.expect_equal_str("milk", "milk")?
    return t.ok()


@[test]
function test_options() -> t.Check:
    t.expect_some[int](Option[int].some(value = 7))?
    t.expect_none[int](Option[int].none)?
    return t.ok()

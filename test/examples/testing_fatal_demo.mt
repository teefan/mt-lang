# Example: death tests with @[test] @[expect_fatal].
#
# Run:
#   mtc test test/examples/testing_fatal_demo.mt
#
# An @[expect_fatal] test must abort (via fatal() or a failed safety check).
# `mtc test` runs each in its own binary and passes iff it aborts.
#
# Expected output (exit code 0):
#   ok   - test_normal_arithmetic
#   passed=1 failed=0 skipped=0
#   ok   - test_explicit_fatal (expect_fatal)
#   ok   - test_unwrap_none_aborts (expect_fatal)

import std.testing as t

@[test]
function test_normal_arithmetic() -> t.Check:
    return t.expect_equal_int(2 + 2, 4)


@[test]
@[expect_fatal]
function test_explicit_fatal() -> t.Check:
    fatal("intentional abort")


@[test]
@[expect_fatal]
function test_unwrap_none_aborts() -> t.Check:
    let absent: Option[int] = Option[int].none
    let value = absent.unwrap()
    return t.expect_equal_int(value, 0)

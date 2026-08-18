# Example: death tests with @[test] @[expect_fatal].
#
# Run:
#   mtc test test/examples/testing_fatal_demo.mt
#
# An @[expect_fatal] test must abort (via fatal(), a failed assertion, or a
# failed safety check). `mtc test` runs each in its own binary and passes iff
# it aborts.
#
# Expected output (exit code 0):
#   ok   - test_normal_arithmetic
#   ok   - test_explicit_fatal (expect_fatal)
#   ok   - test_unwrap_none_aborts (expect_fatal)

@[test]
function test_normal_arithmetic() -> void:
    expect_eq(2 + 2, 4)


@[test]
@[expect_fatal]
function test_explicit_fatal() -> void:
    fatal("intentional abort")


@[test]
@[expect_fatal]
function test_unwrap_none_aborts() -> void:
    let absent: Option[int] = Option[int].none
    let value = absent.unwrap()
    expect_eq(value, 0)
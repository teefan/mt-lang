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
#
# `mtc test` discovers every @[test] function (which must take no parameters
# and return void), synthesizes a runner that invokes each in its own process,
# and reports results. No `main` is needed.

@[test]
function test_arithmetic() -> void:
    expect(2 + 2 == 4, "addition broke")
    expect_eq(6 * 7, 42)
    expect(10 > 3)
    expect(not (1 > 2))


@[test]
function test_booleans() -> void:
    expect_eq(1 < 2, true)
    expect_eq(2 < 1, false)


@[test]
function test_strings() -> void:
    expect_eq("milk", "milk")


@[test]
function test_options() -> void:
    expect(Option[int].some(value = 7).is_some())
    expect(Option[int].none.is_none())
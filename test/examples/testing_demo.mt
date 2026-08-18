# Example: assertions outside of @[test] — usable in any function.
#
# Build & run:
#   mtc build test/examples/testing_demo.mt -o /tmp/testing_demo && /tmp/testing_demo
#
# Expected output (exit code 0): nothing is printed and the process exits 0.
#
# `assert`/`expect` are language intrinsics available in any module; a failed
# assertion aborts the program with the given message. Tests are written as
# `@[test]` functions run by `mtc test`.

function check_arithmetic() -> void:
    assert(2 + 2 == 4, "addition broke")
    expect_eq(6 * 7, 42)


function check_strings() -> void:
    expect_eq("milk", "milk")


function main() -> int:
    check_arithmetic()
    check_strings()
    return 0
# Example: using the std.testing core with a hand-written runner.
#
# Build & run:
#   mtc build test/examples/testing_demo.mt -o /tmp/testing_demo && /tmp/testing_demo
#
# Expected output (exit code 0):
#   ok   - arithmetic
#   ok   - booleans
#   ok   - strings
#   ok   - options
#   passed=4 failed=0 skipped=0
#
# Compiler-driven discovery (a `test "…"` form and `mtc test`) is a later phase;
# see docs/testing.md. Until then, tests are plain functions returning
# `t.Check` and a `main` that records each result.

import std.testing as t

function test_arithmetic() -> t.Check:
    t.expect(2 + 2 == 4, "addition broke")?
    t.expect_equal_int(6 * 7, 42)?
    t.expect_true(10 > 3)?
    t.expect_false(1 > 2)?
    return t.ok()


function test_booleans() -> t.Check:
    t.expect_equal_bool(1 < 2, true)?
    t.expect_equal_bool(2 < 1, false)?
    return t.ok()


function test_strings() -> t.Check:
    t.expect_equal_str("milk", "milk")?
    return t.ok()


function test_options() -> t.Check:
    let present: Option[int] = Option[int].some(value = 7)
    let absent: Option[int] = Option[int].none
    t.expect_some[int](present)?
    t.expect_none[int](absent)?
    return t.ok()


function main() -> int:
    var stats = t.Stats.create()
    stats = t.record(stats, "arithmetic", test_arithmetic())
    stats = t.record(stats, "booleans", test_booleans())
    stats = t.record(stats, "strings", test_strings())
    stats = t.record(stats, "options", test_options())
    return t.summarize(stats)

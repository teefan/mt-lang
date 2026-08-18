# In-language tests for std.math (migrated from
# test/std/std_math_test.rb, run by `mtc test`).

import std.math as math

@[test]
function test_roots_and_exponentials() -> void:
    let eps: double = 0.000001
    expect(math.abs(math.sqrt(9.0) - 3.0) <= eps, "sqrt(9) == 3")
    expect(math.abs(math.pow(2.0, 5.0) - 32.0) <= eps, "pow(2, 5) == 32")
    expect(math.abs(math.exp(1.0) - math.E) <= eps, "exp(1) == E")
    expect(math.abs(math.log(math.E) - 1.0) <= eps, "log(E) == 1")
    expect(math.abs(math.log10(1000.0) - 3.0) <= eps, "log10(1000) == 3")


@[test]
function test_trigonometry() -> void:
    let eps: double = 0.000001
    expect(math.abs(math.sin(math.HALF_PI) - 1.0) <= eps, "sin(pi/2) == 1")
    expect(math.abs(math.cos(math.PI) - -1.0) <= eps, "cos(pi) == -1")
    expect(math.abs(math.tan(0.0) - 0.0) <= eps, "tan(0) == 0")
    expect(math.abs(math.asin(1.0) - math.HALF_PI) <= eps, "asin(1) == pi/2")
    expect(math.abs(math.acos(-1.0) - math.PI) <= eps, "acos(-1) == pi")
    expect(math.abs(math.atan(1.0) - math.QUARTER_PI) <= eps, "atan(1) == pi/4")
    expect(math.abs(math.atan2(1.0, 1.0) - math.QUARTER_PI) <= eps, "atan2(1, 1) == pi/4")


@[test]
function test_rounding_and_abs() -> void:
    let eps: double = 0.000001
    expect(math.abs(math.floor(3.75) - 3.0) <= eps, "floor(3.75) == 3")
    expect(math.abs(math.ceil(3.25) - 4.0) <= eps, "ceil(3.25) == 4")
    expect(math.abs(math.mod(7.5, 2.0) - 1.5) <= eps, "mod(7.5, 2) == 1.5")
    expect(math.abs(math.abs(-4.5) - 4.5) <= eps, "abs(-4.5) == 4.5")

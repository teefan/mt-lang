# In-language tests for std.math (migrated from
# test/std/std_math_test.rb, run by `mtc test`).

import std.math as math
import std.testing as t

@[test]
function test_roots_and_exponentials() -> t.Check:
    let eps: double = 0.000001
    t.expect(math.abs(math.sqrt(9.0) - 3.0) <= eps, "sqrt(9) == 3")?
    t.expect(math.abs(math.pow(2.0, 5.0) - 32.0) <= eps, "pow(2, 5) == 32")?
    t.expect(math.abs(math.exp(1.0) - math.E) <= eps, "exp(1) == E")?
    t.expect(math.abs(math.log(math.E) - 1.0) <= eps, "log(E) == 1")?
    t.expect(math.abs(math.log10(1000.0) - 3.0) <= eps, "log10(1000) == 3")?
    return t.ok()


@[test]
function test_trigonometry() -> t.Check:
    let eps: double = 0.000001
    t.expect(math.abs(math.sin(math.HALF_PI) - 1.0) <= eps, "sin(pi/2) == 1")?
    t.expect(math.abs(math.cos(math.PI) - -1.0) <= eps, "cos(pi) == -1")?
    t.expect(math.abs(math.tan(0.0) - 0.0) <= eps, "tan(0) == 0")?
    t.expect(math.abs(math.asin(1.0) - math.HALF_PI) <= eps, "asin(1) == pi/2")?
    t.expect(math.abs(math.acos(-1.0) - math.PI) <= eps, "acos(-1) == pi")?
    t.expect(math.abs(math.atan(1.0) - math.QUARTER_PI) <= eps, "atan(1) == pi/4")?
    t.expect(math.abs(math.atan2(1.0, 1.0) - math.QUARTER_PI) <= eps, "atan2(1, 1) == pi/4")?
    return t.ok()


@[test]
function test_rounding_and_abs() -> t.Check:
    let eps: double = 0.000001
    t.expect(math.abs(math.floor(3.75) - 3.0) <= eps, "floor(3.75) == 3")?
    t.expect(math.abs(math.ceil(3.25) - 4.0) <= eps, "ceil(3.25) == 4")?
    t.expect(math.abs(math.mod(7.5, 2.0) - 1.5) <= eps, "mod(7.5, 2) == 1.5")?
    t.expect(math.abs(math.abs(-4.5) - 4.5) <= eps, "abs(-4.5) == 4.5")?
    return t.ok()

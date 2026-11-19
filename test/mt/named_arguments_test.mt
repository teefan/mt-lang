# Named-argument lowering: arguments are placed by parameter name and omitted
# defaults are filled from the declaration.  These run through both compilers
# (`mtc test test/mt`), so they catch the source-order lowering bug that the
# analyzer-only tests cannot see.

struct Calc:
    base: int

extending Calc:
    function sub(x: int, y: int) -> int:
        return this.base + x - y

    function sub_default(x: int, y: int = 5) -> int:
        return this.base + x - y

    function generic_sub[T](x: T, y: T) -> T:
        return x - y


function sub(x: int, y: int) -> int:
    return x - y


function sub_default(x: int, y: int = 5) -> int:
    return x - y


function generic_sub[T](x: T, y: T) -> T:
    return x - y


@[test]
function test_function_named_arguments_follow_parameter_order() -> void:
    expect_eq(sub(y = 1, x = 10), 9)


@[test]
function test_function_positional_before_named_is_allowed() -> void:
    expect_eq(sub(10, y = 1), 9)


@[test]
function test_function_default_is_filled() -> void:
    expect_eq(sub_default(y = 1, x = 10), 9)
    expect_eq(sub_default(x = 10), 5)


@[test]
function test_method_named_arguments_follow_parameter_order() -> void:
    var calc = Calc(base = 100)
    expect_eq(calc.sub(y = 1, x = 10), 109)


@[test]
function test_method_default_is_filled() -> void:
    var calc = Calc(base = 100)
    expect_eq(calc.sub_default(y = 1, x = 10), 109)
    expect_eq(calc.sub_default(x = 10), 105)


@[test]
function test_specialized_named_arguments_follow_parameter_order() -> void:
    expect_eq(generic_sub[int](y = 1, x = 10), 9)


@[test]
function test_specialized_method_named_arguments_follow_parameter_order() -> void:
    var calc = Calc(base = 0)
    expect_eq(calc.generic_sub[int](y = 1, x = 10), 9)

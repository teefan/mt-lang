# In-language tests for compound-assignment type checking.

@[test]
function test_integer_compound_assignment() -> void:
    var value = 1
    value += 2
    value *= 3
    value <<= 1
    value -= 4
    expect_eq(value, 14)

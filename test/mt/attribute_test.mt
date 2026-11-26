# In-language tests for compile-time attribute reflection (`has_attribute`).

attribute[struct] marked()

@[marked]
struct Tagged:
    value: int

struct Plain:
    value: int

const TAGGED_HAS: bool = has_attribute(Tagged, marked)
const PLAIN_HAS: bool = has_attribute(Plain, marked)

@[test]
function test_has_attribute_true_and_false() -> void:
    expect(TAGGED_HAS, "has_attribute sees @[marked]")
    expect(not PLAIN_HAS, "has_attribute is false without the attribute")

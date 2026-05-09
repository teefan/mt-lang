module examples.language_standard.algorithms

import examples.language_standard.types as types

public type IntFn = fn(value: int) -> int


function double_value(value: int) -> int:
    return value * 2


public function named_callback_result(value: int) -> int:
    return apply_named(double_value, value)


public function apply_named(callback: IntFn, value: int) -> int:
    return callback(value)


public function make_adder(offset: int) -> proc(value: int) -> int:
    return proc(value: int) -> int:
        return value + offset


public function closure_result(base: int) -> int:
    let add = make_adder(5)
    return add(base)


public function fill_tail(values: ref[array[int, 4]]) -> void:
    read(values)[1..4] = (2, 3, 4)
    return


public function take_or_zero(handle: ptr[int]?) -> int:
    let value = handle else:
        return 0

    unsafe:
        return read(value)


public function sum_positive(values: span[int]) -> int:
    var total = 0
    for value in values:
        if value < 0:
            continue
        total += value
    return total


public function zip_total(left: span[int], right: span[int]) -> int:
    var total = 0
    for left_value, right_value in left, right:
        total += left_value + right_value
    return total


public function countdown(start: int) -> int:
    var current = start
    var total = 0
    while current > 0:
        if current == 2:
            current -= 1
            continue
        total += current
        if total > 10:
            break
        current -= 1
    return total


public function first_const(values: ref[array[int, 4]]) -> const_ptr[int]:
    return const_ptr_of(read(values)[0])


public function float_bits(value: float) -> uint:
    return unsafe: reinterpret[uint](value)


public function pointer_touch(counter: ptr[types.Counter]) -> int:
    unsafe:
        counter.total += 1
        return counter.total


public function choose_box(flag: bool) -> types.Box[int]:
    if flag:
        return types.Box[int].some(value = 7)
    return types.Box[int].none


public function require_positive(value: int) -> int:
    if value < 0:
        fatal("value must be non-negative")
    return value


public function defer_block_demo() -> int:
    var total = 3
    defer:
        total += 1
        total += 1
    return total

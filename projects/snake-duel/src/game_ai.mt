module src.game_ai


def clamp_i32(value: i32, min_value: i32, max_value: i32) -> i32:
    if value < min_value:
        return min_value
    if value > max_value:
        return max_value

    return value


pub def choose_axis(delta_x: i32, delta_y: i32, tick: i32) -> i32:
    let abs_x = if delta_x < 0: -delta_x else: delta_x
    let abs_y = if delta_y < 0: -delta_y else: delta_y

    if abs_x > abs_y:
        return 0
    if abs_y > abs_x:
        return 1

    return if tick % 2 == 0: 0 else: 1


pub def choose_dx(self_x: i32, target_x: i32, tick: i32) -> i32:
    if target_x > self_x:
        return 1
    if target_x < self_x:
        return -1

    return if tick % 2 == 0: 1 else: -1


pub def choose_dy(self_y: i32, target_y: i32, tick: i32) -> i32:
    if target_y > self_y:
        return 1
    if target_y < self_y:
        return -1

    return if tick % 2 == 0: 1 else: -1


pub def clamp_dir(value: i32) -> i32:
    return clamp_i32(value, -1, 1)

module src.game_ai


def clamp_int(value: int, min_value: int, max_value: int) -> int:
    if value < min_value:
        return min_value
    if value > max_value:
        return max_value

    return value


pub def choose_axis(delta_x: int, delta_y: int, tick: int) -> int:
    let abs_x = if delta_x < 0: -delta_x else: delta_x
    let abs_y = if delta_y < 0: -delta_y else: delta_y

    if abs_x > abs_y:
        return 0
    if abs_y > abs_x:
        return 1

    return if tick % 2 == 0: 0 else: 1


pub def choose_dx(self_x: int, target_x: int, tick: int) -> int:
    if target_x > self_x:
        return 1
    if target_x < self_x:
        return -1

    return if tick % 2 == 0: 1 else: -1


pub def choose_dy(self_y: int, target_y: int, tick: int) -> int:
    if target_y > self_y:
        return 1
    if target_y < self_y:
        return -1

    return if tick % 2 == 0: 1 else: -1


pub def clamp_dir(value: int) -> int:
    return clamp_int(value, -1, 1)

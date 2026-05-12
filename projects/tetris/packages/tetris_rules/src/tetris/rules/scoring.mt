module tetris.rules.scoring

public function gravity_seconds(level: int) -> float:
    if level <= 0:
        return 0.7
    if level == 1:
        return 0.58
    if level == 2:
        return 0.47
    if level == 3:
        return 0.38
    if level == 4:
        return 0.3
    if level == 5:
        return 0.24
    return 0.18


public function clear_score(cleared_lines: int, level: int) -> int:
    return cleared_lines * cleared_lines * 100 * (level + 1)

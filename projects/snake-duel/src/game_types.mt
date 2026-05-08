module src.game_types

import std.raylib as rl

const cell_size_value: int = 24
const grid_width_value: int = 32
const grid_height_value: int = 24
const max_body_value: int = 256
const hud_height_value: int = 72
const screen_width_value: int = grid_width_value * cell_size_value
const screen_height_value: int = (grid_height_value * cell_size_value) + hud_height_value
const tick_seconds_value: float = 0.1

const state_title_value: int = 0
const state_playing_value: int = 1
const state_game_over_value: int = 2

const winner_draw_value: int = 0
const winner_player_value: int = 1
const winner_enemy_value: int = 2

public struct Vec2i:
    x: int
    y: int

public struct Snake:
    body: array[Vec2i, 256]
    length: int
    dir_x: int
    dir_y: int
    alive: bool
    score: int
    color: rl.Color

public struct Game:
    player: Snake
    enemy: Snake
    food: Vec2i
    tick: int
    state: int
    winner: int


public function vec2i(x: int, y: int) -> Vec2i:
    return Vec2i(x = x, y = y)


public function cell_size() -> int:
    return cell_size_value


public function grid_width() -> int:
    return grid_width_value


public function grid_height() -> int:
    return grid_height_value


public function max_body() -> int:
    return max_body_value


public function hud_height() -> int:
    return hud_height_value


public function screen_width() -> int:
    return screen_width_value


public function screen_height() -> int:
    return screen_height_value


public function tick_seconds() -> float:
    return tick_seconds_value


public function state_title() -> int:
    return state_title_value


public function state_playing() -> int:
    return state_playing_value


public function state_game_over() -> int:
    return state_game_over_value


public function winner_draw() -> int:
    return winner_draw_value


public function winner_player() -> int:
    return winner_player_value


public function winner_enemy() -> int:
    return winner_enemy_value

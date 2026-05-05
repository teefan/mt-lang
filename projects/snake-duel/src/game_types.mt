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

pub struct Vec2i:
    x: int
    y: int

pub struct Snake:
    body: array[Vec2i, 256]
    length: int
    dir_x: int
    dir_y: int
    alive: bool
    score: int
    color: rl.Color

pub struct Game:
    player: Snake
    enemy: Snake
    food: Vec2i
    tick: int
    state: int
    winner: int


pub def vec2i(x: int, y: int) -> Vec2i:
    return Vec2i(x = x, y = y)


pub def cell_size() -> int:
    return cell_size_value


pub def grid_width() -> int:
    return grid_width_value


pub def grid_height() -> int:
    return grid_height_value


pub def max_body() -> int:
    return max_body_value


pub def hud_height() -> int:
    return hud_height_value


pub def screen_width() -> int:
    return screen_width_value


pub def screen_height() -> int:
    return screen_height_value


pub def tick_seconds() -> float:
    return tick_seconds_value


pub def state_title() -> int:
    return state_title_value


pub def state_playing() -> int:
    return state_playing_value


pub def state_game_over() -> int:
    return state_game_over_value


pub def winner_draw() -> int:
    return winner_draw_value


pub def winner_player() -> int:
    return winner_player_value


pub def winner_enemy() -> int:
    return winner_enemy_value

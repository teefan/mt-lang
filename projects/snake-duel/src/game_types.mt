module src.game_types

import std.raylib as rl

const cell_size_value: i32 = 24
const grid_width_value: i32 = 32
const grid_height_value: i32 = 24
const max_body_value: i32 = 256
const hud_height_value: i32 = 72
const screen_width_value: i32 = grid_width_value * cell_size_value
const screen_height_value: i32 = (grid_height_value * cell_size_value) + hud_height_value
const tick_seconds_value: f32 = 0.1

const state_title_value: i32 = 0
const state_playing_value: i32 = 1
const state_game_over_value: i32 = 2

const winner_draw_value: i32 = 0
const winner_player_value: i32 = 1
const winner_enemy_value: i32 = 2

pub struct Vec2i:
    x: i32
    y: i32

pub struct Snake:
    body: array[Vec2i, 256]
    length: i32
    dir_x: i32
    dir_y: i32
    alive: bool
    score: i32
    color: rl.Color

pub struct Game:
    player: Snake
    enemy: Snake
    food: Vec2i
    tick: i32
    state: i32
    winner: i32


pub def vec2i(x: i32, y: i32) -> Vec2i:
    return Vec2i(x = x, y = y)


pub def cell_size() -> i32:
    return cell_size_value


pub def grid_width() -> i32:
    return grid_width_value


pub def grid_height() -> i32:
    return grid_height_value


pub def max_body() -> i32:
    return max_body_value


pub def hud_height() -> i32:
    return hud_height_value


pub def screen_width() -> i32:
    return screen_width_value


pub def screen_height() -> i32:
    return screen_height_value


pub def tick_seconds() -> f32:
    return tick_seconds_value


pub def state_title() -> i32:
    return state_title_value


pub def state_playing() -> i32:
    return state_playing_value


pub def state_game_over() -> i32:
    return state_game_over_value


pub def winner_draw() -> i32:
    return winner_draw_value


pub def winner_player() -> i32:
    return winner_player_value


pub def winner_enemy() -> i32:
    return winner_enemy_value

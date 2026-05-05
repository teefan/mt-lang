module src.game_logic

import std.raylib as rl
import src.game_ai as game_ai
import src.game_types as gt


def same_cell(lhs: gt.Vec2i, rhs: gt.Vec2i) -> bool:
    return lhs.x == rhs.x and lhs.y == rhs.y


def snake_contains_cell(snake: gt.Snake, cell: gt.Vec2i, from_index: int) -> bool:
    var index = from_index
    while index < snake.length:
        if same_cell(snake.body[index], cell):
            return true
        index += 1

    return false


def can_turn(current_x: int, current_y: int, next_x: int, next_y: int) -> bool:
    return not (next_x == -current_x and next_y == -current_y)


def make_snake(head_x: int, head_y: int, dx: int, dy: int, color: rl.Color) -> gt.Snake:
    var snake = zero[gt.Snake]
    snake.length = 3
    snake.dir_x = dx
    snake.dir_y = dy
    snake.alive = true
    snake.score = 0
    snake.color = color

    snake.body[0] = gt.vec2i(head_x, head_y)
    snake.body[1] = gt.vec2i(head_x - dx, head_y - dy)
    snake.body[2] = gt.vec2i(head_x - (dx * 2), head_y - (dy * 2))
    return snake


def spawn_food(player: gt.Snake, enemy: gt.Snake) -> gt.Vec2i:
    var tries = 0
    while tries < 1024:
        let candidate = gt.vec2i(rl.get_random_value(0, gt.grid_width() - 1), rl.get_random_value(0, gt.grid_height() - 1))
        if not snake_contains_cell(player, candidate, 0) and not snake_contains_cell(enemy, candidate, 0):
            return candidate
        tries += 1

    return gt.vec2i(gt.grid_width() / 2, gt.grid_height() / 2)


pub def reset_game() -> gt.Game:
    let player = make_snake(6, 6, 1, 0, rl.SKYBLUE)
    let enemy = make_snake(gt.grid_width() - 7, gt.grid_height() - 7, -1, 0, rl.ORANGE)
    return gt.Game(
        player = player,
        enemy = enemy,
        food = spawn_food(player, enemy),
        tick = 0,
        state = gt.state_title(),
        winner = gt.winner_draw(),
    )


def move_snake(snake: gt.Snake, grow: bool) -> gt.Snake:
    var moved = snake
    if grow and moved.length < gt.max_body():
        moved.length += 1

    var index = moved.length - 1
    while index > 0:
        moved.body[index] = moved.body[index - 1]
        index -= 1

    moved.body[0].x += moved.dir_x
    moved.body[0].y += moved.dir_y
    return moved


def out_of_bounds(cell: gt.Vec2i) -> bool:
    return cell.x < 0 or cell.y < 0 or cell.x >= gt.grid_width() or cell.y >= gt.grid_height()


pub def update_player_direction(player: gt.Snake) -> gt.Snake:
    var next = player

    if rl.is_key_pressed(rl.KeyboardKey.KEY_UP) or rl.is_key_pressed(rl.KeyboardKey.KEY_W):
        if can_turn(next.dir_x, next.dir_y, 0, -1):
            next.dir_x = 0
            next.dir_y = -1

    if rl.is_key_pressed(rl.KeyboardKey.KEY_DOWN) or rl.is_key_pressed(rl.KeyboardKey.KEY_S):
        if can_turn(next.dir_x, next.dir_y, 0, 1):
            next.dir_x = 0
            next.dir_y = 1

    if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT) or rl.is_key_pressed(rl.KeyboardKey.KEY_A):
        if can_turn(next.dir_x, next.dir_y, -1, 0):
            next.dir_x = -1
            next.dir_y = 0

    if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT) or rl.is_key_pressed(rl.KeyboardKey.KEY_D):
        if can_turn(next.dir_x, next.dir_y, 1, 0):
            next.dir_x = 1
            next.dir_y = 0

    return next


def ai_update_direction(enemy: gt.Snake, player: gt.Snake, food: gt.Vec2i, tick: int) -> gt.Snake:
    var next = enemy
    let raw_dx = game_ai.choose_dx(next.body[0].x, food.x, tick)
    let raw_dy = game_ai.choose_dy(next.body[0].y, food.y, tick)
    let dx = game_ai.clamp_dir(raw_dx)
    let dy = game_ai.clamp_dir(raw_dy)
    let axis = game_ai.choose_axis(food.x - next.body[0].x, food.y - next.body[0].y, tick)

    if axis == 0 and dx != 0 and can_turn(next.dir_x, next.dir_y, dx, 0):
        next.dir_x = dx
        next.dir_y = 0
        return next

    if dy != 0 and can_turn(next.dir_x, next.dir_y, 0, dy):
        next.dir_x = 0
        next.dir_y = dy
        return next

    if dx != 0 and can_turn(next.dir_x, next.dir_y, dx, 0):
        next.dir_x = dx
        next.dir_y = 0
        return next

    let fallback_axis = game_ai.choose_axis(player.body[0].x - next.body[0].x, player.body[0].y - next.body[0].y, tick)
    if fallback_axis == 0 and can_turn(next.dir_x, next.dir_y, 1, 0):
        next.dir_x = 1
        next.dir_y = 0
    elif can_turn(next.dir_x, next.dir_y, 0, 1):
        next.dir_x = 0
        next.dir_y = 1

    return next


def evaluate_collisions(game: gt.Game) -> gt.Game:
    var next = game
    if out_of_bounds(next.player.body[0]) or snake_contains_cell(next.player, next.player.body[0], 1) or snake_contains_cell(next.enemy, next.player.body[0], 0):
        next.player.alive = false

    if out_of_bounds(next.enemy.body[0]) or snake_contains_cell(next.enemy, next.enemy.body[0], 1) or snake_contains_cell(next.player, next.enemy.body[0], 0):
        next.enemy.alive = false

    if same_cell(next.player.body[0], next.enemy.body[0]):
        next.player.alive = false
        next.enemy.alive = false

    return next


pub def step_game(game: gt.Game) -> gt.Game:
    var next = game
    next.enemy = ai_update_direction(next.enemy, next.player, next.food, next.tick)

    let player_eats = same_cell(gt.vec2i(next.player.body[0].x + next.player.dir_x, next.player.body[0].y + next.player.dir_y), next.food)
    let enemy_eats = same_cell(gt.vec2i(next.enemy.body[0].x + next.enemy.dir_x, next.enemy.body[0].y + next.enemy.dir_y), next.food)

    next.player = move_snake(next.player, player_eats)
    next.enemy = move_snake(next.enemy, enemy_eats)

    if player_eats:
        next.player.score += 1
    if enemy_eats:
        next.enemy.score += 1
    if player_eats or enemy_eats:
        next.food = spawn_food(next.player, next.enemy)

    next = evaluate_collisions(next)

    if not next.player.alive or not next.enemy.alive:
        next.state = gt.state_game_over()
        if next.player.alive and not next.enemy.alive:
            next.winner = gt.winner_player()
        elif next.enemy.alive and not next.player.alive:
            next.winner = gt.winner_enemy()
        else:
            next.winner = gt.winner_draw()

    next.tick += 1
    return next

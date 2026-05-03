module examples.raylib.core.core_undo_redo

import std.c.raylib as rl

struct Point:
    x: i32
    y: i32

struct PlayerState:
    cell: Point
    color: rl.Color

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [core] example - undo redo"
const max_undo_states: i32 = 26
const grid_cell_size: i32 = 24
const max_grid_cells_x: i32 = 30
const max_grid_cells_y: i32 = 13


def player_states_equal(left: PlayerState, right: PlayerState) -> bool:
    return (
        left.cell.x == right.cell.x and
        left.cell.y == right.cell.y and
        left.color.r == right.color.r and
        left.color.g == right.color.g and
        left.color.b == right.color.b and
        left.color.a == right.color.a
    )


def random_player_color() -> rl.Color:
    return rl.Color(
        r = rl.GetRandomValue(20, 255),
        g = rl.GetRandomValue(20, 220),
        b = rl.GetRandomValue(20, 240),
        a = 255,
    )


def initialize_states(states: ref[array[PlayerState, 26]], player: PlayerState) -> void:
    var items = read(states)
    var index = 0
    while index < max_undo_states:
        items[index] = player
        index += 1
    read(states) = items
    return


def clamp_player(player: ref[PlayerState]) -> void:
    if player.cell.x < 0:
        player.cell.x = 0
    elif player.cell.x >= max_grid_cells_x:
        player.cell.x = max_grid_cells_x - 1

    if player.cell.y < 0:
        player.cell.y = 0
    elif player.cell.y >= max_grid_cells_y:
        player.cell.y = max_grid_cells_y - 1
    return


def draw_recorded_cell(state: PlayerState, grid_position: rl.Vector2, color: rl.Color) -> void:
    rl.DrawRectangle(
        i32<-grid_position.x + state.cell.x * grid_cell_size,
        i32<-grid_position.y + state.cell.y * grid_cell_size,
        grid_cell_size,
        grid_cell_size,
        color,
    )
    return


def draw_recorded_cells_range(states: array[PlayerState, 26], start_index: i32, end_index: i32, grid_position: rl.Vector2) -> void:
    var index = start_index
    while index < end_index:
        draw_recorded_cell(states[index], grid_position, rl.LIGHTGRAY)
        index += 1
    return


def draw_recorded_cells(states: array[PlayerState, 26], first_undo_index: i32, last_undo_index: i32, current_undo_index: i32, grid_position: rl.Vector2) -> void:
    if last_undo_index > first_undo_index:
        draw_recorded_cells_range(states, first_undo_index, current_undo_index, grid_position)
    elif first_undo_index > last_undo_index:
        if current_undo_index > last_undo_index:
            draw_recorded_cells_range(states, first_undo_index, current_undo_index, grid_position)
        else:
            draw_recorded_cells_range(states, first_undo_index, max_undo_states, grid_position)
            draw_recorded_cells_range(states, 0, current_undo_index, grid_position)
    return


def draw_grid(grid_position: rl.Vector2) -> void:
    var y = 0
    while y <= max_grid_cells_y:
        rl.DrawLine(
            i32<-grid_position.x,
            i32<-grid_position.y + y * grid_cell_size,
            i32<-grid_position.x + max_grid_cells_x * grid_cell_size,
            i32<-grid_position.y + y * grid_cell_size,
            rl.GRAY,
        )
        y += 1

    var x = 0
    while x <= max_grid_cells_x:
        rl.DrawLine(
            i32<-grid_position.x + x * grid_cell_size,
            i32<-grid_position.y,
            i32<-grid_position.x + x * grid_cell_size,
            i32<-grid_position.y + max_grid_cells_y * grid_cell_size,
            rl.GRAY,
        )
        x += 1
    return


def draw_undo_slots_range(position: rl.Vector2, slot_size: i32, start_index: i32, end_index: i32, fill_color: rl.Color, line_color: rl.Color) -> void:
    var index = start_index
    while index < end_index:
        rl.DrawRectangle(i32<-position.x + slot_size * index, i32<-position.y, slot_size, slot_size, fill_color)
        rl.DrawRectangleLines(i32<-position.x + slot_size * index, i32<-position.y, slot_size, slot_size, line_color)
        index += 1
    return


def draw_undo_buffer(position: rl.Vector2, first_undo_index: i32, last_undo_index: i32, current_undo_index: i32, slot_size: i32) -> void:
    rl.DrawRectangle(i32<-position.x + 8 + slot_size * current_undo_index, i32<-position.y - 10, 8, 8, rl.RED)
    rl.DrawRectangleLines(i32<-position.x + 2 + slot_size * first_undo_index, i32<-position.y + 27, 8, 8, rl.BLACK)
    rl.DrawRectangle(i32<-position.x + 14 + slot_size * last_undo_index, i32<-position.y + 27, 8, 8, rl.BLACK)

    var index = 0
    while index < max_undo_states:
        rl.DrawRectangle(i32<-position.x + slot_size * index, i32<-position.y, slot_size, slot_size, rl.LIGHTGRAY)
        rl.DrawRectangleLines(i32<-position.x + slot_size * index, i32<-position.y, slot_size, slot_size, rl.GRAY)
        index += 1

    if first_undo_index <= last_undo_index:
        draw_undo_slots_range(position, slot_size, first_undo_index, last_undo_index + 1, rl.SKYBLUE, rl.BLUE)
    else:
        draw_undo_slots_range(position, slot_size, first_undo_index, max_undo_states, rl.SKYBLUE, rl.BLUE)
        draw_undo_slots_range(position, slot_size, 0, last_undo_index + 1, rl.SKYBLUE, rl.BLUE)

    if first_undo_index < current_undo_index:
        draw_undo_slots_range(position, slot_size, first_undo_index, current_undo_index, rl.GREEN, rl.LIME)
    elif current_undo_index < first_undo_index:
        draw_undo_slots_range(position, slot_size, first_undo_index, max_undo_states, rl.GREEN, rl.LIME)
        draw_undo_slots_range(position, slot_size, 0, current_undo_index, rl.GREEN, rl.LIME)

    rl.DrawRectangle(i32<-position.x + slot_size * current_undo_index, i32<-position.y, slot_size, slot_size, rl.GOLD)
    rl.DrawRectangleLines(i32<-position.x + slot_size * current_undo_index, i32<-position.y, slot_size, slot_size, rl.ORANGE)
    return


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var current_undo_index = 0
    var first_undo_index = 0
    var last_undo_index = 0
    var undo_frame_counter = 0
    let undo_info_pos = rl.Vector2(x = 110.0, y = 400.0)

    var player = PlayerState(
        cell = Point(x = 10, y = 10),
        color = rl.RED,
    )

    var states = zero[array[PlayerState, 26]]()
    initialize_states(ref_of(states), player)

    let grid_position = rl.Vector2(x = 40.0, y = 60.0)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_RIGHT):
            player.cell.x += 1
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_LEFT):
            player.cell.x -= 1
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_UP):
            player.cell.y -= 1
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_DOWN):
            player.cell.y += 1

        clamp_player(ref_of(player))

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE):
            player.color = random_player_color()

        undo_frame_counter += 1
        if undo_frame_counter >= 2:
            if not player_states_equal(states[current_undo_index], player):
                current_undo_index += 1
                if current_undo_index >= max_undo_states:
                    current_undo_index = 0
                if current_undo_index == first_undo_index:
                    first_undo_index += 1
                    if first_undo_index >= max_undo_states:
                        first_undo_index = 0

                states[current_undo_index] = player
                last_undo_index = current_undo_index

            undo_frame_counter = 0

        if rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT_CONTROL) and rl.IsKeyPressed(rl.KeyboardKey.KEY_Z):
            if current_undo_index != first_undo_index:
                current_undo_index -= 1
                if current_undo_index < 0:
                    current_undo_index = max_undo_states - 1

                if not player_states_equal(states[current_undo_index], player):
                    player = states[current_undo_index]

        if rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT_CONTROL) and rl.IsKeyPressed(rl.KeyboardKey.KEY_Y):
            if current_undo_index != last_undo_index:
                var next_undo_index = current_undo_index + 1
                if next_undo_index >= max_undo_states:
                    next_undo_index = 0

                if next_undo_index != first_undo_index:
                    current_undo_index = next_undo_index

                    if not player_states_equal(states[current_undo_index], player):
                        player = states[current_undo_index]

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawText(c"[ARROWS] MOVE PLAYER - [SPACE] CHANGE PLAYER COLOR", 40, 20, 20, rl.DARKGRAY)

        draw_recorded_cells(states, first_undo_index, last_undo_index, current_undo_index, grid_position)
        draw_grid(grid_position)

        rl.DrawRectangle(
            i32<-grid_position.x + player.cell.x * grid_cell_size,
            i32<-grid_position.y + player.cell.y * grid_cell_size,
            grid_cell_size + 1,
            grid_cell_size + 1,
            player.color,
        )

        rl.DrawText(c"UNDO STATES:", i32<-undo_info_pos.x - 85, i32<-undo_info_pos.y + 9, 10, rl.DARKGRAY)
        draw_undo_buffer(undo_info_pos, first_undo_index, last_undo_index, current_undo_index, 24)

    return 0

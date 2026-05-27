import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_UNDO_STATES: int = 26
const GRID_CELL_SIZE: int = 24
const MAX_GRID_CELLS_X: int = 30
const MAX_GRID_CELLS_Y: int = 13


struct Point:
    x: int
    y: int


struct PlayerState:
    cell: Point
    color: rl.Color


function states_equal(left: PlayerState, right: PlayerState) -> bool:
    return left.cell.x == right.cell.x and left.cell.y == right.cell.y and left.color.r == right.color.r and left.color.g == right.color.g and left.color.b == right.color.b and left.color.a == right.color.a


function draw_undo_buffer(position: rl.Vector2, first_undo_index: int, last_undo_index: int, current_undo_index: int, slot_size: int) -> void:
    rl.draw_rectangle(int<-position.x + 8 + slot_size * current_undo_index, int<-position.y - 10, 8, 8, rl.RED)
    rl.draw_rectangle_lines(int<-position.x + 2 + slot_size * first_undo_index, int<-position.y + 27, 8, 8, rl.BLACK)
    rl.draw_rectangle(int<-position.x + 14 + slot_size * last_undo_index, int<-position.y + 27, 8, 8, rl.BLACK)

    var index = 0
    while index < MAX_UNDO_STATES:
        rl.draw_rectangle(int<-position.x + slot_size * index, int<-position.y, slot_size, slot_size, rl.LIGHTGRAY)
        rl.draw_rectangle_lines(int<-position.x + slot_size * index, int<-position.y, slot_size, slot_size, rl.GRAY)
        index += 1

    if first_undo_index <= last_undo_index:
        var index = first_undo_index
        while index <= last_undo_index:
            rl.draw_rectangle(int<-position.x + slot_size * index, int<-position.y, slot_size, slot_size, rl.SKYBLUE)
            rl.draw_rectangle_lines(int<-position.x + slot_size * index, int<-position.y, slot_size, slot_size, rl.BLUE)
            index += 1
    else:
        var index = first_undo_index
        while index < MAX_UNDO_STATES:
            rl.draw_rectangle(int<-position.x + slot_size * index, int<-position.y, slot_size, slot_size, rl.SKYBLUE)
            rl.draw_rectangle_lines(int<-position.x + slot_size * index, int<-position.y, slot_size, slot_size, rl.BLUE)
            index += 1
        index = 0
        while index <= last_undo_index:
            rl.draw_rectangle(int<-position.x + slot_size * index, int<-position.y, slot_size, slot_size, rl.SKYBLUE)
            rl.draw_rectangle_lines(int<-position.x + slot_size * index, int<-position.y, slot_size, slot_size, rl.BLUE)
            index += 1

    if first_undo_index < current_undo_index:
        var index = first_undo_index
        while index < current_undo_index:
            rl.draw_rectangle(int<-position.x + slot_size * index, int<-position.y, slot_size, slot_size, rl.GREEN)
            rl.draw_rectangle_lines(int<-position.x + slot_size * index, int<-position.y, slot_size, slot_size, rl.LIME)
            index += 1
    else if current_undo_index < first_undo_index:
        var index = first_undo_index
        while index < MAX_UNDO_STATES:
            rl.draw_rectangle(int<-position.x + slot_size * index, int<-position.y, slot_size, slot_size, rl.GREEN)
            rl.draw_rectangle_lines(int<-position.x + slot_size * index, int<-position.y, slot_size, slot_size, rl.LIME)
            index += 1
        index = 0
        while index < current_undo_index:
            rl.draw_rectangle(int<-position.x + slot_size * index, int<-position.y, slot_size, slot_size, rl.GREEN)
            rl.draw_rectangle_lines(int<-position.x + slot_size * index, int<-position.y, slot_size, slot_size, rl.LIME)
            index += 1

    rl.draw_rectangle(int<-position.x + slot_size * current_undo_index, int<-position.y, slot_size, slot_size, rl.GOLD)
    rl.draw_rectangle_lines(int<-position.x + slot_size * current_undo_index, int<-position.y, slot_size, slot_size, rl.ORANGE)


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - undo redo")
    defer rl.close_window()

    var current_undo_index = 0
    var first_undo_index = 0
    var last_undo_index = 0
    var undo_frame_counter = 0
    let undo_info_pos = rl.Vector2(x = 110.0, y = 400.0)

    var player = PlayerState(cell = Point(x = 10, y = 10), color = rl.RED)
    var states: array[PlayerState, MAX_UNDO_STATES] = zero[array[PlayerState, MAX_UNDO_STATES]]
    var index = 0
    while index < MAX_UNDO_STATES:
        states[index] = player
        index += 1

    let grid_position = rl.Vector2(x = 40.0, y = 60.0)
    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT):
            player.cell.x += 1
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT):
            player.cell.x -= 1
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_UP):
            player.cell.y -= 1
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_DOWN):
            player.cell.y += 1

        if player.cell.x < 0:
            player.cell.x = 0
        else if player.cell.x >= MAX_GRID_CELLS_X:
            player.cell.x = MAX_GRID_CELLS_X - 1
        if player.cell.y < 0:
            player.cell.y = 0
        else if player.cell.y >= MAX_GRID_CELLS_Y:
            player.cell.y = MAX_GRID_CELLS_Y - 1

        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            player.color.r = ubyte<-rl.get_random_value(20, 255)
            player.color.g = ubyte<-rl.get_random_value(20, 220)
            player.color.b = ubyte<-rl.get_random_value(20, 240)

        undo_frame_counter += 1
        if undo_frame_counter >= 2:
            if not states_equal(states[current_undo_index], player):
                current_undo_index += 1
                if current_undo_index >= MAX_UNDO_STATES:
                    current_undo_index = 0
                if current_undo_index == first_undo_index:
                    first_undo_index += 1
                if first_undo_index >= MAX_UNDO_STATES:
                    first_undo_index = 0

                states[current_undo_index] = player
                last_undo_index = current_undo_index
            undo_frame_counter = 0

        if rl.is_key_down(rl.KeyboardKey.KEY_LEFT_CONTROL) and rl.is_key_pressed(rl.KeyboardKey.KEY_Z):
            if current_undo_index != first_undo_index:
                current_undo_index -= 1
                if current_undo_index < 0:
                    current_undo_index = MAX_UNDO_STATES - 1
                if not states_equal(states[current_undo_index], player):
                    player = states[current_undo_index]

        if rl.is_key_down(rl.KeyboardKey.KEY_LEFT_CONTROL) and rl.is_key_pressed(rl.KeyboardKey.KEY_Y):
            if current_undo_index != last_undo_index:
                var next_undo_index = current_undo_index + 1
                if next_undo_index >= MAX_UNDO_STATES:
                    next_undo_index = 0
                if next_undo_index != first_undo_index:
                    current_undo_index = next_undo_index
                    if not states_equal(states[current_undo_index], player):
                        player = states[current_undo_index]

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)
        rl.draw_text("[ARROWS] MOVE PLAYER - [SPACE] CHANGE PLAYER COLOR", 40, 20, 20, rl.DARKGRAY)

        if last_undo_index > first_undo_index:
            var index = first_undo_index
            while index < current_undo_index:
                rl.draw_rectangle_rec(
                    rl.Rectangle(x = grid_position.x + float<-(states[index].cell.x * GRID_CELL_SIZE), y = grid_position.y + float<-(states[index].cell.y * GRID_CELL_SIZE), width = float<-GRID_CELL_SIZE, height = float<-GRID_CELL_SIZE),
                    rl.LIGHTGRAY,
                )
                index += 1
        else if first_undo_index > last_undo_index:
            if current_undo_index < MAX_UNDO_STATES and current_undo_index > last_undo_index:
                var index = first_undo_index
                while index < current_undo_index:
                    rl.draw_rectangle_rec(
                        rl.Rectangle(x = grid_position.x + float<-(states[index].cell.x * GRID_CELL_SIZE), y = grid_position.y + float<-(states[index].cell.y * GRID_CELL_SIZE), width = float<-GRID_CELL_SIZE, height = float<-GRID_CELL_SIZE),
                        rl.LIGHTGRAY,
                    )
                    index += 1
            else:
                var index = first_undo_index
                while index < MAX_UNDO_STATES:
                    rl.draw_rectangle(int<-grid_position.x + states[index].cell.x * GRID_CELL_SIZE, int<-grid_position.y + states[index].cell.y * GRID_CELL_SIZE, GRID_CELL_SIZE, GRID_CELL_SIZE, rl.LIGHTGRAY)
                    index += 1
                index = 0
                while index < current_undo_index:
                    rl.draw_rectangle(int<-grid_position.x + states[index].cell.x * GRID_CELL_SIZE, int<-grid_position.y + states[index].cell.y * GRID_CELL_SIZE, GRID_CELL_SIZE, GRID_CELL_SIZE, rl.LIGHTGRAY)
                    index += 1

        var y = 0
        while y <= MAX_GRID_CELLS_Y:
            rl.draw_line(int<-grid_position.x, int<-grid_position.y + y * GRID_CELL_SIZE, int<-grid_position.x + MAX_GRID_CELLS_X * GRID_CELL_SIZE, int<-grid_position.y + y * GRID_CELL_SIZE, rl.GRAY)
            y += 1
        var x = 0
        while x <= MAX_GRID_CELLS_X:
            rl.draw_line(int<-grid_position.x + x * GRID_CELL_SIZE, int<-grid_position.y, int<-grid_position.x + x * GRID_CELL_SIZE, int<-grid_position.y + MAX_GRID_CELLS_Y * GRID_CELL_SIZE, rl.GRAY)
            x += 1

        rl.draw_rectangle(int<-grid_position.x + player.cell.x * GRID_CELL_SIZE, int<-grid_position.y + player.cell.y * GRID_CELL_SIZE, GRID_CELL_SIZE + 1, GRID_CELL_SIZE + 1, player.color)
        rl.draw_text("UNDO STATES:", int<-undo_info_pos.x - 85, int<-undo_info_pos.y + 9, 10, rl.DARKGRAY)
        draw_undo_buffer(undo_info_pos, first_undo_index, last_undo_index, current_undo_index, 24)
        rl.end_drawing()

    return 0

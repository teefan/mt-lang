module game_engine

import std.raylib as rl

const board_width: int = 10
const board_height: int = 20
const board_cells: int = 200
const cell_size: int = 28
const tile_size: int = 16
const board_left: int = 56
const board_top: int = 44
const preview_left: int = 388
const preview_top: int = 104
const window_width: int = 640
const window_height: int = 700

const piece_i: int = 1
const piece_j: int = 2
const piece_l: int = 3
const piece_o: int = 4
const piece_s: int = 5
const piece_t: int = 6
const piece_z: int = 7

struct Cell:
    x: int
    y: int

struct Piece:
    kind: int
    rotation: int
    x: int
    y: int

struct Game:
    board: array[int, 200]
    active: Piece
    next_kind: int
    score: int
    lines: int
    level: int
    drop_timer: float
    cleared_flash: float
    game_over: bool

const cells_i_0: array[Cell, 4] = array[Cell, 4](Cell(x = 0, y = 1), Cell(x = 1, y = 1), Cell(x = 2, y = 1), Cell(x = 3, y = 1))
const cells_i_1: array[Cell, 4] = array[Cell, 4](Cell(x = 2, y = 0), Cell(x = 2, y = 1), Cell(x = 2, y = 2), Cell(x = 2, y = 3))
const cells_j_0: array[Cell, 4] = array[Cell, 4](Cell(x = 0, y = 0), Cell(x = 0, y = 1), Cell(x = 1, y = 1), Cell(x = 2, y = 1))
const cells_j_1: array[Cell, 4] = array[Cell, 4](Cell(x = 1, y = 0), Cell(x = 2, y = 0), Cell(x = 1, y = 1), Cell(x = 1, y = 2))
const cells_j_2: array[Cell, 4] = array[Cell, 4](Cell(x = 0, y = 1), Cell(x = 1, y = 1), Cell(x = 2, y = 1), Cell(x = 2, y = 2))
const cells_j_3: array[Cell, 4] = array[Cell, 4](Cell(x = 1, y = 0), Cell(x = 1, y = 1), Cell(x = 0, y = 2), Cell(x = 1, y = 2))
const cells_l_0: array[Cell, 4] = array[Cell, 4](Cell(x = 2, y = 0), Cell(x = 0, y = 1), Cell(x = 1, y = 1), Cell(x = 2, y = 1))
const cells_l_1: array[Cell, 4] = array[Cell, 4](Cell(x = 1, y = 0), Cell(x = 1, y = 1), Cell(x = 1, y = 2), Cell(x = 2, y = 2))
const cells_l_2: array[Cell, 4] = array[Cell, 4](Cell(x = 0, y = 1), Cell(x = 1, y = 1), Cell(x = 2, y = 1), Cell(x = 0, y = 2))
const cells_l_3: array[Cell, 4] = array[Cell, 4](Cell(x = 0, y = 0), Cell(x = 1, y = 0), Cell(x = 1, y = 1), Cell(x = 1, y = 2))
const cells_o: array[Cell, 4] = array[Cell, 4](Cell(x = 1, y = 0), Cell(x = 2, y = 0), Cell(x = 1, y = 1), Cell(x = 2, y = 1))
const cells_s_0: array[Cell, 4] = array[Cell, 4](Cell(x = 1, y = 0), Cell(x = 2, y = 0), Cell(x = 0, y = 1), Cell(x = 1, y = 1))
const cells_s_1: array[Cell, 4] = array[Cell, 4](Cell(x = 1, y = 0), Cell(x = 1, y = 1), Cell(x = 2, y = 1), Cell(x = 2, y = 2))
const cells_t_0: array[Cell, 4] = array[Cell, 4](Cell(x = 1, y = 0), Cell(x = 0, y = 1), Cell(x = 1, y = 1), Cell(x = 2, y = 1))
const cells_t_1: array[Cell, 4] = array[Cell, 4](Cell(x = 1, y = 0), Cell(x = 1, y = 1), Cell(x = 2, y = 1), Cell(x = 1, y = 2))
const cells_t_2: array[Cell, 4] = array[Cell, 4](Cell(x = 0, y = 1), Cell(x = 1, y = 1), Cell(x = 2, y = 1), Cell(x = 1, y = 2))
const cells_t_3: array[Cell, 4] = array[Cell, 4](Cell(x = 1, y = 0), Cell(x = 0, y = 1), Cell(x = 1, y = 1), Cell(x = 1, y = 2))
const cells_z_0: array[Cell, 4] = array[Cell, 4](Cell(x = 0, y = 0), Cell(x = 1, y = 0), Cell(x = 1, y = 1), Cell(x = 2, y = 1))
const cells_z_1: array[Cell, 4] = array[Cell, 4](Cell(x = 2, y = 0), Cell(x = 1, y = 1), Cell(x = 2, y = 1), Cell(x = 1, y = 2))


function make_game() -> Game:
    var game = zero[Game]
    game.reset()
    return game


function random_kind() -> int:
    return rl.get_random_value(piece_i, piece_z)


function shape_cells(kind: int, rotation: int) -> array[Cell, 4]:
    let spin = rotation % 4

    if kind == piece_i:
        if spin == 0 or spin == 2:
            return cells_i_0
        return cells_i_1

    if kind == piece_j:
        if spin == 0:
            return cells_j_0
        elif spin == 1:
            return cells_j_1
        elif spin == 2:
            return cells_j_2
        return cells_j_3

    if kind == piece_l:
        if spin == 0:
            return cells_l_0
        elif spin == 1:
            return cells_l_1
        elif spin == 2:
            return cells_l_2
        return cells_l_3

    if kind == piece_o:
        return cells_o

    if kind == piece_s:
        if spin == 0 or spin == 2:
            return cells_s_0
        return cells_s_1

    if kind == piece_t:
        if spin == 0:
            return cells_t_0
        elif spin == 1:
            return cells_t_1
        elif spin == 2:
            return cells_t_2
        return cells_t_3

    if spin == 0 or spin == 2:
        return cells_z_0
    return cells_z_1


function tile_source_rect(tile_id: int) -> rl.Rectangle:
    return rl.Rectangle(
        x = float<-((tile_id - 1) * tile_size),
        y = 0.0,
        width = float<-tile_size,
        height = float<-tile_size,
    )


function board_index(x: int, y: int) -> int:
    return y * board_width + x


function gravity_seconds(level: int) -> float:
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


methods Game:
    editable function reset():
        this.board = zero[array[int, 200]]
        this.next_kind = random_kind()
        this.score = 0
        this.lines = 0
        this.level = 0
        this.drop_timer = 0.0
        this.cleared_flash = 0.0
        this.game_over = false
        this.spawn_next_piece()


    editable function spawn_next_piece():
        this.active = Piece(kind = this.next_kind, rotation = 0, x = 3, y = 0)
        this.next_kind = random_kind()
        this.drop_timer = 0.0

        if this.collides(this.active, 0, 0, this.active.rotation):
            this.game_over = true


    editable function collides(piece: Piece, move_x: int, move_y: int, next_rotation: int) -> bool:
        let cells = shape_cells(piece.kind, next_rotation)

        for i in 0..4:
            let cell = cells[i]
            let board_x = piece.x + cell.x + move_x
            let board_y = piece.y + cell.y + move_y

            if board_x < 0 or board_x >= board_width:
                return true

            if board_y >= board_height:
                return true

            if board_y >= 0 and this.board[board_index(board_x, board_y)] != 0:
                return true

        return false


    editable function try_move(delta_x: int, delta_y: int) -> bool:
        if this.collides(this.active, delta_x, delta_y, this.active.rotation):
            return false

        this.active.x += delta_x
        this.active.y += delta_y
        return true


    editable function try_rotate(delta: int) -> bool:
        let next_rotation = (this.active.rotation + delta + 4) % 4
        if not this.collides(this.active, 0, 0, next_rotation):
            this.active.rotation = next_rotation
            return true

        if not this.collides(this.active, -1, 0, next_rotation):
            this.active.x -= 1
            this.active.rotation = next_rotation
            return true

        if not this.collides(this.active, 1, 0, next_rotation):
            this.active.x += 1
            this.active.rotation = next_rotation
            return true

        return false


    editable function lock_piece(effect: rl.Sound):
        let cells = shape_cells(this.active.kind, this.active.rotation)

        for i in 0..4:
            let cell = cells[i]
            let board_x = this.active.x + cell.x
            let board_y = this.active.y + cell.y
            if board_y >= 0:
                this.board[board_index(board_x, board_y)] = this.active.kind

        let cleared = this.clear_full_rows()
        if cleared > 0:
            this.lines += cleared
            this.level = this.lines / 10
            this.score += cleared * cleared * 100 * (this.level + 1)
            this.cleared_flash = 0.18
            rl.play_sound(effect)
        else:
            this.score += 12

        this.spawn_next_piece()


    editable function clear_full_rows() -> int:
        var cleared = 0
        var y = board_height

        while y > 0:
            y -= 1

            var full = true
            for x in 0..board_width:
                if this.board[board_index(x, y)] == 0:
                    full = false

            if not full:
                continue

            var pull = y
            while pull > 0:
                for x in 0..board_width:
                    this.board[board_index(x, pull)] = this.board[board_index(x, pull - 1)]
                pull -= 1

            for x in 0..board_width:
                this.board[board_index(x, 0)] = 0

            cleared += 1
            y += 1

        return cleared


    editable function hard_drop(effect: rl.Sound):
        while this.try_move(0, 1):
            this.score += 2

        this.lock_piece(effect)


    editable function update(effect: rl.Sound):
        if this.cleared_flash > 0.0:
            this.cleared_flash -= rl.get_frame_time()
            if this.cleared_flash < 0.0:
                this.cleared_flash = 0.0

        if this.game_over:
            if rl.is_key_pressed(rl.KeyboardKey.KEY_ENTER) or rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
                this.reset()
            return

        if rl.is_key_pressed_repeat(rl.KeyboardKey.KEY_LEFT):
            this.try_move(-1, 0)

        if rl.is_key_pressed_repeat(rl.KeyboardKey.KEY_RIGHT):
            this.try_move(1, 0)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_UP) or rl.is_key_pressed(rl.KeyboardKey.KEY_X):
            this.try_rotate(1)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_Z):
            this.try_rotate(-1)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            this.hard_drop(effect)
            return

        let drop_scale = if rl.is_key_down(rl.KeyboardKey.KEY_DOWN): 0.12 else: 1.0
        this.drop_timer += rl.get_frame_time()

        if this.drop_timer < gravity_seconds(this.level) * drop_scale:
            return

        this.drop_timer = 0.0
        if not this.try_move(0, 1):
            this.lock_piece(effect)


    function draw_block(texture: rl.Texture2D, tile_id: int, x: int, y: int, scale: float) -> void:
        let source = tile_source_rect(tile_id)
        let destination = rl.Rectangle(
            x = float<-x,
            y = float<-y,
            width = float<-cell_size * scale,
            height = float<-cell_size * scale,
        )
        rl.draw_texture_pro(texture, source, destination, rl.Vector2(x = 0.0, y = 0.0), 0.0, rl.WHITE)


    function draw_board(texture: rl.Texture2D) -> void:
        rl.draw_rectangle_rounded(
            rl.Rectangle(x = float<-(board_left - 12), y = float<-(board_top - 12), width = float<-(board_width * cell_size + 24), height = float<-(board_height * cell_size + 24)),
            0.08,
            8,
            rl.Color(r = 20, g = 27, b = 43, a = 255),
        )
        rl.draw_rectangle_lines_ex(
            rl.Rectangle(x = float<-(board_left - 12), y = float<-(board_top - 12), width = float<-(board_width * cell_size + 24), height = float<-(board_height * cell_size + 24)),
            3.0,
            rl.Color(r = 72, g = 92, b = 138, a = 255),
        )

        for y in 0..board_height:
            for x in 0..board_width:
                let px = board_left + x * cell_size
                let py = board_top + y * cell_size
                rl.draw_rectangle(px, py, cell_size - 2, cell_size - 2, rl.Color(r = 10, g = 14, b = 24, a = 255))
                let tile_id = this.board[board_index(x, y)]
                if tile_id != 0:
                    this.draw_block(texture, tile_id, px, py, 1.0)

        if this.game_over:
            return

        let cells = shape_cells(this.active.kind, this.active.rotation)
        for i in 0..4:
            let cell = cells[i]
            let px = board_left + (this.active.x + cell.x) * cell_size
            let py = board_top + (this.active.y + cell.y) * cell_size
            this.draw_block(texture, this.active.kind, px, py, 1.0)


    function draw_preview(texture: rl.Texture2D) -> void:
        rl.draw_rectangle_rounded(
            rl.Rectangle(x = float<-(preview_left - 18), y = float<-(preview_top - 28), width = 190.0, height = 180.0),
            0.12,
            8,
            rl.Color(r = 20, g = 27, b = 43, a = 255),
        )
        rl.draw_text("NEXT", preview_left, preview_top - 10, 26, rl.RAYWHITE)

        let cells = shape_cells(this.next_kind, 0)
        for i in 0..4:
            let cell = cells[i]
            let px = preview_left + 28 + cell.x * (cell_size - 4)
            let py = preview_top + 28 + cell.y * (cell_size - 4)
            this.draw_block(texture, this.next_kind, px, py, 0.86)


    function draw_sidebar() -> void:
        rl.draw_text("MILK TEA", preview_left, 320, 34, rl.RAYWHITE)
        rl.draw_text("TETRIS", preview_left, 356, 34, rl.GOLD)
        rl.draw_text(f"Score  #{this.score}", preview_left, 420, 24, rl.SKYBLUE)
        rl.draw_text(f"Lines  #{this.lines}", preview_left, 452, 24, rl.LIME)
        rl.draw_text(f"Level  #{this.level}", preview_left, 484, 24, rl.ORANGE)

        rl.draw_text("Move   Left / Right", preview_left, 560, 18, rl.LIGHTGRAY)
        rl.draw_text("Rotate Up / Z / X", preview_left, 584, 18, rl.LIGHTGRAY)
        rl.draw_text("Soft   Hold Down", preview_left, 608, 18, rl.LIGHTGRAY)
        rl.draw_text("Drop   Space", preview_left, 632, 18, rl.LIGHTGRAY)

        if this.cleared_flash > 0.0:
            rl.draw_text("LINE CLEAR!", preview_left, 250, 24, rl.YELLOW)

        if this.game_over:
            rl.draw_rectangle(70, 268, 500, 116, rl.Color(r = 6, g = 10, b = 18, a = 214))
            rl.draw_rectangle_lines_ex(rl.Rectangle(x = 70.0, y = 268.0, width = 500.0, height = 116.0), 3.0, rl.MAROON)
            rl.draw_text("STACK OVER", 208, 292, 36, rl.RED)
            rl.draw_text("Press Enter or Space to restart", 138, 338, 22, rl.RAYWHITE)


    function draw(texture: rl.Texture2D) -> void:
        rl.clear_background(rl.Color(r = 7, g = 10, b = 18, a = 255))
        rl.draw_rectangle_gradient_v(0, 0, window_width, window_height, rl.Color(r = 17, g = 28, b = 52, a = 255), rl.Color(r = 6, g = 10, b = 18, a = 255))
        this.draw_board(texture)
        this.draw_preview(texture)
        this.draw_sidebar()
        rl.draw_fps(window_width - 92, 10)


function main() -> int:
    rl.init_window(window_width, window_height, "Milk Tea Tetris")
    defer rl.close_window()
    rl.set_target_fps(60)

    rl.init_audio_device()
    defer rl.close_audio_device()

    let tiles = rl.load_texture("assets/tetris_tiles.png")
    defer rl.unload_texture(tiles)
    let clear_sound = rl.load_sound("assets/line_clear.wav")
    defer rl.unload_sound(clear_sound)

    var game = make_game()

    while not rl.window_should_close():
        game.update(clear_sound)

        rl.begin_drawing()
        defer rl.end_drawing()
        game.draw(tiles)

    return 0

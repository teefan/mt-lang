import platform_info as platform_info
import std.raylib as rl
import std.raylib.packed_assets as rl_assets
import std.raylib.runtime as rl_runtime
import tetris.pieces.defs as pieces
import tetris.rules.scoring as scoring

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
const horizontal_repeat_delay: float = 0.16
const horizontal_repeat_interval: float = 0.05

interface ScreenState:
    editable function update(effect: rl.Sound) -> void
    function draw(texture: rl.Texture2D) -> void

struct TitleScreen implements ScreenState:
    blink_timer: float
    start_requested: bool

struct PausedScreen implements ScreenState:
    blink_timer: float
    resume_requested: bool
    exit_requested: bool
    snapshot: Game

struct Game implements ScreenState:
    board: array[int, 200]
    active: pieces.Piece
    next_kind: int
    score: int
    lines: int
    level: int
    drop_timer: float
    horizontal_move_direction: int
    horizontal_move_repeat_timer: float
    pause_requested: bool
    exit_requested: bool
    cleared_flash: float
    game_over: bool

struct RuntimeAssets:
    tiles: rl.Texture2D
    clear_sound: rl.Sound

variant RuntimeAssetsError:
    missing_assets_directory
    packed_assets(error: rl_assets.Error)


function packed_assets_error(error: rl_assets.Error) -> RuntimeAssetsError:
    return RuntimeAssetsError.packed_assets(error = error)


function runtime_assets_exit_code(error: RuntimeAssetsError) -> int:
    match error:
        RuntimeAssetsError.missing_assets_directory:
            return 1
        RuntimeAssetsError.packed_assets as payload:
            return int<-payload.error


function make_paused_screen(game: Game) -> PausedScreen:
    return PausedScreen(
        blink_timer = 0.0,
        resume_requested = false,
        exit_requested = false,
        snapshot = game,
    )


function run_screen_frame[T implements ScreenState](screen: ref[T], texture: rl.Texture2D, effect: rl.Sound) -> void:
    screen.update(effect)

    rl.begin_drawing()
    defer rl.end_drawing()
    screen.draw(texture)


function random_kind() -> int:
    return rl.get_random_value(pieces.piece_i, pieces.piece_z)


function tile_source_rect(tile_id: int) -> rl.Rectangle:
    return rl.Rectangle(
        x = float<-((tile_id - 1) * tile_size),
        y = 0.0,
        width = float<-tile_size,
        height = float<-tile_size,
    )


function board_index(x: int, y: int) -> int:
    return y * board_width + x


function load_runtime_assets() -> Result[RuntimeAssets, RuntimeAssetsError]:
    let assets_pack = rl_assets.open_assets_pack_if_present() else as error:
        return Result[RuntimeAssets, RuntimeAssetsError].failure(error= packed_assets_error(error))

    match assets_pack:
        Option.none:
            return load_directory_runtime_assets()
        Option.some as reader_payload:
            var reader = reader_payload.value
            defer rl_assets.close_reader(ref_of(reader))
            return load_packed_runtime_assets(reader)


function load_packed_runtime_assets(reader: rl_assets.Reader) -> Result[RuntimeAssets, RuntimeAssetsError]:
    let tiles = rl_assets.load_texture(reader, "assets/tetris_tiles.png") else as error:
        return Result[RuntimeAssets, RuntimeAssetsError].failure(error= packed_assets_error(error))

    let clear_sound = rl_assets.load_sound(reader, "assets/line_clear.wav") else as error:
        rl.unload_texture(tiles)
        return Result[RuntimeAssets, RuntimeAssetsError].failure(error= packed_assets_error(error))

    return Result[RuntimeAssets, RuntimeAssetsError].success(value= RuntimeAssets(
        tiles = tiles,
        clear_sound = clear_sound
    ))


function load_directory_runtime_assets() -> Result[RuntimeAssets, RuntimeAssetsError]:
    if not rl_runtime.enter_assets_directory():
        return Result[RuntimeAssets, RuntimeAssetsError].failure(error= RuntimeAssetsError.missing_assets_directory)

    let tiles = rl.load_texture("tetris_tiles.png")
    if not rl.is_texture_valid(tiles):
        return Result[
            RuntimeAssets,
            RuntimeAssetsError
        ].failure(error= packed_assets_error(rl_assets.Error.invalid_texture))

    let clear_sound = rl.load_sound("line_clear.wav")
    if not rl.is_sound_valid(clear_sound):
        rl.unload_texture(tiles)
        return Result[
            RuntimeAssets,
            RuntimeAssetsError
        ].failure(error= packed_assets_error(rl_assets.Error.invalid_sound))

    return Result[RuntimeAssets, RuntimeAssetsError].success(value= RuntimeAssets(
        tiles = tiles,
        clear_sound = clear_sound
    ))


extending TitleScreen:
    static function default() -> TitleScreen:
        return TitleScreen(
            blink_timer = 0.0,
            start_requested = false,
        )


    editable function update(_effect: rl.Sound):
        this.blink_timer += rl.get_frame_time()

        if rl.is_key_pressed(rl.KeyboardKey.KEY_ENTER) or rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            this.start_requested = true


    function draw(_texture: rl.Texture2D) -> void:
        rl.clear_background(rl.Color(r = 7, g = 10, b = 18, a = 255))
        rl.draw_rectangle_gradient_v(
            0,
            0,
            window_width,
            window_height,
            rl.Color(r = 17, g = 28, b = 52, a = 255),
            rl.Color(r = 6, g = 10, b = 18, a = 255)
        )
        rl.draw_text("MILK TEA", 148, 168, 58, rl.RAYWHITE)
        rl.draw_text("TETRIS", 214, 236, 58, rl.GOLD)
        rl.draw_text("Stack clean lines and survive the climb.", 108, 334, 24, rl.SKYBLUE)
        rl.draw_text("Left/Right move  Up/Z/X rotate", 126, 404, 22, rl.LIGHTGRAY)
        rl.draw_text("Down soft drop   Space hard drop", 114, 434, 22, rl.LIGHTGRAY)
        rl.draw_text("P pauses the run, Esc returns here", 124, 466, 20, rl.GRAY)

        let blink = int<-(this.blink_timer * 3.0)
        if blink % 2 == 0:
            rl.draw_text("Press Enter or Space to start", 142, 544, 28, rl.WHITE)


extending RuntimeAssets:
    editable function release():
        rl.unload_texture(this.tiles)
        rl.unload_sound(this.clear_sound)


extending PausedScreen:
    editable function update(_effect: rl.Sound):
        this.blink_timer += rl.get_frame_time()

        if (
            rl.is_key_pressed(rl.KeyboardKey.KEY_ENTER)
            or rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE)
            or rl.is_key_pressed(rl.KeyboardKey.KEY_P)
        ):
            this.resume_requested = true

        if rl.is_key_pressed(rl.KeyboardKey.KEY_ESCAPE):
            this.exit_requested = true


    function draw(texture: rl.Texture2D) -> void:
        this.snapshot.draw(texture)
        rl.draw_rectangle(0, 0, window_width, window_height, rl.Color(r = 6, g = 10, b = 18, a = 164))
        rl.draw_rectangle_rounded(
            rl.Rectangle(x = 140.0, y = 170.0, width = 360.0, height = 316.0),
            0.12,
            10,
            rl.Color(r = 18, g = 26, b = 44, a = 244)
        )
        rl.draw_rectangle_lines_ex(
            rl.Rectangle(x = 140.0, y = 170.0, width = 360.0, height = 316.0),
            3.0,
            rl.Color(r = 87, g = 111, b = 166, a = 255)
        )
        rl.draw_text("PAUSED", 236, 212, 54, rl.RAYWHITE)
        rl.draw_text("Frozen board. Same stack, same next piece.", 152, 286, 22, rl.SKYBLUE)
        rl.draw_text(f"Score  #{this.snapshot.score}", 186, 344, 26, rl.GOLD)
        rl.draw_text(f"Lines  #{this.snapshot.lines}", 186, 378, 26, rl.LIME)
        rl.draw_text(f"Level  #{this.snapshot.level}", 186, 412, 26, rl.ORANGE)
        rl.draw_text("Enter / Space / P resumes", 160, 454, 22, rl.LIGHTGRAY)
        rl.draw_text("Esc returns to title", 196, 482, 20, rl.GRAY)

        let blink = int<-(this.blink_timer * 3.0)
        if blink % 2 == 0:
            rl.draw_text("Press a key to continue", 176, 526, 24, rl.WHITE)


extending Game:
    static function default() -> Game:
        var game = Game(
            board = zero[array[int, 200]],
            active = default[pieces.Piece],
            next_kind = random_kind(),
            score = 0,
            lines = 0,
            level = 0,
            drop_timer = 0.0,
            horizontal_move_direction = 0,
            horizontal_move_repeat_timer = 0.0,
            pause_requested = false,
            exit_requested = false,
            cleared_flash = 0.0,
            game_over = false,
        )
        game.spawn_next_piece()
        return game


    editable function reset():
        this.board = zero[array[int, 200]]
        this.next_kind = random_kind()
        this.score = 0
        this.lines = 0
        this.level = 0
        this.drop_timer = 0.0
        this.horizontal_move_direction = 0
        this.horizontal_move_repeat_timer = 0.0
        this.pause_requested = false
        this.exit_requested = false
        this.cleared_flash = 0.0
        this.game_over = false
        this.spawn_next_piece()


    editable function spawn_next_piece():
        this.active = pieces.Piece(kind = this.next_kind, rotation = 0, x = 3, y = 0)
        this.next_kind = random_kind()
        this.drop_timer = 0.0
        this.horizontal_move_direction = 0
        this.horizontal_move_repeat_timer = 0.0
        this.pause_requested = false
        this.exit_requested = false

        if this.collides(this.active, 0, 0, this.active.rotation):
            this.game_over = true


    editable function collides(piece: pieces.Piece, move_x: int, move_y: int, next_rotation: int) -> bool:
        let cells = pieces.shape_cells(piece.kind, next_rotation)

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
        let cells = pieces.shape_cells(this.active.kind, this.active.rotation)

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
            this.score += scoring.clear_score(cleared, this.level)
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
        let frame_time = rl.get_frame_time()
        this.pause_requested = false
        this.exit_requested = false

        if this.cleared_flash > 0.0:
            this.cleared_flash -= frame_time
            if this.cleared_flash < 0.0:
                this.cleared_flash = 0.0

        if this.game_over:
            if rl.is_key_pressed(rl.KeyboardKey.KEY_ENTER) or rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
                this.reset()
            return

        if rl.is_key_pressed(rl.KeyboardKey.KEY_P):
            this.pause_requested = true
            return

        if rl.is_key_pressed(rl.KeyboardKey.KEY_ESCAPE):
            this.exit_requested = true
            return

        var horizontal_direction = 0
        if rl.is_key_down(rl.KeyboardKey.KEY_LEFT) and not rl.is_key_down(rl.KeyboardKey.KEY_RIGHT):
            horizontal_direction = -1
        else if rl.is_key_down(rl.KeyboardKey.KEY_RIGHT) and not rl.is_key_down(rl.KeyboardKey.KEY_LEFT):
            horizontal_direction = 1

        if horizontal_direction == 0:
            this.horizontal_move_direction = 0
            this.horizontal_move_repeat_timer = 0.0
        else if horizontal_direction != this.horizontal_move_direction:
            this.horizontal_move_direction = horizontal_direction
            this.horizontal_move_repeat_timer = horizontal_repeat_delay
            this.try_move(horizontal_direction, 0)
        else:
            this.horizontal_move_repeat_timer -= frame_time
            while this.horizontal_move_repeat_timer <= 0.0:
                this.try_move(horizontal_direction, 0)
                this.horizontal_move_repeat_timer += horizontal_repeat_interval

        if rl.is_key_pressed(rl.KeyboardKey.KEY_UP) or rl.is_key_pressed(rl.KeyboardKey.KEY_X):
            this.try_rotate(1)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_Z):
            this.try_rotate(-1)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            this.hard_drop(effect)
            return

        let drop_scale = if rl.is_key_down(rl.KeyboardKey.KEY_DOWN): 0.12 else: 1.0
        this.drop_timer += frame_time

        if this.drop_timer < scoring.gravity_seconds(this.level) * drop_scale:
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
            rl.Rectangle(
                x = float<-(board_left - 12),
                y = float<-(board_top - 12),
                width = float<-(board_width * cell_size + 24),
                height = float<-(board_height * cell_size + 24)
            ),
            0.08,
            8,
            rl.Color(r = 20, g = 27, b = 43, a = 255),
        )
        rl.draw_rectangle_lines_ex(
            rl.Rectangle(
                x = float<-(board_left - 12),
                y = float<-(board_top - 12),
                width = float<-(board_width * cell_size + 24),
                height = float<-(board_height * cell_size + 24)
            ),
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

        let cells = pieces.shape_cells(this.active.kind, this.active.rotation)
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

        let cells = pieces.shape_cells(this.next_kind, 0)
        for i in 0..4:
            let cell = cells[i]
            let px = preview_left + 28 + cell.x * (cell_size - 4)
            let py = preview_top + 28 + cell.y * (cell_size - 4)
            this.draw_block(texture, this.next_kind, px, py, 0.86)


    function draw_sidebar() -> void:
        rl.draw_text("MILK TEA", preview_left, 320, 34, rl.RAYWHITE)
        rl.draw_text("TETRIS", preview_left, 356, 34, rl.GOLD)
        rl.draw_text(platform_info.label(), preview_left, 392, 18, rl.GRAY)
        rl.draw_text(f"Score  #{this.score}", preview_left, 420, 24, rl.SKYBLUE)
        rl.draw_text(f"Lines  #{this.lines}", preview_left, 452, 24, rl.LIME)
        rl.draw_text(f"Level  #{this.level}", preview_left, 484, 24, rl.ORANGE)

        rl.draw_text("Move   Left / Right", preview_left, 560, 18, rl.LIGHTGRAY)
        rl.draw_text("Rotate Up / Z / X", preview_left, 584, 18, rl.LIGHTGRAY)
        rl.draw_text("Soft   Hold Down", preview_left, 608, 18, rl.LIGHTGRAY)
        rl.draw_text("Drop   Space", preview_left, 632, 18, rl.LIGHTGRAY)
        rl.draw_text("Pause  P", preview_left, 656, 18, rl.LIGHTGRAY)

        if this.cleared_flash > 0.0:
            rl.draw_text("LINE CLEAR!", preview_left, 250, 24, rl.YELLOW)

        if this.game_over:
            rl.draw_rectangle(70, 268, 500, 116, rl.Color(r = 6, g = 10, b = 18, a = 214))
            rl.draw_rectangle_lines_ex(rl.Rectangle(x = 70.0, y = 268.0, width = 500.0, height = 116.0), 3.0, rl.MAROON)
            rl.draw_text("STACK OVER", 208, 292, 36, rl.RED)
            rl.draw_text("Press Enter or Space to restart", 138, 338, 22, rl.RAYWHITE)


    function draw(texture: rl.Texture2D) -> void:
        rl.clear_background(rl.Color(r = 7, g = 10, b = 18, a = 255))
        rl.draw_rectangle_gradient_v(
            0,
            0,
            window_width,
            window_height,
            rl.Color(r = 17, g = 28, b = 52, a = 255),
            rl.Color(r = 6, g = 10, b = 18, a = 255)
        )
        this.draw_board(texture)
        this.draw_preview(texture)
        this.draw_sidebar()
        rl.draw_fps(window_width - 92, 10)


function main() -> int:
    rl.init_window(window_width, window_height, "Milk Tea Tetris")
    defer rl.close_window()
    rl.set_exit_key(rl.KeyboardKey.KEY_NULL)
    rl.set_target_fps(60)

    rl.init_audio_device()
    defer rl.close_audio_device()

    var assets = load_runtime_assets() else as error:
        return runtime_assets_exit_code(error)
    defer assets.release()

    var title = default[TitleScreen]
    var paused: PausedScreen
    var game: Game
    var showing_title = true
    var showing_pause = false

    while not rl.window_should_close():
        if showing_title:
            run_screen_frame(title, assets.tiles, assets.clear_sound)
            if title.start_requested:
                game = default[Game]
                showing_title = false
                showing_pause = false
        else if showing_pause:
            run_screen_frame(paused, assets.tiles, assets.clear_sound)
            if paused.resume_requested:
                showing_pause = false
            else if paused.exit_requested:
                title = default[TitleScreen]
                showing_pause = false
                showing_title = true
        else:
            run_screen_frame(game, assets.tiles, assets.clear_sound)
            if game.pause_requested:
                paused = make_paused_screen(game)
                showing_pause = true
            else if game.exit_requested:
                title = default[TitleScreen]
                showing_title = true

    return 0

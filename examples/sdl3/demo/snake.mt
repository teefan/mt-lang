module examples.sdl3.demo.snake

import std.c.sdl3 as c

const step_rate_in_milliseconds: c.Uint64 = 125
const snake_block_size_in_pixels: i32 = 24
const snake_block_size_in_pixels_f: f32 = 24.0
const snake_game_width: i32 = 24
const snake_game_height: i32 = 18
const snake_matrix_size: i32 = snake_game_width * snake_game_height
const window_width: i32 = snake_block_size_in_pixels * snake_game_width
const window_height: i32 = snake_block_size_in_pixels * snake_game_height
const window_flags: u64 = cast[u64](c.SDL_WINDOW_RESIZABLE)
const presentation_mode: c.SDL_RendererLogicalPresentation = c.SDL_RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX

enum SnakeCell: i32
    SNAKE_CELL_NOTHING = 0
    SNAKE_CELL_SRIGHT = 1
    SNAKE_CELL_SUP = 2
    SNAKE_CELL_SLEFT = 3
    SNAKE_CELL_SDOWN = 4
    SNAKE_CELL_FOOD = 5

enum SnakeDirection: i32
    SNAKE_DIR_RIGHT = 0
    SNAKE_DIR_UP = 1
    SNAKE_DIR_LEFT = 2
    SNAKE_DIR_DOWN = 3

struct SnakeContext:
    cells: array[SnakeCell, 432]
    head_xpos: i32
    head_ypos: i32
    tail_xpos: i32
    tail_ypos: i32
    next_dir: SnakeDirection
    inhibit_tail_step: i32

var window: ptr[c.SDL_Window]
var renderer: ptr[c.SDL_Renderer]
var joystick: ptr[c.SDL_Joystick]? = null
var snake_ctx: SnakeContext = zero[SnakeContext]()
var last_step: c.Uint64 = 0

def cell_index(x: i32, y: i32) -> i32:
    return x + (y * snake_game_width)

def snake_cell_at(x: i32, y: i32) -> SnakeCell:
    return snake_ctx.cells[cell_index(x, y)]

def put_cell_at(x: i32, y: i32, cell_type: SnakeCell) -> void:
    snake_ctx.cells[cell_index(x, y)] = cell_type

def direction_cell(direction: SnakeDirection) -> SnakeCell:
    if direction == SnakeDirection.SNAKE_DIR_RIGHT:
        return SnakeCell.SNAKE_CELL_SRIGHT
    if direction == SnakeDirection.SNAKE_DIR_UP:
        return SnakeCell.SNAKE_CELL_SUP
    if direction == SnakeDirection.SNAKE_DIR_LEFT:
        return SnakeCell.SNAKE_CELL_SLEFT
    return SnakeCell.SNAKE_CELL_SDOWN

def wrap_coordinate(value: i32, max_value: i32) -> i32:
    if value < 0:
        return max_value - 1
    if value >= max_value:
        return 0
    return value

def set_rect_xy(rect: ptr[c.SDL_FRect], x: i32, y: i32) -> void:
    unsafe:
        deref(rect).x = cast[f32](x * snake_block_size_in_pixels)
        deref(rect).y = cast[f32](y * snake_block_size_in_pixels)

def are_cells_full() -> bool:
    for index in range(0, snake_matrix_size):
        if snake_ctx.cells[index] == SnakeCell.SNAKE_CELL_NOTHING:
            return false

    return true

def new_food_pos() -> void:
    while true:
        let x = c.SDL_rand(snake_game_width)
        let y = c.SDL_rand(snake_game_height)

        if snake_cell_at(x, y) == SnakeCell.SNAKE_CELL_NOTHING:
            put_cell_at(x, y, SnakeCell.SNAKE_CELL_FOOD)
            return

def snake_initialize() -> void:
    snake_ctx = zero[SnakeContext]()
    snake_ctx.head_xpos = snake_game_width / 2
    snake_ctx.head_ypos = snake_game_height / 2
    snake_ctx.tail_xpos = snake_ctx.head_xpos
    snake_ctx.tail_ypos = snake_ctx.head_ypos
    snake_ctx.next_dir = SnakeDirection.SNAKE_DIR_RIGHT
    snake_ctx.inhibit_tail_step = 4

    put_cell_at(snake_ctx.tail_xpos, snake_ctx.tail_ypos, SnakeCell.SNAKE_CELL_SRIGHT)

    for _index in range(0, 4):
        new_food_pos()

def snake_redir(direction: SnakeDirection) -> void:
    let cell_type = snake_cell_at(snake_ctx.head_xpos, snake_ctx.head_ypos)

    if direction == SnakeDirection.SNAKE_DIR_RIGHT:
        if cell_type != SnakeCell.SNAKE_CELL_SLEFT:
            snake_ctx.next_dir = direction
        return

    if direction == SnakeDirection.SNAKE_DIR_UP:
        if cell_type != SnakeCell.SNAKE_CELL_SDOWN:
            snake_ctx.next_dir = direction
        return

    if direction == SnakeDirection.SNAKE_DIR_LEFT:
        if cell_type != SnakeCell.SNAKE_CELL_SRIGHT:
            snake_ctx.next_dir = direction
        return

    if cell_type != SnakeCell.SNAKE_CELL_SUP:
        snake_ctx.next_dir = direction

def move_tail() -> void:
    let tail_cell = snake_cell_at(snake_ctx.tail_xpos, snake_ctx.tail_ypos)
    put_cell_at(snake_ctx.tail_xpos, snake_ctx.tail_ypos, SnakeCell.SNAKE_CELL_NOTHING)

    if tail_cell == SnakeCell.SNAKE_CELL_SRIGHT:
        snake_ctx.tail_xpos += 1
    else:
        if tail_cell == SnakeCell.SNAKE_CELL_SUP:
            snake_ctx.tail_ypos -= 1
        else:
            if tail_cell == SnakeCell.SNAKE_CELL_SLEFT:
                snake_ctx.tail_xpos -= 1
            else:
                if tail_cell == SnakeCell.SNAKE_CELL_SDOWN:
                    snake_ctx.tail_ypos += 1

    snake_ctx.tail_xpos = wrap_coordinate(snake_ctx.tail_xpos, snake_game_width)
    snake_ctx.tail_ypos = wrap_coordinate(snake_ctx.tail_ypos, snake_game_height)

def snake_step() -> void:
    if snake_ctx.inhibit_tail_step > 1:
        snake_ctx.inhibit_tail_step -= 1
    else:
        move_tail()

    let previous_head_xpos = snake_ctx.head_xpos
    let previous_head_ypos = snake_ctx.head_ypos

    if snake_ctx.next_dir == SnakeDirection.SNAKE_DIR_RIGHT:
        snake_ctx.head_xpos += 1
    else:
        if snake_ctx.next_dir == SnakeDirection.SNAKE_DIR_UP:
            snake_ctx.head_ypos -= 1
        else:
            if snake_ctx.next_dir == SnakeDirection.SNAKE_DIR_LEFT:
                snake_ctx.head_xpos -= 1
            else:
                snake_ctx.head_ypos += 1

    snake_ctx.head_xpos = wrap_coordinate(snake_ctx.head_xpos, snake_game_width)
    snake_ctx.head_ypos = wrap_coordinate(snake_ctx.head_ypos, snake_game_height)

    let destination_cell = snake_cell_at(snake_ctx.head_xpos, snake_ctx.head_ypos)
    if destination_cell != SnakeCell.SNAKE_CELL_NOTHING and destination_cell != SnakeCell.SNAKE_CELL_FOOD:
        snake_initialize()
        return

    let dir_as_cell = direction_cell(snake_ctx.next_dir)
    put_cell_at(previous_head_xpos, previous_head_ypos, dir_as_cell)
    put_cell_at(snake_ctx.head_xpos, snake_ctx.head_ypos, dir_as_cell)

    if destination_cell == SnakeCell.SNAKE_CELL_FOOD:
        if are_cells_full():
            snake_initialize()
            return

        new_food_pos()
        snake_ctx.inhibit_tail_step += 1

def handle_key_event(key_code: c.SDL_Scancode) -> bool:
    if key_code == c.SDL_Scancode.SDL_SCANCODE_ESCAPE or key_code == c.SDL_Scancode.SDL_SCANCODE_Q:
        return false

    if key_code == c.SDL_Scancode.SDL_SCANCODE_R:
        snake_initialize()
        return true

    if key_code == c.SDL_Scancode.SDL_SCANCODE_RIGHT:
        snake_redir(SnakeDirection.SNAKE_DIR_RIGHT)
        return true

    if key_code == c.SDL_Scancode.SDL_SCANCODE_UP:
        snake_redir(SnakeDirection.SNAKE_DIR_UP)
        return true

    if key_code == c.SDL_Scancode.SDL_SCANCODE_LEFT:
        snake_redir(SnakeDirection.SNAKE_DIR_LEFT)
        return true

    if key_code == c.SDL_Scancode.SDL_SCANCODE_DOWN:
        snake_redir(SnakeDirection.SNAKE_DIR_DOWN)

    return true

def handle_hat_event(hat: u8) -> void:
    if hat == c.SDL_HAT_RIGHT:
        snake_redir(SnakeDirection.SNAKE_DIR_RIGHT)
    else:
        if hat == c.SDL_HAT_UP:
            snake_redir(SnakeDirection.SNAKE_DIR_UP)
        else:
            if hat == c.SDL_HAT_LEFT:
                snake_redir(SnakeDirection.SNAKE_DIR_LEFT)
            else:
                if hat == c.SDL_HAT_DOWN:
                    snake_redir(SnakeDirection.SNAKE_DIR_DOWN)

def pump_events() -> bool:
    var event = c.SDL_Event(type = 0)

    while c.SDL_PollEvent(raw(addr(event))):
        if event.quit.type == c.SDL_EventType.SDL_EVENT_QUIT:
            return false
        else:
            if event.jdevice.type == c.SDL_EventType.SDL_EVENT_JOYSTICK_ADDED:
                if joystick == null:
                    joystick = c.SDL_OpenJoystick(event.jdevice.which)
            else:
                if event.jdevice.type == c.SDL_EventType.SDL_EVENT_JOYSTICK_REMOVED:
                    if joystick != null:
                        if c.SDL_GetJoystickID(joystick) == event.jdevice.which:
                            c.SDL_CloseJoystick(joystick)
                            joystick = null
                else:
                    if event.jhat.type == c.SDL_EventType.SDL_EVENT_JOYSTICK_HAT_MOTION:
                        handle_hat_event(event.jhat.value)
                    else:
                        if event.key.type == c.SDL_EventType.SDL_EVENT_KEY_DOWN:
                            if not handle_key_event(event.key.scancode):
                                return false

    return true

def render_frame() -> void:
    let now = c.SDL_GetTicks()
    var rect = c.SDL_FRect(x = 0.0, y = 0.0, w = snake_block_size_in_pixels_f, h = snake_block_size_in_pixels_f)

    while (now - last_step) >= step_rate_in_milliseconds:
        snake_step()
        last_step += step_rate_in_milliseconds

    c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderClear(renderer)

    for x in range(0, snake_game_width):
        for y in range(0, snake_game_height):
            let cell_type = snake_cell_at(x, y)

            if cell_type == SnakeCell.SNAKE_CELL_NOTHING:
                continue

            set_rect_xy(raw(addr(rect)), x, y)

            if cell_type == SnakeCell.SNAKE_CELL_FOOD:
                c.SDL_SetRenderDrawColor(renderer, 80, 80, 255, c.SDL_ALPHA_OPAQUE)
            else:
                c.SDL_SetRenderDrawColor(renderer, 0, 128, 0, c.SDL_ALPHA_OPAQUE)

            c.SDL_RenderFillRect(renderer, raw(addr(rect)))

    c.SDL_SetRenderDrawColor(renderer, 255, 255, 0, c.SDL_ALPHA_OPAQUE)
    set_rect_xy(raw(addr(rect)), snake_ctx.head_xpos, snake_ctx.head_ypos)
    c.SDL_RenderFillRect(renderer, raw(addr(rect)))
    c.SDL_RenderPresent(renderer)

def app_main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    if not c.SDL_SetAppMetadata(c"Example Snake game", c"1.0", c"com.example.Snake"):
        return 1

    if not c.SDL_SetAppMetadataProperty(c"SDL.app.metadata.url", c"https://examples.libsdl.org/SDL3/demo/01-snake/"):
        return 1
    if not c.SDL_SetAppMetadataProperty(c"SDL.app.metadata.creator", c"SDL team"):
        return 1
    if not c.SDL_SetAppMetadataProperty(c"SDL.app.metadata.copyright", c"Placed in the public domain"):
        return 1
    if not c.SDL_SetAppMetadataProperty(c"SDL.app.metadata.type", c"game"):
        return 1

    if not c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_JOYSTICK):
        return 1
    defer c.SDL_Quit()
    defer:
        if joystick != null:
            c.SDL_CloseJoystick(joystick)

    if not c.SDL_CreateWindowAndRenderer(c"examples/demo/snake", window_width, window_height, window_flags, raw(addr(window)), raw(addr(renderer))):
        return 1
    defer c.SDL_DestroyRenderer(renderer)
    defer c.SDL_DestroyWindow(window)

    c.SDL_SetRenderLogicalPresentation(renderer, window_width, window_height, presentation_mode)

    snake_initialize()
    last_step = c.SDL_GetTicks()

    while pump_events():
        render_frame()

    return 0

def main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    return c.SDL_RunApp(argc, argv, app_main, null)

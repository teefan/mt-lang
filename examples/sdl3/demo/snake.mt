import std.sdl3 as sdl

const STEP_RATE_IN_MILLISECONDS: ptr_uint = 125
const SNAKE_BLOCK_SIZE_IN_PIXELS: int = 24
const SNAKE_GAME_WIDTH: int = 24
const SNAKE_GAME_HEIGHT: int = 18
const SNAKE_MATRIX_SIZE: int = SNAKE_GAME_WIDTH * SNAKE_GAME_HEIGHT
const SNAKE_CELL_MAX_BITS: int = 3
const SNAKE_CELL_SET_BITS: int = 7
const SNAKE_CELLS_BYTES: int = (SNAKE_GAME_WIDTH * SNAKE_GAME_HEIGHT * 3) / 8
const WINDOW_WIDTH: int = SNAKE_BLOCK_SIZE_IN_PIXELS * SNAKE_GAME_WIDTH
const WINDOW_HEIGHT: int = SNAKE_BLOCK_SIZE_IN_PIXELS * SNAKE_GAME_HEIGHT


enum SnakeCell: ubyte
    nothing = 0
    sright = 1
    sup = 2
    sleft = 3
    sdown = 4
    food = 5


enum SnakeDirection: int
    right
    up
    left
    down


struct SnakeContext:
    cells: array[ubyte, SNAKE_CELLS_BYTES]
    head_xpos: byte
    head_ypos: byte
    tail_xpos: byte
    tail_ypos: byte
    next_dir: SnakeDirection
    inhibit_tail_step: byte
    occupied_cells: uint


function snake_cell_at(ctx: ref[SnakeContext], x: byte, y: byte) -> SnakeCell:
    let shift = (int<-x + int<-y * SNAKE_GAME_WIDTH) * SNAKE_CELL_MAX_BITS
    let byte_index = shift / 8
    let bit_offset = shift % 8
    let lo = ctx.cells[byte_index]
    let hi = if byte_index + 1 < SNAKE_CELLS_BYTES: ctx.cells[byte_index + 1] else: 0
    let range = int<-lo | (hi << 8)
    return SnakeCell<-(range >> bit_offset & SNAKE_CELL_SET_BITS)


function put_cell_at(ctx: ref[SnakeContext], x: byte, y: byte, cell: SnakeCell) -> void:
    let shift = (int<-x + int<-y * SNAKE_GAME_WIDTH) * SNAKE_CELL_MAX_BITS
    let byte_index = shift / 8
    let bit_offset = shift % 8
    let lo = ctx.cells[byte_index]
    let hi = if byte_index + 1 < SNAKE_CELLS_BYTES: ctx.cells[byte_index + 1] else: 0
    let range = int<-lo | (hi << 8)
    let clear = SNAKE_CELL_SET_BITS << bit_offset
    let value = (range & ~clear) | ((int<-cell & SNAKE_CELL_SET_BITS) << bit_offset)
    ctx.cells[byte_index] = ubyte<-value
    if byte_index + 1 < SNAKE_CELLS_BYTES:
        ctx.cells[byte_index + 1] = ubyte<-(value >> 8)


function are_cells_full(ctx: ref[SnakeContext]) -> bool:
    return ctx.occupied_cells == SNAKE_GAME_WIDTH * SNAKE_GAME_HEIGHT


function new_food_pos(ctx: ref[SnakeContext]) -> void:
    var done = false
    while not done:
        let x = byte<-sdl.rand(SNAKE_GAME_WIDTH)
        let y = byte<-sdl.rand(SNAKE_GAME_HEIGHT)
        if snake_cell_at(ctx, x, y) == SnakeCell.nothing:
            put_cell_at(ctx, x, y, SnakeCell.food)
            done = true


function snake_initialize(ctx: ref[SnakeContext]) -> void:
    for i in 0..SNAKE_CELLS_BYTES:
        ctx.cells[i] = 0
    ctx.head_xpos = byte<-SNAKE_GAME_WIDTH / 2
    ctx.tail_xpos = ctx.head_xpos
    ctx.head_ypos = byte<-SNAKE_GAME_HEIGHT / 2
    ctx.tail_ypos = ctx.head_ypos
    ctx.next_dir = SnakeDirection.right
    ctx.inhibit_tail_step = 4
    ctx.occupied_cells = 3
    put_cell_at(ctx, ctx.tail_xpos, ctx.tail_ypos, SnakeCell.sright)
    for _ in 0..4:
        new_food_pos(ctx)
        ctx.occupied_cells += 1


function snake_redir(ctx: ref[SnakeContext], dir: SnakeDirection) -> void:
    let cell = snake_cell_at(ctx, ctx.head_xpos, ctx.head_ypos)
    if (
        (dir == SnakeDirection.right and cell != SnakeCell.sleft)
        or (dir == SnakeDirection.up and cell != SnakeCell.sdown)
        or (dir == SnakeDirection.left and cell != SnakeCell.sright)
        or (dir == SnakeDirection.down and cell != SnakeCell.sup)
    ):
        ctx.next_dir = dir


function wrap_around(val: ref[byte], max: byte) -> void:
    if read(val) < 0:
        read(val) = max - 1
    else if read(val) > max - 1:
        read(val) = 0


function snake_step(ctx: ref[SnakeContext]) -> void:
    let dir_as_cell = SnakeCell<-(int<-ctx.next_dir + 1)
    if ctx.inhibit_tail_step == 1:
        let tail_cell = snake_cell_at(ctx, ctx.tail_xpos, ctx.tail_ypos)
        put_cell_at(ctx, ctx.tail_xpos, ctx.tail_ypos, SnakeCell.nothing)
        match tail_cell:
            SnakeCell.sright:
                ctx.tail_xpos += 1
            SnakeCell.sup:
                ctx.tail_ypos -= 1
            SnakeCell.sleft:
                ctx.tail_xpos -= 1
            SnakeCell.sdown:
                ctx.tail_ypos += 1
            _:
                pass
        wrap_around(ctx.tail_xpos, byte<-SNAKE_GAME_WIDTH)
        wrap_around(ctx.tail_ypos, byte<-SNAKE_GAME_HEIGHT)

    let prev_xpos = ctx.head_xpos
    let prev_ypos = ctx.head_ypos
    match ctx.next_dir:
        SnakeDirection.right:
            ctx.head_xpos += 1
        SnakeDirection.up:
            ctx.head_ypos -= 1
        SnakeDirection.left:
            ctx.head_xpos -= 1
        SnakeDirection.down:
            ctx.head_ypos += 1
    wrap_around(ctx.head_xpos, byte<-SNAKE_GAME_WIDTH)
    wrap_around(ctx.head_ypos, byte<-SNAKE_GAME_HEIGHT)

    let head_cell = snake_cell_at(ctx, ctx.head_xpos, ctx.head_ypos)
    if head_cell != SnakeCell.nothing and head_cell != SnakeCell.food:
        snake_initialize(ctx)
        return

    put_cell_at(ctx, prev_xpos, prev_ypos, dir_as_cell)
    put_cell_at(ctx, ctx.head_xpos, ctx.head_ypos, dir_as_cell)
    if head_cell == SnakeCell.food:
        if are_cells_full(ctx):
            snake_initialize(ctx)
            return
        new_food_pos(ctx)
        ctx.inhibit_tail_step += 1
        ctx.occupied_cells += 1


function handle_key_event(ctx: ref[SnakeContext], key_code: sdl.Scancode) -> bool:
    if key_code == sdl.Scancode.SDL_SCANCODE_ESCAPE or key_code == sdl.Scancode.SDL_SCANCODE_Q:
        return false
    else if key_code == sdl.Scancode.SDL_SCANCODE_R:
        snake_initialize(ctx)
    else if key_code == sdl.Scancode.SDL_SCANCODE_RIGHT:
        snake_redir(ctx, SnakeDirection.right)
    else if key_code == sdl.Scancode.SDL_SCANCODE_UP:
        snake_redir(ctx, SnakeDirection.up)
    else if key_code == sdl.Scancode.SDL_SCANCODE_LEFT:
        snake_redir(ctx, SnakeDirection.left)
    else if key_code == sdl.Scancode.SDL_SCANCODE_DOWN:
        snake_redir(ctx, SnakeDirection.down)
    return true


function handle_hat_event(ctx: ref[SnakeContext], hat: ubyte) -> bool:
    if hat == sdl.HAT_RIGHT:
        snake_redir(ctx, SnakeDirection.right)
    else if hat == sdl.HAT_UP:
        snake_redir(ctx, SnakeDirection.up)
    else if hat == sdl.HAT_LEFT:
        snake_redir(ctx, SnakeDirection.left)
    else if hat == sdl.HAT_DOWN:
        snake_redir(ctx, SnakeDirection.down)
    return true


function main() -> int:
    if not sdl.init(sdl.INIT_VIDEO | sdl.INIT_JOYSTICK):
        fatal(f"could not initialize SDL: #{sdl.get_error()}")
    defer: sdl.quit()

    var window: sdl.Window = zero[sdl.Window]
    var renderer: sdl.Renderer = zero[sdl.Renderer]
    if not sdl.create_window_and_renderer(
        "examples/demo/snake",
        WINDOW_WIDTH,
        WINDOW_HEIGHT,
        sdl.WINDOW_RESIZABLE,
        window,
        renderer
    ):
        fatal(f"could not create window/renderer: #{sdl.get_error()}")
    defer: sdl.destroy_renderer(renderer)
    defer: sdl.destroy_window(window)

    if not sdl.set_render_logical_presentation(
        renderer,
        WINDOW_WIDTH,
        WINDOW_HEIGHT,
        sdl.RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX
    ):
        pass

    var joystick: ptr[sdl.Joystick]? = null
    var snake_ctx: SnakeContext
    var last_step = sdl.get_ticks()
    snake_initialize(ref_of(snake_ctx))

    var running = true
    while running:
        var ev: sdl.Event = zero[sdl.Event]
        while sdl.poll_event(ev):
            let ev_type = int<-ev.type
            if ev_type == int<-sdl.EventType.SDL_EVENT_QUIT:
                running = false
            else if ev_type == int<-sdl.EventType.SDL_EVENT_JOYSTICK_ADDED:
                if joystick == null:
                    joystick = sdl.open_joystick(ev.jdevice.which)
            else if ev_type == int<-sdl.EventType.SDL_EVENT_JOYSTICK_REMOVED:
                if joystick != null and sdl.get_joystick_id(joystick) == ev.jdevice.which:
                    sdl.close_joystick(joystick)
                    joystick = null
            else if ev_type == int<-sdl.EventType.SDL_EVENT_JOYSTICK_HAT_MOTION:
                if not handle_hat_event(ref_of(snake_ctx), ev.jhat.value):
                    running = false
            else if ev_type == int<-sdl.EventType.SDL_EVENT_KEY_DOWN:
                if not handle_key_event(ref_of(snake_ctx), ev.key.scancode):
                    running = false

        let now = sdl.get_ticks()
        while now - last_step >= STEP_RATE_IN_MILLISECONDS:
            snake_step(ref_of(snake_ctx))
            last_step += STEP_RATE_IN_MILLISECONDS

        var r: sdl.FRect
        r.w = SNAKE_BLOCK_SIZE_IN_PIXELS
        r.h = SNAKE_BLOCK_SIZE_IN_PIXELS
        sdl.set_render_draw_color(renderer, 0, 0, 0, sdl.ALPHA_OPAQUE)
        sdl.render_clear(renderer)

        var x: int = 0
        var y: int = 0
        while x < SNAKE_GAME_WIDTH:
            y = 0
            while y < SNAKE_GAME_HEIGHT:
                let cell = snake_cell_at(ref_of(snake_ctx), byte<-x, byte<-y)
                if cell != SnakeCell.nothing:
                    r.x = x * SNAKE_BLOCK_SIZE_IN_PIXELS
                    r.y = y * SNAKE_BLOCK_SIZE_IN_PIXELS
                    if cell == SnakeCell.food:
                        sdl.set_render_draw_color(renderer, 80, 80, 255, sdl.ALPHA_OPAQUE)
                    else:
                        sdl.set_render_draw_color(renderer, 0, 128, 0, sdl.ALPHA_OPAQUE)
                    sdl.render_fill_rect(renderer, r)
                y += 1
            x += 1

        sdl.set_render_draw_color(renderer, 255, 255, 0, sdl.ALPHA_OPAQUE)
        r.x = int<-snake_ctx.head_xpos * SNAKE_BLOCK_SIZE_IN_PIXELS
        r.y = int<-snake_ctx.head_ypos * SNAKE_BLOCK_SIZE_IN_PIXELS
        sdl.render_fill_rect(renderer, r)
        sdl.render_present(renderer)

    if joystick != null:
        sdl.close_joystick(joystick)

    return 0

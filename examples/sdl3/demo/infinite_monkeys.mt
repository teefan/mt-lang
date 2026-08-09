import std.sdl3 as sdl
import std.str as text_ops

const MAX_ROWS: int = 64
const MAX_COLS: int = 256
const LINE_BYTES: int = MAX_COLS * 4 + 1
const MONKEYS: int = 100
const KMOD_SHIFT: uint = sdl.KMOD_LSHIFT | sdl.KMOD_RSHIFT
const DEFAULT_TEXT: cstr = c<<-TEXT
Jabberwocky, by Lewis Carroll

'Twas brillig, and the slithy toves
      Did gyre and gimble in the wabe:
All mimsy were the borogoves,
      And the mome raths outgrabe.

"Beware the Jabberwock, my son!
      The jaws that bite, the claws that catch!
Beware the Jubjub bird, and shun
      The frumious Bandersnatch!"

He took his vorpal sword in hand;
      Long time the manxome foe he sought-
So rested he by the Tumtum tree
      And stood awhile in thought.

And, as in uffish thought he stood,
      The Jabberwock, with eyes of flame,
Came whiffling through the tulgey wood,
      And burbled as it came!

One, two! One, two! And through and through
      The vorpal blade went snicker-snack!
He left it dead, and with its head
      He went galumphing back.

"And hast thou slain the Jabberwock?
      Come to my arms, my beamish boy!
O frabjous day! Callooh! Callay!"
      He chortled in his joy.

'Twas brillig, and the slithy toves
      Did gyre and gimble in the wabe:
All mimsy were the borogoves,
      And the mome raths outgrabe.
TEXT


struct Line:
    text: array[uint, MAX_COLS]
    length: int


struct MonkeyState:
    progress: cstr
    remaining: ptr_uint
    total: ptr_uint
    row: int
    rows: int
    cols: int
    lines: array[Line, MAX_ROWS]
    monkey_chars: Line


function imin(a: int, b: int) -> int:
    return if a < b: a else: b


function on_window_size_changed(state: ref[MonkeyState], renderer: sdl.Renderer) -> void:
    var w = 0
    var h = 0
    if not sdl.get_current_render_output_size(renderer, ptr_of(w), ptr_of(h)):
        return

    state.row = 0
    state.rows = imin((h / sdl.DEBUG_TEXT_FONT_CHARACTER_SIZE) - 4, MAX_ROWS)
    state.cols = imin(w / sdl.DEBUG_TEXT_FONT_CHARACTER_SIZE, MAX_COLS)
    if state.rows < 0:
        state.rows = 0
    if state.cols < 0:
        state.cols = 0
    for i in 0..MAX_ROWS:
        state.lines[i].length = 0
    for i in 0..state.cols:
        state.monkey_chars.text[i] = ' '
    state.monkey_chars.length = state.cols


function display_line(renderer: sdl.Renderer, x: float, y: float, line: ref[Line]) -> void:
    if line.length == 0:
        return

    var utf8: array[char, LINE_BYTES]
    var spot: ptr[char] = ptr_of(utf8[0])
    for i in 0..line.length:
        spot = sdl.ucs4_to_utf8(line.text[i], spot)
    unsafe:
        spot[0] = zero[char]
    let line_text = unsafe: text_ops.cstr_as_str(cstr<-ptr_of(utf8[0]))
    sdl.render_debug_text(renderer, x, y, line_text)


function can_monkey_type(ch: uint) -> bool:
    var modstate: sdl.Keymod = sdl.Keymod<-0
    let scancode = sdl.get_scancode_from_key(ch, ptr_of(modstate))
    if scancode < sdl.Scancode.SDL_SCANCODE_A or scancode > sdl.Scancode.SDL_SCANCODE_SLASH:
        return false
    if (int<-modstate & ~int<-KMOD_SHIFT) != 0:
        return false
    return true


function monkey_play() -> uint:
    let count = int<-sdl.Scancode.SDL_SCANCODE_SLASH - int<-sdl.Scancode.SDL_SCANCODE_A + 1
    let scancode = sdl.Scancode<-(int<-sdl.Scancode.SDL_SCANCODE_A + sdl.rand(count))
    let modstate = if sdl.rand(2) != 0: ushort<-KMOD_SHIFT else: ushort<-0
    return sdl.get_key_from_scancode(scancode, modstate, false)


function advance_row(state: ref[MonkeyState]) -> void:
    state.row += 1
    state.lines[state.row % state.rows].length = 0


function add_monkey_char(state: ref[MonkeyState], monkey: int, ch: uint) -> void:
    if monkey >= 0 and state.cols > 0:
        state.monkey_chars.text[monkey % state.cols] = ch

    if state.rows > 0:
        if ch == uint<-'\n':
            advance_row(state)
        else:
            let line_index = state.row % state.rows
            let current = state.lines[line_index].length
            state.lines[line_index].text[current] = ch
            state.lines[line_index].length = current + 1
            if current + 1 == state.cols:
                advance_row(state)

    unsafe:
        let _ = sdl.step_utf8(ptr_of(state.progress), ptr_of(state.remaining))


function get_next_char(state: ref[MonkeyState]) -> uint:
    var ch: uint = 0
    while state.remaining > 0:
        var spot = state.progress
        ch = sdl.step_utf8(ptr_of(spot), null)
        if not can_monkey_type(ch):
            add_monkey_char(state, -1, ch)
            continue
        break
    return ch


function main() -> int:
    if not sdl.set_app_metadata("Infinite Monkeys", "1.0", "com.example.infinite-monkeys"):
        pass

    if not sdl.init(sdl.INIT_VIDEO):
        fatal(f"could not initialize SDL: #{sdl.get_error()}")
    defer: sdl.quit()

    var window: sdl.Window = zero[sdl.Window]
    var renderer: sdl.Renderer = zero[sdl.Renderer]
    if not sdl.create_window_and_renderer(
        "examples/demo/infinite-monkeys",
        640,
        480,
        sdl.WINDOW_RESIZABLE,
        window,
        renderer
    ):
        fatal(f"could not create window/renderer: #{sdl.get_error()}")
    defer: sdl.destroy_renderer(renderer)
    defer: sdl.destroy_window(window)

    var state: MonkeyState
    state.progress = DEFAULT_TEXT
    state.total = sdl.strlen(DEFAULT_TEXT)
    state.remaining = state.total
    on_window_size_changed(ref_of(state), renderer)

    var start_time: sdl.Time = 0
    sdl.get_current_time(start_time)
    var end_time: sdl.Time = 0

    var running = true
    while running:
        var ev: sdl.Event = zero[sdl.Event]
        while sdl.poll_event(ev):
            let ev_type = int<-ev.type
            if ev_type == int<-sdl.EventType.SDL_EVENT_QUIT:
                running = false
            else if ev_type == int<-sdl.EventType.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
                on_window_size_changed(ref_of(state), renderer)

        var next_char: uint = 0
        var monkey = 0
        while monkey < MONKEYS:
            if next_char == 0:
                next_char = get_next_char(ref_of(state))
                if next_char == 0:
                    break
            let ch = monkey_play()
            if ch == next_char:
                add_monkey_char(ref_of(state), monkey, ch)
                next_char = 0
            monkey += 1

        sdl.set_render_draw_color(renderer, 0, 0, 0, sdl.ALPHA_OPAQUE)
        sdl.render_clear(renderer)

        if state.rows > 0:
            sdl.set_render_draw_color(renderer, 255, 255, 255, sdl.ALPHA_OPAQUE)
            let x = 0.0
            var y = 0.0
            let row_offset = state.row - state.rows + 1
            let first_row = if row_offset < 0: 0 else: row_offset
            for i in 0..state.rows:
                display_line(renderer, x, y, ref_of(state.lines[(first_row + i) % state.rows]))
                y += float<-sdl.DEBUG_TEXT_FONT_CHARACTER_SIZE

            y = float<-(state.rows + 1) * float<-sdl.DEBUG_TEXT_FONT_CHARACTER_SIZE
            var now: sdl.Time = 0
            sdl.get_current_time(now)
            if state.remaining == 0 and end_time == 0:
                end_time = now
            let display_time = if state.remaining == 0: end_time else: now
            let elapsed = (long<-display_time - long<-start_time) / sdl.NS_PER_SECOND
            let seconds = int<-(elapsed % 60)
            let minutes = int<-((elapsed / 60) % 60)
            let hours = int<-((elapsed / 60) / 60)
            var caption: str_buffer[64]
            caption.assign_format(f"Monkeys: #{MONKEYS} - #{hours}H:#{minutes}M:#{seconds}S")
            sdl.render_debug_text(renderer, x, y, caption.as_str())
            y += float<-sdl.DEBUG_TEXT_FONT_CHARACTER_SIZE

            display_line(renderer, x, y, ref_of(state.monkey_chars))
            y += float<-sdl.DEBUG_TEXT_FONT_CHARACTER_SIZE

            sdl.set_render_draw_color(renderer, 0, 255, 0, sdl.ALPHA_OPAQUE)
            var rect: sdl.FRect
            rect.x = x
            rect.y = y
            let progress_fraction = float<-(state.total - state.remaining) / float<-state.total
            rect.w = progress_fraction * (state.cols * sdl.DEBUG_TEXT_FONT_CHARACTER_SIZE)
            rect.h = sdl.DEBUG_TEXT_FONT_CHARACTER_SIZE
            sdl.render_fill_rect(renderer, rect)

        sdl.render_present(renderer)

    return 0

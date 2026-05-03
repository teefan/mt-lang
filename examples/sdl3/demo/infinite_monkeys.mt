module examples.sdl3.demo.infinite_monkeys

import std.c.sdl3 as c
import std.mem.heap as heap

const window_width: i32 = 640
const window_height: i32 = 480
const window_title: cstr = c"examples/demo/infinite-monkeys"
const window_flags: u64 = u64<-0
const default_monkey_count: i32 = 100
const min_monkey_scancode: i32 = i32<-c.SDL_Scancode.SDL_SCANCODE_A
const max_monkey_scancode: i32 = i32<-c.SDL_Scancode.SDL_SCANCODE_SLASH
const shift_only_mods: c.SDL_Keymod = c.SDL_Keymod<-(c.SDL_KMOD_LSHIFT | c.SDL_KMOD_RSHIFT)
const monkey_shift_mod: u16 = u16<-c.SDL_KMOD_LSHIFT
const default_text: cstr = c"Jabberwocky, by Lewis Carroll\n\n'Twas brillig, and the slithy toves\n      Did gyre and gimble in the wabe:\nAll mimsy were the borogoves,\n      And the mome raths outgrabe.\n\n\"Beware the Jabberwock, my son!\n      The jaws that bite, the claws that catch!\nBeware the Jubjub bird, and shun\n      The frumious Bandersnatch!\"\n\nHe took his vorpal sword in hand;\n      Long time the manxome foe he sought-\nSo rested he by the Tumtum tree\n      And stood awhile in thought.\n\nAnd, as in uffish thought he stood,\n      The Jabberwock, with eyes of flame,\nCame whiffling through the tulgey wood,\n      And burbled as it came!\n\nOne, two! One, two! And through and through\n      The vorpal blade went snicker-snack!\nHe left it dead, and with its head\n      He went galumphing back.\n\n\"And hast thou slain the Jabberwock?\n      Come to my arms, my beamish boy!\nO frabjous day! Callooh! Callay!\"\n      He chortled in his joy.\n\n'Twas brillig, and the slithy toves\n      Did gyre and gimble in the wabe:\nAll mimsy were the borogoves,\n      And the mome raths outgrabe.\n"

struct Line:
    text: ptr[u32]?
    length: i32

var window: ptr[c.SDL_Window]
var renderer: ptr[c.SDL_Renderer]
var text_data: ptr[char]? = null
var text_length: usize = 0
var progress: cstr = c""
var progress_remaining: usize = 0
var start_time: c.SDL_Time = 0
var end_time: c.SDL_Time = 0
var row: i32 = 0
var rows: i32 = 0
var cols: i32 = 0
var lines: ptr[Line]? = null
var monkey_chars: Line = zero[Line]()
var monkeys: i32 = default_monkey_count

def free_lines() -> void:
    let line_storage = lines
    if line_storage != null:
        for index in range(0, rows):
            unsafe:
                let line = line_storage + usize<-index
                heap.release(line.text)
                line.text = null
                line.length = 0

        heap.release(line_storage)
        lines = null

    heap.release(monkey_chars.text)
    monkey_chars.text = null
    monkey_chars.length = 0
    row = 0
    rows = 0
    cols = 0

def on_window_size_changed() -> void:
    var w: i32 = 0
    var h: i32 = 0

    if not c.SDL_GetCurrentRenderOutputSize(renderer, ptr_of(ref_of(w)), ptr_of(ref_of(h))):
        return

    free_lines()

    rows = (h / c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE) - 4
    cols = w / c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE
    if rows <= 0 or cols <= 0:
        return

    let line_storage = heap.must_alloc_zeroed[Line](usize<-rows)
    lines = line_storage

    for index in range(0, rows):
        unsafe:
            let line = line_storage + usize<-index
            line.text = heap.must_alloc_zeroed[u32](usize<-cols)
            line.length = 0

    monkey_chars.text = heap.must_alloc_zeroed[u32](usize<-cols)
    monkey_chars.length = cols

    let monkey_text = monkey_chars.text
    if monkey_text != null:
        for index in range(0, cols):
            unsafe:
                read(monkey_text + usize<-index) = u32<-32

def step_progress() -> void:
    if progress_remaining == 0:
        return

    var next = progress
    var remaining = progress_remaining
    c.SDL_StepUTF8(ptr_of(ref_of(next)), ptr_of(ref_of(remaining)))
    progress = next
    progress_remaining = remaining

def display_line(x: f32, y: f32, line: ptr[Line]) -> void:
    var line_length: i32 = 0
    var line_text: ptr[u32]? = null

    unsafe:
        line_length = line.length
        line_text = line.text

    if line_length <= 0:
        return

    if line_text == null:
        return

    let utf8_size = (usize<-line_length * usize<-4) + usize<-1
    let utf8 = heap.must_alloc[char](utf8_size)
    defer heap.release(utf8)

    unsafe:
        var spot = utf8

        for index in range(0, line_length):
            spot = c.SDL_UCS4ToUTF8(read(line_text + usize<-index), spot)

        read(spot) = char<-0
        c.SDL_RenderDebugText(renderer, x, y, cstr<-utf8)

def can_monkey_type(ch: u32) -> bool:
    var modstate: c.SDL_Keymod = 0
    let scancode = c.SDL_GetScancodeFromKey(ch, ptr_of(ref_of(modstate)))
    let scancode_value = i32<-scancode

    if scancode_value < min_monkey_scancode or scancode_value > max_monkey_scancode:
        return false

    if (modstate & ~shift_only_mods) != 0:
        return false

    return true

def advance_row() -> void:
    if rows <= 0:
        return

    row += 1
    let line_storage = lines
    if line_storage == null:
        return

    unsafe:
        let line = line_storage + usize<-(row % rows)
        line.length = 0

def add_monkey_char(monkey: i32, ch: u32) -> void:
    let monkey_text = monkey_chars.text
    if monkey >= 0 and monkey_text != null and cols > 0:
        unsafe:
            read(monkey_text + usize<-(monkey % cols)) = ch

    let line_storage = lines
    if line_storage != null:
        if ch == u32<-10:
            advance_row()
        else:
            unsafe:
                let line = line_storage + usize<-(row % rows)
                let line_text = line.text
                let line_length = line.length

                if line_text != null and line_length < cols:
                    read(line_text + usize<-line_length) = ch
                    line.length = line_length + 1
                    if line.length == cols:
                        advance_row()

    step_progress()

def get_next_char() -> u32:
    while progress_remaining > 0:
        var spot = progress
        var remaining = progress_remaining
        let ch = c.SDL_StepUTF8(ptr_of(ref_of(spot)), ptr_of(ref_of(remaining)))

        if ch == 0:
            return 0

        if can_monkey_type(ch):
            return ch

        add_monkey_char(-1, ch)

    return 0

def monkey_play() -> u32:
    let count = max_monkey_scancode - min_monkey_scancode + 1
    let scancode = c.SDL_Scancode<-(min_monkey_scancode + c.SDL_rand(count))
    let modstate = if c.SDL_rand(2) != 0: monkey_shift_mod else: u16<-0
    return c.SDL_GetKeyFromScancode(scancode, modstate, false)

def pump_events() -> bool:
    var event = zero[c.SDL_Event]()

    while c.SDL_PollEvent(ptr_of(ref_of(event))):
        if c.SDL_EventType.SDL_EVENT_QUIT == c.SDL_EventType.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
            on_window_size_changed()
        else:
            if c.SDL_EventType.SDL_EVENT_QUIT == c.SDL_EventType.SDL_EVENT_QUIT:
                return false

    return true

def render_frame() -> void:
    var next_char: u32 = 0

    for monkey in range(0, monkeys):
        if next_char == 0:
            next_char = get_next_char()
            if next_char == 0:
                break

        let ch = monkey_play()
        if ch == next_char:
            add_monkey_char(monkey, ch)
            next_char = 0

    c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderClear(renderer)

    c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, c.SDL_ALPHA_OPAQUE)
    var x: f32 = 0.0
    var y: f32 = 0.0

    let line_storage = lines
    if line_storage != null:
        var row_offset = row - rows + 1
        if row_offset < 0:
            row_offset = 0

        for index in range(0, rows):
            unsafe:
                let line = line_storage + usize<-((row_offset + index) % rows)
                display_line(x, y, line)
            y += f32<-c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE

        y = f32<-((rows + 1) * c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE)
        var now: c.SDL_Time = 0
        if progress_remaining == 0:
            if end_time == 0:
                c.SDL_GetCurrentTime(ptr_of(ref_of(end_time)))
            now = end_time
        else:
            c.SDL_GetCurrentTime(ptr_of(ref_of(now)))

        var elapsed = (now - start_time) / c.SDL_Time<-c.SDL_NS_PER_SECOND
        let seconds = i32<-(elapsed % c.SDL_Time<-60)
        elapsed /= c.SDL_Time<-60
        let minutes = i32<-(elapsed % c.SDL_Time<-60)
        elapsed /= c.SDL_Time<-60
        let hours = i32<-elapsed
        var caption: ptr[char]? = null

        unsafe:
            c.SDL_asprintf(ptr[ptr[char]]<-ptr_of(ref_of(caption)), c"Monkeys: %d - %dH:%dM:%dS", monkeys, hours, minutes, seconds)

        if caption != null:
            unsafe:
                c.SDL_RenderDebugText(renderer, x, y, cstr<-caption)
            c.SDL_free(caption)

        y += f32<-c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE

        let monkey_text = monkey_chars.text
        if monkey_text != null:
            display_line(x, y, ptr_of(ref_of(monkey_chars)))
            y += f32<-c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE

    c.SDL_SetRenderDrawColor(renderer, 0, 255, 0, c.SDL_ALPHA_OPAQUE)
    var rect = c.SDL_FRect(x = x, y = y, w = 0.0, h = f32<-c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE)
    if text_length > 0 and cols > 0:
        let completed = text_length - progress_remaining
        rect.w = (f32<-completed / f32<-text_length) * f32<-(cols * c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE)

    c.SDL_RenderFillRect(renderer, ptr_of(ref_of(rect)))
    c.SDL_RenderPresent(renderer)

def app_main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    monkeys = default_monkey_count
    progress = c""
    progress_remaining = 0
    text_length = 0
    start_time = 0
    end_time = 0

    if not c.SDL_SetAppMetadata(c"Infinite Monkeys", c"1.0", c"com.example.infinite-monkeys"):
        return 1

    if not c.SDL_Init(c.SDL_INIT_VIDEO):
        c.SDL_Log(c"Couldn't initialize SDL: %s", c.SDL_GetError())
        return 1
    defer c.SDL_Quit()
    defer:
        free_lines()
        if text_data != null:
            c.SDL_free(text_data)
            text_data = null

    if not c.SDL_CreateWindowAndRenderer(window_title, window_width, window_height, window_flags, ptr_of(ref_of(window)), ptr_of(ref_of(renderer))):
        c.SDL_Log(c"Couldn't create window/renderer: %s", c.SDL_GetError())
        return 1
    defer c.SDL_DestroyRenderer(renderer)
    defer c.SDL_DestroyWindow(window)

    c.SDL_SetRenderVSync(renderer, 1)

    var arg: i32 = 1
    unsafe:
        if arg < argc:
            let maybe_flag = cstr<-read(argv + usize<-arg)
            if c.SDL_strcmp(maybe_flag, c"--monkeys") == 0:
                arg += 1
                if arg < argc:
                    let maybe_count = cstr<-read(argv + usize<-arg)
                    monkeys = c.SDL_atoi(maybe_count)
                    arg += 1
                else:
                    let program_name = if argc > 0: cstr<-read(argv) else: c"infinite-monkeys"
                    c.SDL_Log(c"Usage: %s [--monkeys N] [file.txt]", program_name)
                    return 1

        if arg < argc:
            let file = cstr<-read(argv + usize<-arg)
            var size: usize = 0
            let loaded = c.SDL_LoadFile(file, ptr_of(ref_of(size)))
            if loaded == null:
                c.SDL_Log(c"Couldn't open %s: %s", file, c.SDL_GetError())
                return 1

            text_data = ptr[char]<-loaded

            text_length = size
        else:
            let copied = c.SDL_strdup(default_text)
            if copied == null:
                c.SDL_Log(c"Couldn't allocate default text: %s", c.SDL_GetError())
                return 1

            text_data = copied
            text_length = c.SDL_strlen(default_text)

    let loaded_text = text_data
    if loaded_text == null:
        return 1

    unsafe:
        progress = cstr<-loaded_text
    progress_remaining = text_length
    c.SDL_GetCurrentTime(ptr_of(ref_of(start_time)))
    on_window_size_changed()

    while pump_events():
        render_frame()

    return 0

def main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    return c.SDL_RunApp(argc, argv, app_main, null)
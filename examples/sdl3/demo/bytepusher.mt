import std.sdl3 as sdl
import std.str as text_ops

const SCREEN_W: int = 256
const SCREEN_H: int = 256
const RAM_SIZE: int = 0x1000000
const RAM_BYTES: int = RAM_SIZE + 8
const FRAMES_PER_SECOND: int = 60
const SAMPLES_PER_FRAME: int = 256
const MAX_AUDIO_LATENCY_FRAMES: int = 5

const IO_KEYBOARD: int = 0
const IO_PC: int = 2
const IO_SCREEN_PAGE: int = 5
const IO_AUDIO_BANK: int = 6
const KEY_ESCAPE: int = 27
const KEY_RETURN: int = 13

var ram: array[ubyte, RAM_BYTES]
var last_tick: long = 0
var tick_acc: long = 0
var status_text: str_buffer[32]
var status_ticks: int = 0
var keystate: ushort = 0
var display_help: bool = true
var positional_input: bool = false


function read_u16(addr: int) -> int:
    return (int<-ram[addr] << 8) | int<-ram[addr + 1]


function read_u24(addr: int) -> int:
    return (int<-ram[addr] << 16) | (int<-ram[addr + 1] << 8) | int<-ram[addr + 2]


function set_status(text: str) -> void:
    status_text.assign(text)
    status_ticks = FRAMES_PER_SECOND * 3


function shadow_text(renderer: sdl.Renderer, x: int, y: int, text: str) -> void:
    sdl.set_render_draw_color(renderer, 0, 0, 0, sdl.ALPHA_OPAQUE)
    sdl.render_debug_text(renderer, float<-(x + 1), float<-(y + 1), text)
    sdl.set_render_draw_color(renderer, 255, 255, 255, sdl.ALPHA_OPAQUE)
    sdl.render_debug_text(renderer, float<-x, float<-y, text)
    sdl.set_render_draw_color(renderer, 0, 0, 0, sdl.ALPHA_OPAQUE)


function basename(path: cstr) -> str:
    let text = text_ops.cstr_as_str(path)
    var last_sep: ptr_uint = 0
    var i: ptr_uint = 0
    while i < text.len:
        let c = text.byte_at(i)
        if c == byte<-'/' or c == byte<-'\\':
            last_sep = i + 1
        i += 1
    return text.slice(last_sep, text.len - last_sep)


function load_bytefile(path: cstr, audiostream: ptr[sdl.AudioStream]) -> bool:
    let stream = sdl.io_from_file(path, "rb")
    display_help = true
    for i in 0..RAM_SIZE:
        ram[i] = 0
    if stream == null:
        return false

    var bytes_read: ptr_uint = 0
    var ok = true
    while bytes_read < ptr_uint<-RAM_SIZE:
        let read = sdl.read_io(stream, unsafe: ptr[void]<-ptr_of(ram[int<-bytes_read]), ptr_uint<-RAM_SIZE - bytes_read)
        bytes_read += read
        if read == 0:
            ok = sdl.get_io_status(stream) == sdl.IOStatus.SDL_IO_STATUS_EOF
            break
    sdl.close_io(stream)

    sdl.clear_audio_stream(audiostream)
    display_help = not ok
    return ok


function keycode_mask(key: sdl.Keycode) -> ushort:
    let k = int<-key
    if k >= int<-'0' and k <= int<-'9':
        return ushort<-(1 << (k - int<-'0'))
    else if k >= int<-'a' and k <= int<-'f':
        return ushort<-(1 << (k - int<-'a' + 10))
    return 0


function scancode_mask(scancode: sdl.Scancode) -> ushort:
    var index = 0
    if scancode == sdl.Scancode.SDL_SCANCODE_1:
        index = 0x1
    else if scancode == sdl.Scancode.SDL_SCANCODE_2:
        index = 0x2
    else if scancode == sdl.Scancode.SDL_SCANCODE_3:
        index = 0x3
    else if scancode == sdl.Scancode.SDL_SCANCODE_4:
        index = 0xc
    else if scancode == sdl.Scancode.SDL_SCANCODE_Q:
        index = 0x4
    else if scancode == sdl.Scancode.SDL_SCANCODE_W:
        index = 0x5
    else if scancode == sdl.Scancode.SDL_SCANCODE_E:
        index = 0x6
    else if scancode == sdl.Scancode.SDL_SCANCODE_R:
        index = 0xd
    else if scancode == sdl.Scancode.SDL_SCANCODE_A:
        index = 0x7
    else if scancode == sdl.Scancode.SDL_SCANCODE_S:
        index = 0x8
    else if scancode == sdl.Scancode.SDL_SCANCODE_D:
        index = 0x9
    else if scancode == sdl.Scancode.SDL_SCANCODE_F:
        index = 0xe
    else if scancode == sdl.Scancode.SDL_SCANCODE_Z:
        index = 0xa
    else if scancode == sdl.Scancode.SDL_SCANCODE_X:
        index = 0x0
    else if scancode == sdl.Scancode.SDL_SCANCODE_C:
        index = 0xb
    else if scancode == sdl.Scancode.SDL_SCANCODE_V:
        index = 0xf
    else:
        return 0
    return ushort<-(1 << index)


function null_audio_callback(
    _userdata: ptr[void],
    _stream: ptr[sdl.AudioStream],
    _additional_frames: int,
    _total_frames: int
) -> void:
    pass


function main() -> int:
    if not sdl.set_app_metadata("SDL 3 BytePusher", "1.0", "com.example.SDL3BytePusher"):
        pass

    if not sdl.init(sdl.INIT_AUDIO | sdl.INIT_VIDEO):
        fatal(f"could not initialize SDL: #{sdl.get_error()}")
    defer: sdl.quit()

    var zoom = 2
    let primary_display = sdl.get_primary_display()
    var usable_bounds: sdl.Rect
    if sdl.get_display_usable_bounds(primary_display, ptr_of(usable_bounds)):
        let zoom_w = (usable_bounds.w - usable_bounds.x) * 2 / 3 / SCREEN_W
        let zoom_h = (usable_bounds.h - usable_bounds.y) * 2 / 3 / SCREEN_H
        zoom = if zoom_w < zoom_h: zoom_w else: zoom_h
        if zoom < 1:
            zoom = 1

    var window: sdl.Window = zero[sdl.Window]
    var renderer: sdl.Renderer = zero[sdl.Renderer]
    if not sdl.create_window_and_renderer(
        "SDL 3 BytePusher",
        SCREEN_W * zoom,
        SCREEN_H * zoom,
        sdl.WINDOW_RESIZABLE,
        window,
        renderer
    ):
        fatal(f"could not create window/renderer: #{sdl.get_error()}")
    defer: sdl.destroy_renderer(renderer)
    defer: sdl.destroy_window(window)

    if not sdl.set_render_logical_presentation(
        renderer,
        SCREEN_W,
        SCREEN_H,
        sdl.RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_INTEGER_SCALE
    ):
        pass

    let palette = sdl.create_palette(256) else:
        fatal(f"could not create palette: #{sdl.get_error()}")
    defer: sdl.destroy_palette(palette)

    unsafe:
        let colors = read(palette).colors
        var i = 0
        for r in 0..6:
            for g in 0..6:
                for b in 0..6:
                    colors[i] = sdl.Color(
                        r = ubyte<-(r * 0x33),
                        g = ubyte<-(g * 0x33),
                        b = ubyte<-(b * 0x33),
                        a = sdl.ALPHA_OPAQUE
                    )
                    i += 1
        while i < 256:
            colors[i] = sdl.Color(r = 0, g = 0, b = 0, a = sdl.ALPHA_OPAQUE)
            i += 1

    let texture = sdl.create_texture(
        renderer,
        sdl.PixelFormat.SDL_PIXELFORMAT_INDEX8,
        sdl.TextureAccess.SDL_TEXTUREACCESS_STREAMING,
        SCREEN_W,
        SCREEN_H
    ) else:
        fatal(f"could not create texture: #{sdl.get_error()}")
    defer: sdl.destroy_texture(texture)
    sdl.set_texture_palette(texture, palette)
    sdl.set_texture_scale_mode(texture, sdl.ScaleMode.SDL_SCALEMODE_NEAREST)

    let audio_spec = sdl.AudioSpec(
        format = sdl.AudioFormat.SDL_AUDIO_S8,
        channels = 1,
        freq = SAMPLES_PER_FRAME * FRAMES_PER_SECOND
    )
    let audiostream = sdl.open_audio_device_stream(
        0xFFFFFFFF,
        const_ptr_of(audio_spec),
        null_audio_callback,
        null
    ) else:
        fatal(f"could not open audio device: #{sdl.get_error()}")
    defer: sdl.destroy_audio_stream(audiostream)
    sdl.set_audio_stream_gain(audiostream, 0.1)
    sdl.resume_audio_stream_device(audiostream)

    let renderer_name = sdl.get_renderer_name(renderer)
    if renderer_name != null:
        set_status(f"renderer: #{text_ops.cstr_as_str(renderer_name)}")

    last_tick = long<-sdl.get_ticks_ns()
    tick_acc = sdl.NS_PER_SECOND

    var running = true
    while running:
        var ev: sdl.Event = zero[sdl.Event]
        while sdl.poll_event(ev):
            let ev_type = int<-ev.type
            if ev_type == int<-sdl.EventType.SDL_EVENT_QUIT:
                running = false
            else if ev_type == int<-sdl.EventType.SDL_EVENT_DROP_FILE:
                let file = ev.drop.data
                if load_bytefile(file, audiostream):
                    set_status(f"loaded #{basename(file)}")
                else:
                    set_status(f"load failed: #{basename(file)}")
            else if ev_type == int<-sdl.EventType.SDL_EVENT_KEY_DOWN:
                if int<-ev.key.key == KEY_ESCAPE:
                    running = false
                if int<-ev.key.key == KEY_RETURN:
                    positional_input = not positional_input
                    keystate = 0
                    set_status(if positional_input: "switched to positional input" else: "switched to symbolic input")
                keystate |= if positional_input: scancode_mask(ev.key.scancode) else: keycode_mask(ev.key.key)
            else if ev_type == int<-sdl.EventType.SDL_EVENT_KEY_UP:
                keystate &= if positional_input: ~scancode_mask(ev.key.scancode) else: ~keycode_mask(ev.key.key)

        let tick = long<-sdl.get_ticks_ns()
        let delta = tick - last_tick
        last_tick = tick
        tick_acc += delta * FRAMES_PER_SECOND
        let updated = tick_acc >= sdl.NS_PER_SECOND
        let skip_audio = tick_acc >= MAX_AUDIO_LATENCY_FRAMES * sdl.NS_PER_SECOND

        if skip_audio:
            sdl.clear_audio_stream(audiostream)

        while tick_acc >= sdl.NS_PER_SECOND:
            tick_acc -= sdl.NS_PER_SECOND

            ram[IO_KEYBOARD] = ubyte<-(int<-keystate >> 8)
            ram[IO_KEYBOARD + 1] = ubyte<-keystate

            var pc = read_u24(IO_PC)
            for _ in 0..SCREEN_W * SCREEN_H:
                let src = read_u24(pc)
                let dst = read_u24(pc + 3)
                ram[dst] = ram[src]
                pc = read_u24(pc + 6)

            if not skip_audio or tick_acc < sdl.NS_PER_SECOND:
                let bank = read_u16(IO_AUDIO_BANK)
                sdl.put_audio_stream_data(
                    audiostream,
                    unsafe: const_ptr[void]<-const_ptr_of(ram[bank << 8]),
                    SAMPLES_PER_FRAME
                )

        if updated:
            let page = int<-ram[IO_SCREEN_PAGE]
            sdl.update_texture(
                texture,
                null,
                unsafe: const_ptr[void]<-const_ptr_of(ram[page << 16]),
                SCREEN_W
            )

        sdl.render_clear(renderer)

        if display_help:
            shadow_text(renderer, 4, 4, "Drop a BytePusher file in this")
            shadow_text(renderer, 8, 12, "window to load and run it!")
            shadow_text(renderer, 4, 28, "Press ENTER to switch between")
            shadow_text(renderer, 8, 36, "positional and symbolic input.")
        else:
            sdl.render_texture(renderer, texture, null, null)

        if status_ticks > 0:
            if updated:
                status_ticks -= 1
            shadow_text(renderer, 4, SCREEN_H - 12, status_text.as_str())

        sdl.render_present(renderer)

    return 0

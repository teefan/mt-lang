module examples.sdl3.demo.bytepusher

import std.c.sdl3 as c

const screen_width: i32 = 256
const screen_height: i32 = 256
const ram_size: i32 = 0x1000000
const frames_per_second: c.Uint64 = 60
const samples_per_frame: i32 = 256
const ns_per_second: c.Uint64 = c.Uint64<-c.SDL_NS_PER_SECOND
const max_audio_latency_frames: c.Uint64 = 5
const io_keyboard: i32 = 0
const io_pc: i32 = 2
const io_screen_page: i32 = 5
const io_audio_bank: i32 = 6
const window_title: cstr = c"SDL 3 BytePusher"
const window_flags: u64 = u64<-c.SDL_WINDOW_RESIZABLE
const presentation_mode: c.SDL_RendererLogicalPresentation = c.SDL_RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_INTEGER_SCALE
const default_playback_device: u32 = u32<-0xFFFFFFFF
const status_buffer_len: i32 = screen_width / 8

var ram: array[c.Uint8, 16777224] = zero[array[c.Uint8, 16777224]]()
var last_tick: c.Uint64 = 0
var tick_acc: c.Uint64 = 0
var window: ptr[c.SDL_Window]
var renderer: ptr[c.SDL_Renderer]
var palette: ptr[c.SDL_Palette]? = null
var texture: ptr[c.SDL_Texture]? = null
var render_target: ptr[c.SDL_Texture]? = null
var audio_stream: ptr[c.SDL_AudioStream]? = null
var audio_device: c.SDL_AudioDeviceID = 0
var status: array[char, 32] = zero[array[char, 32]]()
var status_ticks: i32 = 0
var keystate: c.Uint16 = 0
var display_help: bool = true
var positional_input: bool = false


def chars_to_cstr(text: ptr[char]) -> cstr:
    unsafe:
        return cstr<-text


def read_u16(addr: i32) -> c.Uint16:
    return (c.Uint16<-ram[addr] << 8) | c.Uint16<-ram[addr + 1]


def read_u24(addr: i32) -> c.Uint32:
    return (c.Uint32<-ram[addr] << 16) | (c.Uint32<-ram[addr + 1] << 8) | c.Uint32<-ram[addr + 2]


def set_status_message(message: cstr) -> void:
    c.SDL_strlcpy(ptr_of(ref_of(status[0])), message, usize<-status_buffer_len)
    status[status_buffer_len - 1] = char<-0
    status_ticks = i32<-(frames_per_second * 3)


def set_status_filename(prefix: cstr, path: cstr) -> void:
    c.SDL_snprintf(ptr_of(ref_of(status[0])), usize<-status_buffer_len, prefix, filename(path))
    status[status_buffer_len - 1] = char<-0
    status_ticks = i32<-(frames_per_second * 3)


def set_status_renderer(name: cstr) -> void:
    c.SDL_snprintf(ptr_of(ref_of(status[0])), usize<-status_buffer_len, c"renderer: %s", name)
    status[status_buffer_len - 1] = char<-0
    status_ticks = i32<-(frames_per_second * 3)


def filename(path: cstr) -> cstr:
    var index = i32<-c.SDL_strlen(path)
    var result = path

    unsafe:
        let path_ptr = ptr[char]<-path

        while index > 0:
            index -= 1
            let ch = read(path_ptr + usize<-index)
            if ch == char<-47 or ch == char<-92:
                result = cstr<-(path_ptr + usize<-(index + 1))
                break

    return result


def load_stream(stream: ptr[c.SDL_IOStream]?, close_io: bool) -> bool:
    var bytes_read: usize = 0
    var ok = true

    c.SDL_memset(ptr_of(ref_of(ram[0])), 0, usize<-ram_size)

    if stream == null:
        return false

    while bytes_read < usize<-ram_size:
        let read_count = c.SDL_ReadIO(stream, ptr_of(ref_of(ram[i32<-bytes_read])), usize<-ram_size - bytes_read)
        bytes_read += read_count
        if read_count == 0:
            ok = c.SDL_GetIOStatus(stream) == c.SDL_IOStatus.SDL_IO_STATUS_EOF
            break

    if close_io:
        c.SDL_CloseIO(stream)

    if audio_stream != null:
        c.SDL_ClearAudioStream(audio_stream)

    display_help = not ok
    return ok


def load_file(path: cstr) -> bool:
    if load_stream(c.SDL_IOFromFile(path, c"rb"), true):
        set_status_filename(c"loaded %s", path)
        return true

    set_status_filename(c"load failed: %s", path)
    return false


def print_text(x: i32, y: i32, text: cstr) -> void:
    c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderDebugText(renderer, f32<-(x + 1), f32<-(y + 1), text)
    c.SDL_SetRenderDrawColor(renderer, 0xFF, 0xFF, 0xFF, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderDebugText(renderer, f32<-x, f32<-y, text)
    c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, c.SDL_ALPHA_OPAQUE)


def keycode_mask(key: u32) -> c.Uint16:
    if key >= u32<-48 and key <= u32<-57:
        return c.Uint16<-1 << c.Uint16<-(key - u32<-48)

    if key >= u32<-65 and key <= u32<-70:
        return c.Uint16<-1 << c.Uint16<-(key - u32<-65 + u32<-10)

    if key >= u32<-97 and key <= u32<-102:
        return c.Uint16<-1 << c.Uint16<-(key - u32<-97 + u32<-10)

    return 0


def scancode_mask(scancode: c.SDL_Scancode) -> c.Uint16:
    if scancode == c.SDL_Scancode.SDL_SCANCODE_1:
        return c.Uint16<-1 << c.Uint16<-0x1
    elif scancode == c.SDL_Scancode.SDL_SCANCODE_2:
        return c.Uint16<-1 << c.Uint16<-0x2
    elif scancode == c.SDL_Scancode.SDL_SCANCODE_3:
        return c.Uint16<-1 << c.Uint16<-0x3
    elif scancode == c.SDL_Scancode.SDL_SCANCODE_4:
        return c.Uint16<-1 << c.Uint16<-0xC
    elif scancode == c.SDL_Scancode.SDL_SCANCODE_Q:
        return c.Uint16<-1 << c.Uint16<-0x4
    elif scancode == c.SDL_Scancode.SDL_SCANCODE_W:
        return c.Uint16<-1 << c.Uint16<-0x5
    elif scancode == c.SDL_Scancode.SDL_SCANCODE_E:
        return c.Uint16<-1 << c.Uint16<-0x6
    elif scancode == c.SDL_Scancode.SDL_SCANCODE_R:
        return c.Uint16<-1 << c.Uint16<-0xD
    elif scancode == c.SDL_Scancode.SDL_SCANCODE_A:
        return c.Uint16<-1 << c.Uint16<-0x7
    elif scancode == c.SDL_Scancode.SDL_SCANCODE_S:
        return c.Uint16<-1 << c.Uint16<-0x8
    elif scancode == c.SDL_Scancode.SDL_SCANCODE_D:
        return c.Uint16<-1 << c.Uint16<-0x9
    elif scancode == c.SDL_Scancode.SDL_SCANCODE_F:
        return c.Uint16<-1 << c.Uint16<-0xE
    elif scancode == c.SDL_Scancode.SDL_SCANCODE_Z:
        return c.Uint16<-1 << c.Uint16<-0xA
    elif scancode == c.SDL_Scancode.SDL_SCANCODE_X:
        return c.Uint16<-1 << c.Uint16<-0x0
    elif scancode == c.SDL_Scancode.SDL_SCANCODE_C:
        return c.Uint16<-1 << c.Uint16<-0xB
    elif scancode == c.SDL_Scancode.SDL_SCANCODE_V:
        return c.Uint16<-1 << c.Uint16<-0xF

    return 0


def pump_events() -> bool:
    var event = zero[c.SDL_Event]()

    while c.SDL_PollEvent(ptr_of(ref_of(event))):
        if event.type_ == u32<-c.SDL_EventType.SDL_EVENT_QUIT:
            return false
        elif event.type_ == u32<-c.SDL_EventType.SDL_EVENT_DROP_FILE:
            load_file(event.drop.data)
        elif event.type_ == u32<-c.SDL_EventType.SDL_EVENT_KEY_DOWN:
            if event.key.scancode == c.SDL_Scancode.SDL_SCANCODE_ESCAPE:
                return false

            if event.key.scancode == c.SDL_Scancode.SDL_SCANCODE_RETURN:
                positional_input = not positional_input
                keystate = 0
                if positional_input:
                    set_status_message(c"switched to positional input")
                else:
                    set_status_message(c"switched to symbolic input")

            if positional_input:
                keystate |= scancode_mask(event.key.scancode)
            else:
                keystate |= keycode_mask(event.key.key)
        elif event.type_ == u32<-c.SDL_EventType.SDL_EVENT_KEY_UP:
            if positional_input:
                let mask = scancode_mask(event.key.scancode)
                keystate &= c.Uint16<-~mask
            else:
                let mask = keycode_mask(event.key.key)
                keystate &= c.Uint16<-~mask

    return true


def render_frame() -> void:
    let tick = c.SDL_GetTicksNS()
    let delta = tick - last_tick
    let active_audio_stream = audio_stream
    let active_texture = texture
    let active_render_target = render_target

    last_tick = tick
    tick_acc += delta * frames_per_second

    let updated = tick_acc >= ns_per_second
    let skip_audio = tick_acc >= max_audio_latency_frames * ns_per_second

    if skip_audio and active_audio_stream != null:
        c.SDL_ClearAudioStream(active_audio_stream)

    while tick_acc >= ns_per_second:
        tick_acc -= ns_per_second
        ram[io_keyboard] = c.Uint8<-(keystate >> 8)
        ram[io_keyboard + 1] = c.Uint8<-keystate

        var pc = i32<-read_u24(io_pc)
        for index in range(0, screen_width * screen_height):
            let src = i32<-read_u24(pc)
            let dst = i32<-read_u24(pc + 3)
            ram[dst] = ram[src]
            pc = i32<-read_u24(pc + 6)

        if (not skip_audio or tick_acc < ns_per_second) and active_audio_stream != null:
            let audio_offset = i32<-read_u16(io_audio_bank) * 256
            c.SDL_PutAudioStreamData(active_audio_stream, ptr_of(ref_of(ram[audio_offset])), samples_per_frame)

    if updated and active_texture != null and active_render_target != null:
        let pixel_offset = i32<-ram[io_screen_page] << 16
        c.SDL_UpdateTexture(active_texture, null, ptr_of(ref_of(ram[pixel_offset])), screen_width)

        c.SDL_SetRenderTarget(renderer, active_render_target)
        c.SDL_RenderTexture(renderer, active_texture, null, null)

        if display_help:
            print_text(4, 4, c"Drop a BytePusher file in this")
            print_text(8, 12, c"window to load and run it!")
            print_text(4, 28, c"Press ENTER to switch between")
            print_text(8, 36, c"positional and symbolic input.")

        if status_ticks > 0:
            status_ticks -= 1
            print_text(4, screen_height - 12, chars_to_cstr(ptr_of(ref_of(status[0]))))

    c.SDL_SetRenderTarget(renderer, null)
    c.SDL_RenderClear(renderer)
    if active_render_target != null:
        c.SDL_RenderTexture(renderer, active_render_target, null, null)
    c.SDL_RenderPresent(renderer)


def app_main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    var usable_bounds = zero[c.SDL_Rect]()
    var audio_spec = zero[c.SDL_AudioSpec]()
    var zoom = 2

    if not c.SDL_SetAppMetadata(c"SDL 3 BytePusher", c"1.0", c"com.example.SDL3BytePusher"):
        return 1

    if not c.SDL_SetAppMetadataProperty(c"SDL.app.metadata.url", c"https://examples.libsdl.org/SDL3/demo/04-bytepusher/"):
        return 1
    if not c.SDL_SetAppMetadataProperty(c"SDL.app.metadata.creator", c"SDL team"):
        return 1
    if not c.SDL_SetAppMetadataProperty(c"SDL.app.metadata.copyright", c"Placed in the public domain"):
        return 1
    if not c.SDL_SetAppMetadataProperty(c"SDL.app.metadata.kind", c"game"):
        return 1

    if not c.SDL_Init(c.SDL_INIT_AUDIO | c.SDL_INIT_VIDEO):
        return 1
    defer c.SDL_Quit()
    defer:
        if audio_stream != null:
            c.SDL_DestroyAudioStream(audio_stream)
        if texture != null:
            c.SDL_DestroyTexture(texture)
        if render_target != null:
            c.SDL_DestroyTexture(render_target)
        if palette != null:
            c.SDL_DestroyPalette(palette)
        if audio_device != 0:
            c.SDL_CloseAudioDevice(audio_device)

    display_help = true

    let primary_display = c.SDL_GetPrimaryDisplay()
    if c.SDL_GetDisplayUsableBounds(primary_display, ptr_of(ref_of(usable_bounds))):
        let zoom_w = (usable_bounds.w - usable_bounds.x) * 2 / 3 / screen_width
        let zoom_h = (usable_bounds.h - usable_bounds.y) * 2 / 3 / screen_height
        if zoom_w < zoom_h:
            zoom = zoom_w
        else:
            zoom = zoom_h

        if zoom < 1:
            zoom = 1

    if not c.SDL_CreateWindowAndRenderer(window_title, screen_width * zoom, screen_height * zoom, window_flags, ptr_of(ref_of(window)), ptr_of(ref_of(renderer))):
        return 1
    defer c.SDL_DestroyRenderer(renderer)
    defer c.SDL_DestroyWindow(window)

    if not c.SDL_SetRenderLogicalPresentation(renderer, screen_width, screen_height, presentation_mode):
        return 1

    var created_palette = c.SDL_CreatePalette(256)
    palette = created_palette

    var color_index = 0
    unsafe:
        for red in range(0, 6):
            for green in range(0, 6):
                for blue in range(0, 6):
                    created_palette.colors[color_index] = c.SDL_Color(
                        r = c.Uint8<-(red * 0x33),
                        g = c.Uint8<-(green * 0x33),
                        b = c.Uint8<-(blue * 0x33),
                        a = c.SDL_ALPHA_OPAQUE,
                    )
                    color_index += 1

        for index in range(color_index, 256):
            created_palette.colors[index] = c.SDL_Color(r = 0, g = 0, b = 0, a = c.SDL_ALPHA_OPAQUE)

    let created_texture = c.SDL_CreateTexture(renderer, c.SDL_PixelFormat.SDL_PIXELFORMAT_INDEX8, c.SDL_TextureAccess.SDL_TEXTUREACCESS_STREAMING, screen_width, screen_height)
    let created_render_target = c.SDL_CreateTexture(renderer, c.SDL_PixelFormat.SDL_PIXELFORMAT_UNKNOWN, c.SDL_TextureAccess.SDL_TEXTUREACCESS_TARGET, screen_width, screen_height)
    if created_texture == null or created_render_target == null:
        return 1

    texture = created_texture
    render_target = created_render_target

    if not c.SDL_SetTexturePalette(created_texture, created_palette):
        return 1
    if not c.SDL_SetTextureScaleMode(created_texture, c.SDL_ScaleMode.SDL_SCALEMODE_NEAREST):
        return 1
    if not c.SDL_SetTextureScaleMode(created_render_target, c.SDL_ScaleMode.SDL_SCALEMODE_NEAREST):
        return 1

    audio_spec.channels = 1
    audio_spec.format = c.SDL_AudioFormat.SDL_AUDIO_S8
    audio_spec.freq = samples_per_frame * i32<-frames_per_second

    audio_device = c.SDL_OpenAudioDevice(default_playback_device, null)
    if audio_device == 0:
        return 1

    let created_stream = c.SDL_CreateAudioStream(ptr_of(ref_of(audio_spec)), null)
    if created_stream == null:
        return 1
    if not c.SDL_BindAudioStream(audio_device, created_stream):
        c.SDL_DestroyAudioStream(created_stream)
        return 1
    if not c.SDL_SetAudioStreamGain(created_stream, 0.1):
        c.SDL_DestroyAudioStream(created_stream)
        return 1

    audio_stream = created_stream

    set_status_renderer(c.SDL_GetRendererName(renderer))
    last_tick = c.SDL_GetTicksNS()
    tick_acc = ns_per_second

    if argc > 1:
        unsafe:
            load_file(cstr<-read(argv + usize<-1))

    while pump_events():
        render_frame()

    return 0


def main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    return c.SDL_RunApp(argc, argv, app_main, null)

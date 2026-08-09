import std.sdl3 as sdl
import std.sdl3.runtime as runtime
import std.str as text_ops

const WINDOW_WIDTH: int = 640
const WINDOW_HEIGHT: int = 480
const BUTTON_COUNT: int = 17


function main() -> int:
    if not sdl.init(sdl.INIT_VIDEO | sdl.INIT_GAMEPAD):
        fatal(f"could not initialize SDL: #{sdl.get_error()}")
    defer: sdl.quit()

    var window: sdl.Window = zero[sdl.Window]
    var renderer: sdl.Renderer = zero[sdl.Renderer]
    if not sdl.create_window_and_renderer(
        "examples/input/gamepad-polling",
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
        sdl.RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_STRETCH
    ):
        fatal(f"could not set render logical presentation: #{sdl.get_error()}")

    var path = runtime.asset_path("gamepad_front.png")
    defer: path.release()
    let surface = sdl.load_png(path.as_str()) else:
        fatal(f"could not load gamepad_front.png: #{sdl.get_error()}")
    let texture = sdl.create_texture_from_surface(renderer, surface) else:
        fatal(f"could not create texture: #{sdl.get_error()}")
    sdl.destroy_surface(surface)
    defer: sdl.destroy_texture(texture)

    var gamepad: ptr[sdl.Gamepad]? = null

    var running = true
    while running:
        var ev: sdl.Event = zero[sdl.Event]
        while sdl.poll_event(ev):
            let ev_type = int<-ev.type
            if ev_type == int<-sdl.EventType.SDL_EVENT_QUIT:
                running = false
            else if ev_type == int<-sdl.EventType.SDL_EVENT_GAMEPAD_ADDED:
                if gamepad == null:
                    gamepad = sdl.open_gamepad(ev.gdevice.which)
                    if gamepad == null:
                        fatal(f"failed to open gamepad: #{sdl.get_error()}")
            else if ev_type == int<-sdl.EventType.SDL_EVENT_GAMEPAD_REMOVED:
                if gamepad != null and sdl.get_gamepad_id(gamepad) == ev.gdevice.which:
                    sdl.close_gamepad(gamepad)
                    gamepad = null

        var text: cstr? = null
        if gamepad != null:
            text = sdl.get_gamepad_name(gamepad)

        var leftthumblast: ptr_uint = 0xFFFFFFFF
        var rightthumblast: ptr_uint = 0xFFFFFFFF
        let now = sdl.get_ticks()

        sdl.set_render_draw_color(renderer, 0xFF, 0xFF, 0xFF, 0xFF)
        sdl.render_clear(renderer)

        if gamepad != null:
            let button_rects = array[sdl.FRect, BUTTON_COUNT](
                sdl.FRect(x = 497, y = 266, w = 38, h = 38),
                sdl.FRect(x = 550, y = 217, w = 38, h = 38),
                sdl.FRect(x = 445, y = 221, w = 38, h = 38),
                sdl.FRect(x = 499, y = 173, w = 38, h = 38),
                sdl.FRect(x = 235, y = 228, w = 32, h = 29),
                sdl.FRect(x = 287, y = 195, w = 69, h = 69),
                sdl.FRect(x = 377, y = 228, w = 32, h = 29),
                sdl.FRect(x = 91, y = 234, w = 63, h = 63),
                sdl.FRect(x = 381, y = 354, w = 63, h = 63),
                sdl.FRect(x = 74, y = 73, w = 102, h = 29),
                sdl.FRect(x = 468, y = 73, w = 102, h = 29),
                sdl.FRect(x = 207, y = 316, w = 32, h = 32),
                sdl.FRect(x = 207, y = 384, w = 32, h = 32),
                sdl.FRect(x = 173, y = 351, w = 32, h = 32),
                sdl.FRect(x = 242, y = 351, w = 32, h = 32),
                sdl.FRect(x = 310, y = 286, w = 23, h = 27)
            )

            sdl.render_texture(renderer, texture, null, null)

            sdl.set_render_draw_color(renderer, 0x00, 0xFF, 0x00, 0xFF)
            for i in 0..BUTTON_COUNT - 1:
                let button = sdl.GamepadButton<-(int<-sdl.GamepadButton.SDL_GAMEPAD_BUTTON_SOUTH + i)
                if sdl.get_gamepad_button(gamepad, button):
                    sdl.render_fill_rect(renderer, button_rects[i])

            sdl.set_render_draw_color(renderer, 0x00, 0x00, 0xFF, 0xFF)

            let left_axis_x = sdl.get_gamepad_axis(gamepad, sdl.GamepadAxis.SDL_GAMEPAD_AXIS_LEFTX)
            let left_axis_y = sdl.get_gamepad_axis(gamepad, sdl.GamepadAxis.SDL_GAMEPAD_AXIS_LEFTY)
            if sdl.abs(left_axis_x) > 1000 or sdl.abs(left_axis_y) > 1000:
                leftthumblast = now
            if now - leftthumblast < 500:
                sdl.render_fill_rect(
                    renderer,
                    sdl.FRect(
                        x = 107 + (left_axis_x / 32767.0) * 30.0,
                        y = 252 + (left_axis_y / 32767.0) * 30.0,
                        w = 30,
                        h = 30
                    )
                )

            let right_axis_x = sdl.get_gamepad_axis(gamepad, sdl.GamepadAxis.SDL_GAMEPAD_AXIS_RIGHTX)
            let right_axis_y = sdl.get_gamepad_axis(gamepad, sdl.GamepadAxis.SDL_GAMEPAD_AXIS_RIGHTY)
            if sdl.abs(right_axis_x) > 1000 or sdl.abs(right_axis_y) > 1000:
                rightthumblast = now
            if now - rightthumblast < 500:
                sdl.render_fill_rect(
                    renderer,
                    sdl.FRect(
                        x = 397 + (right_axis_x / 32767.0) * 30.0,
                        y = 370 + (right_axis_y / 32767.0) * 30.0,
                        w = 30,
                        h = 30
                    )
                )

            let left_trigger = sdl.get_gamepad_axis(gamepad, sdl.GamepadAxis.SDL_GAMEPAD_AXIS_LEFT_TRIGGER)
            if left_trigger > 1000:
                let trigger_height = (left_trigger / 32767.0) * 65.0
                sdl.render_fill_rect(
                    renderer,
                    sdl.FRect(x = 127, y = 1.0 + 65.0 - trigger_height, w = 37, h = trigger_height)
                )

            let right_trigger = sdl.get_gamepad_axis(gamepad, sdl.GamepadAxis.SDL_GAMEPAD_AXIS_RIGHT_TRIGGER)
            if right_trigger > 1000:
                let trigger_height = (right_trigger / 32767.0) * 65.0
                sdl.render_fill_rect(
                    renderer,
                    sdl.FRect(x = 481, y = 1.0 + 65.0 - trigger_height, w = 37, h = trigger_height)
                )

        let label = if text != null: text_ops.cstr_as_str(text) else: "Plug in a gamepad, please."
        let text_x = (WINDOW_WIDTH - runtime.debug_text_width(label)) / 2.0
        let text_y = if gamepad != null:
            float<-(WINDOW_HEIGHT - (sdl.DEBUG_TEXT_FONT_CHARACTER_SIZE + 2))
        else:
            (WINDOW_HEIGHT - sdl.DEBUG_TEXT_FONT_CHARACTER_SIZE) / 2.0
        sdl.set_render_draw_color(renderer, 0x00, 0x00, 0xFF, 0xFF)
        sdl.render_debug_text(renderer, text_x, text_y, label)
        sdl.render_present(renderer)

    return 0

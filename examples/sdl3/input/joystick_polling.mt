import std.sdl3 as sdl
import std.sdl3.runtime as runtime
import std.str as text_ops

const WINDOW_WIDTH: int = 640
const WINDOW_HEIGHT: int = 480
const COLOR_COUNT: int = 64


function main() -> int:
    if not sdl.init(sdl.INIT_VIDEO | sdl.INIT_JOYSTICK):
        fatal(f"could not initialize SDL: #{sdl.get_error()}")
    defer: sdl.quit()

    var window: sdl.Window = zero[sdl.Window]
    var renderer: sdl.Renderer = zero[sdl.Renderer]
    if not sdl.create_window_and_renderer(
        "examples/input/joystick-polling",
        WINDOW_WIDTH,
        WINDOW_HEIGHT,
        sdl.WINDOW_RESIZABLE,
        window,
        renderer
    ):
        fatal(f"could not create window/renderer: #{sdl.get_error()}")
    defer: sdl.destroy_renderer(renderer)
    defer: sdl.destroy_window(window)

    var colors: array[sdl.Color, COLOR_COUNT]
    for i in 0..COLOR_COUNT:
        colors[i] = sdl.Color(
            r = ubyte<-sdl.rand(255),
            g = ubyte<-sdl.rand(255),
            b = ubyte<-sdl.rand(255),
            a = 255
        )

    var joystick: ptr[sdl.Joystick]? = null

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
                    if joystick == null:
                        fatal(f"failed to open joystick: #{sdl.get_error()}")
            else if ev_type == int<-sdl.EventType.SDL_EVENT_JOYSTICK_REMOVED:
                if joystick != null and sdl.get_joystick_id(joystick) == ev.jdevice.which:
                    sdl.close_joystick(joystick)
                    joystick = null

        var text: cstr? = null
        if joystick != null:
            text = sdl.get_joystick_name(joystick)

        sdl.set_render_draw_color(renderer, 0, 0, 0, 255)
        sdl.render_clear(renderer)
        var winw: int = 640
        var winh: int = 480
        sdl.get_window_size(window, winw, winh)

        if joystick != null:
            let size = 30.0
            var total = sdl.get_num_joystick_axes(joystick)
            var bar_y = (winh - total * size) / 2.0
            let axis_x = winw / 2.0
            for i in 0..total:
                let color = colors[i % COLOR_COUNT]
                let val = sdl.get_joystick_axis(joystick, i) / 32767.0
                let dx = axis_x + val * axis_x
                sdl.set_render_draw_color(renderer, color.r, color.g, color.b, color.a)
                sdl.render_fill_rect(renderer, sdl.FRect(x = dx, y = bar_y, w = axis_x - sdl.fabsf(dx), h = size))
                bar_y += size

            total = sdl.get_num_joystick_buttons(joystick)
            var button_x = (winw - total * size) / 2.0
            for i in 0..total:
                let color = colors[i % COLOR_COUNT]
                let dst = sdl.FRect(x = button_x, y = 0.0, w = size, h = size)
                if sdl.get_joystick_button(joystick, i):
                    sdl.set_render_draw_color(renderer, color.r, color.g, color.b, color.a)
                else:
                    sdl.set_render_draw_color(renderer, 0, 0, 0, 255)
                sdl.render_fill_rect(renderer, dst)
                sdl.set_render_draw_color(renderer, 255, 255, 255, color.a)
                sdl.render_rect(renderer, dst)
                button_x += size

            total = sdl.get_num_joystick_hats(joystick)
            var hat_x = (winw - total * (size * 2.0)) / 2.0 + size / 2.0
            let hat_y = winh - size
            for i in 0..total:
                let color = colors[i % COLOR_COUNT]
                let thirdsize = size / 3.0
                var cross = array[sdl.FRect, 2](
                    sdl.FRect(x = hat_x, y = hat_y + thirdsize, w = size, h = thirdsize),
                    sdl.FRect(x = hat_x + thirdsize, y = hat_y, w = thirdsize, h = size)
                )
                let hat = sdl.get_joystick_hat(joystick, i)
                let up_rect = sdl.FRect(x = hat_x + thirdsize, y = hat_y, w = thirdsize, h = thirdsize)
                let right_rect = sdl.FRect(
                    x = hat_x + thirdsize * 2.0,
                    y = hat_y + thirdsize,
                    w = thirdsize,
                    h = thirdsize
                )
                let down_rect = sdl.FRect(
                    x = hat_x + thirdsize,
                    y = hat_y + thirdsize * 2.0,
                    w = thirdsize,
                    h = thirdsize
                )
                let left_rect = sdl.FRect(x = hat_x, y = hat_y + thirdsize, w = thirdsize, h = thirdsize)
                sdl.set_render_draw_color(renderer, 90, 90, 90, 255)
                sdl.render_fill_rects(renderer, cross)
                sdl.set_render_draw_color(renderer, color.r, color.g, color.b, color.a)
                if (uint<-hat & sdl.HAT_UP) != 0:
                    sdl.render_fill_rect(renderer, up_rect)
                if (uint<-hat & sdl.HAT_RIGHT) != 0:
                    sdl.render_fill_rect(renderer, right_rect)
                if (uint<-hat & sdl.HAT_DOWN) != 0:
                    sdl.render_fill_rect(renderer, down_rect)
                if (uint<-hat & sdl.HAT_LEFT) != 0:
                    sdl.render_fill_rect(renderer, left_rect)
                hat_x += size * 2.0

        let label = if text != null: text_ops.cstr_as_str(text) else: "Plug in a joystick, please."
        let text_x = (winw - runtime.debug_text_width(label)) / 2.0
        let text_y = (winh - sdl.DEBUG_TEXT_FONT_CHARACTER_SIZE) / 2.0
        sdl.set_render_draw_color(renderer, 255, 255, 255, 255)
        sdl.render_debug_text(renderer, text_x, text_y, label)
        sdl.render_present(renderer)

    return 0

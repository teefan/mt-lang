import std.sdl3 as sdl

const WINDOW_WIDTH: int = 640
const WINDOW_HEIGHT: int = 480

var pressure: float = 0.0
var previous_touch_x: float = -1.0
var previous_touch_y: float = -1.0
var tilt_x: float = 0.0
var tilt_y: float = 0.0


function main() -> int:
    if not sdl.init(sdl.INIT_VIDEO):
        fatal(f"could not initialize SDL: #{sdl.get_error()}")
    defer: sdl.quit()

    var window: sdl.Window = zero[sdl.Window]
    var renderer: sdl.Renderer = zero[sdl.Renderer]
    if not sdl.create_window_and_renderer(
        "examples/pen/drawing-lines",
        WINDOW_WIDTH,
        WINDOW_HEIGHT,
        0,
        window,
        renderer
    ):
        fatal(f"could not create window/renderer: #{sdl.get_error()}")
    defer: sdl.destroy_renderer(renderer)
    defer: sdl.destroy_window(window)

    var output_w: int = 0
    var output_h: int = 0
    sdl.get_render_output_size(renderer, output_w, output_h)
    let render_target = sdl.create_texture(
        renderer,
        sdl.PixelFormat.SDL_PIXELFORMAT_RGBA8888,
        sdl.TextureAccess.SDL_TEXTUREACCESS_TARGET,
        output_w,
        output_h
    ) else:
        fatal(f"could not create render target: #{sdl.get_error()}")
    defer: sdl.destroy_texture(render_target)

    sdl.set_render_target(renderer, render_target)
    sdl.set_render_draw_color(renderer, 100, 100, 100, sdl.ALPHA_OPAQUE)
    sdl.render_clear(renderer)
    sdl.set_render_target(renderer, null)
    sdl.set_render_draw_blend_mode(renderer, sdl.BLENDMODE_BLEND)

    var running = true
    while running:
        var ev: sdl.Event = zero[sdl.Event]
        while sdl.poll_event(ev):
            let ev_type = int<-ev.type
            if ev_type == int<-sdl.EventType.SDL_EVENT_QUIT:
                running = false
            else if ev_type == int<-sdl.EventType.SDL_EVENT_PEN_MOTION:
                if pressure > 0.0:
                    if previous_touch_x >= 0.0:
                        sdl.set_render_target(renderer, render_target)
                        sdl.set_render_draw_color_float(renderer, 0, 0, 0, pressure)
                        sdl.render_line(renderer, previous_touch_x, previous_touch_y, ev.pmotion.x, ev.pmotion.y)
                    previous_touch_x = ev.pmotion.x
                    previous_touch_y = ev.pmotion.y
                else:
                    previous_touch_x = -1.0
                    previous_touch_y = -1.0
            else if ev_type == int<-sdl.EventType.SDL_EVENT_PEN_AXIS:
                if ev.paxis.axis == sdl.PenAxis.SDL_PEN_AXIS_PRESSURE:
                    pressure = ev.paxis.value
                else if ev.paxis.axis == sdl.PenAxis.SDL_PEN_AXIS_XTILT:
                    tilt_x = ev.paxis.value
                else if ev.paxis.axis == sdl.PenAxis.SDL_PEN_AXIS_YTILT:
                    tilt_y = ev.paxis.value

        sdl.set_render_target(renderer, null)
        sdl.set_render_draw_color(renderer, 0, 0, 0, sdl.ALPHA_OPAQUE)
        sdl.render_clear(renderer)
        sdl.render_texture(renderer, render_target, null, null)
        sdl.set_render_draw_color(renderer, 255, 255, 255, 255)
        sdl.render_debug_text(renderer, 0, 8, f"Tilt: #{tilt_x} #{tilt_y}")
        sdl.render_present(renderer)

    return 0

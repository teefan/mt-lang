module examples.sdl3.renderer.points

import std.c.sdl3 as c

const window_width: int = 640
const window_height: int = 480
const window_title: cstr = c"examples/renderer/points"
const presentation_mode: c.SDL_RendererLogicalPresentation = c.SDL_RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX
const window_flags: ulong = ulong<-c.SDL_WINDOW_RESIZABLE
const point_count: int = 500
const min_pixels_per_second: float = 30.0
const max_pixels_per_second: float = 60.0

var window: ptr[c.SDL_Window]
var renderer: ptr[c.SDL_Renderer]
var last_time: ptr_uint = 0
var points: array[c.SDL_FPoint, 500] = zero[array[c.SDL_FPoint, 500]]
var point_speeds: array[float, 500] = zero[array[float, 500]]


def pump_events() -> bool:
    var event = zero[c.SDL_Event]

    while c.SDL_PollEvent(ptr_of(event)):
        if event.type_ == uint<-c.SDL_EventType.SDL_EVENT_QUIT:
            return false

    return true


def render_frame() -> void:
    let now = c.SDL_GetTicks()
    let elapsed = float<-(now - last_time) / 1000.0
    let width_f = float<-window_width
    let height_f = float<-window_height

    for index in 0..point_count:
        let distance = elapsed * point_speeds[index]
        points[index].x += distance
        points[index].y += distance

        if points[index].x >= width_f or points[index].y >= height_f:
            if c.SDL_rand(2) != 0:
                points[index].x = c.SDL_randf() * width_f
                points[index].y = 0.0
            else:
                points[index].x = 0.0
                points[index].y = c.SDL_randf() * height_f

            point_speeds[index] = min_pixels_per_second + (c.SDL_randf() * (max_pixels_per_second - min_pixels_per_second))

    last_time = now

    c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderClear(renderer)
    c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderPoints(renderer, ptr_of(points[0]), point_count)
    c.SDL_RenderPresent(renderer)


def app_main(argc: int, argv: ptr[ptr[char]]) -> int:
    c.SDL_SetAppMetadata(c"Example Renderer Points", c"1.0", c"com.example.renderer-points")

    if not c.SDL_Init(c.SDL_INIT_VIDEO):
        return 1
    defer c.SDL_Quit()

    if not c.SDL_CreateWindowAndRenderer(window_title, window_width, window_height, window_flags, ptr_of(window), ptr_of(renderer)):
        return 1
    defer c.SDL_DestroyRenderer(renderer)
    defer c.SDL_DestroyWindow(window)

    if not c.SDL_SetRenderLogicalPresentation(renderer, window_width, window_height, presentation_mode):
        return 1

    for index in 0..point_count:
        points[index].x = c.SDL_randf() * float<-window_width
        points[index].y = c.SDL_randf() * float<-window_height
        point_speeds[index] = min_pixels_per_second + (c.SDL_randf() * (max_pixels_per_second - min_pixels_per_second))

    last_time = c.SDL_GetTicks()

    while pump_events():
        render_frame()

    return 0


def main(argc: int, argv: ptr[ptr[char]]) -> int:
    return c.SDL_RunApp(argc, argv, app_main, null)

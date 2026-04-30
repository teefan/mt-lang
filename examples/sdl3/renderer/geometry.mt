module examples.sdl3.renderer.geometry

import std.c.sdl3 as c

const sample_texture_path: cstr = c"../resources/sample.png"
const window_width: i32 = 640
const window_height: i32 = 480
const window_title: cstr = c"examples/renderer/geometry"
const presentation_mode: c.SDL_RendererLogicalPresentation = c.SDL_RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX
const window_flags: u64 = u64<-c.SDL_WINDOW_RESIZABLE

var window: ptr[c.SDL_Window]
var renderer: ptr[c.SDL_Renderer]
var texture: ptr[c.SDL_Texture]
var texture_width: i32 = 0
var texture_height: i32 = 0

def pump_events() -> bool:
    var event = c.SDL_Event(type = 0)

    while c.SDL_PollEvent(raw(addr(event))):
        if event.quit.type == c.SDL_EventType.SDL_EVENT_QUIT:
            return false

    return true

def render_frame() -> void:
    let now = i32<-c.SDL_GetTicks()
    let direction = if (now % 2000) >= 1000 then 1.0 else -1.0
    let scale = (f32<-((now % 1000) - 500) / 500.0) * direction
    let size = 200.0 + (200.0 * scale)

    var vertices = zero[array[c.SDL_Vertex, 4]]()
    var indices = array[i32, 6](0, 1, 2, 1, 2, 3)

    c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderClear(renderer)

    vertices[0].position.x = f32<-window_width / 2.0
    vertices[0].position.y = (f32<-window_height - size) / 2.0
    vertices[0].color.r = 1.0
    vertices[0].color.a = 1.0

    vertices[1].position.x = (f32<-window_width + size) / 2.0
    vertices[1].position.y = (f32<-window_height + size) / 2.0
    vertices[1].color.g = 1.0
    vertices[1].color.a = 1.0

    vertices[2].position.x = (f32<-window_width - size) / 2.0
    vertices[2].position.y = (f32<-window_height + size) / 2.0
    vertices[2].color.b = 1.0
    vertices[2].color.a = 1.0

    c.SDL_RenderGeometry(renderer, null, raw(addr(vertices[0])), 3, null, 0)

    vertices[0].position.x = 10.0
    vertices[0].position.y = 10.0
    vertices[0].color.r = 1.0
    vertices[0].color.g = 1.0
    vertices[0].color.b = 1.0
    vertices[0].color.a = 1.0
    vertices[0].tex_coord.x = 0.0
    vertices[0].tex_coord.y = 0.0

    vertices[1].position.x = 150.0
    vertices[1].position.y = 10.0
    vertices[1].color.r = 1.0
    vertices[1].color.g = 1.0
    vertices[1].color.b = 1.0
    vertices[1].color.a = 1.0
    vertices[1].tex_coord.x = 1.0
    vertices[1].tex_coord.y = 0.0

    vertices[2].position.x = 10.0
    vertices[2].position.y = 150.0
    vertices[2].color.r = 1.0
    vertices[2].color.g = 1.0
    vertices[2].color.b = 1.0
    vertices[2].color.a = 1.0
    vertices[2].tex_coord.x = 0.0
    vertices[2].tex_coord.y = 1.0

    c.SDL_RenderGeometry(renderer, texture, raw(addr(vertices[0])), 3, null, 0)

    for index in range(0, 3):
        vertices[index].position.x += 450.0

    vertices[3].position.x = 600.0
    vertices[3].position.y = 150.0
    vertices[3].color.r = 1.0
    vertices[3].color.g = 1.0
    vertices[3].color.b = 1.0
    vertices[3].color.a = 1.0
    vertices[3].tex_coord.x = 1.0
    vertices[3].tex_coord.y = 1.0

    c.SDL_RenderGeometry(renderer, texture, raw(addr(vertices[0])), 4, raw(addr(indices[0])), 6)
    c.SDL_RenderPresent(renderer)

def app_main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    c.SDL_SetAppMetadata(c"Example Renderer Geometry", c"1.0", c"com.example.renderer-geometry")

    if not c.SDL_Init(c.SDL_INIT_VIDEO):
        return 1
    defer c.SDL_Quit()

    if not c.SDL_CreateWindowAndRenderer(window_title, window_width, window_height, window_flags, raw(addr(window)), raw(addr(renderer))):
        return 1
    defer c.SDL_DestroyRenderer(renderer)
    defer c.SDL_DestroyWindow(window)

    if not c.SDL_SetRenderLogicalPresentation(renderer, window_width, window_height, presentation_mode):
        return 1

    let surface = c.SDL_LoadPNG(sample_texture_path)
    if surface == null:
        return 1
    defer c.SDL_DestroySurface(surface)

    unsafe:
        texture_width = deref(surface).w
        texture_height = deref(surface).h

    let created_texture = c.SDL_CreateTextureFromSurface(renderer, surface)
    if created_texture == null:
        return 1
    texture = created_texture
    defer c.SDL_DestroyTexture(texture)

    while pump_events():
        render_frame()

    return 0

def main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    return c.SDL_RunApp(argc, argv, app_main, null)

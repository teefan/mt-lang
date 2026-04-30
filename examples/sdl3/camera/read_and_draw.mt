module examples.sdl3.camera.read_and_draw

import std.c.sdl3 as c

const window_width: i32 = 640
const window_height: i32 = 480
const window_title: cstr = c"examples/camera/read-and-draw"
const window_flags: u64 = u64<-c.SDL_WINDOW_RESIZABLE
const presentation_mode: c.SDL_RendererLogicalPresentation = c.SDL_RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX

var window: ptr[c.SDL_Window]
var renderer: ptr[c.SDL_Renderer]
var camera: ptr[c.SDL_Camera]? = null
var texture: ptr[c.SDL_Texture]? = null
var exit_status: i32 = 0

def pump_events() -> bool:
    var event = c.SDL_Event(type = 0)

    while c.SDL_PollEvent(raw(addr(event))):
        if event.quit.type == c.SDL_EventType.SDL_EVENT_QUIT:
            return false
        else:
            if event.cdevice.type == c.SDL_EventType.SDL_EVENT_CAMERA_DEVICE_APPROVED:
                c.SDL_Log(c"Camera use approved by user!")
            else:
                if event.cdevice.type == c.SDL_EventType.SDL_EVENT_CAMERA_DEVICE_DENIED:
                    c.SDL_Log(c"Camera use denied by user!")
                    exit_status = 1
                    return false

    return true

def render_frame() -> void:
    var timestamp_ns: c.Uint64 = 0

    if camera != null:
        let frame = c.SDL_AcquireCameraFrame(camera, raw(addr(timestamp_ns)))

        if frame != null:
            if texture == null:
                unsafe:
                    c.SDL_SetWindowSize(window, deref(frame).w, deref(frame).h)
                    c.SDL_SetRenderLogicalPresentation(renderer, deref(frame).w, deref(frame).h, presentation_mode)

                    let created_texture = c.SDL_CreateTexture(
                        renderer,
                        deref(frame).format,
                        c.SDL_TextureAccess.SDL_TEXTUREACCESS_STREAMING,
                        deref(frame).w,
                        deref(frame).h,
                    )

                    if created_texture != null:
                        texture = created_texture

            let frame_texture = texture
            if frame_texture != null:
                unsafe:
                    c.SDL_UpdateTexture(frame_texture, null, deref(frame).pixels, deref(frame).pitch)

            c.SDL_ReleaseCameraFrame(camera, frame)

    c.SDL_SetRenderDrawColor(renderer, 0x99, 0x99, 0x99, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderClear(renderer)

    if texture != null:
        c.SDL_RenderTexture(renderer, texture, null, null)

    c.SDL_RenderPresent(renderer)

def app_main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    var devices: ptr[c.SDL_CameraID]? = null
    var device_count: i32 = 0

    c.SDL_SetAppMetadata(c"Example Camera Read and Draw", c"1.0", c"com.example.camera-read-and-draw")

    if not c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_CAMERA):
        return 1
    defer c.SDL_Quit()

    if not c.SDL_CreateWindowAndRenderer(window_title, window_width, window_height, window_flags, raw(addr(window)), raw(addr(renderer))):
        return 1
    defer c.SDL_DestroyRenderer(renderer)
    defer c.SDL_DestroyWindow(window)
    defer:
        if camera != null:
            c.SDL_CloseCamera(camera)

        if texture != null:
            c.SDL_DestroyTexture(texture)

    devices = c.SDL_GetCameras(raw(addr(device_count)))
    if devices == null:
        return 1

    if device_count == 0:
        unsafe:
            c.SDL_free(ptr[void]<-devices)
        return 1

    unsafe:
        let opened_camera = c.SDL_OpenCamera(deref(devices), null)
        c.SDL_free(ptr[void]<-devices)

        if opened_camera == null:
            return 1

        camera = opened_camera

    exit_status = 0

    while pump_events():
        render_frame()

    return exit_status

def main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    return c.SDL_RunApp(argc, argv, app_main, null)

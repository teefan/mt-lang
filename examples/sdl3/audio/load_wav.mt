module examples.sdl3.audio.load_wav

import std.c.sdl3 as c

const window_width: i32 = 640
const window_height: i32 = 480
const window_title: cstr = c"examples/audio/load-wav"
const window_flags: u64 = u64<-c.SDL_WINDOW_RESIZABLE
const presentation_mode: c.SDL_RendererLogicalPresentation = c.SDL_RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX
const default_playback_device: u32 = u32<-0xFFFFFFFF
const sample_wav_path: cstr = c"../resources/sample.wav"

var window: ptr[c.SDL_Window]
var renderer: ptr[c.SDL_Renderer]
var stream: ptr[c.SDL_AudioStream]? = null
var audio_device: c.SDL_AudioDeviceID = 0
var wav_data: ptr[c.Uint8]
var wav_data_len: c.Uint32 = 0

def pump_events() -> bool:
    var event = c.SDL_Event(type = 0)

    while c.SDL_PollEvent(ptr_of(ref_of(event))):
        if event.quit.type == c.SDL_EventType.SDL_EVENT_QUIT:
            return false

    return true

def render_frame() -> void:
    let active_stream = stream

    if active_stream != null:
        if c.SDL_GetAudioStreamQueued(active_stream) < i32<-wav_data_len:
            c.SDL_PutAudioStreamData(active_stream, wav_data, i32<-wav_data_len)

    c.SDL_RenderClear(renderer)
    c.SDL_RenderPresent(renderer)

def app_main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    var spec = zero[c.SDL_AudioSpec]()

    c.SDL_SetAppMetadata(c"Example Audio Load Wave", c"1.0", c"com.example.audio-load-wav")

    if not c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_AUDIO):
        return 1
    defer c.SDL_Quit()
    defer:
        if stream != null:
            c.SDL_DestroyAudioStream(stream)
        c.SDL_free(wav_data)

    if not c.SDL_CreateWindowAndRenderer(window_title, window_width, window_height, window_flags, ptr_of(ref_of(window)), ptr_of(ref_of(renderer))):
        return 1
    defer c.SDL_DestroyRenderer(renderer)
    defer c.SDL_DestroyWindow(window)

    if not c.SDL_SetRenderLogicalPresentation(renderer, window_width, window_height, presentation_mode):
        return 1

    if not c.SDL_LoadWAV(sample_wav_path, ptr_of(ref_of(spec)), ptr_of(ref_of(wav_data)), ptr_of(ref_of(wav_data_len))):
        return 1

    audio_device = c.SDL_OpenAudioDevice(default_playback_device, null)
    if audio_device == 0:
        return 1
    defer c.SDL_CloseAudioDevice(audio_device)

    let created_stream = c.SDL_CreateAudioStream(ptr_of(ref_of(spec)), null)
    if created_stream == null:
        return 1
    if not c.SDL_BindAudioStream(audio_device, created_stream):
        c.SDL_DestroyAudioStream(created_stream)
        return 1

    stream = created_stream

    while pump_events():
        render_frame()

    return 0

def main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    return c.SDL_RunApp(argc, argv, app_main, null)

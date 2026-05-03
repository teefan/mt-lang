module examples.sdl3.audio.simple_playback

import std.c.sdl3 as c

const window_width: i32 = 640
const window_height: i32 = 480
const window_title: cstr = c"examples/audio/simple-playback"
const window_flags: u64 = u64<-c.SDL_WINDOW_RESIZABLE
const presentation_mode: c.SDL_RendererLogicalPresentation = c.SDL_RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX
const default_playback_device: u32 = u32<-0xFFFFFFFF
const audio_sample_rate: i32 = 8000
const tone_frequency: i32 = 440
const minimum_audio: i32 = (audio_sample_rate * i32<-sizeof(f32)) / 2
const sample_chunk_size: i32 = 512

var window: ptr[c.SDL_Window]
var renderer: ptr[c.SDL_Renderer]
var stream: ptr[c.SDL_AudioStream]? = null
var audio_device: c.SDL_AudioDeviceID = 0
var current_sine_sample: i32 = 0


def pump_events() -> bool:
    var event = zero[c.SDL_Event]()

    while c.SDL_PollEvent(ptr_of(ref_of(event))):
        if event.type_ == u32<-c.SDL_EventType.SDL_EVENT_QUIT:
            return false

    return true


def render_frame() -> void:
    let active_stream = stream
    if active_stream != null:
        if c.SDL_GetAudioStreamQueued(active_stream) < minimum_audio:
            var samples = zero[array[f32, 512]]()

            for index in range(0, sample_chunk_size):
                let phase = f32<-(current_sine_sample * tone_frequency) / f32<-audio_sample_rate
                samples[index] = c.SDL_sinf(phase * 2.0 * c.SDL_PI_F)
                current_sine_sample += 1

            current_sine_sample %= audio_sample_rate
            c.SDL_PutAudioStreamData(active_stream, ptr_of(ref_of(samples[0])), sample_chunk_size * i32<-sizeof(f32))

    c.SDL_RenderClear(renderer)
    c.SDL_RenderPresent(renderer)


def app_main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    var spec = zero[c.SDL_AudioSpec]()

    c.SDL_SetAppMetadata(c"Example Audio Simple Playback", c"1.0", c"com.example.audio-simple-playback")

    if not c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_AUDIO):
        return 1
    defer c.SDL_Quit()
    defer:
        if stream != null:
            c.SDL_DestroyAudioStream(stream)

    if not c.SDL_CreateWindowAndRenderer(window_title, window_width, window_height, window_flags, ptr_of(ref_of(window)), ptr_of(ref_of(renderer))):
        return 1
    defer c.SDL_DestroyRenderer(renderer)
    defer c.SDL_DestroyWindow(window)

    if not c.SDL_SetRenderLogicalPresentation(renderer, window_width, window_height, presentation_mode):
        return 1

    audio_device = c.SDL_OpenAudioDevice(default_playback_device, null)
    if audio_device == 0:
        return 1
    defer c.SDL_CloseAudioDevice(audio_device)

    spec.channels = 1
    spec.format = c.SDL_AudioFormat.SDL_AUDIO_F32
    spec.freq = audio_sample_rate

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

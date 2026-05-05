module examples.sdl3.audio.simple_playback_callback

import std.c.sdl3 as c

const window_width: int = 640
const window_height: int = 480
const window_title: cstr = c"examples/audio/simple-playback-callback"
const window_flags: ulong = ulong<-c.SDL_WINDOW_RESIZABLE
const presentation_mode: c.SDL_RendererLogicalPresentation = c.SDL_RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX
const default_playback_device: uint = uint<-0xFFFFFFFF
const audio_sample_rate: int = 8000
const tone_frequency: int = 440
const sample_chunk_size: int = 128

var window: ptr[c.SDL_Window]
var renderer: ptr[c.SDL_Renderer]
var stream: ptr[c.SDL_AudioStream]? = null
var current_sine_sample: int = 0


def min_int(lhs: int, rhs: int) -> int:
    if lhs < rhs:
        return lhs

    return rhs


def feed_audio_stream_more(userdata: ptr[void], astream: ptr[c.SDL_AudioStream], additional_amount: int, total_amount: int) -> void:
    var remaining_samples = additional_amount / int<-size_of(float)

    while remaining_samples > 0:
        var samples = zero[array[float, 128]]
        let total = min_int(remaining_samples, sample_chunk_size)

        for index in 0..total:
            let phase = float<-(current_sine_sample * tone_frequency) / float<-audio_sample_rate
            samples[index] = c.SDL_sinf(phase * 2.0 * c.SDL_PI_F)
            current_sine_sample += 1

        current_sine_sample %= audio_sample_rate
        c.SDL_PutAudioStreamData(astream, ptr_of(samples[0]), total * int<-size_of(float))
        remaining_samples -= total


def pump_events() -> bool:
    var event = zero[c.SDL_Event]

    while c.SDL_PollEvent(ptr_of(event)):
        if event.type_ == uint<-c.SDL_EventType.SDL_EVENT_QUIT:
            return false

    return true


def render_frame() -> void:
    c.SDL_RenderClear(renderer)
    c.SDL_RenderPresent(renderer)


def app_main(argc: int, argv: ptr[ptr[char]]) -> int:
    var spec = zero[c.SDL_AudioSpec]

    c.SDL_SetAppMetadata(c"Example Simple Audio Playback Callback", c"1.0", c"com.example.audio-simple-playback-callback")

    if not c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_AUDIO):
        return 1
    defer c.SDL_Quit()

    if not c.SDL_CreateWindowAndRenderer(window_title, window_width, window_height, window_flags, ptr_of(window), ptr_of(renderer)):
        return 1
    defer c.SDL_DestroyRenderer(renderer)
    defer c.SDL_DestroyWindow(window)
    defer:
        if stream != null:
            c.SDL_DestroyAudioStream(stream)

    c.SDL_SetRenderLogicalPresentation(renderer, window_width, window_height, presentation_mode)

    spec.channels = 1
    spec.format = c.SDL_AudioFormat.SDL_AUDIO_F32
    spec.freq = audio_sample_rate

    let opened_stream = c.SDL_OpenAudioDeviceStream(default_playback_device, ptr_of(spec), feed_audio_stream_more, null)
    if opened_stream == null:
        return 1

    stream = opened_stream
    c.SDL_ResumeAudioStreamDevice(opened_stream)

    while pump_events():
        render_frame()

    return 0


def main(argc: int, argv: ptr[ptr[char]]) -> int:
    return c.SDL_RunApp(argc, argv, app_main, null)

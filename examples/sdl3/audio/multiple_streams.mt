module examples.sdl3.audio.multiple_streams

import std.c.sdl3 as c

const window_width: i32 = 640
const window_height: i32 = 480
const window_title: cstr = c"examples/audio/multiple-streams"
const window_flags: u64 = u64<-c.SDL_WINDOW_RESIZABLE
const presentation_mode: c.SDL_RendererLogicalPresentation = c.SDL_RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX
const default_playback_device: u32 = u32<-0xFFFFFFFF
const sample_wav_path: cstr = c"../resources/sample.wav"
const sword_wav_path: cstr = c"../resources/sword.wav"
const sound_count: i32 = 2

struct Sound:
    wav_data: ptr[c.Uint8]?
    wav_data_len: c.Uint32
    stream: ptr[c.SDL_AudioStream]?

var window: ptr[c.SDL_Window]
var renderer: ptr[c.SDL_Renderer]
var audio_device: c.SDL_AudioDeviceID = 0
var sounds: array[Sound, 2] = zero[array[Sound, 2]]()


def init_sound(path: cstr, sound_index: i32) -> bool:
    var spec = zero[c.SDL_AudioSpec]()
    var wav_data: ptr[c.Uint8]
    var wav_data_len: c.Uint32 = 0

    if not c.SDL_LoadWAV(path, ptr_of(ref_of(spec)), ptr_of(ref_of(wav_data)), ptr_of(ref_of(wav_data_len))):
        return false

    let created_stream = c.SDL_CreateAudioStream(ptr_of(ref_of(spec)), null)
    if created_stream == null:
        c.SDL_free(wav_data)
        return false

    if not c.SDL_BindAudioStream(audio_device, created_stream):
        c.SDL_DestroyAudioStream(created_stream)
        c.SDL_free(wav_data)
        return false

    sounds[sound_index].wav_data = wav_data
    sounds[sound_index].wav_data_len = wav_data_len
    sounds[sound_index].stream = created_stream
    return true


def pump_events() -> bool:
    var event = zero[c.SDL_Event]()

    while c.SDL_PollEvent(ptr_of(ref_of(event))):
        if event.type_ == u32<-c.SDL_EventType.SDL_EVENT_QUIT:
            return false

    return true


def render_frame() -> void:
    for index in range(0, sound_count):
        let stream = sounds[index].stream
        if stream != null:
            let wav_data = sounds[index].wav_data
            if wav_data != null:
                if c.SDL_GetAudioStreamQueued(stream) < i32<-sounds[index].wav_data_len:
                    c.SDL_PutAudioStreamData(stream, wav_data, i32<-sounds[index].wav_data_len)

    c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderClear(renderer)
    c.SDL_RenderPresent(renderer)


def cleanup_sound(sound_index: i32) -> void:
    let stream = sounds[sound_index].stream
    if stream != null:
        c.SDL_DestroyAudioStream(stream)
        sounds[sound_index].stream = null

    let wav_data = sounds[sound_index].wav_data
    if wav_data != null:
        c.SDL_free(wav_data)
        sounds[sound_index].wav_data = null

    sounds[sound_index].wav_data_len = 0


def app_main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    c.SDL_SetAppMetadata(c"Example Audio Multiple Streams", c"1.0", c"com.example.audio-multiple-streams")

    if not c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_AUDIO):
        return 1
    defer c.SDL_Quit()
    defer:
        for index in range(0, sound_count):
            cleanup_sound(index)

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

    if not init_sound(sample_wav_path, 0):
        return 1
    if not init_sound(sword_wav_path, 1):
        return 1

    while pump_events():
        render_frame()

    return 0


def main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    return c.SDL_RunApp(argc, argv, app_main, null)

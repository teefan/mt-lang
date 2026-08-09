import std.sdl3 as sdl
import std.sdl3.runtime as runtime

const WINDOW_WIDTH: int = 640
const WINDOW_HEIGHT: int = 480


struct Sound:
    wav_data: ptr[ubyte]
    wav_data_len: uint
    stream: ptr[sdl.AudioStream]


function init_sound(audio_device: uint, fname: str) -> Sound:
    var spec: sdl.AudioSpec
    var wav_data: ptr[ubyte]
    var wav_data_len: uint = 0
    var path = runtime.asset_path(fname)
    if not sdl.load_wav(path.as_str(), ptr_of(spec), ptr_of(wav_data), ptr_of(wav_data_len)):
        fatal(f"could not load .wav file: #{sdl.get_error()}")
    defer: path.release()

    let created = sdl.create_audio_stream(const_ptr_of(spec), null) else:
        fatal(f"could not create audio stream: #{sdl.get_error()}")
    if not sdl.bind_audio_stream(audio_device, created):
        fatal(f"failed to bind stream to device: #{sdl.get_error()}")
    return Sound(wav_data = wav_data, wav_data_len = wav_data_len, stream = created)


function main() -> int:
    if not sdl.init(sdl.INIT_VIDEO | sdl.INIT_AUDIO):
        fatal(f"could not initialize SDL: #{sdl.get_error()}")
    defer: sdl.quit()

    var window: sdl.Window = zero[sdl.Window]
    var renderer: sdl.Renderer = zero[sdl.Renderer]
    if not sdl.create_window_and_renderer(
        "examples/audio/multiple-streams",
        WINDOW_WIDTH,
        WINDOW_HEIGHT,
        sdl.WINDOW_RESIZABLE,
        window,
        renderer
    ):
        fatal(f"could not create window/renderer: #{sdl.get_error()}")
    defer: sdl.destroy_renderer(renderer)
    defer: sdl.destroy_window(window)

    let audio_device = sdl.open_audio_device(0xFFFFFFFF, null)
    if audio_device == 0:
        fatal(f"could not open audio device: #{sdl.get_error()}")
    defer: sdl.close_audio_device(audio_device)

    var sounds: array[Sound, 2]
    sounds[0] = init_sound(audio_device, "sample.wav")
    sounds[1] = init_sound(audio_device, "sword.wav")
    defer:
        for i in 0..2:
            sdl.destroy_audio_stream(sounds[i].stream)
            sdl.free(unsafe: ptr[void]<-sounds[i].wav_data)

    var running = true
    while running:
        var ev: sdl.Event = zero[sdl.Event]
        while sdl.poll_event(ev):
            if ev.type == int<-sdl.EventType.SDL_EVENT_QUIT:
                running = false

        for i in 0..2:
            if sdl.get_audio_stream_queued(sounds[i].stream) < int<-sounds[i].wav_data_len:
                sdl.put_audio_stream_data(
                    sounds[i].stream,
                    unsafe: const_ptr[void]<-sounds[i].wav_data,
                    int<-sounds[i].wav_data_len
                )

        sdl.set_render_draw_color(renderer, 0, 0, 0, 255)
        sdl.render_clear(renderer)
        sdl.render_present(renderer)

    return 0

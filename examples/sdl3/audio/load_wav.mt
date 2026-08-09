import std.sdl3 as sdl
import std.sdl3.runtime as runtime

const WINDOW_WIDTH: int = 640
const WINDOW_HEIGHT: int = 480


function no_op_audio_callback(
    _userdata: ptr[void],
    _stream: ptr[sdl.AudioStream],
    _additional: int,
    _total: int
) -> void:
    pass


function main() -> int:
    if not sdl.init(sdl.INIT_VIDEO | sdl.INIT_AUDIO):
        fatal(f"could not initialize SDL: #{sdl.get_error()}")
    defer: sdl.quit()

    var window: sdl.Window = zero[sdl.Window]
    var renderer: sdl.Renderer = zero[sdl.Renderer]
    if not sdl.create_window_and_renderer(
        "examples/audio/load-wav",
        WINDOW_WIDTH,
        WINDOW_HEIGHT,
        sdl.WINDOW_RESIZABLE,
        window,
        renderer
    ):
        fatal(f"could not create window/renderer: #{sdl.get_error()}")
    defer: sdl.destroy_renderer(renderer)
    defer: sdl.destroy_window(window)

    var spec: sdl.AudioSpec
    var wav_data: ptr[ubyte]
    var wav_data_len: uint = 0
    var path = runtime.asset_path("sample.wav")
    if not sdl.load_wav(path.as_str(), ptr_of(spec), ptr_of(wav_data), ptr_of(wav_data_len)):
        fatal(f"could not load sample.wav: #{sdl.get_error()}")
    defer: path.release()
    defer: sdl.free(unsafe: ptr[void]<-wav_data)

    let stream = sdl.open_audio_device_stream(0xFFFFFFFF, const_ptr_of(spec), no_op_audio_callback, null) else:
        fatal(f"could not create audio stream: #{sdl.get_error()}")
    defer: sdl.destroy_audio_stream(stream)
    sdl.resume_audio_stream_device(stream)

    var running = true
    while running:
        var ev: sdl.Event = zero[sdl.Event]
        while sdl.poll_event(ev):
            if ev.type == int<-sdl.EventType.SDL_EVENT_QUIT:
                running = false

        if sdl.get_audio_stream_queued(stream) < int<-wav_data_len:
            sdl.put_audio_stream_data(stream, unsafe: const_ptr[void]<-wav_data, int<-wav_data_len)

        sdl.render_clear(renderer)
        sdl.render_present(renderer)

    return 0

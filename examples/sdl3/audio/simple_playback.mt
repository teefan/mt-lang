import std.sdl3 as sdl

const WINDOW_WIDTH: int = 640
const WINDOW_HEIGHT: int = 480
const SAMPLE_RATE: int = 8000


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
        "examples/audio/simple-playback",
        WINDOW_WIDTH,
        WINDOW_HEIGHT,
        sdl.WINDOW_RESIZABLE,
        window,
        renderer
    ):
        fatal(f"could not create window/renderer: #{sdl.get_error()}")
    defer: sdl.destroy_renderer(renderer)
    defer: sdl.destroy_window(window)

    let spec = sdl.AudioSpec(format = sdl.AudioFormat.SDL_AUDIO_F32, channels = 1, freq = SAMPLE_RATE)
    let stream = sdl.open_audio_device_stream(0xFFFFFFFF, const_ptr_of(spec), no_op_audio_callback, null) else:
        fatal(f"could not create audio stream: #{sdl.get_error()}")
    defer: sdl.destroy_audio_stream(stream)
    sdl.resume_audio_stream_device(stream)

    let minimum_audio = (SAMPLE_RATE * 4) / 2
    var current_sine_sample: int = 0

    var running = true
    while running:
        var ev: sdl.Event = zero[sdl.Event]
        while sdl.poll_event(ev):
            if ev.type == int<-sdl.EventType.SDL_EVENT_QUIT:
                running = false

        if sdl.get_audio_stream_queued(stream) < minimum_audio:
            var samples: array[float, 512]
            for i in 0..512:
                let phase = current_sine_sample * 440 / 8000.0
                samples[i] = sdl.sinf(phase * 2 * sdl.PI_F)
                current_sine_sample += 1
            current_sine_sample %= 8000
            sdl.put_audio_stream_data(stream, unsafe: const_ptr[void]<-const_ptr_of(samples[0]), 512 * 4)

        sdl.render_clear(renderer)
        sdl.render_present(renderer)

    return 0

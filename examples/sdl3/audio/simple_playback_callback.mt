import std.sdl3 as sdl

const WINDOW_WIDTH: int = 640
const WINDOW_HEIGHT: int = 480
const SAMPLE_RATE: int = 8000

var current_sine_sample: int = 0


function feed_the_audio_stream_more(
    _userdata: ptr[void],
    astream: ptr[sdl.AudioStream],
    additional_amount: int,
    _total_amount: int
) -> void:
    var additional = additional_amount / 4
    while additional > 0:
        var samples: array[float, 128]
        let total = if additional < 128: additional else: 128
        for i in 0..total:
            let phase = current_sine_sample * 440 / 8000.0
            samples[i] = sdl.sinf(phase * 2 * sdl.PI_F)
            current_sine_sample += 1
        current_sine_sample %= 8000
        sdl.put_audio_stream_data(astream, unsafe: const_ptr[void]<-const_ptr_of(samples[0]), total * 4)
        additional -= total


function main() -> int:
    if not sdl.init(sdl.INIT_VIDEO | sdl.INIT_AUDIO):
        fatal(f"could not initialize SDL: #{sdl.get_error()}")
    defer: sdl.quit()

    var window: sdl.Window = zero[sdl.Window]
    var renderer: sdl.Renderer = zero[sdl.Renderer]
    if not sdl.create_window_and_renderer(
        "examples/audio/simple-playback-callback",
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
    let stream = sdl.open_audio_device_stream(0xFFFFFFFF, const_ptr_of(spec), feed_the_audio_stream_more, null) else:
        fatal(f"could not create audio stream: #{sdl.get_error()}")
    defer: sdl.destroy_audio_stream(stream)
    sdl.resume_audio_stream_device(stream)

    var running = true
    while running:
        var ev: sdl.Event = zero[sdl.Event]
        while sdl.poll_event(ev):
            if ev.type == int<-sdl.EventType.SDL_EVENT_QUIT:
                running = false

        sdl.render_clear(renderer)
        sdl.render_present(renderer)

    return 0

module examples.idiomatic.raylib.async_asset_loading

import std.bytes as bytes
import std.async as aio
import std.fs as fs
import std.libuv.runtime as rt
import std.mem.arena as arena
import std.raylib as rl

const screen_width: i32 = 960
const screen_height: i32 = 540
const logo_path: str = "../../raylib/resources/raylib_logo.png"
const sound_path: str = "../../raylib/resources/sound.wav"


def load_logo_bytes() -> bytes.Buffer:
    var scratch = arena.create(96)
    defer scratch.release()

    let loaded = fs.read_bytes(logo_path, ref_of(scratch))
    if not loaded.is_ok:
        panic("could not read raylib logo bytes")
    return loaded.value


def load_sound_bytes() -> bytes.Buffer:
    var scratch = arena.create(96)
    defer scratch.release()

    let loaded = fs.read_bytes(sound_path, ref_of(scratch))
    if not loaded.is_ok:
        panic("could not read raylib sound bytes")
    return loaded.value


def texture_from_png_bytes(data: bytes.Buffer) -> rl.Texture2D:
    var scratch = arena.create(16)
    defer scratch.release()

    let view = bytes.as_span(data)
    let image = rl.load_image_from_memory(scratch.to_cstr(".png"), view.data, i32<-view.len)
    if not rl.is_image_valid(image):
        panic("raylib could not decode png bytes")

    let texture = rl.load_texture_from_image(image)
    rl.unload_image(image)
    if not rl.is_texture_valid(texture):
        panic("raylib could not upload texture bytes")
    return texture


def sound_from_wav_bytes(data: bytes.Buffer) -> rl.Sound:
    var scratch = arena.create(16)
    defer scratch.release()

    let view = bytes.as_span(data)
    let wave = rl.load_wave_from_memory(scratch.to_cstr(".wav"), view.data, i32<-view.len)
    if not rl.is_wave_valid(wave):
        panic("raylib could not decode wav bytes")

    let sound = rl.load_sound_from_wave(wave)
    rl.unload_wave(wave)
    if not rl.is_sound_valid(sound):
        panic("raylib could not create sound")
    return sound


def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Async Asset Loading")
    defer rl.close_window()

    rl.init_audio_device()
    defer rl.close_audio_device()

    let loop_result = rt.create_loop()
    if not loop_result.is_ok:
        return 1
    var loop = loop_result.value

    let logo_task = aio.work_on(loop, load_logo_bytes)
    let sound_task = aio.work_on(loop, load_sound_bytes)

    var logo = zero[rl.Texture2D]
    var ping = zero[rl.Sound]
    var logo_loaded = false
    var sound_loaded = false
    var played_ready_sound = false

    defer:
        if logo_loaded:
            rl.unload_texture(logo)
        if sound_loaded:
            rl.unload_sound(ping)
        if rt.loop_release(ref_of(loop)) != 0:
            panic("libuv loop release failed")

    rl.set_target_fps(60)

    while not rl.window_should_close():
        aio.pump(loop)

        if not logo_loaded and aio.ready(logo_task):
            var logo_bytes = aio.finish(logo_task)
            logo = texture_from_png_bytes(logo_bytes)
            logo_loaded = true
            bytes.release(ref_of(logo_bytes))

        if not sound_loaded and aio.ready(sound_task):
            var sound_bytes = aio.finish(sound_task)
            ping = sound_from_wav_bytes(sound_bytes)
            sound_loaded = true
            bytes.release(ref_of(sound_bytes))

        if logo_loaded and sound_loaded and not played_ready_sound:
            rl.play_sound(ping)
            played_ready_sound = true

        if sound_loaded and rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            rl.play_sound(ping)

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_text("ASYNC ASSET LOADING", 40, 36, 34, rl.BLACK)
        rl.draw_text("libuv workers read bytes off-thread while raylib uploads texture and audio on the main thread", 40, 76, 20, rl.DARKGRAY)

        rl.draw_rectangle(40, 122, 380, 28, if logo_loaded: rl.GREEN else: rl.LIGHTGRAY)
        rl.draw_rectangle_lines(40, 122, 380, 28, rl.DARKGRAY)
        rl.draw_text(if logo_loaded: "texture ready" else: "texture bytes loading on worker", 52, 128, 14, rl.BLACK)

        rl.draw_rectangle(40, 164, 380, 28, if sound_loaded: rl.SKYBLUE else: rl.LIGHTGRAY)
        rl.draw_rectangle_lines(40, 164, 380, 28, rl.DARKGRAY)
        rl.draw_text(if sound_loaded: "sound ready" else: "sound bytes loading on worker", 52, 170, 14, rl.BLACK)

        if logo_loaded:
            rl.draw_texture(logo, screen_width / 2 - logo.width / 2, 220, rl.WHITE)
        else:
            rl.draw_rectangle(screen_width / 2 - 130, 220, 260, 180, rl.fade(rl.LIGHTGRAY, 0.5))
            rl.draw_rectangle_lines(screen_width / 2 - 130, 220, 260, 180, rl.GRAY)
            rl.draw_text("waiting for texture upload", screen_width / 2 - 96, 300, 20, rl.GRAY)

        if logo_loaded and sound_loaded:
            rl.draw_text("Press SPACE to replay the asynchronously loaded sound.", 40, 470, 20, rl.DARKBLUE)
        else:
            rl.draw_text("Assets start loading together as soon as the window opens.", 40, 470, 20, rl.DARKGRAY)

    return 0

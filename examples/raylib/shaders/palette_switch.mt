import std.raylib as rl
import std.raylib.runtime as rl_runtime


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330
const MAX_PALETTES: int = 3
const COLORS_PER_PALETTE: int = 8

const PALETTES: array[array[array[int, 3], COLORS_PER_PALETTE], MAX_PALETTES] = array[array[array[int, 3], COLORS_PER_PALETTE], MAX_PALETTES](
    array[array[int, 3], COLORS_PER_PALETTE](
        array[int, 3](0, 0, 0),
        array[int, 3](255, 0, 0),
        array[int, 3](0, 255, 0),
        array[int, 3](0, 0, 255),
        array[int, 3](0, 255, 255),
        array[int, 3](255, 0, 255),
        array[int, 3](255, 255, 0),
        array[int, 3](255, 255, 255),
    ),
    array[array[int, 3], COLORS_PER_PALETTE](
        array[int, 3](4, 12, 6),
        array[int, 3](17, 35, 24),
        array[int, 3](30, 58, 41),
        array[int, 3](48, 93, 66),
        array[int, 3](77, 128, 97),
        array[int, 3](137, 162, 87),
        array[int, 3](190, 220, 127),
        array[int, 3](238, 255, 204),
    ),
    array[array[int, 3], COLORS_PER_PALETTE](
        array[int, 3](21, 25, 26),
        array[int, 3](138, 76, 88),
        array[int, 3](217, 98, 117),
        array[int, 3](230, 184, 193),
        array[int, 3](69, 107, 115),
        array[int, 3](75, 151, 166),
        array[int, 3](165, 189, 194),
        array[int, 3](255, 245, 247),
    ),
)

const PALETTE_TEXT: array[str, MAX_PALETTES] = array[str, MAX_PALETTES](
    "3-BIT RGB",
    "AMMO-8 (GameBoy-like)",
    "RKBV (2-strip film)",
)


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - palette switch")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let shader = rl.load_shader(null, rl.text_format("shaders/glsl%i/palette_switch.fs", GLSL_VERSION))
    defer rl.unload_shader(shader)

    let palette_location = rl.get_shader_location(shader, "palette")
    var current_palette = 0
    let line_height = SCREEN_HEIGHT / COLORS_PER_PALETTE

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT):
            current_palette += 1
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT):
            current_palette -= 1

        if current_palette >= MAX_PALETTES:
            current_palette = 0
        else if current_palette < 0:
            current_palette = MAX_PALETTES - 1

        var active_palette = PALETTES[current_palette]
        rl.set_shader_value_v(
            shader,
            palette_location,
            ptr_of(active_palette[0]),
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_IVEC3,
            COLORS_PER_PALETTE,
        )

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_shader_mode(shader)
        var index = 0
        while index < COLORS_PER_PALETTE:
            rl.draw_rectangle(
                0,
                line_height * index,
                rl.get_screen_width(),
                line_height,
                rl.Color(r = ubyte<-index, g = ubyte<-index, b = ubyte<-index, a = 255),
            )
            index += 1
        rl.end_shader_mode()

        rl.draw_text("< >", 10, 10, 30, rl.DARKBLUE)
        rl.draw_text("CURRENT PALETTE:", 60, 15, 20, rl.RAYWHITE)
        rl.draw_text(PALETTE_TEXT[current_palette], 300, 15, 20, rl.RED)
        rl.draw_fps(700, 15)
        rl.end_drawing()

    return 0

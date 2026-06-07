import std.raygui as gui
import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.str as text

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330
const MAX_TEXTURES: int = 4


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - color correction")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let textures: array[rl.Texture2D, MAX_TEXTURES] = array[rl.Texture2D, MAX_TEXTURES](
        rl.load_texture("parrots.png"),
        rl.load_texture("cat.png"),
        rl.load_texture("mandrill.png"),
        rl.load_texture("fudesumi.png")
    )
    defer:
        var index = 0
        while index < MAX_TEXTURES:
            rl.unload_texture(textures[index])
            index += 1

    let shader = rl.load_shader(null, rl.text_format("shaders/glsl%i/color_correction.fs", GLSL_VERSION))
    defer rl.unload_shader(shader)

    var image_index = 0
    var reset_button_clicked = false
    var contrast: float = 0.0
    var saturation: float = 0.0
    var brightness: float = 0.0

    let contrast_location = rl.get_shader_location(shader, "contrast")
    let saturation_location = rl.get_shader_location(shader, "saturation")
    let brightness_location = rl.get_shader_location(shader, "brightness")

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_ONE):
            image_index = 0
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_TWO):
            image_index = 1
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_THREE):
            image_index = 2
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_FOUR):
            image_index = 3

        if rl.is_key_pressed(rl.KeyboardKey.KEY_R) or reset_button_clicked:
            contrast = 0.0
            saturation = 0.0
            brightness = 0.0

        rl.set_shader_value(shader, contrast_location, contrast, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
        rl.set_shader_value(shader, saturation_location, saturation, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
        rl.set_shader_value(shader, brightness_location, brightness, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_shader_mode(shader)
        rl.draw_texture(
            textures[image_index],
            290 - textures[image_index].width / 2,
            rl.get_screen_height() / 2 - textures[image_index].height / 2,
            rl.WHITE
        )
        rl.end_shader_mode()

        rl.draw_line(580, 0, 580, rl.get_screen_height(), rl.Color(r = 218, g = 218, b = 218, a = 255))
        rl.draw_rectangle(
            580,
            0,
            rl.get_screen_width(),
            rl.get_screen_height(),
            rl.Color(r = 232, g = 232, b = 232, a = 255)
        )

        rl.draw_text("Color Correction", 585, 40, 20, rl.GRAY)
        rl.draw_text("Picture", 602, 75, 10, rl.GRAY)
        rl.draw_text("Press [1] - [4] to Change Picture", 600, 230, 8, rl.GRAY)
        rl.draw_text("Press [R] to Reset Values", 600, 250, 8, rl.GRAY)

        gui.toggle_group(rl.Rectangle(x = 645.0, y = 70.0, width = 20.0, height = 20.0), "1;2;3;4", image_index)
        gui.slider_bar(
            rl.Rectangle(x = 645.0, y = 100.0, width = 120.0, height = 20.0),
            "Contrast",
            text.cstr_as_str(rl.text_format("%.0f", contrast)),
            contrast,
            -100.0,
            100.0
        )
        gui.slider_bar(
            rl.Rectangle(x = 645.0, y = 130.0, width = 120.0, height = 20.0),
            "Saturation",
            text.cstr_as_str(rl.text_format("%.0f", saturation)),
            saturation,
            -100.0,
            100.0
        )
        gui.slider_bar(
            rl.Rectangle(x = 645.0, y = 160.0, width = 120.0, height = 20.0),
            "Brightness",
            text.cstr_as_str(rl.text_format("%.0f", brightness)),
            brightness,
            -100.0,
            100.0
        )
        reset_button_clicked = gui.button(rl.Rectangle(x = 645.0, y = 190.0, width = 40.0, height = 20.0), "Reset") != 0

        rl.draw_fps(710, 10)
        rl.end_drawing()

    return 0

module examples.raylib.shaders.shaders_color_correction

import std.c.raylib as rl
import std.c.raygui as gui

const screen_width: int = 800
const screen_height: int = 450
const glsl_version: int = 330
const max_textures: int = 4
const shader_path_format: cstr = c"../resources/shaders/glsl%i/color_correction.fs"
const contrast_format: cstr = c"%.0f"
const texture_path_one: cstr = c"../resources/parrots.png"
const texture_path_two: cstr = c"../resources/cat.png"
const texture_path_three: cstr = c"../resources/mandrill.png"
const texture_path_four: cstr = c"../resources/fudesumi.png"
const contrast_uniform_name: cstr = c"contrast"
const saturation_uniform_name: cstr = c"saturation"
const brightness_uniform_name: cstr = c"brightness"
const title_text: cstr = c"Color Correction"
const picture_text: cstr = c"Picture"
const change_picture_text: cstr = c"Press [1] - [4] to Change Picture"
const reset_text: cstr = c"Press [R] to Reset Values"
const toggle_group_text: cstr = c"1;2;3;4"
const contrast_text: cstr = c"Contrast"
const saturation_text: cstr = c"Saturation"
const brightness_text: cstr = c"Brightness"
const reset_button_text: cstr = c"Reset"
const window_title: cstr = c"raylib [shaders] example - color correction"


def main() -> int:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let textures = array[rl.Texture2D, max_textures](
        rl.LoadTexture(texture_path_one),
        rl.LoadTexture(texture_path_two),
        rl.LoadTexture(texture_path_three),
        rl.LoadTexture(texture_path_four),
    )

    var unload_index = 0
    defer:
        while unload_index < max_textures:
            rl.UnloadTexture(textures[unload_index])
            unload_index += 1

    let shader = rl.LoadShader(zero[cstr?], rl.TextFormat(shader_path_format, glsl_version))
    defer rl.UnloadShader(shader)

    let contrast_location = rl.GetShaderLocation(shader, contrast_uniform_name)
    let saturation_location = rl.GetShaderLocation(shader, saturation_uniform_name)
    let brightness_location = rl.GetShaderLocation(shader, brightness_uniform_name)

    var image_index = 0
    var reset_button_clicked = 0
    var contrast: float = 0.0
    var saturation: float = 0.0
    var brightness: float = 0.0

    rl.SetShaderValue(shader, contrast_location, ptr_of(contrast), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
    rl.SetShaderValue(shader, saturation_location, ptr_of(saturation), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
    rl.SetShaderValue(shader, brightness_location, ptr_of(brightness), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_ONE):
            image_index = 0
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_TWO):
            image_index = 1
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_THREE):
            image_index = 2
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_FOUR):
            image_index = 3

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_R) or reset_button_clicked != 0:
            contrast = 0.0
            saturation = 0.0
            brightness = 0.0

        rl.SetShaderValue(shader, contrast_location, ptr_of(contrast), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
        rl.SetShaderValue(shader, saturation_location, ptr_of(saturation), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
        rl.SetShaderValue(shader, brightness_location, ptr_of(brightness), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

        let selected_texture = textures[image_index]

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginShaderMode(shader)
        rl.DrawTexture(selected_texture, 580 / 2 - selected_texture.width / 2, rl.GetScreenHeight() / 2 - selected_texture.height / 2, rl.WHITE)
        rl.EndShaderMode()

        rl.DrawLine(580, 0, 580, rl.GetScreenHeight(), rl.Color(r = 218, g = 218, b = 218, a = 255))
        rl.DrawRectangle(580, 0, rl.GetScreenWidth(), rl.GetScreenHeight(), rl.Color(r = 232, g = 232, b = 232, a = 255))

        rl.DrawText(title_text, 585, 40, 20, rl.GRAY)
        rl.DrawText(picture_text, 602, 75, 10, rl.GRAY)
        rl.DrawText(change_picture_text, 600, 230, 8, rl.GRAY)
        rl.DrawText(reset_text, 600, 250, 8, rl.GRAY)

        gui.GuiToggleGroup(gui.Rectangle(x = 645.0, y = 70.0, width = 20.0, height = 20.0), toggle_group_text, ptr_of(image_index))

        gui.GuiSliderBar(
            gui.Rectangle(x = 645.0, y = 100.0, width = 120.0, height = 20.0),
            contrast_text,
            rl.TextFormat(contrast_format, contrast),
            ptr_of(contrast),
            -100.0,
            100.0,
        )
        gui.GuiSliderBar(
            gui.Rectangle(x = 645.0, y = 130.0, width = 120.0, height = 20.0),
            saturation_text,
            rl.TextFormat(contrast_format, saturation),
            ptr_of(saturation),
            -100.0,
            100.0,
        )
        gui.GuiSliderBar(
            gui.Rectangle(x = 645.0, y = 160.0, width = 120.0, height = 20.0),
            brightness_text,
            rl.TextFormat(contrast_format, brightness),
            ptr_of(brightness),
            -100.0,
            100.0,
        )

        reset_button_clicked = gui.GuiButton(gui.Rectangle(x = 645.0, y = 190.0, width = 40.0, height = 20.0), reset_button_text)

        rl.DrawFPS(710, 10)

    return 0

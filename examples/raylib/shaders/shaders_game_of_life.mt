module examples.raylib.shaders.shaders_game_of_life

import std.c.libm as math
import std.c.raygui as gui
import std.c.raylib as rl

enum InteractionMode: i32
    MODE_RUN = 0
    MODE_PAUSE = 1
    MODE_DRAW = 2

const screen_width: i32 = 800
const screen_height: i32 = 450
const menu_width: i32 = 100
const window_width: i32 = screen_width - menu_width
const window_height: i32 = screen_height
const world_width: i32 = 2048
const world_height: i32 = 2048
const random_tiles: i32 = 8
const number_of_presets: i32 = 10
const glsl_version: i32 = 330
const shader_path_format: cstr = c"../resources/shaders/glsl%i/game_of_life.fs"
const resolution_uniform_name: cstr = c"resolution"
const toggle_group_text: cstr = c"Run\nPause\nDraw"
const zoom_format: cstr = c"Zoom: %ix"
const speed_format: cstr = c"Speed: %i frame%s"
const window_title: cstr = c"raylib [shaders] example - game of life"


def gui_rect(x: f32, y: f32, width: f32, height: f32) -> gui.Rectangle:
    return gui.Rectangle(x = x, y = y, width = width, height = height)


def free_image_to_draw(image_to_draw: ref[rl.Image], has_image_to_draw: ref[bool]) -> void:
    if read(has_image_to_draw):
        rl.UnloadImage(read(image_to_draw))
        read(image_to_draw) = zero[rl.Image]()
        read(has_image_to_draw) = false


def load_preset_image(preset: i32) -> rl.Image:
    if preset == 0:
        return rl.LoadImage(c"../resources/game_of_life/glider.png")
    if preset == 1:
        return rl.LoadImage(c"../resources/game_of_life/r_pentomino.png")
    if preset == 2:
        return rl.LoadImage(c"../resources/game_of_life/acorn.png")
    if preset == 3:
        return rl.LoadImage(c"../resources/game_of_life/spaceships.png")
    if preset == 4:
        return rl.LoadImage(c"../resources/game_of_life/still_lifes.png")
    if preset == 5:
        return rl.LoadImage(c"../resources/game_of_life/oscillators.png")
    if preset == 6:
        return rl.LoadImage(c"../resources/game_of_life/puffer_train.png")
    if preset == 7:
        return rl.LoadImage(c"../resources/game_of_life/glider_gun.png")
    return rl.LoadImage(c"../resources/game_of_life/breeder.png")


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let world_rect_source = rl.Rectangle(x = 0.0, y = 0.0, width = f32<-world_width, height = -f32<-world_height)
    let world_rect_dest = rl.Rectangle(x = 0.0, y = 0.0, width = f32<-world_width, height = f32<-world_height)
    let texture_on_screen = rl.Rectangle(x = 0.0, y = 0.0, width = f32<-window_width, height = f32<-window_height)

    let preset_names = array[cstr, 10](
        c"Glider",
        c"R-pentomino",
        c"Acorn",
        c"Spaceships",
        c"Still lifes",
        c"Oscillators",
        c"Puffer train",
        c"Glider Gun",
        c"Breeder",
        c"Random",
    )
    let preset_positions = array[rl.Vector2, 10](
        rl.Vector2(x = 0.5, y = 0.5),
        rl.Vector2(x = 0.5, y = 0.5),
        rl.Vector2(x = 0.5, y = 0.5),
        rl.Vector2(x = 0.1, y = 0.5),
        rl.Vector2(x = 0.5, y = 0.5),
        rl.Vector2(x = 0.5, y = 0.5),
        rl.Vector2(x = 0.1, y = 0.5),
        rl.Vector2(x = 0.2, y = 0.2),
        rl.Vector2(x = 0.1, y = 0.5),
        rl.Vector2(x = 0.5, y = 0.5),
    )

    var zoom = 1
    var offset_x: f32 = f32<-(world_width - window_width) / 2.0
    var offset_y: f32 = f32<-(world_height - window_height) / 2.0
    var frames_per_step = 1
    var frame = 0

    var preset = -1
    var mode = i32<-InteractionMode.MODE_RUN
    var button_zoom_in = false
    var button_zoom_out = false
    var button_faster = false
    var button_slower = false

    let shader = rl.LoadShader(zero[cstr?](), rl.TextFormat(shader_path_format, glsl_version))
    defer rl.UnloadShader(shader)

    let resolution_loc = rl.GetShaderLocation(shader, resolution_uniform_name)
    var resolution = array[f32, 2](f32<-world_width, f32<-world_height)
    rl.SetShaderValue(shader, resolution_loc, ptr_of(ref_of(resolution[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)

    let world1 = rl.LoadRenderTexture(world_width, world_height)
    let world2 = rl.LoadRenderTexture(world_width, world_height)
    defer:
        rl.UnloadRenderTexture(world1)
        rl.UnloadRenderTexture(world2)

    rl.BeginTextureMode(world2)
    rl.ClearBackground(rl.RAYWHITE)
    rl.EndTextureMode()

    var start_pattern = rl.LoadImage(c"../resources/game_of_life/r_pentomino.png")
    rl.UpdateTextureRec(
        world2.texture,
        rl.Rectangle(
            x = world_width / 2.0,
            y = world_height / 2.0,
            width = f32<-start_pattern.width,
            height = f32<-start_pattern.height,
        ),
        start_pattern.data,
    )
    rl.UnloadImage(start_pattern)

    var current_world = world2
    var previous_world = world1

    var image_to_draw = zero[rl.Image]()
    var has_image_to_draw = false

    var previous_mouse_position = rl.Vector2(x = 0.0, y = 0.0)
    var first_color = -1

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        frame += 1

        let mouse_wheel_move = rl.GetMouseWheelMove()
        if button_zoom_in or (button_zoom_out and zoom > 1) or mouse_wheel_move != 0.0:
            free_image_to_draw(ref_of(image_to_draw), ref_of(has_image_to_draw))

            let zoom_f = f32<-zoom
            let center_x = offset_x + f32<-window_width / 2.0 / zoom_f
            let center_y = offset_y + f32<-window_height / 2.0 / zoom_f
            if button_zoom_in or mouse_wheel_move > 0.0:
                zoom *= 2
            if (button_zoom_out or mouse_wheel_move < 0.0) and zoom > 1:
                zoom /= 2
            let new_zoom_f = f32<-zoom
            offset_x = center_x - f32<-window_width / 2.0 / new_zoom_f
            offset_y = center_y - f32<-window_height / 2.0 / new_zoom_f

        if button_faster and frames_per_step > 1:
            frames_per_step -= 1
        if button_slower:
            frames_per_step += 1

        if mode == i32<-InteractionMode.MODE_RUN or mode == i32<-InteractionMode.MODE_PAUSE:
            free_image_to_draw(ref_of(image_to_draw), ref_of(has_image_to_draw))

            let mouse_position = rl.GetMousePosition()
            if rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_LEFT) and mouse_position.x < f32<-window_width:
                offset_x -= (mouse_position.x - previous_mouse_position.x) / f32<-zoom
                offset_y -= (mouse_position.y - previous_mouse_position.y) / f32<-zoom
            previous_mouse_position = mouse_position
        else:
            let offset_decimal_x = offset_x - math.floorf(offset_x)
            let offset_decimal_y = offset_y - math.floorf(offset_y)
            let zoom_f = f32<-zoom
            var size_in_world_x = i32<-math.ceilf((f32<-window_width + offset_decimal_x * zoom_f) / zoom_f)
            var size_in_world_y = i32<-math.ceilf((f32<-window_height + offset_decimal_y * zoom_f) / zoom_f)
            if offset_x + f32<-size_in_world_x >= f32<-world_width:
                size_in_world_x = world_width - i32<-math.floorf(offset_x)
            if offset_y + f32<-size_in_world_y >= f32<-world_height:
                size_in_world_y = world_height - i32<-math.floorf(offset_y)

            if not has_image_to_draw:
                let world_on_screen = rl.LoadRenderTexture(size_in_world_x, size_in_world_y)
                rl.BeginTextureMode(world_on_screen)
                rl.DrawTexturePro(
                    current_world.texture,
                    rl.Rectangle(x = math.floorf(offset_x), y = math.floorf(offset_y), width = f32<-size_in_world_x, height = -f32<-size_in_world_y),
                    rl.Rectangle(x = 0.0, y = 0.0, width = f32<-size_in_world_x, height = f32<-size_in_world_y),
                    rl.Vector2(x = 0.0, y = 0.0),
                    0.0,
                    rl.WHITE,
                )
                rl.EndTextureMode()
                image_to_draw = rl.LoadImageFromTexture(world_on_screen.texture)
                has_image_to_draw = true
                rl.UnloadRenderTexture(world_on_screen)

            let mouse_position = rl.GetMousePosition()
            if rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_LEFT) and mouse_position.x < f32<-window_width:
                var mouse_x = i32<-((mouse_position.x + offset_decimal_x * zoom_f) / zoom_f)
                var mouse_y = i32<-((mouse_position.y + offset_decimal_y * zoom_f) / zoom_f)
                if mouse_x >= size_in_world_x:
                    mouse_x = size_in_world_x - 1
                if mouse_y >= size_in_world_y:
                    mouse_y = size_in_world_y - 1
                if first_color == -1:
                    first_color = if rl.GetImageColor(image_to_draw, mouse_x, mouse_y).r < 5: 0 else: 1
                let previous_color = if rl.GetImageColor(image_to_draw, mouse_x, mouse_y).r < 5: 0 else: 1

                rl.ImageDrawPixel(ptr_of(ref_of(image_to_draw)), mouse_x, mouse_y, if first_color != 0: rl.BLACK else: rl.RAYWHITE)

                if previous_color != first_color:
                    rl.UpdateTextureRec(
                        current_world.texture,
                        rl.Rectangle(x = math.floorf(offset_x), y = math.floorf(offset_y), width = f32<-size_in_world_x, height = f32<-size_in_world_y),
                        image_to_draw.data,
                    )
            else:
                first_color = -1

        if preset >= 0:
            if preset < number_of_presets - 1:
                var pattern = load_preset_image(preset)
                rl.BeginTextureMode(current_world)
                rl.ClearBackground(rl.RAYWHITE)
                rl.EndTextureMode()
                rl.UpdateTextureRec(
                    current_world.texture,
                    rl.Rectangle(
                        x = f32<-world_width * preset_positions[preset].x - f32<-pattern.width / 2.0,
                        y = f32<-world_height * preset_positions[preset].y - f32<-pattern.height / 2.0,
                        width = f32<-pattern.width,
                        height = f32<-pattern.height,
                    ),
                    pattern.data,
                )
                rl.UnloadImage(pattern)
            else:
                var pattern = rl.GenImageColor(world_width / random_tiles, world_height / random_tiles, rl.RAYWHITE)
                for tile_x in range(0, random_tiles):
                    for tile_y in range(0, random_tiles):
                        rl.ImageClearBackground(ptr_of(ref_of(pattern)), rl.RAYWHITE)
                        for pixel_x in range(0, pattern.width):
                            for pixel_y in range(0, pattern.height):
                                if rl.GetRandomValue(0, 100) < 15:
                                    rl.ImageDrawPixel(ptr_of(ref_of(pattern)), pixel_x, pixel_y, rl.BLACK)
                        rl.UpdateTextureRec(
                            current_world.texture,
                            rl.Rectangle(
                                x = f32<-(pattern.width * tile_x),
                                y = f32<-(pattern.height * tile_y),
                                width = f32<-pattern.width,
                                height = f32<-pattern.height,
                            ),
                            pattern.data,
                        )
                rl.UnloadImage(pattern)

            mode = i32<-InteractionMode.MODE_PAUSE
            offset_x = f32<-world_width * preset_positions[preset].x - f32<-window_width / f32<-zoom / 2.0
            offset_y = f32<-world_height * preset_positions[preset].y - f32<-window_height / f32<-zoom / 2.0

        if offset_x < 0.0:
            offset_x = 0.0
        if offset_y < 0.0:
            offset_y = 0.0
        if offset_x > f32<-world_width - f32<-window_width / f32<-zoom:
            offset_x = f32<-world_width - f32<-window_width / f32<-zoom
        if offset_y > f32<-world_height - f32<-window_height / f32<-zoom:
            offset_y = f32<-world_height - f32<-window_height / f32<-zoom

        let texture_source_to_screen = rl.Rectangle(
            x = offset_x,
            y = offset_y,
            width = f32<-window_width / f32<-zoom,
            height = f32<-window_height / f32<-zoom,
        )

        if mode == i32<-InteractionMode.MODE_RUN and (frame % frames_per_step) == 0:
            let temp_world = current_world
            current_world = previous_world
            previous_world = temp_world

            rl.BeginTextureMode(current_world)
            rl.BeginShaderMode(shader)
            rl.DrawTexturePro(previous_world.texture, world_rect_source, world_rect_dest, rl.Vector2(x = 0.0, y = 0.0), 0.0, rl.RAYWHITE)
            rl.EndShaderMode()
            rl.EndTextureMode()

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.DrawTexturePro(current_world.texture, texture_source_to_screen, texture_on_screen, rl.Vector2(x = 0.0, y = 0.0), 0.0, rl.WHITE)

        rl.DrawLine(window_width, 0, window_width, screen_height, rl.Color(r = 218, g = 218, b = 218, a = 255))
        rl.DrawRectangle(window_width, 0, screen_width - window_width, screen_height, rl.Color(r = 232, g = 232, b = 232, a = 255))

        rl.DrawText(c"Conway's", 704, 4, 20, rl.DARKBLUE)
        rl.DrawText(c" game of", 704, 19, 20, rl.DARKBLUE)
        rl.DrawText(c"  life", 708, 34, 20, rl.DARKBLUE)
        rl.DrawText(c"in raylib", 757, 42, 6, rl.BLACK)

        rl.DrawText(c"Presets", 710, 58, 8, rl.GRAY)
        preset = -1
        for index in range(0, number_of_presets):
            if gui.GuiButton(gui_rect(710.0, 70.0 + 18.0 * f32<-index, 80.0, 16.0), preset_names[index]) != 0:
                preset = index

        gui.GuiToggleGroup(gui_rect(710.0, 258.0, 80.0, 16.0), toggle_group_text, ptr_of(ref_of(mode)))

        rl.DrawText(rl.TextFormat(zoom_format, zoom), 710, 316, 8, rl.GRAY)
        button_zoom_in = gui.GuiButton(gui_rect(710.0, 328.0, 80.0, 16.0), c"Zoom in") != 0
        button_zoom_out = gui.GuiButton(gui_rect(710.0, 346.0, 80.0, 16.0), c"Zoom out") != 0

        rl.DrawText(rl.TextFormat(speed_format, frames_per_step, if frames_per_step > 1: c"s" else: c""), 710, 370, 8, rl.GRAY)
        button_faster = gui.GuiButton(gui_rect(710.0, 382.0, 80.0, 16.0), c"Faster") != 0
        button_slower = gui.GuiButton(gui_rect(710.0, 400.0, 80.0, 16.0), c"Slower") != 0

        rl.DrawFPS(712, 426)

    free_image_to_draw(ref_of(image_to_draw), ref_of(has_image_to_draw))
    return 0

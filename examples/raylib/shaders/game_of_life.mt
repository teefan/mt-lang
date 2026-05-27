import std.raygui as gui
import std.raylib as rl
import std.raylib.runtime as rl_runtime


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MENU_WIDTH: int = 100
const WINDOW_WIDTH: int = SCREEN_WIDTH - MENU_WIDTH
const WINDOW_HEIGHT: int = SCREEN_HEIGHT
const WORLD_WIDTH: int = 2048
const WORLD_HEIGHT: int = 2048
const RANDOM_TILES: int = 8
const PRESET_COUNT: int = 10
const IMAGE_PRESET_COUNT: int = 9
const GLSL_VERSION: int = 330

const PRESET_IMAGE_NAMES: array[str, IMAGE_PRESET_COUNT] = array[str, IMAGE_PRESET_COUNT](
    "game_of_life/glider.png",
    "game_of_life/r_pentomino.png",
    "game_of_life/acorn.png",
    "game_of_life/spaceships.png",
    "game_of_life/still_lifes.png",
    "game_of_life/oscillators.png",
    "game_of_life/puffer_train.png",
    "game_of_life/glider_gun.png",
    "game_of_life/breeder.png",
)


enum InteractionMode: int
    MODE_RUN = 0
    MODE_PAUSE = 1
    MODE_DRAW = 2


struct PresetPattern:
    name: str
    position: rl.Vector2


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - game of life")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let world_rect_source = rl.Rectangle(x = 0.0, y = 0.0, width = float<-WORLD_WIDTH, height = -(float<-WORLD_HEIGHT))
    let world_rect_dest = rl.Rectangle(x = 0.0, y = 0.0, width = float<-WORLD_WIDTH, height = float<-WORLD_HEIGHT)
    let texture_on_screen = rl.Rectangle(x = 0.0, y = 0.0, width = float<-WINDOW_WIDTH, height = float<-WINDOW_HEIGHT)
    let preset_patterns = array[PresetPattern, PRESET_COUNT](
        PresetPattern(name = "Glider", position = rl.Vector2(x = 0.5, y = 0.5)),
        PresetPattern(name = "R-pentomino", position = rl.Vector2(x = 0.5, y = 0.5)),
        PresetPattern(name = "Acorn", position = rl.Vector2(x = 0.5, y = 0.5)),
        PresetPattern(name = "Spaceships", position = rl.Vector2(x = 0.1, y = 0.5)),
        PresetPattern(name = "Still lifes", position = rl.Vector2(x = 0.5, y = 0.5)),
        PresetPattern(name = "Oscillators", position = rl.Vector2(x = 0.5, y = 0.5)),
        PresetPattern(name = "Puffer train", position = rl.Vector2(x = 0.1, y = 0.5)),
        PresetPattern(name = "Glider Gun", position = rl.Vector2(x = 0.2, y = 0.2)),
        PresetPattern(name = "Breeder", position = rl.Vector2(x = 0.1, y = 0.5)),
        PresetPattern(name = "Random", position = rl.Vector2(x = 0.5, y = 0.5)),
    )

    var zoom = 1
    var offset_x = float<-(WORLD_WIDTH - WINDOW_WIDTH) / 2.0
    var offset_y = float<-(WORLD_HEIGHT - WINDOW_HEIGHT) / 2.0
    var frames_per_step = 1
    var frame = 0

    var preset = -1
    var mode = int<-InteractionMode.MODE_RUN
    var button_zoom_in = false
    var button_zoom_out = false
    var button_faster = false
    var button_slower = false

    let shader = rl.load_shader(null, rl.text_format("shaders/glsl%i/game_of_life.fs", GLSL_VERSION))
    defer rl.unload_shader(shader)
    let resolution_location = rl.get_shader_location(shader, "resolution")
    let resolution = array[float, 2](float<-WORLD_WIDTH, float<-WORLD_HEIGHT)
    rl.set_shader_value(shader, resolution_location, resolution, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)

    var world1 = rl.load_render_texture(WORLD_WIDTH, WORLD_HEIGHT)
    defer rl.unload_render_texture(world1)
    var world2 = rl.load_render_texture(WORLD_WIDTH, WORLD_HEIGHT)
    defer rl.unload_render_texture(world2)
    rl.begin_texture_mode(world2)
    rl.clear_background(rl.RAYWHITE)
    rl.end_texture_mode()

    var start_pattern = rl.load_image("game_of_life/r_pentomino.png")
    rl.update_texture_rec(
        world2.texture,
        rl.Rectangle(x = float<-WORLD_WIDTH / 2.0, y = float<-WORLD_HEIGHT / 2.0, width = float<-start_pattern.width, height = float<-start_pattern.height),
        start_pattern.data,
    )
    rl.unload_image(start_pattern)

    var current_world = world2
    var previous_world = world1
    var image_to_draw = zero[rl.Image]
    var has_image_to_draw = false
    var previous_mouse_position = rl.Vector2(x = 0.0, y = 0.0)
    var first_color = -1

    rl.set_target_fps(60)

    while not rl.window_should_close():
        frame += 1

        let mouse_wheel_move = rl.get_mouse_wheel_move()
        if button_zoom_in or (button_zoom_out and zoom > 1) or mouse_wheel_move != 0.0:
            if has_image_to_draw:
                rl.unload_image(image_to_draw)
                has_image_to_draw = false

            let center_x = offset_x + (float<-WINDOW_WIDTH / 2.0) / float<-zoom
            let center_y = offset_y + (float<-WINDOW_HEIGHT / 2.0) / float<-zoom
            if button_zoom_in or mouse_wheel_move > 0.0:
                zoom *= 2
            if (button_zoom_out or mouse_wheel_move < 0.0) and zoom > 1:
                zoom /= 2
            offset_x = center_x - (float<-WINDOW_WIDTH / 2.0) / float<-zoom
            offset_y = center_y - (float<-WINDOW_HEIGHT / 2.0) / float<-zoom

        if button_faster and frames_per_step > 1:
            frames_per_step -= 1
        if button_slower:
            frames_per_step += 1

        if mode == int<-InteractionMode.MODE_RUN or mode == int<-InteractionMode.MODE_PAUSE:
            if has_image_to_draw:
                rl.unload_image(image_to_draw)
                has_image_to_draw = false

            let mouse_position = rl.get_mouse_position()
            if rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT) and mouse_position.x < WINDOW_WIDTH:
                offset_x -= (mouse_position.x - previous_mouse_position.x) / float<-zoom
                offset_y -= (mouse_position.y - previous_mouse_position.y) / float<-zoom
            previous_mouse_position = mouse_position
        else:
            let offset_decimal_x = offset_x - float<-(int<-offset_x)
            let offset_decimal_y = offset_y - float<-(int<-offset_y)
            var size_in_world_x = int<-((float<-(WINDOW_WIDTH) + offset_decimal_x * float<-zoom + float<-(zoom - 1)) / float<-zoom)
            var size_in_world_y = int<-((float<-(WINDOW_HEIGHT) + offset_decimal_y * float<-zoom + float<-(zoom - 1)) / float<-zoom)
            if offset_x + float<-size_in_world_x >= WORLD_WIDTH:
                size_in_world_x = WORLD_WIDTH - int<-offset_x
            if offset_y + float<-size_in_world_y >= WORLD_HEIGHT:
                size_in_world_y = WORLD_HEIGHT - int<-offset_y

            if not has_image_to_draw:
                let world_on_screen = rl.load_render_texture(size_in_world_x, size_in_world_y)
                rl.begin_texture_mode(world_on_screen)
                rl.draw_texture_pro(
                    current_world.texture,
                    rl.Rectangle(x = float<-(int<-offset_x), y = float<-(int<-offset_y), width = float<-size_in_world_x, height = -(float<-size_in_world_y)),
                    rl.Rectangle(x = 0.0, y = 0.0, width = float<-size_in_world_x, height = float<-size_in_world_y),
                    rl.Vector2(x = 0.0, y = 0.0),
                    0.0,
                    rl.WHITE,
                )
                rl.end_texture_mode()
                image_to_draw = rl.load_image_from_texture(world_on_screen.texture)
                has_image_to_draw = true
                rl.unload_render_texture(world_on_screen)

            let mouse_position = rl.get_mouse_position()
            if rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT) and mouse_position.x < WINDOW_WIDTH:
                var mouse_x = int<-((mouse_position.x + offset_decimal_x * float<-zoom) / float<-zoom)
                var mouse_y = int<-((mouse_position.y + offset_decimal_y * float<-zoom) / float<-zoom)
                if mouse_x >= size_in_world_x:
                    mouse_x = size_in_world_x - 1
                if mouse_y >= size_in_world_y:
                    mouse_y = size_in_world_y - 1
                if first_color == -1:
                    first_color = if rl.get_image_color(image_to_draw, mouse_x, mouse_y).r < 5: 0 else: 1
                let previous_color = if rl.get_image_color(image_to_draw, mouse_x, mouse_y).r < 5: 0 else: 1

                rl.image_draw_pixel(image_to_draw, mouse_x, mouse_y, if first_color != 0: rl.BLACK else: rl.RAYWHITE)
                if previous_color != first_color:
                    rl.update_texture_rec(
                        current_world.texture,
                        rl.Rectangle(x = float<-(int<-offset_x), y = float<-(int<-offset_y), width = float<-size_in_world_x, height = float<-size_in_world_y),
                        image_to_draw.data,
                    )
            else:
                first_color = -1

        if preset >= 0:
            if preset < PRESET_COUNT - 1:
                var pattern = rl.load_image(PRESET_IMAGE_NAMES[preset])
                rl.begin_texture_mode(current_world)
                rl.clear_background(rl.RAYWHITE)
                rl.end_texture_mode()
                rl.update_texture_rec(
                    current_world.texture,
                    rl.Rectangle(
                        x = float<-WORLD_WIDTH * preset_patterns[preset].position.x - float<-pattern.width / 2.0,
                        y = float<-WORLD_HEIGHT * preset_patterns[preset].position.y - float<-pattern.height / 2.0,
                        width = float<-pattern.width,
                        height = float<-pattern.height,
                    ),
                    pattern.data,
                )
                rl.unload_image(pattern)
            else:
                var pattern = rl.gen_image_color(WORLD_WIDTH / RANDOM_TILES, WORLD_HEIGHT / RANDOM_TILES, rl.RAYWHITE)
                var i = 0
                while i < RANDOM_TILES:
                    var j = 0
                    while j < RANDOM_TILES:
                        rl.image_clear_background(pattern, rl.RAYWHITE)
                        var x = 0
                        while x < pattern.width:
                            var y = 0
                            while y < pattern.height:
                                if rl.get_random_value(0, 100) < 15:
                                    rl.image_draw_pixel(pattern, x, y, rl.BLACK)
                                y += 1
                            x += 1
                        rl.update_texture_rec(
                            current_world.texture,
                            rl.Rectangle(x = float<-(pattern.width * i), y = float<-(pattern.height * j), width = float<-pattern.width, height = float<-pattern.height),
                            pattern.data,
                        )
                        j += 1
                    i += 1
                rl.unload_image(pattern)

            mode = int<-InteractionMode.MODE_PAUSE
            offset_x = float<-WORLD_WIDTH * preset_patterns[preset].position.x - float<-WINDOW_WIDTH / float<-zoom / 2.0
            offset_y = float<-WORLD_HEIGHT * preset_patterns[preset].position.y - float<-WINDOW_HEIGHT / float<-zoom / 2.0

        if offset_x < 0.0:
            offset_x = 0.0
        if offset_y < 0.0:
            offset_y = 0.0
        if offset_x > WORLD_WIDTH - float<-WINDOW_WIDTH / float<-zoom:
            offset_x = WORLD_WIDTH - float<-WINDOW_WIDTH / float<-zoom
        if offset_y > WORLD_HEIGHT - float<-WINDOW_HEIGHT / float<-zoom:
            offset_y = WORLD_HEIGHT - float<-WINDOW_HEIGHT / float<-zoom

        let texture_source_to_screen = rl.Rectangle(
            x = offset_x,
            y = offset_y,
            width = float<-WINDOW_WIDTH / float<-zoom,
            height = float<-WINDOW_HEIGHT / float<-zoom,
        )

        if mode == int<-InteractionMode.MODE_RUN and frame % frames_per_step == 0:
            let temp_world = current_world
            current_world = previous_world
            previous_world = temp_world

            rl.begin_texture_mode(current_world)
            rl.begin_shader_mode(shader)
            rl.draw_texture_pro(previous_world.texture, world_rect_source, world_rect_dest, rl.Vector2(x = 0.0, y = 0.0), 0.0, rl.RAYWHITE)
            rl.end_shader_mode()
            rl.end_texture_mode()

        rl.begin_drawing()
        rl.draw_texture_pro(current_world.texture, texture_source_to_screen, texture_on_screen, rl.Vector2(x = 0.0, y = 0.0), 0.0, rl.WHITE)
        rl.draw_line(WINDOW_WIDTH, 0, WINDOW_WIDTH, SCREEN_HEIGHT, rl.Color(r = 218, g = 218, b = 218, a = 255))
        rl.draw_rectangle(WINDOW_WIDTH, 0, SCREEN_WIDTH - WINDOW_WIDTH, SCREEN_HEIGHT, rl.Color(r = 232, g = 232, b = 232, a = 255))

        rl.draw_text("Conway's", 704, 4, 20, rl.DARKBLUE)
        rl.draw_text(" game of", 704, 19, 20, rl.DARKBLUE)
        rl.draw_text("  life", 708, 34, 20, rl.DARKBLUE)
        rl.draw_text("in raylib", 757, 42, 6, rl.BLACK)

        rl.draw_text("Presets", 710, 58, 8, rl.GRAY)
        preset = -1
        var preset_index = 0
        while preset_index < PRESET_COUNT:
            if gui.button(rl.Rectangle(x = 710.0, y = 70.0 + 18.0 * float<-preset_index, width = 80.0, height = 16.0), preset_patterns[preset_index].name) != 0:
                preset = preset_index
            preset_index += 1

        gui.toggle_group(rl.Rectangle(x = 710.0, y = 258.0, width = 80.0, height = 16.0), "Run\nPause\nDraw", mode)

        rl.draw_text(rl.text_format("Zoom: %ix", zoom), 710, 316, 8, rl.GRAY)
        button_zoom_in = gui.button(rl.Rectangle(x = 710.0, y = 328.0, width = 80.0, height = 16.0), "Zoom in") != 0
        button_zoom_out = gui.button(rl.Rectangle(x = 710.0, y = 346.0, width = 80.0, height = 16.0), "Zoom out") != 0

        let frame_suffix = if frames_per_step > 1: "s" else: ""
        rl.draw_text(rl.text_format("Speed: %i frame%s", frames_per_step, frame_suffix), 710, 370, 8, rl.GRAY)
        button_faster = gui.button(rl.Rectangle(x = 710.0, y = 382.0, width = 80.0, height = 16.0), "Faster") != 0
        button_slower = gui.button(rl.Rectangle(x = 710.0, y = 400.0, width = 80.0, height = 16.0), "Slower") != 0
        rl.draw_fps(712, 426)
        rl.end_drawing()

    if has_image_to_draw:
        rl.unload_image(image_to_draw)

    return 0

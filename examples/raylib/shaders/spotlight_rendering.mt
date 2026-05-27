import std.math as math
import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.raymath as rm


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330
const MAX_SPOTS: int = 3
const MAX_STARS: int = 400


struct Spot:
    position: rl.Vector2
    speed: rl.Vector2
    inner: float
    radius: float
    position_loc: int
    inner_loc: int
    radius_loc: int


struct Star:
    position: rl.Vector2
    speed: rl.Vector2


function reset_star() -> Star:
    var star = Star(
        position = rl.Vector2(x = float<-SCREEN_WIDTH / 2.0, y = float<-SCREEN_HEIGHT / 2.0),
        speed = rl.Vector2(
            x = float<-rl.get_random_value(-1000, 1000) / 100.0,
            y = float<-rl.get_random_value(-1000, 1000) / 100.0,
        ),
    )

    while not ((math.abs(double<-star.speed.x) + math.abs(double<-star.speed.y)) > 1.0):
        star.speed.x = float<-rl.get_random_value(-1000, 1000) / 100.0
        star.speed.y = float<-rl.get_random_value(-1000, 1000) / 100.0

    star.position = rm.vector2_add(star.position, rm.vector2_multiply(star.speed, rl.Vector2(x = 8.0, y = 8.0)))
    return star


function update_star(star: Star) -> Star:
    var updated = star
    updated.position = rm.vector2_add(updated.position, updated.speed)

    if updated.position.x < 0.0 or updated.position.x > float<-SCREEN_WIDTH or updated.position.y < 0.0 or updated.position.y > float<-SCREEN_HEIGHT:
        return reset_star()

    return updated


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - spotlight rendering")
    defer rl.close_window()
    rl.hide_cursor()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let tex_ray = rl.load_texture("raysan.png")
    defer rl.unload_texture(tex_ray)

    var stars: array[Star, MAX_STARS] = zero[array[Star, MAX_STARS]]
    var index = 0
    while index < MAX_STARS:
        stars[index] = reset_star()
        index += 1

    var progress = 0
    while progress < SCREEN_WIDTH / 2:
        index = 0
        while index < MAX_STARS:
            stars[index] = update_star(stars[index])
            index += 1
        progress += 1

    var frame_counter = 0
    let shader = rl.load_shader(null, rl.text_format("shaders/glsl%i/spotlight.fs", GLSL_VERSION))
    defer rl.unload_shader(shader)

    var spots: array[Spot, MAX_SPOTS] = zero[array[Spot, MAX_SPOTS]]
    index = 0
    while index < MAX_SPOTS:
        let position_name = rl.text_format("spots[%i].pos", index)
        let inner_name = rl.text_format("spots[%i].inner", index)
        let radius_name = rl.text_format("spots[%i].radius", index)

        var speed = rl.Vector2(x = 0.0, y = 0.0)
        while (math.abs(double<-speed.x) + math.abs(double<-speed.y)) < 2.0:
            speed.x = float<-rl.get_random_value(-400, 40) / 25.0
            speed.y = float<-rl.get_random_value(-400, 40) / 25.0

        spots[index] = Spot(
            position = rl.Vector2(
                x = float<-rl.get_random_value(64, SCREEN_WIDTH - 64),
                y = float<-rl.get_random_value(64, SCREEN_HEIGHT - 64),
            ),
            speed = speed,
            inner = 28.0 * float<-(index + 1),
            radius = 48.0 * float<-(index + 1),
            position_loc = rl.get_shader_location(shader, position_name),
            inner_loc = rl.get_shader_location(shader, inner_name),
            radius_loc = rl.get_shader_location(shader, radius_name),
        )
        rl.set_shader_value(shader, spots[index].position_loc, spots[index].position, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
        rl.set_shader_value(shader, spots[index].inner_loc, spots[index].inner, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
        rl.set_shader_value(shader, spots[index].radius_loc, spots[index].radius, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
        index += 1

    let screen_width_location = rl.get_shader_location(shader, "screenWidth")
    let screen_width_value: float = SCREEN_WIDTH
    rl.set_shader_value(shader, screen_width_location, screen_width_value, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        frame_counter += 1

        index = 0
        while index < MAX_STARS:
            stars[index] = update_star(stars[index])
            index += 1

        index = 0
        while index < MAX_SPOTS:
            var spot = spots[index]
            if index == 0:
                let mouse_position = rl.get_mouse_position()
                spot.position.x = mouse_position.x
                spot.position.y = float<-SCREEN_HEIGHT - mouse_position.y
            else:
                spot.position.x += spot.speed.x
                spot.position.y += spot.speed.y

                if spot.position.x < 64.0 or spot.position.x > float<-(SCREEN_WIDTH - 64):
                    spot.speed.x = -spot.speed.x
                if spot.position.y < 64.0 or spot.position.y > float<-(SCREEN_HEIGHT - 64):
                    spot.speed.y = -spot.speed.y

            spots[index] = spot
            rl.set_shader_value(shader, spot.position_loc, spot.position, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
            index += 1

        rl.begin_drawing()
        rl.clear_background(rl.DARKBLUE)

        index = 0
        while index < MAX_STARS:
            rl.draw_rectangle(int<-stars[index].position.x, int<-stars[index].position.y, 2, 2, rl.WHITE)
            index += 1

        index = 0
        while index < 16:
            let x = int<-((float<-SCREEN_WIDTH / 2.0) + float<-(math.cos(double<-(frame_counter + index * 8) / 51.45) * double<-(float<-SCREEN_WIDTH / 2.2)) - 32.0)
            let y = int<-((float<-SCREEN_HEIGHT / 2.0) + float<-(math.sin(double<-(frame_counter + index * 8) / 17.87) * double<-(float<-SCREEN_HEIGHT / 4.2)))
            rl.draw_texture(tex_ray, x, y, rl.WHITE)
            index += 1

        rl.begin_shader_mode(shader)
        rl.draw_rectangle(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, rl.WHITE)
        rl.end_shader_mode()

        rl.draw_fps(10, 10)
        rl.draw_text("Move the mouse!", 10, 30, 20, rl.GREEN)
        rl.draw_text("Pitch Black", int<-(float<-SCREEN_WIDTH * 0.2), SCREEN_HEIGHT / 2, 20, rl.GREEN)
        rl.draw_text("Dark", int<-(float<-SCREEN_WIDTH * 0.66), SCREEN_HEIGHT / 2, 20, rl.GREEN)
        rl.end_drawing()

    return 0

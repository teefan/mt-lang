import std.raylib as rl
import std.raylib.runtime as rl_runtime

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330

struct RoundedRectangle:
    rectangle_loc: int
    radius_loc: int
    color_loc: int
    shadow_radius_loc: int
    shadow_offset_loc: int
    shadow_scale_loc: int
    shadow_color_loc: int
    border_thickness_loc: int
    border_color_loc: int


function create_rounded_rectangle(shader: rl.Shader) -> RoundedRectangle:
    return RoundedRectangle(
        rectangle_loc = rl.get_shader_location(shader, "rectangle"),
        radius_loc = rl.get_shader_location(shader, "radius"),
        color_loc = rl.get_shader_location(shader, "color"),
        shadow_radius_loc = rl.get_shader_location(shader, "shadowRadius"),
        shadow_offset_loc = rl.get_shader_location(shader, "shadowOffset"),
        shadow_scale_loc = rl.get_shader_location(shader, "shadowScale"),
        shadow_color_loc = rl.get_shader_location(shader, "shadowColor"),
        border_thickness_loc = rl.get_shader_location(shader, "borderThickness"),
        border_color_loc = rl.get_shader_location(shader, "borderColor")
    )


function color_vector(color: rl.Color) -> array[float, 4]:
    return array[float, 4](
        float<-color.r / 255.0,
        float<-color.g / 255.0,
        float<-color.b / 255.0,
        float<-color.a / 255.0
    )


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - rounded rectangle")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let shader = rl.load_shader(
        rl.text_format("shaders/glsl%i/base.vs", GLSL_VERSION),
        rl.text_format("shaders/glsl%i/rounded_rectangle.fs", GLSL_VERSION)
    )
    defer rl.unload_shader(shader)

    let rounded_rectangle = create_rounded_rectangle(shader)

    let corner_radius = array[float, 4](5.0, 10.0, 15.0, 20.0)
    let shadow_radius: float = 20.0
    let shadow_offset = array[float, 2](0.0, -5.0)
    let shadow_scale: float = 0.95
    let border_thickness: float = 5.0

    rl.set_shader_value(
        shader,
        rounded_rectangle.radius_loc,
        corner_radius,
        int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4
    )
    rl.set_shader_value(
        shader,
        rounded_rectangle.shadow_radius_loc,
        shadow_radius,
        int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT
    )
    rl.set_shader_value(
        shader,
        rounded_rectangle.shadow_offset_loc,
        shadow_offset,
        int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2
    )
    rl.set_shader_value(
        shader,
        rounded_rectangle.shadow_scale_loc,
        shadow_scale,
        int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT
    )
    rl.set_shader_value(
        shader,
        rounded_rectangle.border_thickness_loc,
        border_thickness,
        int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT
    )

    let rectangle_color = color_vector(rl.BLUE)
    let shadow_color = color_vector(rl.DARKBLUE)
    let border_color = color_vector(rl.SKYBLUE)
    let transparent = array[float, 4](0.0, 0.0, 0.0, 0.0)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        var rec = rl.Rectangle(x = 50.0, y = 70.0, width = 110.0, height = 60.0)
        rl.draw_rectangle_lines(
            int<-rec.x - 20,
            int<-rec.y - 20,
            int<-rec.width + 40,
            int<-rec.height + 40,
            rl.DARKGRAY
        )
        rl.draw_text("Rounded rectangle", int<-rec.x - 20, int<-rec.y - 35, 10, rl.DARKGRAY)

        rec.y = float<-SCREEN_HEIGHT - rec.y - rec.height
        let rec0 = array[float, 4](rec.x, rec.y, rec.width, rec.height)
        rl.set_shader_value(
            shader,
            rounded_rectangle.rectangle_loc,
            rec0,
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4
        )
        rl.set_shader_value(
            shader,
            rounded_rectangle.color_loc,
            rectangle_color,
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4
        )
        rl.set_shader_value(
            shader,
            rounded_rectangle.shadow_color_loc,
            transparent,
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4
        )
        rl.set_shader_value(
            shader,
            rounded_rectangle.border_color_loc,
            transparent,
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4
        )
        rl.begin_shader_mode(shader)
        rl.draw_rectangle(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, rl.WHITE)
        rl.end_shader_mode()

        rec = rl.Rectangle(x = 50.0, y = 200.0, width = 110.0, height = 60.0)
        rl.draw_rectangle_lines(
            int<-rec.x - 20,
            int<-rec.y - 20,
            int<-rec.width + 40,
            int<-rec.height + 40,
            rl.DARKGRAY
        )
        rl.draw_text("Rounded rectangle shadow", int<-rec.x - 20, int<-rec.y - 35, 10, rl.DARKGRAY)
        rec.y = float<-SCREEN_HEIGHT - rec.y - rec.height
        let rec1 = array[float, 4](rec.x, rec.y, rec.width, rec.height)
        rl.set_shader_value(
            shader,
            rounded_rectangle.rectangle_loc,
            rec1,
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4
        )
        rl.set_shader_value(
            shader,
            rounded_rectangle.color_loc,
            transparent,
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4
        )
        rl.set_shader_value(
            shader,
            rounded_rectangle.shadow_color_loc,
            shadow_color,
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4
        )
        rl.set_shader_value(
            shader,
            rounded_rectangle.border_color_loc,
            transparent,
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4
        )
        rl.begin_shader_mode(shader)
        rl.draw_rectangle(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, rl.WHITE)
        rl.end_shader_mode()

        rec = rl.Rectangle(x = 50.0, y = 330.0, width = 110.0, height = 60.0)
        rl.draw_rectangle_lines(
            int<-rec.x - 20,
            int<-rec.y - 20,
            int<-rec.width + 40,
            int<-rec.height + 40,
            rl.DARKGRAY
        )
        rl.draw_text("Rounded rectangle border", int<-rec.x - 20, int<-rec.y - 35, 10, rl.DARKGRAY)
        rec.y = float<-SCREEN_HEIGHT - rec.y - rec.height
        let rec2 = array[float, 4](rec.x, rec.y, rec.width, rec.height)
        rl.set_shader_value(
            shader,
            rounded_rectangle.rectangle_loc,
            rec2,
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4
        )
        rl.set_shader_value(
            shader,
            rounded_rectangle.color_loc,
            transparent,
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4
        )
        rl.set_shader_value(
            shader,
            rounded_rectangle.shadow_color_loc,
            transparent,
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4
        )
        rl.set_shader_value(
            shader,
            rounded_rectangle.border_color_loc,
            border_color,
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4
        )
        rl.begin_shader_mode(shader)
        rl.draw_rectangle(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, rl.WHITE)
        rl.end_shader_mode()

        rec = rl.Rectangle(x = 240.0, y = 80.0, width = 500.0, height = 300.0)
        rl.draw_rectangle_lines(
            int<-rec.x - 30,
            int<-rec.y - 30,
            int<-rec.width + 60,
            int<-rec.height + 60,
            rl.DARKGRAY
        )
        rl.draw_text("Rectangle with all three combined", int<-rec.x - 30, int<-rec.y - 45, 10, rl.DARKGRAY)
        rec.y = float<-SCREEN_HEIGHT - rec.y - rec.height
        let rec3 = array[float, 4](rec.x, rec.y, rec.width, rec.height)
        rl.set_shader_value(
            shader,
            rounded_rectangle.rectangle_loc,
            rec3,
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4
        )
        rl.set_shader_value(
            shader,
            rounded_rectangle.color_loc,
            rectangle_color,
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4
        )
        rl.set_shader_value(
            shader,
            rounded_rectangle.shadow_color_loc,
            shadow_color,
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4
        )
        rl.set_shader_value(
            shader,
            rounded_rectangle.border_color_loc,
            border_color,
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4
        )
        rl.begin_shader_mode(shader)
        rl.draw_rectangle(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, rl.WHITE)
        rl.end_shader_mode()

        rl.draw_text(
            "(c) Rounded rectangle SDF by Inigo Quilez. MIT License.",
            SCREEN_WIDTH - 300,
            SCREEN_HEIGHT - 20,
            10,
            rl.BLACK
        )
        rl.end_drawing()

    return 0

module examples.raylib.shaders.shaders_rounded_rectangle

import std.c.raylib as rl

struct RoundedRectangle:
    corner_radius: rl.Vector4
    shadow_radius: f32
    shadow_offset: rl.Vector2
    shadow_scale: f32
    border_thickness: f32
    rectangle_loc: i32
    radius_loc: i32
    color_loc: i32
    shadow_radius_loc: i32
    shadow_offset_loc: i32
    shadow_scale_loc: i32
    shadow_color_loc: i32
    border_thickness_loc: i32
    border_color_loc: i32

const screen_width: i32 = 800
const screen_height: i32 = 450
const glsl_version: i32 = 330
const vertex_shader_path_format: cstr = c"../resources/shaders/glsl%i/base.vs"
const fragment_shader_path_format: cstr = c"../resources/shaders/glsl%i/rounded_rectangle.fs"
const rectangle_uniform_name: cstr = c"rectangle"
const radius_uniform_name: cstr = c"radius"
const color_uniform_name: cstr = c"color"
const shadow_radius_uniform_name: cstr = c"shadowRadius"
const shadow_offset_uniform_name: cstr = c"shadowOffset"
const shadow_scale_uniform_name: cstr = c"shadowScale"
const shadow_color_uniform_name: cstr = c"shadowColor"
const border_thickness_uniform_name: cstr = c"borderThickness"
const border_color_uniform_name: cstr = c"borderColor"
const rounded_rectangle_text: cstr = c"Rounded rectangle"
const rounded_shadow_text: cstr = c"Rounded rectangle shadow"
const rounded_border_text: cstr = c"Rounded rectangle border"
const rounded_combined_text: cstr = c"Rectangle with all three combined"
const credit_text: cstr = c"(c) Rounded rectangle SDF by Inigo Quilez. MIT License."
const window_title: cstr = c"raylib [shaders] example - rounded rectangle"

def normalized_color(color: rl.Color) -> array[f32, 4]:
    return array[f32, 4](
        f32<-color.r / 255.0,
        f32<-color.g / 255.0,
        f32<-color.b / 255.0,
        f32<-color.a / 255.0,
    )

def rectangle_components(rectangle: rl.Rectangle) -> array[f32, 4]:
    return array[f32, 4](rectangle.x, rectangle.y, rectangle.width, rectangle.height)

def vector4_components(vector: rl.Vector4) -> array[f32, 4]:
    return array[f32, 4](vector.x, vector.y, vector.z, vector.w)

def vector2_components(vector: rl.Vector2) -> array[f32, 2]:
    return array[f32, 2](vector.x, vector.y)

def set_vec4_uniform(shader: rl.Shader, location: i32, x: f32, y: f32, z: f32, w: f32) -> void:
    var values = array[f32, 4](x, y, z, w)
    rl.SetShaderValue(shader, location, ptr_of(ref_of(values[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4)

def set_vec2_uniform(shader: rl.Shader, location: i32, x: f32, y: f32) -> void:
    var values = array[f32, 2](x, y)
    rl.SetShaderValue(shader, location, ptr_of(ref_of(values[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)

def set_float_uniform(shader: rl.Shader, location: i32, value: f32) -> void:
    var storage: f32 = value
    rl.SetShaderValue(shader, location, ptr_of(ref_of(storage)), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

def set_rectangle_uniform(shader: rl.Shader, rounded_rectangle: RoundedRectangle, rectangle: rl.Rectangle) -> void:
    let rectangle_values = rectangle_components(rectangle)
    set_vec4_uniform(shader, rounded_rectangle.rectangle_loc, rectangle_values[0], rectangle_values[1], rectangle_values[2], rectangle_values[3])

def set_color_uniform(shader: rl.Shader, location: i32, color: rl.Color) -> void:
    let color_values = normalized_color(color)
    set_vec4_uniform(shader, location, color_values[0], color_values[1], color_values[2], color_values[3])

def update_rounded_rectangle(rounded_rectangle: RoundedRectangle, shader: rl.Shader) -> void:
    let radius_values = vector4_components(rounded_rectangle.corner_radius)
    let shadow_offset_values = vector2_components(rounded_rectangle.shadow_offset)
    var shadow_radius = rounded_rectangle.shadow_radius
    var shadow_scale = rounded_rectangle.shadow_scale
    var border_thickness = rounded_rectangle.border_thickness

    set_vec4_uniform(shader, rounded_rectangle.radius_loc, radius_values[0], radius_values[1], radius_values[2], radius_values[3])
    set_float_uniform(shader, rounded_rectangle.shadow_radius_loc, shadow_radius)
    set_vec2_uniform(shader, rounded_rectangle.shadow_offset_loc, shadow_offset_values[0], shadow_offset_values[1])
    set_float_uniform(shader, rounded_rectangle.shadow_scale_loc, shadow_scale)
    set_float_uniform(shader, rounded_rectangle.border_thickness_loc, border_thickness)

def create_rounded_rectangle(corner_radius: rl.Vector4, shadow_radius: f32, shadow_offset: rl.Vector2, shadow_scale: f32, border_thickness: f32, shader: rl.Shader) -> RoundedRectangle:
    let rounded_rectangle = RoundedRectangle(
        corner_radius = corner_radius,
        shadow_radius = shadow_radius,
        shadow_offset = shadow_offset,
        shadow_scale = shadow_scale,
        border_thickness = border_thickness,
        rectangle_loc = rl.GetShaderLocation(shader, rectangle_uniform_name),
        radius_loc = rl.GetShaderLocation(shader, radius_uniform_name),
        color_loc = rl.GetShaderLocation(shader, color_uniform_name),
        shadow_radius_loc = rl.GetShaderLocation(shader, shadow_radius_uniform_name),
        shadow_offset_loc = rl.GetShaderLocation(shader, shadow_offset_uniform_name),
        shadow_scale_loc = rl.GetShaderLocation(shader, shadow_scale_uniform_name),
        shadow_color_loc = rl.GetShaderLocation(shader, shadow_color_uniform_name),
        border_thickness_loc = rl.GetShaderLocation(shader, border_thickness_uniform_name),
        border_color_loc = rl.GetShaderLocation(shader, border_color_uniform_name),
    )

    update_rounded_rectangle(rounded_rectangle, shader)
    return rounded_rectangle

def flipped_rectangle(rectangle: rl.Rectangle) -> rl.Rectangle:
    return rl.Rectangle(
        x = rectangle.x,
        y = f32<-screen_height - rectangle.y - rectangle.height,
        width = rectangle.width,
        height = rectangle.height,
    )

def draw_shader_pass(shader: rl.Shader, rounded_rectangle: RoundedRectangle, rectangle: rl.Rectangle, color: rl.Color, shadow_color: rl.Color, border_color: rl.Color) -> void:
    set_rectangle_uniform(shader, rounded_rectangle, flipped_rectangle(rectangle))
    set_color_uniform(shader, rounded_rectangle.color_loc, color)
    set_color_uniform(shader, rounded_rectangle.shadow_color_loc, shadow_color)
    set_color_uniform(shader, rounded_rectangle.border_color_loc, border_color)

    rl.BeginShaderMode(shader)
    rl.DrawRectangle(0, 0, screen_width, screen_height, rl.WHITE)
    rl.EndShaderMode()

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let shader = rl.LoadShader(
        rl.TextFormat(vertex_shader_path_format, glsl_version),
        rl.TextFormat(fragment_shader_path_format, glsl_version),
    )
    defer rl.UnloadShader(shader)

    let rounded_rectangle = create_rounded_rectangle(
        rl.Vector4(x = 5.0, y = 10.0, z = 15.0, w = 20.0),
        20.0,
        rl.Vector2(x = 0.0, y = -5.0),
        0.95,
        5.0,
        shader,
    )

    let rectangle_color = rl.BLUE
    let shadow_color = rl.DARKBLUE
    let border_color = rl.SKYBLUE
    let transparent = rl.Color(r = 0, g = 0, b = 0, a = 0)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        let first_rectangle = rl.Rectangle(x = 50.0, y = 70.0, width = 110.0, height = 60.0)
        rl.DrawRectangleLines(i32<-first_rectangle.x - 20, i32<-first_rectangle.y - 20, i32<-first_rectangle.width + 40, i32<-first_rectangle.height + 40, rl.DARKGRAY)
        rl.DrawText(rounded_rectangle_text, i32<-first_rectangle.x - 20, i32<-first_rectangle.y - 35, 10, rl.DARKGRAY)
        draw_shader_pass(shader, rounded_rectangle, first_rectangle, rectangle_color, transparent, transparent)

        let second_rectangle = rl.Rectangle(x = 50.0, y = 200.0, width = 110.0, height = 60.0)
        rl.DrawRectangleLines(i32<-second_rectangle.x - 20, i32<-second_rectangle.y - 20, i32<-second_rectangle.width + 40, i32<-second_rectangle.height + 40, rl.DARKGRAY)
        rl.DrawText(rounded_shadow_text, i32<-second_rectangle.x - 20, i32<-second_rectangle.y - 35, 10, rl.DARKGRAY)
        draw_shader_pass(shader, rounded_rectangle, second_rectangle, transparent, shadow_color, transparent)

        let third_rectangle = rl.Rectangle(x = 50.0, y = 330.0, width = 110.0, height = 60.0)
        rl.DrawRectangleLines(i32<-third_rectangle.x - 20, i32<-third_rectangle.y - 20, i32<-third_rectangle.width + 40, i32<-third_rectangle.height + 40, rl.DARKGRAY)
        rl.DrawText(rounded_border_text, i32<-third_rectangle.x - 20, i32<-third_rectangle.y - 35, 10, rl.DARKGRAY)
        draw_shader_pass(shader, rounded_rectangle, third_rectangle, transparent, transparent, border_color)

        let fourth_rectangle = rl.Rectangle(x = 240.0, y = 80.0, width = 500.0, height = 300.0)
        rl.DrawRectangleLines(i32<-fourth_rectangle.x - 30, i32<-fourth_rectangle.y - 30, i32<-fourth_rectangle.width + 60, i32<-fourth_rectangle.height + 60, rl.DARKGRAY)
        rl.DrawText(rounded_combined_text, i32<-fourth_rectangle.x - 30, i32<-fourth_rectangle.y - 45, 10, rl.DARKGRAY)
        draw_shader_pass(shader, rounded_rectangle, fourth_rectangle, rectangle_color, shadow_color, border_color)

        rl.DrawText(credit_text, screen_width - 300, screen_height - 20, 10, rl.BLACK)

    return 0
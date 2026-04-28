module examples.idiomatic.raylib.polygon_drawing

import std.raylib as rl
import std.raylib.math as rm
import std.rlgl as rlgl

const max_points: i32 = 11
const screen_width: i32 = 800
const screen_height: i32 = 450
const texture_path: str = "../../raylib/textures/resources/cat.png"

def draw_texture_poly(texture: rl.Texture2D, center: rl.Vector2, points: array[rl.Vector2, 11], texcoords: array[rl.Vector2, 11], tint: rl.Color) -> void:
    rlgl.set_texture(texture.id)
    rlgl.begin(rlgl.RL_TRIANGLES)
    rlgl.color_4ub(tint.r, tint.g, tint.b, tint.a)

    for index in range(0, max_points - 1):
        rlgl.tex_coord_2f(0.5, 0.5)
        rlgl.vertex_2f(center.x, center.y)

        rlgl.tex_coord_2f(texcoords[index].x, texcoords[index].y)
        rlgl.vertex_2f(points[index].x + center.x, points[index].y + center.y)

        rlgl.tex_coord_2f(texcoords[index + 1].x, texcoords[index + 1].y)
        rlgl.vertex_2f(points[index + 1].x + center.x, points[index + 1].y + center.y)

    rlgl.end()
    rlgl.set_texture(cast[u32](0))

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Polygon Drawing")
    defer rl.close_window()

    let texcoords = array[rl.Vector2, 11](
        rl.Vector2(x = 0.75, y = 0.0),
        rl.Vector2(x = 0.25, y = 0.0),
        rl.Vector2(x = 0.0, y = 0.5),
        rl.Vector2(x = 0.0, y = 0.75),
        rl.Vector2(x = 0.25, y = 1.0),
        rl.Vector2(x = 0.375, y = 0.875),
        rl.Vector2(x = 0.625, y = 0.875),
        rl.Vector2(x = 0.75, y = 1.0),
        rl.Vector2(x = 1.0, y = 0.75),
        rl.Vector2(x = 1.0, y = 0.5),
        rl.Vector2(x = 0.75, y = 0.0),
    )

    var points = zero[array[rl.Vector2, 11]]()
    for index in range(0, max_points):
        points[index].x = (texcoords[index].x - 0.5) * 256.0
        points[index].y = (texcoords[index].y - 0.5) * 256.0

    var positions = zero[array[rl.Vector2, 11]]()
    for index in range(0, max_points):
        positions[index] = points[index]

    let texture = rl.load_texture(texture_path)
    defer rl.unload_texture(texture)

    var angle: f32 = 0.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        angle += 1.0

        for index in range(0, max_points):
            positions[index] = points[index].rotate(angle * rm.deg2rad)

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_text("textured polygon", 20, 20, 20, rl.DARKGRAY)

        draw_texture_poly(
            texture,
            rl.Vector2(x = cast[f32](rl.get_screen_width()) / 2.0, y = cast[f32](rl.get_screen_height()) / 2.0),
            positions,
            texcoords,
            rl.WHITE,
        )

    return 0

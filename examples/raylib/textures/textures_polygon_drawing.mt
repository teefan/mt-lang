module examples.raylib.textures.textures_polygon_drawing

import std.c.raylib as rl
import std.c.rlgl as rlgl
import std.raylib.math as rm

const max_points: i32 = 11
const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [textures] example - polygon drawing"
const title_text: cstr = c"textured polygon"
const texture_path: cstr = c"../resources/cat.png"


def draw_texture_poly(texture: rl.Texture, center: rl.Vector2, points: ptr[rl.Vector2], texcoords: ptr[rl.Vector2], point_count: i32, tint: rl.Color) -> void:
    unsafe:
        rlgl.rlSetTexture(texture.id)
        rlgl.rlBegin(rlgl.RL_TRIANGLES)

        rlgl.rlColor4ub(tint.r, tint.g, tint.b, tint.a)

        for index in 0..point_count - 1:
            rlgl.rlTexCoord2f(0.5, 0.5)
            rlgl.rlVertex2f(center.x, center.y)

            rlgl.rlTexCoord2f((texcoords + index).x, (texcoords + index).y)
            rlgl.rlVertex2f((points + index).x + center.x, (points + index).y + center.y)

            rlgl.rlTexCoord2f((texcoords + index + 1).x, (texcoords + index + 1).y)
            rlgl.rlVertex2f((points + index + 1).x + center.x, (points + index + 1).y + center.y)

        rlgl.rlEnd()
        rlgl.rlSetTexture(u32<-0)


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var texcoords = array[rl.Vector2, max_points](
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

    var points = zero[array[rl.Vector2, max_points]]()
    for index in 0..max_points:
        points[index].x = (texcoords[index].x - 0.5) * 256.0
        points[index].y = (texcoords[index].y - 0.5) * 256.0

    var positions = zero[array[rl.Vector2, max_points]]()
    for index in 0..max_points:
        positions[index] = points[index]

    let texture = rl.LoadTexture(texture_path)
    defer rl.UnloadTexture(texture)

    var angle: f32 = 0.0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        angle += 1.0

        for index in 0..max_points:
            positions[index] = points[index].rotate(angle * rm.deg2rad)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawText(title_text, 20, 20, 20, rl.DARKGRAY)

        draw_texture_poly(
            texture,
            rl.Vector2(x = f32<-rl.GetScreenWidth() / 2.0, y = f32<-rl.GetScreenHeight() / 2.0),
            ptr_of(positions[0]),
            ptr_of(texcoords[0]),
            max_points,
            rl.WHITE,
        )

    return 0

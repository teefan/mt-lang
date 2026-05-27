import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.raymath as math
import std.rlgl as rlgl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_POINTS: int = 11
const DEG_TO_RAD: float = rl.PI / 180.0


function draw_texture_poly(texture: rl.Texture2D, center: rl.Vector2, points: ref[array[rl.Vector2, MAX_POINTS]], texcoords: ref[array[rl.Vector2, MAX_POINTS]], point_count: int, tint: rl.Color) -> void:
    rlgl.set_texture(texture.id)
    rlgl.begin(rlgl.RL_TRIANGLES)
    rlgl.color4ub(tint.r, tint.g, tint.b, tint.a)

    var index = 0
    while index < point_count - 1:
        let point = read(points)[index]
        let next_point = read(points)[index + 1]
        let uv = read(texcoords)[index]
        let next_uv = read(texcoords)[index + 1]

        rlgl.tex_coord2f(0.5, 0.5)
        rlgl.vertex2f(center.x, center.y)

        rlgl.tex_coord2f(uv.x, uv.y)
        rlgl.vertex2f(point.x + center.x, point.y + center.y)

        rlgl.tex_coord2f(next_uv.x, next_uv.y)
        rlgl.vertex2f(next_point.x + center.x, next_point.y + center.y)
        index += 1

    rlgl.end()
    rlgl.set_texture(0)


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [textures] example - polygon drawing")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var texcoords = array[rl.Vector2, MAX_POINTS](
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

    var points: array[rl.Vector2, MAX_POINTS] = zero[array[rl.Vector2, MAX_POINTS]]
    var index = 0
    while index < MAX_POINTS:
        points[index].x = (texcoords[index].x - 0.5) * 256.0
        points[index].y = (texcoords[index].y - 0.5) * 256.0
        index += 1

    var positions = array[rl.Vector2, MAX_POINTS](
        points[0],
        points[1],
        points[2],
        points[3],
        points[4],
        points[5],
        points[6],
        points[7],
        points[8],
        points[9],
        points[10],
    )

    let texture = rl.load_texture("cat.png")
    defer rl.unload_texture(texture)

    var angle = float<-0.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        angle += 1.0
        index = 0
        while index < MAX_POINTS:
            positions[index] = math.vector2_rotate(points[index], angle * DEG_TO_RAD)
            index += 1

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_text("textured polygon", 20, 20, 20, rl.DARKGRAY)
        draw_texture_poly(
            texture,
            rl.Vector2(x = float<-SCREEN_WIDTH / 2.0, y = float<-SCREEN_HEIGHT / 2.0),
            ref_of(positions),
            ref_of(texcoords),
            MAX_POINTS,
            rl.WHITE,
        )

        rl.end_drawing()

    return 0

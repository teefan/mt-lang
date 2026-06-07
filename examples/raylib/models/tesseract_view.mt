import std.math as math
import std.raylib as rl
import std.raymath as rm

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const TESSERACT_POINT_COUNT: int = 16
const ROTATION_SPEED: double = 0.7853981633974483


function matching_coordinate_count(left: rl.Vector4, right: rl.Vector4) -> int:
    var count = 0
    if left.x == right.x:
        count += 1
    if left.y == right.y:
        count += 1
    if left.z == right.z:
        count += 1
    if left.w == right.w:
        count += 1
    return count


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [models] example - tesseract view")
    defer rl.close_window()

    let camera = rl.Camera3D(
        position = rl.Vector3(x = 4.0, y = 4.0, z = 4.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 0.0, z = 1.0),
        fovy = 50.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE
    )

    let tesseract = array[rl.Vector4, TESSERACT_POINT_COUNT](
        rl.Vector4(x = 1.0, y = 1.0, z = 1.0, w = 1.0),
        rl.Vector4(x = 1.0, y = 1.0, z = 1.0, w = -1.0),
        rl.Vector4(x = 1.0, y = 1.0, z = -1.0, w = 1.0),
        rl.Vector4(x = 1.0, y = 1.0, z = -1.0, w = -1.0),
        rl.Vector4(x = 1.0, y = -1.0, z = 1.0, w = 1.0),
        rl.Vector4(x = 1.0, y = -1.0, z = 1.0, w = -1.0),
        rl.Vector4(x = 1.0, y = -1.0, z = -1.0, w = 1.0),
        rl.Vector4(x = 1.0, y = -1.0, z = -1.0, w = -1.0),
        rl.Vector4(x = -1.0, y = 1.0, z = 1.0, w = 1.0),
        rl.Vector4(x = -1.0, y = 1.0, z = 1.0, w = -1.0),
        rl.Vector4(x = -1.0, y = 1.0, z = -1.0, w = 1.0),
        rl.Vector4(x = -1.0, y = 1.0, z = -1.0, w = -1.0),
        rl.Vector4(x = -1.0, y = -1.0, z = 1.0, w = 1.0),
        rl.Vector4(x = -1.0, y = -1.0, z = 1.0, w = -1.0),
        rl.Vector4(x = -1.0, y = -1.0, z = -1.0, w = 1.0),
        rl.Vector4(x = -1.0, y = -1.0, z = -1.0, w = -1.0)
    )

    var transformed: array[rl.Vector3, TESSERACT_POINT_COUNT] = zero[array[rl.Vector3, TESSERACT_POINT_COUNT]]
    var w_values: array[float, TESSERACT_POINT_COUNT] = zero[array[float, TESSERACT_POINT_COUNT]]

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let rotation = float<-(ROTATION_SPEED * rl.get_time())

        var index = 0
        while index < TESSERACT_POINT_COUNT:
            var point = tesseract[index]
            let rotated_xw = rm.vector2_rotate(rl.Vector2(x = point.x, y = point.w), rotation)
            point.x = rotated_xw.x
            point.w = rotated_xw.y

            let projection_scale = 3.0 / (3.0 - point.w)
            point.x *= projection_scale
            point.y *= projection_scale
            point.z *= projection_scale

            transformed[index] = rl.Vector3(x = point.x, y = point.y, z = point.z)
            w_values[index] = point.w
            index += 1

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        index = 0
        while index < TESSERACT_POINT_COUNT:
            rl.draw_sphere(transformed[index], float<-math.abs(double<-(w_values[index] * 0.1)), rl.RED)

            var edge_index = index + 1
            while edge_index < TESSERACT_POINT_COUNT:
                if matching_coordinate_count(tesseract[index], tesseract[edge_index]) == 3:
                    rl.draw_line_3d(transformed[index], transformed[edge_index], rl.MAROON)
                edge_index += 1

            index += 1
        rl.end_mode_3d()
        rl.end_drawing()

    return 0

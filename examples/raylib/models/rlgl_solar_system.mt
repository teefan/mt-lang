import std.math as math
import std.raylib as rl
import std.rlgl as rlgl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const SUN_RADIUS: float = 4.0
const EARTH_RADIUS: float = 0.6
const EARTH_ORBIT_RADIUS: float = 8.0
const MOON_RADIUS: float = 0.16
const MOON_ORBIT_RADIUS: float = 1.5
const DEG_TO_RAD: float = rl.PI / 180.0


function draw_sphere_basic(color: rl.Color) -> void:
    let rings = 16
    let slices = 16

    rlgl.check_render_batch_limit((rings + 2) * slices * 6)
    rlgl.begin(rlgl.RL_TRIANGLES)
    rlgl.color4ub(color.r, color.g, color.b, color.a)

    var ring = 0
    while ring < rings + 2:
        var slice = 0
        while slice < slices:
            let angle0 = DEG_TO_RAD * (270.0 + (180.0 / float<-(rings + 1)) * float<-ring)
            let angle1 = DEG_TO_RAD * (270.0 + (180.0 / float<-(rings + 1)) * float<-(ring + 1))
            let slice0 = DEG_TO_RAD * (float<-slice * 360.0 / float<-slices)
            let slice1 = DEG_TO_RAD * (float<-(slice + 1) * 360.0 / float<-slices)

            rlgl.vertex3f(
                float<-(math.cos(double<-angle0) * math.sin(double<-slice0)),
                float<-math.sin(double<-angle0),
                float<-(math.cos(double<-angle0) * math.cos(double<-slice0))
            )
            rlgl.vertex3f(
                float<-(math.cos(double<-angle1) * math.sin(double<-slice1)),
                float<-math.sin(double<-angle1),
                float<-(math.cos(double<-angle1) * math.cos(double<-slice1))
            )
            rlgl.vertex3f(
                float<-(math.cos(double<-angle1) * math.sin(double<-slice0)),
                float<-math.sin(double<-angle1),
                float<-(math.cos(double<-angle1) * math.cos(double<-slice0))
            )

            rlgl.vertex3f(
                float<-(math.cos(double<-angle0) * math.sin(double<-slice0)),
                float<-math.sin(double<-angle0),
                float<-(math.cos(double<-angle0) * math.cos(double<-slice0))
            )
            rlgl.vertex3f(
                float<-(math.cos(double<-angle0) * math.sin(double<-slice1)),
                float<-math.sin(double<-angle0),
                float<-(math.cos(double<-angle0) * math.cos(double<-slice1))
            )
            rlgl.vertex3f(
                float<-(math.cos(double<-angle1) * math.sin(double<-slice1)),
                float<-math.sin(double<-angle1),
                float<-(math.cos(double<-angle1) * math.cos(double<-slice1))
            )

            slice += 1
        ring += 1

    rlgl.end()


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [models] example - rlgl solar system")
    defer rl.close_window()

    let camera = rl.Camera3D(
        position = rl.Vector3(x = 16.0, y = 16.0, z = 16.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE
    )

    let rotation_speed = float<-0.2
    var earth_rotation = float<-0.0
    var earth_orbit_rotation = float<-0.0
    var moon_rotation = float<-0.0
    var moon_orbit_rotation = float<-0.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        earth_rotation += 5.0 * rotation_speed
        earth_orbit_rotation += (365.0 / 360.0 * (5.0 * rotation_speed) * rotation_speed)
        moon_rotation += 2.0 * rotation_speed
        moon_orbit_rotation += 8.0 * rotation_speed

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)

        rlgl.push_matrix()
        rlgl.scalef(SUN_RADIUS, SUN_RADIUS, SUN_RADIUS)
        draw_sphere_basic(rl.GOLD)
        rlgl.pop_matrix()

        rlgl.push_matrix()
        rlgl.rotatef(earth_orbit_rotation, 0.0, 1.0, 0.0)
        rlgl.translatef(EARTH_ORBIT_RADIUS, 0.0, 0.0)

        rlgl.push_matrix()
        rlgl.rotatef(earth_rotation, 0.25, 1.0, 0.0)
        rlgl.scalef(EARTH_RADIUS, EARTH_RADIUS, EARTH_RADIUS)
        draw_sphere_basic(rl.BLUE)
        rlgl.pop_matrix()

        rlgl.rotatef(moon_orbit_rotation, 0.0, 1.0, 0.0)
        rlgl.translatef(MOON_ORBIT_RADIUS, 0.0, 0.0)
        rlgl.rotatef(moon_rotation, 0.0, 1.0, 0.0)
        rlgl.scalef(MOON_RADIUS, MOON_RADIUS, MOON_RADIUS)
        draw_sphere_basic(rl.LIGHTGRAY)
        rlgl.pop_matrix()

        rl.draw_circle_3d(
            rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
            EARTH_ORBIT_RADIUS,
            rl.Vector3(x = 1.0, y = 0.0, z = 0.0),
            90.0,
            rl.fade(rl.RED, 0.5)
        )
        rl.draw_grid(20, 1.0)

        rl.end_mode_3d()

        rl.draw_text("EARTH ORBITING AROUND THE SUN!", 400, 10, 20, rl.MAROON)
        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0

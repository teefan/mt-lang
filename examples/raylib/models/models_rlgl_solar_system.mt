module examples.raylib.models.models_rlgl_solar_system

import std.c.libm as math
import std.c.raylib as rl
import std.c.rlgl as rlgl
import std.raylib.math as rm

const screen_width: i32 = 800
const screen_height: i32 = 450
const sun_radius: f32 = 4.0
const earth_radius: f32 = 0.6
const earth_orbit_radius: f32 = 8.0
const moon_radius: f32 = 0.16
const moon_orbit_radius: f32 = 1.5
const orbit_text: cstr = c"EARTH ORBITING AROUND THE SUN!"
const window_title: cstr = c"raylib [models] example - rlgl solar system"


def draw_sphere_basic(color: rl.Color) -> void:
    let rings = 16
    let slices = 16

    rlgl.rlCheckRenderBatchLimit((rings + 2) * slices * 6)
    rlgl.rlBegin(rlgl.RL_TRIANGLES)
    rlgl.rlColor4ub(color.r, color.g, color.b, color.a)

    for i in 0..rings + 2:
        let latitude0 = rm.deg2rad * (270.0 + (180.0 / f32<-(rings + 1)) * f32<-i)
        let latitude1 = rm.deg2rad * (270.0 + (180.0 / f32<-(rings + 1)) * f32<-(i + 1))
        let cos_lat0 = math.cosf(latitude0)
        let sin_lat0 = math.sinf(latitude0)
        let cos_lat1 = math.cosf(latitude1)
        let sin_lat1 = math.sinf(latitude1)

        for j in 0..slices:
            let longitude0 = rm.deg2rad * (f32<-j * 360.0 / f32<-slices)
            let longitude1 = rm.deg2rad * (f32<-(j + 1) * 360.0 / f32<-slices)
            let sin_longitude0 = math.sinf(longitude0)
            let cos_longitude0 = math.cosf(longitude0)
            let sin_longitude1 = math.sinf(longitude1)
            let cos_longitude1 = math.cosf(longitude1)

            rlgl.rlVertex3f(cos_lat0 * sin_longitude0, sin_lat0, cos_lat0 * cos_longitude0)
            rlgl.rlVertex3f(cos_lat1 * sin_longitude1, sin_lat1, cos_lat1 * cos_longitude1)
            rlgl.rlVertex3f(cos_lat1 * sin_longitude0, sin_lat1, cos_lat1 * cos_longitude0)

            rlgl.rlVertex3f(cos_lat0 * sin_longitude0, sin_lat0, cos_lat0 * cos_longitude0)
            rlgl.rlVertex3f(cos_lat0 * sin_longitude1, sin_lat0, cos_lat0 * cos_longitude1)
            rlgl.rlVertex3f(cos_lat1 * sin_longitude1, sin_lat1, cos_lat1 * cos_longitude1)

    rlgl.rlEnd()


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let camera = rl.Camera3D(
        position = rl.Vector3(x = 16.0, y = 16.0, z = 16.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    let rotation_speed: f32 = 0.2
    var earth_rotation: f32 = 0.0
    var earth_orbit_rotation: f32 = 0.0
    var moon_rotation: f32 = 0.0
    var moon_orbit_rotation: f32 = 0.0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        earth_rotation += 5.0 * rotation_speed
        earth_orbit_rotation += (365.0 / 360.0 * (5.0 * rotation_speed) * rotation_speed)
        moon_rotation += 2.0 * rotation_speed
        moon_orbit_rotation += 8.0 * rotation_speed

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode3D(camera)

        rlgl.rlPushMatrix()
        rlgl.rlScalef(sun_radius, sun_radius, sun_radius)
        draw_sphere_basic(rl.GOLD)
        rlgl.rlPopMatrix()

        rlgl.rlPushMatrix()
        rlgl.rlRotatef(earth_orbit_rotation, 0.0, 1.0, 0.0)
        rlgl.rlTranslatef(earth_orbit_radius, 0.0, 0.0)

        rlgl.rlPushMatrix()
        rlgl.rlRotatef(earth_rotation, 0.25, 1.0, 0.0)
        rlgl.rlScalef(earth_radius, earth_radius, earth_radius)
        draw_sphere_basic(rl.BLUE)
        rlgl.rlPopMatrix()

        rlgl.rlRotatef(moon_orbit_rotation, 0.0, 1.0, 0.0)
        rlgl.rlTranslatef(moon_orbit_radius, 0.0, 0.0)
        rlgl.rlRotatef(moon_rotation, 0.0, 1.0, 0.0)
        rlgl.rlScalef(moon_radius, moon_radius, moon_radius)
        draw_sphere_basic(rl.LIGHTGRAY)
        rlgl.rlPopMatrix()

        rl.DrawCircle3D(rl.Vector3(x = 0.0, y = 0.0, z = 0.0), earth_orbit_radius, rl.Vector3(x = 1.0, y = 0.0, z = 0.0), 90.0, rl.Fade(rl.RED, 0.5))
        rl.DrawGrid(20, 1.0)

        rl.EndMode3D()
        rl.DrawText(orbit_text, 400, 10, 20, rl.MAROON)
        rl.DrawFPS(10, 10)

    return 0

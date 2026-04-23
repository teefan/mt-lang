module examples.raylib.core.core_3d_camera_fps

import std.c.raylib as rl
import std.math as math
import std.raylib.math as rm

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [core] example - 3d camera fps"
const gravity: f32 = 32.0
const max_speed: f32 = 20.0
const crouch_speed: f32 = 5.0
const jump_force: f32 = 12.0
const max_accel: f32 = 150.0
const friction: f32 = 0.86
const air_drag: f32 = 0.98
const control: f32 = 15.0
const crouch_height: f32 = 0.0
const stand_height: f32 = 1.0
const bottom_height: f32 = 0.5
const step_rotation: f32 = 0.01
const bob_side: f32 = 0.1
const bob_up: f32 = 0.15

struct Body:
    position: rl.Vector3
    velocity: rl.Vector3
    dir: rl.Vector3
    is_grounded: bool

struct FpsState:
    look_rotation: rl.Vector2
    head_timer: f32
    walk_lerp: f32
    head_lerp: f32
    lean: rl.Vector2

methods Body:
    edit def update(rot: f32, side: i32, forward: i32, jump_pressed: bool, crouch_hold: bool) -> void:
        var input = rl.Vector2(x = side, y = -forward)
        if side != 0 and forward != 0:
            input = input.normalize()

        let delta = rl.GetFrameTime()

        if not this.is_grounded:
            this.velocity.y -= gravity * delta

        if this.is_grounded and jump_pressed:
            this.velocity.y = jump_force
            this.is_grounded = false

        let up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0)
        let front = rl.Vector3(x = 0.0, y = 0.0, z = 1.0).rotate_by_axis_angle(up, rot)
        let right = rl.Vector3(x = 1.0, y = 0.0, z = 0.0).rotate_by_axis_angle(up, rot)
        let desired_dir = rl.Vector3(
            x = input.x * right.x + input.y * front.x,
            y = 0.0,
            z = input.x * right.z + input.y * front.z,
        )
        this.dir = this.dir.lerp(desired_dir, control * delta)

        var decel = air_drag
        if this.is_grounded:
            decel = friction
        var hvel = rl.Vector3(x = this.velocity.x * decel, y = 0.0, z = this.velocity.z * decel)

        let hvel_length = hvel.length()
        if hvel_length < max_speed * 0.01:
            hvel = rm.Vector3.zero()

        let speed = hvel.dot(this.dir)
        var active_max_speed = max_speed
        if crouch_hold:
            active_max_speed = crouch_speed
        let accel = rm.clamp(active_max_speed - speed, 0.0, max_accel * delta)
        hvel.x += this.dir.x * accel
        hvel.z += this.dir.z * accel

        this.velocity.x = hvel.x
        this.velocity.z = hvel.z

        this.position.x += this.velocity.x * delta
        this.position.y += this.velocity.y * delta
        this.position.z += this.velocity.z * delta

        if this.position.y <= 0.0:
            this.position.y = 0.0
            this.velocity.y = 0.0
            this.is_grounded = true

methods FpsState:
    edit def update_camera(camera: ptr[rl.Camera3D], body: Body) -> void:
        let up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0)
        let target_offset = rl.Vector3(x = 0.0, y = 0.0, z = -1.0)

        let yaw = target_offset.rotate_by_axis_angle(up, this.look_rotation.x)

        var max_angle_up = up.angle(yaw)
        max_angle_up -= 0.001
        if -this.look_rotation.y > max_angle_up:
            this.look_rotation.y = -max_angle_up

        var max_angle_down = up.negate().angle(yaw)
        max_angle_down *= -1.0
        max_angle_down += 0.001
        if -this.look_rotation.y < max_angle_down:
            this.look_rotation.y = -max_angle_down

        let right = yaw.cross(up).normalize()
        var pitch_angle = -this.look_rotation.y - this.lean.y
        pitch_angle = rm.clamp(pitch_angle, -math.pi / 2.0 + 0.0001, math.pi / 2.0 - 0.0001)
        let pitch = yaw.rotate_by_axis_angle(right, pitch_angle)

        let head_sin = rm.sin(this.head_timer * math.pi)
        let head_cos = rm.cos(this.head_timer * math.pi)
        unsafe:
            camera->up = up.rotate_by_axis_angle(pitch, head_sin * step_rotation + this.lean.x)

        var bobbing = right.scale(head_sin * bob_side)
        bobbing.y = rm.abs(head_cos * bob_up)

        unsafe:
            camera->position = camera->position.add(bobbing.scale(this.walk_lerp))
            camera->target = camera->position.add(pitch)

def draw_level() -> void:
    let floor_extent = 25
    let tile_size: f32 = 5.0
    let tile_color_one = rl.Color(r = 150, g = 200, b = 200, a = 255)

    var y = -floor_extent
    while y < floor_extent:
        var x = -floor_extent
        while x < floor_extent:
            if (x + y) % 2 == 0:
                var tile_color = rl.LIGHTGRAY
                if x % 2 != 0:
                    tile_color = tile_color_one
                rl.DrawPlane(rl.Vector3(x = x * tile_size, y = 0.0, z = y * tile_size), rl.Vector2(x = tile_size, y = tile_size), tile_color)
            x += 1
        y += 1

    let tower_size = rl.Vector3(x = 16.0, y = 32.0, z = 16.0)
    let tower_color = rl.Color(r = 150, g = 200, b = 200, a = 255)

    var tower_position = rl.Vector3(x = 16.0, y = 16.0, z = 16.0)
    rl.DrawCubeV(tower_position, tower_size, tower_color)
    rl.DrawCubeWiresV(tower_position, tower_size, rl.DARKBLUE)

    tower_position.x = -tower_position.x
    rl.DrawCubeV(tower_position, tower_size, tower_color)
    rl.DrawCubeWiresV(tower_position, tower_size, rl.DARKBLUE)

    tower_position.z = -tower_position.z
    rl.DrawCubeV(tower_position, tower_size, tower_color)
    rl.DrawCubeWiresV(tower_position, tower_size, rl.DARKBLUE)

    tower_position.x = -tower_position.x
    rl.DrawCubeV(tower_position, tower_size, tower_color)
    rl.DrawCubeWiresV(tower_position, tower_size, rl.DARKBLUE)

    rl.DrawSphere(rl.Vector3(x = 300.0, y = 300.0, z = 0.0), 100.0, rl.RED)

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let sensitivity = rl.Vector2(x = 0.001, y = 0.001)
    var player = Body(
        position = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        velocity = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        dir = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        is_grounded = false,
    )
    var state = FpsState(
        look_rotation = rl.Vector2(x = 0.0, y = 0.0),
        head_timer = 0.0,
        walk_lerp = 0.0,
        head_lerp = stand_height,
        lean = rl.Vector2(x = 0.0, y = 0.0),
    )

    var camera = rl.Camera3D(
        position = rl.Vector3(
            x = player.position.x,
            y = player.position.y + (bottom_height + state.head_lerp),
            z = player.position.z,
        ),
        target = rl.Vector3(x = 0.0, y = 0.0, z = -1.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 60.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    state.update_camera(&camera, player)
    rl.DisableCursor()
    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        let mouse_delta = rl.GetMouseDelta()
        state.look_rotation.x -= mouse_delta.x * sensitivity.x
        state.look_rotation.y += mouse_delta.y * sensitivity.y

        var sideway = 0
        if rl.IsKeyDown(rl.KeyboardKey.KEY_D):
            sideway += 1
        if rl.IsKeyDown(rl.KeyboardKey.KEY_A):
            sideway -= 1

        var forward = 0
        if rl.IsKeyDown(rl.KeyboardKey.KEY_W):
            forward += 1
        if rl.IsKeyDown(rl.KeyboardKey.KEY_S):
            forward -= 1

        let crouching = rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT_CONTROL)
        player.update(state.look_rotation.x, sideway, forward, rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE), crouching)

        let delta = rl.GetFrameTime()
        var target_head_lerp = stand_height
        if crouching:
            target_head_lerp = crouch_height
        state.head_lerp = rm.lerp(state.head_lerp, target_head_lerp, 20.0 * delta)
        camera.position = rl.Vector3(
            x = player.position.x,
            y = player.position.y + (bottom_height + state.head_lerp),
            z = player.position.z,
        )

        if player.is_grounded and (forward != 0 or sideway != 0):
            state.head_timer += delta * 3.0
            state.walk_lerp = rm.lerp(state.walk_lerp, 1.0, 10.0 * delta)
            camera.fovy = rm.lerp(camera.fovy, 55.0, 5.0 * delta)
        else:
            state.walk_lerp = rm.lerp(state.walk_lerp, 0.0, 10.0 * delta)
            camera.fovy = rm.lerp(camera.fovy, 60.0, 5.0 * delta)

        state.lean.x = rm.lerp(state.lean.x, cast[f32](sideway) * 0.02, 10.0 * delta)
        state.lean.y = rm.lerp(state.lean.y, cast[f32](forward) * 0.015, 10.0 * delta)

        state.update_camera(&camera, player)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode3D(camera)
        draw_level()
        rl.EndMode3D()

        rl.DrawRectangle(5, 5, 330, 75, rl.Fade(rl.SKYBLUE, 0.5))
        rl.DrawRectangleLines(5, 5, 330, 75, rl.BLUE)
        rl.DrawText(c"Camera controls:", 15, 15, 10, rl.BLACK)
        rl.DrawText(c"- Move keys: W, A, S, D, Space, Left-Ctrl", 15, 30, 10, rl.BLACK)
        rl.DrawText(c"- Look around: arrow keys or mouse", 15, 45, 10, rl.BLACK)
        rl.DrawText(c"- Movement speed affects camera bobbing", 15, 60, 10, rl.BLACK)

    return 0

import std.math as math
import std.raylib as rl
import std.raymath as rm

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GRAVITY: float = 32.0
const MAX_SPEED: float = 20.0
const CROUCH_SPEED: float = 5.0
const JUMP_FORCE: float = 12.0
const MAX_ACCEL: float = 150.0
const FRICTION: float = 0.86
const AIR_DRAG: float = 0.98
const CONTROL: float = 15.0
const CROUCH_HEIGHT: float = 0.0
const STAND_HEIGHT: float = 1.0
const BOTTOM_HEIGHT: float = 0.5
const MOUSE_SENSITIVITY_X: float = 0.001
const MOUSE_SENSITIVITY_Y: float = 0.001
const HEAD_LERP_SPEED: float = 20.0
const WALK_LERP_SPEED: float = 10.0
const FOV_LERP_SPEED: float = 5.0
const WALK_FOV: float = 55.0
const IDLE_FOV: float = 60.0
const HEAD_TIMER_SPEED: float = 3.0
const LEAN_X_FACTOR: float = 0.02
const LEAN_Y_FACTOR: float = 0.015
const HEAD_STEP_ROTATION: float = 0.01
const HEAD_BOB_SIDE: float = 0.1
const HEAD_BOB_UP: float = 0.15
const SPEED_EPSILON: float = 0.01
const ANGLE_EPSILON: float = 0.0001
const CLAMP_EPSILON: float = 0.001
const HALF_PI: float = rl.PI / float<-2

struct Body:
    position: rl.Vector3
    velocity: rl.Vector3
    dir: rl.Vector3
    is_grounded: bool

var player: Body = Body(
    position = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
    velocity = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
    dir = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
    is_grounded = false
)
var look_rotation: rl.Vector2 = rl.Vector2(x = 0.0, y = 0.0)
var head_timer: float = 0.0
var walk_lerp: float = 0.0
var head_lerp: float = STAND_HEIGHT
var lean: rl.Vector2 = rl.Vector2(x = 0.0, y = 0.0)


function abs_float(value: float) -> float:
    return float<-math.abs(double<-value)


function update_body(
    body: ref[Body],
    rot: float,
    side: int,
    forward: int,
    jump_pressed: bool,
    crouch_hold: bool
) -> void:
    let input = rl.Vector2(x = float<-side, y = -float<-forward)
    let delta = rl.get_frame_time()
    let is_grounded = unsafe: read(body).is_grounded

    if not is_grounded:
        unsafe: read(body).velocity.y -= GRAVITY * delta

    if is_grounded and jump_pressed:
        unsafe:
            read(body).velocity.y = JUMP_FORCE
            read(body).is_grounded = false

    let front = rl.Vector3(x = float<-math.sin(double<-rot), y = 0.0, z = float<-math.cos(double<-rot))
    let right = rl.Vector3(x = float<-math.cos(double<-(-rot)), y = 0.0, z = float<-math.sin(double<-(-rot)))
    let desired_dir = rl.Vector3(
        x = input.x * right.x + input.y * front.x,
        y = 0.0,
        z = input.x * right.z + input.y * front.z
    )
    let updated_dir = rm.vector3_lerp(unsafe: read(body).dir, desired_dir, CONTROL * delta)
    unsafe: read(body).dir = updated_dir

    let decel = if is_grounded: FRICTION else: AIR_DRAG
    let body_velocity = unsafe: read(body).velocity
    var horizontal_velocity = rl.Vector3(x = body_velocity.x * decel, y = 0.0, z = body_velocity.z * decel)

    if rm.vector3_length(horizontal_velocity) < MAX_SPEED * SPEED_EPSILON:
        horizontal_velocity = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)

    let speed = rm.vector3_dot_product(horizontal_velocity, updated_dir)
    let max_speed = if crouch_hold: CROUCH_SPEED else: MAX_SPEED
    let accel = rm.clamp(max_speed - speed, 0.0, MAX_ACCEL * delta)
    horizontal_velocity.x += updated_dir.x * accel
    horizontal_velocity.z += updated_dir.z * accel

    unsafe:
        read(body).velocity.x = horizontal_velocity.x
        read(body).velocity.z = horizontal_velocity.z
        read(body).position.x += read(body).velocity.x * delta
        read(body).position.y += read(body).velocity.y * delta
        read(body).position.z += read(body).velocity.z * delta

    let position_y = unsafe: read(body).position.y
    if position_y <= 0.0:
        unsafe:
            read(body).position.y = 0.0
            read(body).velocity.y = 0.0
            read(body).is_grounded = true


function update_camera_fps(camera: ref[rl.Camera3D]) -> void:
    let up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0)
    let target_offset = rl.Vector3(x = 0.0, y = 0.0, z = -1.0)
    let yaw = rm.vector3_rotate_by_axis_angle(target_offset, up, look_rotation.x)

    let max_angle_up = rm.vector3_angle(up, yaw) - CLAMP_EPSILON
    if -look_rotation.y > max_angle_up:
        look_rotation.y = -max_angle_up

    var max_angle_down = rm.vector3_angle(rm.vector3_negate(up), yaw)
    max_angle_down *= -1.0
    max_angle_down += CLAMP_EPSILON
    if -look_rotation.y < max_angle_down:
        look_rotation.y = -max_angle_down

    let right = rm.vector3_normalize(rm.vector3_cross_product(yaw, up))
    var pitch_angle = -look_rotation.y - lean.y
    pitch_angle = rm.clamp(pitch_angle, -HALF_PI + ANGLE_EPSILON, HALF_PI - ANGLE_EPSILON)
    let pitch = rm.vector3_rotate_by_axis_angle(yaw, right, pitch_angle)

    let head_sin = float<-math.sin(double<-(head_timer * rl.PI))
    let head_cos = float<-math.cos(double<-(head_timer * rl.PI))
    unsafe: read(camera).up = rm.vector3_rotate_by_axis_angle(up, pitch, head_sin * HEAD_STEP_ROTATION + lean.x)

    var bobbing = rm.vector3_scale(right, head_sin * HEAD_BOB_SIDE)
    bobbing.y = abs_float(head_cos * HEAD_BOB_UP)
    unsafe:
        read(camera).position = rm.vector3_add(read(camera).position, rm.vector3_scale(bobbing, walk_lerp))
        read(camera).target = rm.vector3_add(read(camera).position, pitch)


function draw_level() -> void:
    let tile_color = rl.Color(r = ubyte<-150, g = ubyte<-200, b = ubyte<-200, a = ubyte<-255)
    let tower_size = rl.Vector3(x = 16.0, y = 32.0, z = 16.0)

    var y = -25
    while y < 25:
        var x = -25
        while x < 25:
            let position = rl.Vector3(x = float<-x * 5.0, y = 0.0, z = float<-y * 5.0)
            if (y % 2 != 0) and (x % 2 != 0):
                rl.draw_plane(position, rl.Vector2(x = 5.0, y = 5.0), tile_color)
            else if (y % 2 == 0) and (x % 2 == 0):
                rl.draw_plane(position, rl.Vector2(x = 5.0, y = 5.0), rl.LIGHTGRAY)
            x += 1
        y += 1

    var tower_position = rl.Vector3(x = 16.0, y = 16.0, z = 16.0)
    rl.draw_cube_v(tower_position, tower_size, tile_color)
    rl.draw_cube_wires_v(tower_position, tower_size, rl.DARKBLUE)
    tower_position.x *= -1.0
    rl.draw_cube_v(tower_position, tower_size, tile_color)
    rl.draw_cube_wires_v(tower_position, tower_size, rl.DARKBLUE)
    tower_position.z *= -1.0
    rl.draw_cube_v(tower_position, tower_size, tile_color)
    rl.draw_cube_wires_v(tower_position, tower_size, rl.DARKBLUE)
    tower_position.x *= -1.0
    rl.draw_cube_v(tower_position, tower_size, tile_color)
    rl.draw_cube_wires_v(tower_position, tower_size, rl.DARKBLUE)

    rl.draw_sphere(
        rl.Vector3(x = 300.0, y = 300.0, z = 0.0),
        100.0,
        rl.Color(r = ubyte<-255, g = ubyte<-0, b = ubyte<-0, a = ubyte<-255)
    )


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - 3d camera fps")
    defer rl.close_window()

    var camera = rl.Camera3D(
        position = rl.Vector3(
            x = player.position.x,
            y = player.position.y + (BOTTOM_HEIGHT + head_lerp),
            z = player.position.z
        ),
        target = rl.Vector3(x = 0.0, y = 0.0, z = -1.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = IDLE_FOV,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE
    )

    update_camera_fps(ref_of(camera))
    rl.disable_cursor()
    rl.set_target_fps(60)

    while not rl.window_should_close():
        let mouse_delta = rl.get_mouse_delta()
        look_rotation.x -= mouse_delta.x * MOUSE_SENSITIVITY_X
        look_rotation.y += mouse_delta.y * MOUSE_SENSITIVITY_Y

        var sideway = 0
        if rl.is_key_down(rl.KeyboardKey.KEY_D):
            sideway += 1
        if rl.is_key_down(rl.KeyboardKey.KEY_A):
            sideway -= 1

        var forward = 0
        if rl.is_key_down(rl.KeyboardKey.KEY_W):
            forward += 1
        if rl.is_key_down(rl.KeyboardKey.KEY_S):
            forward -= 1

        let crouching = rl.is_key_down(rl.KeyboardKey.KEY_LEFT_CONTROL)
        update_body(
            ref_of(player),
            look_rotation.x,
            sideway,
            forward,
            rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE),
            crouching
        )

        let delta = rl.get_frame_time()
        head_lerp = rm.lerp(head_lerp, if crouching: CROUCH_HEIGHT else: STAND_HEIGHT, HEAD_LERP_SPEED * delta)
        camera.position = rl.Vector3(
            x = player.position.x,
            y = player.position.y + (BOTTOM_HEIGHT + head_lerp),
            z = player.position.z
        )

        if player.is_grounded and (forward != 0 or sideway != 0):
            head_timer += delta * HEAD_TIMER_SPEED
            walk_lerp = rm.lerp(walk_lerp, 1.0, WALK_LERP_SPEED * delta)
            camera.fovy = rm.lerp(camera.fovy, WALK_FOV, FOV_LERP_SPEED * delta)
        else:
            walk_lerp = rm.lerp(walk_lerp, 0.0, WALK_LERP_SPEED * delta)
            camera.fovy = rm.lerp(camera.fovy, IDLE_FOV, FOV_LERP_SPEED * delta)

        lean.x = rm.lerp(lean.x, float<-sideway * LEAN_X_FACTOR, WALK_LERP_SPEED * delta)
        lean.y = rm.lerp(lean.y, float<-forward * LEAN_Y_FACTOR, WALK_LERP_SPEED * delta)
        update_camera_fps(ref_of(camera))

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)
        rl.begin_mode_3d(camera)
        draw_level()
        rl.end_mode_3d()

        rl.draw_rectangle(5, 5, 330, 75, rl.fade(rl.SKYBLUE, 0.5))
        rl.draw_rectangle_lines(5, 5, 330, 75, rl.BLUE)
        rl.draw_text("Camera controls:", 15, 15, 10, rl.BLACK)
        rl.draw_text("- Move keys: W, A, S, D, Space, Left-Ctrl", 15, 30, 10, rl.BLACK)
        rl.draw_text("- Look around: arrow keys or mouse", 15, 45, 10, rl.BLACK)
        let velocity_len = rm.vector2_length(rl.Vector2(x = player.velocity.x, y = player.velocity.z))
        let velocity_text = rl.text_format("- Velocity Len: (%06.3f)", velocity_len)
        rl.draw_text(velocity_text, 15, 60, 10, rl.BLACK)
        rl.end_drawing()

    return 0

## Shared machinery for the box3d sample ports.
##
## Ported from third_party/box3d-upstream/samples (sample.cpp, gfx/camera.h)
## to Milk Tea. Provides:
##   - Vec3 / Quat / Transform math helpers (mirrors box3d math_functions.h)
##   - a raylib-backed 3D debug renderer: shapes are rendered manually from a
##     body list each sample registers, while b3World_Draw supplies the joint,
##     contact, bounds, and string overlays through simple callbacks
##   - an orbit camera (yaw / pitch / distance around a target)
##   - ray-based mouse dragging (box3d has no mouse joint)
##   - deterministic XorShift32 randomness (RAND_SEED = 12345)
##   - a Sample interface plus a run() driver that owns the window/step/draw loop
import std.box3d as b3
import std.math as math
import std.raylib as rl
import std.str as str_mod

const SCREEN_WIDTH: int = 1280
const SCREEN_HEIGHT: int = 720
public const HERTZ: float = 60.0
const SUB_STEP_COUNT: int = 4
const MAX_BODIES: int = 512
const MAX_SHAPES: int = 16
public const DEG_TO_RAD: float = 0.017453292519943295

# =============================================================================
# Vec3 math helpers
# =============================================================================
extending b3.Vec3:
    public function add(other: b3.Vec3) -> b3.Vec3:
        return b3.Vec3(x = this.x + other.x, y = this.y + other.y, z = this.z + other.z)

    public function sub(other: b3.Vec3) -> b3.Vec3:
        return b3.Vec3(x = this.x - other.x, y = this.y - other.y, z = this.z - other.z)

    public function scale(value: float) -> b3.Vec3:
        return b3.Vec3(x = this.x * value, y = this.y * value, z = this.z * value)

    public function mul_comp(other: b3.Vec3) -> b3.Vec3:
        return b3.Vec3(x = this.x * other.x, y = this.y * other.y, z = this.z * other.z)

    public function neg() -> b3.Vec3:
        return b3.Vec3(x = -this.x, y = -this.y, z = -this.z)

    public function dot(other: b3.Vec3) -> float:
        return this.x * other.x + this.y * other.y + this.z * other.z

    public function cross(other: b3.Vec3) -> b3.Vec3:
        return b3.Vec3(x = this.y * other.z - this.z * other.y, y = this.z * other.x - this.x * other.z, z = this.x * other.y - this.y * other.x)

    public function length() -> float:
        return float<-math.sqrt(double<-(this.x * this.x + this.y * this.y + this.z * this.z))

    public function length_sq() -> float:
        return this.x * this.x + this.y * this.y + this.z * this.z

    public function normalize() -> b3.Vec3:
        let len = this.length()
        if len < 0.000001:
            return b3.b3Vec3_zero
        return this.scale(1.0 / len)

# =============================================================================
# Quat math helpers (from box3d math_functions.h inline functions)
# =============================================================================
public function quat_from_axis_angle(axis: b3.Vec3, radians: float) -> b3.Quat:
    let half = 0.5 * radians
    let s = math.sin(double<-half)
    let c = math.cos(double<-half)
    return b3.Quat(v = axis.scale(float<-s), s = float<-c)

public function mul_quat(a: b3.Quat, b: b3.Quat) -> b3.Quat:
    let va = a.v
    let vb = b.v
    return b3.Quat(v = va.scale(b.s).add(vb.scale(a.s)).add(va.cross(vb)), s = a.s * b.s - va.dot(vb))

public function mul_quat_vec(q: b3.Quat, v: b3.Vec3) -> b3.Vec3:
    let t = q.v.cross(v).scale(2.0)
    return v.add(t.scale(q.s)).add(q.v.cross(t))

public function quat_axis_angle(q: b3.Quat) -> (b3.Vec3, float):
    let clamped = if q.s > 1.0: 1.0 else: if q.s < -1.0: -1.0 else: q.s
    let angle = 2.0 * float<-math.acos(double<-clamped)
    let vlen = q.v.length()
    if vlen > 0.0001:
        return (q.v.scale(1.0 / vlen), angle)
    return (b3.Vec3(x = 1.0, y = 0.0, z = 0.0), 0.0)

# =============================================================================
# Transform math helpers
# =============================================================================
extending b3.Transform:
    public function mul_point(p: b3.Vec3) -> b3.Vec3:
        return this.p.add(mul_quat_vec(this.q, p))

    public function rotate(v: b3.Vec3) -> b3.Vec3:
        return mul_quat_vec(this.q, v)

public function mul_transforms(a: b3.Transform, b: b3.Transform) -> b3.Transform:
    return b3.Transform(p = a.p.add(mul_quat_vec(a.q, b.p)), q = mul_quat(a.q, b.q))

# =============================================================================
# Vec3 <-> raylib Vector3
# =============================================================================
public function to_rl_v3(v: b3.Vec3) -> rl.Vector3:
    return rl.Vector3(x = v.x, y = v.y, z = v.z)

public function from_rl_v3(v: rl.Vector3) -> b3.Vec3:
    return b3.Vec3(x = v.x, y = v.y, z = v.z)

# =============================================================================
# Hex color conversion (b3HexColor is 0xRRGGBB)
# =============================================================================
public function hex_to_color(color: b3.HexColor) -> rl.Color:
    let value = uint<-color
    return rl.Color(r = ubyte<-(value >> 16 & 0xFFu), g = ubyte<-(value >> 8 & 0xFFu), b = ubyte<-(value & 0xFFu), a = 255ub)

# =============================================================================
# Camera (orbit)
# =============================================================================
struct Camera:
    target: b3.Vec3
    yaw: float
    pitch: float
    distance: float
    fov: float

# degrees around Y
# degrees above horizontal
public function default_camera(target: b3.Vec3, distance: float) -> Camera:
    return Camera(target = target, yaw = 30.0, pitch = 20.0, distance = distance, fov = 45.0)

extending Camera:
    public function to_raylib() -> rl.Camera3D:
        let yaw_r = this.yaw * DEG_TO_RAD
        let pitch_r = this.pitch * DEG_TO_RAD
        let cp = math.cos(double<-pitch_r)
        let dir = b3.Vec3(x = float<-(math.cos(double<-yaw_r) * cp), y = float<-math.sin(double<-pitch_r), z = float<-(math.sin(double<-yaw_r) * cp))
        let pos = this.target.add(dir.scale(this.distance))
        return rl.Camera3D(position = to_rl_v3(pos), target = to_rl_v3(this.target), up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0), fovy = this.fov, projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE)

# =============================================================================
# Module state
# =============================================================================
var s_camera: Camera
var s_world_id: b3.WorldId = b3.b3_nullWorldId
var s_debug_draw: b3.DebugDraw
var s_cube_model: rl.Model
var s_paused: bool = false
var s_single_step: bool = false
var s_stepped: bool = false
var s_drag_enabled: bool = true
var s_drag_body: b3.BodyId = b3.b3_nullBodyId
var s_drag_grab_offset: b3.Vec3
var s_bodies: array[b3.BodyId, MAX_BODIES]
var s_body_count: int = 0
var s_dummy_context: int = 0
var s_text_line: int = 0

public function track_body(body: b3.BodyId) -> void:
    if s_body_count < MAX_BODIES:
        s_bodies[s_body_count] = body
        s_body_count += 1

public function enable_drag(enable: bool) -> void:
    s_drag_enabled = enable

public function mouse_world_point() -> b3.Vec3:
    return s_drag_point

public function set_camera_target(target: b3.Vec3) -> void:
    s_camera.target = target

public function paused() -> bool:
    return s_paused

public function stepped() -> bool:
    return s_stepped

var s_drag_point: b3.Vec3

# =============================================================================
# Debug draw callbacks (fed to b3World_Draw for joints, contacts, strings, ...)
# =============================================================================
function debug_draw_segment(p1: b3.Vec3, p2: b3.Vec3, color: b3.HexColor, _context: ptr[void]) -> void:
    rl.draw_line_3d(to_rl_v3(p1), to_rl_v3(p2), hex_to_color(color))

function debug_draw_point(p: b3.Vec3, size: float, color: b3.HexColor, _context: ptr[void]) -> void:
    let _s = size
    rl.draw_sphere(to_rl_v3(p), 0.15, hex_to_color(color))

function debug_draw_transform(transform: b3.Transform, _context: ptr[void]) -> void:
    let scale = 0.5
    let p = transform.p
    let axis_x = transform.rotate(b3.Vec3(x = 1.0, y = 0.0, z = 0.0))
    let axis_y = transform.rotate(b3.Vec3(x = 0.0, y = 1.0, z = 0.0))
    let axis_z = transform.rotate(b3.Vec3(x = 0.0, y = 0.0, z = 1.0))
    rl.draw_line_3d(to_rl_v3(p), to_rl_v3(p.add(axis_x.scale(scale))), rl.RED)
    rl.draw_line_3d(to_rl_v3(p), to_rl_v3(p.add(axis_y.scale(scale))), rl.GREEN)
    rl.draw_line_3d(to_rl_v3(p), to_rl_v3(p.add(axis_z.scale(scale))), rl.BLUE)

function debug_draw_sphere(p: b3.Vec3, radius: float, color: b3.HexColor, alpha: float, _context: ptr[void]) -> void:
    let _a = alpha
    rl.draw_sphere_wires(to_rl_v3(p), radius, 6, 12, hex_to_color(color))

function debug_draw_capsule(p1: b3.Vec3, p2: b3.Vec3, radius: float, color: b3.HexColor, alpha: float, _context: ptr[void]) -> void:
    let _a = alpha
    rl.draw_cylinder_wires_ex(to_rl_v3(p1), to_rl_v3(p2), radius, radius, 12, hex_to_color(color))

function debug_draw_bounds(aabb: b3.AABB, color: b3.HexColor, _context: ptr[void]) -> void:
    let lower = aabb.lowerBound
    let upper = aabb.upperBound
    let size = upper.sub(lower)
    let center = lower.add(upper).scale(0.5)
    draw_oriented_box(center, b3.b3Quat_identity, size, color)

function debug_draw_box(extents: b3.Vec3, transform: b3.Transform, color: b3.HexColor, _context: ptr[void]) -> void:
    draw_oriented_box(transform.p, transform.q, extents.scale(2.0), color)

function debug_draw_string(p: b3.Vec3, text: cstr, color: b3.HexColor, _context: ptr[void]) -> void:
    let screen = rl.get_world_to_screen(to_rl_v3(p), s_camera.to_raylib())
    let label = str_mod.cstr_as_str(text)
    rl.draw_text_ex(rl.get_font_default(), label, screen, 20.0, 1.0, hex_to_color(color))

function draw_oriented_box(center: b3.Vec3, rotation: b3.Quat, size: b3.Vec3, color: b3.HexColor) -> void:
    let (axis, angle) = quat_axis_angle(rotation)
    rl.draw_model_ex(s_cube_model, to_rl_v3(center), to_rl_v3(axis), angle, to_rl_v3(size), hex_to_color(color))

function setup_debug_draw() -> void:
    let default_draw = b3.default_debug_draw()
    s_debug_draw = default_draw
    s_debug_draw.DrawSegmentFcn = debug_draw_segment
    s_debug_draw.DrawPointFcn = debug_draw_point
    s_debug_draw.DrawTransformFcn = debug_draw_transform
    s_debug_draw.DrawSphereFcn = debug_draw_sphere
    s_debug_draw.DrawCapsuleFcn = debug_draw_capsule
    s_debug_draw.DrawBoundsFcn = debug_draw_bounds
    s_debug_draw.DrawBoxFcn = debug_draw_box
    s_debug_draw.DrawStringFcn = debug_draw_string
    s_debug_draw.drawJoints = true
    s_debug_draw.drawContacts = true

# =============================================================================
# Shape / body rendering
# =============================================================================
function shape_color(body: b3.BodyId) -> b3.HexColor:
    let body_type = b3.body_get_type(body)
    match body_type:
        b3.BodyType.b3_staticBody:
            return b3.HexColor.b3_colorDarkGray
        b3.BodyType.b3_kinematicBody:
            return b3.HexColor.b3_colorSteelBlue
        _:
            if b3.body_is_awake(body):
                return b3.HexColor.b3_colorTan
            return b3.HexColor.b3_colorLightSlateGray

function draw_shape(shape: b3.ShapeId, transform: b3.WorldTransform, body: b3.BodyId) -> void:
    let shape_type = b3.shape_get_type(shape)
    let color = shape_color(body)
    match shape_type:
        b3.ShapeType.b3_sphereShape:
            let sphere = b3.shape_get_sphere(shape)
            let center = transform.mul_point(sphere.center)
            rl.draw_sphere(to_rl_v3(center), sphere.radius, hex_to_color(color))
            rl.draw_sphere_wires(to_rl_v3(center), sphere.radius, 6, 12, hex_to_color(b3.HexColor.b3_colorDarkGray))
        b3.ShapeType.b3_capsuleShape:
            let capsule = b3.shape_get_capsule(shape)
            let p1 = transform.mul_point(capsule.center1)
            let p2 = transform.mul_point(capsule.center2)
            rl.draw_capsule(to_rl_v3(p1), to_rl_v3(p2), capsule.radius, 6, 8, hex_to_color(color))
        b3.ShapeType.b3_hullShape:
            let hull = b3.shape_get_hull(shape)
            unsafe:
                let data = read(hull)
                let lower = data.aabb.lowerBound
                let upper = data.aabb.upperBound
                let center_local = lower.add(upper).scale(0.5)
                let size = upper.sub(lower)
                let center = transform.mul_point(center_local)
                draw_oriented_box(center, transform.q, size, color)
        _:
            let aabb = b3.shape_get_aabb(shape)
            let lower = aabb.lowerBound
            let upper = aabb.upperBound
            let size = upper.sub(lower)
            let center = lower.add(upper).scale(0.5)
            draw_oriented_box(center, b3.b3Quat_identity, size, b3.HexColor.b3_colorDarkGray)

function draw_body(body: b3.BodyId) -> void:
    if not b3.body_is_valid(body):
        return
    let transform = b3.body_get_transform(body)
    let shape_count = b3.body_get_shape_count(body)
    if shape_count <= 0:
        return
    var shapes: array[b3.ShapeId, MAX_SHAPES]
    let count = b3.body_get_shapes(body, ptr_of(shapes[0]), MAX_SHAPES)
    var index = 0
    while index < count:
        draw_shape(shapes[index], transform, body)
        index += 1

public function draw_world() -> void:
    var index = 0
    while index < s_body_count:
        draw_body(s_bodies[index])
        index += 1
    b3.world_draw(s_world_id, s_debug_draw, ulong<-0xFFFFFFFF)

# =============================================================================
# Mouse picking (ray-based drag; box3d has no mouse joint)
# =============================================================================
function ray_ground_point(ray: rl.Ray) -> b3.Vec3:
    let origin = from_rl_v3(ray.position)
    let direction = from_rl_v3(ray.direction)
    if abs_float(direction.y) < 0.0001:
        return origin
    let t = -origin.y / direction.y
    return b3.Vec3(x = origin.x + t * direction.x, y = 0.0, z = origin.z + t * direction.z)

function mouse_down(ray: rl.Ray) -> void:
    if s_drag_body != b3.b3_nullBodyId:
        return
    let origin = from_rl_v3(ray.position)
    let direction = from_rl_v3(ray.direction)
    let filter = b3.default_query_filter()
    let result = b3.world_cast_ray_closest(s_world_id, origin, direction.scale(1000.0), filter)
    if not result.hit:
        return
    let picked = b3.shape_get_body(result.shapeId)
    if b3.body_get_type(picked) != b3.BodyType.b3_dynamicBody:
        return
    s_drag_body = picked
    let center = b3.body_get_position(s_drag_body)
    s_drag_grab_offset = result.point.sub(center)

function mouse_move(ground: b3.Vec3) -> void:
    if s_drag_body == b3.b3_nullBodyId:
        return
    if not b3.body_is_valid(s_drag_body):
        s_drag_body = b3.b3_nullBodyId
        return
    let mass = b3.body_get_mass(s_drag_body)
    if mass < 0.001:
        return
    let center = b3.body_get_position(s_drag_body)
    let velocity = b3.body_get_linear_velocity(s_drag_body)
    # Mass-scaled PD controller: the spring stiffness and damping are tuned per
    # unit of body mass, so boxes and spheres drag the same regardless of their
    # density (box3d's default shape density makes a 1 m cube weigh 1000 kg).
    let target = ground.sub(s_drag_grab_offset)
    var accel = target.sub(center).scale(50.0).sub(velocity.scale(8.0))
    let accel_len = accel.length()
    if accel_len > 200.0:
        accel = accel.scale(200.0 / accel_len)
    b3.body_apply_force(s_drag_body, accel.scale(mass), center, true)

function mouse_up() -> void:
    s_drag_body = b3.b3_nullBodyId

# =============================================================================
# Deterministic randomness (mirrors shared/random.h)
# =============================================================================
var g_random_seed: uint = 12345
const RAND_LIMIT: uint = 32767

public function random_int() -> int:
    var x = g_random_seed
    x = x ^ x << 13
    x = x ^ x >> 17
    x = x ^ x << 5
    g_random_seed = x
    return int<-(x % (RAND_LIMIT + 1u))

public function random_float() -> float:
    let value = random_int() & int<-RAND_LIMIT
    return value / 32767.0

public function random_float_range(lo: float, hi: float) -> float:
    return lo + random_float() * (hi - lo)

public function random_vec3(lo: float, hi: float) -> b3.Vec3:
    return b3.Vec3(x = random_float_range(lo, hi), y = random_float_range(lo, hi), z = random_float_range(lo, hi))

# =============================================================================
# World / body / shape factory helpers
# =============================================================================
public function create_world() -> b3.WorldId:
    let world_def = b3.default_world_def()
    s_world_id = b3.create_world(world_def)
    return s_world_id

public function world_id() -> b3.WorldId:
    return s_world_id

public function add_ground_box(extent: float) -> b3.BodyId:
    var body_def = b3.default_body_def()
    body_def.name = c"ground"
    let ground = b3.create_body(s_world_id, body_def)
    track_body(ground)
    let shape_def = b3.default_shape_def()
    let box = b3.make_box_hull(extent, 0.5, extent)
    b3.create_hull_shape(ground, shape_def, box.base)
    return ground

public function make_dynamic_box(position: b3.Vec3, hx: float, hy: float, hz: float) -> b3.BodyId:
    var body_def = b3.default_body_def()
    body_def.type = b3.BodyType.b3_dynamicBody
    body_def.position = position
    let body = b3.create_body(s_world_id, body_def)
    track_body(body)
    let shape_def = b3.default_shape_def()
    let box = b3.make_box_hull(hx, hy, hz)
    b3.create_hull_shape(body, shape_def, box.base)
    return body

public function make_dynamic_sphere(position: b3.Vec3, radius: float) -> b3.BodyId:
    var body_def = b3.default_body_def()
    body_def.type = b3.BodyType.b3_dynamicBody
    body_def.position = position
    let body = b3.create_body(s_world_id, body_def)
    track_body(body)
    let shape_def = b3.default_shape_def()
    let sphere = b3.Sphere(center = b3.b3Vec3_zero, radius = radius)
    b3.create_sphere_shape(body, shape_def, sphere)
    return body

public function make_dynamic_capsule(position: b3.Vec3, half_height: float, radius: float) -> b3.BodyId:
    var body_def = b3.default_body_def()
    body_def.type = b3.BodyType.b3_dynamicBody
    body_def.position = position
    let body = b3.create_body(s_world_id, body_def)
    track_body(body)
    let shape_def = b3.default_shape_def()
    let capsule = b3.Capsule(center1 = b3.Vec3(x = 0.0, y = -half_height, z = 0.0), center2 = b3.Vec3(x = 0.0, y = half_height, z = 0.0), radius = radius)
    b3.create_capsule_shape(body, shape_def, capsule)
    return body

# =============================================================================
# Scalar helpers
# =============================================================================
public function clamp_float(value: float, lo: float, hi: float) -> float:
    return if value < lo: lo else: if value > hi: hi else: value

public function abs_float(value: float) -> float:
    return if value < 0.0: -value else: value

# =============================================================================
# Sample interface and run() driver
# =============================================================================
public interface Sample:
    editable function on_step() -> void
    editable function draw_overlay() -> void

# Called every frame after the world step; samples poll rl.is_key_pressed
# and read contact/sensor/body events here.
# Called each frame in 2D overlay space after the world render.
public function draw_text_line(text: str) -> void:
    rl.draw_text(text, 5, s_text_line, 20, rl.LIGHTGRAY)
    s_text_line += 22

# Optional 3D scene-draw hook that samples can install to draw extra geometry
# (rays, contact points, gizmos) inside the 3D pass each frame.
function noop_scene_draw() -> void:
    pass

var s_scene_draw: fn() -> void = noop_scene_draw

public function set_scene_draw(fcn: fn() -> void) -> void:
    s_scene_draw = fcn

function update_camera_input() -> void:
    if rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_RIGHT):
        let delta = rl.get_mouse_delta()
        s_camera.yaw += delta.x * 0.2
        s_camera.pitch = clamp_float(s_camera.pitch + delta.y * 0.2, -89.0, 89.0)
    if rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_MIDDLE):
        let delta = rl.get_mouse_delta()
        let scale = 0.01 * s_camera.distance
        let yaw_r = s_camera.yaw * DEG_TO_RAD
        let right = b3.Vec3(x = float<-math.cos(double<-yaw_r), y = 0.0, z = float<-math.sin(double<-yaw_r))
        let forward = b3.Vec3(x = float<--math.sin(double<-yaw_r), y = 0.0, z = float<-math.cos(double<-yaw_r))
        s_camera.target = s_camera.target.add(right.scale(-delta.x * scale)).add(forward.scale(delta.y * scale))
    let wheel = rl.get_mouse_wheel_move()
    if wheel != 0.0:
        s_camera.distance = clamp_float(s_camera.distance * (1.0 - 0.1 * wheel), 0.5, 500.0)

public function run(sample: dyn[Sample], title: str, target: b3.Vec3, distance: float) -> int:
    s_camera = default_camera(target, distance)
    setup_debug_draw()
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, title)
    defer:
        rl.close_window()
    defer:
        b3.destroy_world(s_world_id)
    s_cube_model = rl.load_model_from_mesh(rl.gen_mesh_cube(1.0, 1.0, 1.0))
    defer:
        rl.unload_model(s_cube_model)
    rl.set_target_fps(60)
    s_paused = false
    s_single_step = false
    while not rl.window_should_close():
        update_camera_input()
        let camera = s_camera.to_raylib()
        let mouse = rl.get_mouse_position()
        let ray = rl.get_screen_to_world_ray(mouse, camera)
        let ground = ray_ground_point(ray)
        s_drag_point = ground
        if s_drag_enabled:
            if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
                mouse_down(ray)
            if rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT):
                mouse_move(ground)
            if rl.is_mouse_button_released(rl.MouseButton.MOUSE_BUTTON_LEFT):
                mouse_up()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_P):
            s_paused = not s_paused
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE) and s_paused:
            s_single_step = true
        if rl.is_key_pressed(rl.KeyboardKey.KEY_F12):
            rl.take_screenshot("box3d_screenshot.png")
        var time_step = 1.0 / HERTZ
        if s_paused:
            if s_single_step:
                s_single_step = false
            else:
                time_step = 0.0
        s_stepped = time_step > 0.0
        b3.world_step(s_world_id, time_step, SUB_STEP_COUNT)
        sample.on_step()
        rl.begin_drawing()
        rl.clear_background(rl.Color(r = 38ub, g = 38ub, b = 44ub, a = 255ub))
        rl.begin_mode_3d(camera)
        rl.draw_grid(40, 1.0)
        draw_world()
        s_scene_draw()
        rl.end_mode_3d()
        s_text_line = 0
        draw_text_line(title)
        if s_paused:
            draw_text_line("PAUSED (Space: single step)")
        sample.draw_overlay()
        rl.end_drawing()
    return 0

## Shared machinery for the box2d sample ports.
##
## Ported from third_party/box2d-upstream/samples (draw.cpp, sample.cpp,
## random.h) to Milk Tea. Provides:
##   - a raylib-backed b2DebugDraw implementation
##   - a world-to-screen camera (box2d +Y up, matching upstream orientation)
##   - a single-threaded world factory
##   - mouse-joint picking via overlap query
##   - deterministic XorShift32 randomness (RAND_SEED = 12345)
##   - a Sample interface plus a run() driver that owns the window/step/draw loop

import std.box2d as b2
import std.math as math
import std.raylib as rl
import std.str as str_mod

const SCREEN_WIDTH: int = 1280
const SCREEN_HEIGHT: int = 720
public const HERTZ: float = 60.0
const SUB_STEP_COUNT: int = 4
const MAX_POLYGON_VERTICES: int = 8

# =============================================================================
# Vec2 / Rot / Transform math helpers
# =============================================================================

extending b2.Vec2:
    public function add(other: b2.Vec2) -> b2.Vec2:
        return b2.Vec2(x = this.x + other.x, y = this.y + other.y)

    public function sub(other: b2.Vec2) -> b2.Vec2:
        return b2.Vec2(x = this.x - other.x, y = this.y - other.y)

    public function scale(value: float) -> b2.Vec2:
        return b2.Vec2(x = this.x * value, y = this.y * value)

    public function neg() -> b2.Vec2:
        return b2.Vec2(x = -this.x, y = -this.y)

    public function dot(other: b2.Vec2) -> float:
        return this.x * other.x + this.y * other.y

    public function length() -> float:
        return float<-math.sqrt(double<-(this.x * this.x + this.y * this.y))

    public function length_sq() -> float:
        return this.x * this.x + this.y * this.y

extending b2.Rot:
    public function mul_vector(v: b2.Vec2) -> b2.Vec2:
        return b2.Vec2(x = this.c * v.x - this.s * v.y, y = this.s * v.x + this.c * v.y)

    public function x_axis() -> b2.Vec2:
        return b2.Vec2(x = this.c, y = this.s)

    public function y_axis() -> b2.Vec2:
        return b2.Vec2(x = -this.s, y = this.c)

extending b2.Transform:
    public function mul_point(p: b2.Vec2) -> b2.Vec2:
        return this.p.add(this.q.mul_vector(p))

public function make_rot(angle: float) -> b2.Rot:
    let cs = b2.compute_cos_sin(angle)
    return b2.Rot(c = cs.cosine, s = cs.sine)

public function min_float(a: float, b: float) -> float:
    return if a < b: a else: b

public function max_float(a: float, b: float) -> float:
    return if a > b: a else: b

public function clamp_float(value: float, lo: float, hi: float) -> float:
    return max_float(lo, min_float(value, hi))

public function min_int(a: int, b: int) -> int:
    return if a < b: a else: b

public function max_int(a: int, b: int) -> int:
    return if a > b: a else: b

# =============================================================================
# Hex color conversion (b2HexColor is 0xRRGGBB)
# =============================================================================

public function hex_to_color(color: b2.HexColor) -> rl.Color:
    let value = uint<-color
    return rl.Color(
        r = ubyte<-((value >> 16) & 0xFFu),
        g = ubyte<-((value >> 8) & 0xFFu),
        b = ubyte<-(value & 0xFFu),
        a = 255ub
    )

# =============================================================================
# Camera
# =============================================================================

struct Camera:
    center: b2.Vec2
    zoom: float
    width: float
    height: float

extending Camera:
    public function convert_screen_to_world(screen: rl.Vector2) -> b2.Vec2:
        let w = this.width
        let h = this.height
        let u = screen.x / w
        let v = (h - screen.y) / h
        let ratio = w / h
        let extents = b2.Vec2(x = this.zoom * ratio, y = this.zoom)
        let lower = this.center.sub(extents)
        let upper = this.center.add(extents)
        return b2.Vec2(
            x = (1.0 - u) * lower.x + u * upper.x,
            y = (1.0 - v) * lower.y + v * upper.y
        )

    public function convert_world_to_screen(world: b2.Vec2) -> rl.Vector2:
        let w = this.width
        let h = this.height
        let ratio = w / h
        let extents = b2.Vec2(x = this.zoom * ratio, y = this.zoom)
        let lower = this.center.sub(extents)
        let upper = this.center.add(extents)
        let u = (world.x - lower.x) / (upper.x - lower.x)
        let v = (world.y - lower.y) / (upper.y - lower.y)
        return rl.Vector2(x = u * w, y = (1.0 - v) * h)

    public function pixels_per_world_unit() -> float:
        return this.height / (2.0 * this.zoom)

# =============================================================================
# Module state shared with the debug-draw callbacks
# =============================================================================

var s_camera: Camera
var s_world_id: b2.WorldId = b2.b2_nullWorldId
var s_debug_draw: b2.DebugDraw
var s_poly_points: array[rl.Vector2, MAX_POLYGON_VERTICES]
var s_dummy_context: int = 0
var s_paused: bool = false
var s_single_step: bool = false
var s_stepped: bool = false

public function paused() -> bool:
    return s_paused

public function stepped() -> bool:
    return s_stepped

# =============================================================================
# Debug draw callbacks
# =============================================================================
# Debug draw callbacks
# =============================================================================

public function draw_world_segment(p1: b2.Vec2, p2: b2.Vec2, color: b2.HexColor) -> void:
    let s1 = s_camera.convert_world_to_screen(p1)
    let s2 = s_camera.convert_world_to_screen(p2)
    rl.draw_line_ex(s1, s2, 2.0, hex_to_color(color))

public function draw_world_point(p: b2.Vec2, size: float, color: b2.HexColor) -> void:
    let screen = s_camera.convert_world_to_screen(p)
    rl.draw_circle_v(screen, 0.5 * size, hex_to_color(color))

public function draw_world_circle(center: b2.Vec2, radius: float, color: b2.HexColor) -> void:
    let screen = s_camera.convert_world_to_screen(center)
    let pixel_radius = radius * s_camera.pixels_per_world_unit()
    rl.draw_circle_lines_v(screen, pixel_radius, hex_to_color(color))

public function draw_world_aabb(aabb: b2.AABB, color: b2.HexColor) -> void:
    let lower = aabb.lowerBound
    let upper = aabb.upperBound
    draw_world_segment(lower, b2.Vec2(x = upper.x, y = lower.y), color)
    draw_world_segment(b2.Vec2(x = upper.x, y = lower.y), upper, color)
    draw_world_segment(upper, b2.Vec2(x = lower.x, y = upper.y), color)
    draw_world_segment(b2.Vec2(x = lower.x, y = upper.y), lower, color)

public function draw_world_transform(transform: b2.Transform) -> void:
    let axis_scale = 0.2
    let p = transform.p
    draw_world_segment(p, p.add(transform.q.x_axis().scale(axis_scale)), b2.HexColor.b2_colorRed)
    draw_world_segment(p, p.add(transform.q.y_axis().scale(axis_scale)), b2.HexColor.b2_colorGreen)

function debug_draw_polygon(
    vertices: const_ptr[b2.Vec2],
    vertex_count: int,
    color: b2.HexColor,
    _context: ptr[void]
) -> void:
    if vertex_count < 2:
        return
    unsafe:
        var last = read(vertices + ptr_uint<-(vertex_count - 1))
        var index = 0
        while index < vertex_count:
            let current = read(vertices + ptr_uint<-index)
            draw_world_segment(last, current, color)
            last = current
            index += 1

function debug_draw_solid_polygon(
    transform: b2.Transform,
    vertices: const_ptr[b2.Vec2],
    vertex_count: int,
    _radius: float,
    color: b2.HexColor,
    _context: ptr[void]
) -> void:
    if vertex_count < 3:
        return
    unsafe:
        var index = 0
        while index < vertex_count:
            let vertex = read(vertices + ptr_uint<-index)
            let world_pos = transform.mul_point(vertex)
            s_poly_points[index] = s_camera.convert_world_to_screen(world_pos)
            index += 1
    rl.draw_triangle_fan_ptr(const_ptr_of(s_poly_points[0]), vertex_count, hex_to_color(color))

function debug_draw_circle(center: b2.Vec2, radius: float, color: b2.HexColor, _context: ptr[void]) -> void:
    draw_world_circle(center, radius, color)

function debug_draw_solid_circle(
    transform: b2.Transform,
    radius: float,
    color: b2.HexColor,
    _context: ptr[void]
) -> void:
    let screen = s_camera.convert_world_to_screen(transform.p)
    let pixel_radius = radius * s_camera.pixels_per_world_unit()
    rl.draw_circle_v(screen, pixel_radius, hex_to_color(color))

function debug_draw_solid_capsule(
    p1: b2.Vec2,
    p2: b2.Vec2,
    radius: float,
    color: b2.HexColor,
    _context: ptr[void]
) -> void:
    let s1 = s_camera.convert_world_to_screen(p1)
    let s2 = s_camera.convert_world_to_screen(p2)
    let pixel_radius = radius * s_camera.pixels_per_world_unit()
    let fill = hex_to_color(color)
    rl.draw_line_ex(s1, s2, 2.0 * pixel_radius, fill)
    rl.draw_circle_v(s1, pixel_radius, fill)
    rl.draw_circle_v(s2, pixel_radius, fill)

function debug_draw_segment(p1: b2.Vec2, p2: b2.Vec2, color: b2.HexColor, _context: ptr[void]) -> void:
    draw_world_segment(p1, p2, color)

function debug_draw_transform(transform: b2.Transform, _context: ptr[void]) -> void:
    draw_world_transform(transform)

function debug_draw_point(p: b2.Vec2, size: float, color: b2.HexColor, _context: ptr[void]) -> void:
    draw_world_point(p, size, color)

function debug_draw_string(world_pos: b2.Vec2, text: cstr, color: b2.HexColor, _context: ptr[void]) -> void:
    let screen = s_camera.convert_world_to_screen(world_pos)
    let label = str_mod.cstr_as_str(text)
    rl.draw_text_ex(rl.get_font_default(), label, screen, 20.0, 1.0, hex_to_color(color))

function setup_debug_draw() -> void:
    let default_draw = b2.default_debug_draw()
    s_debug_draw = default_draw
    s_debug_draw.drawShapes = true
    s_debug_draw.drawJoints = true
    s_debug_draw.DrawPolygonFcn = debug_draw_polygon
    s_debug_draw.DrawSolidPolygonFcn = debug_draw_solid_polygon
    s_debug_draw.DrawCircleFcn = debug_draw_circle
    s_debug_draw.DrawSolidCircleFcn = debug_draw_solid_circle
    s_debug_draw.DrawSolidCapsuleFcn = debug_draw_solid_capsule
    s_debug_draw.DrawSegmentFcn = debug_draw_segment
    s_debug_draw.DrawTransformFcn = debug_draw_transform
    s_debug_draw.DrawPointFcn = debug_draw_point
    s_debug_draw.DrawStringFcn = debug_draw_string

# =============================================================================
# World creation and mouse-joint picking
# =============================================================================

public function create_world() -> b2.WorldId:
    let world_def = b2.default_world_def()
    let world_id = b2.create_world(world_def)
    return world_id

var s_query_point: b2.Vec2
var s_query_result: b2.BodyId = b2.b2_nullBodyId
var s_mouse_joint: b2.JointId = b2.b2_nullJointId
var s_mouse_ground_body: b2.BodyId = b2.b2_nullBodyId

function overlap_query_callback(shape_id: b2.ShapeId, _context: ptr[void]) -> bool:
    let body = b2.shape_get_body(shape_id)
    if b2.body_get_type(body) != b2.BodyType.b2_dynamicBody:
        return true
    if b2.shape_test_point(shape_id, s_query_point):
        s_query_result = body
        return false
    return true

function null_context() -> ptr[void]:
    return unsafe: reinterpret[ptr[void]](ptr_of(s_dummy_context))

function mouse_down(world_point: b2.Vec2) -> void:
    if s_mouse_joint != b2.b2_nullJointId:
        return
    let d = b2.Vec2(x = 0.001, y = 0.001)
    let box = b2.AABB(lowerBound = world_point.sub(d), upperBound = world_point.add(d))
    s_query_point = world_point
    s_query_result = b2.b2_nullBodyId
    let filter = b2.default_query_filter()
    let _stats = b2.world_overlap_aabb(s_world_id, box, filter, overlap_query_callback, null_context())
    if s_query_result != b2.b2_nullBodyId:
        let body_def = b2.default_body_def()
        s_mouse_ground_body = b2.create_body(s_world_id, body_def)
        var mouse_def = b2.default_mouse_joint_def()
        mouse_def.bodyIdA = s_mouse_ground_body
        mouse_def.bodyIdB = s_query_result
        mouse_def.target = world_point
        mouse_def.hertz = 10.0
        mouse_def.dampingRatio = 0.7
        let gravity = b2.world_get_gravity(s_world_id)
        mouse_def.maxForce = 1000.0 * b2.body_get_mass(s_query_result) * gravity.length()
        s_mouse_joint = b2.create_mouse_joint(s_world_id, const_ptr_of(mouse_def))
        b2.body_set_awake(s_query_result, true)

function mouse_move(world_point: b2.Vec2) -> void:
    if s_mouse_joint == b2.b2_nullJointId:
        return
    if not b2.joint_is_valid(s_mouse_joint):
        s_mouse_joint = b2.b2_nullJointId
        return
    b2.mouse_joint_set_target(s_mouse_joint, world_point)
    let body_b = b2.joint_get_body_b(s_mouse_joint)
    b2.body_set_awake(body_b, true)

function mouse_up(_world_point: b2.Vec2) -> void:
    if not b2.joint_is_valid(s_mouse_joint):
        s_mouse_joint = b2.b2_nullJointId
    if s_mouse_joint != b2.b2_nullJointId:
        b2.destroy_joint(s_mouse_joint)
        s_mouse_joint = b2.b2_nullJointId
        if s_mouse_ground_body != b2.b2_nullBodyId:
            b2.destroy_body(s_mouse_ground_body)
            s_mouse_ground_body = b2.b2_nullBodyId

# =============================================================================
# Deterministic randomness (mirrors shared/random.h)
# =============================================================================

var g_random_seed: uint = 12345
const RAND_LIMIT: uint = 32767

public function random_int() -> int:
    var x = g_random_seed
    x = x ^ (x << 13)
    x = x ^ (x >> 17)
    x = x ^ (x << 5)
    g_random_seed = x
    return int<-(x % (RAND_LIMIT + 1u))

public function random_float() -> float:
    let value = random_int() & int<-RAND_LIMIT
    return (value) / 32767.0

public function random_float_range(lo: float, hi: float) -> float:
    return lo + random_float() * (hi - lo)

public function random_polygon(extent: float) -> b2.Polygon:
    var points: array[b2.Vec2, b2.B2_MAX_POLYGON_VERTICES]
    let count = 3 + random_int() % 6
    var index = 0
    while index < count:
        points[index] = b2.Vec2(
            x = random_float_range(-extent, extent),
            y = random_float_range(-extent, extent)
        )
        index += 1
    let hull = b2.compute_hull(const_ptr_of(points[0]), count)
    if hull.count > 0:
        return b2.make_polygon(const_ptr_of(hull), 0.0)
    return b2.make_square(extent)

# =============================================================================
# Sample interface and run() driver
# =============================================================================

public interface Sample:
    # Called every frame after the world step; safe to read contact/body events
    # and to create or destroy bodies. Samples poll rl.is_key_pressed here.
    editable function on_step() -> void
    # Called each frame inside the draw pass after the world debug draw.
    function draw_overlay() -> void

var s_text_line: int = 0

public function draw_text_line(text: str) -> void:
    rl.draw_text(text, 5, s_text_line, 20, rl.LIGHTGRAY)
    s_text_line += 22

function step_world(time_step: float) -> void:
    b2.world_step(s_world_id, time_step, SUB_STEP_COUNT)

public function run(sample: dyn[Sample], title: str, center: b2.Vec2, zoom: float, world_id: b2.WorldId) -> int:
    s_world_id = world_id
    s_camera = Camera(
        center = center,
        zoom = zoom,
        width = float<-SCREEN_WIDTH,
        height = float<-SCREEN_HEIGHT
    )
    setup_debug_draw()

    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, title)
    defer: rl.close_window()
    defer: b2.destroy_world(s_world_id)
    rl.set_target_fps(60)

    s_paused = false
    s_single_step = false

    while not rl.window_should_close():
        let mouse = rl.get_mouse_position()
        let world_point = s_camera.convert_screen_to_world(mouse)
        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            mouse_down(world_point)
        if rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT):
            mouse_move(world_point)
        if rl.is_mouse_button_released(rl.MouseButton.MOUSE_BUTTON_LEFT):
            mouse_up(world_point)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_P):
            s_paused = not s_paused
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE) and s_paused:
            s_single_step = true
        if rl.is_key_pressed(rl.KeyboardKey.KEY_F12):
            rl.take_screenshot("box2d_screenshot.png")

        var time_step = 1.0 / HERTZ
        if s_paused:
            if s_single_step: s_single_step = false else: time_step = 0.0

        s_stepped = time_step > 0.0
        b2.world_step(s_world_id, time_step, SUB_STEP_COUNT)

        sample.on_step()

        rl.begin_drawing()
        rl.clear_background(rl.Color(r = 38ub, g = 38ub, b = 44ub, a = 255ub))
        b2.world_draw(s_world_id, s_debug_draw)
        s_text_line = 0
        draw_text_line(title)
        if s_paused:
            draw_text_line("PAUSED (Space: single step)")
        sample.draw_overlay()
        rl.end_drawing()

    return 0

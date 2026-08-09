## Box2D sample port: "Shape Distance" (from box2d-upstream/samples/sample_collision.cpp).
##
## Computes the distance between two shapes with b2ShapeDistance and visualizes
## the GJK simplex when enabled. Shape A is fixed at the origin; shape B can be
## dragged and rotated.
##   1 / 2 / 3 / 4     shape A: point / segment / triangle / box
##   5 / 6 / 7 / 8     shape B: point / segment / triangle / box
##   [ / ]             radius A
##   - / =             radius B
##   S                 toggle simplex visualization
##   I                 toggle vertex indices
##   U                 toggle simplex cache
##   , / .             simplex index (when drawing simplex)
##   Left mouse           drag shape B
##   Left mouse + Shift   rotate shape B
##   P                   pause, Space single-step

import std.box2d as b2
import std.raylib as rl
import examples.box2d.common as common

const SIMPLEX_CAPACITY: int = 20

enum ShapeKind:
    point
    segment
    triangle
    box

struct ShapeDistance implements common.Sample:
    world: b2.WorldId
    point: b2.Vec2
    segment: b2.Segment
    triangle: b2.Polygon
    box: b2.Polygon
    type_a: ShapeKind
    type_b: ShapeKind
    radius_a: float
    radius_b: float
    proxy_a: b2.ShapeProxy
    proxy_b: b2.ShapeProxy
    cache: b2.SimplexCache
    distance_output: b2.DistanceOutput
    simplexes: array[b2.Simplex, SIMPLEX_CAPACITY]
    simplex_count: int
    simplex_index: int
    transform: b2.Transform
    angle: float
    base_position: b2.Vec2
    start_point: b2.Vec2
    base_angle: float
    dragging: bool
    rotating: bool
    show_indices: bool
    use_cache: bool
    draw_simplex: bool

function weight2(a1: float, w1: b2.Vec2, a2: float, w2: b2.Vec2) -> b2.Vec2:
    return b2.Vec2(x = a1 * w1.x + a2 * w2.x, y = a1 * w1.y + a2 * w2.y)

function weight3(a1: float, w1: b2.Vec2, a2: float, w2: b2.Vec2, a3: float, w3: b2.Vec2) -> b2.Vec2:
    return b2.Vec2(
        x = a1 * w1.x + a2 * w2.x + a3 * w3.x,
        y = a1 * w1.y + a2 * w2.y + a3 * w3.y
    )

function compute_witness(s: b2.Simplex) -> (b2.Vec2, b2.Vec2):
    if s.count == 1:
        return (s.v1.wA, s.v1.wB)
    if s.count == 2:
        let a = weight2(s.v1.a, s.v1.wA, s.v2.a, s.v2.wA)
        let b = weight2(s.v1.a, s.v1.wB, s.v2.a, s.v2.wB)
        return (a, b)
    let a = weight3(s.v1.a, s.v1.wA, s.v2.a, s.v2.wA, s.v3.a, s.v3.wA)
    return (a, a)

function shape_distance_create(world_id: b2.WorldId) -> ShapeDistance:
    common.enable_mouse_joint(false)
    let triangle_points: array[b2.Vec2, 3] = array[b2.Vec2, 3](
        b2.Vec2(x = -0.5, y = 0.0),
        b2.Vec2(x = 0.5, y = 0.0),
        b2.Vec2(x = 0.0, y = 1.0)
    )
    let triangle_hull = b2.compute_hull(const_ptr_of(triangle_points[0]), 3)

    var sample = ShapeDistance(
        world = world_id,
        point = b2.b2Vec2_zero,
        segment = b2.Segment(
            point1 = b2.Vec2(x = -0.5, y = 0.0),
            point2 = b2.Vec2(x = 0.5, y = 0.0)
        ),
        triangle = b2.make_polygon(const_ptr_of(triangle_hull), 0.0),
        box = b2.make_square(0.5),
        type_a = ShapeKind.box,
        type_b = ShapeKind.box,
        radius_a = 0.0,
        radius_b = 0.0,
        proxy_a = b2.ShapeProxy(points = zero[array[b2.Vec2, 8]], count = 0, radius = 0.0),
        proxy_b = b2.ShapeProxy(points = zero[array[b2.Vec2, 8]], count = 0, radius = 0.0),
        cache = b2.b2_emptySimplexCache,
        distance_output = b2.DistanceOutput(
            pointA = b2.b2Vec2_zero,
            pointB = b2.b2Vec2_zero,
            normal = b2.b2Vec2_zero,
            distance = 0.0,
            iterations = 0,
            simplexCount = 0
        ),
        simplexes = zero[array[b2.Simplex, SIMPLEX_CAPACITY]],
        simplex_count = 0,
        simplex_index = 0,
        transform = b2.b2Transform_identity,
        angle = 0.0,
        base_position = b2.b2Vec2_zero,
        start_point = b2.b2Vec2_zero,
        base_angle = 0.0,
        dragging = false,
        rotating = false,
        show_indices = false,
        use_cache = false,
        draw_simplex = false
    )
    sample.make_proxies()
    return sample

extending ShapeDistance:
    function make_proxy(kind: ShapeKind, radius: float) -> b2.ShapeProxy:
        var proxy = b2.ShapeProxy(points = zero[array[b2.Vec2, 8]], count = 0, radius = 0.0)
        proxy.radius = radius
        match kind:
            ShapeKind.point:
                proxy.points[0] = b2.b2Vec2_zero
                proxy.count = 1
            ShapeKind.segment:
                proxy.points[0] = this.segment.point1
                proxy.points[1] = this.segment.point2
                proxy.count = 2
            ShapeKind.triangle:
                var index = 0
                while index < this.triangle.count:
                    proxy.points[index] = this.triangle.vertices[index]
                    index += 1
                proxy.count = this.triangle.count
            ShapeKind.box:
                var index = 0
                while index < 4:
                    proxy.points[index] = this.box.vertices[index]
                    index += 1
                proxy.count = 4
        return proxy

    editable function make_proxies() -> void:
        this.proxy_a = this.make_proxy(this.type_a, this.radius_a)
        this.proxy_b = this.make_proxy(this.type_b, this.radius_b)

    function draw_shape(kind: ShapeKind, transform: b2.Transform, radius: float, color: b2.HexColor) -> void:
        match kind:
            ShapeKind.point:
                let p = transform.mul_point(this.point)
                if radius > 0.0:
                    common.draw_world_solid_circle(p, radius, color)
                else:
                    common.draw_world_point(p, 5.0, color)
            ShapeKind.segment:
                let p1 = transform.mul_point(this.segment.point1)
                let p2 = transform.mul_point(this.segment.point2)
                if radius > 0.0:
                    common.draw_world_solid_capsule(p1, p2, radius, color)
                else:
                    common.draw_world_segment(p1, p2, color)
            ShapeKind.triangle:
                common.draw_world_solid_polygon(
                    transform, const_ptr_of(this.triangle.vertices[0]), this.triangle.count, color
                )
            ShapeKind.box:
                common.draw_world_solid_polygon(
                    transform, const_ptr_of(this.box.vertices[0]), this.box.count, color
                )

    editable function on_step() -> void:
        this.compute_distance()
        let p = common.mouse_world_point()
        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            if not rl.is_key_down(rl.KeyboardKey.KEY_LEFT_SHIFT) and not this.rotating:
                this.dragging = true
                this.start_point = p
                this.base_position = this.transform.p
            else if rl.is_key_down(rl.KeyboardKey.KEY_LEFT_SHIFT) and not this.dragging:
                this.rotating = true
                this.start_point = p
                this.base_angle = this.angle
        if rl.is_mouse_button_released(rl.MouseButton.MOUSE_BUTTON_LEFT):
            this.dragging = false
            this.rotating = false
        if this.dragging:
            this.transform.p = this.base_position.add(p.sub(this.start_point).scale(0.5))
        else if this.rotating:
            let dx = p.x - this.start_point.x
            this.angle = common.clamp_float(this.base_angle + dx, -b2.B2_PI, b2.B2_PI)
            this.transform.q = common.make_rot(this.angle)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_ONE):
            this.type_a = ShapeKind.point
            this.make_proxies()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_TWO):
            this.type_a = ShapeKind.segment
            this.make_proxies()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_THREE):
            this.type_a = ShapeKind.triangle
            this.make_proxies()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_FOUR):
            this.type_a = ShapeKind.box
            this.make_proxies()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_FIVE):
            this.type_b = ShapeKind.point
            this.make_proxies()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SIX):
            this.type_b = ShapeKind.segment
            this.make_proxies()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SEVEN):
            this.type_b = ShapeKind.triangle
            this.make_proxies()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_EIGHT):
            this.type_b = ShapeKind.box
            this.make_proxies()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT_BRACKET):
            this.radius_a = common.max_float(this.radius_a - 0.05, 0.0)
            this.proxy_a.radius = this.radius_a
        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT_BRACKET):
            this.radius_a = common.min_float(this.radius_a + 0.05, 0.5)
            this.proxy_a.radius = this.radius_a
        if rl.is_key_pressed(rl.KeyboardKey.KEY_MINUS):
            this.radius_b = common.max_float(this.radius_b - 0.05, 0.0)
            this.proxy_b.radius = this.radius_b
        if rl.is_key_pressed(rl.KeyboardKey.KEY_EQUAL):
            this.radius_b = common.min_float(this.radius_b + 0.05, 0.5)
            this.proxy_b.radius = this.radius_b
        if rl.is_key_pressed(rl.KeyboardKey.KEY_S):
            this.draw_simplex = not this.draw_simplex
            this.simplex_index = 0
        if rl.is_key_pressed(rl.KeyboardKey.KEY_I):
            this.show_indices = not this.show_indices
        if rl.is_key_pressed(rl.KeyboardKey.KEY_U):
            this.use_cache = not this.use_cache
        if rl.is_key_pressed(rl.KeyboardKey.KEY_COMMA):
            this.simplex_index = common.clamp_int(this.simplex_index - 1, 0, this.simplex_count - 1)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_PERIOD):
            this.simplex_index = common.clamp_int(this.simplex_index + 1, 0, this.simplex_count - 1)

    editable function compute_distance() -> void:
        let input = b2.DistanceInput(
            proxyA = this.proxy_a,
            proxyB = this.proxy_b,
            transformA = b2.b2Transform_identity,
            transformB = this.transform,
            useRadii = true
        )
        if not this.use_cache:
            this.cache.count = 0
        this.distance_output = b2.shape_distance(
            const_ptr_of(input),
            ptr_of(this.cache),
            ptr_of(this.simplexes[0]),
            SIMPLEX_CAPACITY
        )
        this.simplex_count = this.distance_output.simplexCount

    function draw_overlay() -> void:
        let output = this.distance_output
        this.draw_shape(this.type_a, b2.b2Transform_identity, this.radius_a, b2.HexColor.b2_colorCyan)
        this.draw_shape(this.type_b, this.transform, this.radius_b, b2.HexColor.b2_colorBisque)

        if this.draw_simplex:
            let simplex = this.simplexes[this.simplex_index]
            if this.simplex_index > 0:
                let (point_a, point_b) = compute_witness(simplex)
                common.draw_world_segment(point_a, point_b, b2.HexColor.b2_colorWhite)
                common.draw_world_point(point_a, 10.0, b2.HexColor.b2_colorWhite)
                common.draw_world_point(point_b, 10.0, b2.HexColor.b2_colorWhite)
            let colors: array[b2.HexColor, 3] = array[b2.HexColor, 3](
                b2.HexColor.b2_colorRed,
                b2.HexColor.b2_colorGreen,
                b2.HexColor.b2_colorBlue
            )
            var index = 0
            while index < simplex.count:
                let vertex = if index == 0: simplex.v1 else: if index == 1: simplex.v2 else: simplex.v3
                common.draw_world_point(vertex.wA, 10.0, colors[index])
                common.draw_world_point(vertex.wB, 10.0, colors[index])
                index += 1
        else:
            common.draw_world_segment(output.pointA, output.pointB, b2.HexColor.b2_colorDimGray)
            common.draw_world_point(output.pointA, 10.0, b2.HexColor.b2_colorWhite)
            common.draw_world_point(output.pointB, 10.0, b2.HexColor.b2_colorWhite)
            common.draw_world_segment(
                output.pointA, output.pointA.add(output.normal.scale(0.5)), b2.HexColor.b2_colorYellow
            )

        common.draw_text_line(f"distance = #{output.distance:.2} iterations = #{output.iterations}")
        if this.cache.count == 1:
            common.draw_text_line(f"cache = {{{int<-this.cache.indexA[0]}}}, {{{int<-this.cache.indexB[0]}}}")
        else if this.cache.count == 2:
            common.draw_text_line(f"cache = [{int<-this.cache.indexA[0]},{int<-this.cache.indexA[1]}]")
            common.draw_text_line(f"  [{int<-this.cache.indexB[0]},{int<-this.cache.indexB[1]}]")
        common.draw_text_line("1-4: shape A  5-8: shape B  []/ - =: radii")
        common.draw_text_line("S: simplex  I: indices  U: cache  drag/shift-drag: move/rotate B")

function main() -> int:
    let world_id = common.create_world()
    var sample = shape_distance_create(world_id)
    return common.run(
        adapt[common.Sample](ref_of(sample)),
        "Box2D - Shape Distance",
        b2.Vec2(x = 0.0, y = 0.0),
        3.0,
        world_id
    )

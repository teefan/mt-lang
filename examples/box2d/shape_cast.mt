## Box2D sample port: "Shape Cast" (from box2d-upstream/samples/sample_collision.cpp).
##
## Casts shape B along a translation against shape A using b2ShapeCast, showing
## the shape at its start, swept end, and first-hit position.
##   1 / 2 / 3 / 4     shape A: point / segment / triangle / box
##   5 / 6 / 7 / 8     shape B: point / segment / triangle / box
##   [ / ]             radius A
##   - / =             radius B
##   E                 toggle can encroach
##   Left mouse           drag shape B
##   Left mouse + Shift   rotate shape B
##   Left mouse + Ctrl    set the sweep translation
##   P                   pause, Space single-step

import std.box2d as b2
import std.raylib as rl
import examples.box2d.common as common

enum ShapeKind:
    point
    segment
    triangle
    box

struct ShapeCast implements common.Sample:
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
    transform: b2.Transform
    translation: b2.Vec2
    angle: float
    base_position: b2.Vec2
    start_point: b2.Vec2
    base_angle: float
    dragging: bool
    sweeping: bool
    rotating: bool
    encroach: bool

function shape_cast_create(world_id: b2.WorldId) -> ShapeCast:
    common.enable_mouse_joint(false)
    let triangle_points: array[b2.Vec2, 3] = array[b2.Vec2, 3](
        b2.Vec2(x = -0.5, y = 0.0),
        b2.Vec2(x = 0.5, y = 0.0),
        b2.Vec2(x = 0.0, y = 1.0)
    )
    let triangle_hull = b2.compute_hull(const_ptr_of(triangle_points[0]), 3)

    var sample = ShapeCast(
        world = world_id,
        point = b2.b2Vec2_zero,
        segment = b2.Segment(
            point1 = b2.Vec2(x = 0.0, y = 0.0),
            point2 = b2.Vec2(x = 0.5, y = 0.0)
        ),
        triangle = b2.make_polygon(const_ptr_of(triangle_hull), 0.0),
        box = b2.make_offset_box(0.5, 0.5, b2.b2Vec2_zero, b2.b2Rot_identity),
        type_a = ShapeKind.box,
        type_b = ShapeKind.point,
        radius_a = 0.0,
        radius_b = 0.2,
        proxy_a = b2.ShapeProxy(points = zero[array[b2.Vec2, 8]], count = 0, radius = 0.0),
        proxy_b = b2.ShapeProxy(points = zero[array[b2.Vec2, 8]], count = 0, radius = 0.0),
        transform = b2.Transform(p = b2.Vec2(x = -0.6, y = 0.0), q = b2.b2Rot_identity),
        translation = b2.Vec2(x = 2.0, y = 0.0),
        angle = 0.0,
        base_position = b2.b2Vec2_zero,
        start_point = b2.b2Vec2_zero,
        base_angle = 0.0,
        dragging = false,
        sweeping = false,
        rotating = false,
        encroach = false
    )
    sample.make_proxies()
    return sample

extending ShapeCast:
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
        let p = common.mouse_world_point()
        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            let shift_down = rl.is_key_down(rl.KeyboardKey.KEY_LEFT_SHIFT)
            let ctrl_down = rl.is_key_down(rl.KeyboardKey.KEY_LEFT_CONTROL)
            if not shift_down and not ctrl_down:
                this.dragging = true
                this.sweeping = false
                this.rotating = false
                this.start_point = p
                this.base_position = this.transform.p
            else if rl.is_key_down(rl.KeyboardKey.KEY_LEFT_SHIFT):
                this.dragging = false
                this.sweeping = false
                this.rotating = true
                this.start_point = p
                this.base_angle = this.angle
            else if rl.is_key_down(rl.KeyboardKey.KEY_LEFT_CONTROL):
                this.dragging = false
                this.sweeping = true
                this.rotating = false
                this.start_point = p
                this.base_position = b2.b2Vec2_zero
        if rl.is_mouse_button_released(rl.MouseButton.MOUSE_BUTTON_LEFT):
            this.dragging = false
            this.sweeping = false
            this.rotating = false
        if this.dragging:
            this.transform.p = this.base_position.add(p.sub(this.start_point).scale(0.5))
        else if this.rotating:
            let dx = p.x - this.start_point.x
            this.angle = common.clamp_float(this.base_angle + dx, -b2.B2_PI, b2.B2_PI)
            this.transform.q = common.make_rot(this.angle)
        else if this.sweeping:
            this.translation = p.sub(this.start_point)

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
        if rl.is_key_pressed(rl.KeyboardKey.KEY_E):
            this.encroach = not this.encroach

    function draw_overlay() -> void:
        let input = b2.ShapeCastPairInput(
            proxyA = this.proxy_a,
            proxyB = this.proxy_b,
            transformA = b2.b2Transform_identity,
            transformB = this.transform,
            translationB = this.translation,
            maxFraction = 1.0,
            canEncroach = this.encroach
        )
        let output = b2.shape_cast(const_ptr_of(input))

        let hit_transform = b2.Transform(
            p = this.transform.p.add(this.translation.scale(output.fraction)),
            q = this.transform.q
        )

        let distance_input = b2.DistanceInput(
            proxyA = this.proxy_a,
            proxyB = this.proxy_b,
            transformA = b2.b2Transform_identity,
            transformB = hit_transform,
            useRadii = false
        )
        var distance_cache = b2.b2_emptySimplexCache
        let dummy_vertex = b2.SimplexVertex(
            wA = b2.b2Vec2_zero,
            wB = b2.b2Vec2_zero,
            w = b2.b2Vec2_zero,
            a = 0.0,
            indexA = 0,
            indexB = 0
        )
        var dummy_simplex = b2.Simplex(v1 = dummy_vertex, v2 = dummy_vertex, v3 = dummy_vertex, count = 0)
        let distance_output = b2.shape_distance(
            const_ptr_of(distance_input), ptr_of(distance_cache), ptr_of(dummy_simplex), 0
        )

        this.draw_shape(this.type_a, b2.b2Transform_identity, this.radius_a, b2.HexColor.b2_colorCyan)
        this.draw_shape(this.type_b, this.transform, this.radius_b, b2.HexColor.b2_colorLightGreen)
        let end_transform = b2.Transform(p = this.transform.p.add(this.translation), q = this.transform.q)
        this.draw_shape(this.type_b, end_transform, this.radius_b, b2.HexColor.b2_colorIndianRed)

        if output.hit:
            this.draw_shape(this.type_b, hit_transform, this.radius_b, b2.HexColor.b2_colorPlum)
            if output.fraction > 0.0:
                common.draw_world_point(output.point, 5.0, b2.HexColor.b2_colorWhite)
                common.draw_world_segment(
                    output.point, output.point.add(output.normal.scale(0.5)), b2.HexColor.b2_colorYellow
                )
            else:
                common.draw_world_point(output.point, 5.0, b2.HexColor.b2_colorPeru)

        common.draw_text_line(f"hit = #{output.hit} iterations = #{output.iterations}")
        common.draw_text_line(f"fraction = #{output.fraction:.2} distance = #{distance_output.distance:.2}")
        common.draw_text_line("drag: move  shift+drag: rotate  ctrl+drag: sweep  E: encroach")

function main() -> int:
    let world_id = common.create_world()
    var sample = shape_cast_create(world_id)
    return common.run(
        adapt[common.Sample](ref_of(sample)),
        "Box2D - Shape Cast",
        b2.Vec2(x = 0.0, y = 0.25),
        3.0,
        world_id
    )

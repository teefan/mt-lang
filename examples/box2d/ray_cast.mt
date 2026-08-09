## Box2D sample port: "Ray Cast" (from box2d-upstream/samples/sample_collision.cpp).
##
## Interactive ray-casting against five shapes (circle, capsule, box, triangle,
## segment). The ray is cast in local space and transformed back to world space.
##   Left mouse           drag the ray end point
##   Left mouse + Shift   translate the shapes
##   Left mouse + Ctrl    rotate the shapes
##   F                   toggle fraction text
##   R                   reset the shape transform
##   P                   pause, Space single-step

import std.box2d as b2
import std.raylib as rl
import examples.box2d.common as common

struct RayCast implements common.Sample:
    world: b2.WorldId
    circle: b2.Circle
    capsule: b2.Capsule
    box: b2.Polygon
    triangle: b2.Polygon
    segment: b2.Segment
    transform: b2.Transform
    angle: float
    ray_start: b2.Vec2
    ray_end: b2.Vec2
    base_position: b2.Vec2
    base_angle: float
    start_position: b2.Vec2
    ray_drag: bool
    translating: bool
    rotating: bool
    show_fraction: bool

function ray_cast_create(world_id: b2.WorldId) -> RayCast:
    common.enable_mouse_joint(false)
    let triangle_points: array[b2.Vec2, 3] = array[b2.Vec2, 3](
        b2.Vec2(x = -2.0, y = 0.0),
        b2.Vec2(x = 2.0, y = 0.0),
        b2.Vec2(x = 2.0, y = 3.0)
    )
    let triangle_hull = b2.compute_hull(const_ptr_of(triangle_points[0]), 3)
    return RayCast(
        world = world_id,
        circle = b2.Circle(center = b2.Vec2(x = 0.0, y = 0.0), radius = 2.0),
        capsule = b2.Capsule(
            center1 = b2.Vec2(x = -1.0, y = 1.0),
            center2 = b2.Vec2(x = 1.0, y = -1.0),
            radius = 1.5
        ),
        box = b2.make_box(2.0, 2.0),
        triangle = b2.make_polygon(const_ptr_of(triangle_hull), 0.0),
        segment = b2.Segment(
            point1 = b2.Vec2(x = -3.0, y = 0.0),
            point2 = b2.Vec2(x = 3.0, y = 0.0)
        ),
        transform = b2.b2Transform_identity,
        angle = 0.0,
        ray_start = b2.Vec2(x = 0.0, y = 30.0),
        ray_end = b2.Vec2(x = 0.0, y = 0.0),
        base_position = b2.b2Vec2_zero,
        base_angle = 0.0,
        start_position = b2.b2Vec2_zero,
        ray_drag = false,
        translating = false,
        rotating = false,
        show_fraction = false
    )

extending RayCast:
    editable function on_step() -> void:
        let p = common.mouse_world_point()
        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            this.start_position = p
            let shift_down = rl.is_key_down(rl.KeyboardKey.KEY_LEFT_SHIFT)
            let ctrl_down = rl.is_key_down(rl.KeyboardKey.KEY_LEFT_CONTROL)
            if not shift_down and not ctrl_down:
                this.ray_start = p
                this.ray_drag = true
            else if rl.is_key_down(rl.KeyboardKey.KEY_LEFT_SHIFT):
                this.translating = true
                this.base_position = this.transform.p
            else if rl.is_key_down(rl.KeyboardKey.KEY_LEFT_CONTROL):
                this.rotating = true
                this.base_angle = this.angle
        if rl.is_mouse_button_released(rl.MouseButton.MOUSE_BUTTON_LEFT):
            this.ray_drag = false
            this.translating = false
            this.rotating = false

        if this.ray_drag:
            this.ray_end = p
        else if this.translating:
            this.transform.p = this.base_position.add(p.sub(this.start_position).scale(0.5))
        else if this.rotating:
            let dx = p.x - this.start_position.x
            this.angle = common.clamp_float(this.base_angle + 0.5 * dx, -b2.B2_PI, b2.B2_PI)
            this.transform.q = common.make_rot(this.angle)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_F):
            this.show_fraction = not this.show_fraction
        if rl.is_key_pressed(rl.KeyboardKey.KEY_R):
            this.transform = b2.b2Transform_identity
            this.angle = 0.0

    function draw_ray(output: b2.CastOutput) -> void:
        let p1 = this.ray_start
        let p2 = this.ray_end
        let d = p2.sub(p1)
        if output.hit:
            if output.fraction == 0.0:
                common.draw_world_point(output.point, 5.0, b2.HexColor.b2_colorPeru)
            else:
                let p = p1.add(d.scale(output.fraction))
                common.draw_world_segment(p1, p, b2.HexColor.b2_colorWhite)
                common.draw_world_point(p1, 5.0, b2.HexColor.b2_colorGreen)
                common.draw_world_point(output.point, 5.0, b2.HexColor.b2_colorWhite)
                common.draw_world_segment(p, p.add(output.normal), b2.HexColor.b2_colorViolet)
                if this.show_fraction:
                    common.draw_world_string(
                        p.add(b2.Vec2(x = 0.05, y = -0.02)),
                        f"#{output.fraction:.2}",
                        b2.HexColor.b2_colorWhite
                    )
        else:
            common.draw_world_segment(p1, p2, b2.HexColor.b2_colorWhite)
            common.draw_world_point(p1, 5.0, b2.HexColor.b2_colorGreen)
            common.draw_world_point(p2, 5.0, b2.HexColor.b2_colorRed)

    function draw_overlay() -> void:
        let yellow = b2.HexColor.b2_colorYellow
        var offset = b2.Vec2(x = -20.0, y = 20.0)
        let increment = b2.Vec2(x = 10.0, y = 0.0)
        var max_fraction = 1.0
        var output = b2.CastOutput(
            normal = b2.b2Vec2_zero,
            point = b2.b2Vec2_zero,
            fraction = 0.0,
            iterations = 0,
            hit = false
        )

        # circle
        var t = b2.Transform(p = this.transform.p.add(offset), q = this.transform.q)
        common.draw_world_solid_circle(t.mul_point(this.circle.center), this.circle.radius, yellow)
        var input = b2.RayCastInput(
            origin = t.inv_mul_point(this.ray_start),
            translation = t.q.mul_vector_inv(this.ray_end.sub(this.ray_start)),
            maxFraction = max_fraction
        )
        var local_output = b2.ray_cast_circle(const_ptr_of(input), const_ptr_of(this.circle))
        if local_output.hit:
            output = local_output
            output.point = t.mul_point(local_output.point)
            output.normal = t.q.mul_vector(local_output.normal)
            max_fraction = local_output.fraction
        offset = offset.add(increment)

        # capsule
        t = b2.Transform(p = this.transform.p.add(offset), q = this.transform.q)
        let capsule_p1 = t.mul_point(this.capsule.center1)
        let capsule_p2 = t.mul_point(this.capsule.center2)
        common.draw_world_solid_capsule(capsule_p1, capsule_p2, this.capsule.radius, yellow)
        input = b2.RayCastInput(
            origin = t.inv_mul_point(this.ray_start),
            translation = t.q.mul_vector_inv(this.ray_end.sub(this.ray_start)),
            maxFraction = max_fraction
        )
        local_output = b2.ray_cast_capsule(const_ptr_of(input), const_ptr_of(this.capsule))
        if local_output.hit:
            output = local_output
            output.point = t.mul_point(local_output.point)
            output.normal = t.q.mul_vector(local_output.normal)
            max_fraction = local_output.fraction
        offset = offset.add(increment)

        # box
        t = b2.Transform(p = this.transform.p.add(offset), q = this.transform.q)
        common.draw_world_solid_polygon(t, const_ptr_of(this.box.vertices[0]), this.box.count, yellow)
        input = b2.RayCastInput(
            origin = t.inv_mul_point(this.ray_start),
            translation = t.q.mul_vector_inv(this.ray_end.sub(this.ray_start)),
            maxFraction = max_fraction
        )
        local_output = b2.ray_cast_polygon(const_ptr_of(input), const_ptr_of(this.box))
        if local_output.hit:
            output = local_output
            output.point = t.mul_point(local_output.point)
            output.normal = t.q.mul_vector(local_output.normal)
            max_fraction = local_output.fraction
        offset = offset.add(increment)

        # triangle
        t = b2.Transform(p = this.transform.p.add(offset), q = this.transform.q)
        common.draw_world_solid_polygon(t, const_ptr_of(this.triangle.vertices[0]), this.triangle.count, yellow)
        input = b2.RayCastInput(
            origin = t.inv_mul_point(this.ray_start),
            translation = t.q.mul_vector_inv(this.ray_end.sub(this.ray_start)),
            maxFraction = max_fraction
        )
        local_output = b2.ray_cast_polygon(const_ptr_of(input), const_ptr_of(this.triangle))
        if local_output.hit:
            output = local_output
            output.point = t.mul_point(local_output.point)
            output.normal = t.q.mul_vector(local_output.normal)
            max_fraction = local_output.fraction
        offset = offset.add(increment)

        # segment
        t = b2.Transform(p = this.transform.p.add(offset), q = this.transform.q)
        let segment_p1 = t.mul_point(this.segment.point1)
        let segment_p2 = t.mul_point(this.segment.point2)
        common.draw_world_segment(segment_p1, segment_p2, yellow)
        input = b2.RayCastInput(
            origin = t.inv_mul_point(this.ray_start),
            translation = t.q.mul_vector_inv(this.ray_end.sub(this.ray_start)),
            maxFraction = max_fraction
        )
        local_output = b2.ray_cast_segment(const_ptr_of(input), const_ptr_of(this.segment), false)
        if local_output.hit:
            output = local_output
            output.point = t.mul_point(local_output.point)
            output.normal = t.q.mul_vector(local_output.normal)

        this.draw_ray(output)
        common.draw_text_line("left drag: ray  shift+drag: translate  ctrl+drag: rotate")
        common.draw_text_line("F: fraction  R: reset")

function main() -> int:
    let world_id = common.create_world()
    var sample = ray_cast_create(world_id)
    return common.run(
        adapt[common.Sample](ref_of(sample)),
        "Box2D - Ray Cast",
        b2.Vec2(x = 0.0, y = 20.0),
        17.5,
        world_id
    )

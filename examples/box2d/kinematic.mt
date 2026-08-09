## Box2D sample port: "Kinematic" (from box2d-upstream/samples/sample_bodies.cpp).
##
## A kinematic body is driven to follow a Lissajous target transform each step,
## demonstrating b2Body_SetTargetTransform.
##   Left mouse    drag bodies (mouse joint)
##   P             pause, Space single-step

import std.box2d as b2
import examples.box2d.common as common

struct Kinematic implements common.Sample:
    world: b2.WorldId
    body_id: b2.BodyId
    amplitude: float
    time: float

function kinematic_create(world_id: b2.WorldId) -> Kinematic:
    var sample = Kinematic(
        world = world_id,
        body_id = b2.b2_nullBodyId,
        amplitude = 2.0,
        time = 0.0
    )

    var body_def = b2.default_body_def()
    body_def.type = b2.BodyType.b2_kinematicBody
    body_def.position = b2.Vec2(x = 2.0 * sample.amplitude, y = 0.0)
    sample.body_id = b2.create_body(world_id, body_def)
    let box = b2.make_box(0.1, 1.0)
    b2.create_polygon_shape(sample.body_id, b2.default_shape_def(), box)

    return sample

extending Kinematic:
    editable function on_step() -> void:
        if common.stepped():
            let cs = b2.compute_cos_sin(this.time)
            let cs2 = b2.compute_cos_sin(2.0 * this.time)
            let point = b2.Vec2(
                x = 2.0 * this.amplitude * cs.cosine,
                y = this.amplitude * cs2.sine
            )
            let rotation = common.make_rot(2.0 * this.time)
            let axis = rotation.mul_vector(b2.Vec2(x = 0.0, y = 1.0))
            common.draw_world_segment(point.sub(axis.scale(0.5)), point.add(axis.scale(0.5)), b2.HexColor.b2_colorPlum)
            common.draw_world_point(point, 10.0, b2.HexColor.b2_colorPlum)
            let target = b2.Transform(p = point, q = rotation)
            b2.body_set_target_transform(this.body_id, target, 1.0 / common.HERTZ)
            this.time += 1.0 / common.HERTZ

    function draw_overlay() -> void:
        common.draw_text_line("kinematic body driven to a Lissajous target")

function main() -> int:
    let world_id = common.create_world()
    var sample = kinematic_create(world_id)
    return common.run(
        adapt[common.Sample](ref_of(sample)),
        "Box2D - Kinematic",
        b2.Vec2(x = 0.0, y = 0.0),
        4.0,
        world_id
    )

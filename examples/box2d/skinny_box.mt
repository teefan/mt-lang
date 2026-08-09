## Box2D sample port: "Skinny Box" (from box2d-upstream/samples/sample_continuous.cpp).
##
## A very skinny box or capsule drops at high speed with high angular velocity
## to stress continuous collision against a low-friction ground with a post.
##   C             toggle capsule / box shape
##   Space         launch
##   A             toggle auto test (relaunch every 60 steps)
##   Left mouse    drag bodies (mouse joint)
##   P             pause, Space single-step

import std.box2d as b2
import std.raylib as rl
import examples.box2d.common as common

struct SkinnyBox implements common.Sample:
    world: b2.WorldId
    body_id: b2.BodyId
    capsule: bool
    auto_test: bool
    step_count: int

function skinny_box_create(world_id: b2.WorldId) -> SkinnyBox:
    let ground = b2.create_body(world_id, b2.default_body_def())
    var ground_shape = b2.default_shape_def()
    ground_shape.material.friction = 0.9
    let segment = b2.Segment(
        point1 = b2.Vec2(x = -10.0, y = 0.0),
        point2 = b2.Vec2(x = 10.0, y = 0.0)
    )
    b2.create_segment_shape(ground, ground_shape, segment)
    let post = b2.make_offset_box(0.1, 1.0, b2.Vec2(x = 0.0, y = 1.0), b2.b2Rot_identity)
    b2.create_polygon_shape(ground, ground_shape, post)

    var sample = SkinnyBox(
        world = world_id,
        body_id = b2.b2_nullBodyId,
        capsule = false,
        auto_test = false,
        step_count = 0
    )
    sample.launch()
    return sample

extending SkinnyBox:
    editable function launch() -> void:
        if this.body_id != b2.b2_nullBodyId:
            b2.destroy_body(this.body_id)

        let angular_velocity = common.random_float_range(-50.0, 50.0)

        var body_def = b2.default_body_def()
        body_def.type = b2.BodyType.b2_dynamicBody
        body_def.position = b2.Vec2(x = 0.0, y = 8.0)
        body_def.angularVelocity = angular_velocity
        body_def.linearVelocity = b2.Vec2(x = 0.0, y = -100.0)
        this.body_id = b2.create_body(this.world, body_def)

        var shape_def = b2.default_shape_def()
        shape_def.density = 1.0
        shape_def.material.friction = 0.9

        if this.capsule:
            let capsule = b2.Capsule(
                center1 = b2.Vec2(x = 0.0, y = -1.0),
                center2 = b2.Vec2(x = 0.0, y = 1.0),
                radius = 0.1
            )
            b2.create_capsule_shape(this.body_id, shape_def, capsule)
        else:
            let polygon = b2.make_box(2.0, 0.05)
            b2.create_polygon_shape(this.body_id, shape_def, polygon)

    editable function on_step() -> void:
        if rl.is_key_pressed(rl.KeyboardKey.KEY_C):
            this.capsule = not this.capsule
            this.launch()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            this.launch()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_A):
            this.auto_test = not this.auto_test
        if this.auto_test and this.step_count % 60 == 0:
            this.launch()
        this.step_count += 1

    function draw_overlay() -> void:
        common.draw_text_line(f"capsule = #{this.capsule} auto test = #{this.auto_test}")
        common.draw_text_line("C: capsule  Space: launch  A: auto test")

function main() -> int:
    let world_id = common.create_world()
    var sample = skinny_box_create(world_id)
    return common.run(
        adapt[common.Sample](ref_of(sample)),
        "Box2D - Skinny Box",
        b2.Vec2(x = 1.0, y = 5.0),
        25.0 * 0.25,
        world_id
    )

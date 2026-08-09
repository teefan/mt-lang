## Box2D sample port: "Falling Hinges" (from box2d-upstream/samples/sample_determinism.cpp).
##
## A 4-column by 30-row array of rounded boxes connected pairwise by revolute
## joints. Once every body sleeps, the step counter and a transform hash are
## shown, matching the cross-platform determinism unit test scenario.
##   Left mouse    drag bodies (mouse joint)
##   P             pause, Space single-step

import std.box2d as b2
import examples.box2d.common as common

const COLUMN_COUNT: int = 4
const ROW_COUNT: int = 30
const BODY_COUNT: int = COLUMN_COUNT * ROW_COUNT

struct FallingHinges implements common.Sample:
    world: b2.WorldId
    body_ids: array[b2.BodyId, BODY_COUNT]
    step_count: int
    sleep_step: int
    hash: uint
    done: bool

function falling_hinges_create(world_id: b2.WorldId) -> FallingHinges:
    var body_def = b2.default_body_def()
    body_def.position = b2.Vec2(x = 0.0, y = -1.0)
    let ground = b2.create_body(world_id, body_def)
    let ground_box = b2.make_box(20.0, 1.0)
    b2.create_polygon_shape(ground, b2.default_shape_def(), ground_box)

    var sample = FallingHinges(
        world = world_id,
        body_ids = zero[array[b2.BodyId, BODY_COUNT]],
        step_count = 0,
        sleep_step = -1,
        hash = 0u,
        done = false
    )

    let h = 0.25
    let r = 0.1 * h
    let box = b2.make_rounded_box(h - r, h - r, r)
    var shape_def = b2.default_shape_def()
    shape_def.material.friction = 0.3

    let offset = 0.4 * h
    let dx = 10.0 * h
    let xroot = -0.5 * dx * (COLUMN_COUNT - 1)

    var joint_def = b2.default_revolute_joint_def()
    joint_def.enableLimit = true
    joint_def.lowerAngle = -0.1 * b2.B2_PI
    joint_def.upperAngle = 0.2 * b2.B2_PI
    joint_def.enableSpring = true
    joint_def.hertz = 0.5
    joint_def.dampingRatio = 0.5
    joint_def.localAnchorA = b2.Vec2(x = h, y = h)
    joint_def.localAnchorB = b2.Vec2(x = offset, y = -h)
    joint_def.drawSize = 0.1

    var body_index = 0
    var column = 0
    while column < COLUMN_COUNT:
        let x = xroot + column * dx
        var prev_body: b2.BodyId = b2.b2_nullBodyId
        var row = 0
        while row < ROW_COUNT:
            var bdef = b2.default_body_def()
            bdef.type = b2.BodyType.b2_dynamicBody
            bdef.position = b2.Vec2(x = x + offset * row, y = h + 2.0 * h * row)
            bdef.rotation = common.make_rot(0.1 * (row) - 1.0)
            let body = b2.create_body(world_id, bdef)
            if row % 2 == 0:
                prev_body = body
            else:
                joint_def.bodyIdA = prev_body
                joint_def.bodyIdB = body
                b2.create_revolute_joint(world_id, joint_def)
                prev_body = b2.b2_nullBodyId
            b2.create_polygon_shape(body, shape_def, box)
            sample.body_ids[body_index] = body
            body_index += 1
            row += 1
        column += 1

    return sample

extending FallingHinges:
    editable function on_step() -> void:
        if this.done:
            return
        if this.hash == 0u:
            let body_events = b2.world_get_body_events(this.world)
            if body_events.moveCount == 0:
                var hash: uint = 5381u
                var index = 0
                while index < BODY_COUNT:
                    var xf = b2.body_get_transform(this.body_ids[index])
                    let data = unsafe: reinterpret[ptr[ubyte]](ptr_of(xf))
                    hash = b2.hash(hash, data, 16)
                    index += 1
                this.hash = hash
                this.sleep_step = this.step_count
        this.step_count += 1
        if this.hash != 0u:
            this.done = true

    function draw_overlay() -> void:
        if this.done:
            common.draw_text_line(f"sleep step = #{this.sleep_step}, hash = 0x#{this.hash:x}")
        else:
            common.draw_text_line("waiting for all bodies to sleep...")

function main() -> int:
    let world_id = common.create_world()
    var sample = falling_hinges_create(world_id)
    return common.run(
        adapt[common.Sample](ref_of(sample)),
        "Box2D - Falling Hinges",
        b2.Vec2(x = 0.0, y = 7.5),
        10.0,
        world_id
    )

## Box2D sample port: "Explosion" (from box2d-upstream/samples/sample_shapes.cpp).
##
## A zero-gravity wheel of twelve box segments welded to a static hub, slowly
## spinning. Pressing Space triggers b2World_Explode at the hub.
##   Space         explode
##   Left mouse    drag bodies (mouse joint)
##   P             pause, Space single-step

import std.box2d as b2
import std.raylib as rl
import examples.box2d.common as common

const SPOKE_COUNT: int = 12

struct Explosion implements common.Sample:
    world: b2.WorldId
    joint_ids: array[b2.JointId, SPOKE_COUNT]
    radius: float
    falloff: float
    impulse: float
    reference_angle: float

function unwind_angle(radians: float) -> float:
    var result = radians
    while result > b2.B2_PI:
        result -= 2.0 * b2.B2_PI
    while result < -b2.B2_PI:
        result += 2.0 * b2.B2_PI
    return result

function explosion_create(world_id: b2.WorldId) -> Explosion:
    var sample = Explosion(
        world = world_id,
        joint_ids = zero[array[b2.JointId, SPOKE_COUNT]],
        radius = 7.0,
        falloff = 3.0,
        impulse = 10.0,
        reference_angle = 0.0
    )

    let body_def = b2.default_body_def()
    let ground = b2.create_body(world_id, body_def)

    var spoke_def = b2.default_body_def()
    spoke_def.type = b2.BodyType.b2_dynamicBody
    spoke_def.gravityScale = 0.0

    let shape_def = b2.default_shape_def()

    var weld_def = b2.default_weld_joint_def()
    weld_def.referenceAngle = 0.0
    weld_def.angularHertz = 0.5
    weld_def.angularDampingRatio = 0.7
    weld_def.linearHertz = 0.5
    weld_def.linearDampingRatio = 0.7
    weld_def.bodyIdA = ground
    weld_def.localAnchorB = b2.Vec2(x = 0.0, y = 0.0)

    let box = b2.make_box(1.0, 0.1)
    let r = 8.0

    var index = 0
    while index < SPOKE_COUNT:
        let angle = index * 30.0 * b2.B2_PI / 180.0
        let cs = b2.compute_cos_sin(angle)
        let position = b2.Vec2(x = r * cs.cosine, y = r * cs.sine)
        spoke_def.position = position
        let body = b2.create_body(world_id, spoke_def)
        b2.create_polygon_shape(body, shape_def, box)
        weld_def.localAnchorA = position
        weld_def.bodyIdB = body
        sample.joint_ids[index] = b2.create_weld_joint(world_id, weld_def)
        index += 1

    return sample

extending Explosion:
    editable function on_step() -> void:
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            var explosion_def = b2.default_explosion_def()
            explosion_def.position = b2.Vec2(x = 0.0, y = 0.0)
            explosion_def.radius = this.radius
            explosion_def.falloff = this.falloff
            explosion_def.impulsePerLength = this.impulse
            b2.world_explode(this.world, explosion_def)

        if common.stepped():
            this.reference_angle += 60.0 * b2.B2_PI / 180.0 / common.HERTZ
            this.reference_angle = unwind_angle(this.reference_angle)
            var index = 0
            while index < SPOKE_COUNT:
                b2.joint_set_reference_angle(this.joint_ids[index], this.reference_angle)
                index += 1

    function draw_overlay() -> void:
        let origin = b2.Vec2(x = 0.0, y = 0.0)
        common.draw_world_circle(origin, this.radius + this.falloff, b2.HexColor.b2_colorBox2DBlue)
        common.draw_world_circle(origin, this.radius, b2.HexColor.b2_colorBox2DYellow)
        common.draw_text_line(f"reference angle = #{this.reference_angle}")
        common.draw_text_line("Space: explode")

function main() -> int:
    let world_id = common.create_world()
    var sample = explosion_create(world_id)
    return common.run(
        adapt[common.Sample](ref_of(sample)),
        "Box2D - Explosion",
        b2.Vec2(x = 0.0, y = 0.0),
        14.0,
        world_id
    )

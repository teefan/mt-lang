## Box2D sample port: "Body Type" (from box2d-upstream/samples/sample_bodies.cpp).
##
## A platform and payloads whose body type can be switched between static,
## kinematic, and dynamic at runtime, showing how each interacts.
##   1 / 2 / 3     static / kinematic / dynamic
##   E             toggle bodies enabled
##   Left mouse    drag bodies (mouse joint)
##   P             pause, Space single-step

import std.box2d as b2
import std.raylib as rl
import examples.box2d.common as common

struct BodyType implements common.Sample:
    world: b2.WorldId
    attachment_id: b2.BodyId
    second_attachment_id: b2.BodyId
    platform_id: b2.BodyId
    second_payload_id: b2.BodyId
    touching_body_id: b2.BodyId
    floating_body_id: b2.BodyId
    body_kind: b2.BodyType
    speed: float
    is_enabled: bool

function body_type_create(world_id: b2.WorldId) -> BodyType:
    var sample = BodyType(
        world = world_id,
        attachment_id = b2.b2_nullBodyId,
        second_attachment_id = b2.b2_nullBodyId,
        platform_id = b2.b2_nullBodyId,
        second_payload_id = b2.b2_nullBodyId,
        touching_body_id = b2.b2_nullBodyId,
        floating_body_id = b2.b2_nullBodyId,
        body_kind = b2.BodyType.b2_dynamicBody,
        speed = 3.0,
        is_enabled = true
    )

    let ground = b2.create_body(world_id, b2.default_body_def())
    let segment = b2.Segment(
        point1 = b2.Vec2(x = -20.0, y = 0.0),
        point2 = b2.Vec2(x = 20.0, y = 0.0)
    )
    b2.create_segment_shape(ground, b2.default_shape_def(), segment)

    # attachment
    var body_def = b2.default_body_def()
    body_def.type = b2.BodyType.b2_dynamicBody
    body_def.position = b2.Vec2(x = -2.0, y = 3.0)
    sample.attachment_id = b2.create_body(world_id, body_def)
    var box_shape = b2.default_shape_def()
    box_shape.density = 1.0
    let box = b2.make_box(0.5, 2.0)
    b2.create_polygon_shape(sample.attachment_id, box_shape, box)

    # second attachment
    body_def = b2.default_body_def()
    body_def.type = sample.body_kind
    body_def.isEnabled = sample.is_enabled
    body_def.position = b2.Vec2(x = 3.0, y = 3.0)
    sample.second_attachment_id = b2.create_body(world_id, body_def)
    b2.create_polygon_shape(sample.second_attachment_id, box_shape, box)

    # platform
    body_def = b2.default_body_def()
    body_def.type = sample.body_kind
    body_def.isEnabled = sample.is_enabled
    body_def.position = b2.Vec2(x = -4.0, y = 5.0)
    sample.platform_id = b2.create_body(world_id, body_def)
    let platform_box = b2.make_offset_box(
        0.5, 4.0,
        b2.Vec2(x = 4.0, y = 0.0),
        common.make_rot(0.5 * b2.B2_PI)
    )
    var platform_shape = b2.default_shape_def()
    platform_shape.density = 2.0
    b2.create_polygon_shape(sample.platform_id, platform_shape, platform_box)

    var revolute = b2.default_revolute_joint_def()
    revolute.maxMotorTorque = 50.0
    revolute.enableMotor = true
    let pivot1 = b2.Vec2(x = -2.0, y = 5.0)
    revolute.bodyIdA = sample.attachment_id
    revolute.bodyIdB = sample.platform_id
    revolute.localAnchorA = b2.body_get_local_point(sample.attachment_id, pivot1)
    revolute.localAnchorB = b2.body_get_local_point(sample.platform_id, pivot1)
    b2.create_revolute_joint(world_id, revolute)
    let pivot2 = b2.Vec2(x = 3.0, y = 5.0)
    revolute.bodyIdA = sample.second_attachment_id
    revolute.bodyIdB = sample.platform_id
    revolute.localAnchorA = b2.body_get_local_point(sample.second_attachment_id, pivot2)
    revolute.localAnchorB = b2.body_get_local_point(sample.platform_id, pivot2)
    b2.create_revolute_joint(world_id, revolute)

    var prismatic = b2.default_prismatic_joint_def()
    prismatic.bodyIdA = ground
    prismatic.bodyIdB = sample.platform_id
    let anchor = b2.Vec2(x = 0.0, y = 5.0)
    prismatic.localAnchorA = b2.body_get_local_point(ground, anchor)
    prismatic.localAnchorB = b2.body_get_local_point(sample.platform_id, anchor)
    prismatic.localAxisA = b2.Vec2(x = 1.0, y = 0.0)
    prismatic.maxMotorForce = 1000.0
    prismatic.motorSpeed = 0.0
    prismatic.enableMotor = true
    prismatic.lowerTranslation = -10.0
    prismatic.upperTranslation = 10.0
    prismatic.enableLimit = true
    b2.create_prismatic_joint(world_id, prismatic)

    # payload
    body_def = b2.default_body_def()
    body_def.type = b2.BodyType.b2_dynamicBody
    body_def.position = b2.Vec2(x = -3.0, y = 8.0)
    let payload = b2.create_body(world_id, body_def)
    let payload_box = b2.make_box(0.75, 0.75)
    var payload_shape = b2.default_shape_def()
    payload_shape.density = 2.0
    b2.create_polygon_shape(payload, payload_shape, payload_box)

    # second payload
    body_def = b2.default_body_def()
    body_def.type = sample.body_kind
    body_def.isEnabled = sample.is_enabled
    body_def.position = b2.Vec2(x = 2.0, y = 8.0)
    sample.second_payload_id = b2.create_body(world_id, body_def)
    b2.create_polygon_shape(sample.second_payload_id, payload_shape, payload_box)

    # touching body on the ground
    body_def = b2.default_body_def()
    body_def.type = sample.body_kind
    body_def.isEnabled = sample.is_enabled
    body_def.position = b2.Vec2(x = 8.0, y = 0.2)
    sample.touching_body_id = b2.create_body(world_id, body_def)
    let capsule = b2.Capsule(
        center1 = b2.Vec2(x = 0.0, y = 0.0),
        center2 = b2.Vec2(x = 1.0, y = 0.0),
        radius = 0.25
    )
    b2.create_capsule_shape(sample.touching_body_id, payload_shape, capsule)

    # floating body
    body_def = b2.default_body_def()
    body_def.type = sample.body_kind
    body_def.isEnabled = sample.is_enabled
    body_def.position = b2.Vec2(x = -8.0, y = 12.0)
    body_def.gravityScale = 0.0
    sample.floating_body_id = b2.create_body(world_id, body_def)
    let circle = b2.Circle(center = b2.Vec2(x = 0.0, y = 0.5), radius = 0.25)
    b2.create_circle_shape(sample.floating_body_id, payload_shape, circle)

    return sample

extending BodyType:
    editable function set_body_type(kind: b2.BodyType) -> void:
        this.body_kind = kind
        b2.body_set_type(this.platform_id, kind)
        b2.body_set_type(this.second_attachment_id, kind)
        b2.body_set_type(this.second_payload_id, kind)
        b2.body_set_type(this.touching_body_id, kind)
        b2.body_set_type(this.floating_body_id, kind)
        if kind == b2.BodyType.b2_kinematicBody:
            b2.body_set_linear_velocity(this.platform_id, b2.Vec2(x = -this.speed, y = 0.0))
            b2.body_set_angular_velocity(this.platform_id, 0.0)

    editable function set_enabled(enable: bool) -> void:
        this.is_enabled = enable
        if enable:
            b2.body_enable(this.platform_id)
            b2.body_enable(this.second_attachment_id)
            b2.body_enable(this.second_payload_id)
            b2.body_enable(this.touching_body_id)
            b2.body_enable(this.floating_body_id)
            if this.body_kind == b2.BodyType.b2_kinematicBody:
                b2.body_set_linear_velocity(this.platform_id, b2.Vec2(x = -this.speed, y = 0.0))
                b2.body_set_angular_velocity(this.platform_id, 0.0)
        else:
            b2.body_disable(this.platform_id)
            b2.body_disable(this.second_attachment_id)
            b2.body_disable(this.second_payload_id)
            b2.body_disable(this.touching_body_id)
            b2.body_disable(this.floating_body_id)

    editable function on_step() -> void:
        if rl.is_key_pressed(rl.KeyboardKey.KEY_ONE):
            this.set_body_type(b2.BodyType.b2_staticBody)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_TWO):
            this.set_body_type(b2.BodyType.b2_kinematicBody)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_THREE):
            this.set_body_type(b2.BodyType.b2_dynamicBody)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_E):
            this.set_enabled(not this.is_enabled)

        # drive the kinematic platform back and forth
        if this.body_kind == b2.BodyType.b2_kinematicBody:
            let p = b2.body_get_position(this.platform_id)
            var v = b2.body_get_linear_velocity(this.platform_id)
            if (p.x < -14.0 and v.x < 0.0) or (p.x > 6.0 and v.x > 0.0):
                v = b2.Vec2(x = -v.x, y = v.y)
                b2.body_set_linear_velocity(this.platform_id, v)

    function kind_label() -> str:
        if this.body_kind == b2.BodyType.b2_staticBody:
            return "static"
        if this.body_kind == b2.BodyType.b2_kinematicBody:
            return "kinematic"
        return "dynamic"

    function draw_overlay() -> void:
        common.draw_text_line(f"body type = #{this.kind_label()} enabled = #{this.is_enabled}")
        common.draw_text_line("1/2/3: type  E: toggle enabled")

function main() -> int:
    let world_id = common.create_world()
    var sample = body_type_create(world_id)
    return common.run(
        adapt[common.Sample](ref_of(sample)),
        "Box2D - Body Type",
        b2.Vec2(x = 0.8, y = 6.4),
        25.0 * 0.4,
        world_id
    )

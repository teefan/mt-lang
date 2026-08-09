## Box2D sample port: "Bridge" (from box2d-upstream/samples/sample_joints.cpp).
##
## A suspension bridge of 160 planks connected by revolute joints with springs
## and motor friction. Two triangles and three circles are dropped onto it.
##   [ / ]         joint friction torque
##   , / .         spring hertz
##   - / =         spring damping ratio
##   ; / '         constraint hertz
##   / / \         constraint damping ratio
##   Left mouse    drag bodies (mouse joint)
##   P             pause, Space single-step

import std.box2d as b2
import std.raylib as rl
import examples.box2d.common as common

const PLANK_COUNT: int = 160
const JOINT_COUNT: int = PLANK_COUNT + 1

struct Bridge implements common.Sample:
    world: b2.WorldId
    body_ids: array[b2.BodyId, PLANK_COUNT]
    joint_ids: array[b2.JointId, JOINT_COUNT]
    friction_torque: float
    spring_hertz: float
    spring_damping_ratio: float
    constraint_hertz: float
    constraint_damping_ratio: float

function bridge_create(world_id: b2.WorldId) -> Bridge:
    var sample = Bridge(
        world = world_id,
        body_ids = zero[array[b2.BodyId, PLANK_COUNT]],
        joint_ids = zero[array[b2.JointId, JOINT_COUNT]],
        friction_torque = 200.0,
        spring_hertz = 2.0,
        spring_damping_ratio = 0.7,
        constraint_hertz = 60.0,
        constraint_damping_ratio = 0.0
    )

    let ground = b2.create_body(world_id, b2.default_body_def())

    let plank_box = b2.make_box(0.5, 0.125)
    var shape_def = b2.default_shape_def()
    shape_def.density = 20.0

    var joint_def = b2.default_revolute_joint_def()
    joint_def.enableMotor = true
    joint_def.maxMotorTorque = sample.friction_torque
    joint_def.enableSpring = true
    joint_def.hertz = sample.spring_hertz
    joint_def.dampingRatio = sample.spring_damping_ratio

    let xbase = -80.0
    var prev_body = ground
    var index = 0
    while index < PLANK_COUNT:
        var body_def = b2.default_body_def()
        body_def.type = b2.BodyType.b2_dynamicBody
        body_def.position = b2.Vec2(x = xbase + 0.5 + index, y = 20.0)
        body_def.linearDamping = 0.1
        body_def.angularDamping = 0.1
        sample.body_ids[index] = b2.create_body(world_id, body_def)
        b2.create_polygon_shape(sample.body_ids[index], shape_def, plank_box)

        let pivot = b2.Vec2(x = xbase + index, y = 20.0)
        joint_def.bodyIdA = prev_body
        joint_def.bodyIdB = sample.body_ids[index]
        joint_def.localAnchorA = b2.body_get_local_point(prev_body, pivot)
        joint_def.localAnchorB = b2.body_get_local_point(sample.body_ids[index], pivot)
        sample.joint_ids[index] = b2.create_revolute_joint(world_id, joint_def)
        prev_body = sample.body_ids[index]
        index += 1

    let end_pivot = b2.Vec2(x = xbase + PLANK_COUNT, y = 20.0)
    joint_def.bodyIdA = prev_body
    joint_def.bodyIdB = ground
    joint_def.localAnchorA = b2.body_get_local_point(prev_body, end_pivot)
    joint_def.localAnchorB = b2.body_get_local_point(ground, end_pivot)
    sample.joint_ids[PLANK_COUNT] = b2.create_revolute_joint(world_id, joint_def)

    let triangle_points: array[b2.Vec2, 3] = array[b2.Vec2, 3](
        b2.Vec2(x = -0.5, y = 0.0),
        b2.Vec2(x = 0.5, y = 0.0),
        b2.Vec2(x = 0.0, y = 1.5)
    )
    let triangle_hull = b2.compute_hull(const_ptr_of(triangle_points[0]), 3)
    let triangle = b2.make_polygon(const_ptr_of(triangle_hull), 0.0)
    var heavy_shape = b2.default_shape_def()
    heavy_shape.density = 20.0

    index = 0
    while index < 2:
        var body_def = b2.default_body_def()
        body_def.type = b2.BodyType.b2_dynamicBody
        body_def.position = b2.Vec2(x = -8.0 + 8.0 * index, y = 22.0)
        let body = b2.create_body(world_id, body_def)
        b2.create_polygon_shape(body, heavy_shape, triangle)
        index += 1

    let circle = b2.Circle(center = b2.Vec2(x = 0.0, y = 0.0), radius = 0.5)
    index = 0
    while index < 3:
        var body_def = b2.default_body_def()
        body_def.type = b2.BodyType.b2_dynamicBody
        body_def.position = b2.Vec2(x = -6.0 + 6.0 * index, y = 25.0)
        let body = b2.create_body(world_id, body_def)
        b2.create_circle_shape(body, heavy_shape, circle)
        index += 1

    return sample

extending Bridge:
    editable function apply_joint_settings() -> void:
        var index = 0
        while index < JOINT_COUNT:
            b2.revolute_joint_set_max_motor_torque(this.joint_ids[index], this.friction_torque)
            b2.revolute_joint_set_spring_hertz(this.joint_ids[index], this.spring_hertz)
            b2.revolute_joint_set_spring_damping_ratio(this.joint_ids[index], this.spring_damping_ratio)
            b2.joint_set_constraint_tuning(
                this.joint_ids[index],
                this.constraint_hertz,
                this.constraint_damping_ratio
            )
            index += 1

    editable function on_step() -> void:
        var changed = false
        if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT_BRACKET):
            this.friction_torque = common.max_float(this.friction_torque - 100.0, 0.0)
            changed = true
        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT_BRACKET):
            this.friction_torque = common.min_float(this.friction_torque + 100.0, 10000.0)
            changed = true
        if rl.is_key_pressed(rl.KeyboardKey.KEY_COMMA):
            this.spring_hertz = common.max_float(this.spring_hertz - 0.5, 0.0)
            changed = true
        if rl.is_key_pressed(rl.KeyboardKey.KEY_PERIOD):
            this.spring_hertz = common.min_float(this.spring_hertz + 0.5, 30.0)
            changed = true
        if rl.is_key_pressed(rl.KeyboardKey.KEY_MINUS):
            this.spring_damping_ratio = common.max_float(this.spring_damping_ratio - 0.1, 0.0)
            changed = true
        if rl.is_key_pressed(rl.KeyboardKey.KEY_EQUAL):
            this.spring_damping_ratio = common.min_float(this.spring_damping_ratio + 0.1, 2.0)
            changed = true
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SEMICOLON):
            this.constraint_hertz = common.max_float(this.constraint_hertz - 15.0, 15.0)
            changed = true
        if rl.is_key_pressed(rl.KeyboardKey.KEY_APOSTROPHE):
            this.constraint_hertz = common.min_float(this.constraint_hertz + 15.0, 240.0)
            changed = true
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SLASH):
            this.constraint_damping_ratio = common.max_float(this.constraint_damping_ratio - 0.5, 0.0)
            changed = true
        if rl.is_key_pressed(rl.KeyboardKey.KEY_BACKSLASH):
            this.constraint_damping_ratio = common.min_float(this.constraint_damping_ratio + 0.5, 10.0)
            changed = true
        if changed:
            this.apply_joint_settings()

    function draw_overlay() -> void:
        common.draw_text_line(f"friction = #{this.friction_torque:.0} spring hertz = #{this.spring_hertz:.1}")
        common.draw_text_line(f"spring damping = #{this.spring_damping_ratio:.2}")
        common.draw_text_line(f"constraint = #{this.constraint_hertz:.0} / #{this.constraint_damping_ratio:.1}")
        common.draw_text_line("[] friction  ,/. s-hertz  -/= s-damping")
        common.draw_text_line(";/' c-hertz  /| c-damping")

function main() -> int:
    let world_id = common.create_world()
    var sample = bridge_create(world_id)
    return common.run(
        adapt[common.Sample](ref_of(sample)),
        "Box2D - Bridge",
        b2.Vec2(x = 0.0, y = 20.0),
        25.0 * 2.5,
        world_id
    )

## Box2D sample port: "Prismatic" (from box2d-upstream/samples/sample_joints.cpp).
##
## A box slides along a prismatic joint with a tilted axis, with optional
## limits, a motor, and a spring.
##   L             toggle joint limit
##   M             toggle joint motor
##   S             toggle joint spring
##   Up / Down     motor speed (when motor enabled)
##   [ / ]         max motor force (when motor enabled)
##   , / .         spring hertz (when spring enabled)
##   - / =         spring target translation (when spring enabled)
##   Left mouse    drag bodies (mouse joint)
##   P             pause, Space single-step

import std.box2d as b2
import std.raylib as rl
import examples.box2d.common as common

struct PrismaticJoint implements common.Sample:
    world: b2.WorldId
    joint_id: b2.JointId
    motor_speed: float
    motor_force: float
    hertz: float
    damping_ratio: float
    translation: float
    enable_spring: bool
    enable_motor: bool
    enable_limit: bool

function prismatic_joint_create(world_id: b2.WorldId) -> PrismaticJoint:
    let ground = b2.create_body(world_id, b2.default_body_def())

    var sample = PrismaticJoint(
        world = world_id,
        joint_id = b2.b2_nullJointId,
        motor_speed = 2.0,
        motor_force = 25.0,
        hertz = 1.0,
        damping_ratio = 0.5,
        translation = 0.0,
        enable_spring = false,
        enable_motor = false,
        enable_limit = true
    )

    var body_def = b2.default_body_def()
    body_def.position = b2.Vec2(x = 0.0, y = 10.0)
    body_def.type = b2.BodyType.b2_dynamicBody
    let body = b2.create_body(world_id, body_def)
    let box = b2.make_box(0.5, 2.0)
    b2.create_polygon_shape(body, b2.default_shape_def(), box)

    let pivot = b2.Vec2(x = 0.0, y = 9.0)
    let axis = b2.Vec2(x = 1.0, y = 1.0).normalize()
    var joint_def = b2.default_prismatic_joint_def()
    joint_def.bodyIdA = ground
    joint_def.bodyIdB = body
    joint_def.localAxisA = b2.body_get_local_vector(ground, axis)
    joint_def.localAnchorA = b2.body_get_local_point(ground, pivot)
    joint_def.localAnchorB = b2.body_get_local_point(body, pivot)
    joint_def.motorSpeed = sample.motor_speed
    joint_def.maxMotorForce = sample.motor_force
    joint_def.enableMotor = sample.enable_motor
    joint_def.lowerTranslation = -10.0
    joint_def.upperTranslation = 10.0
    joint_def.enableLimit = sample.enable_limit
    joint_def.enableSpring = sample.enable_spring
    joint_def.hertz = sample.hertz
    joint_def.dampingRatio = sample.damping_ratio
    sample.joint_id = b2.create_prismatic_joint(world_id, joint_def)

    return sample

extending PrismaticJoint:
    editable function on_step() -> void:
        if rl.is_key_pressed(rl.KeyboardKey.KEY_L):
            this.enable_limit = not this.enable_limit
            b2.prismatic_joint_enable_limit(this.joint_id, this.enable_limit)
            b2.joint_wake_bodies(this.joint_id)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_M):
            this.enable_motor = not this.enable_motor
            b2.prismatic_joint_enable_motor(this.joint_id, this.enable_motor)
            b2.joint_wake_bodies(this.joint_id)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_S):
            this.enable_spring = not this.enable_spring
            b2.prismatic_joint_enable_spring(this.joint_id, this.enable_spring)
            b2.joint_wake_bodies(this.joint_id)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_UP):
            this.motor_speed = common.min_float(this.motor_speed + 1.0, 40.0)
            b2.prismatic_joint_set_motor_speed(this.joint_id, this.motor_speed)
            b2.joint_wake_bodies(this.joint_id)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_DOWN):
            this.motor_speed = common.max_float(this.motor_speed - 1.0, -40.0)
            b2.prismatic_joint_set_motor_speed(this.joint_id, this.motor_speed)
            b2.joint_wake_bodies(this.joint_id)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT_BRACKET):
            this.motor_force = common.max_float(this.motor_force - 5.0, 0.0)
            b2.prismatic_joint_set_max_motor_force(this.joint_id, this.motor_force)
            b2.joint_wake_bodies(this.joint_id)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT_BRACKET):
            this.motor_force = common.min_float(this.motor_force + 5.0, 200.0)
            b2.prismatic_joint_set_max_motor_force(this.joint_id, this.motor_force)
            b2.joint_wake_bodies(this.joint_id)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_COMMA):
            this.hertz = common.max_float(this.hertz - 0.5, 0.0)
            b2.prismatic_joint_set_spring_hertz(this.joint_id, this.hertz)
            b2.joint_wake_bodies(this.joint_id)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_PERIOD):
            this.hertz = common.min_float(this.hertz + 0.5, 10.0)
            b2.prismatic_joint_set_spring_hertz(this.joint_id, this.hertz)
            b2.joint_wake_bodies(this.joint_id)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_MINUS):
            this.translation = common.max_float(this.translation - 0.5, -5.0)
            b2.prismatic_joint_set_target_translation(this.joint_id, this.translation)
            b2.joint_wake_bodies(this.joint_id)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_EQUAL):
            this.translation = common.min_float(this.translation + 0.5, 5.0)
            b2.prismatic_joint_set_target_translation(this.joint_id, this.translation)
            b2.joint_wake_bodies(this.joint_id)

    function draw_overlay() -> void:
        let force = b2.prismatic_joint_get_motor_force(this.joint_id)
        let translation = b2.prismatic_joint_get_translation(this.joint_id)
        let speed = b2.prismatic_joint_get_speed(this.joint_id)
        common.draw_text_line(f"motor force = #{force:.2} translation = #{translation:.2}")
        common.draw_text_line(f"speed = #{speed:.4}  L limit  M motor  S spring")
        common.draw_text_line("Up/Dn speed  [] force  ,/. hertz  -/= target")

function main() -> int:
    let world_id = common.create_world()
    var sample = prismatic_joint_create(world_id)
    return common.run(
        adapt[common.Sample](ref_of(sample)),
        "Box2D - Prismatic",
        b2.Vec2(x = 0.0, y = 8.0),
        25.0 * 0.5,
        world_id
    )

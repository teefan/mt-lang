## Box2D sample port: "Wheel" (from box2d-upstream/samples/sample_joints.cpp).
##
## A capsule rides on a wheel joint along a tilted axis with spring, limit, and
## motor all enabled.
##   L             toggle joint limit
##   M             toggle joint motor
##   S             toggle joint spring
##   Up / Down     motor speed (when motor enabled)
##   [ / ]         max motor torque (when motor enabled)
##   , / .         spring hertz (when spring enabled)
##   - / =         spring damping ratio (when spring enabled)
##   Left mouse    drag bodies (mouse joint)
##   P             pause, Space single-step

import std.box2d as b2
import std.raylib as rl
import examples.box2d.common as common

struct WheelJoint implements common.Sample:
    world: b2.WorldId
    joint_id: b2.JointId
    motor_speed: float
    motor_torque: float
    hertz: float
    damping_ratio: float
    enable_spring: bool
    enable_motor: bool
    enable_limit: bool

function wheel_joint_create(world_id: b2.WorldId) -> WheelJoint:
    let ground = b2.create_body(world_id, b2.default_body_def())

    var sample = WheelJoint(
        world = world_id,
        joint_id = b2.b2_nullJointId,
        motor_speed = 2.0,
        motor_torque = 5.0,
        hertz = 1.0,
        damping_ratio = 0.7,
        enable_spring = true,
        enable_motor = true,
        enable_limit = true
    )

    var body_def = b2.default_body_def()
    body_def.position = b2.Vec2(x = 0.0, y = 10.25)
    body_def.type = b2.BodyType.b2_dynamicBody
    let body = b2.create_body(world_id, body_def)
    let capsule = b2.Capsule(
        center1 = b2.Vec2(x = 0.0, y = -0.5),
        center2 = b2.Vec2(x = 0.0, y = 0.5),
        radius = 0.5
    )
    b2.create_capsule_shape(body, b2.default_shape_def(), capsule)

    let pivot = b2.Vec2(x = 0.0, y = 10.0)
    let axis = b2.Vec2(x = 1.0, y = 1.0).normalize()
    var joint_def = b2.default_wheel_joint_def()
    joint_def.bodyIdA = ground
    joint_def.bodyIdB = body
    joint_def.localAxisA = b2.body_get_local_vector(ground, axis)
    joint_def.localAnchorA = b2.body_get_local_point(ground, pivot)
    joint_def.localAnchorB = b2.body_get_local_point(body, pivot)
    joint_def.motorSpeed = sample.motor_speed
    joint_def.maxMotorTorque = sample.motor_torque
    joint_def.enableMotor = sample.enable_motor
    joint_def.lowerTranslation = -3.0
    joint_def.upperTranslation = 3.0
    joint_def.enableLimit = sample.enable_limit
    joint_def.hertz = sample.hertz
    joint_def.dampingRatio = sample.damping_ratio
    sample.joint_id = b2.create_wheel_joint(world_id, joint_def)

    return sample

extending WheelJoint:
    editable function on_step() -> void:
        if rl.is_key_pressed(rl.KeyboardKey.KEY_L):
            this.enable_limit = not this.enable_limit
            b2.wheel_joint_enable_limit(this.joint_id, this.enable_limit)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_M):
            this.enable_motor = not this.enable_motor
            b2.wheel_joint_enable_motor(this.joint_id, this.enable_motor)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_S):
            this.enable_spring = not this.enable_spring
            b2.wheel_joint_enable_spring(this.joint_id, this.enable_spring)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_UP):
            this.motor_speed = common.min_float(this.motor_speed + 1.0, 20.0)
            b2.wheel_joint_set_motor_speed(this.joint_id, this.motor_speed)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_DOWN):
            this.motor_speed = common.max_float(this.motor_speed - 1.0, -20.0)
            b2.wheel_joint_set_motor_speed(this.joint_id, this.motor_speed)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT_BRACKET):
            this.motor_torque = common.max_float(this.motor_torque - 1.0, 0.0)
            b2.wheel_joint_set_max_motor_torque(this.joint_id, this.motor_torque)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT_BRACKET):
            this.motor_torque = common.min_float(this.motor_torque + 1.0, 20.0)
            b2.wheel_joint_set_max_motor_torque(this.joint_id, this.motor_torque)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_COMMA):
            this.hertz = common.max_float(this.hertz - 0.5, 0.0)
            b2.wheel_joint_set_spring_hertz(this.joint_id, this.hertz)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_PERIOD):
            this.hertz = common.min_float(this.hertz + 0.5, 10.0)
            b2.wheel_joint_set_spring_hertz(this.joint_id, this.hertz)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_MINUS):
            this.damping_ratio = common.max_float(this.damping_ratio - 0.1, 0.0)
            b2.wheel_joint_set_spring_damping_ratio(this.joint_id, this.damping_ratio)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_EQUAL):
            this.damping_ratio = common.min_float(this.damping_ratio + 0.1, 2.0)
            b2.wheel_joint_set_spring_damping_ratio(this.joint_id, this.damping_ratio)

    function draw_overlay() -> void:
        let torque = b2.wheel_joint_get_motor_torque(this.joint_id)
        common.draw_text_line(f"motor torque = #{torque:.2}  L limit  M motor  S spring")
        common.draw_text_line("Up/Dn speed  [] torque  ,/. hertz  -/= damping")

function main() -> int:
    let world_id = common.create_world()
    var sample = wheel_joint_create(world_id)
    return common.run(
        adapt[common.Sample](ref_of(sample)),
        "Box2D - Wheel",
        b2.Vec2(x = 0.0, y = 10.0),
        25.0 * 0.15,
        world_id
    )

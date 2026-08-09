## Box2D sample port: "Revolute" (from box2d-upstream/samples/sample_joints.cpp).
##
## A capsule pendulum and an offset-box lever, both connected to the ground by
## revolute joints with limits, a spring, and a motor.
##   L             toggle joint limit
##   M             toggle joint motor
##   S             toggle joint spring
##   Up / Down     motor speed (when motor enabled)
##   [ / ]         max motor torque (when motor enabled)
##   - / =         target angle degrees (when spring enabled)
##   , / .         spring hertz (when spring enabled)
##   Left mouse    drag bodies (mouse joint)
##   P             pause, Space single-step

import std.box2d as b2
import std.raylib as rl
import examples.box2d.common as common

struct RevoluteJoint implements common.Sample:
    world: b2.WorldId
    joint_id1: b2.JointId
    joint_id2: b2.JointId
    motor_speed: float
    motor_torque: float
    hertz: float
    damping_ratio: float
    target_degrees: float
    enable_spring: bool
    enable_motor: bool
    enable_limit: bool

function revolute_joint_create(world_id: b2.WorldId) -> RevoluteJoint:
    var body_def = b2.default_body_def()
    body_def.position = b2.Vec2(x = 0.0, y = -1.0)
    let ground = b2.create_body(world_id, body_def)
    let ground_box = b2.make_box(40.0, 1.0)
    b2.create_polygon_shape(ground, b2.default_shape_def(), ground_box)

    var sample = RevoluteJoint(
        world = world_id,
        joint_id1 = b2.b2_nullJointId,
        joint_id2 = b2.b2_nullJointId,
        motor_speed = 1.0,
        motor_torque = 1000.0,
        hertz = 2.0,
        damping_ratio = 0.5,
        target_degrees = 45.0,
        enable_spring = false,
        enable_motor = false,
        enable_limit = true
    )

    # capsule pendulum
    var capsule_def = b2.default_body_def()
    capsule_def.type = b2.BodyType.b2_dynamicBody
    capsule_def.position = b2.Vec2(x = -10.0, y = 20.0)
    let body1 = b2.create_body(world_id, capsule_def)
    var shape_def = b2.default_shape_def()
    shape_def.density = 1.0
    let capsule = b2.Capsule(
        center1 = b2.Vec2(x = 0.0, y = -1.0),
        center2 = b2.Vec2(x = 0.0, y = 6.0),
        radius = 0.5
    )
    b2.create_capsule_shape(body1, shape_def, capsule)
    let pivot1 = b2.Vec2(x = -10.0, y = 20.5)
    var joint1 = b2.default_revolute_joint_def()
    joint1.bodyIdA = ground
    joint1.bodyIdB = body1
    joint1.localAnchorA = b2.body_get_local_point(ground, pivot1)
    joint1.localAnchorB = b2.body_get_local_point(body1, pivot1)
    joint1.targetAngle = b2.B2_PI * 45.0 / 180.0
    joint1.enableSpring = false
    joint1.hertz = 2.0
    joint1.dampingRatio = 0.5
    joint1.motorSpeed = 1.0
    joint1.maxMotorTorque = 1000.0
    joint1.enableMotor = false
    joint1.referenceAngle = 0.5 * b2.B2_PI
    joint1.lowerAngle = -0.5 * b2.B2_PI
    joint1.upperAngle = 0.75 * b2.B2_PI
    joint1.enableLimit = true
    sample.joint_id1 = b2.create_revolute_joint(world_id, joint1)

    # ball that falls onto the pendulum
    var ball_def = b2.default_body_def()
    ball_def.type = b2.BodyType.b2_dynamicBody
    ball_def.position = b2.Vec2(x = 5.0, y = 30.0)
    let ball = b2.create_body(world_id, ball_def)
    let ball_circle = b2.Circle(center = b2.Vec2(x = 0.0, y = 0.0), radius = 2.0)
    b2.create_circle_shape(ball, shape_def, ball_circle)

    # offset-box lever
    var lever_def = b2.default_body_def()
    lever_def.type = b2.BodyType.b2_dynamicBody
    lever_def.position = b2.Vec2(x = 20.0, y = 10.0)
    let lever = b2.create_body(world_id, lever_def)
    let lever_box = b2.make_offset_box(10.0, 0.5, b2.Vec2(x = -10.0, y = 0.0), b2.b2Rot_identity)
    b2.create_polygon_shape(lever, shape_def, lever_box)
    let pivot2 = b2.Vec2(x = 19.0, y = 10.0)
    var joint2 = b2.default_revolute_joint_def()
    joint2.bodyIdA = ground
    joint2.bodyIdB = lever
    joint2.localAnchorA = b2.body_get_local_point(ground, pivot2)
    joint2.localAnchorB = b2.body_get_local_point(lever, pivot2)
    joint2.lowerAngle = -0.25 * b2.B2_PI
    joint2.upperAngle = 0.1 * b2.B2_PI
    joint2.enableLimit = true
    joint2.enableMotor = true
    joint2.motorSpeed = 0.0
    joint2.maxMotorTorque = sample.motor_torque
    sample.joint_id2 = b2.create_revolute_joint(world_id, joint2)

    return sample

extending RevoluteJoint:
    editable function on_step() -> void:
        if rl.is_key_pressed(rl.KeyboardKey.KEY_L):
            this.enable_limit = not this.enable_limit
            b2.revolute_joint_enable_limit(this.joint_id1, this.enable_limit)
            b2.joint_wake_bodies(this.joint_id1)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_M):
            this.enable_motor = not this.enable_motor
            b2.revolute_joint_enable_motor(this.joint_id1, this.enable_motor)
            b2.joint_wake_bodies(this.joint_id1)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_S):
            this.enable_spring = not this.enable_spring
            b2.revolute_joint_enable_spring(this.joint_id1, this.enable_spring)
            b2.joint_wake_bodies(this.joint_id1)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_UP):
            this.motor_speed = common.min_float(this.motor_speed + 1.0, 20.0)
            b2.revolute_joint_set_motor_speed(this.joint_id1, this.motor_speed)
            b2.joint_wake_bodies(this.joint_id1)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_DOWN):
            this.motor_speed = common.max_float(this.motor_speed - 1.0, -20.0)
            b2.revolute_joint_set_motor_speed(this.joint_id1, this.motor_speed)
            b2.joint_wake_bodies(this.joint_id1)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT_BRACKET):
            this.motor_torque = common.max_float(this.motor_torque - 100.0, 0.0)
            b2.revolute_joint_set_max_motor_torque(this.joint_id1, this.motor_torque)
            b2.joint_wake_bodies(this.joint_id1)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT_BRACKET):
            this.motor_torque = common.min_float(this.motor_torque + 100.0, 5000.0)
            b2.revolute_joint_set_max_motor_torque(this.joint_id1, this.motor_torque)
            b2.joint_wake_bodies(this.joint_id1)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_MINUS):
            this.target_degrees = common.max_float(this.target_degrees - 5.0, -180.0)
            b2.revolute_joint_set_target_angle(this.joint_id1, b2.B2_PI * this.target_degrees / 180.0)
            b2.joint_wake_bodies(this.joint_id1)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_EQUAL):
            this.target_degrees = common.min_float(this.target_degrees + 5.0, 180.0)
            b2.revolute_joint_set_target_angle(this.joint_id1, b2.B2_PI * this.target_degrees / 180.0)
            b2.joint_wake_bodies(this.joint_id1)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_COMMA):
            this.hertz = common.max_float(this.hertz - 0.5, 0.0)
            b2.revolute_joint_set_spring_hertz(this.joint_id1, this.hertz)
            b2.joint_wake_bodies(this.joint_id1)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_PERIOD):
            this.hertz = common.min_float(this.hertz + 0.5, 30.0)
            b2.revolute_joint_set_spring_hertz(this.joint_id1, this.hertz)
            b2.joint_wake_bodies(this.joint_id1)

    function draw_overlay() -> void:
        let angle1 = b2.revolute_joint_get_angle(this.joint_id1)
        let torque1 = b2.revolute_joint_get_motor_torque(this.joint_id1)
        let torque2 = b2.revolute_joint_get_motor_torque(this.joint_id2)
        common.draw_text_line(f"angle = #{angle1:.2} motor torque 1 = #{torque1:.2}")
        common.draw_text_line(f"motor torque 2 = #{torque2:.2}  L limit  M motor  S spring")
        common.draw_text_line("Up/Dn speed  [] torque  -/= target  ,/. hertz")

function main() -> int:
    let world_id = common.create_world()
    var sample = revolute_joint_create(world_id)
    return common.run(
        adapt[common.Sample](ref_of(sample)),
        "Box2D - Revolute",
        b2.Vec2(x = 0.0, y = 15.5),
        25.0 * 0.7,
        world_id
    )

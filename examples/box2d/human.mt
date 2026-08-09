## Port of box2d-upstream/shared/human.c.
##
## Builds a humanoid ragdoll from eleven capsule/polygon bones connected by
## revolute joints with limits, motors, and springs.

import std.box2d as b2
import examples.box2d.common as common

const BONE_HIP: int = 0
const BONE_TORSO: int = 1
const BONE_HEAD: int = 2
const BONE_UPPER_LEFT_LEG: int = 3
const BONE_LOWER_LEFT_LEG: int = 4
const BONE_UPPER_RIGHT_LEG: int = 5
const BONE_LOWER_RIGHT_LEG: int = 6
const BONE_UPPER_LEFT_ARM: int = 7
const BONE_LOWER_LEFT_ARM: int = 8
const BONE_UPPER_RIGHT_ARM: int = 9
const BONE_LOWER_RIGHT_ARM: int = 10
public const BONE_COUNT: int = 11

public struct Bone:
    body_id: b2.BodyId
    joint_id: b2.JointId
    friction_scale: float
    parent_index: int

public struct Human:
    bones: array[Bone, BONE_COUNT]
    friction_torque: float
    scale: float
    spawned: bool

function create_joint(
    world_id: b2.WorldId,
    body_a: b2.BodyId,
    body_b: b2.BodyId,
    pivot: b2.Vec2,
    lower_angle: float,
    upper_angle: float,
    max_torque: float,
    hertz: float,
    damping_ratio: float,
    draw_size: float
) -> b2.JointId:
    var joint_def = b2.default_revolute_joint_def()
    joint_def.bodyIdA = body_a
    joint_def.bodyIdB = body_b
    joint_def.localAnchorA = b2.body_get_local_point(body_a, pivot)
    joint_def.localAnchorB = b2.body_get_local_point(body_b, pivot)
    joint_def.enableLimit = true
    joint_def.lowerAngle = lower_angle
    joint_def.upperAngle = upper_angle
    joint_def.enableMotor = true
    joint_def.maxMotorTorque = max_torque
    joint_def.enableSpring = hertz > 0.0
    joint_def.hertz = hertz
    joint_def.dampingRatio = damping_ratio
    joint_def.drawSize = draw_size
    return b2.create_revolute_joint(world_id, joint_def)

public function create_human(
    world_id: b2.WorldId,
    position: b2.Vec2,
    scale: float,
    friction_torque: float,
    hertz: float,
    damping_ratio: float,
    group_index: int
) -> Human:
    var human = Human(
        bones = zero[array[Bone, BONE_COUNT]],
        friction_torque = friction_torque,
        scale = scale,
        spawned = false
    )
    var index = 0
    while index < BONE_COUNT:
        human.bones[index].body_id = b2.b2_nullBodyId
        human.bones[index].joint_id = b2.b2_nullJointId
        human.bones[index].friction_scale = 1.0
        human.bones[index].parent_index = -1
        index += 1

    var body_def = b2.default_body_def()
    body_def.type = b2.BodyType.b2_dynamicBody
    body_def.sleepThreshold = 0.1

    var shape_def = b2.default_shape_def()
    shape_def.material.friction = 0.2
    shape_def.filter.groupIndex = -group_index
    shape_def.filter.categoryBits = 2z
    shape_def.filter.maskBits = 3z

    var foot_shape_def = shape_def
    foot_shape_def.material.friction = 0.05
    foot_shape_def.filter.categoryBits = 2z
    foot_shape_def.filter.maskBits = 1z

    let s = scale
    let max_torque = friction_torque * s
    let draw_size = 0.05

    # hip
    body_def.position = position.add(b2.Vec2(x = 0.0, y = 0.95 * s))
    body_def.linearDamping = 0.0
    human.bones[BONE_HIP].body_id = b2.create_body(world_id, body_def)
    let hip_capsule = b2.Capsule(
        center1 = b2.Vec2(x = 0.0, y = -0.02 * s),
        center2 = b2.Vec2(x = 0.0, y = 0.02 * s),
        radius = 0.095 * s
    )
    b2.create_capsule_shape(human.bones[BONE_HIP].body_id, shape_def, hip_capsule)

    # torso
    human.bones[BONE_TORSO].parent_index = BONE_HIP
    body_def.position = position.add(b2.Vec2(x = 0.0, y = 1.2 * s))
    body_def.linearDamping = 0.0
    human.bones[BONE_TORSO].body_id = b2.create_body(world_id, body_def)
    human.bones[BONE_TORSO].friction_scale = 0.5
    let torso_capsule = b2.Capsule(
        center1 = b2.Vec2(x = 0.0, y = -0.135 * s),
        center2 = b2.Vec2(x = 0.0, y = 0.135 * s),
        radius = 0.09 * s
    )
    b2.create_capsule_shape(human.bones[BONE_TORSO].body_id, shape_def, torso_capsule)
    let torso_pivot = position.add(b2.Vec2(x = 0.0, y = 1.0 * s))
    human.bones[BONE_TORSO].joint_id = create_joint(
        world_id, human.bones[BONE_HIP].body_id, human.bones[BONE_TORSO].body_id,
        torso_pivot, -0.25 * b2.B2_PI, 0.0,
        human.bones[BONE_TORSO].friction_scale * max_torque, hertz, damping_ratio, draw_size
    )

    # head
    human.bones[BONE_HEAD].parent_index = BONE_TORSO
    body_def.position = position.add(b2.Vec2(x = 0.0, y = 1.475 * s))
    body_def.linearDamping = 0.1
    human.bones[BONE_HEAD].body_id = b2.create_body(world_id, body_def)
    human.bones[BONE_HEAD].friction_scale = 0.25
    let head_capsule = b2.Capsule(
        center1 = b2.Vec2(x = 0.0, y = -0.038 * s),
        center2 = b2.Vec2(x = 0.0, y = 0.039 * s),
        radius = 0.075 * s
    )
    b2.create_capsule_shape(human.bones[BONE_HEAD].body_id, shape_def, head_capsule)
    let head_pivot = position.add(b2.Vec2(x = 0.0, y = 1.4 * s))
    human.bones[BONE_HEAD].joint_id = create_joint(
        world_id, human.bones[BONE_TORSO].body_id, human.bones[BONE_HEAD].body_id,
        head_pivot, -0.3 * b2.B2_PI, 0.1 * b2.B2_PI,
        human.bones[BONE_HEAD].friction_scale * max_torque, hertz, damping_ratio, draw_size
    )

    let foot_points: array[b2.Vec2, 4] = array[b2.Vec2, 4](
        b2.Vec2(x = -0.03 * s, y = -0.185 * s),
        b2.Vec2(x = 0.11 * s, y = -0.185 * s),
        b2.Vec2(x = 0.11 * s, y = -0.16 * s),
        b2.Vec2(x = -0.03 * s, y = -0.14 * s)
    )
    let foot_hull = b2.compute_hull(const_ptr_of(foot_points[0]), 4)
    let foot_polygon = b2.make_polygon(const_ptr_of(foot_hull), 0.015 * s)

    # upper left leg
    human.bones[BONE_UPPER_LEFT_LEG].parent_index = BONE_HIP
    body_def.position = position.add(b2.Vec2(x = 0.0, y = 0.775 * s))
    body_def.linearDamping = 0.0
    human.bones[BONE_UPPER_LEFT_LEG].body_id = b2.create_body(world_id, body_def)
    human.bones[BONE_UPPER_LEFT_LEG].friction_scale = 1.0
    let upper_leg_capsule = b2.Capsule(
        center1 = b2.Vec2(x = 0.0, y = -0.125 * s),
        center2 = b2.Vec2(x = 0.0, y = 0.125 * s),
        radius = 0.06 * s
    )
    b2.create_capsule_shape(human.bones[BONE_UPPER_LEFT_LEG].body_id, shape_def, upper_leg_capsule)
    let upper_leg_pivot = position.add(b2.Vec2(x = 0.0, y = 0.9 * s))
    human.bones[BONE_UPPER_LEFT_LEG].joint_id = create_joint(
        world_id, human.bones[BONE_HIP].body_id, human.bones[BONE_UPPER_LEFT_LEG].body_id,
        upper_leg_pivot, -0.05 * b2.B2_PI, 0.4 * b2.B2_PI,
        human.bones[BONE_UPPER_LEFT_LEG].friction_scale * max_torque, hertz, damping_ratio, draw_size
    )

    # lower left leg
    human.bones[BONE_LOWER_LEFT_LEG].parent_index = BONE_UPPER_LEFT_LEG
    body_def.position = position.add(b2.Vec2(x = 0.0, y = 0.475 * s))
    body_def.linearDamping = 0.0
    human.bones[BONE_LOWER_LEFT_LEG].body_id = b2.create_body(world_id, body_def)
    human.bones[BONE_LOWER_LEFT_LEG].friction_scale = 0.5
    let lower_leg_capsule = b2.Capsule(
        center1 = b2.Vec2(x = 0.0, y = -0.155 * s),
        center2 = b2.Vec2(x = 0.0, y = 0.125 * s),
        radius = 0.045 * s
    )
    b2.create_capsule_shape(human.bones[BONE_LOWER_LEFT_LEG].body_id, shape_def, lower_leg_capsule)
    b2.create_polygon_shape(human.bones[BONE_LOWER_LEFT_LEG].body_id, foot_shape_def, foot_polygon)
    let lower_leg_pivot = position.add(b2.Vec2(x = 0.0, y = 0.625 * s))
    human.bones[BONE_LOWER_LEFT_LEG].joint_id = create_joint(
        world_id, human.bones[BONE_UPPER_LEFT_LEG].body_id, human.bones[BONE_LOWER_LEFT_LEG].body_id,
        lower_leg_pivot, -0.5 * b2.B2_PI, -0.02 * b2.B2_PI,
        human.bones[BONE_LOWER_LEFT_LEG].friction_scale * max_torque, hertz, damping_ratio, draw_size
    )

    # upper right leg
    human.bones[BONE_UPPER_RIGHT_LEG].parent_index = BONE_HIP
    body_def.position = position.add(b2.Vec2(x = 0.0, y = 0.775 * s))
    body_def.linearDamping = 0.0
    human.bones[BONE_UPPER_RIGHT_LEG].body_id = b2.create_body(world_id, body_def)
    human.bones[BONE_UPPER_RIGHT_LEG].friction_scale = 1.0
    b2.create_capsule_shape(human.bones[BONE_UPPER_RIGHT_LEG].body_id, shape_def, upper_leg_capsule)
    let upper_right_leg_pivot = position.add(b2.Vec2(x = 0.0, y = 0.9 * s))
    human.bones[BONE_UPPER_RIGHT_LEG].joint_id = create_joint(
        world_id, human.bones[BONE_HIP].body_id, human.bones[BONE_UPPER_RIGHT_LEG].body_id,
        upper_right_leg_pivot, -0.05 * b2.B2_PI, 0.4 * b2.B2_PI,
        human.bones[BONE_UPPER_RIGHT_LEG].friction_scale * max_torque, hertz, damping_ratio, draw_size
    )

    # lower right leg
    human.bones[BONE_LOWER_RIGHT_LEG].parent_index = BONE_UPPER_RIGHT_LEG
    body_def.position = position.add(b2.Vec2(x = 0.0, y = 0.475 * s))
    body_def.linearDamping = 0.0
    human.bones[BONE_LOWER_RIGHT_LEG].body_id = b2.create_body(world_id, body_def)
    human.bones[BONE_LOWER_RIGHT_LEG].friction_scale = 0.5
    b2.create_capsule_shape(human.bones[BONE_LOWER_RIGHT_LEG].body_id, shape_def, lower_leg_capsule)
    b2.create_polygon_shape(human.bones[BONE_LOWER_RIGHT_LEG].body_id, foot_shape_def, foot_polygon)
    let lower_right_leg_pivot = position.add(b2.Vec2(x = 0.0, y = 0.625 * s))
    human.bones[BONE_LOWER_RIGHT_LEG].joint_id = create_joint(
        world_id, human.bones[BONE_UPPER_RIGHT_LEG].body_id, human.bones[BONE_LOWER_RIGHT_LEG].body_id,
        lower_right_leg_pivot, -0.5 * b2.B2_PI, -0.02 * b2.B2_PI,
        human.bones[BONE_LOWER_RIGHT_LEG].friction_scale * max_torque, hertz, damping_ratio, draw_size
    )

    # upper left arm
    human.bones[BONE_UPPER_LEFT_ARM].parent_index = BONE_TORSO
    human.bones[BONE_UPPER_LEFT_ARM].friction_scale = 0.5
    body_def.position = position.add(b2.Vec2(x = 0.0, y = 1.225 * s))
    body_def.linearDamping = 0.0
    human.bones[BONE_UPPER_LEFT_ARM].body_id = b2.create_body(world_id, body_def)
    let upper_arm_capsule = b2.Capsule(
        center1 = b2.Vec2(x = 0.0, y = -0.125 * s),
        center2 = b2.Vec2(x = 0.0, y = 0.125 * s),
        radius = 0.035 * s
    )
    b2.create_capsule_shape(human.bones[BONE_UPPER_LEFT_ARM].body_id, shape_def, upper_arm_capsule)
    let upper_arm_pivot = position.add(b2.Vec2(x = 0.0, y = 1.35 * s))
    human.bones[BONE_UPPER_LEFT_ARM].joint_id = create_joint(
        world_id, human.bones[BONE_TORSO].body_id, human.bones[BONE_UPPER_LEFT_ARM].body_id,
        upper_arm_pivot, -0.1 * b2.B2_PI, 0.8 * b2.B2_PI,
        human.bones[BONE_UPPER_LEFT_ARM].friction_scale * max_torque, hertz, damping_ratio, draw_size
    )

    # lower left arm
    human.bones[BONE_LOWER_LEFT_ARM].parent_index = BONE_UPPER_LEFT_ARM
    body_def.position = position.add(b2.Vec2(x = 0.0, y = 0.975 * s))
    body_def.linearDamping = 0.1
    human.bones[BONE_LOWER_LEFT_ARM].body_id = b2.create_body(world_id, body_def)
    human.bones[BONE_LOWER_LEFT_ARM].friction_scale = 0.1
    let lower_arm_capsule = b2.Capsule(
        center1 = b2.Vec2(x = 0.0, y = -0.125 * s),
        center2 = b2.Vec2(x = 0.0, y = 0.125 * s),
        radius = 0.03 * s
    )
    b2.create_capsule_shape(human.bones[BONE_LOWER_LEFT_ARM].body_id, shape_def, lower_arm_capsule)
    let lower_arm_pivot = position.add(b2.Vec2(x = 0.0, y = 1.1 * s))
    human.bones[BONE_LOWER_LEFT_ARM].joint_id = create_joint(
        world_id, human.bones[BONE_UPPER_LEFT_ARM].body_id, human.bones[BONE_LOWER_LEFT_ARM].body_id,
        lower_arm_pivot, -0.2 * b2.B2_PI, 0.3 * b2.B2_PI,
        human.bones[BONE_LOWER_LEFT_ARM].friction_scale * max_torque, hertz, damping_ratio, draw_size
    )
    # reference angle 0.25*PI applied via setter below
    b2.joint_set_reference_angle(human.bones[BONE_LOWER_LEFT_ARM].joint_id, 0.25 * b2.B2_PI)

    # upper right arm
    human.bones[BONE_UPPER_RIGHT_ARM].parent_index = BONE_TORSO
    human.bones[BONE_UPPER_RIGHT_ARM].friction_scale = 0.5
    body_def.position = position.add(b2.Vec2(x = 0.0, y = 1.225 * s))
    body_def.linearDamping = 0.0
    human.bones[BONE_UPPER_RIGHT_ARM].body_id = b2.create_body(world_id, body_def)
    b2.create_capsule_shape(human.bones[BONE_UPPER_RIGHT_ARM].body_id, shape_def, upper_arm_capsule)
    let upper_right_arm_pivot = position.add(b2.Vec2(x = 0.0, y = 1.35 * s))
    human.bones[BONE_UPPER_RIGHT_ARM].joint_id = create_joint(
        world_id, human.bones[BONE_TORSO].body_id, human.bones[BONE_UPPER_RIGHT_ARM].body_id,
        upper_right_arm_pivot, -0.1 * b2.B2_PI, 0.8 * b2.B2_PI,
        human.bones[BONE_UPPER_RIGHT_ARM].friction_scale * max_torque, hertz, damping_ratio, draw_size
    )

    # lower right arm
    human.bones[BONE_LOWER_RIGHT_ARM].parent_index = BONE_UPPER_RIGHT_ARM
    body_def.position = position.add(b2.Vec2(x = 0.0, y = 0.975 * s))
    body_def.linearDamping = 0.1
    human.bones[BONE_LOWER_RIGHT_ARM].body_id = b2.create_body(world_id, body_def)
    human.bones[BONE_LOWER_RIGHT_ARM].friction_scale = 0.1
    b2.create_capsule_shape(human.bones[BONE_LOWER_RIGHT_ARM].body_id, shape_def, lower_arm_capsule)
    let lower_right_arm_pivot = position.add(b2.Vec2(x = 0.0, y = 1.1 * s))
    human.bones[BONE_LOWER_RIGHT_ARM].joint_id = create_joint(
        world_id, human.bones[BONE_UPPER_RIGHT_ARM].body_id, human.bones[BONE_LOWER_RIGHT_ARM].body_id,
        lower_right_arm_pivot, -0.2 * b2.B2_PI, 0.3 * b2.B2_PI,
        human.bones[BONE_LOWER_RIGHT_ARM].friction_scale * max_torque, hertz, damping_ratio, draw_size
    )
    b2.joint_set_reference_angle(human.bones[BONE_LOWER_RIGHT_ARM].joint_id, 0.25 * b2.B2_PI)

    human.spawned = true
    return human

public function destroy_human(human: ref[Human]) -> void:
    var index = 0
    while index < BONE_COUNT:
        if human.bones[index].joint_id != b2.b2_nullJointId:
            b2.destroy_joint(human.bones[index].joint_id)
            human.bones[index].joint_id = b2.b2_nullJointId
        index += 1
    index = 0
    while index < BONE_COUNT:
        if human.bones[index].body_id != b2.b2_nullBodyId:
            b2.destroy_body(human.bones[index].body_id)
            human.bones[index].body_id = b2.b2_nullBodyId
        index += 1
    human.spawned = false

public function human_set_joint_friction_torque(human: ref[Human], torque: float) -> void:
    if torque == 0.0:
        var index = 1
        while index < BONE_COUNT:
            b2.revolute_joint_enable_motor(human.bones[index].joint_id, false)
            index += 1
    else:
        var index = 1
        while index < BONE_COUNT:
            b2.revolute_joint_enable_motor(human.bones[index].joint_id, true)
            let scale = human.scale * human.bones[index].friction_scale
            b2.revolute_joint_set_max_motor_torque(human.bones[index].joint_id, scale * torque)
            index += 1

public function human_set_joint_spring_hertz(human: ref[Human], hertz: float) -> void:
    if hertz == 0.0:
        var index = 1
        while index < BONE_COUNT:
            b2.revolute_joint_enable_spring(human.bones[index].joint_id, false)
            index += 1
    else:
        var index = 1
        while index < BONE_COUNT:
            b2.revolute_joint_enable_spring(human.bones[index].joint_id, true)
            b2.revolute_joint_set_spring_hertz(human.bones[index].joint_id, hertz)
            index += 1

public function human_set_joint_damping_ratio(human: ref[Human], damping_ratio: float) -> void:
    var index = 1
    while index < BONE_COUNT:
        b2.revolute_joint_set_spring_damping_ratio(human.bones[index].joint_id, damping_ratio)
        index += 1

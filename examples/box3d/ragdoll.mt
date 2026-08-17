## Box3D sample port: "Ragdoll" (from box3d-upstream/samples/sample_ragdoll.cpp).
##
## A simplified humanoid made of capsule limbs and a spherical head, connected
## with spherical joints at the shoulders, elbows, hips, and knees. It drops
## onto the ground and collapses into a heap.
##   Left mouse     drag bodies (ray spring)
##   Right mouse    orbit camera
##   Wheel          zoom
##   P              pause, Space single-step
import std.box3d as b3
import examples.box3d.common as common

struct Ragdoll implements common.Sample:
    world: b3.WorldId

function make_limb(position: b3.Vec3, half_height: float, radius: float) -> b3.BodyId:
    return common.make_dynamic_capsule(position, half_height, radius)

function make_head(position: b3.Vec3, radius: float) -> b3.BodyId:
    return common.make_dynamic_sphere(position, radius)

function connect(world_id: b3.WorldId, body_a: b3.BodyId, body_b: b3.BodyId, local_a: b3.Vec3, local_b: b3.Vec3) -> void:
    var joint_def = b3.default_spherical_joint_def()
    joint_def.base.bodyIdA = body_a
    joint_def.base.bodyIdB = body_b
    joint_def.base.localFrameA.p = local_a
    joint_def.base.localFrameB.p = local_b
    joint_def.enableSpring = true
    joint_def.hertz = 8.0
    joint_def.dampingRatio = 1.0
    joint_def.enableConeLimit = true
    joint_def.coneAngle = 0.35
    b3.create_spherical_joint(world_id, joint_def)

function ragdoll_create(world_id: b3.WorldId) -> Ragdoll:
    common.add_ground_box(20.0)
    # pelvis at the center; torso above; head on top
    let pelvis = make_limb(b3.Vec3(x = 0.0, y = 1.5, z = 0.0), 0.2, 0.15)
    let torso = make_limb(b3.Vec3(x = 0.0, y = 2.2, z = 0.0), 0.4, 0.18)
    let head = make_head(b3.Vec3(x = 0.0, y = 3.1, z = 0.0), 0.2)
    connect(world_id, pelvis, torso, b3.Vec3(x = 0.0, y = 0.2, z = 0.0), b3.Vec3(x = 0.0, y = -0.4, z = 0.0))
    connect(world_id, torso, head, b3.Vec3(x = 0.0, y = 0.4, z = 0.0), b3.Vec3(x = 0.0, y = -0.2, z = 0.0))
    # arms
    let upper_arm_l = make_limb(b3.Vec3(x = -0.4, y = 2.4, z = 0.0), 0.25, 0.08)
    let lower_arm_l = make_limb(b3.Vec3(x = -0.4, y = 1.9, z = 0.0), 0.25, 0.07)
    let upper_arm_r = make_limb(b3.Vec3(x = 0.4, y = 2.4, z = 0.0), 0.25, 0.08)
    let lower_arm_r = make_limb(b3.Vec3(x = 0.4, y = 1.9, z = 0.0), 0.25, 0.07)
    connect(world_id, torso, upper_arm_l, b3.Vec3(x = -0.4, y = 0.2, z = 0.0), b3.Vec3(x = 0.0, y = 0.25, z = 0.0))
    connect(world_id, upper_arm_l, lower_arm_l, b3.Vec3(x = 0.0, y = -0.25, z = 0.0), b3.Vec3(x = 0.0, y = 0.25, z = 0.0))
    connect(world_id, torso, upper_arm_r, b3.Vec3(x = 0.4, y = 0.2, z = 0.0), b3.Vec3(x = 0.0, y = 0.25, z = 0.0))
    connect(world_id, upper_arm_r, lower_arm_r, b3.Vec3(x = 0.0, y = -0.25, z = 0.0), b3.Vec3(x = 0.0, y = 0.25, z = 0.0))
    # legs
    let upper_leg_l = make_limb(b3.Vec3(x = -0.2, y = 1.0, z = 0.0), 0.3, 0.12)
    let lower_leg_l = make_limb(b3.Vec3(x = -0.2, y = 0.45, z = 0.0), 0.3, 0.1)
    let upper_leg_r = make_limb(b3.Vec3(x = 0.2, y = 1.0, z = 0.0), 0.3, 0.12)
    let lower_leg_r = make_limb(b3.Vec3(x = 0.2, y = 0.45, z = 0.0), 0.3, 0.1)
    connect(world_id, pelvis, upper_leg_l, b3.Vec3(x = -0.2, y = -0.2, z = 0.0), b3.Vec3(x = 0.0, y = 0.3, z = 0.0))
    connect(world_id, upper_leg_l, lower_leg_l, b3.Vec3(x = 0.0, y = -0.3, z = 0.0), b3.Vec3(x = 0.0, y = 0.3, z = 0.0))
    connect(world_id, pelvis, upper_leg_r, b3.Vec3(x = 0.2, y = -0.2, z = 0.0), b3.Vec3(x = 0.0, y = 0.3, z = 0.0))
    connect(world_id, upper_leg_r, lower_leg_r, b3.Vec3(x = 0.0, y = -0.3, z = 0.0), b3.Vec3(x = 0.0, y = 0.3, z = 0.0))
    return Ragdoll(world = world_id)

extending Ragdoll:
    editable function on_step() -> void:
        pass

    editable function draw_overlay() -> void:
        common.draw_text_line("ragdoll: capsules + spheres on spherical joints")

function main() -> int:
    let world_id = common.create_world()
    var sample = ragdoll_create(world_id)
    return common.run(adapt[common.Sample](ref_of(sample)), "Box3D - Ragdoll", b3.Vec3(x = 0.0, y = 1.5, z = 0.0), 12.0)

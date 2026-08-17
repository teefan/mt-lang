## Box3D sample port: "Distance Joint" (from box3d-upstream/samples/sample_joint.cpp).
##
## A chain of four spheres hangs from a fixed anchor on distance joints with
## soft spring tuning, so the chain sways and settles.
##   Left mouse     drag bodies (ray spring)
##   Right mouse    orbit camera
##   Wheel          zoom
##   P              pause, Space single-step
import std.box3d as b3
import examples.box3d.common as common

const CHAIN_COUNT: int = 4

struct DistanceJoint implements common.Sample:
    world: b3.WorldId

function distance_joint_create(world_id: b3.WorldId) -> DistanceJoint:
    common.add_ground_box(20.0)
    let radius = 0.25
    let sphere = b3.Sphere(center = b3.b3Vec3_zero, radius = radius)
    # static anchor body high up
    var anchor_def = b3.default_body_def()
    anchor_def.position = b3.Vec3(x = 0.0, y = 8.0, z = 0.0)
    let anchor = b3.create_body(world_id, anchor_def)
    var joint_def = b3.default_distance_joint_def()
    joint_def.hertz = 5.0
    joint_def.dampingRatio = 0.5
    joint_def.length = 1.5
    joint_def.enableSpring = true
    joint_def.lowerSpringForce = -2000.0
    joint_def.upperSpringForce = 100.0
    var shape_def = b3.default_shape_def()
    shape_def.density = 20.0
    var prev = anchor
    var index = 0
    while index < CHAIN_COUNT:
        var sphere_body_def = b3.default_body_def()
        sphere_body_def.type = b3.BodyType.b3_dynamicBody
        sphere_body_def.angularDamping = 1.0
        sphere_body_def.position = b3.Vec3(x = 0.0, y = 8.0 - 1.5 * (index + 1), z = 0.0)
        let body = b3.create_body(world_id, sphere_body_def)
        common.track_body(body)
        b3.create_sphere_shape(body, shape_def, sphere)
        joint_def.base.bodyIdA = prev
        joint_def.base.bodyIdB = body
        joint_def.base.localFrameA.p = b3.b3Vec3_zero
        joint_def.base.localFrameB.p = b3.b3Vec3_zero
        b3.create_distance_joint(world_id, joint_def)
        prev = body
        index += 1
    return DistanceJoint(world = world_id)

extending DistanceJoint:
    editable function on_step() -> void:
        pass

    editable function draw_overlay() -> void:
        common.draw_text_line("distance joint chain: 4 spheres")

function main() -> int:
    let world_id = common.create_world()
    var sample = distance_joint_create(world_id)
    return common.run(adapt[common.Sample](ref_of(sample)), "Box3D - Distance Joint", b3.Vec3(x = 0.0, y = 4.0, z = 0.0), 18.0)

## Box3D sample port: "Capsule Stack" (from box3d-upstream/samples/sample_stacking.cpp).
##
## A stack of twenty horizontal capsules constrained to a 2D plane with motion
## locks (linear Z and all angular axes locked).
##   Left mouse     drag bodies (ray spring)
##   Right mouse    orbit camera
##   Wheel          zoom
##   P              pause, Space single-step
import std.box3d as b3
import examples.box3d.common as common

const CAPSULE_COUNT: int = 20

struct CapsuleStack implements common.Sample:
    world: b3.WorldId

function capsule_stack_create(world_id: b3.WorldId) -> CapsuleStack:
    common.add_ground_box(40.0)
    var body_def = b3.default_body_def()
    body_def.type = b3.BodyType.b3_dynamicBody
    body_def.motionLocks.linearZ = true
    body_def.motionLocks.angularX = true
    body_def.motionLocks.angularY = true
    body_def.motionLocks.angularZ = true
    let radius = 0.5
    let capsule = b3.Capsule(center1 = b3.Vec3(x = -1.0, y = 0.0, z = 0.0), center2 = b3.Vec3(x = 1.0, y = 0.0, z = 0.0), radius = radius)
    let shape_def = b3.default_shape_def()
    var y = 1.5 * radius
    var index = 0
    while index < CAPSULE_COUNT:
        body_def.position = b3.Vec3(x = 0.0, y = y, z = 0.0)
        let body = b3.create_body(world_id, body_def)
        common.track_body(body)
        b3.create_capsule_shape(body, shape_def, capsule)
        y += 2.0 * radius
        index += 1
    return CapsuleStack(world = world_id)

extending CapsuleStack:
    editable function on_step() -> void:
        pass

    editable function draw_overlay() -> void:
        common.draw_text_line("capsule stack: 20 capsules, motion locks on")

function main() -> int:
    let world_id = common.create_world()
    var sample = capsule_stack_create(world_id)
    return common.run(adapt[common.Sample](ref_of(sample)), "Box3D - Capsule Stack", b3.Vec3(x = 0.0, y = 10.0, z = 0.0), 30.0)

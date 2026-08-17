## Box3D sample port: "Box Stack" (from box3d-upstream/samples/sample_stacking.cpp).
##
## A tall stack of forty cubes with rolling resistance on a ground box.
##   Left mouse     drag bodies (ray spring)
##   Right mouse    orbit camera
##   Wheel          zoom
##   P              pause, Space single-step
import std.box3d as b3
import examples.box3d.common as common

const BOX_COUNT: int = 40

struct BoxStack implements common.Sample:
    world: b3.WorldId

function box_stack_create(world_id: b3.WorldId) -> BoxStack:
    common.add_ground_box(40.0)
    var body_def = b3.default_body_def()
    body_def.type = b3.BodyType.b3_dynamicBody
    body_def.name = c"cube"
    let a = 0.5
    let cube = b3.make_box_hull(a, a, a)
    var index = 0
    while index < BOX_COUNT:
        body_def.position = b3.Vec3(x = 0.0, y = 1.5 * a + 2.5 * a * index, z = 0.0)
        let body = b3.create_body(world_id, body_def)
        common.track_body(body)
        let shape_def = b3.default_shape_def()
        b3.create_hull_shape(body, shape_def, cube.base)
        index += 1
    return BoxStack(world = world_id)

extending BoxStack:
    editable function on_step() -> void:
        pass

    editable function draw_overlay() -> void:
        common.draw_text_line("box stack: 40 cubes")

function main() -> int:
    let world_id = common.create_world()
    var sample = box_stack_create(world_id)
    return common.run(adapt[common.Sample](ref_of(sample)), "Box3D - Box Stack", b3.Vec3(x = 0.0, y = 20.0, z = 0.0), 45.0)

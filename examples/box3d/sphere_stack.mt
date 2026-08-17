## Box3D sample port: "Sphere Stack" (from box3d-upstream/samples/sample_stacking.cpp).
##
## A tall stack of thirty spheres with rolling resistance on a ground box.
##   Left mouse     drag bodies (ray spring)
##   Right mouse    orbit camera
##   Wheel          zoom
##   P              pause, Space single-step
import std.box3d as b3
import examples.box3d.common as common

const SPHERE_COUNT: int = 30

struct SphereStack implements common.Sample:
    world: b3.WorldId

function sphere_stack_create(world_id: b3.WorldId) -> SphereStack:
    common.add_ground_box(15.0)
    var body_def = b3.default_body_def()
    body_def.type = b3.BodyType.b3_dynamicBody
    body_def.name = c"sphere"
    let radius = 0.5
    let sphere = b3.Sphere(center = b3.b3Vec3_zero, radius = radius)
    var shape_def = b3.default_shape_def()
    shape_def.baseMaterial.rollingResistance = 0.1
    var y = 1.5 * radius
    var index = 0
    while index < SPHERE_COUNT:
        body_def.position = b3.Vec3(x = 0.0, y = y, z = 0.0)
        let body = b3.create_body(world_id, body_def)
        common.track_body(body)
        b3.create_sphere_shape(body, shape_def, sphere)
        y += 3.0 * radius
        index += 1
    return SphereStack(world = world_id)

extending SphereStack:
    editable function on_step() -> void:
        pass

    editable function draw_overlay() -> void:
        common.draw_text_line("sphere stack: 30 spheres")

function main() -> int:
    let world_id = common.create_world()
    var sample = sphere_stack_create(world_id)
    return common.run(adapt[common.Sample](ref_of(sample)), "Box3D - Sphere Stack", b3.Vec3(x = 0.0, y = 10.0, z = 0.0), 40.0)

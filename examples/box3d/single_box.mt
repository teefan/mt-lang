## Box3D sample port: "Single Box" (from box3d-upstream/samples/sample_stacking.cpp).
##
## A single dynamic cube dropped onto a ground box. Overlay text shows the
## live position each frame.
##   Left mouse     drag bodies (ray spring)
##   Right mouse    orbit camera
##   Middle mouse   pan camera
##   Wheel          zoom
##   P              pause, Space single-step
import std.box3d as b3
import examples.box3d.common as common

struct SingleBox implements common.Sample:
    body: b3.BodyId

function single_box_create(world_id: b3.WorldId) -> SingleBox:
    common.add_ground_box(20.0)
    var body_def = b3.default_body_def()
    body_def.name = c"cube"
    body_def.type = b3.BodyType.b3_dynamicBody
    body_def.position = b3.Vec3(x = 0.0, y = 3.0, z = 0.0)
    body_def.angularVelocity = b3.Vec3(x = 0.0, y = 2.0, z = 0.0)
    let body = b3.create_body(world_id, body_def)
    common.track_body(body)
    let cube = b3.make_cube_hull(0.5)
    let shape_def = b3.default_shape_def()
    b3.create_hull_shape(body, shape_def, cube.base)
    return SingleBox(body = body)

extending SingleBox:
    editable function on_step() -> void:
        pass

    editable function draw_overlay() -> void:
        let position = b3.body_get_position(this.body)
        common.draw_text_line(f"position = (#{position.x:.2}, #{position.y:.2}, #{position.z:.2})")
        common.draw_text_line("Left mouse drags bodies")

function main() -> int:
    let world_id = common.create_world()
    var sample = single_box_create(world_id)
    return common.run(adapt[common.Sample](ref_of(sample)), "Box3D - Single Box", b3.Vec3(x = 0.0, y = 1.0, z = 0.0), 12.0)

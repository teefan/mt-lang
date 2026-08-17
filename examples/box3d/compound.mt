## Box3D sample port: "Simple Compound" (from box3d-upstream/samples/sample_compound.cpp).
##
## A ground body whose shape is a compound of a box hull offset to the side,
## with a sphere dropped onto it. Demonstrates baked compound shapes.
##   Left mouse     drag bodies (ray spring)
##   Right mouse    orbit camera
##   Wheel          zoom
##   P              pause, Space single-step
import std.box3d as b3
import examples.box3d.common as common

struct Compound implements common.Sample:
    compound: ptr[b3.CompoundData]

function compound_create(world_id: b3.WorldId) -> Compound:
    let a = 4.0
    let material = b3.default_surface_material()
    let box = b3.make_box_hull(a, 0.125 * a, a)
    var hull_transform = b3.Transform(p = b3.Vec3(x = 1.0, y = -0.125 * a, z = 0.0), q = common.quat_from_axis_angle(b3.b3Vec3_axisY, 0.0))
    let axis = b3.Vec3(x = 1.0, y = 0.0, z = 1.0).normalize()
    hull_transform.q = common.quat_from_axis_angle(axis, 0.0)
    var hulls: array[b3.CompoundHullDef, 1]
    hulls[0] = b3.CompoundHullDef(hull = const_ptr_of(box.base), transform = hull_transform, material = material)
    var compound_def = b3.CompoundDef(hulls = ptr_of(hulls[0]), hullCount = 1)
    let compound = b3.create_compound(ptr_of(compound_def))
    var body_def = b3.default_body_def()
    body_def.position = b3.Vec3(x = 2.0, y = -1.0, z = 0.0)
    body_def.rotation = common.quat_from_axis_angle(b3.b3Vec3_axisY, 0.25 * b3.B3_PI)
    let ground = b3.create_body(world_id, body_def)
    common.track_body(ground)
    var shape_def = b3.default_shape_def()
    b3.create_baked_compound_shape(ground, shape_def, compound)
    b3.world_set_contact_recycle_distance(world_id, 0.0)
    var sphere_body_def = b3.default_body_def()
    sphere_body_def.type = b3.BodyType.b3_dynamicBody
    sphere_body_def.position = b3.Vec3(x = 0.0, y = 2.0, z = 0.0)
    let sphere_body = b3.create_body(world_id, sphere_body_def)
    common.track_body(sphere_body)
    let sphere_shape_def = b3.default_shape_def()
    let sphere = b3.Sphere(center = b3.b3Vec3_zero, radius = 0.25)
    b3.create_sphere_shape(sphere_body, sphere_shape_def, sphere)
    return Compound(compound = compound)

extending Compound:
    editable function on_step() -> void:
        pass

    editable function draw_overlay() -> void:
        common.draw_text_line("compound: ground baked compound + sphere")

function main() -> int:
    let world_id = common.create_world()
    var sample = compound_create(world_id)
    return common.run(adapt[common.Sample](ref_of(sample)), "Box3D - Compound", b3.Vec3(x = 0.0, y = 0.0, z = 0.0), 25.0)
